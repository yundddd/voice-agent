// Regression tests for the opencode harness (+211): the second backend
// the voice bridge can speak. The rig is doctrine from bridge_queue_test:
// a real bridge process on a scratch port, a stub for the harness, and
// STUB_LOG as the court of record — 'delivered' is a line on disk, never
// a frame the client happened to see. The stub here is not a CLI but a
// v2 SERVICE (bridge_stub_opencode.mjs): it enforces the request schemas
// the live 2.0.18 service enforced, so the two body-shape bugs this
// change fixes (instructions {value}, permission {decision}) fail the
// test exactly as they failed the wire — with a 400 nobody was reading.
//
// Run: node --test tool/bridge_oc_test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import http from 'node:http';

const HERE = new URL('.', import.meta.url).pathname;
const TOKEN = 'testtok';
const PORT = 19760 + (process.pid % 701);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, cond, ms = 6000) {
  const t0 = Date.now();
  for (;;) {
    if (await cond()) return;
    if (Date.now() - t0 > ms) throw new Error('timeout: ' + what);
    await sleep(25);
  }
}
// Streaming call: resolves at the headers, .text keeps accumulating —
// the queue-test shape, so a /talk that stays open (a cut turn) does
// not deadlock the witness.
function call(port, pathname, { body = null, method = 'GET' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(`http://127.0.0.1:${port}` + pathname,
      { method }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (c) => text += c);
      res.on('end', () => { c.done = true; });
      const c = {
        req,
        done: false,
        get status() { return res.statusCode; },
        get text() { return text; },
      };
      resolve(c);
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}
// A short call whose answer is the whole body (health, harness).
async function full(port, pathname, { body = null, method = 'GET' } = {}) {
  const c = await call(port, pathname, { body, method });
  await until('body end', async () => c.done, 4000);
  return { status: c.status, text: c.text };
}
const health = async (port) => JSON.parse((await full(port, '/health')).text);
// +305: the pointer lives under the bridge's HOME, keyed by hash of the
// work dir — the rig mirrors the bridge's own arithmetic, so a drift in
// either shows up as a missing file, not a passing test.
const ptrPath = (home, harnessName, dir) => join(home, '.claude-bridge', 'pointers',
  `${harnessName === 'opencode' ? 'opencode' : 'claude'}-${createHash('sha256').update(resolve(dir)).digest('hex').slice(0, 16)}`);

// A world: scratch HOME (so the persisted harness choice and the oc
// state file live in the test), scratch dir (so the per-harness pointer
// files are the test's own), the stub service booted FIRST (the bridge
// polls for its registration), then the bridge pointed at it.
async function world({ bridgeArgs = [], stubEnv = {}, homeHarness = null } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'oc-home-'));
  const dir = mkdtempSync(join(tmpdir(), 'oc-dir-'));
  const log = join(home, 'stub.log');
  const ocPort = PORT + 1 + (world.n = (world.n ?? 0) + 1) * 2;
  const stub = spawn(process.execPath,
    [join(HERE, 'bridge_stub_opencode.mjs'), '--port', String(ocPort)],
    { env: { ...process.env, HOME: home, STUB_OC_LOG: log, ...stubEnv } });
  stub.stderr.resume();
  const stFile = join(home, '.local/state/opencode/service.json');
  await until('stub service registered', async () => existsSync(stFile));
  if (homeHarness) {
    writeFileSync(join(home, '.claude_bridge_harness'), homeHarness);
  }
  const bridge = spawn(process.execPath,
    [join(HERE, 'claude_bridge.mjs'),
      '--harness', 'opencode', '--token', TOKEN,
      '--port', String(PORT + 100 + world.n), '--dir', dir,
      ...bridgeArgs],
    { env: { ...process.env, HOME: home } });
  bridge.stderr.resume();
  const port = PORT + 100 + world.n;
  await until('bridge up', async () => {
    try { return (await health(port)).ok; } catch { return false; }
  });
  return {
    home, dir, log, port, bridge, stub,
    logs: () => { try { return readFileSync(log, 'utf8'); } catch { return ''; } },
    stop() { bridge.kill(); stub.kill(); },
  };
}

test('a spoken turn rides the bus: say frames, done, and the utterance on disk', async () => {
  const w = await world({
    stubEnv: { STUB_OC_SAYS: 'One sentence here.\nAnd the second.' } });
  try {
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'hello phone' });
    await until('done', async () => a.text.includes('event: done'));
    assert.ok(a.text.includes('event: say'), 'no say frames relayed');
    assert.ok(a.text.includes('One sentence here.'), 'first sentence missing');
    assert.ok(a.text.includes('And the second.'), 'second sentence missing');
    assert.ok(w.logs().includes('prompt hello phone'),
      'the utterance never reached the service');
    // The bus dedup proved itself twice over: the flush spoke the
    // sentence once, the text.ended snapshot must NOT echo it. Counted
    // on say PAYLOAD lines only — a tally frame's `draft` field may
    // lawfully mirror the same prose for the phone's live preview, and
    // that is not a second say.
    const saidOnce = (s) => assert.equal(
      a.text.split('\n').filter(l =>
        l.startsWith(`data: {"text":"${s}"`)).length, 1,
      'sentence relayed twice (flush + snapshot): ' + s);
    saidOnce('One sentence here.');
    saidOnce('And the second.');
    // The session remembered the voice shape: the entry took, so the
    // prompt carried nothing but the user's words (a {content} body is
    // a 400 — the old bug — and its fallback would smear the system
    // prompt across this first line).
    assert.match(w.logs(), /^instructions voice You are a hands-free/m);
    // And the bridge learned its session id from the wire.
    await until('pointer written', async () =>
      existsSync(ptrPath(w.home, 'opencode', w.dir)));
    // +UUID: pointer v2 — line 1 is the --resume material, line 2 the
    // conversation's app uuid (its tab name across a restart).
    const ptr = readFileSync(ptrPath(w.home, 'opencode', w.dir), 'utf8').split('\n');
    assert.equal(ptr[0].trim(), 'soc-1');
    assert.match((ptr[1] ?? '').trim(), /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, 'pointer line 2 is the app uuid');
    assert.ok(!existsSync(ptrPath(w.home, 'claude', w.dir)),
      'the other harness\u2019s pointer was touched');
    // +305: the pointer left no dotfile behind in the project dir.
    assert.ok(!existsSync(join(w.dir, '.opencode_bridge_session')) &&
      !existsSync(join(w.dir, '.claude_bridge_session')),
      'a pointer dotfile was left in the project dir');
  } finally { w.stop(); }
});

test('a permission ask is answered with a legal decision, not swallowed', async () => {
  const w = await world({ stubEnv: { STUB_OC_PERMISSION: '1' } });
  try {
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'do the thing' });
    await until('done', async () => a.text.includes('event: done'));
    // A {response} body (the old bug) would be a 400 the bridge's
    // catch swallowed and this line would never exist — the real
    // service would have left the turn hanging on an unanswered ask.
    await until('verdict recorded', async () =>
      w.logs().includes('permission-reply always'));
  } finally { w.stop(); }
});

test('/stop cuts an open opencode turn through the service interrupt', async () => {
  const w = await world({ stubEnv: { STUB_OC_STALL: '1' } });
  try {
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'start something long' });
    await until('answer airing', async () => a.text.includes('event: say'));
    assert.equal((await health(w.port)).turnOpen, true);
    await call(w.port, `/stop?token=${TOKEN}`, { method: 'POST' });
    await until('interrupt recorded', async () =>
      w.logs().includes('interrupt'));
    await until('turn closed', async () =>
      (await health(w.port)).turnOpen === false);
  } finally { w.stop(); }
});

test('/harness flips both ways, persists, and each harness keeps its own pointer', async () => {
  const w = await world();
  try {
    assert.equal((await health(w.port)).harness, 'opencode');
    // Give the opencode side a remembered conversation first.
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'one for the road' });
    await until('done', async () => a.text.includes('event: done'));

    const r1 = await full(w.port, `/harness?token=${TOKEN}`,
      { method: 'POST', body: '{"to":"claude"}' });
    assert.equal(r1.status, 200);
    assert.equal((await health(w.port)).harness, 'claude');
    assert.equal(readFileSync(join(w.home, '.claude_bridge_harness'), 'utf8'), 'claude');

    // +214: the era TIMELINE — every flip the bridge performed (and the
    // era its boot found) is on the record, so the phone's chat
    // migration can place legacy bubbles by birth time instead of
    // guessing one label for the whole past.
    const hist = (await health(w.port)).harnessHistory;
    assert.deepEqual(hist.map((h) => h.harness), ['opencode', 'claude']);
    assert.ok(hist[1].since >= hist[0].since, 'eras are ordered');

    const r2 = await full(w.port, `/harness?token=${TOKEN}`,
      { method: 'POST', body: '{"to":"opencode"}' });
    assert.equal(r2.status, 200);
    const h = await health(w.port);
    assert.equal(h.harness, 'opencode');
    // The flip-back resumed ITS OWN conversation, untouched by the
    // detour through the other harness — and +UUID names the resumption
    // by its BACKEND property: the app uuid (sessionId) never moved.
    assert.equal(h.backendSid, 'soc-1');
    assert.match(h.sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, 'the tab keeps its birth name across harness flips');
    // …and the timeline says so, in order, with the detour named.
    assert.deepEqual((await health(w.port)).harnessHistory.map(
      (x) => x.harness), ['opencode', 'claude', 'opencode']);

    const bad = await full(w.port, `/harness?token=${TOKEN}`,
      { method: 'POST', body: '{"to":"pi"}' });
    assert.equal(bad.status, 400);
  } finally { w.stop(); }
});

test('a persisted opencode choice does not hijack an explicitly named --claude', async () => {
  // The regression the whole queue suite died on the day the harness
  // file shipped: the rig passes --claude <stub>, and the persisted
  // runtime flip dragged every test onto the live service. Naming the
  // binary IS choosing the harness.
  const home = mkdtempSync(join(tmpdir(), 'oc-home-'));
  const dir = mkdtempSync(join(tmpdir(), 'oc-dir-'));
  writeFileSync(join(home, '.claude_bridge_harness'), 'opencode');
  const stubLog = join(home, 'stub.log');
  writeFileSync(stubLog, '');
  const port = PORT + 90;
  const bridge = spawn(process.execPath,
    [join(HERE, 'claude_bridge.mjs'), '--token', TOKEN,
      '--port', String(port), '--dir', dir,
      '--claude', join(HERE, 'bridge_stub_claude.mjs')],
    { env: { ...process.env, HOME: home, STUB_LOG: stubLog,
      STUB_RESULT_MS: '200' } });
  bridge.stderr.resume();
  try {
    await until('bridge up', async () => {
      try { return (await health(port)).ok; } catch { return false; }
    });
    assert.equal((await health(port)).harness, 'claude');
    const a = await call(port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'still claude' });
    await until('done', async () => a.text.includes('event: done'));
    assert.ok(readFileSync(stubLog, 'utf8').includes('still claude'));
  } finally { bridge.kill(); }
});

// ── +216: the model picker, both dialects ─────────────────────────────
test('the opencode picker lists the service catalog and moves the session', async () => {
  const w = await world();
  try {
    const menu = JSON.parse((await full(w.port, `/models?token=${TOKEN}`)).text);
    assert.equal(menu.harness, 'opencode');
    assert.deepEqual(menu.models, [
      { id: 'acme/alpha', label: 'Acme Alpha' },
      { id: 'acme/beta', label: 'Acme Beta' },
      { id: 'other/gamma', label: 'other/gamma' }, // no name: id stands in
    ]);
    const r = await full(w.port, `/model?token=${TOKEN}`,
      { method: 'POST', body: '{"id":"acme/beta"}' });
    assert.equal(r.status, 200);
    assert.equal((await health(w.port)).model, 'acme/beta');
    // No session yet: the pick must PARK and ride the session's
    // CREATION, or the first turn would answer in the wrong voice.
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'who answers' });
    await until('done', async () => a.text.includes('event: done'));
    assert.ok(w.logs().includes('model-create acme/beta'),
      'the pick never rode the session creation');
    // With the session ALIVE, the next pick goes straight to its API…
    const r2 = await full(w.port, `/model?token=${TOKEN}`,
      { method: 'POST', body: '{"id":"other/gamma"}' });
    assert.equal(r2.status, 200);
    await until('the session-model call lands', async () =>
      w.logs().includes('model other/gamma'));
    assert.equal((await health(w.port)).model, 'other/gamma');
  } finally { w.stop(); }
});

test('the claude picker serves the menu, the control frame, and the respawn carry', async () => {
  const home = mkdtempSync(join(tmpdir(), 'oc-home-'));
  const dir = mkdtempSync(join(tmpdir(), 'oc-dir-'));
  const stubLog = join(home, 'stub.log');
  const argsLog = join(home, 'args.log');
  writeFileSync(stubLog, '');
  const port = PORT + 91;
  const bridge = spawn(process.execPath,
    [join(HERE, 'claude_bridge.mjs'), '--token', TOKEN,
      '--port', String(port), '--dir', dir,
      '--models', 'default,opus',
      '--claude', join(HERE, 'bridge_stub_claude.mjs')],
    { env: { ...process.env, HOME: home, STUB_LOG: stubLog,
      STUB_ARGS_LOG: argsLog, STUB_RESULT_MS: '200' } });
  bridge.stderr.resume();
  try {
    await until('bridge up', async () => {
      try { return (await health(port)).ok; } catch { return false; }
    });
    const menu = JSON.parse((await full(port, `/models?token=${TOKEN}`)).text);
    assert.deepEqual(menu.models, [
      { id: 'default', label: 'default' },
      { id: 'opus', label: 'opus' },
    ]);
    const r = await full(port, `/model?token=${TOKEN}`,
      { method: 'POST', body: '{"id":"opus"}' });
    assert.equal(r.status, 200);
    // The 200 is the WRITE's word; the pipe's word is the next read.
    await until('the control frame lands', async () =>
      readFileSync(stubLog, 'utf8').includes('set-model opus'));
    assert.equal((await health(port)).model, 'opus');
    // Off-menu is refused at the BRIDGE gate (never the CLI's).
    const bad = await full(port, `/model?token=${TOKEN}`,
      { method: 'POST', body: '{"id":"pi"}' });
    assert.equal(bad.status, 400);
    assert.ok(bad.text.includes('not in --models'));
    assert.equal((await health(port)).model, 'opus');
    // The pick survives the child: /new + a fresh talk respawns WITH
    // --model in the CLI's face.
    await full(port, `/new?token=${TOKEN}`, { method: 'POST' });
    const a = await call(port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'fresh child same model' });
    await until('done', async () => a.text.includes('event: done'));
    // A pick is not hostage to the child's lifespan: the respawn line
    // carries --model (no session to API, so the flag is the carry).
    await until('the respawn carries the pick', async () =>
      existsSync(argsLog) &&
      readFileSync(argsLog, 'utf8').includes('--model opus'));
  } finally { bridge.kill(); }
});

test('a refused set_model rolls the current back', async () => {
  const home = mkdtempSync(join(tmpdir(), 'oc-home-'));
  const dir = mkdtempSync(join(tmpdir(), 'oc-dir-'));
  writeFileSync(join(home, 'stub.log'), '');
  const port = PORT + 92;
  const bridge = spawn(process.execPath,
    [join(HERE, 'claude_bridge.mjs'), '--token', TOKEN,
      '--port', String(port), '--dir', dir, '--models', 'default,opus',
      '--claude', join(HERE, 'bridge_stub_claude.mjs')],
    { env: { ...process.env, HOME: home,
      STUB_LOG: join(home, 'stub.log'), STUB_MODEL_FAIL: '1',
      STUB_RESULT_MS: '300' } });
  bridge.stderr.resume();
  try {
    await until('bridge up', async () => {
      try { return (await health(port)).ok; } catch { return false; }
    });
    const r = await full(port, `/model?token=${TOKEN}`,
      { method: 'POST', body: '{"id":"opus"}' });
    assert.equal(r.status, 200); // the WRITE happened…
    await until('the refusal lands', async () =>
      (await health(port)).model === 'default', 4000); // …and was walked back
  } finally { bridge.kill(); }
});

test('+219 a failed turn carries the provider\u2019s reason to the phone', async () => {
  const w = await world({ stubEnv: { STUB_OC_FAIL: '1' } });
  try {
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'answer me' });
    await until('done', async () => a.text.includes('event: done'));
    assert.ok(a.text.includes('"isError":true'),
      'the done frame lost the error flag');
    // The field bug +219 exists for: the 403 died in the bridge's
    // stderr while the phone closed the turn 'done clean'. The
    // provider's own words must ride the frame.
    assert.ok(a.text.includes('Access to model denied'),
      'the reason never reached the wire');
    assert.ok(!w.logs().includes('unhandled bus event session.step.failed'),
      'step.failed no longer clutters the tape — it speaks via the done');
    await until('turn closed', async () =>
      (await health(w.port)).turnOpen === false);
  } finally { w.stop(); }
});

// ── +221: transient failures speak ───────────────────────────────────
test('a claude api_retry surfaces as retry progress, not a frozen spinner', async () => {
  const home = mkdtempSync(join(tmpdir(), 'oc-home-'));
  const dir = mkdtempSync(join(tmpdir(), 'oc-dir-'));
  writeFileSync(join(home, 'stub.log'), '');
  const port = PORT + 93;
  const bridge = spawn(process.execPath,
    [join(HERE, 'claude_bridge.mjs'), '--token', TOKEN,
      '--port', String(port), '--dir', dir,
      '--claude', join(HERE, 'bridge_stub_claude.mjs')],
    { env: { ...process.env, HOME: home, STUB_LOG: join(home, 'stub.log'),
      STUB_RETRY: '1', STUB_RESULT_MS: '900' } });
  bridge.stderr.resume();
  try {
    await until('bridge up', async () => {
      try { return (await health(port)).ok; } catch { return false; }
    });
    const a = await call(port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'go' });
    await until('done', async () => a.text.includes('event: done'));
    assert.ok(a.text.includes('"name":"retry"'),
      'the api_retry frame never reached the wire');
    assert.ok(a.text.includes('429') && a.text.includes('attempt 2/5'),
      'the retry frame said nothing about why or how far');
    assert.ok(!a.text.includes('"isError":true'),
      'a recovered retry must not poison the done');
  } finally { bridge.kill(); }
});

test('an opencode step failure says RETRYING while the turn lives', async () => {
  const w = await world({ stubEnv: { STUB_OC_RETRY: '1' } });
  try {
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'go' });
    await until('done', async () => a.text.includes('event: done'));
    assert.ok(a.text.includes('"name":"retry"') &&
      a.text.includes('Too many requests.'),
      'the failed step stayed between the service and the bridge');
    assert.ok(!a.text.includes('"isError":true'),
      'the turn recovered — the done stays clean');
    assert.ok(a.text.includes('The stub sees you.'),
      'a retried turn must still deliver its answer');
  } finally { w.stop(); }
});

test('a dropped event bus mid-turn says reconnecting and loses nothing', async () => {
  const w = await world({ stubEnv: { STUB_OC_DROP: '1', STUB_OC_MS: '200' } });
  try {
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'go' });
    await until('done', async () => a.text.includes('event: done'), 8000);
    assert.ok(a.text.includes('reconnecting'),
      'the phone deserved to know the wire blipped');
    // The ring replay + id-dedup belt: the answer survives the drop
    // EXACTLY once (the replay of a spoken delta must not re-speak).
    const said = a.text.split('\n')
      .filter((l) => l.startsWith('data: {"text":"The stub sees you."'))
      .length;
    assert.equal(said, 1, 'the dropped-and-replayed turn spoke twice');
  } finally { w.stop(); }
});

test('+223 moving folders carries the destination\u2019s remembered session', async () => {
  const home = mkdtempSync(join(tmpdir(), 'oc-home-'));
  const a = join(home, 'proj-a');
  const b = join(home, 'proj-b');
  mkdirSync(a); mkdirSync(b);
  writeFileSync(join(b, '.claude_bridge_session'), 'ses-B');
  const argsLog = join(home, 'args.log');
  const port = PORT + 94;
  const bridge = spawn(process.execPath,
    [join(HERE, 'claude_bridge.mjs'), '--token', TOKEN,
      '--port', String(port), '--dir', a,
      '--claude', join(HERE, 'bridge_stub_claude.mjs')],
    { env: { ...process.env, HOME: home, STUB_LOG: join(home, 'stub.log'),
      STUB_ARGS_LOG: argsLog, STUB_RESULT_MS: '200' } });
  bridge.stderr.resume();
  try {
    await until('bridge up', async () => {
      try { return (await health(port)).ok; } catch { return false; }
    });
    const r = await full(port, `/dir?token=${TOKEN}`,
      { method: 'POST', body: JSON.stringify({path: b}) });
    assert.equal(r.status, 200);
    const dirAns = JSON.parse(r.text);
    assert.equal(dirAns.ok, true);
    assert.equal(dirAns.dir, b);
    // +UUID: the destination's remembered thread is BACKEND news
    // ('ses-B' for --resume); the answer's sessionId is the seated
    // record's app uuid.
    assert.equal(dirAns.backendSid, 'ses-B');
    assert.match(dirAns.sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    assert.equal((await health(port)).backendSid, 'ses-B');
    // +305: the destination's LEGACY dotfile was read once, re-minted
    // under ~/.claude-bridge/pointers, and deleted from the project.
    assert.ok(existsSync(ptrPath(home, 'claude', b)),
      'the legacy pointer was not migrated under the bridge roof');
    assert.ok(!existsSync(join(b, '.claude_bridge_session')),
      'the migrated pointer left the old dotfile in the project dir');
    // The remembered conversation is not merely REPORTED — the next
    // utterance RESUMES it: the pointer rides --resume into the CLI.
    const t = await call(port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'resume me' });
    await until('done', async () => t.text.includes('event: done'));
    assert.ok(readFileSync(argsLog, 'utf8').includes('--resume ses-B'),
      'the moved-to session was not resumed');
  } finally { bridge.kill(); }
});

// ── +229: the opencode usage dialect ─────────────────────────────────
test('the context bar reads per-call usage, not the session\u2019s lifetime sum', async () => {
  // The field bug: the phone's bar marched past 1M inside one turn
  // while the real prompt sat in the tens of thousands. The bus's
  // token counters are session CUMULATES; the bar's law (+609) reads
  // message_start's input as THIS call's context. The adapter must
  // subtract, or every step re-presents the whole past as new.
  const w = await world();
  try {
    const t1 = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'one' });
    await until('first done', async () => t1.text.includes('event: done'));
    // Turn one closes with the call's own usage: 1234 in + 42 out.
    assert.equal((await health(w.port)).context.in, 1276);
    const t2 = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'two' });
    await until('second done', async () => t2.text.includes('event: done'));
    // The second call's message_start carries THIS call's context —
    // the pre-bug wire said 2468 (the cumulative total).
    assert.ok(t2.text.includes('"in":1234'),
      'the second turn did not report a per-call context: ' + t2.text);
    assert.ok(!t2.text.includes('"in":2468'),
      'the context bar was fed the session\u2019s lifetime sum');
    assert.equal((await health(w.port)).context.in, 1276,
      'the post-turn snapshot grew by the whole past, not the delta');
  } finally { w.stop(); }
});

test('a tool round-trip inside a turn does not blink the spinner off', async () => {
  // The field bug: the box went on and off through a working turn.
  // The bus closes EVERY step with a message_stop, and the tool has
  // already resolved by then — so the shared +83 path read 'settled'
  // mid-turn and the phone hid the working box between steps. The
  // turn has ONE boundary; the settled verdict may speak only at it.
  const w = await world({ stubEnv: { STUB_OC_TOOL: '1' } });
  try {
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'run the suite' });
    await until('done', async () => a.text.includes('event: done'));
    // Both sentences of the two-step turn arrived, exactly once.
    assert.ok(a.text.includes('Running a check.'), 'step one missing');
    assert.ok(a.text.includes('All green.'), 'step two missing');
    // The settled tally appears ONCE, and only AFTER the last words
    // (the held stop flushed by the turn's result). A per-step stop
    // settled after step one — before 'All green.' — the blink.
    const lines = a.text.split('\n');
    const settledAt = lines.findIndex((l) =>
      l.startsWith('data: {') && l.includes('"kind":"settled"'));
    assert.ok(settledAt >= 0, 'the turn never declared itself settled');
    const lastSay = lines.findLastIndex((l) =>
      l.startsWith('data: {"text":"All green."'));
    assert.ok(lastSay >= 0, 'the second step never spoke');
    assert.ok(settledAt > lastSay,
      'settled relayed before the turn\u2019s last words — the blink');
    assert.equal(lines.filter((l) =>
      l.startsWith('data: {') && l.includes('"kind":"settled"')).length, 1,
      'more than one settled verdict in one turn');
  } finally { w.stop(); }
});

// ── +230: /seat — the session tabs' one atomic verb ────────────────
test('/seat moves harness, folder and conversation in one request', async () => {
  const w = await world();
  try {
    // Fresh and alone: the whole question set is ONE body.
    const r = await full(w.port, `/seat?token=${TOKEN}`, {
      method: 'POST',
      body: '{"harness":"opencode","fresh":true}',
    });
    assert.equal(r.status, 200);
    const j = JSON.parse(r.text);
    assert.equal(j.ok, true);
    // +UUID: 'fresh' is a conversation, unnamed at the BACKEND but
    // born named at the APP — the answer is its uuid, and the pointer
    // stays empty until a harness id exists.
    assert.match(j.sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, 'fresh answers with its birth uuid');
    assert.equal(j.backendSid, null, 'fresh has no backend thread yet');
    assert.equal(j.harness, 'opencode');
    assert.equal((await health(w.port)).sessionId, j.sessionId);
    // A turn names the session (the stub is always soc-1)…
    const a = await call(w.port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'first words' });
    await until('done', async () => a.text.includes('event: done'));
    // the same record, now backend-named (the stub is always soc-1)…
    assert.equal((await health(w.port)).backendSid, 'soc-1');
    assert.equal((await health(w.port)).sessionId, j.sessionId,
      'naming the backend thread never renames the conversation');
    // …and an explicit RESUME by name re-seats and REWRITES the
    // pointer, so a bridge restart wakes on the tab seated last —
    // the +223 pointer law, now callable with a chosen thread.
    const r2 = await full(w.port, `/seat?token=${TOKEN}`, {
      method: 'POST', body: '{"sessionId":"ses-HOME"}',
    });
    // A bare id is BACKEND news: the seat resolves/adopts it and
    // answers in the app uuid; the pointer keeps both lines.
    const j2 = JSON.parse(r2.text);
    assert.match(j2.sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    assert.equal(j2.backendSid, 'ses-HOME');
    assert.equal((await health(w.port)).sessionId, j2.sessionId);
    assert.equal((await health(w.port)).backendSid, 'ses-HOME');
    const ptr2 = readFileSync(ptrPath(w.home, 'opencode', w.dir), 'utf8').split('\n');
    assert.equal(ptr2[0].trim(), 'ses-HOME',
      'the pointer did not follow the named seat');
    assert.equal(ptr2[1].trim(), j2.sessionId, 'pointer uuid follows the seat');
    // Harness in the SAME verb: the era timeline grows, and with no
    // sessionId named the claude side reads ITS pointer (none yet →
    // fresh on the next word).
    const r3 = await full(w.port, `/seat?token=${TOKEN}`, {
      method: 'POST', body: '{"harness":"claude"}',
    });
    const j3 = JSON.parse(r3.text);
    assert.equal(j3.harness, 'claude');
    // +UUID: no claude pointer → a blank conversation, still born named.
    assert.match(j3.sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    assert.equal(j3.backendSid, null);
    const hist = (await health(w.port)).harnessHistory;
    assert.deepEqual(hist.map((x) => x.harness), ['opencode', 'claude']);
  } finally { w.stop(); }
});

test('/seat refuses what it cannot honour, and says why', async () => {
  const w = await world();
  try {
    const bad = await full(w.port, `/seat?token=${TOKEN}`, {
      method: 'POST', body: '{"harness":"pi"}',
    });
    assert.equal(bad.status, 400);
    assert.match(JSON.parse(bad.text).error, /claude or opencode/);
    const out = await full(w.port, `/seat?token=${TOKEN}`, {
      method: 'POST', body: '{"dir":"/etc"}',
    });
    assert.equal(out.status, 400);
    assert.match(JSON.parse(out.text).error, /dir-root/);
    const sill = await full(w.port, `/seat?token=${TOKEN}`, {
      method: 'POST', body: '{"sessionId":"ses;rm -rf"}',
    });
    assert.equal(sill.status, 400);
    // Nothing moved through any of them.
    assert.equal((await health(w.port)).harness, 'opencode');
  } finally { w.stop(); }
});

test('/models?harness= answers for a seat the bridge is not on', async () => {
  const w = await world(); // seated opencode, stub catalog acme/*
  try {
    const r = JSON.parse((await full(
      w.port, `/models?token=${TOKEN}&harness=claude`)).text);
    assert.equal(r.harness, 'claude');
    assert.deepEqual(r.models.map((m) => m.id),
      ['default', 'sonnet', 'opus', 'haiku']); // the claude menu
    // …and the seat never moved: the sheet previews without touching.
    // The other seat's remembered pick answers too (claude defaults
    // to 'default'); the opencode side proves its model only when a
    // step names it — nothing moved here to make it lie.
    assert.equal(r.current, 'default');
    const h = await health(w.port);
    assert.equal(h.harness, 'opencode');
    assert.equal(h.model, null);
  } finally { w.stop(); }
});

test('+230 the claude seat resumes a NAMED conversation on respawn', async () => {
  const home = mkdtempSync(join(tmpdir(), 'oc-home-'));
  const dir = mkdtempSync(join(tmpdir(), 'oc-dir-'));
  writeFileSync(join(home, 'stub.log'), '');
  const argsLog = join(home, 'args.log');
  const port = PORT + 95;
  const bridge = spawn(process.execPath,
    [join(HERE, 'claude_bridge.mjs'), '--token', TOKEN,
      '--port', String(port), '--dir', dir,
      '--claude', join(HERE, 'bridge_stub_claude.mjs')],
    { env: { ...process.env, HOME: home, STUB_LOG: join(home, 'stub.log'),
      STUB_ARGS_LOG: argsLog, STUB_RESULT_MS: '200' } });
  bridge.stderr.resume();
  try {
    await until('bridge up', async () => {
      try { return (await health(port)).ok; } catch { return false; }
    });
    const r = await full(port, `/seat?token=${TOKEN}`, {
      method: 'POST', body: '{"sessionId":"ses-TAB"}',
    });
    // +UUID: the answer speaks the app uuid; the BACKEND line carries
    // the named thread that --resume will ride.
    const seatJ = JSON.parse(r.text);
    assert.match(seatJ.sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    assert.equal(seatJ.backendSid, 'ses-TAB');
    const t = await call(port, `/talk?token=${TOKEN}`,
      { method: 'POST', body: 'resumed thread' });
    await until('done', async () => t.text.includes('event: done'));
    // The lazy respawn carried --resume with the NAMED id, not a
    // pointer's guess: that name IS the tab's conversation.
    await until('the resume carries the named session', async () =>
      existsSync(argsLog) &&
      readFileSync(argsLog, 'utf8').includes('--resume ses-TAB'));
  } finally { bridge.kill(); }
});
