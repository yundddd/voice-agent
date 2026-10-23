// ── OpenCode adapter: the opencode v2 service harness --------------------
// Discovered live against the v2 service (opencode 2.0.18): its HTTP API
// is /api/* with basic auth from ~/.local/state/opencode/service.json
// (username opencode; the password ROTATES with the service, so the file
// is re-read per call), sessions are POST /api/session {location}, the
// turn is POST /api/session/{id}/prompt {text}, the bus is GET /api/event
// (SSE; envelope {id, type, data}), cuts are POST …/interrupt, and the
// turn closes with session.execution.succeeded. The bus speaks parts, not
// Anthropic frames — session.text.{started,delta,ended},
// session.reasoning.*, session.tool.{input.started,called,success},
// session.usage.updated — and THIS file is the only place that knows it:
// the bus events are translated straight into normalized HarnessEvents
// (interface.mjs), the same set the Cloude adapter feeds. Where the old
// design faked Claude stream-json frames to reuse handleEvent, this
// adapter now speaks the app's own protocol; the counterfeit is gone.
import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { HarnessEvent, harnessEvent, HarnessSession } from './interface.mjs';

// One opencode conversation at a time this era: the service identity is a
// module singleton, so a second opencode record shares its session — a
// documented limitation, the bus filter speaks for it (as it always did).
const oc = {
  ev: new EventEmitter(),
  ctrl: null, sid: null, gen: 0, disposed: true,
  seen: new Set(), // bus event ids (a resubscribe may replay the tail)
  tools: new Map(), // oc call id -> tool name (for error results)
  callIn: 0, callOut: 0, cost: 0, needsPreamble: false, extraErrs: [],
  cumIn: 0, cumOut: 0,  // session LIFETIME token totals (see +229 below)
  stopTimer: null,      // a step-end message_stop held back (+229)
  model: null,        // 'provider/model' the last step proved itself on
  pendingModel: null, // a pick made before any session existed
  // Per-spawn knowledge the VERBS need at moments the child may be down
  // (the /model door parks a pick before any session exists):
  dir: null, sysPrompt: '', bin: 'opencode', dumpNote: () => {},
  onStreamDropped: () => {},
};
oc.stdout = oc.ev; // (the SSE reader fills 'event' directly now; the
oc.stderr = new EventEmitter(); // emitter IS the wire)

const ocAuth = (st) => 'Basic ' +
  Buffer.from(`opencode:${st.password}`).toString('base64');
const ocState = () => {
  try {
    return JSON.parse(readFileSync(
      join(homedir(), '.local/state/opencode/service.json'), 'utf8'));
  } catch { return null; }
};
async function ocAlive(st) {
  try {
    const r = await fetch(st.url + '/api/info', {
      headers: { authorization: ocAuth(st) },
      signal: AbortSignal.timeout(3000) });
    return r.ok;
  } catch { return false; }
}
// The endpoint, reviving the shared service once if it is down: `opencode
// serve --service` registers itself in the state file, which is also how
// the TUI on the desktop finds it — the bridge does not own a private
// server, it joins (or wakes) the machine's.
let ocReviving = null;
async function ocEndpoint() {
  let st = ocState();
  if (st && await ocAlive(st)) return st;
  if (!ocReviving) {
    ocReviving = (async () => {
      try {
        const c = spawn(oc.bin,
          ['serve', '--service', '--hostname', '127.0.0.1'],
          { detached: true, stdio: 'ignore' });
        c.unref();
      } catch {}
      const t0 = Date.now();
      while (Date.now() - t0 < 10000) {
        await new Promise(r => setTimeout(r, 400));
        st = ocState();
        if (st && await ocAlive(st)) return st;
      }
      throw new Error('opencode service not reachable (no live service, ' +
        `'${oc.bin} serve --service' did not register within 10s)`);
    })().finally(() => { ocReviving = null; });
  }
  return ocReviving;
}
async function ocReq(path, body, method) {
  const st = await ocEndpoint();
  const r = await fetch(st.url + path, {
    method: method ?? (body === undefined ? 'GET' : 'POST'),
    headers: { authorization: ocAuth(st),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000) });
  const txt = await r.text();
  if (!r.ok) throw new Error(`opencode ${r.status} on ${path}: ${txt.slice(0, 200)}`);
  try { return txt ? JSON.parse(txt) : {}; } catch { return {}; }
}
function ocEmit(type, kind, fields) {
  oc.ev.emit('event', harnessEvent(type, kind, fields));
}

// +229: an opencode STEP is a message, not the turn — the bus closes a
// step while the next one is a breath away (tool round-trip, retry
// backoff, the harness's own accounting between calls). Relaying
// message_stop the instant step.ended lands tells the phone 'text
// final, nothing generating' (+83's settled verdict) in the MIDDLE of
// a working turn, and the field verdict was the box blinking off and
// on through every step boundary — where the claude CLI, whose
// message_stop lands with a tool still open, stays quiet and keeps the
// wheel lit. So the step-end stop is HELD: any new activity cancels
// it (no settled frame at all, exactly like claude's between-calls
// truth), and the turn's own result flushes it first (the settled
// verdict still speaks at the real boundary, with the draft tail, one
// beat before the done). The hold only ever expires on a bus that has
// gone mute mid-turn — where 'settled' is the honest word anyway.
const OC_STOP_HOLD_MS = 3000;
function ocHoldStop() {
  if (oc.stopTimer) return;
  oc.stopTimer = setTimeout(() => {
    oc.stopTimer = null;
    ocEmit(HarnessEvent.MessageStop, 'message_stop', {});
  }, OC_STOP_HOLD_MS);
}
function ocBreakStop(flush) {
  if (!oc.stopTimer) return;
  clearTimeout(oc.stopTimer);
  oc.stopTimer = null;
  if (flush) ocEmit(HarnessEvent.MessageStop, 'message_stop', {});
}

// The census on the Cloude side counts its raw stream_event kinds; this
// adapter names the normalized event the bus part BECOMES, so the
// [census] journal line reads the same shape from either harness.
function translateBus(j) {
  const t = typeof j.type === 'string' ? j.type : '';
  const d = j.data ?? {};
  if (typeof j.id === 'string') { // dedupe a resubscribe's replayed tail
    if (oc.seen.has(j.id)) return;
    oc.seen.add(j.id);
    if (oc.seen.size > 600) oc.seen.delete(oc.seen.values().next().value);
  }
  // The bus is machine-global: Tim's own desktop opencode sessions ride
  // it too. Only OUR session (or session-less server events) may speak.
  if (d.sessionID && d.sessionID !== oc.sid) return;
  if (t === 'session.step.started') {
    ocBreakStop(false); // generation resumed — no settled verdict this side
    // +216: the step names the model it runs — the picker's current
    // goes from optimistic to PROVEN the moment the turn starts.
    if (d.model?.id && d.model?.providerID) {
      oc.model = `${d.model.providerID}/${d.model.id}`;
      ocEmit(HarnessEvent.ModelRan, 'step.started', { model: oc.model });
    }
    ocEmit(HarnessEvent.CallStart, 'message_start',
      { inputTokens: oc.callIn, cacheRead: 0, cacheCreation: 0 });
  } else if (t === 'session.reasoning.started') {
    ocBreakStop(false);
    ocEmit(HarnessEvent.BlockStart, 'content_block_start', { kind2: 'thinking' });
  } else if (t === 'session.reasoning.delta') {
    ocEmit(HarnessEvent.BlockDelta, 'content_block_delta',
      { kind2: 'thinking', text: d.delta ?? '' });
  } else if (t === 'session.reasoning.ended') {
    ocEmit(HarnessEvent.BlockStop, 'content_block_stop', {});
  } else if (t === 'session.text.started') {
    ocBreakStop(false);
    ocEmit(HarnessEvent.BlockStart, 'content_block_start', { kind2: 'text' });
  } else if (t === 'session.text.delta') {
    ocEmit(HarnessEvent.BlockDelta, 'content_block_delta',
      { kind2: 'text', text: d.delta ?? '' });
  } else if (t === 'session.text.ended') {
    ocEmit(HarnessEvent.BlockStop, 'content_block_stop', {});
    // The final part text rides the snapshot path too: it claims the
    // block's spoken watermark and owes only the un-relayed remainder
    // (identical bookkeeping to the claude CLI's own snapshots).
    if (typeof d.text === 'string' && d.text.trim()) {
      ocEmit(HarnessEvent.Snapshot, 'snapshot', {
        role: 'assistant', blocks: [{ type: 'text', text: d.text }],
        hay: JSON.stringify([{ type: 'text', text: d.text }]) });
    }
  } else if (t === 'session.tool.input.started') {
    ocBreakStop(false);
    ocEmit(HarnessEvent.BlockStart, 'content_block_start',
      { kind2: 'tool_use', name: d.name ?? 'tool' });
  } else if (t === 'session.tool.called') {
    ocBreakStop(false);
    oc.tools.set(d.id, d.name);
    ocEmit(HarnessEvent.Snapshot, 'snapshot', {
      role: 'assistant',
      blocks: [{ type: 'tool_use', id: d.id, name: d.name, input: d.input ?? {} }],
      hay: JSON.stringify([{ type: 'tool_use', id: d.id, name: d.name }]) });
  } else if (t === 'session.tool.success' || /^session\.tool\.(failed|error)/.test(t)) {
    oc.tools.delete(d.id);
    const txt = (d.content ?? []).map(c => c.text ?? '').join('\n');
    ocEmit(HarnessEvent.Snapshot, 'snapshot', {
      role: 'user',
      blocks: [{ type: 'tool_result', tool_use_id: d.id,
        content: txt, is_error: t !== 'session.tool.success' }],
      hay: JSON.stringify([{ type: 'tool_result', tool_use_id: d.id }]) });
  } else if (t === 'session.step.ended') {
    ocHoldStop(); // +229: held, not relayed — the next breath may cancel it
  } else if (t === 'session.usage.updated') {
    // +229: the bus's token numbers are the session's LIFETIME
    // CUMULATES, not this call's usage (field: a ~60k-context voice
    // session reported 2.18M input — every step's whole prompt,
    // summed). The token machinery downstream reads every number here
    // as THIS call's usage — CallStart's inputTokens IS the context the
    // call carried (the +609 law the context bar stands on) — so the
    // bar marched past the model's window inside one turn while the
    // real prompt had barely grown. Derive the deltas: what the
    // counters moved since the last snapshot IS the call's usage (and
    // for a no-cache provider, each call carries the whole context, so
    // the delta IS the context). A counter SMALLER than the last
    // snapshot is a new session or a compaction's fresh page: the
    // whole number stands as the delta.
    const tok = d.tokens ?? {};
    const cumIn = (tok.input ?? 0) + (tok.cache?.read ?? 0) + (tok.cache?.write ?? 0);
    const cumOut = tok.output ?? 0;
    oc.callIn = cumIn >= oc.cumIn ? cumIn - oc.cumIn : cumIn;
    oc.callOut = cumOut >= oc.cumOut ? cumOut - oc.cumOut : cumOut;
    oc.cumIn = cumIn; oc.cumOut = cumOut;
    oc.cost = d.cost ?? oc.cost;
    ocEmit(HarnessEvent.Usage, 'message_delta', { outputTokens: oc.callOut });
  } else if (/^session\.permission\.(request|create)/.test(t)) {
    // Voice has nobody to answer a prompt: approve once, loudly in the
    // log. The reply body is {decision} (schema-verified: 'response' is
    // a 400, and a 400 here hangs the turn forever behind a question
    // nobody answers). The explicit-deny rules in opencode's own config
    // still win server-side, exactly as bypassPermissions keeps them
    // under claude.
    const reqID = d.requestID ?? d.id;
    console.error(`  [oc] auto-approving permission ${reqID}`);
    ocReq(`/api/session/${oc.sid}/permission/${reqID}/reply`,
      { decision: 'always' }).catch(() => {});
  } else if (t === 'session.step.failed') {
    // +221: a failed STEP while the turn still lives is the harness
    // breathing between attempts — say so, in the same retry shape the
    // Cloude adapter feeds for its own api_retry system event, so the
    // phone learns one shape for 'the harness is retrying'.
    const e = d.error ?? {};
    ocEmit(HarnessEvent.Retry, 'step.failed', {
      status: e.type ?? 'step.failed',
      error: typeof e.message === 'string' ? e.message : '',
      gaveUp: false,
    });
  } else if (t === 'session.model.selected') {
    // +219: the service CONFIRMS a model change on its own bus — the
    // picker's optimistic current goes proven at the moment of the
    // pick, not only when a step next runs.
    if (d.model?.id && d.model?.providerID) {
      oc.model = `${d.model.providerID}/${d.model.id}`;
      ocEmit(HarnessEvent.ModelRan, 'model.selected', { model: oc.model });
    }
  } else if (t === 'session.execution.succeeded') {
    ocBreakStop(true); // +229: the turn's REAL boundary — settled before done
    ocEnd({
      isError: false, why: '(no detail)',
      usage: { input_tokens: oc.callIn, output_tokens: oc.callOut },
      costUsd: oc.cost });
  } else if (/^session\.execution\.(failed|cancelled|canceled|interrupted)$/.test(t)
             || t === 'session.error') {
    ocBreakStop(true);
    ocEnd({
      isError: true, why: [d.error ?? d.reason ?? t, ...oc.extraErrs],
      usage: {} });
  } else if (t.startsWith('session.') && !t.startsWith('session.inbox.')
             && !['session.created', 'session.step.streamed',
                  'session.tool.input.ended',
                  'session.tool.progress',
                  'session.instructions.updated', 'session.execution.started',
                  'session.updated'].includes(t)) {
    // Name the gaps once each, not once each per frame: the tape should
    // still be legible after an hour of traffic.
    if (!oc.kindsLogged?.has(t)) {
      (oc.kindsLogged ??= new Set()).add(t);
      console.error(`  [oc] unhandled bus event ${t} — ${JSON.stringify(d).slice(0, 160)}`);
    }
  }
}

// The turn's last word, and the conversation's name with it: the bridge
// rekeys the record on the id the moment it surfaces (the +257 law,
// where the old adapter carried session_id on every counterfeit result).
function ocEnd(fields) {
  if (oc.sid) ocEmit(HarnessEvent.SessionId, 'result', { sid: oc.sid });
  ocEmit(HarnessEvent.TurnEnd, 'result', fields);
}

function ocClose() {
  // Turn the fake child through 'exit' exactly once, so the shared
  // bookkeeping (detached tools, receipts, error relay) runs the same.
  if (oc.disposed) return;
  oc.disposed = true;
  if (oc.stopTimer) { clearTimeout(oc.stopTimer); oc.stopTimer = null; }
  try { oc.ctrl?.abort(); } catch {}
  process.nextTick(() => oc.ev.emit('exit', 0, null));
}
async function ocPrompt(text) {
  try {
    if (!oc.sid) {
      // A model picked before the session existed rides its creation.
      const s = await ocReq('/api/session', {
        title: 'voice bridge', location: { directory: oc.dir },
        ...(oc.pendingModel ? { model: oc.pendingModel } : {}),
      });
      oc.pendingModel = null;
      oc.sid = s.data?.id ?? s.id;
      oc.cumIn = 0; oc.cumOut = 0; // +229: a fresh session's counters are its own
      // The voice prompt belongs to the SESSION, not to one message, so
      // every later utterance keeps the spoken-answer shape. The v2
      // instructions API takes {value} (schema-verified: {content} is a
      // 400); if it still shrugs, fall back to carrying the prompt in
      // the first utterance (flagged once).
      try {
        await ocReq(`/api/experimental/session/${oc.sid}/instructions/entries/voice`,
          { value: oc.sysPrompt }, 'PUT');
      } catch { oc.needsPreamble = true; }
      oc.dumpNote('oc-session', oc.sid);
    }
    let t = text;
    if (oc.needsPreamble) {
      t = oc.sysPrompt + '\n\n' + text;
      oc.needsPreamble = false;
    }
    await ocReq(`/api/session/${oc.sid}/prompt`, { text: t });
  } catch (e) {
    // A failed prompt must still CLOSE the turn the /talk began: the
    // phone learned 'started' and is owed a done.
    console.error('  [oc] prompt failed: ' + e);
    ocEnd({ isError: true, why: String(e?.message ?? e), usage: {} });
  }
}
// The VERB surface, module-level so the /model door can park a pick
// before any session (or even any bus listener) exists — the same
// freedom the old ocStdin shim gave the counterfeit-child design.
export function opencodeSetModel(id) {
  const slash = id.indexOf('/');
  const model = slash < 0
    ? { providerID: 'opencode', id }
    : { providerID: id.slice(0, slash), id: id.slice(slash + 1) };
  const prev = oc.model;
  oc.model = id;
  const send = oc.sid
    ? ocReq(`/api/session/${oc.sid}/model`, { model })
    : Promise.resolve().then(() => { oc.pendingModel = model; });
  return send.catch((e) => { oc.model = prev; throw e; })
    .then(() => {
      console.error('  [model] opencode -> ' + id +
        (oc.sid ? '' : ' (parked for the next session)'));
      return id;
    });
}
export function opencodeCurrentModel() { return oc.model; }
export function opencodeModelList(d) { // the picker's whole menu, live
  return ocReq('/api/model?location%5Bdirectory%5D=' +
    encodeURIComponent(d))
    .then((r) => ((r && r.data) ?? []).map((m) => ({
      id: `${m.providerID}/${m.id}`,
      label: m.name ?? `${m.providerID}/${m.id}`,
    })));
}

export class OpenCodeSession extends HarnessSession {
  // Joining (or waking) the machine's service, bound to ONE conversation:
  // dir for the session location, sysPrompt for the instructions entry,
  // resume for the sid to rehydrate. The bus listener survives drops
  // with backoff; the tail replay is deduped by event id.
  constructor({ dir, sysPrompt, resume, bin, dumpNote, onStreamDropped }) {
    super();
    oc.dir = dir;
    oc.sysPrompt = sysPrompt ?? '';
    oc.bin = bin ?? oc.bin;
    oc.dumpNote = dumpNote ?? (() => {});
    oc.onStreamDropped = onStreamDropped ?? (() => {});
    oc.gen++;
    oc.ev.removeAllListeners(); // a replaced backend's forwards retire
    oc.sid = resume ?? null;
    oc.callIn = oc.callOut = 0;
    oc.cost = 0;
    oc.seen.clear();
    oc.tools.clear();
    oc.disposed = false;
    // Forward the singleton bus onto THIS session's emitter — under the
    // same listeners the bridge attaches to every adapter.
    oc.ev.on('event', (ev) => this.emit('event', ev));
    // Same law as the claude side: only the backend that HOLDS the seat
    // may announce a death (a replaced backend's exit is bookkeeping —
    // the bridge's guard reads focus.child).
    oc.ev.on('exit', (code, sig) => this.emit('exit', code, sig));
    this._gen = oc.gen;
    this._listen();
    console.error('  [opencode] backend up (resume=' +
      (resume ? resume.slice(0, 16) : 'none — fresh session') + ')');
  }
  prompt(text) {
    // opencode's own condense: the chip hears the same compact boundary
    // the Cloude adapter feeds for the CLI, and the turn closes on the
    // prompt call's own terms. (Voice has no slash-command menu beyond
    // this one; everything else is an utterance.)
    if (/^\/compact(\s|$)/i.test(String(text).trim())) {
      ocReq(`/api/session/${oc.sid}/compact`, undefined, 'POST').then(() => {
        ocEmit(HarnessEvent.SystemNotice, 'compact_boundary',
          { notice: 'compact_boundary' });
        ocEnd({ isError: false, why: '(no detail)', usage: {} });
      }).catch(e => console.error('  [oc] compact failed: ' + e));
      return;
    }
    ocPrompt(text);
  }
  interrupt() {
    if (!oc.sid) return;
    ocReq(`/api/session/${oc.sid}/interrupt`, undefined, 'POST').catch(e =>
      console.error('  [oc] interrupt failed: ' + e));
  }
  setModel(id) { return opencodeSetModel(id); }
  kill() { ocClose(); }
  currentModel() { return oc.model; }
  async _listen() {
    const gen = this._gen;
    let backoff = 500;
    while (!oc.disposed && gen === oc.gen) {
      try {
        const st = await ocEndpoint();
        oc.ctrl = new AbortController();
        const res = await fetch(st.url + '/api/event', {
          headers: { authorization: ocAuth(st),
            accept: 'text/event-stream' },
          signal: oc.ctrl.signal });
        if (!res.ok) throw new Error('event http ' + res.status);
        backoff = 500; // the link proved itself; reset the ladder
        const rd = res.body.getReader();
        const dec = new TextDecoder();
        let buf = '';
        for (;;) {
          const { done, value } = await rd.read();
          if (done) throw new Error('event stream ended');
          buf += dec.decode(value, { stream: true });
          let i;
          while ((i = buf.indexOf('\n\n')) >= 0) {
            const f = buf.slice(0, i);
            buf = buf.slice(i + 2);
            const dl = f.split('\n').find(l => l.startsWith('data:'));
            if (!dl) continue;
            try { translateBus(JSON.parse(dl.slice(5))); } catch {}
          }
        }
      } catch (e) {
        if (oc.disposed || gen !== oc.gen) return;
        // First drop while a turn is open gets one loud line — and
        // +221: while a turn is OPEN the phone is hearing that line too
        // (the service replays the tail on reconnect, so the words are
        // 'reconnecting', truthfully, not 'lost'). After the first the
        // retries are quiet; the heartbeat already says quiet-not-gone.
        if (backoff === 500) {
          console.error('  [oc] event stream dropped: ' + e);
          oc.onStreamDropped();
        }
        await new Promise(r => setTimeout(r, backoff));
        backoff = Math.min(8000, backoff * 2);
      }
    }
  }
}
