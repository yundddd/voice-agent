// ── model-based property tester for the voice turn machine (+328) ─────────
// Doctrine in README "Test lab". Fakes at every boundary (lab.mjs);
// interleavings by seeded generator; the reference model's laws checked
// after EVERY step; failures shrunk and seed-locked.
//
// Run: node tool/testlab/proptest.mjs [--runs N] [--seed S] [--steps M]
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { TOKEN, sleep, call, waitFor, quiesce, bootWorld, FakePhone } from './lab.mjs';
import { FRAMES, newPlan, nextFragments, finishPlan } from './wireframes.mjs';

const HERE = import.meta.dirname;
const argv = process.argv.slice(2);
const flag = (n, d) => {
  const i = argv.indexOf('--' + n);
  return i >= 0 ? argv[i + 1] : d;
};
const RUNS = Number(flag('runs', 40));
const LOCKED = flag('seed', null);
const MAX_STEPS = Number(flag('steps', 22));

// ── reference model ───────────────────────────────────────────────────────
class RefModel {
  constructor(phone, relay) { this.phone = phone; this.relay = relay;
    this.turns = new Map(); this.seenMid = new Set(); }
  // The ledger is IDENTITY-based (+186 law): a frame's _mid is born with
  // it and never changes across re-relays, so a repeat of a known mid
  // is a replay (legal, the phone dedups it), and a KNOWN turn wearing a
  // NEW mid is the wire lying — that is the +325 bug class.
  check(v) {
    const p = this.phone;
    for (const s of p.spoken)
      if (s.sess !== s.focusAtSpeak)
        v.push(`TTS spoke from ${s.sess} while focus was ${s.focusAtSpeak}`);
    const seenMid = this.seenMid; // PERSISTS across checks: one frame, judged once
    for (const [conv, frames] of p.chats) {
      let openTurn = 0;
      for (const f of frames) {
        const d = f.data;
        const mid = d._mid;
        if (mid != null) {
          if (seenMid.has(mid)) continue; // replay of a frame we know
          seenMid.add(mid);
          // a frame the relay dropped for this ear is still 'known':
          // the reattach replay that finally carries it is a delivery,
          // never a reopen (the +104 law — a dead stream decides the
          // TRANSPORT, not the message)
          if (this.relay?.dropped?.has(mid)) continue;
        }
        const t = d._turn ?? 0;
        if (f.ev === 'tool' && d?.name === 'started' && t) {
          if (!this.turns.has(t)) this.turns.set(t, { conv, state: 'open', done: 0 });
          const rec = this.turns.get(t);
          if (rec.state === 'done')
            v.push(`turn ${t} reopened in ${conv}`);
        }
        if (f.ev === 'done') {
          const dt = d._turn ?? 0;
          if (openTurn && dt && dt !== openTurn)
            v.push(`done for turn ${dt} arrived while ${openTurn} was open in ${conv}`);
          const rec = this.turns.get(dt || openTurn);
          if (rec) {
            rec.done++;
            if (rec.done > 1) v.push(`turn ${dt || openTurn} closed twice in ${conv}`);
            rec.state = 'done';
          } else {
            this.turns.set(dt || 0, { conv, state: 'done', done: 1 });
          }
          openTurn = 0;
        }
        if (f.ev !== 'done' && t && this.turns.get(t)?.state === 'done') {
          // Receipts and deliveries are not turn OUTPUT: a cut tool's
          // 'finished' rides into the NEXT turn on purpose (heldFinished
          // mirrors +99's promise), a /send file frame is a delivery
          // that surfaces whenever an ear returns. The law — 'nothing
          // of the turn arrives after' — is about the stream, and the
          // phone's pumps already filed those two shapes by identity.
          const name = f.data?.name;
          // +114: a re-relayed sentence retires its parked copy by TEXT,
          // wearing a fresh mid; an echo of a closed turn is the law
          // working, not a late frame.
          const isReceipt = f.ev === 'file' || f.ev === 'say' ||
            (f.ev === 'tool' && (name === 'finished' || name === 'queued'));
          if (!isReceipt)
            v.push(`frame ${f.ev}:${name ?? ''} of closed turn ${t} arrived after its done (${conv})`);
        }
      }
    }
  }
}

// ── the generator ─────────────────────────────────────────────────────────
function mulberry32(a) {
  return () => {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
const ACTIONS = ['prompt', 'switchTo', 'interrupt', 'newSession',
  'closeSession', 'stubEmit', 'stubFinish', 'stubCrash',
  'dropConnection', 'reconnect', 'tick',
  'faultDrop', 'faultDup', 'faultReorder', 'faultDelay', 'faultCut',
  'modelPick', 'harnessFlip', 'dirMove', 'compact', 'sendFile'];
const WEIGHTS = [12, 8, 5, 3, 2, 20, 9, 2, 4, 4, 7, 3, 2, 2, 2, 2,
  4, 3, 2, 3, 3];
function pickAction(rand) {
  const total = WEIGHTS.reduce((a, b) => a + b, 0);
  let r = rand() * total;
  for (let i = 0; i < ACTIONS.length; i++) { r -= WEIGHTS[i]; if (r <= 0) return ACTIONS[i]; }
  return 'tick';
}

// push OC bus fragments through the service stub's control door
async function ocPush(world, events) {
  const ports = world.ocPorts();
  if (!ports?.ctl) return false;
  await call(`http://127.0.0.1:${ports.ctl}/pushes`,
    { method: 'POST', body: JSON.stringify({ events }) }).catch(() => null);
  return true;
}

async function apply(world, rand, st, a) {
  const { phone, relay } = world;
  // Self-heal first: a closeSession can empty the ledger, and every
  // action below speaks a conversation — an undefined name turns the
  // named verbs mute (the +322 disease, in the lab's own mirror).
  if (!Object.keys(st.convs).length) {
    const l = 'c-' + st.created++;
    const u = randomUUID();
    await phone.fresh(u);
    st.convs[l] = u;
  }
  const known = Object.keys(st.convs);
  const label = known[Math.floor(rand() * known.length)];
  const conv = st.convs[label];
  switch (a) {
    case 'prompt': {
      const text = 'say the number ' + Math.floor(rand() * 90 + 10);
      const r = await phone.prompt(conv, text);
      if (r.status === 200 && !st.plans[conv]) {
        if (st.harness === 'opencode') st.ocOpen.add(conv);
        else st.plans[conv] = newPlan(conv, rand);
      }
      st.lastConv = conv; st.lastLabel = label;
      return `prompt ${label} "${text}"${r.status !== 200 ? ' -> ' + r.status : ''}`;
    }
    case 'switchTo':
      await phone.seat(conv);
      return `switchTo ${label}`;
    case 'interrupt':
      await phone.stop(conv);
      if (st.harness === 'opencode' && st.ocOpen.has(conv)) {
        await ocPush(world, FRAMES.oc.interrupted(conv));
        st.ocOpen.delete(conv);
      }
      return `stop ${label}`;
    case 'newSession': {
      const freshLabel = 'c-' + st.created++;
      const fresh = randomUUID();
      const r = await phone.fresh(fresh);
      if (r.status === 200) st.convs[freshLabel] = fresh;
      return `newSession ${freshLabel}`;
    }
    case 'closeSession':
      await phone.reset(conv);
      delete st.convs[label]; delete st.plans[conv]; st.ocOpen.delete(conv);
      return `closeSession ${label}`;
    case 'stubEmit': {
      if (st.harness === 'opencode') {
        const ok = await ocPush(world, FRAMES.oc.delta(label, st.n++));
        return ok ? `stubEmit ${label} (oc bus)` : `stubEmit ${label} (no oc stub)`;
      }
      const key = st.lastConv ?? conv;
      const port = world.ctlPortFor(key);
      if (!port) return `stubEmit (no child for ${st.lastLabel ?? label})`;
      const plan = st.plans[key];
      const frames = plan ? nextFragments(plan, rand) : null;
      if (!frames) return `stubEmit ${st.lastLabel ?? label} (plan empty)`;
      await call(`http://127.0.0.1:${port}/emit`,
        { method: 'POST', body: JSON.stringify(frames) }).catch(() => {});
      return `stubEmit ${st.lastLabel ?? label} (${frames.length} frames)`;
    }
    case 'stubFinish': {
      if (st.harness === 'opencode') {
        if (!st.ocOpen.size) return 'stubFinish (no open oc turn)';
        const [c] = [...st.ocOpen];
        const ok = await ocPush(world, FRAMES.oc.finish(c));
        if (ok) st.ocOpen.delete(c);
        return ok ? `stubFinish ${label} (oc exec.succeeded)` : 'stubFinish (no oc stub)';
      }
      const key = st.lastConv ?? conv;
      const port = world.ctlPortFor(key);
      if (!port) return `stubFinish (no child for ${st.lastLabel ?? label})`;
      const plan = st.plans[key];
      const frames = plan ? finishPlan(st, plan) : FRAMES.resultClean(key);
      delete st.plans[key];
      await call(`http://127.0.0.1:${port}/emit`,
        { method: 'POST', body: JSON.stringify(frames) }).catch(() => {});
      return `stubFinish ${st.lastLabel ?? label}`;
    }
    case 'stubCrash': {
      const key = st.lastConv ?? conv;
      const port = world.ctlPortFor(key);
      if (!port) return `stubCrash (no child for ${st.lastLabel ?? label})`;
      await call(`http://127.0.0.1:${port}/crash`,
        { method: 'POST', body: '{}' }).catch(() => {});
      delete st.plans[key];
      return `stubCrash ${st.lastLabel ?? label}`;
    }
    case 'dropConnection':
      await phone.drop(conv);
      return `dropConnection ${label}`;
    case 'reconnect':
      await phone.reconnect(conv);
      return `reconnect ${label}`;
    case 'tick': {
      const ms = [10, 300, 850, 1300, 2100, 3500][Math.floor(rand() * 6)];
      await world.tick(ms);
      return `tick ${ms}`;
    }
    case 'faultDrop': relay.fault(conv, 'drop'); return `faultDrop ${label}`;
    case 'faultDup': relay.fault(conv, 'dup'); return `faultDup ${label}`;
    case 'faultReorder': relay.fault(conv, 'reorder'); return `faultReorder ${label}`;
    case 'faultDelay': relay.fault(conv, 'delay'); return `faultDelay ${label}`;
    case 'faultCut': relay.fault(conv, 'cut'); return `faultCut ${label}`;
    case 'modelPick': {
      // Ask about the RECORD's harness (rows report their own, +323
      // law), not whatever the seat happens to be.
      const hh = await world.health();
      const row = (hh?.json?.sessions ?? []).find(r => r.sid === conv);
      const harnessNow = row?.harness ?? 'claude';
      const menu = await call(
        `${phone.base}/models?token=${TOKEN}&harness=${harnessNow}`);
      const ids = (menu.json?.models ?? []).map(m => m.id);
      if (!ids.length) return 'modelPick (menu empty)';
      const picked = ids[Math.floor(rand() * ids.length)];
      const prev = menu.json.current;
      let armed = false;
      const port = world.ctlPortFor(st.lastConv ?? conv);
      if (port && rand() < 0.5 && st.harness === 'claude') {
        armed = (await call(`http://127.0.0.1:${port}/refuse_model`,
          { method: 'POST', body: JSON.stringify({ model: picked }) })).status === 200;
      }
      await phone.setModel(conv, picked);
      // The refusal counts only when the stub SPOKE it: an armed pick
      // whose child died mid-flight is not a rollback — the choice is
      // real and rides the respawn flag (the +216 law), and current
      // staying at the pick is honest, not stuck.
      let refused = false;
      if (armed) {
        await waitFor(async () => {
          const h = await call(`http://127.0.0.1:${port}/heard`);
          refused = String(h.text || '').includes('refused ' + picked);
          return refused;
        }, { cap: 400, step: 40 });
      }
      // +282 both-ways law: a 'default' pick settles to the proven run
      // if the harness ever named one, else to the honest 'default'.
      // A successful pick may legally read as either the optimistic id
      // (until the harness next speaks) or the PREVIOUS proven word (an
      // init frame re-settles it, +282). It may NOT be a third word.
      const expected = picked === 'default'
        ? (refused ? prev : [prev, 'default'])
        : (refused ? prev : [picked, prev]);
      let settled = null;
      await waitFor(async () => {
        const m = await call(`${phone.base}/models?token=${TOKEN}`);
        settled = m.json?.current;
        return Array.isArray(expected) ? expected.includes(settled)
          : settled === expected;
      }, { cap: refused ? 600 : 1500, step: 50 });
      if (!(Array.isArray(expected) ? expected.includes(settled) : settled === expected))
        st.violations.push(`model ${picked} ${refused ? 'refusal' : 'pick'} left current at ${settled} (was ${prev})`);
      return `modelPick ${picked}${refused ? ' (refused)' : armed ? ' (armed, no refusal heard)' : ''}`;
    }
    case 'harnessFlip': {
      const to = st.harness === 'claude' ? 'opencode' : 'claude';
      await call(`${phone.base}/harness?token=${TOKEN}`,
        { method: 'POST', body: JSON.stringify({ to }) });
      st.harness = to;
      // the era flip rests whatever was mid-flight in the old child:
      st.plans = {}; st.ocOpen.clear();
      const h = await world.health();
      if (h?.json?.harness !== to)
        st.violations.push(`/harness flip to ${to} not reported by health (${h?.json?.harness})`);
      return `harnessFlip -> ${to}`;
    }
    case 'dirMove': {
      const target = st.dirNow === world.secondDir ? conv && st.home : world.secondDir;
      await call(`${phone.base}/dir?token=${TOKEN}`,
        { method: 'POST', body: JSON.stringify({ path: target }) });
      const h = await world.health();
      if (h?.json?.dir && h.json.dir !== target)
        st.violations.push(`/dir to ${target}: health says ${h.json.dir}`);
      else if (h?.json?.dir) st.dirNow = h.json.dir;
      return `dirMove -> ${target.split('/').pop()}`;
    }
    case 'compact': {
      const r = await phone.prompt(conv, '/compact');
      if (st.harness === 'claude' && r.status === 200) {
        // slash prompts ride stdin verbatim; the turn needs its result
        const port = world.ctlPortFor(conv);
        if (port) await call(`http://127.0.0.1:${port}/emit`,
          { method: 'POST', body: JSON.stringify(FRAMES.compactBoundary(conv).concat(FRAMES.resultClean(conv))) })
          .catch(() => {});
      }
      return `compact ${label}`;
    }
    case 'sendFile': {
      // The returning-ear law (+298), and the law the lab learned the
      // hard way at +328: /seat RESTS the conversation being left —
      // re-seating the tab already home wipes its just-parked backlog
      // (the app knows never to swipe to the tab it's on, so it never
      // hits this). Seat only when AWAY; drain by attach either way.
      if (phone.focus !== conv) await phone.seat(conv);
      const r = await call(`${phone.base}/send?token=${TOKEN}`,
        { method: 'POST', body: JSON.stringify({ path: st.notePath, sessionId: conv }) });
      const j = r.json ?? {};
      if (j.ok) {
        if (phone.focus !== conv) await phone.seat(conv);
        await phone.reconnect(conv);
      }
      if (!j.ok) return `sendFile (refused: ${r.text?.slice(0, 40)})`;
      const landed = await waitFor(
        () => (phone.chats.get(conv) ?? []).some(f => f.ev === 'file'),
        { cap: 1200, step: 25 });
      if (!landed)
        st.violations.push(`/send named ${label} (${conv}): no file frame in its chat; response named ${j.conv}`);
      return `sendFile ${j.name}${landed ? ' → owned' : ' → LOST'}`;
    }
  }
  return a;
}

// ── one run / one trace ───────────────────────────────────────────────────
async function runTrace(seed, actions) {
  const world = await bootWorld();
  const rand = mulberry32(seed);
  const home = randomUUID(); // the phone's first tab
  const st = { plans: {}, convs: { 'c-1': home }, created: 2,
    lastConv: home, lastLabel: 'c-1', errNext: false,
    harness: 'claude', ocOpen: new Set(), n: 10, violations: [],
    home: world.home, secondDir: world.secondDir, dirNow: world.home,
    notePath: null };
  try {
    const { writeFileSync: wf } = await import('node:fs');
    st.notePath = join(world.home, 'a-note.txt');
    wf(st.notePath, 'a note for the phone\n');
  } catch {}
  await world.phone.fresh(home);
  const model = new RefModel(world.phone, world.relay);
  const violations = st.violations;
  world.phone.violations = violations;
  const trace = [];
  try {
    for (const a of actions) {
      const label = await apply(world, rand, st, a);
      trace.push(label);
      await world.tick(200);                // timers fire when the tick says
      await quiesce(world);                 // and frames land when they land
      model.check(violations);
      const h = await world.health().catch(() => null);
      if (h?.json) {
        for (const row of h.json.sessions ?? []) {
          if (row.turnOpen && row.turn) {
            const rec = model.turns.get(row.turn);
            if (rec?.state === 'done' && !row.queued)
              violations.push(`session ${row.sid} reports busy after turn ${row.turn}'s done`);
          }
          if ((row.missed ?? 0) > 500)
            violations.push(`backlog unbounded: ${row.missed} on ${row.sid}`);
        }
      }
      const clk = await world.clock().catch(() => null);
      if ((clk?.json?.pending ?? 0) > 200)
        violations.push(`timer leak: ${clk.json.pending} pending`);
      if (violations.length) break;
    }
    // quiesce: finish open plans, then DRAIN every still-busy row —
    // the law says the harness must end it, so hand it the ending.
    for (const conv of Object.keys(st.plans)) {
      st.lastConv = conv;
      await apply(world, rand, st, 'stubFinish');
    }
    if (st.ocOpen.size) {
      for (const c of [...st.ocOpen]) await ocPush(world, FRAMES.oc.finish(c));
      st.ocOpen.clear();
    }
    for (let round = 0; round < 6; round++) {
      const h = await world.health();
      const open = (h?.json?.sessions ?? []).filter(r => r.turnOpen);
      if (!open.length) break;
      for (const row of open) {
        // The ROW names its own harness (per +323: a doomed row speaks
        // for itself): a claude child from an earlier era leaves a
        // stale port file behind, so "port exists" is not the question.
        if (row.harness === 'opencode')
          await ocPush(world, FRAMES.oc.finish(row.sid));
        else {
          const port = world.ctlPortFor(row.sid);
          if (port) await call(`http://127.0.0.1:${port}/emit`,
            { method: 'POST', body: JSON.stringify(FRAMES.resultClean(row.sid)) })
            .catch(() => {});
        }
      }
      await world.tick(3000);
      await quiesce(world, 1200);
    }
    {
      const h = await world.health();
      const rows = h?.json?.sessions ?? [];
      // The documented opencode limitation: ONE conversation at a time
      // wears the service identity (the bus filter speaks it) — when
      // two rows are opencode-era, a busy orphan of the handover is
      // the era's fact, not a leak. Note it; do not call it a bug.
      const ocRows = rows.filter(r => r.harness === 'opencode').length;
      for (const row of rows.filter(r => r.turnOpen)) {
        if (row.harness === 'opencode' && ocRows > 1) continue;
        violations.push(`session ${row.sid} busy forever after its harness finished`);
      }
      // HEARD-TRIM law (+114 authority, the honest endgame): return
      // EVERY ear, let each thread's backlog drain into its chat, ack
      // every mid the phone now holds — and the unheard backlog must
      // go to zero. A number that survives its own ack is the +159
      // stuck-badge class, wearing whatever banner it likes.
      for (const u of Object.values(st.convs)) await world.phone.reconnect(u);
      await world.tick(1200);
      await quiesce(world, 1200);
      // Two drain+ack rounds: a marker re-relayed after the first ack
      // (heldFinished riding two turns) earns its trim from the second.
      for (let round = 0; round < 2; round++) {
        const mids = [...world.phone.chats.values()].flat()
          .map(f => f.data._mid).filter(m => m != null);
        if (mids.length) await call(`${world.phone.base}/heard?token=${TOKEN}`,
          { method: 'POST', body: JSON.stringify({ mids }) });
        await world.tick(1200);
        await quiesce(world, 800);
      }
      const hFinal = await world.health();
      for (const row of hFinal?.json?.sessions ?? [])
        if ((row.missed ?? 0) > 0)
          violations.push(`heard mail re-owed: ${row.sid} still reports ${row.missed} after its ear drained and acked every frame`);
    }
    await world.tick(4000);
    await quiesce(world, 1500);
    await world.phone.settlePumps().catch(() => {});
    model.check(violations);
    const dupKeys = new Set((world.relay.appliedLog ?? [])
      .filter(x => x.applied === 'dup').map(x => x.key));
    for (const [mid, n] of world.phone.liveDeliveries) {
      if (n > 1 && !dupKeys.size)
        violations.push(`live frame mid=${mid} delivered ${n} times with no dup fault armed`);
    }
  } catch (e) {
    violations.push('harness error: ' + (e?.stack ?? e));
  } finally {
    const log = world.log();
    world.shutdown();
    return { violations: violations.length
      ? violations[0] + '\n--- bridge tail ---\n' + log.slice(-2500) : null,
      trace, spoken: world.phone?.spoken?.length ?? 0,
      frames: [...(world.phone?.chats?.values() ?? [])].reduce((a, c) => a + c.length, 0) };
  }
}

// ── shrink (ddmin over the action trace; determinism by seed) ────────────
async function shrink(seed, actions) {
  if (!(await runTrace(seed, actions)).violations) return actions; // flake guard
  let cur = actions.slice();
  for (let n = 2; n <= cur.length;) {
    const chunk = Math.max(1, Math.floor(cur.length / n));
    let shrunk = false;
    for (let i = 0; i < cur.length; i += chunk) {
      const cand = cur.slice(0, i).concat(cur.slice(i + chunk));
      if (!cand.length) continue;
      if ((await runTrace(seed, cand)).violations) { cur = cand; shrunk = true; break; }
    }
    if (!shrunk) n = n >= cur.length ? n + 1 : Math.min(cur.length, n * 2);
    else n = 2;
    if (cur.length <= 1) break;
  }
  return cur;
}

// ── main ──────────────────────────────────────────────────────────────────
let failed = 0, passed = 0;
const startSeed = LOCKED ? Number(LOCKED) : (Date.now() & 0x7fffffff);
for (let run = 0; run < RUNS; run++) {
  const seed = LOCKED ? startSeed : startSeed + run;
  const rand = mulberry32(seed);
  const actions = Array.from({ length: MAX_STEPS }, () => pickAction(rand));
  const t0 = Date.now();
  const r = await runTrace(seed, actions);
  if (process.env.LAB_TRACE)
    console.log(`seed ${seed}: ${((Date.now() - t0) / 1000).toFixed(1)}s ${r.violations ? 'FAIL' : 'ok'}`);
  if (r.violations) {
    failed++;
    const min = await shrink(seed, actions);
    console.log(`FAIL seed ${seed}\n  ${r.violations.split('\n')[0]}`);
    if (process.env.LAB_FULL) console.log(r.violations);
    console.log('  shrunk trace:');
    for (const t of min) console.log('    ' + t);
    console.log(`  lock: --seed ${seed}`);
    mkdirSync(join(HERE, 'failures'), { recursive: true });
    writeFileSync(join(HERE, 'failures', seed + '.json'),
      JSON.stringify({ seed, actions, min, note: r.violations.split('\n')[0] }, null, 2));
  } else {
    passed++;
    if (process.env.LAB_TRACE) {
      console.log(`seed ${seed} ok — ${r.spoken} spoken, ${r.frames} frames in chats; trace:`);
      for (const t of r.trace) console.log('    ' + t);
    }
  }
  if (LOCKED) break;
}
console.log(`\n${passed} passed, ${failed} failed` +
  (LOCKED ? ` (locked seed ${startSeed})` : ` (${RUNS} runs)`));
process.exit(failed ? 1 : 0);
