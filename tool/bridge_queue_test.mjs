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

// The lifecycle receipt (0.1.0+128): a turn that ends with NO ear on it
// — backgrounded by a press, a hide, or a dead socket — closes with a
// structured 'finished' frame ahead of its done, so whatever view next
// listens reads WHEN the out-of-earshot work actually ended. A heard
// turn gets no marker (its own done is the receipt).
test('a backgrounded turn ends with a finished receipt before its done',
  async () => {
    const stubLog = join(mkdtempSync(join(tmpdir(), 'bridge-qlog-')), 'stub.log');
    const proc = startBridge(stubLog, PORT5);
    try {
      await up(PORT5);
      const a = await call(PORT5, `/talk?token=${TOKEN}`,
        { body: 'long working turn', method: 'POST' });
      await until('turn open', async () => (await health(PORT5)).turnOpen === true);

      // The phone hangs up mid-turn: the turn runs BACKGROUND. Its
      // result (stub clock: 1.5 s) fires with nobody listening — exactly
      // the shape the receipt exists for.
      a.kill();
      await until('backgrounded turn settled', async () => {
        const h = await health(PORT5);
        return h.turnOpen === false && h.backgrounded === false;
      });

      // The replay tells the whole story, in order: work…, finished, done.
      const replayed = await call(PORT5, `/attach?token=${TOKEN}`);
      await until('backlog drained', async () => {
        try { return (await health(PORT5)).missed === 0; } catch { return false; }
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
    const proc = startBridge(stubLog, PORT5 + 1);
    try {
      await up(PORT5 + 1);
      const a = await call(PORT5 + 1, `/talk?token=${TOKEN}`,
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
