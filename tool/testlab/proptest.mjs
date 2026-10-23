// ── model-based property tester for the voice turn machine (+328) ─────────
// Doctrine: README "Test lab". Fakes at every boundary; interleavings by
// seeded generator; invariants from a tiny reference model checked after
// EVERY step; failures shrunk to the smallest reproducing trace and their
// seed locked.
//
//   fake ASR:  phone.prompt(conv, text)   — no mic, no device
//   fake TTS:  phone.spoken — every played say, stamped with the focus
//   clock:     POST /test/tick — heartbeats/holds/timeouts fire when SAID
//   harness:   stubEmit/stubFinish/stubCrash on the per-conversation
//              step-driven stub (real wire shapes only)
//   transport: fault relay — drop/delay/dup/reorder/cut on command
//   lifecycle: dropConnection kills the socket; reconnect rides /attach
//
// Run: node tool/testlab/proptest.mjs [--runs N] [--seed S] [--steps M]
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, mkdirSync, rmSync, readFileSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import http from 'node:http';
import { VirtualClock } from './clock.mjs';
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
const TOKEN = 'labtok';

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
// Condition waits replace wall-clock guesses: poll until the wire is
// quiet (no new frames landing anywhere) rather than napping a fixed
// hopeful duration — loopback delivers in single-digit ms, so the cap
// is pressure relief, not the expected path.
async function waitFor(cond, { cap = 2000, step = 10 } = {}) {
  const t0 = Date.now();
  for (;;) {
    if (await cond()) return true;
    if (Date.now() - t0 > cap) return false;
    await sleep(step);
  }
}
async function quiesce(world, cap = 800) {
  let last = -1, same = 0;
  return waitFor(() => {
    const n = (world.relay.appliedLog?.length ?? 0)
      + [...world.phone.chats.values()].reduce((a, c) => a + c.length, 0);
    if (n === last) same++; else { same = 0; last = n; }
    return same >= 2; // two still polls: the wire went quiet
  }, { cap, step: 10 });
}
async function call(url, opts = {}) {
  // Same watchdog on every named verb (the relay's dropped request
  // would otherwise ride undici's 300 s too).
  if (opts.signal === undefined && opts.method === 'POST')
    opts = { ...opts, signal: AbortSignal.timeout(2000) };
  const r = await fetch(url, opts).catch(() => ({
    status: 0, text: '', headers: {}, })); // dead-socket-shaped
  const t = typeof r.text === 'string' ? r.text : await r.text().catch(() => '');
  let j = null; try { j = JSON.parse(t); } catch {}
  return { status: r.status, json: j, text: t };
}
async function waitHealth(port, tries = 80) {
  for (let i = 0; i < tries; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}/health`);
      if (r.ok) return await r.json(); } catch {}
    await sleep(25);
  }
  throw new Error('bridge /health never answered');
}

// ── fault relay: the app-side proxy with a frame journal ──────────────────
class FaultRelay {
  constructor({ bridgePort, clock }) {
    this.bridgePort = bridgePort; this.clock = clock;
    this.rules = new Map();   // streamKey -> [{action, ms, dueAt}]
    this.listeners = [];      // (key, frameText, applied)
    this.port = null;
  }
  start() {
    return new Promise((res) => {
      this.server = http.createServer((req, r2) => this.handle(req, r2));
      this.server.listen(0, '127.0.0.1', () => {
        this.port = this.server.address().port; res();
      });
    });
  }
  stop() { try { this.server.close(); } catch {} }
  fault(match, action, ms = 1200) {
    const q = this.rules.get(match) ?? [];
    q.push({ action, ms, dueAt: action === 'delay' ? this.clock.now + ms : 0 });
    this.rules.set(match, q);
  }
  note(key, frame, applied) {
    (this.appliedLog ??= []).push({ key, applied });
    for (const l of this.listeners) l(key, frame, applied);
  }
  keyFor(url) {
    const m = /sessions\/([^/]+)\//.exec(url) || /session=([^&]+)/.exec(url);
    return m ? m[1] : url.split('?')[0];
  }
  handle(req, res) {
    let body = '';
    req.on('data', (c) => body += c);
    req.on('end', () => {
      const key = this.keyFor(req.url);
      const upstream = http.request({
        host: '127.0.0.1', port: this.bridgePort, path: req.url,
        method: req.method, headers: { ...req.headers, host: 'x' },
      }, (ur) => {
        const ct = ur.headers['content-type'] || '';
        if (!ct.includes('event-stream')) {
          res.writeHead(ur.statusCode, ur.headers);
          ur.pipe(res); return;
        }
        res.writeHead(ur.statusCode, ur.headers);
        let buf = '', held = null;
        const flushHeld = () => {
          if (held) { res.write(held); this.note(key, held, 'reorder'); held = null; }
        };
        const step = (frame) => { // frame is one complete SSE block
          const q = this.rules.get(key) ?? [];
          // delayed frames whose virtual due has arrived speak first:
          for (let i = 0; i < q.length; i++) {
            const f = q[i];
            if (f.action === 'delay' && this.clock.now >= f.dueAt) {
              q.splice(i, 1); i--;
              res.write(f.frame); this.note(key, f.frame, 'delay');
            }
          }
          if (frame.startsWith(':')) { flushHeld(); res.write(frame); return; }
          const f = q[0];
          if (!f) { flushHeld(); res.write(frame); this.note(key, frame, 'pass'); return; }
          if (f.action === 'drop') { q.shift(); this.note(key, frame, 'drop'); return; }
          if (f.action === 'dup') { q.shift(); res.write(frame); res.write(frame);
            this.note(key, frame, 'dup'); return; }
          if (f.action === 'cut') { q.shift(); this.note(key, frame, 'cut');
            try { ur.destroy(); } catch {} try { res.destroy(); } catch {} return; }
          if (f.action === 'reorder') {
            q.shift();
            if (held) { res.write(held); res.write(frame);
              this.note(key, held, 'reorder'); this.note(key, frame, 'reorder');
              held = null; }
            else held = frame;
            return;
          }
          if (f.action === 'delay') { // arm on the next frame arrival
            if (f.frame === undefined) {
              q.shift(); f.frame = frame;
              this.clock.timers.some(() => true); // no-op keeps linter honest
              q.unshift(f); return;
            }
          }
          flushHeld(); res.write(frame); this.note(key, frame, 'pass');
        };
        ur.on('data', (chunk) => {
          buf += chunk;
          let i;
          while ((i = buf.indexOf('\n\n')) >= 0) {
            const frame = buf.slice(0, i + 2); buf = buf.slice(i + 2);
            step(frame);
          }
        });
        ur.on('end', () => { flushHeld(); try { res.end(buf || ''); } catch {} });
        res.on('close', () => { try { ur.destroy(); } catch {} });
      });
      upstream.on('error', () => { try { res.end(); } catch {} });
      if (body) upstream.write(body);
      upstream.end();
    });
  }
}

// ── the fake phone ────────────────────────────────────────────────────────
class FakePhone {
  constructor({ relayPort }) {
    this.base = `http://127.0.0.1:${relayPort}`;
    this.focus = null;
    this.chats = new Map();
    this.spoken = [];
    this.heardMids = new Set();
    this.liveDeliveries = new Map(); // _mid -> count on LIVE views (dup check)
    this.views = new Map();
    this.violations = [];
    this.replaying = new Set(); // convs whose current view is a replay
  }
  chat(conv) { if (!this.chats.has(conv)) this.chats.set(conv, []); return this.chats.get(conv); }
  ingest(viewConv, ev, data, replaying) {
    // ownership is the frame's OWN stamp (+274)
    const owner = data._sess || viewConv;
    this.chat(owner).push({ ev, data, replaying, at: Date.now() });
    if (!replaying && data._mid != null)
      this.liveDeliveries.set(data._mid, (this.liveDeliveries.get(data._mid) ?? 0) + 1);
    if (ev === 'say' && data.text) {
      const mid = data._mid;
      if (mid != null && this.heardMids.has(mid)) return; // dedup the replay
      if (owner === this.focus) {
        this.spoken.push({ text: data.text, sess: owner,
          focusAtSpeak: this.focus, turn: data._turn, mid });
        this.heardMids.add(mid);
        call(`${this.base}/heard?token=${TOKEN}`,
          { method: 'POST', body: JSON.stringify({ mids: [mid] }) }).catch(() => {});
      }
    }
  }
  consume(conv, res, replaying) {
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    const pump = (async () => {
      for (;;) {
        let d;
        try { d = await reader.read(); } catch { return; }
        if (d.done) return;
        buf += dec.decode(d.value, { stream: true });
        let i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          const f = buf.slice(0, i); buf = buf.slice(i + 2);
          const em = /event: (\w+)\n/.exec(f + '\n');
          const dm = /data: (.*)/.exec(f);
          if (!em || !dm) continue;
          let data; try { data = JSON.parse(dm[1]); } catch { continue; }
          this.ingest(conv, em[1], data, replaying);
          if (em[1] === 'done') { try { await reader.cancel(); } catch {} return; }
        }
      }
    })();
    this.views.set(conv, { reader, pump });
  }
  async prompt(conv, text, { interrupt = true } = {}) {
    let r;
    try {
      r = await fetch(`${this.base}/sessions/${conv}/prompts?token=${TOKEN}`,
        { method: 'POST', headers: { 'content-type': 'application/json' },
          // A phone waits seconds, not minutes, for a response head: a
          // cut-before-headers socket must cost the lab a watchdog, not
          // undici's 300-second default.
          signal: AbortSignal.timeout(2000),
          body: JSON.stringify({ text, interrupt: interrupt ? 1 : 0 }) });
    } catch { return { status: 0 }; } // dead socket: what the phone does
    if (r.status !== 200) return { status: r.status };
    this.consume(conv, r, false);
    return { status: 200 };
  }
  async seat(conv) {
    this.focus = conv;
    return call(`${this.base}/seat?token=${TOKEN}`,
      { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ sessionId: conv }) });
  }
  async fresh(conv) {
    this.focus = conv;
    return call(`${this.base}/seat?token=${TOKEN}`,
      { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ sessionId: conv, fresh: true }) });
  }
  async stop(conv) {
    await call(`${this.base}/sessions/${conv}/stop?token=${TOKEN}`, { method: 'POST' });
  }
  async reset(conv) {
    await call(`${this.base}/sessions/${conv}/reset?token=${TOKEN}`, { method: 'POST' });
    this.views.delete(conv);
  }
  async drop(conv) {
    const v = this.views.get(conv);
    if (v) { try { await v.reader.cancel(); } catch {} this.views.delete(conv); }
  }
  async reconnect(conv) {
    let r;
    try { r = await fetch(`${this.base}/attach?token=${TOKEN}&session=${conv}`,
      { signal: AbortSignal.timeout(2000) }); }
    catch { return { status: 0 }; }
    if (r.status !== 200) return r;
    this.consume(conv, r, true);
    return r;
  }
  // Bounded on purpose: a view whose turn never got its done (a parked
  // prompt flushed into a plan-less turn) would wait forever — the
  // final quiesce gives it a beat, then the shutdown reaps it.
  async settlePumps(ms = 500) {
    await Promise.race([
      Promise.allSettled([...this.views.values()].map(v => v.pump)),
      sleep(ms),
    ]);
  }
}

// ── reference model ───────────────────────────────────────────────────────
class RefModel {
  constructor(phone) { this.phone = phone; this.turns = new Map(); this.seenMid = new Set(); }
  // The ledger is IDENTITY-based (+186 law): a frame's _mid is born with
  // it and never changes across re-relays, so a repeat of a known mid
  // is a replay (legal, the phone dedups it), and a KNOWN turn wearing a
  // NEW mid is the wire lying — that is the violation the +325 bug class
  // would trip.
  check(v) {
    const p = this.phone;
    for (const s of p.spoken)
      if (s.sess !== s.focusAtSpeak)
        v.push(`TTS spoke from ${s.sess} while focus was ${s.focusAtSpeak}`);
    const seenMid = this.seenMid; // PERSISTS across checks: one frame,
    // judged once — otherwise a completed turn 'reopens' every step after
    for (const [conv, frames] of p.chats) {
      let openTurn = 0;
      for (const f of frames) {
        const d = f.data;
        const mid = d._mid;
        if (mid != null) {
          if (seenMid.has(mid)) continue; // replay of a frame we know
          seenMid.add(mid);
        }
        const t = d._turn ?? 0;
        if (f.ev === 'tool' && d?.name === 'started' && t) {
          if (!this.turns.has(t)) this.turns.set(t, { conv, state: 'open', done: 0 });
          const rec = this.turns.get(t);
          if (rec.state === 'done') v.push(`turn ${t} reopened in ${conv} — ` +
            `frame: ${f.ev}:${d?.name ?? ''}#${mid}/t${t} replay=${f.replaying} idx=${frames.indexOf(f)}/${frames.length} — ledger: ` +
            frames.map(x => `${x.ev}:${x.data?.name ?? ''}#${x.data?._mid}/t${x.data?._turn}${x.replaying ? '*' : ''}`).join(' '));
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
        if (f.ev !== 'done' && t && this.turns.get(t)?.state === 'done')
          v.push(`frame ${f.ev} of closed turn ${t} arrived after its done (${conv})`);
      }
    }
  }
}

async function pickBridgePort() {
  for (let i = 0; i < 8; i++) {
    const p = 8900 + Math.floor(Math.random() * 900);
    const open = await new Promise((res) => {
      const srv = http.createServer();
      srv.on('error', () => res(false));
      srv.listen(p, '127.0.0.1', () => srv.close(() => res(true)));
    });
    if (open) return p;
  }
  throw new Error('no free bridge port');
}

// ── the world ─────────────────────────────────────────────────────────────
async function bootWorld() {
  const home = mkdtempSync(join(tmpdir(), 'lab-'));
  // random-ish start port, walked until the bridge binds: parallel and
  // sequential lab runs can never collide on it
  const bridgePort = await pickBridgePort();
  const env = { ...process.env, HOME: home, BRIDGE_TEST_CLOCK: '1',
    STUB_CTL_DIR: join(home, 'ctl'),
    STUB_OC_LOG: join(home, 'oc.log'), STUB_OC_PORT: '4391',
    STUB_CTL_PORT: '4392' };
  mkdirSync(env.STUB_CTL_DIR, { recursive: true });
  const oc = spawn(process.execPath, [join(HERE, 'stub_opencode.mjs')],
    { env, stdio: 'ignore' });
  const stubCmd = join(HERE, 'stub_claude.mjs'); // shebang'd, executable
  const bridge = spawn(process.execPath, [
    join(HERE, '..', 'claude_bridge.mjs'),
    '--dir', home, '--token', TOKEN, '--port', String(bridgePort),
    '--claude', stubCmd, '--dir-root', home, '--harness', 'claude',
  ], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let bridgeLog = '';
  bridge.stderr.on('data', (b) => { bridgeLog += b; });
  const relay = new FaultRelay({ bridgePort, clock: new VirtualClock(Date.now()) });
  await relay.start();
  const phone = new FakePhone({ relayPort: relay.port });
  try { await waitHealth(bridgePort); }
  catch (e) { bridge.stdout?.resume(); throw new Error(e.message + '\n' + bridgeLog.slice(-1500)); }
  return {
    home, bridge, oc, bridgePort, relay, phone,
    tick: (ms) => call(`http://127.0.0.1:${bridgePort}/test/tick?token=${TOKEN}`,
      { method: 'POST', body: JSON.stringify({ ms }) }).catch(() => null),
    clock: () => call(`http://127.0.0.1:${bridgePort}/test/clock?token=${TOKEN}`)
      .catch(() => null),
    health: () => call(`http://127.0.0.1:${bridgePort}/health`)
      .catch(() => null),
    ctlPortFor: (conv) => {
      const f = join(env.STUB_CTL_DIR, conv + '.port');
      return existsSync(f) ? Number(readFileSync(f, 'utf8')) : null;
    },
    log: () => bridgeLog,
    shutdown() {
      try { bridge.kill('SIGKILL'); } catch {}
      try { oc.kill('SIGKILL'); } catch {}
      relay.stop();
      rmSync(home, { recursive: true, force: true });
    },
  };
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
  'faultDrop', 'faultDup', 'faultReorder', 'faultDelay', 'faultCut'];
const WEIGHTS = [13, 9, 5, 3, 2, 24, 11, 2, 4, 4, 8, 3, 2, 2, 2, 2];
function pickAction(rand) {
  const total = WEIGHTS.reduce((a, b) => a + b, 0);
  let r = rand() * total;
  for (let i = 0; i < ACTIONS.length; i++) { r -= WEIGHTS[i]; if (r <= 0) return ACTIONS[i]; }
  return 'tick';
}

async function apply(world, rand, st, a) {
  const { phone, relay } = world;
  const known = Object.keys(st.convs);
  const label = known[Math.floor(rand() * known.length)] ?? 'c-1';
  const conv = st.convs[label]; // actions speak the phone's uuid
  switch (a) {
    case 'prompt': {
      const text = 'say the number ' + Math.floor(rand() * 90 + 10);
      const r = await phone.prompt(conv, text);
      if (r.status === 200 && !st.plans[conv])
        st.plans[conv] = { conv, queue: [].concat(newPlan(conv, rand)) };
      st.lastConv = conv; st.lastLabel = label;
      return `prompt ${label} "${text}"${r.status !== 200 ? ' -> ' + r.status : ''}`;
    }
    case 'switchTo':
      await phone.seat(conv);
      return `switchTo ${label}`;
    case 'interrupt':
      await phone.stop(conv);
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
      delete st.convs[label]; delete st.plans[conv];
      return `closeSession ${label}`;
    case 'stubEmit': {
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
  }
  return a;
}

// ── one run / one trace ───────────────────────────────────────────────────
async function runTrace(seed, actions) {
  const world = await bootWorld();
  const rand = mulberry32(seed);
  const home = randomUUID(); // the phone's first tab
  const st = { plans: {}, convs: { 'c-1': home }, created: 2,
    lastConv: home, lastLabel: 'c-1', errNext: false };
  await world.phone.fresh(home);
  const model = new RefModel(world.phone);
  const violations = [];
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
          // I5 (mid-run, the honest form): busy is legal while the
          // ledger shows a genuinely open turn; busy with the ledger
          // CLOSED at that turn is health lying about its own record.
          if (row.turnOpen && row.turn) {
            const rec = model.turns.get(row.turn);
            if (rec?.state === 'done' && !row.queued)
              violations.push(`session ${row.sid} reports busy after turn ${row.turn}'s done`);
          }
          // I6: the unheard backlog stays bounded
          if ((row.missed ?? 0) > 500)
            violations.push(`backlog unbounded: ${row.missed} on ${row.sid}`);
        }
      }
      const clk = await world.clock().catch(() => null);
      if ((clk?.json?.pending ?? 0) > 200)
        violations.push(`timer leak: ${clk.json.pending} pending`);
      if (violations.length) break;
    }
    // quiesce: finish every open plan, then DRAIN — every row still
    // busy after the plans are gone gets its turn's end spoken (a
    // flushed parked prompt has no plan of its own; the law says it
    // must end, so we hand it the end the harness would have sent).
    for (const conv of Object.keys(st.plans)) {
      st.lastConv = conv;
      await apply(world, rand, st, 'stubFinish');
    }
    for (let round = 0; round < 6; round++) {
      const h = await world.health();
      const open = (h?.json?.sessions ?? []).filter(r => r.turnOpen);
      if (!open.length) break;
      for (const row of open) {
        const port = world.ctlPortFor(row.sid);
        if (port) await call(`http://127.0.0.1:${port}/emit`,
          { method: 'POST', body: JSON.stringify(FRAMES.resultClean(row.sid)) })
          .catch(() => {});
      }
      await world.tick(3000);
      await quiesce(world, 1200);
    }
    {
      const h = await world.health();
      for (const row of (h?.json?.sessions ?? []).filter(r => r.turnOpen))
        violations.push(`session ${row.sid} busy forever after its harness finished`);
    }
    await world.tick(4000);
    await quiesce(world, 1500);
    await world.phone.settlePumps().catch(() => {});
    model.check(violations);
    // I-dup: a live frame may arrive twice ONLY behind a dup fault the
    // relay itself applied — never silently from the bridge.
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
async function shrink(seed, actions, first) {
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
