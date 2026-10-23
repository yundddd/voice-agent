// Named-law tests on the lab world (+328 gap fixes). Where proptest
// explores interleavings, THESE pin the single laws the review found
// unpinned — deterministic walks, step-driven stubs, virtual clock.
//   node --test tool/testlab/laws_test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { TOKEN, call, waitFor, quiesce, bootWorld } from './lab.mjs';
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

async function waitForThen(fn, ms) {
  let last = null;
  await waitFor(async () => { last = fn(); return !!last; }, { cap: ms, step: 25 });
  return last;
}
