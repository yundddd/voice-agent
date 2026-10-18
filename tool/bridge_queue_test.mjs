// Regression tests for the queue at +104 ('the queued message was lost').
// Both transports that park a prompt behind an in-flight turn must deliver
// it when the floor frees — whether the phone is still listening on its
// SSE stream or its socket died in the queue (Android watchdog, lifecycle
// HIDE). The old flushPending ate the second flavour silently: the pin
// froze at 'queued', no turn ever ran, the utterance was gone.
//
// Run: node --test tool/bridge_queue_test.mjs
//
// A real bridge process is spawned on a scratch port, driven over HTTP,
// with bridge_stub_claude.mjs as the harness: every utterance that
// reaches the harness is logged, so 'delivered' is a fact on disk, not a
// frame the client happened to see.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import http from 'node:http';

const HERE = new URL('.', import.meta.url).pathname;
const TOKEN = 'testtok';
// Wide window, pid-spread, one port per test (each spins its own bridge).
const PORT1 = 18732 + (process.pid % 977);
const PORT2 = PORT1 + 1;
const PORT3 = PORT1 + 2;
const PORT4 = PORT1 + 3;
const PORT5 = PORT1 + 4;
const PORT8 = PORT1 + 7;
const PORT9 = PORT1 + 8;

function startBridge(stubLog, port, extraEnv = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'bridge-qtest-'));
  const proc = spawn(
    process.execPath,
    [join(HERE, 'claude_bridge.mjs'), '--dir', dir, '--token', TOKEN,
      '--port', String(port), '--claude', join(HERE, 'bridge_stub_claude.mjs')],
    { env: { ...process.env, STUB_LOG: stubLog, STUB_RESULT_MS: '1500',
      ...extraEnv } },
  );
  proc.stderr.resume(); // keep the pipe draining; the test speaks over HTTP
  return proc;
}

// One HTTP exchange: resolves as soon as headers are in, then keeps
// accumulating the body (SSE streams included). .text reads the current
// stream contents, .kill() hangs up mid-stream like a dying phone.
function call(port, pathname, { body = null, method = 'GET' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(`http://127.0.0.1:${port}` + pathname,
      { method }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { text += c; });
      resolve({
        req,
        get text() { return text; },
        kill() { req.destroy(); },
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

const health = async (port) => JSON.parse((await call(port, '/health')).text);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, cond, ms = 6000) {
  const t0 = Date.now();
  for (;;) {
    if (await cond()) return;
    if (Date.now() - t0 > ms) throw new Error(`timeout waiting for ${what}`);
    await sleep(25);
  }
}
const seen = (stubLog) => {
  try { return readFileSync(stubLog, 'utf8').split('\n').filter(Boolean); }
  catch { return []; } // no file yet: nothing has reached the harness
};
async function stopBridge(proc) {
  proc.kill();
  if (!proc.exitCode) await new Promise((r) => proc.on('exit', r));
}
const up = (port) => until('bridge health', async () => {
  try { return (await health(port)).ok === true; } catch { return false; }
});

test('a polite queue whose phone stream died still gets its turn (+104)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT1);
  try {
    await up(PORT1);

    // Turn A, heard: the stub holds it open for 1.5 s.
    const a = await call(PORT1, `/talk?token=${TOKEN}`,
      { body: 'first turn', method: 'POST' });
    await until('turn A open', async () => (await health(PORT1)).turnOpen === true);

    // Turn B parks behind it politely and reads its notice…
    const b = await call(PORT1, `/talk?token=${TOKEN}&interrupt=0`,
      { body: 'second queued message', method: 'POST' });
    await until('B queued notice', async () => b.text.includes('"name":"queued"'));
    // B must NOT have reached the harness yet (the polite promise). Not
    // an equality on the log: the stub process is still booting here,
    // and 'first turn' may not have hit disk yet — its turn being OPEN
    // (turnOpen, the queued notice) is the proof A runs first.
    assert.ok(!seen(stubLog).includes('second queued message'),
      'polite queue jumped the in-flight turn');

    // …then the phone dies: socket gone BEFORE the flush. The old code
    // flipped this to abandoned and the message vanished here.
    b.kill();
    await until('queue flushed', async () => (await health(PORT1)).queued === false);

    // Delivered is a fact on disk: the harness received the prompt…
    await until('B reaching the harness', async () =>
      seen(stubLog).includes('second queued message'));
    // …and the ring carries the +81 pickup marker for the phone's return.
    const ring = JSON.parse((await call(PORT1, `/poll?token=${TOKEN}&since=0`)).text);
    assert.ok(ring.events.some((e) =>
      e.data?.name === 'started' && e.data?.detail === 'second queued message'),
      'no started marker on the ring');
    // B's own turn closed too (stub result #2): the machine is at rest.
    await until('everything settled', async () => {
      const h = await health(PORT1);
      return h.turnOpen === false && h.queued === false;
    });
    assert.deepEqual(seen(stubLog), ['first turn', 'second queued message']);
    assert.ok(a.text.includes('event: done'), 'turn A never got its own done');
  } finally {
    await stopBridge(proc);
  }
});

// The slide-up interrupt bug (field report: 'the conversation shows no
// updates at all'): the aborted turn's `done` must not reach a stream —
// the phone files a stray done against the fresh bubble it just sent,
// and the new turn is born dead.
test('an interrupted turn dies without a done of its own (+106)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT3);
  try {
    await up(PORT3);
    const a = await call(PORT3, `/talk?token=${TOKEN}`,
      { body: 'first turn', method: 'POST' });
    await until('turn A open', async () => (await health(PORT3)).turnOpen === true);
    const b = await call(PORT3, `/talk?token=${TOKEN}&interrupt=1`,
      { body: 'interrupting prompt', method: 'POST' });
    await until('B queued notice', async () => b.text.includes('"name":"queued"'));

    // A's timer-fired result closes the aborted turn while B is pending:
    // the view handover happens WITHOUT any done crossing over. Watch
    // from the flush instant — before B's own result can legitimately
    // produce one — so a leaking funeral notice shows up as a stray
    // 'event: done' on either stream.
    await until('queue flushed', async () => (await health(PORT3)).queued === false);
    assert.ok(!b.text.includes('event: done'),
      'stray done murdered the fresh bubble (the +106 bug)');
    assert.ok(!a.text.includes('event: done'),
      'the aborted turn leaked a done to the old view');

    // The fresh turn still lives and dies properly: its OWN done closes
    // its stream exactly once, and the harness got the prompt.
    await until('B own done', async () => b.text.includes('event: done'));
    assert.equal(b.text.split('event: done').length - 1, 1,
      'B saw more than one done');
    await until('B turn settled', async () => (await health(PORT3)).turnOpen === false);
    assert.deepEqual(seen(stubLog), ['first turn', 'interrupting prompt']);
  } finally {
    await stopBridge(proc);
  }
});

test('a polite queue on a live stream flushes to its own socket', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT2);
  try {
    await up(PORT2);
    const a = await call(PORT2, `/talk?token=${TOKEN}`,
      { body: 'first turn', method: 'POST' });
    await until('turn A open', async () => (await health(PORT2)).turnOpen === true);
    const b = await call(PORT2, `/talk?token=${TOKEN}&interrupt=0`,
      { body: 'second queued message', method: 'POST' });
    await until('B queued notice', async () => b.text.includes('"name":"queued"'));

    // The live path (beginTurn onto the waiting response): when A's result
    // frees the floor, B becomes the heard view and its OWN turn's done
    // arrives on B's stream — never diverted to A's.
    await until('B done event', async () => b.text.includes('event: done'));
    assert.ok(a.text.includes('event: done'), 'turn A never got its own done');
    assert.ok(b.text.indexOf('event: done') > b.text.indexOf('"name":"queued"'),
      'done preceded the queue notice');
    assert.deepEqual(seen(stubLog), ['first turn', 'second queued message']);
  } finally {
    await stopBridge(proc);
  }
});

// The +114 invariant: EVERY relayed sentence keeps exactly one copy in
// the unheard backlog — delivered-live included, because delivery is
// not hearing (the wire can die between frame and speaker, and the
// phone's retract-aware ledger decides at replay time). A re-relay of
// one sentence must never stack a second copy. /attach's replay is the
// ground truth for both.
test('every relayed sentence keeps one replayable copy, never two (+114)',
  async () => {
    const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
    const proc = startBridge(stubLog, PORT4, {
      STUB_SAYS: 'Heard once.\nNever twice.\nHeard once.', // third line: a
      // re-relay of the first — the copy must stay singular
    });
    try {
      await up(PORT4);
      const a = await call(PORT4, `/talk?token=${TOKEN}`,
        { body: 'tell me something', method: 'POST' });
      await until('turn open', async () => (await health(PORT4)).turnOpen === true);

      // The phone LISTENS all the way (no kill this time): the say
      // frames stream live AND still end up backed once each.
      await until('turn closed', async () => {
        const h = await health(PORT4);
        return h.turnOpen === false && h.missed >= 2;
      });
      const replayed = await call(PORT4, `/attach?token=${TOKEN}`);
      await until('backlog drained', async () => {
        try { return (await health(PORT4)).missed === 0; } catch { return false; }
      });
      await sleep(150); // let the replay bytes land in the collector
      const counts = (needle) =>
        replayed.text.split(needle).length - 1;
      assert.equal(counts('Heard once.'), 1,
        'the live-delivered copy was eaten or stacked (+112/+113 failure modes)');
      assert.equal(counts('Never twice.'), 1);
      a.kill();
    } finally {
      await stopBridge(proc);
    }
  });

// Behaviour 2 (the phone's Queue button, cuttool=1): a polite queue that
// lands over a RUNNING TOOL still backgrounds it — the agent is freed for
// the new prompt at once — and the tool's completion reports later, into
// the new turn's stream. Politeness governs THINKING only; nobody waits
// out a build they just interrupted the listening for.
const PORT6 = PORT1 + 5;
test('a queue press over a running tool backgrounds it and frees the agent ' +
    '(behaviour 2)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT6, {
    STUB_TOOL: 'npm test', STUB_TOOL_START_MS: '100',
    STUB_RESULT_MS: '30000', // the build never settles on its own here
    STUB_TOOL_DONE_MS: '700', STUB_TOOL_DONE_TEXT: 'Background build finished.',
  });
  try {
    await up(PORT6);
    // Turn A: a long build, heard live — the tool step proves it is open.
    const a = await call(PORT6, `/talk?token=${TOKEN}`,
      { body: 'run the suite', method: 'POST' });
    await until('Bash step relayed', async () => a.text.includes('"name":"Bash"'));

    // Queue politely-with-backgrounding over the open tool:
    const b = await call(PORT6, `/talk?token=${TOKEN}&interrupt=0&cuttool=1`,
      { body: 'status please', method: 'POST' });
    await until('notice announces the cut', async () =>
      b.text.includes('"name":"queued"') &&
      b.text.includes('the running call was interrupted'));

    // The queue did NOT wait for the 30 s build: the cut flushed the
    // floor within a heartbeat, in order, with no stray done (+106).
    await until('B reached the harness', async () =>
      seen(stubLog).includes('status please'));
    const lines = seen(stubLog);
    assert.ok(lines.indexOf('run the suite') < lines.indexOf('status please'),
      'the queue jumped the turn instead of cutting it');
    assert.ok(!a.text.includes('event: done'),
      'the cut turn got its funeral done anyway');

    // The ring carried the queue notice too — the pull transport gets
    // its 'One moment — the running tool was put into background' note.
    await until('queued notice on the ring', async () => {
      const r = JSON.parse((await call(PORT6, `/poll?token=${TOKEN}&since=0`)).text);
      return r.events.some((e) => e.ev === 'tool' && e.data?.name === 'queued');
    });

    // And the SURVIVING tool reports itself finished inside the new
    // turn — a structured 'finished' frame (what the phone's banner
    // retires on) plus its completion say for the conversation.
    await until('background completion lands', async () =>
      b.text.includes('Background build finished.'));
    assert.ok(b.text.includes('"name":"finished"'),
      'the tool_result of a cut tool must relay its finished frame');
    assert.ok(b.text.includes('Bash npm test'),
      'the finished frame names the command the banner showed');
    a.kill();
    b.kill();
  } finally {
    await stopBridge(proc);
  }
});

// The cut's paperwork, in the order the story needs (field report:
// 'out of timestamp order — says cancelled AND finished AND backgrounded
// all at once'). A queue press that kills a RUNNING tool sends its
// tool_result (Claude's error reply) BEFORE the turn's result — and
// with it flushPending: relaying that receipt on arrival stamped
// 'Bash sleep 10 finished.' above the 'put into background' notice it
// belonged to, and said FINISHED for a call the cut itself cancelled.
// The receipt now (1) waits for the flush, landing after queued/started,
// and (2) carries kind='cancelled' when the result says aborted.
const PORT6B = PORT1 + 15;
test('a cut tool\u2019s cancelled receipt follows its backgrounding notice ' +
    '(ordered, honest verb)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT6B, {
    STUB_TOOL: 'sleep 10', STUB_TOOL_START_MS: '100',
    STUB_RESULT_MS: '30000',
    STUB_TOOL_DONE_MS: '400',
    STUB_TOOL_CANCELLED: '1',
  });
  try {
    await up(PORT6B);
    const a = await call(PORT6B, `/talk?token=${TOKEN}`,
      { body: 'sleep please', method: 'POST' });
    await until('tool open', async () =>
      a.text.includes('"name":"Bash"'));
    const b = await call(PORT6B, `/talk?token=${TOKEN}&interrupt=0&cuttool=1`,
      { body: 'new message', method: 'POST' });

    // The ring is the phone's eye (both transports feed it; the pull
    // loop reads it): assert the STORY ORDER on the single sequence.
    await until('cancelled receipt on the ring', async () => {
      const r = JSON.parse((await call(PORT6B, `/poll?token=${TOKEN}&since=0`)).text);
      return (r.events ?? []).some((e) =>
        e.ev === 'tool' && e.data?.name === 'finished' &&
        e.data?.kind === 'cancelled');
    });
    const r = JSON.parse((await call(PORT6B, `/poll?token=${TOKEN}&since=0`)).text);
    const names = (r.events ?? []).map((e) =>
      e.ev === 'tool' ? `${e.data?.name}:${e.data?.kind ?? ''}` : e.ev);
    const atQueued = names.findIndex((n) => n.startsWith('queued:'));
    const atStarted = names.findIndex((n) => n.startsWith('started:'));
    const atFinished = names.findIndex((n) =>
      n === 'finished:cancelled');
    assert.ok(atQueued >= 0, 'the backgrounding notice rode the flush');
    assert.ok(atQueued < atFinished,
      'the cancelled receipt lands AFTER the backgrounding it answers ' +
      `— ring order: ${names.join(' ')}`);
    assert.ok(atStarted === -1 || atStarted < atFinished,
      'and after the pickup marker when one rides');
    const fin = (r.events ?? [])[atFinished]?.data ?? {};
    assert.equal(fin.detail, 'Bash sleep 10',
      'and it still names the step the banner showed');
    a.kill();
    b.kill();
  } finally {
    await stopBridge(proc);
  }
});

// The phone's pump died mid-handoff (the +104 flip: Android cut the SSE
// stream while the prompt sat queued). Its recovery is a drain /attach —
// and the ONLY thing that retires a fossilised 'queued' pin there is the
// pickup marker riding the backlog replay. beginTurn wipes the backlog
// the moment the flushed turn opens, which used to eat the marker it had
// just relayed: the drain came back complete, the answer got voiced, and
// the pin stayed on screen forever (the bash-sleep field report's twin).
const PORT7 = PORT1 + 6;
test('the pickup marker survives the flush’s backlog wipe — /attach ' +
    'replays it (drain path retires the pin)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT7);
  try {
    await up(PORT7);
    const a = await call(PORT7, `/talk?token=${TOKEN}`,
      { body: 'first turn', method: 'POST' });
    await until('turn A open', async () => (await health(PORT7)).turnOpen === true);

    // A POLL-transport queue press: parked, notice on the ring, socket
    // closed at enqueue exactly like the phone does it.
    await call(PORT7, `/talk?token=${TOKEN}&interrupt=0&poll=1`,
      { body: 'polled queue', method: 'POST' });
    await until('queue flushed', async () => (await health(PORT7)).queued === false);

    // Now the drained phone arrives: /attach replays the unheard backlog,
    // and the started marker must ride that replay (ring or nothing —
    // /attach does not read the ring).
    const at = await call(PORT7, `/attach?token=${TOKEN}`);
    await until('marker in the replay', async () =>
      at.text.includes('"name":"started"'));
    assert.ok(at.text.includes('"detail":"polled queue"'),
      'the replayed marker must name the prompt it picked up');
    await until('B reaching the harness', async () =>
      seen(stubLog).includes('polled queue'));
    a.kill();
    at.kill();
  } finally {
    await stopBridge(proc);
  }
});
// The lifecycle receipt (0.1.0+128): a turn that ends with NO ear on it
// — backgrounded by a press, a hide, or a dead socket — closes with a
// structured 'finished' frame ahead of its done, so whatever view next
// listens reads WHEN the out-of-earshot work actually ended. A heard
// turn gets no marker (its own done is the receipt).
test('a backgrounded turn ends with a finished receipt before its done',
  async () => {
    const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
    const proc = startBridge(stubLog, PORT7);
    try {
      await up(PORT7);
      const a = await call(PORT7, `/talk?token=${TOKEN}`,
        { body: 'long working turn', method: 'POST' });
      await until('turn open', async () => (await health(PORT7)).turnOpen === true);

      // The phone hangs up mid-turn: the turn runs BACKGROUND. Its
      // result (stub clock: 1.5 s) fires with nobody listening — exactly
      // the shape the receipt exists for.
      a.kill();
      await until('backgrounded turn settled', async () => {
        const h = await health(PORT7);
        return h.turnOpen === false && h.backgrounded === false;
      });

      // The replay tells the whole story, in order: work…, finished, done.
      const replayed = await call(PORT7, `/attach?token=${TOKEN}`);
      await until('backlog drained', async () => {
        try { return (await health(PORT7)).missed === 0; } catch { return false; }
      });
      await sleep(150); // let the replay bytes land in the collector
      const at = (needle) => replayed.text.indexOf(needle);
      assert.ok(at('"name":"finished"') >= 0,
        'no finished receipt on the replay — the badge question stays ' +
        'unanswerable from the wire');
      assert.ok(at('"name":"finished"') < at('event: done'),
        'the receipt must precede the done (replay order: work, finished, done)');
      assert.ok(replayed.text.includes('ended after'),
        'the receipt should say how long the work ran');
    } finally {
      await stopBridge(proc);
    }
  });

test('a heard turn closes with its done alone — no finished marker',
  async () => {
    const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
    const proc = startBridge(stubLog, PORT7 + 1);
    try {
      await up(PORT7 + 1);
      const a = await call(PORT7 + 1, `/talk?token=${TOKEN}`,
        { body: 'short heard turn', method: 'POST' });
      await until('turn done', async () => a.text.includes('event: done'));
      assert.ok(!a.text.includes('"name":"finished"'),
        'a heard turn must not carry a finished marker — its done is the ' +
        'receipt, and a marker would let a replay retire a badge about ' +
        'work that never left the ear');
    } finally {
      await stopBridge(proc);
    }
  });

// +133 (probe-verified against the real CLI 2.1.286): the AGENT may
// background a shell itself — Bash run_in_background. The tool closes
// instantly with a start receipt, the turn answers, and when the shell
// finishes the CLI speaks UNPROMPTED: a report turn with no /talk
// behind it. The bridge must (1) announce the debt while the shell
// runs — /health counts it in `detached`, the banner's proof of life;
// (2) open the report as a background turn, so a fresh /talk queues
// politely behind the agent's own news; (3) relay the named `tool
// finished` receipt at the moment the report reads the task output;
// (4) deliver the model's answer as ordinary `say` frames.
test('the harness backgrounding its own shell reports in unprompted (+133)',
  async () => {
    const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')),
      'stub.log');
    const proc = startBridge(stubLog, PORT8, {
      STUB_TOOL: 'sleep 10', STUB_TOOL_START_MS: '100',
      STUB_TOOL_BG: '1', STUB_BG_DONE_MS: '1300', STUB_RESULT_MS: '400',
      STUB_SAYS: 'started',
    });
    try {
      await up(PORT8);
      await call(PORT8, `/talk?token=${TOKEN}&poll=1`,
        { body: 'run bash sleep', method: 'POST' });
      // The poll transport closes its /talk response early: the launch
      // frames are read where they actually ride — the ring.
      await until('launch receipt frames on the ring', async () => {
        const ring = JSON.parse(
          (await call(PORT8, `/poll?token=${TOKEN}&since=0`)).text);
        return ring.events.some((e) => e.data?.name === 'backgrounded' &&
          e.data?.detail === 'Bash sleep 10') &&
          ring.events.some((e) => e.data?.name === 'Bash');
      });
      await until('launch turn closed', async () =>
        (await health(PORT8)).turnOpen === false);

      // The debt window: the turn is over, the SHELL is not. /health
      // owes the phone proof the work is alive. (Read once — the debt
      // lands with the launch receipt's bookkeeping and holds through
      // the report.)
      let owed = false;
      for (let i = 0; i < 10 && !owed; i++) {
        owed = (await health(PORT8)).detached >= 1;
        if (!owed) await sleep(100);
      }
      assert.ok(owed, 'the agent task is never counted in detached');

      // The report turn opens on its own, and a polite prompt landing
      // in it must QUEUE (the agent is mid-sentence about its news).
      await until('report turn opens unprompted', async () =>
        (await health(PORT8)).turnOpen === true);
      const b = await call(PORT8, `/talk?token=${TOKEN}&poll=1&interrupt=0`,
        { body: 'queued behind the report', method: 'POST' });
      await until('queue notice', async () =>
        b.text.includes('"name":"queued"'));
      assert.ok(!seen(stubLog).includes('queued behind the report'),
        'the queue jumped the agent\'s own report turn');

      // The ring tells the whole story in order: the named receipt
      // lands inside the report turn, the model's ANSWER rides as
      // ordinary say frames, and the queue's pickup marker comes last
      // (the report held the floor while its news was spoken).
      let ring = [];
      await until('the full report story on the ring', async () => {
        ring = (JSON.parse(
          (await call(PORT8, `/poll?token=${TOKEN}&since=0`)).text))
          .events;
        const evs = ring.map((e) => JSON.stringify(e.data ?? {}));
        const fin = evs.findIndex((d) =>
          d.includes('"name":"finished"') && d.includes('Bash sleep 10'));
        const said = evs.findIndex((d) => d.includes('BGOUT-hello'));
        const pick = evs.findIndex((d) =>
          d.includes('"name":"started"') &&
          d.includes('queued behind the report'));
        return fin >= 0 && said > fin && pick > said;
      });

      await until('all settled', async () => {
        const h = await health(PORT8);
        return h.turnOpen === false && h.queued === false &&
          h.detached === 0;
      });
      await until('the queue was delivered', async () =>
        seen(stubLog).includes('queued behind the report'));
    } finally {
      await stopBridge(proc);
    }
  });

// +155: the poll transport's replay ledger needs a boundary to stop at:
// past ITS OWN started marker, every say is the answer — news, never a
// dedup candidate. An idle bridge used to start the turn without ever
// announcing it, and a live reply reusing a paragraph from minutes ago
// was swallowed whole (field: 'Rendering audio' with a silent chat).
test('an idle bridge announces the pickup of the turn it starts now (+155)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT9);
  try {
    await up(PORT9);
    await call(PORT9, `/talk?token=${TOKEN}&poll=1`,
      { body: 'sleep again please', method: 'POST' });
    await until('started marker on the ring', async () => {
      const ring = JSON.parse((await call(PORT9, `/poll?token=${TOKEN}&since=0`)).text);
      return ring.events.some((e) =>
        e.ev === 'tool' && e.data?.name === 'started'
        && e.data?.detail === 'sleep again please');
    });
    const ring = JSON.parse((await call(PORT9, `/poll?token=${TOKEN}&since=0`)).text);
    const first = ring.events.findIndex((e) => e.data?.name === 'started');
    assert.equal(first, 0,
      'the marker is the turn\u2019s FIRST frame — the ledger boundary '
      + 'must precede anything it could wrongly silence');
    await until('the turn reached the harness', async () =>
      seen(stubLog).includes('sleep again please'));
  } finally {
    await stopBridge(proc);
  }
});
