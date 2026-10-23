// ── the lab's shared machinery (split from proptest at +328's gap-fix) ───
// The world a law-test needs: bridge on a virtual clock, step-driven
// stubs (real wire shapes only), fault relay, fake phone. The generator
// lives in proptest.mjs; a named-law pin (laws_test.mjs) imports THIS.
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, readFileSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import http from 'node:http';
import { VirtualClock } from './clock.mjs';
import { FRAMES } from './wireframes.mjs';

export const HERE = import.meta.dirname;
export const TOKEN = 'labtok';

export const sleep = (ms) => new Promise(r => setTimeout(r, ms));
// Condition waits replace wall-clock guesses: poll until the wire is
// quiet (no new frames landing anywhere) rather than napping a fixed
// hopeful duration — loopback delivers in single-digit ms, so the cap
// is pressure relief, not the expected path.
export async function waitFor(cond, { cap = 2000, step = 10 } = {}) {
  const t0 = Date.now();
  for (;;) {
    if (await cond()) return true;
    if (Date.now() - t0 > cap) return false;
    await sleep(step);
  }
}
export async function quiesce(world, cap = 800) {
  let last = -1, same = 0;
  return waitFor(() => {
    const n = (world.relay.appliedLog?.length ?? 0)
      + [...world.phone.chats.values()].reduce((a, c) => a + c.length, 0);
    if (n === last) same++; else { same = 0; last = n; }
    return same >= 2; // two still polls: the wire went quiet
  }, { cap, step: 10 });
}
export async function call(url, opts = {}) {
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
export async function waitHealth(port, tries = 80) {
  for (let i = 0; i < tries; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}/health`);
      if (r.ok) return await r.json(); } catch {}
    await sleep(15);
  }
  throw new Error('bridge /health never answered');
}

// ── fault relay: the app-side proxy with a frame journal ──────────────────
export class FaultRelay {
  constructor({ bridgePort, clock }) {
    this.bridgePort = bridgePort; this.clock = clock;
    this.rules = new Map();   // streamKey -> [{action, ms, dueAt}]
    // NOTE on 'delay': transport lag rides REAL time — the bridge's
    // virtual clock is the HARNESS's time, not the wire's. dueAt is
    // wall-clock; a delayed frame resurfaces on the next arrival after
    // its ms have truly passed.
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
  fault(match, action, ms = 400) {
    const q = this.rules.get(match) ?? [];
    q.push({ action, ms, dueAt: action === 'delay' ? Date.now() + ms : 0 });
    this.rules.set(match, q);
  }
  note(key, frame, applied) {
    (this.appliedLog ??= []).push({ key, applied });
    // A frame the relay SWALLOWED still happened on the wire: keep its
    // mid so the model judges replay-vs-fresh by the bridge's facts,
    // not by what this particular (faulty) ear happened to catch.
    if (applied === 'drop' || applied === 'delay') {
      const m = /"_mid":(\d+)/.exec(frame);
      if (m) (this.dropped ??= new Set()).add(Number(m[1]));
    }
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
            if (f.action === 'delay' && f.frame !== undefined &&
                Date.now() >= f.dueAt) {
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
          if (f.action === 'delay' && f.frame === undefined) {
            q.shift(); f.frame = frame; q.unshift(f);
            // release rides a REAL timer (the test process's own clock):
            // a quiet stream must not starve its delayed frame — the
            // next-arrival check alone would hold it forever.
            setTimeout(() => {
              const qi = this.rules.get(key);
              if (qi?.includes(f)) {
                qi.splice(qi.indexOf(f), 1);
                try { res.write(f.frame); this.note(key, f.frame, 'delay'); }
                catch {}
              }
            }, f.ms);
            return;
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
export class FakePhone {
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
  async setModel(conv, id) {
    return call(`${this.base}/sessions/${conv}/model?token=${TOKEN}`,
      { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ id }) });
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
  async settlePumps(ms = 250) {
    await Promise.race([
      Promise.allSettled([...this.views.values()].map(v => v.pump)),
      sleep(ms),
    ]);
  }
}

export async function pickBridgePort() {
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
export async function bootWorld() {
  const home = mkdtempSync(join(tmpdir(), 'lab-'));
  // random-ish start port, walked until the bridge binds: parallel and
  // sequential lab runs can never collide on it
  const bridgePort = await pickBridgePort();
  const env = { ...process.env, HOME: home, BRIDGE_TEST_CLOCK: '1',
    STUB_CTL_DIR: join(home, 'ctl'),
    STUB_OC_LOG: join(home, 'oc.log'), STUB_OC_PORT: '4391',
    STUB_CTL_PORT: '4392' };
  mkdirSync(env.STUB_CTL_DIR, { recursive: true });
  const secondDir = join(home, 'labdir2'); // a /dir verb needs somewhere to move
  mkdirSync(secondDir, { recursive: true });
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
    ctlDir: env.STUB_CTL_DIR,
    secondDir,
    ctlPortFor: (conv) => {
      const f = join(env.STUB_CTL_DIR, conv + '.port');
      return existsSync(f) ? Number(readFileSync(f, 'utf8')) : null;
    },
    ocPorts: () => {
      const f = join(env.STUB_CTL_DIR, 'oc.ports');
      try { return JSON.parse(readFileSync(f, 'utf8')); } catch { return null; }
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

