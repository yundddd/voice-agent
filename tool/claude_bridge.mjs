// Voice-turn bridge: turns one long-lived `claude -p --input-format
// stream-json` process into an HTTP+SSE endpoint the voice agent can talk
// to over the LAN/Tailscale. Verified against claude 2.1.296 streaming
// stdin multi-turn (context persists between POSTs; each turn ends with a
// `result` event; `session_id` is stable and resume-able).
//
//   node tool/claude_bridge.mjs --dir ~/some-project --token SECRET
//
// Endpoints (all except /health require ?token=):
//   POST /talk   body: plain text utterance -> SSE stream of voice events
//                (event: say / tool / progress / done / error). While the
//                model generates, a `tool {name:"tokens"}` line arrives
//                every ~0.8 s of active generation (and immediately
//                whenever a message closes and the figure goes exact):
//                "thinking · 1.2k out · 21k in" — live output-token
//                progress for the phone's spinner (counted from
//                --include-partial-messages deltas at ~4 chars/token,
//                corrected to the CLI's exact usage as each message
//                closes), carrying numeric {out,in,kind} fields beside
//                the display string so the phone can grow the counter
//                between relays at the rate the relays taught it. A
//                `context` event {in,window} also arrives at
//                every API call start and after each turn: live context
//                consumption plus the model's window (same numbers
//                snapshot into /health as `context`, for turns the phone
//                never heard). It ALSO arrives early and often as a
//                PREVIEW {in,window,preview:true}: at turn start (last
//                turn's exact context + the new utterance's size) and on
//                every fresh tool_result (its text weight at ~4
//                chars/token, images flat) — so the phone's in-count
//                grows while the model is still READING, not only once
//                message_start proves it. Exact frames always overrule
//                previews; /health stores exact figures only (and /new
//                drops the snapshot so the bar goes blank with the
//                chat). A body
//                starting with / is written to stdin as PLAIN-STRING
//                content, so the CLI executes it as a real slash command
//                (block-array content would just feed it to the model —
//                verified on 2.1.296); /compact emits a system
//                compact_boundary, relayed here as `tool compact`.
//                Detaching (closing the SSE mid-turn) does NOT stop the
//                harness: the turn goes BACKGROUND — it keeps working,
//                its output is dropped, and it still ends properly. The
//                next /talk while a background turn runs is QUEUED behind
//                it (a `tool queued` event says which flavour you got):
//                an open long-running tool is left to finish (Claude Code
//                backgrounding), a mere thinking turn is cut short with
//                an in-band interrupt so your prompt starts seconds
//                later — unless the queue came
//                with ?interrupt=0 (the push-to-talk slide-right polite
//                flavour): then the turn in flight is left to finish
//                naturally and the queue flushes on its `result`. /stop hard-cuts an
//                open turn either way, and flushes the queue on its
//                result. None of that queuing is dead air on the phone:
//                the app speaks `tool` events as they arrive (each step
//                start), acknowledges `tool queued` out loud, and pulses
//                a still-working heartbeat through silent steps — the
//                Narrate switch on the app's Bridge screen (see
//                BridgePrefs.narrate).
//   POST /stop   interrupt the OPEN turn (attached or backgrounded) via
//                the CLI's control protocol; context survives, the
//                PROCESS stays alive. No-op while idle.
//   POST /new    start a fresh session (kills + respawns claude, clears
//                background turn and queued prompt)
//   GET  /health liveness + claude up? + turnOpen / backgrounded / queued
//                + context (last known tokens-in-context and the model's
//                window, snapshotted at every result)
//
// Latency note: the upstream proxy re-reads the entire conversation on
// every request (prompt caching is not in play there — cache_read is
// verifiably always 0), so context size IS per-utterance latency. The
// bridge deliberately does NOT auto-compact: /new and /compact stay
// the user's call (the app shows both as chips; the context bar in the
// app makes the size visible while you decide).
//
// Voice events are derived from the raw stream-json: assistant text
// arrives as it closes (no token deltas — the TTS wants whole sentences),
// tool_use becomes `tool` progress lines, `result` becomes `done`.
import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 ? argv[i + 1] : dflt;
};
const dir = arg('dir', process.cwd());
const token = arg('token', process.env.BRIDGE_TOKEN);
const claudeBin = arg('claude', join(homedir(), '.local/bin/claude'));
const port = Number(arg('port', 8732));
// Voice-companion behaviour: spoken answers only. Keeps the TTS honest.
const sysPrompt =
  arg('system', 'You are a hands-free voice assistant driving a dev machine. ' +
      'Answer in one to three short spoken sentences. Never use markdown, ' +
      'code blocks, bullet lists, or emoji: say file paths and numbers in ' +
      'plain words. Do exactly what is asked, then stop.')
  + ' While working, narrate each tool step in one very short sentence.';
// Voice can't answer a permission prompt, and raw stream-json input has no
// host to answer it either - so under anything stricter, prompt-worthy
// tools (WebFetch et al.) get silently DENIED and the answer comes back
// "I can't". bypassPermissions approves everything; explicit deny rules
// (like this user's WebSearch) still win under bypass, verified on
// 2.1.296. Tighten later with --permission-mode acceptEdits (edits+bash
// free, network tools denied) or dontAsk (locked-down) if the voice ever
// stops being the only trigger.
const permMode = arg('permission-mode', 'bypassPermissions');
// NOTE on the model behind this bridge: the upstream proxy re-reads the
// WHOLE conversation as input on every request (observed
// cache_read_input_tokens = 0 always — Anthropic-style prompt caching
// is not in play). Context size therefore translates one-to-one into
// per-utterance latency: a 128k-token chat pays ~10 s even for "hello",
// a 30k chat ~2.5 s. The bridge does not force this on the session:
// /new and /compact stay the user's manual levers (the app shows the
// chip; the context bar right above the talk button shows the number
// that matters).

// -- claude child process: one per /new, kept alive across /talk ----------
let child = null;       // claude process
let childDead = true;   // needs respawn?
let sessionId = null;   // for --resume after a bridge restart
const sidFile = join(dir, '.claude_bridge_session');
let curRes = null;      // { res, keep, turnStart } — the ATTACHED (heard) turn
let turnOpen = false;   // a claude turn is in flight, attached or backgrounded
let pending = null;     // { res, text, keep } — prompt queued behind a background turn
// Events a detached turn produced while NOBODY was listening. The phone's
// stream can die while the app is hidden (Android process death, an OS-
// dropped socket): the turn then runs unheard to its result, and without
// this buffer its entire output was dropped on the floor — the phone came
// back to nothing. An attaching client (GET /attach) replays these first.
const backlog = [];
const BACKLOG_CAP = 200;
let turnStartAt = 0;    // when the open turn began (survives a detach: the
                        // replay-timestamp guards read this, not curRes)
// tool_use ids still without tool_result in the open turn. This is the
// evidence that decides what a new /talk does while a backgrounded turn
// runs: an open tool means "genuinely working — queue mine behind it and
// let the tool finish" (Claude Code backgrounding); none means "it is
// only thinking — an in-band interrupt cuts that (the process survives),
// my prompt starts in a heartbeat".
const openTools = new Set();
// ── Live token tally (the TUI's "thinking · N tokens" progress) ──
// With --include-partial-messages the CLI streams `stream_event`
// wrapper messages: message_start carries this call's input tokens
// (context consumed), content_block_delta carries the growing text /
// thinking / tool-input characters, and message_delta closes a message
// with its EXACT output_tokens. Between those bookends we estimate at
// Claude Code's own ~4 chars/token. Aggregates are per harness turn
// (reset by beginTurn) and relayed as `tool {name:tokens}` every ~0.8 s
// while deltas flow (plus one exact-settling frame whenever a message
// closes) — the phone paints them on the spinner and grows the number
// locally between relays.
let tokIn = 0;        // last message_start input (incl. cache reads)
let tokOutExact = 0;  // exact output tokens (message_deltas, summed)
let tokLastMsgOut = 0; // output tokens of the most recent message (for
// the post-turn context figure: the next prompt carries the FULL history,
// so last call's input + last message's output IS tomorrow's context)
let tokChars = 0;     // delta chars since the last exact figure
let tokKind = '';     // 'thinking' | 'answering' | 'calling X'
let tokSentAt = 0;    // relay throttle clock
// Context consumption (the bar above the talk button): the CLI reports
// the model's contextWindow in every `result` (modelUsage) and this
// call's input tokens in every `message_start`; the `result` usage is
// the authoritative post-turn figure and gets snapshotted here so
// /health can answer even for turns the phone never attached to.
let ctxWindow = 0; // model context window (0 until a result names it)
let lastCtx = {'in': 0, 'window': 0}; // {in, window} snapshot for /health
// ── In-token PREVIEW (why the phone was dead air over a big read) ──
// The API only reports a call's input tokens in its `message_start` —
// which arrives AFTER the server has taken the whole prompt in (tens of
// seconds of prefill on a cache miss, and the CLI live log screaming
// about 100k input tokens while the phone's box said "Asking the
// bridge…" with nothing to show). The bridge cannot know the exact
// figure before the API says so, but it can carry the best number it
// DOES have and grow it as it watches the turn: the previous turn's
// authoritative `lastCtx.in` (exact — that IS what the next call
// starts from), plus ~tokens/4 of the fresh user text, plus ~tokens/4
// of every tool_result's text blocks (images counted at a flat
// ~1600-token vision allowance, not their base64 byte count, or a
// screenshot would read as 30k tokens) relayed the moment the wrapper
// crosses the stream. Frame shape is the same `context` event with
// `preview: true`, so an app can style estimates differently if it
// cares. The next `message_start` (exact, incl. server-side
// compaction) or the turn's `result` always overrules a preview; so
// does /health, which only ever stores exact figures.
let estIn = 0;      // preview tally in force right now
let estSentIn = 0;  // what we last relayed (delta-gate for relays)
// Rough token count of stream-json content (string or block array):
// text at Claude Code's own ~4 chars/token, images flat (a base64
// screenshot's 150 KB is NOT 37k tokens of reading).
const estTokens = (content) => {
  if (typeof content === 'string') return Math.ceil(content.length / 4);
  if (!Array.isArray(content)) return 0;
  let n = 0;
  for (const b of content) {
    if (!b || typeof b !== 'object') continue;
    if (b.type === 'image') { n += 1600; continue; }
    n += estTokens(b.content) + (typeof b.text === 'string' ? Math.ceil(b.text.length / 4) : 0)
       + (typeof b.thinking === 'string' ? Math.ceil(b.thinking.length / 4) : 0);
  }
  return n;
};
// Relay the preview (when attached and it moved the needle) — one
// `context` frame per growth step, not per byte.
const ctxPreviewFrame = () =>
  sse(curRes.res, 'context', { in: estIn, window: ctxWindow, preview: true });
const relayEst = (dir) => {
  estIn = Math.max(0, estIn + dir);
  if (curRes && estIn > 0 && Math.abs(estIn - estSentIn) >= 300) {
    estSentIn = estIn;
    ctxPreviewFrame();
  }
};
const fmtTok = (n) => n < 1000 ? `${n}`
  : n < 1e6 ? `${(n / 1000).toFixed(n < 10000 ? 1 : 0)}k`
  : `${(n / 1e6).toFixed(1)}M`;
const sse = (res, ev, data) =>
  res.write(`event: ${ev}\ndata: ${JSON.stringify(data)}\n\n`);
// Relay a turn event to whoever is listening — the attached client live,
// or the backlog for a future /attach. Transient frames (the ~0.8 s token
// tally, the ctx preview) stay live-only: a reattaching phone re-derives
// them, and a backlog of counters is noise, not memory.
const relay = (ev, data) => {
  if (curRes) { sse(curRes.res, ev, data); return; }
  backlog.push({ ev, data });
  if (backlog.length > BACKLOG_CAP) backlog.shift();
  console.error(`  [backlog] ${ev} (n=${backlog.length})`);
};
// The wire shape of the spinner's live counter: a display string (for
// anything that only shows text) plus numeric fields so the phone can
// paint the exact number AND keep it growing between relays. out is
// tokens-so-far this turn (estimate, or exact after a message closed),
// in is this API call's context consumption, kind is what the model is
// doing right now ('thinking' | 'answering' | 'calling X' | '').
const tokFrame = (out) => ({
  name: 'tokens',
  detail: (tokKind ? tokKind + ' · ' : '')
    + `${fmtTok(Math.round(out))} out · ${fmtTok(tokIn)} in`,
  out: Math.round(out), in: tokIn, kind: tokKind,
});

function spawnClaude(resume) {
  const args = ['-p', '--input-format', 'stream-json',
    '--output-format', 'stream-json', '--verbose',
    // Live token progress for the spinner (see the stream_event branch of
    // handleEvent): partial message chunks as they arrive.
    '--include-partial-messages',
    '--permission-mode', permMode,
    '--append-system-prompt', sysPrompt];
  if (resume) args.push('--resume', resume);
  child = spawn(claudeBin, args, { cwd: dir, env: process.env });
  childDead = false;
  let lineBuf = '';
  child.stdout.on('data', (b) => {
    lineBuf += b;
    let i;
    while ((i = lineBuf.indexOf('\n')) >= 0) {
      const line = lineBuf.slice(0, i).trim();
      lineBuf = lineBuf.slice(i + 1);
      if (line.startsWith('{')) handleEvent(line);
    }
  });
  child.stderr.on('data', (b) => process.stderr.write(`[claude] ${b}`));
  child.on('exit', () => {
    childDead = true;
    // No result event is ever coming for the open turn: free the state
    // machine and let any queued prompt through (beginTurn respawns and
    // --resumes on its own).
    turnOpen = false;
    openTools.clear();
    relay('error', { error: 'claude exited' });
    if (curRes) endTurn();
    flushPending();
  });
}

function handleEvent(line) {
  const m = JSON.parse(line);
  if (m.type !== 'stream_event') { // deltas are a firehose: keep the log legible
    console.error(`EVT ${m.type}/${m.subtype ?? '-'} len=${line.length}`);
  }
  if (m.session_id) sessionId = m.session_id;
  if (m.type === 'stream_event') {
    const e = m.event ?? {};
    if (e.type === 'message_start') {
      const u = e.message?.usage ?? {};
      tokIn = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0)
            + (u.cache_creation_input_tokens ?? 0);
      // Live context consumption as the API call begins (window may be
      // 0 = still unknown until the first result names it; the bar just
      // shows tokens with no fill). The exact number also ends any
      // preview run: the estimate grows from here on, not from there.
      estIn = tokIn; estSentIn = tokIn;
      relay('context', { in: tokIn, window: ctxWindow });
    } else if (e.type === 'content_block_start') {
      const b = e.content_block ?? {};
      tokKind = b.type === 'thinking' ? 'thinking'
        : b.type === 'tool_use' ? `calling ${b.name ?? 'tool'}`
        : b.type === 'text' ? 'answering' : tokKind;
    } else if (e.type === 'content_block_delta') {
      const d = e.delta ?? {};
      tokChars += (d.text ?? d.thinking ?? d.partial_json ?? '').length;
    } else if (e.type === 'message_delta') {
      const o = e.usage?.output_tokens;
      if (o) {
        // The estimate just went exact — settle the phone's counter NOW
        // instead of letting it drift on estimates for another second:
        // one extra frame per closed message is nothing on the wire, and
        // it is the number the app's local growth will be judged against.
        tokOutExact += o; tokLastMsgOut = o; tokChars = 0;
        if (curRes) {
          tokSentAt = Date.now();
          sse(curRes.res, 'tool', tokFrame(tokOutExact));
        }
      }
    }
    // One tally line per ~0.8 s of ACTIVE generation, only while someone
    // is listening: no deltas flowing (waiting, running a tool) means
    // no relay, so the last real `tool` line — "Bash npm test" — keeps
    // the spinner label instead of a frozen counter overriding it. A
    // backgrounded turn keeps counting (the counters ride on for
    // whoever attaches next) but relays nothing. Between relays the
    // phone extrapolates at the rate its own consecutive relays taught
    // it, so the displayed number grows smoothly, not in 2-second jumps.
    if (curRes && tokChars && Date.now() - tokSentAt >= 800) {
      tokSentAt = Date.now();
      sse(curRes.res, 'tool', tokFrame(tokOutExact + Math.floor(tokChars / 4)));
    }
    return;
  }
  // Tool-lifecycle bookkeeping runs BEFORE any listener gate: a
  // backgrounded (detached) turn still opens and closes tools, and the
  // open count is what lets a later /talk decide queue-vs-interrupt.
  if (m.type === 'assistant' || m.type === 'user') {
    const content = Array.isArray(m.message?.content) ? m.message.content : [];
    for (const c of content) {
      if (c.type === 'tool_use' && c.id) openTools.add(c.id);
      else if (c.type === 'tool_result' && c.tool_use_id) openTools.delete(c.tool_use_id);
    }
    // A tool output is the next call's newest read: preview its weight
    // the moment it crosses the stream, so the bar grows WHILE the
    // model chokes on a 40 KB test log instead of 20 s later at that
    // call's message_start. Replays from a --resume (stale timestamps)
    // are history, not fresh weight — same guard as the say path.
    if (m.type === 'user') {
      const replay = m.timestamp && turnStartAt &&
        Date.parse(m.timestamp) < turnStartAt;
      if (!replay) {
        for (const c of content) {
          if (c.type === 'tool_result') relayEst(estTokens(c.content));
        }
      }
    }
  }
  if (m.type === 'result') {
    // The turn's last word — processed even when no one is listening, so
    // backgrounded turns end properly: free the state machine, persist the
    // session id, hand the attached client its done (if it stayed), and
    // give the floor to a queued prompt.
    turnOpen = false;
    openTools.clear();
    if (sessionId) { try { writeFileSync(sidFile, sessionId); } catch {} }
    // Post-turn context snapshot: the LAST API call's input already
    // carries the whole history (earlier outputs included), so the next
    // prompt's size is that input plus the final message's output. The
    // stream counters saw exactly those numbers; without partial
    // messages, fall back to the result's own usage (single-call shape).
    const u = m.usage ?? {};
    const histIn = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0)
                 + (u.cache_creation_input_tokens ?? 0);
    const used = tokIn ? tokIn + tokLastMsgOut
                       : histIn + (u.output_tokens ?? 0);
    const win = Object.values(m.modelUsage ?? {})
        .reduce((a, x) => Math.max(a, x?.contextWindow ?? 0), 0);
    if (win) ctxWindow = win;
    if (used) lastCtx = { in: used, window: ctxWindow };
    if (lastCtx.in) {
      relay('context', { in: lastCtx.in, window: ctxWindow });
    }
    relay('done', { costUsd: m.total_cost_usd, isError: m.is_error });
    if (curRes) endTurn();
    flushPending();
    return;
  }
  // Transcript replay: after --resume (or a child respawn) claude re-emits
  // earlier turns' messages with their ORIGINAL timestamps. Without this
  // filter every resume re-speaks the whole conversation history — heard as
  // "the same response, over and over". Fresh events carry now-stamps, so
  // anything older than this turn's start is history, not an answer.
  if (m.type === 'assistant' && m.timestamp && turnStartAt &&
      Date.parse(m.timestamp) < turnStartAt) {
    console.error('  (replay, skipped)');
    return;
  }
  // No attached listener: this turn runs BACKGROUND. The process keeps
  // working (that is the point); its output now lands in the backlog —
  // a reattaching phone replays it instead of finding nothing ever
  // happened — until the `result` above clears the way for a queued prompt.
  switch (m.type) {
    case 'assistant': {
      // Snapshot handling. The proxy re-emits the growing message but NOT
      // necessarily as an appending prefix: under thinking mode we observed
      // event 1 = [thinking] and event 2 = [text] under the SAME message id,
      // content *replaced* (both length 1). An index watermark therefore
      // skipped the text block (seen=1, nothing past it) and long answers
      // came back with `done` but no `say` — the phone's "the harness ran,
      // but had nothing to say". So: scan every block of every snapshot and
      // let the per-turn exact-text set be the single source of truth —
      // it catches prefix-regrow repeats, re-UUID replays, and same-tuple
      // re-emissions alike. Tools dedupe on their unique c.id (tool_use
      // ids are stable across snapshots). History replays from --resume
      // never reach here at all: the timestamp guard above eats them.
      const content = m.message?.content ?? [];
      for (const c of content) {
        if (c.type === 'text' && c.text.trim()) {
          const t = c.text.trim();
          // Within one turn, relay each exact text once. Identical
          // consecutive progress lines lose their second copy — right
          // trade for audio.
          if (spokenTexts.has(t)) continue;
          spokenTexts.add(t);
          console.error(`  -> say "${t.slice(0, 40)}"`);
          relay('say', { text: t });
        }
        if (c.type === 'tool_use' && c.id && !spokenTools.has(c.id)) {
          spokenTools.add(c.id);
          relay('tool', { name: c.name, detail: summarize(c) });
        }
      }
      break;
    }
    case 'system':
      // The compaction proof the /compact chip listens for: emitted when
      // the CLI finishes condensing the transcript (silent otherwise —
      // no assistant message, empty result text), so relay it as live
      // tool-style progress instead of dead air.
      if (m.subtype === 'compact_boundary') {
        console.error('  -> tool compact');
        relay('tool', {
          name: 'compact',
          detail: 'condensed conversation summary',
        });
      }
      break;
  }
}
function endKeep(t) {
  if (t && t.keep) clearInterval(t.keep);
}
// End the ATTACHED *view* of a turn. This deliberately does NOT clear
// turnOpen: when the phone hangs up mid-turn the turn itself keeps
// running as a BACKGROUND turn (the harness finishes its work, the
// output simply goes nowhere); when the response truly finished, the
// `result` handler already cleared turnOpen before closing us. The dedupe
// sets belong to the turn, not to this view, so they survive a detach and
// are cleared by the next beginTurn.
function endTurn() {
  if (!curRes) return;
  endKeep(curRes);
  const r = curRes.res;
  curRes = null;
  r.end();
}
function writeUserMsg(text) {
  // Slash commands must arrive as PLAIN STRING content: the CLI only runs
  // them as commands then — a block array like [{text:"/compact"}] goes to
  // the model as literal text (it just rambles about the word), verified on
  // 2.1.296. Everything else keeps the structured shape.
  const msg = text.startsWith('/')
      ? { type: 'user', message: { role: 'user', content: text } }
      : { type: 'user',
          message: { role: 'user',
            content: [{ type: 'text', text }] } };
  child.stdin.write(JSON.stringify(msg) + '\n');
}
function summarize(tool) {
  const i = tool.input ?? {};
  return String(i.command ?? i.file_path ?? i.pattern ?? i.url ?? '').slice(0, 80);
}
// In-band turn interrupt via the CLI's control protocol (verified live on
// 2.1.296): a control_request on stdin cancels the OPEN turn — its
// `result` still arrives (is_error: true) and the process keeps running.
// This replaces SIGINT, which in headless -p mode kills the WHOLE process:
// the next utterance then respawns with --resume, the CLI rebuilds the
// conversation from the transcript under a different request prefix, the
// proxy's prompt cache misses, and every turn pays a full cold prefill.
function interruptTurn() {
  if (!child || childDead) return;
  try {
    child.stdin.write(JSON.stringify({
      type: 'control_request', request_id: randomUUID(),
      request: { subtype: 'interrupt' },
    }) + '\n');
  } catch {}
}
// Attach `res` as the heard view of a brand-new turn and release the
// prompt to claude. The 15 s keep-alive pinger belongs to the turn object
// now: a backgrounded turn and whatever replaces it each carry their own.
function beginTurn(text, res, keep) {
  if (childDead) spawnClaude(sessionId); // resume our voice conversation if any
  turnStartAt = Date.now() - 5000; // slack: clock skew
  curRes = { res, keep, turnStart: turnStartAt };
  backlog.length = 0; // a new turn: the old one's buffered frames are stale
  turnOpen = true;
  spokenTools.clear(); // every message lives inside one turn
  spokenTexts.clear();
  tokIn = tokOutExact = tokLastMsgOut = tokChars = tokSentAt = 0; // fresh token tally
  tokKind = '';
  // Preview the coming call's size BEFORE the first message_start (which
  // only lands after the server finishes reading): last turn's exact
  // context + this utterance's own tokens, relayed as the turn's very
  // first frame. A brand-new conversation has no baseline to preview
  // from (0 = nothing honest to say yet; the first message_start will).
  estIn = lastCtx.in > 0 ? lastCtx.in + estTokens(text) : 0;
  estSentIn = estIn;
  if (estIn > 0) ctxPreviewFrame();
  writeUserMsg(text);
}
// A queued prompt got its slot: hand over the floor the moment the
// backgrounded turn released it (its `result` event, or a process death
// — beginTurn respawns with --resume).
function flushPending() {
  if (!pending) return;
  const p = pending;
  pending = null;
  if (p.res.writableEnded) { endKeep(p); return; } // phone abandoned its queued prompt
  beginTurn(p.text, p.res, p.keep); // pinger rides on into the new turn
}
// [the phone's ear] is pressed to it) or only a BACKGROUNDED turn is
// open. Either way a new prompt never waits on it — it is QUEUED at the
// front (latest wins; the prior pending's response is ended). The
// `interrupt` flag decides what happens to the turn in flight: true (the
// default — typed text, conversation barge-in, PTT slide-UP) cuts a mere
// thinking turn with an in-band interrupt — nothing but the model holding
// it, the process never dies (no --resume, no cold prefill on the next
// turn) — so its `result` flushes the queue in a heartbeat; false (PTT
// slide-right, the polite queue) lets the in-flight turn run to its
// natural end first. Either way a long-running OPEN tool is left to
// finish: letting it complete is the entire point of backgrounding, and
// /stop still hard-stops it.
function talk(text, res, interrupt = true) {
  // SSE comment every 15 s: a 3-minute gradle build emits nothing, and
  // idle-detection on the link (NAT, tailscale, Dart clients) should not
  // get creative with a stream that is merely thinking.
  const keep = setInterval(() => {
    try { res.write(': ping\n\n'); } catch {}
  }, 15000);
  // NOTE: must listen on the RESPONSE, not the request: a POST's req
  // 'close' fires the instant its body is read, which would end the
  // stream before claude ever answers. res 'close' = client hung up or
  // response finished.
  res.on('close', () => {
    if (curRes && curRes.res === res) { console.error('  (client detached — turn runs background)'); endTurn(); }
    else if (pending && pending.res === res) { endKeep(pending); pending = null; }
  });
  if (curRes || turnOpen) {
    // Something is in flight — still HEARD (curRes: the phone never let
    // go, e.g. a second client, or the detach's 'close' hasn't landed
    // yet) or backgrounded (turnOpen). Park this prompt at the front of
    // the queue; whichever event frees the floor (the attached turn's
    // `result` closes its stream, or the backgrounded one's) flushes it.
    if (pending) { endKeep(pending); if (!pending.res.writableEnded) pending.res.end(); }
    pending = { res, text, keep };
    sse(res, 'tool', {
      name: 'queued',
      detail: openTools.size
        ? (curRes ? 'the current turn' : 'the background turn')
          + ' is running a tool; your message goes next'
        : interrupt
          ? 'cutting the thinking turn short; your message goes next'
          : 'finishing the current turn; your message goes next',
    });
    if (interrupt && !openTools.size) interruptTurn();
    return;
  }
  beginTurn(text, res, keep);
}
// tool_use ids already relayed this turn (tool_use ids are unique per
// call and stable across snapshots of the same message). Cleared at
// beginTurn: a turn is the natural lifecycle here and it keeps the set
// from growing forever.
const spokenTools = new Set();
// Exact say texts already relayed this turn (catches replays that arrive
// under fresh message ids, e.g. a resumed transcript). Same lifecycle.
const spokenTexts = new Set();

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname !== '/health' && url.searchParams.get('token') !== token) {
    res.writeHead(401).end('nope\n'); return;
  }
  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: true, claudeUp: !childDead, sessionId,
      turnOpen, queued: !!pending,
      backgrounded: turnOpen && !curRes,
      // A turn (or its tail) ran with nobody listening: /attach replays
      // this many buffered events, even after the turn itself ended.
      missed: backlog.length,
      // Last known context consumption and the model's window (0s until
      // the first result names them): lets a phone that missed the live
      // events still fill its context bar.
      context: lastCtx,
    }));
    return;
  }
  if (req.method === 'GET' && url.pathname === '/attach') {
    // The phone's ear died mid-turn (Android killed the app, the OS
    // dropped the socket): replay everything that happened unheard, then
    // go live. Two shapes: the turn is still open — the attacher becomes
    // its heard view (closing the connection backgrounds it again); the
    // turn already ended — the buffered tail (done included) replays and
    // the stream closes, a complete delivery either way. Cancelling the
    // GET is harmless: worst case the turn detaches and keeps working.
    res.writeHead(200, { 'content-type': 'text/event-stream',
      'cache-control': 'no-cache', connection: 'keep-alive' });
    const keep = setInterval(() => {
      try { res.write(': ping\n\n'); } catch {}
    }, 15000);
    for (const { ev, data } of backlog) sse(res, ev, data);
    backlog.length = 0;
    if (!turnOpen) { clearInterval(keep); res.end(); return; }
    curRes = { res, keep, turnStart: turnStartAt };
    res.on('close', () => {
      if (curRes && curRes.res === res) endTurn(); // detach → background it
    });
    return;
  }
  if (req.method !== 'POST') { res.writeHead(405).end(); return; }
  let body = '';
  req.on('data', (c) => body += c);
  req.on('end', () => {
    if (url.pathname === '/talk') {
      res.writeHead(200, { 'content-type': 'text/event-stream',
        'cache-control': 'no-cache', connection: 'keep-alive' });
      // ?interrupt=0 = the polite queue (PTT slide-right): let the turn
      // in flight finish instead of interrupting a thinking-only one.
      talk(body.trim(), res, url.searchParams.get('interrupt') !== '0');
    } else if (url.pathname === '/stop') {
      // Hard stop (tap-Stop): an in-band interrupt ends the turn whether
      // the phone is still listening to it or backgrounded it. Context
      // survives, the PROCESS survives (no kill → no --resume → no cold
      // prefill), and a queued prompt flushes on the resulting `result`
      // event. Only fires while a turn is OPEN.
      if (turnOpen) interruptTurn();
      res.writeHead(200).end('ok\n');
    } else if (url.pathname === '/new') {
      try { rmSync(sidFile); } catch {}
      sessionId = null;
      turnOpen = false;
      openTools.clear();
      // The dead conversation's size is not the fresh one's: drop the
      // context snapshot (and any preview run) so the bar goes blank
      // instead of wearing old numbers. /health reports in:0 from now
      // on until the new session's first message_start proves itself.
      lastCtx = { in: 0, window: ctxWindow };
      estIn = estSentIn = 0;
      if (pending) { endKeep(pending); if (!pending.res.writableEnded) pending.res.end(); pending = null; }
      endTurn();
      child?.kill('SIGTERM'); child = null; childDead = true;
      res.writeHead(200).end('ok\n');
    } else res.writeHead(404).end();
  });
});
// no claude yet until first spawn
if (!existsSync(claudeBin)) { console.error(`no claude at ${claudeBin}`); process.exit(1); }
if (!token) { console.error('set --token or BRIDGE_TOKEN'); process.exit(1); }
try { sessionId = readFileSync(sidFile, 'utf8').trim(); } catch {}
spawnClaude(sessionId || undefined);
server.listen(port, '0.0.0.0', () => console.log(`voice bridge on :${port} dir=${dir} sid=${sessionId ?? 'new'}`));
