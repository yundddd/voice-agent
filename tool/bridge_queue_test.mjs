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
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
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
// +159: the debt-payment and transients-not-memory ports.
const PORT11 = PORT1 + 30;
const PORT12 = PORT1 + 31;
// +182: the sibling-not-murdered port.
const PORT18 = PORT1 + 32;

function startBridge(stubLog, port, extraEnv = {}, extraArgs = []) {
  const dir = mkdtempSync(join(tmpdir(), 'bridge-qtest-'));
  const proc = spawn(
    process.execPath,
    // extraArgs FIRST: arg() reads the first occurrence of a flag, so a
    // test's own --dir/--dir-root override the scratch defaults.
    [join(HERE, 'claude_bridge.mjs'), ...extraArgs, '--token', TOKEN,
      '--port', String(port), '--claude', join(HERE, 'bridge_stub_claude.mjs'),
      '--dir', dir],
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

// Parse an SSE body into {ev, data} frames (padding comments ignored).
function sseEvents(text) {
  const out = [];
  for (const frame of text.split('\n\n')) {
    let ev = null, data = null;
    for (const line of frame.split('\n')) {
      if (line.startsWith('event: ')) ev = line.slice(7).trim();
      else if (line.startsWith('data: ')) {
        try { data = JSON.parse(line.slice(6)); } catch {}
      }
    }
    if (ev) out.push({ev, data});
  }
  return out;
}
// v2: /attach replay does NOT consume the backlog — the phone's ack
// does. Ack every _mid in an SSE body (what a real phone does as it
// TAKES each frame).
async function ackAll(port, sseBody) {
  const mids = sseEvents(sseBody).map((e) => e.data?._mid)
    .filter(Number.isFinite);
  const r = await call(port, `/heard?token=${TOKEN}`,
    {body: JSON.stringify({mids}), method: 'POST'});
  return {mids, res: r};
}

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
      await sleep(150); // let the replay bytes land in the collector
      const counts = (needle) =>
        replayed.text.split(needle).length - 1;
      assert.equal(counts('Heard once.'), 1,
        'the live-delivered copy was eaten or stacked (+112/+113 failure modes)');
      assert.equal(counts('Never twice.'), 1);
      // v2: the replay CONSUMES nothing — the backlog shrinks only
      // under acks. Every replayed frame carries an id; acking the
      // says trims exactly them.
      const frames = sseEvents(replayed.text);
      assert.ok(frames.every((f) => Number.isFinite(f.data?._mid)),
        'every relayed frame carries _mid');
      const once = frames.filter((f) => f.data?.text === 'Heard once.');
      assert.equal(once.length, 1);
      const before = (await health(PORT4)).missed;
      await call(PORT4, `/heard?token=${TOKEN}`, {method: 'POST',
        body: JSON.stringify({mids: [once[0].data._mid]})});
      const after = (await health(PORT4)).missed;
      assert.equal(after, before - 1,
        '/heard trimmed exactly the acked copy');
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
      await sleep(150); // let the replay bytes land in the collector
      // v2: the replay is a look, not a meal — missed only drops under
      // /heard. Ack the whole replay; the backlog must empty exactly.
      assert.ok((await health(PORT7)).missed > 0,
        '/attach consumed the backlog again — only /heard may trim it');
      await ackAll(PORT7, replayed.text);
      await until('backlog drained', async () =>
        (await health(PORT7)).missed === 0);
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
      // v2: the polled receipt NAMES the reserved turn; the notice
      // itself rides the ring (where the pull transport reads all of
      // its frames anyway).
      await until('queue receipt', async () => {
        try { return JSON.parse(b.text).turn > 0; } catch { return false; }
      });
      await until('queue notice on the ring', async () => {
        const r = JSON.parse((await call(PORT8,
          `/poll?token=${TOKEN}&since=0`)).text);
        return r.events.some((e) =>
          e.data?.name === 'queued');
      });
      assert.ok(!seen(stubLog).includes('queued behind the report'),
        'the queue jumped the agent\'s own report turn');
      const bReceipt = JSON.parse(b.text);

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

// wire v2, end to end: a polled POST answers with a JSON receipt naming
// the turn RESERVED for it — before the queue even flushes. The queue
// notice on the ring, the flush's started marker, and the answer's say
// all carry that id; the turn the prompt parked behind closes with a
// done stamped with its OWN (different) id. A reattach replays the
// unheard and consumes nothing; /heard trims by _mid; the second
// replay is silent. The phone never guesses from text, order or age.
const PORT10 = PORT1 + 20;
test('wire v2: reserved turn ids, done carries its owner, /heard trims',
  async () => {
    const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')),
      'stub.log');
    const proc = startBridge(stubLog, PORT10, {STUB_SAYS: 'The answer.'});
    try {
      await up(PORT10);
      assert.equal((await health(PORT10)).proto, 2,
        'the health page names the protocol');
      // Turn A, heard and slow (1.5 s): the farewell we must not confuse.
      const a = await call(PORT10, `/talk?token=${TOKEN}`,
        {body: 'hold the floor', method: 'POST'});
      await until('turn A open', async () =>
        (await health(PORT10)).turnOpen === true);
      const tA = (await health(PORT10)).turn;

      // Polled queue press: the receipt names the turn B will own.
      const b = await call(PORT10, `/talk?token=${TOKEN}&poll=1`,
        {body: 'my answer please', method: 'POST'});
      await sleep(120);
      const receipt = JSON.parse(b.text);
      assert.equal(receipt.ok, true);
      assert.ok(Number.isFinite(receipt.turn),
        'a polled POST answers {ok,turn} — no SSE to discard');
      assert.ok(receipt.turn > tA,
        'the id is RESERVED (the running turn wears its own, older one)');

      await until('flushed', async () =>
        (await health(PORT10)).queued === false);
      await until('answer on the ring', async () => {
        const r = JSON.parse((await call(PORT10,
          `/poll?token=${TOKEN}&since=0`)).text);
        return r.events.some((e) => e.ev === 'say' &&
          e.data?.text === 'The answer.');
      });
      const r = JSON.parse((await call(PORT10,
        `/poll?token=${TOKEN}&since=0`)).text);
      const evs = r.events;
      const note = evs.find((e) => e.data?.name === 'queued');
      const marker = evs.find((e) => e.data?.name === 'started' &&
        e.data?.detail === 'my answer please');
      const say = evs.find((e) => e.ev === 'say');
      assert.ok(note && marker && say, 'story frames missing');
      assert.equal(note.data._turn, receipt.turn,
        'the queue notice belongs to the reserved turn');
      assert.equal(marker.data._turn, receipt.turn,
        'the pickup marker belongs to the reserved turn');
      assert.equal(say.data._turn, receipt.turn,
        'the answer belongs to the turn the receipt promised');
      // The +106 cut leaked A's farewell, so the ring's dones are
      // either the flush turn's own (correctly stamped) or a heard
      // A-shaped farewell — never an anonymous one. The phone's pump
      // tells farewells apart by this field, never by order.
      const dones = evs.filter((e) => e.ev === 'done');
      assert.ok(dones.length >= 1 && dones.every((e) =>
        e.data?._turn === receipt.turn || e.data?._turn === tA),
        'every done names the turn it closes');
      assert.ok(Number.isFinite(note.data._mid) &&
        Number.isFinite(marker.data._mid) &&
        Number.isFinite(say.data._mid));
      assert.ok(marker.data._mid > note.data._mid &&
        say.data._mid > marker.data._mid, 'ids march forward');

      // The drain: replay everything unheard, and prove the replay
      // consumed nothing…
      const at = await call(PORT10, `/attach?token=${TOKEN}`);
      await sleep(200);
      const replay = sseEvents(at.text);
      const replayedSay = replay.find((e) => e.ev === 'say');
      assert.ok(replayedSay, 'the unheard answer did not ride /attach');
      assert.equal(replayedSay.data._mid, say.data._mid,
        'the replayed copy carries the SAME id — one message, one id');
      assert.ok((await health(PORT10)).missed > 0,
        '/attach consumed the backlog again — only /heard may trim it');
      // …then acking the answer trims it and the next replay is silent.
      await call(PORT10, `/heard?token=${TOKEN}`, {method: 'POST',
        body: JSON.stringify({mids: [say.data._mid]})});
      const at2 = await call(PORT10, `/attach?token=${TOKEN}`);
      await sleep(200);
      assert.ok(!sseEvents(at2.text).some((e) => e.ev === 'say' &&
        e.data?.text === 'The answer.'),
        'an acked message is never replayed again');
      a.kill();
      at.kill();
      at2.kill();
    } finally {
      await stopBridge(proc);
    }
  });

// +159 field report: three shells launched run_in_background and
// finished; the harness NOTIFIED — but the notification landed between
// turns, so the proactive-close net never ran and the Read-the-output
// scan never fired either (the model answered straight from the
// notification text). The bridge kept naming the dead shells
// `detached`, and the phone's background banner has exactly one
// dismissal proof — /health saying NOTHING detached. The banner could
// never retire, and the missed backlog below it kept the 10 s
// reattach heartbeat flashing the thinking box forever. The
// notification message itself now pays the debt.
test('a background task notification pays the agent’s background debt ' +
    'with no proactive turn in sight (+159)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT11, {
    STUB_TOOL: 'sleep 60', STUB_TOOL_BG: '1',
    STUB_TOOL_START_MS: '100', STUB_BG_NOTIFY_MS: '500',
    STUB_SAYS: 'Launched.', STUB_RESULT_MS: '300',
  });
  try {
    await up(PORT11);
    const a = await call(PORT11, `/talk?token=${TOKEN}`,
      { body: 'launch it', method: 'POST' });
    await until('launch turn closes', async () =>
      (await health(PORT11)).turnOpen === false);
    // The shell is a tracked, OWED debt — and decisively not paid by
    // its own launch receipt, the user message naming the same id and
    // output path (a task must not pay itself at birth).
    assert.equal((await health(PORT11)).detached, 1,
      'the launched shell is not owed / paid by its launch receipt');
    // The completion notification lands BETWEEN turns: no listener,
    // no open turn, no proactive report anywhere.
    await until('the notification pays the debt', async () =>
      (await health(PORT11)).detached === 0, 4000);
    // The receipt is real backlog now: the next drain picks it up,
    // and acking it empties the unheard queue (the stuck-counter
    // symptom dies at the root).
    const at = await call(PORT11, `/attach?token=${TOKEN}`);
    await sleep(150);
    const replay = sseEvents(at.text);
    const fin = replay.find((e) => e.ev === 'tool' &&
      e.data?.name === 'finished');
    assert.ok(fin && fin.data.detail.includes('sleep 60'),
      'the finished receipt did not ride the drain');
    const { mids } = await ackAll(PORT11, at.text);
    assert.ok(mids.includes(fin.data._mid), 'the receipt carries an id');
    await until('backlog drained', async () =>
      (await health(PORT11)).missed === 0);
    a.kill();
    at.kill();
  } finally {
    await stopBridge(proc);
  }
});

// The tape (15:51:06): two shells owed, the ten-second one's report
// came in, and the drain at result paid BOTH — the sixty had 24 seconds
// still to sleep and its banner went dark fifteen seconds early,
// silently. The field report this walk pins: "the 60 second banner did
// not show up" — gone by a false proof of nothing-open, not by a death.
test('two shells owed; one report pays only its own (+182)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT18, {
    STUB_TOOL: 'sleep 10', STUB_TOOL_BG: '1', STUB_TOOL2_BG: 'sleep 60',
    STUB_TOOL_START_MS: '100', STUB_RESULT_MS: '300', STUB_SAYS: 'Launched.',
    // The production notification shape, its own report turn behind it,
    // and the SIBLING's notification landing later, between turns.
    STUB_BG_NOTIFY_MS: '500', STUB_BG_NOTIFY_SYSTEM: '1',
    STUB_BG_NOTIFY_REPORT: '1', STUB_BG_SAYS: 'The short one finished.',
    STUB_BG_NOTIFY2_MS: '1400',
  });
  try {
    await up(PORT18);
    const a = await call(PORT18, `/talk?token=${TOKEN}`,
      { body: 'launch both', method: 'POST' });
    await until('launch turn closes', async () =>
      (await health(PORT18)).turnOpen === false);
    assert.equal((await health(PORT18)).detached, 2,
      'both shells are owed at launch');
    // The short one completes: a system/task_notification naming only
    // it, then a report turn answering straight from the notification
    // (no Read, no path in the text). The notification scan pays the
    // named task; the report's close must NOT reach the sleeping
    // sibling — the old drain-at-report did, and that is the murder.
    await until('the notification pays its own task', async () =>
      (await health(PORT18)).detached === 1, 4000);
    await until('the report turn closes', async () =>
      (await health(PORT18)).turnOpen === false, 4000);
    assert.equal((await health(PORT18)).detached, 1,
      'the still-sleeping sibling survives its neighbour’s farewell');
    // The sibling reports in later, between turns: its own
    // notification pays its own debt.
    await until('the second notification pays the sibling', async () =>
      (await health(PORT18)).detached === 0, 5000);
    const at = await call(PORT18, `/attach?token=${TOKEN}`);
    await sleep(200);
    // The +128 turn-lifecycle farewell (detail 'ended after …') also
    // rides a finished frame; this walk counts the SHELL receipts.
    const fins = sseEvents(at.text).filter((e) => e.ev === 'tool' &&
      e.data?.name === 'finished' &&
      !String(e.data?.detail).includes('ended after'));
    assert.equal(fins.length, 2, 'one receipt per shell, never shared');
    assert.ok(fins[0].data.detail.includes('sleep 10'),
      'the reported task paid first');
    assert.ok(fins[1].data.detail.includes('sleep 60'),
      'the sibling paid by its own notification, not the report');
    // +186: every receipt carries the TASK's own stamp — the phone
    // dedups on identity; identical labels can never collide again.
    assert.equal(fins[0].data.id, 'tbg1',
      'the finished frame is stamped with its task id');
    assert.equal(fins[1].data.id, 'tbg1b',
      'the sibling receipt carries the sibling’s id');
    a.kill();
    at.kill();
  } finally {
    await stopBridge(proc);
  }
});

// +159, the same loop's other half: relay()'s head comment always
// promised transient frames (the token tally, the ctx preview) stay
// live-only — “a reattaching phone re-derives them” — yet an UNHEARD
// turn pushed them into the backlog all the same. Counters are noise,
// not memory: against BACKLOG_CAP a long silent turn's tallies EVICT
// the frames a drain exists to deliver, and every survivor inflated
// `missed` forever (field: stuck at 197), holding the banner's
// dismissal proof hostage. The backlog now holds only what cannot be
// re-derived: markers, steps, says, receipts, the farewell.
test('an unheard turn backs up memory, never counters (+159)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT12,
    { STUB_TOOL: 'cargo build', STUB_TOOL_START_MS: '50',
      STUB_RESULT_MS: '2000' },
    ['--tok-heartbeat', '200']);
  try {
    await up(PORT12);
    const a = await call(PORT12, `/talk?token=${TOKEN}`,
      { body: 'build it', method: 'POST' });
    await until('tool step lands', async () =>
      a.text.includes('"name":"Bash"'));
    a.kill(); // the phone hangs up mid-turn: everything after is out of earshot
    await until('the unheard turn closes', async () =>
      (await health(PORT12)).turnOpen === false);
    // The drain owes exactly three frames: the pickup marker, the
    // +128 lifecycle receipt (the farewell of a turn that closed out
    // of earshot), and the done. No ctx preview (the result's last
    // word is visible on the next /health glance), no tally
    // (re-derived from the ring). The Bash step rode the LIVE view
    // before the hang-up, and delivered non-say frames archive
    // nothing — it is not owed a replay.
    const h = await health(PORT12);
    assert.equal(h.missed, 3,
      `only the memory frames survive unheard, got ${h.missed}`);
    const at = await call(PORT12, `/attach?token=${TOKEN}`);
    await sleep(150);
    const replay = sseEvents(at.text);
    assert.ok(!replay.some((e) => e.ev === 'context'),
      'a context preview rode the backlog');
    assert.ok(!replay.some((e) => e.ev === 'tool' &&
      e.data?.name === 'tokens'), 'a token tally rode the backlog');
    assert.ok(replay.some((e) => e.ev === 'tool' &&
      e.data?.name === 'started'), 'the pickup marker survived');
    assert.ok(replay.some((e) => e.ev === 'tool' &&
      e.data?.name === 'finished'),
      'the unheard-turn lifecycle receipt — the frame the banner ' +
      'dismissal listens for — survived');
    await ackAll(PORT12, at.text);
    await until('backlog drained by ack', async () =>
      (await health(PORT12)).missed === 0);
    at.kill();
  } finally {
    await stopBridge(proc);
  }
});

// ── the working-folder picker: POST /dir + GET /dirs ──────────────────────
// The phone's Bridge screen moves the agent between projects. The laws
// under test: /dirs offers only real folders inside --dir-root (never
// dot-folders, node_modules or build); /dir refuses anything outside the
// root (or a file) with an honest reason; a move is an honest /new AT
// the destination — the child dies and the next utterance respawns it
// INSIDE the picked folder (cwd.log is the proof the agent cannot fake).
const PORT13 = PORT1 + 40;

test('GET /dirs lists only folders inside --dir-root, /dir moves the agent there',
  async () => {
  const root = mkdtempSync(join(tmpdir(), 'bridge-dirs-'));
  for (const d of ['alpha', 'beta', 'beta/sub', 'node_modules', 'build', '.venv'])
    mkdirSync(join(root, d), { recursive: true });
  writeFileSync(join(root, 'file.txt'), 'x'); // not a folder: never offered
  const stubLog = join(root, 'stub.log');
  const cwdLog = join(root, 'cwd.log');
  const proc = startBridge(stubLog, PORT13, { STUB_CWD_LOG: cwdLog },
    ['--dir', join(root, 'alpha'), '--dir-root', root]);
  try {
    await up(PORT13);
    assert.equal((await health(PORT13)).dir, resolve(join(root, 'alpha')));

    const list = JSON.parse((await call(PORT13, `/dirs?token=${TOKEN}`)).text);
    assert.deepEqual(list.dirs.map((d) => d.name), ['alpha', 'beta']);
    assert.equal(list.parent, null); // the root has nothing above it

    // A sublevel names its parent for the up-arrow, and paths ride the
    // listing's own root-relative form.
    const sub = JSON.parse(
      (await call(PORT13, `/dirs?token=${TOKEN}&in=beta`)).text);
    assert.deepEqual(sub.dirs.map((d) => d.path), ['beta/sub']);
    assert.equal(sub.parent, '', 'one under root: the up-arrow goes to the root');
    const deep = JSON.parse(
      (await call(PORT13, `/dirs?token=${TOKEN}&in=beta/sub`)).text);
    assert.equal(deep.parent, 'beta');
    assert.deepEqual(deep.dirs, []);

    // Refusals: outside the root, and not a folder. (call() resolves on
    // headers, so the 400's reason arrives as the body text.)
    const out = await call(PORT13, `/dir?token=${TOKEN}`,
      { body: JSON.stringify({ path: resolve(dirname(root), 'elsewhere') }),
        method: 'POST' });
    assert.ok(out.text.startsWith('not a folder'), '/dir accepted an escape');
    const file = await call(PORT13, `/dir?token=${TOKEN}`,
      { body: JSON.stringify({ path: 'file.txt' }), method: 'POST' });
    assert.ok(file.text.startsWith('not a folder'), '/dir accepted a file');
    assert.equal((await health(PORT13)).dir, resolve(join(root, 'alpha')),
      'a refused move still moved the agent');

    // The move: an honest thread switch to beta — child dead, dir
    // changed, and the next utterance spawns INSIDE beta (cwd.log
    // line 2). The answer names the destination's remembered thread
    // (+223): beta was never visited, so its pointer is blank and
    // the conversation starts fresh on the next word.
    const mv = await call(PORT13, `/dir?token=${TOKEN}`,
      { body: JSON.stringify({ path: 'beta' }), method: 'POST' });
    assert.deepEqual(JSON.parse(mv.text),
      { ok: true, dir: resolve(join(root, 'beta')), sessionId: null });
    await until('the move lands in health', async () => {
      const h = await health(PORT13);
      return h.dir === resolve(join(root, 'beta')) && h.claudeUp === false;
    });
    await call(PORT13, `/talk?token=${TOKEN}`,
      { body: 'where are we', method: 'POST' });
    await until('respawn inside beta', async () => {
      try {
        return readFileSync(cwdLog, 'utf8').trim().split('\n').at(-1) ===
          resolve(join(root, 'beta'));
      } catch { return false; }
    });
    assert.ok(seen(stubLog).includes('where are we'));
  } finally {
    await stopBridge(proc);
  }
});

// ── +163 THE FOLD ──────────────────────────────────────────────────────
// The plain release no longer waits for the whole turn: the parked
// prompt is handed to the RUNNING turn at the first tool_result
// boundary after it parks (probe on the real CLI 2.1.296: stdin user
// messages fold into the live conversation at the next API call). It
// gets a 'started kind:steered' pickup marker carrying its RESERVED
// turn id, takes the stream seat from the old view, and the host's
// done is re-stamped to its id. A turn with no boundary left (or a
// park after the last one) still falls through to the result-time
// flush — delivery is never later than the old law.
const PORT15 = PORT1 + 40;
const PORT16 = PORT1 + 41;
const FOLD_ENV = {
  // A multi-step turn: foreground tool 1 opens at 50 ms and survives
  // to the result (open while the prompt parks → the notice says so);
  // tool 2 opens and CLOSES at 1330 ms — the boundary the fold rides;
  // the turn itself settles at 4000 ms.
  STUB_TOOL: 'sleep 60', STUB_TOOL_START_MS: '50',
  STUB_TOOL2_MS: '1200', STUB_RESULT_MS: '4000', STUB_SAYS: 'Answered.',
};

test('a politely parked prompt folds into the running turn at the next ' +
    'tool result (+163)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT15, FOLD_ENV);
  try {
    await up(PORT15);
    const a = await call(PORT15, `/talk?token=${TOKEN}`,
      { body: 'the first ask', method: 'POST' });
    await until('host turn open', async () =>
      (await health(PORT15)).turnOpen === true);
    await until('tool 1 is open', async () =>
      a.text.includes('"name":"Bash"')); // parked while a tool runs

    // Park politely WHILE the first tool is open, before tool 2 gives
    // the turn its first boundary.
    const b = await call(PORT15, `/talk?token=${TOKEN}&interrupt=0`,
      { body: 'the steer', method: 'POST' });
    await until('b queued notice', async () =>
      b.text.includes('"name":"queued"'));
    assert.ok(b.text.includes('steer the turn'),
      'the notice words the NEW promise (steer at the next pause)');
    const tB = Number(b.text.match(/"turn":(\d+),"queued":true/)?.[1]);
    assert.ok(Number.isFinite(tB), 'the receipt names the parked turn');
    // The fold happens MID-TURN: the queue drains while the host is
    // still open — the old law could only empty `queued` at `result`.
    await until('fold at the tool boundary', async () => {
      const h = await health(PORT15);
      return h.queued === false && h.turnOpen === true;
    }, 4000);

    // The marker: its own id, the steered kind, an id of its own.
    await until('the steered pickup rides the parked stream', async () =>
      b.text.includes('"kind":"steered"'));
    const frames = sseEvents(b.text);
    const marker = frames.find((e) => e.ev === 'tool' &&
      e.data?.name === 'started');
    assert.equal(marker.data._turn, tB,
      'the pickup marker carries the RESERVED id — the phone names its own turn');

    // The host turn closes: the continuation is spoken to the STEERER
    // (b), and the farewell re-stamped to b's id. (The stub treats the
    // folded stdin line as ITS new turn — its gen-guard delays the
    // result one full cycle; the bridge never learned: its turn stays
    // open until that result lands. The contract assertions below are
    // the same either way.)
    await until('host turn closes', async () =>
      (await health(PORT15)).turnOpen === false, 15000);
    const closed = sseEvents(b.text);
    const done = closed.find((e) => e.ev === 'done');
    assert.ok(done, 'the parked stream got its farewell');
    assert.equal(done.data._turn, tB,
      'the done re-stamp closes the steered turn — the pump ends clean');
    assert.ok(closed.some((e) => e.ev === 'say' &&
      e.data?.text === 'Answered.'),
      'the host turn\u2019s continuation speaks to the phone that steered it');
    assert.ok(seen(stubLog).includes('the steer'),
      'the prompt reached the harness stdin');
    assert.ok(!sseEvents(a.text).some((e) => e.ev === 'done'),
      'the superseded first view never gets a funeral done — it made room');
  } finally {
    await stopBridge(proc);
  }
});

// +171: /compact arrives WITHOUT a seat — the field deadlock where an
// agent's own curl holding both the tool boundary and the parked
// stream could never fold. The notice answers and the caller's stream
// CLOSES; the fold then rides the caller's own tool_result, the
// current view keeps the seat (the host turn is still its stream),
// and the re-stamped done closes the pump of whoever asked.
const PORT17 = PORT1 + 42;

test('a queued /compact folds without ever holding a stream (+171)',
  async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT17, FOLD_ENV);
  try {
    await up(PORT17);
    const a = await call(PORT17, `/talk?token=${TOKEN}`,
      { body: 'the host ask', method: 'POST' });
    await until('host turn open', async () =>
      (await health(PORT17)).turnOpen === true);
    await until('tool 1 is open', async () =>
      a.text.includes('"name":"Bash"'));

    // The agent routes /compact through its own wire. The response
    // must END at the notice — while the host turn churns (its
    // boundary at 1200 ms, its result at 4000 ms — 1000 ms here can
    // only mean 'closed at the notice').
    const bT0 = Date.now();
    const b = await new Promise((resolve, reject) => {
      const rq = http.request(
        `http://127.0.0.1:${PORT17}/talk?token=${TOKEN}&interrupt=0`,
        { method: 'POST' }, (rs) => {
        let t = '';
        rs.setEncoding('utf8');
        rs.on('data', (c) => { t += c; });
        rs.on('end', () => resolve({ ms: Date.now() - bT0, text: t }));
      });
      rq.on('error', reject);
      rq.write('/compact');
      rq.end();
    });
    assert.ok(b.ms < 1000,
      `the seatless caller is released at its notice (${b.ms} ms) — ` +
      'curl returns, so its tool_result CAN be the boundary');
    assert.ok(b.text.includes('"name":"queued"'), 'the notice is the answer');
    assert.ok(!b.text.includes('event: done'),
      'the caller never waits for the turn its own housekeeping folded into');
    const tB = Number(b.text.match(/"turn":(\d+),"queued":true/)?.[1]);
    assert.ok(Number.isFinite(tB), 'the receipt names the parked turn');

    // The boundary arrives (tool 2 closes): the fold fires, the
    // marker rides, and it rides to the CURRENT listener — the seat
    // never moved.
    await until('fold at the tool boundary, seat unmoved', async () =>
      a.text.includes('"kind":"steered"'), 4000);
    const frames = sseEvents(a.text);
    const marker = frames.find((e) => e.ev === 'tool' &&
      e.data?.name === 'started' && e.data?.kind === 'steered');
    assert.equal(marker.data._turn, tB,
      'the pickup carries the reserved /compact id');
    assert.ok(seen(stubLog).includes('/compact'),
      'the housekeeping line reached the harness stdin');

    // The host turn closes: the farewell re-stamped to tB goes to the
    // listener that kept the seat.
    await until('host turn closes', async () =>
      (await health(PORT17)).turnOpen === false, 15000);
    const done = sseEvents(a.text).find((e) => e.ev === 'done');
    assert.ok(done, 'the current view gets its funeral, not a corpse-frame');
    assert.equal(done.data._turn, tB,
      'the done re-stamp closes the steered turn clean');
  } finally {
    await stopBridge(proc);
  }
});

test('a park after the last boundary waits for the flush — the old law ' +
    'is the floor (+163)', async () => {
  const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
  const proc = startBridge(stubLog, PORT16, FOLD_ENV);
  try {
    await up(PORT16);
    await call(PORT16, `/talk?token=${TOKEN}`,
      { body: 'the first ask', method: 'POST' });
    await until('host turn open', async () =>
      (await health(PORT16)).turnOpen === true);
    // Park AFTER tool 2 closed (1330 ms) — no boundary remains before
    // the result at 4000 ms: the prompt must ride to the flush. (Tool
    // 1 is still open, so the notice still promises a steer — what it
    // learns is that the turn settles first: delivery falls through to
    // the old law, never later.)
    await sleep(1800);
    const b = await call(PORT16, `/talk?token=${TOKEN}&interrupt=0`,
      { body: 'too late to steer', method: 'POST' });
    await until('b queued notice', async () =>
      b.text.includes('"name":"queued"'));
    await sleep(600); // past where a tool-2 boundary would have folded it
    assert.equal((await health(PORT16)).queued, true,
      'a park with no boundary left is NOT retro-folded');
    await until('the turn closes and flushes it as its own', async () => {
      if ((await health(PORT16)).queued !== false) return false;
      const m = sseEvents(b.text).find((e) => e.ev === 'tool' &&
        e.data?.name === 'started');
      return !!m && m.data.kind === undefined;
    });
    const marker = sseEvents(b.text).find((e) => e.ev === 'tool' &&
      e.data?.name === 'started');
    assert.ok(marker,
      'a real turn handover, not a fold: the bare started marker');
    await until('its own done', async () =>
      sseEvents(b.text).some((e) => e.ev === 'done'));
  } finally {
    await stopBridge(proc);
  }
});

// ── bridge -> app file delivery: POST /send + GET /file ───────────────────
// The agent's file-out: /send validates against the same --dir-root
// allowlist and relays a permanent `file` frame; the phone pulls the
// bytes from /file, which honours a Range so an interrupted APK resumes.
// The frame is the delivery; the bytes are patient.
const PORT14 = PORT1 + 41;

test('POST /send relays a file frame; GET /file streams it (Range included)',
  async () => {
  const root = mkdtempSync(join(tmpdir(), 'bridge-files-'));
  const payload = 'P'.repeat(1000);
  writeFileSync(join(root, 'payload.bin'), payload);
  mkdirSync(join(root, 'sub'));
  const proc = startBridge(join(root, 'stub.log'), PORT14, {},
    ['--dir', join(root, 'sub'), '--dir-root', root]);
  try {
    await up(PORT14);

    const send = await call(PORT14, `/send?token=${TOKEN}`,
      { body: JSON.stringify({ path: 'payload.bin' }), method: 'POST' });
    assert.deepEqual(JSON.parse(send.text),
      { ok: true, name: 'payload.bin', size: 1000 });

    // The frame rode the ring (permanent, like a say): name, path, size.
    const ring = JSON.parse(
      (await call(PORT14, `/poll?token=${TOKEN}&since=0`)).text);
    const f = ring.events.find((e) => e.ev === 'file');
    assert.ok(f, 'no file frame on the ring');
    assert.equal(f.data.name, 'payload.bin');
    assert.equal(f.data.path, 'payload.bin');
    assert.equal(f.data.size, 1000);
    assert.ok(f.data._mid > 0, 'file frame lacks a _mid (ledger dedup)');

    // Full stream.
    const full = await fetch(`http://127.0.0.1:${PORT14}/file` +
      `?token=${TOKEN}&path=payload.bin`);
    assert.equal(full.status, 200);
    assert.equal(full.headers.get('accept-ranges'), 'bytes');
    assert.equal(await full.text(), payload);

    // A resume: bytes=400- pays the tail only, with a content-range.
    const part = await fetch(`http://127.0.0.1:${PORT14}/file` +
      `?token=${TOKEN}&path=payload.bin`, { headers: { range: 'bytes=400-' } });
    assert.equal(part.status, 206);
    assert.equal(part.headers.get('content-range'), 'bytes 400-999/1000');
    assert.equal((await part.text()).length, 600);

    // Past-the-end partial (the file shrank under a resume): 416 says
    // start whole — the app's downloader restarts on exactly this.
    const gone = await fetch(`http://127.0.0.1:${PORT14}/file` +
      `?token=${TOKEN}&path=payload.bin`, { headers: { range: 'bytes=5000-' } });
    assert.equal(gone.status, 416);

    // Refusals: outside the root (traversal), and a folder, both ways.
    const esc = await fetch(`http://127.0.0.1:${PORT14}/file` +
      `?token=${TOKEN}&path=..%2Fetc%2Fpasswd`);
    assert.equal(esc.status, 400);
    const dirSend = await call(PORT14, `/send?token=${TOKEN}`,
      { body: JSON.stringify({ path: 'sub' }), method: 'POST' });
    assert.ok(dirSend.text.startsWith('not a file'), '/send accepted a folder');
  } finally {
    await stopBridge(proc);
  }
});
