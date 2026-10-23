// The virtual clock: one deterministic time, injected everywhere.
// install() patches the process's Date.now and the four timer globals,
// so anything the bridge (or the relay) schedules is a QUEUE FACT, not
// a race — the test decides when a timeout, a heartbeat, or the +229
// stop-hold fires by calling advance(). Ties break by insertion order,
// so one seed replays exactly.
//
// The bridge process runs with BRIDGE_TEST_CLOCK=1 (see claude_bridge.mjs
// boot) and exposes POST /test/tick {ms} so the test drives the BRIDGE's
// clock; the testlab process keeps its own instance for relay delays.
export class VirtualClock {
  constructor(startMs = 1_700_000_000_000) {
    this.now = startMs;
    this.timers = []; // {due, seq, fn, interval, id, dead}
    this._seq = 0;
    this._installed = null;
  }
  install() {
    const saved = {
      now: Date.now, setTimeout: globalThis.setTimeout,
      clearTimeout: globalThis.clearTimeout,
      setInterval: globalThis.setInterval,
      clearInterval: globalThis.clearInterval,
    };
    this._saved = saved;
    const clock = this;
    Date.now = () => clock.now;
    globalThis.setTimeout = (fn, ms, ...a) => clock._add(fn, ms, 0, a);
    globalThis.setInterval = (fn, ms, ...a) => clock._add(fn, ms, ms, a);
    globalThis.clearTimeout = (t) => { if (t && t.dead !== undefined) t.dead = true; };
    globalThis.clearInterval = (t) => { if (t && t.dead !== undefined) t.dead = true; };
    this._installed = true;
    return this;
  }
  uninstall() {
    if (!this._installed) return;
    Date.now = this._saved.now;
    globalThis.setTimeout = this._saved.setTimeout;
    globalThis.clearTimeout = this._saved.clearTimeout;
    globalThis.setInterval = this._saved.setInterval;
    globalThis.clearInterval = this._saved.clearInterval;
    this._installed = null;
  }
  _add(fn, ms, interval, args) {
    const t = { due: this.now + Math.max(0, Number(ms) || 0),
      seq: this._seq++, fn, interval: interval > 0 ? Math.max(1, Number(ms)) : 0,
      args, dead: false, id: this._seq, unref: () => {}, ref: () => {} };
    this.timers.push(t);
    return t; // a Timeout-shaped handle: clearTimeout reads .dead,
              // and bridge code that calls .unref() finds a noop
  }
  // Live (non-dead) timer count — the bounded-growth invariant reads it.
  pending() { return this.timers.filter(t => !t.dead).length; }
  // Run every timer whose due has arrived, in (due, seq) order,
  // including timers scheduled by the callbacks themselves, up to target.
  advance(ms) {
    const target = this.now + ms;
    let fired = 0;
    for (;;) {
      const live = this.timers.filter(t => !t.dead && t.due <= target)
        .sort((a, b) => a.due - b.due || a.seq - b.seq);
      if (!live.length) break;
      const t = live[0];
      this.now = Math.max(this.now, t.due);
      this.timers = this.timers.filter(x => x !== t);
      if (t.interval) { t.due = this.now + t.interval; this.timers.push(t); }
      try { t.fn(...(t.args || [])); } catch (e) { t.error = e; throw e; }
      fired++;
    }
    this.now = target;
    return fired;
  }
  nextDue() {
    const live = this.timers.filter(t => !t.dead);
    return live.length ? Math.min(...live.map(t => t.due)) - this.now : null;
  }
}
