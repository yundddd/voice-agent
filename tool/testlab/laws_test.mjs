// Named-law tests on the lab world (+328 gap fixes). Where proptest
// explores interleavings, THESE pin the single laws the review found
// unpinned — deterministic walks, step-driven stubs, virtual clock.
//   node --test tool/testlab/laws_test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { TOKEN, call, waitFor, quiesce, bootWorld } from './lab.mjs';
import { FRAMES } from './wireframes.mjs';
import { randomUUID } from 'node:crypto';

test('+282: an init frame settles the operator\'s "default" into the model that RAN', async () => {
  const w = await bootWorld();
  try {
    const conv = randomUUID();
    await w.phone.fresh(conv);
    // the picker's current before any proof: honest 'default'
    const m0 = await call(`${w.phone.base}/models?token=${TOKEN}`);
    assert.equal(m0.json.current, 'default', 'fresh seat claims nothing it has not run');
    // one prompt; the harness then SPEAKS its model on the wire
    await w.phone.prompt(conv, 'who are you');
    const port = await waitForThen(() => w.ctlPortFor(conv), 2000);
    assert.ok(port, 'the step-driven child announced its port');
    await call(`http://127.0.0.1:${port}/emit`, { method: 'POST',
      body: JSON.stringify([{ frame: { type: 'system', subtype: 'init',
        model: 'claude-real-runner', session_id: 'be-282' } }]) });
    await w.tick(200); await quiesce(w);
    const m1 = await call(`${w.phone.base}/models?token=${TOKEN}`);
    assert.equal(m1.json.current, 'claude-real-runner',
      '+282: /health and the picker resolve by the harness\'s tape, not the placeholder');
    const h = await w.health();
    assert.equal(h.json.model, 'claude-real-runner',
      'the seat row carries the same proven word');
  } finally { w.shutdown(); }
});

test('+282 afterword: a result\'s modelUsage names the runner too', async () => {
  const w = await bootWorld();
  try {
    const conv = randomUUID();
    await w.phone.fresh(conv);
    await w.phone.prompt(conv, 'who are you');
    const port = await waitForThen(() => w.ctlPortFor(conv), 2000);
    await call(`http://127.0.0.1:${port}/emit`, { method: 'POST',
      body: JSON.stringify([{ frame: { type: 'result', subtype: 'success',
        is_error: false, session_id: 'be-282b', usage: {}, total_cost_usd: 0,
        modelUsage: { 'claude-afterword': { contextWindow: 200000 } } } }]) });
    await w.tick(200); await quiesce(w);
    const m = await call(`${w.phone.base}/models?token=${TOKEN}`);
    assert.equal(m.json.current, 'claude-afterword');
  } finally { w.shutdown(); }
});

test('+320/+328: a NAMED /send that names nobody is refused, never guessed onto the seat', async () => {
  const w = await bootWorld();
  try {
    const conv = randomUUID();
    await w.phone.fresh(conv);
    const { writeFileSync } = await import('node:fs');
    const { join } = await import('node:path');
    const file = join(w.home, 'named-note.txt');
    writeFileSync(file, 'a note with an honest return address\n');
    // speak a name this bridge has never heard — the guess chain would
    // land the note in whoever is seated (the leak shape the review
    // found and the 08:39 tape taught); the law says refuse.
    const r = await call(`${w.phone.base}/send?token=${TOKEN}`,
      { method: 'POST', body: JSON.stringify({ path: file,
        sessionId: '00000000-1111-2222-3333-444455556666' }) });
    // the existing +320 door answers honestly (its shape is a 400 text
    // line, pinned here so a future refactor cannot quietly start
    // guessing an old tab's note onto whoever sits down)
    assert.equal(r.status, 400, 'a named miss gets its honest answer');
    assert.match(r.text, /no conversation named/);
    // and the UNNAMED path still rides the documented guess chain
    const r2 = await call(`${w.phone.base}/send?token=${TOKEN}`,
      { method: 'POST', body: JSON.stringify({ path: file }) });
    assert.equal(r2.json.ok, true, 'an old phone that cannot name itself still gets its delivery');
    assert.equal(r2.json.conv, conv, 'filed under the seat — the law the guess chain serves');
  } finally { w.shutdown(); }
});

test('+352: the notification LIGHTS the report debt — no gap for a probe to fall into', async () => {
  // The 17:15 tape, walked: build backgrounded, done note replayed,
  // probe reads a clean ledger ('go idle'), THEN the report turn —
  // with a 437 MB file frame — lands in an unwatched backlog. The law
  // the tape wrote: a paid task owes its report the moment the notice
  // is paid, and an ear that attaches on that word STAYS for the words.
  const w = await bootWorld();
  try {
    const conv = randomUUID();
    await w.phone.fresh(conv);
    await w.phone.prompt(conv, 'build it');
    const port = await waitForThen(() => w.ctlPortFor(conv), 2000);
    const emit = (frags) => call(`http://127.0.0.1:${port}/emit`,
      { method: 'POST', body: JSON.stringify(frags) });
    await emit(FRAMES.bgLaunch(conv, 'btask1', './scripts/build-apk.sh').flat());
    await emit(FRAMES.resultClean(conv));
    await w.tick(100); await quiesce(w);
    // the launch turn closed cleanly; the shell still runs, banner lit
    const h0 = await w.health();
    assert.equal(h0.json.turnOpen, false, 'the launch turn is over');
    assert.ok(w.phone.chat(conv).some(c => c.ev === 'tool' &&
      c.data.name === 'backgrounded'), 'the banner was lit');
    // the ear hangs up (the tape's idle phone), then the task reports
    await w.phone.drop(conv);
    await emit(FRAMES.taskNotification(conv, 'btask1'));
    await w.tick(100); await quiesce(w);
    const h1 = await w.health();
    assert.equal(h1.json.turnOpen, true,
      '+352: the notification lights the debt AT THE PAY — the probe ' +
      'window that swallowed the APK is closed');
    // an attaching ear gets the receipt AND holds for the report
    await w.phone.reconnect(conv);
    await w.tick(50); await quiesce(w);
    assert.ok(w.phone.chat(conv).some(c => c.ev === 'tool' &&
      c.data.name === 'finished' && c.replaying),
      'the finished receipt rides the replay');
    assert.ok(!w.phone.chat(conv).some(c => c.ev === 'say'),
      'the report has not spoken yet (the replay held only what was owed)');
    // the report answers on the SAME still-open ear — the proof the
    // attach was promoted, not closed: a stream that hung up at the
    // replay would leave these words stranded in the backlog. The
    // /send between the notice and the answer is the 17:15 tape's own
    // order (the APK's frame, born inside the old gap).
    const { writeFileSync } = await import('node:fs');
    const { join } = await import('node:path');
    const apk = join(w.home, 'xray-app.apk');
    writeFileSync(apk, 'not really 437 MB, but the same frame\n');
    await call(`${w.phone.base}/send?token=${TOKEN}`,
      { method: 'POST', body: JSON.stringify({ path: apk, sessionId: conv }) });
    await emit(FRAMES.textAnswer(conv, 'The build succeeded, the APK is sent.').flat());
    await emit(FRAMES.resultClean(conv));
    await w.tick(100); await quiesce(w);
    assert.ok(w.phone.chat(conv).some(c => c.ev === 'file'),
      '+352: the APK bubble landed on the open ear, not in a stranded backlog');
    assert.ok(w.phone.chat(conv).some(c => c.ev === 'say'),
      '+352: the report reached the ear that attached at the notice — ' +
      'the old code had closed the stream at the replay and the words ' +
      'waited for the next press');
    const h2 = await w.health();
    assert.equal(h2.json.turnOpen, false, 'the report turn closes its own debt');
  } finally { w.shutdown(); }
});

test('+352 belt: a report that never comes unlights its own debt', async () => {
  // A notification from a child that dies before the API call must not
  // hold the floor for eternity: past the grace, /health goes honest,
  // an attached ear is closed the ordinary wordless way, and the tape
  // confesses.
  const w = await bootWorld();
  try {
    const conv = randomUUID();
    await w.phone.fresh(conv);
    await w.phone.prompt(conv, 'build it');
    const port = await waitForThen(() => w.ctlPortFor(conv), 2000);
    const emit = (frags) => call(`http://127.0.0.1:${port}/emit`,
      { method: 'POST', body: JSON.stringify(frags) });
    await emit(FRAMES.bgLaunch(conv, 'btask1', './scripts/build-apk.sh').flat());
    await emit(FRAMES.resultClean(conv));
    await w.tick(100); await quiesce(w);
    await w.phone.drop(conv);
    await emit(FRAMES.taskNotification(conv, 'btask1'));
    await w.tick(100); await quiesce(w);
    assert.equal((await w.health()).json.turnOpen, true, 'lit at the pay');
    await w.phone.reconnect(conv); // an ear takes the promise
    await w.tick(31000); await quiesce(w);
    assert.equal((await w.health()).json.turnOpen, false,
      'the phantom unlit itself at the deadline');
    assert.match(w.log(), /the report never came/, 'and the tape says so');
    await w.phone.settlePumps();
  } finally { w.shutdown(); }
});

test('+354: a refused file DELIVERY survives its conversation\'s next turn', async () => {
  // The 17:42 tape, end to end: the phone sat on the voice-agent tab
  // while X-Ray's build reported in — the file frame was honestly
  // refused ('left unheard for its own thread', no ack, debt kept),
  // and then X-Ray's NEXT turn began and beginTurn's stale-buffer
  // sweep ate the frame between two honest laws. The landing glance
  // (+324 arms a drain for ANY owed mail, no banner needed — the
  // app's side of this law) kept reading missed=0 because the debt
  // was already a corpse; the bubble never surfaced. The law, whole:
  // transcript frames retire with their turn; a file lives until the
  // phone TAKES it.
  const w = await bootWorld();
  try {
    const a = randomUUID(), b = randomUUID();
    await w.phone.fresh(b);
    await w.phone.prompt(b, 'build it');
    const port = await waitForThen(() => w.ctlPortFor(b), 2000);
    const emit = (frags) => call(`http://127.0.0.1:${port}/emit`,
      { method: 'POST', body: JSON.stringify(frags) });
    await emit(FRAMES.bgLaunch(b, 'btask1', './scripts/build-apk.sh').flat());
    await emit(FRAMES.resultClean(b));
    await w.tick(100); await quiesce(w);
    // the reader moves to another conversation (the voice-agent tab)
    await w.phone.fresh(a);
    // the report: the notice pays the debt, /send files under B, the
    // says and the done follow — no ear on B, all of it backlogged
    await emit(FRAMES.taskNotification(b, 'btask1'));
    const { writeFileSync } = await import('node:fs');
    const { join } = await import('node:path');
    const apk = join(w.home, 'refused.apk');
    writeFileSync(apk, 'the delivery that the sweep used to eat\n');
    await call(`${w.phone.base}/send?token=${TOKEN}`,
      { method: 'POST', body: JSON.stringify({ path: apk, sessionId: b }) });
    await emit(FRAMES.textAnswer(b, 'Built and sent.').flat());
    await emit(FRAMES.resultClean(b));
    await w.tick(100); await quiesce(w);
    assert.ok(!w.phone.chat(b).some((c) => c.ev === 'file'),
      'the delivery has not reached any ear yet (it rides the backlog)');
    // the tape's killer: the SAME conversation starts its next turn
    await w.phone.prompt(b, 'did you send it?');
    await emit(FRAMES.textAnswer(b, 'Yes, the bubble is there.').flat());
    await emit(FRAMES.resultClean(b));
    await w.tick(100); await quiesce(w);
    const h = (await w.health()).json;
    const rowB = (h.sessions ?? []).find((r) => r.sid === b);
    assert.ok((rowB?.missed ?? 0) > 0,
      '+354: the file survived the new turn\'s sweep — the debt is alive, ' +
      'not a corpse, and the landing glance can arm a drain for it');
    // the landing drain proper: attach as owner, replay delivers
    await w.phone.reconnect(b);
    await w.tick(50); await quiesce(w);
    assert.ok(w.phone.chat(b).some((c) => c.ev === 'file'),
      '+354: the owner\'s ear gets its bubble — refused, never forgotton');
  } finally { w.shutdown(); }
});

async function waitForThen(fn, ms) {
  let last = null;
  await waitFor(async () => { last = fn(); return !!last; }, { cap: ms, step: 25 });
  return last;
}
