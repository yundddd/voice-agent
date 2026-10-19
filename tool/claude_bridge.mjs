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
//                (event: say / tool / progress / done / error). Progress
//                is designed never to read as "ignored": the turn's very
//                first frame is a `tool {name:"tokens", kind:"thinking"}`
//                tally (out 0, in = best known: exact message_start once
//                proven, else the running preview — the `in` field falls
//                back to the estimate so the spinner line always carries
//                the number that matters), so the phone's line flips
//                from "Asking the bridge…" to "thinking" within one RTT.
//                While the model generates, the tally line arrives
//                every ~0.8 s of active generation (and immediately
//                whenever a message closes and the figure goes exact):
//                "thinking · 1.2k out · 21k in" — live output-token
//                progress for the phone's spinner (counted from
//                --include-partial-messages deltas at ~4 chars/token,
//                corrected to the CLI's exact usage as each message
//                closes), carrying numeric {out,in,kind} fields beside
//                the display string so the phone can grow the counter
//                between relays at the rate the relays taught it — and,
//                while kind is 'thinking', a one-line `thought`: a
//                rolling ~160-char tail of the model's live thinking
//                text, so the phone shows WHAT it is thinking instead
//                of only claiming that it is. If the
//                HEARD view of a model-side (no tool open) turn relays
//                nothing for --tok-heartbeat ms (default 5000; 0 = off),
//                the keep-pinger pushes the tally anyway marked
//                {quiet:true} — "thinking · 0 out · 21k in · no deltas
//                from upstream" — so a proxy that streams no partials
//                (or buffers SSE entirely, OpenAI-style) still shows an
//                ALIVE turn instead of a frozen line: quiet frames are
//                strictly the no-progress signal, since a streaming
//                turn trips the 0.8 s relays before the silence gate.
//                Every turn also logs a stderr `[census]` of what the
//                CLI actually delivered under --include-partial-messages
//                (first partial event, per-kind tallies, delta chars,
//                usage tokens, and a verdict: LIVE DELTAS / USAGE ONLY /
//                NO LIVE EVENTS) — so "why does the app show no
//                progress" is answered from the wire, not by guessing
//                what the proxy does with streaming. A
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
//                naturally and the queue flushes on its `result`.
//                ?cuttool=1 (behaviour 2, the app's Queue button) is the
//                middle flavour: polite while the agent merely thinks,
//                but a RUNNING tool is backgrounded for this prompt —
//                its late result relays a `tool finished` frame, the
//                phone banner's retirement word. /stop hard-cuts an
//                open turn either way, and flushes the queue on its
//                result. Queuing goes quiet on the phone by default
//                (status text only): the app speaks `tool` events as
//                they arrive (each step start), acknowledges `tool
//                queued` out loud, and pulses a still-working heartbeat
//                through silent steps only with the Narrate switch on
//                the app's Bridge screen — off from the factory (see
//                BridgePrefs.narrate). And a queued prompt never dies
//                with its stream (+104): when the response socket closes
//                while queued (quiet-wire watchdog, lifecycle HIDE,
//                Android cutting it), the prompt converts to the poll
//                transport and runs on the ring anyway — its turn lands
//                in the /attach replay for the phone's return. The old
//                abandon branch ate the utterance (field report: 'the
//                queued message was lost'); after the `queued` notice
//                the turn is owed, whatever the transport does. And when
//                the turn in flight dies to make room for that queued
//                prompt (+106), its `done` is NOT relayed — the phone
//                cut the turn itself, and a stray done landing on the
//                reattach view murders the fresh bubble (field report:
//                slide-up, then no updates at all). And the spinner
//                label during a tool pause is the COMMAND ITSELF, bare
//                (+107): the tool_use relay promotes its summary line
//                into the activity kind, so a long test reads 'Bash
//                flutter test · …' on the phone instead of 'Thinking…'
//                over a frozen counter.
//   POST /stop   interrupt the OPEN turn (attached or backgrounded) via
//                the CLI's control protocol; context survives, the
//                PROCESS stays alive. No-op while idle.
//   POST /new    start a fresh session (kills + respawns claude, clears
//                background turn and queued prompt)
//   GET  /health liveness + claude up? + turnOpen / backgrounded / queued
//                / detached (the cut-tool receipts still owed a
//                `finished`, + the agent's own run_in_background shells).
//                +133: a Bash tool_use with run_in_background is the
//                AGENT backgrounding work itself — the phone gets a
//                `tool backgrounded` frame (the bottom line names it,
//                no press involved), and when the CLI later speaks
//                UNPROMPTED to report that task, the bridge runs the
//                report as a proactive background turn: a `tool
//                finished` receipt at the moment it reads the output
//                (or at its result), the model's answer as ordinary
//                `say` frames, and the usual `done`. A /talk landing
//                during such a turn queues; /stop can cut it.
//                + context (last known tokens-in-context and the model's
//                window, snapshotted at every result) + appLog (the
//                phone-journal poller's peer / watermark / reachability)
//   ANY   /applog  The phone app's OWN event journal (lib/app_events.dart):
//                what the PHONE side did during a turn — lifecycle
//                callbacks, stream deaths, reattach verdicts. TWO
//                transports, one ingest path (same watermark, same
//                `[app HH:MM:SS.mmm]` stderr relay, so journalctl shows
//                both machines' views of one misbehaving turn either
//                way):
//                  GET  /applogs?since=N on this bridge proxies the
//                  phone live when it can be dialed (desktop/LAN
//                  peers), else answers from the server-side mirror of
//                  what the phone last PUSHED; source:'push'|'pull'
//                  says which. The bridge polls on
//                  --applog-interval (default 5000; 0 = off).
//                  POST /applog with an envelope body is the PUSH
//                  transport: phones dialed by nobody (Android
//                  tailscale refuses inbound; carrier NAT has no route
//                  at all) push their journal out instead — at-least-
//                  once, deduped by seq here. The pump distinguishes
//                  "refused to be dialed but pushes" (quiet, push mode)
//                  from "answered neither — frozen or killed?" (3
//                  strikes, logged once, recovery logged too).
//                Every app request carries ?logport= so a peer address
//                (the request's own source, same route the turn rides)
//                is always on file for the pull attempt. /health's
//                appLog block reports peer, watermark, mode (push /
//                pull / silent) and last push time.
//
// Latency note: context size IS per-utterance latency for THIS harness,
// but not for the reason first written here. The serving stack (sglang
// behind an Anthropic-compat translation proxy) HAS a working prefix
// (radix) cache, and cross-turn reuse IS attainable: controlled replays
// proved a byte-identical request HITS (0.33 s for a 46k prompt) even
// after 20 s gaps and with a foreign ~11k request landing every few
// seconds — a MISS can therefore only mean the request bytes changed
// early in the prompt. Captured turn bodies named the movers: the CLI's
// EXPERIMENTAL BETAS (a per-turn 400+retry over `thinking.display:
// "updates"`, and a history envelope the beta transcript-reload path
// re-renders from array to string mid-prompt, forking the radix at
// token ~1.5k). Both vanish under CLAUDE_CODE_DISABLE_EXPERIMENTAL_
// BETAS=1, which spawnClaude pins (see the comment there). What remains
// suspect per-turn is the harness's own environment-context collection
// (a git-status snapshot: this agent edits the repo it runs IN, so the
// snapshot legitimately churns between voice turns) — --dump-requests
// DIR captures the live child's real bodies so any future MISS is
// diffed, not argued. The compat layer reports cache_read=0
// structurally either way, so the [census] line's time-to-first-partial
// verdict is the measurement. Footnote: the hybrid linear-attention
// server caches only a few prefix branches (max_mamba_cache_size=10 on
// this launch), so a second concurrent LONG session can still evict
// this one's state between turns; and /compact pays one full re-prefill
// before cheapness returns. Practical rule: the context bar above the
// talk button shows the number that IS your latency; /new and /compact
// stay the user's manual levers.
//
// Voice events are derived from the raw stream-json: assistant text is
// spoken sentence by sentence off the live content_block_deltas (the
// first period lands in TTS mid-message), tool_use becomes `tool`
// progress lines, `result` becomes `done`. The un-said live tail of the
// answer rides the tally frames as `draft` so the chat window can paint
// the reply while it is still being written. On an upstream that sends
// no partials, both features fall back to the old block-close relay.
import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, appendFileSync, mkdirSync, readdirSync, existsSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { relaySentences as cutSentences, settleOwed, fmtTok } from './sentence_relay.mjs';


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
// The tool-step narration sentence is only appended with --narrate-steps:
// by default the harness answers the turn and goes silent — the model's
// own "now I'll run the tests" lines arrive as `say` events, which the
// phone ALWAYS speaks (the app's Narrate switch only gates the cleaner
// templated `tool`-event lines), so making them by default would put
// messy tool-call chatter back on the air no setting could turn off.
const sysPrompt =
  // +122's "work first, then speak" mandate was REVERTED the same day:
  // the listener wants sentences the moment they exist, tool gaps and
  // all — a pause between sentences is the voice thinking out loud, not
  // a fault. The fault was the next segment STOMPING the one on air
  // (seam events firing before the audio could have ended), and that
  // got fixed at the player, not in the prompt.
  arg('system', 'You are a hands-free voice assistant driving a dev machine. ' +
      'Answer in one to three short spoken sentences. Never use markdown, ' +
      'code blocks, bullet lists, or emoji: say file paths and numbers in ' +
      'plain words. Do exactly what is asked, then stop.') +
  (argv.includes('--narrate-steps')
    ? ' While working, narrate each tool step in one very short sentence.'
    : '');
// Voice can't answer a permission prompt, and raw stream-json input has no
// host to answer it either - so under anything stricter, prompt-worthy
// tools (WebFetch et al.) get silently DENIED and the answer comes back
// "I can't". bypassPermissions approves everything; explicit deny rules
// (like this user's WebSearch) still win under bypass, verified on
// 2.1.296. Tighten later with --permission-mode acceptEdits (edits+bash
// free, network tools denied) or dontAsk (locked-down) if the voice ever
// stops being the only trigger.
const permMode = arg('permission-mode', 'bypassPermissions');
// --dump-requests DIR: a transparency tap in front of THIS bridge's CLI
// child. When set, spawnClaude repoints the child at a local forwarding
// proxy via inline --settings (whose env block outranks the user's
// ~/.claude/settings.json — verified 2026-10-16, which is also why a
// plain env override does NOT work), the proxy records every body it
// relays to the real configured base URL, and streams the response
// through untouched (SSE included). A MANIFEST in the dump dir marks
// what the bridge wrote to stdin and when, so files pair with turns.
// Purpose: when the census says MISS, the two offending turn bodies are
// on disk and the diff names the volatile bytes — no more theorizing.
const dumpDir = arg('dump-requests', null);

// NOTE on the model behind this bridge: see the header latency note —
// request-byte stability, not server caprice, is what decides whether a
// turn pays its context's prefill; the [census] line's verdict plus
// --dump-requests turn that from folklore into measurement.

// -- claude child process: one per /new, kept alive across /talk ----------
let child = null;       // claude process
let childDead = true;   // needs respawn?
let sessionId = null;   // for --resume after a bridge restart
const sidFile = join(dir, '.claude_bridge_session');
let curRes = null;      // { res, keep, turnStart } — the ATTACHED (heard) turn
let turnOpen = false;   // a claude turn is in flight, attached or backgrounded
let proactiveTurn = false; // +133: this turn is the harness speaking
// UNPROMPTED — the completion report of a shell it backgrounded itself
// (Bash run_in_background). Nobody pressed anything; its `result` closes
// it like any other, and while it runs a fresh /talk queues politely.
const bgTools = new Map();    // tool_use ids launched run_in_background
const agentTasks = new Map(); // background task id -> {label, outPath}
let pending = null;     // { res, text, keep } — prompt queued behind a background turn
// Tool calls an interrupt (or a cuttool queue) orphaned: tool_use id →
// the step label the phone put on its banner. Their late tool_results
// relay a `tool finished` frame — the banner's retirement word — and
// /health counts these as `detached` so the phone knows a promise is
// still owed (and finds it honestly cleared when the process dies).
const detached = new Map();
// A cut tool's receipt, held until the flush explains the cut: while a
// prompt waits in `pending`, the killed tool's late tool_result lands
// BEFORE the turn's `result` (and with it flushPending's queued/started
// notices) — relaying it on the spot stamped 'Bash sleep 10 finished.'
// in the chat ABOVE the 'put into background' notice it referred to,
// and said FINISHED for a tool the cut itself had CANCELLED (field
// report: out of timestamp order, finished/cancelled/backgrounded all
// at once). Held frames go out at the flush, AFTER the disposition,
// with the honest verb: an error tool_result (Claude's own interrupt
// reply) pays as 'cancelled', never 'finished'.
const heldFinished = [];
// +106: the open turn was cut by interruptTurn to let a waiting prompt
// through — its `result` is then the phone's own doing, and the `done`
// relay skips it (see the result branch).
let cutForPrompt = false;
// Events a detached turn produced while NOBODY was listening. The phone's
// stream can die while the app is hidden (Android process death, an OS-
// dropped socket): the turn then runs unheard to its result, and without
// this buffer its entire output was dropped on the floor — the phone came
// back to nothing. An attaching client (GET /attach) replays these first.
const backlog = [];
const BACKLOG_CAP = 200;
let turnStartAt = 0;    // when the open turn began (survives a detach: the
                        // replay-timestamp guards read this, not curRes)
let turnBeganAt = 0;    // true begin (no replay-slack): the 'finished'
                        // receipt's duration reads this, not turnStartAt
// tool_use ids still without tool_result in the open turn. This is the
// evidence that decides what a new /talk does while a backgrounded turn
// runs: an open tool means "genuinely working — queue mine behind it and
// let the tool finish" (Claude Code backgrounding); none means "it is
// only thinking — an in-band interrupt cuts that (the process survives),
// my prompt starts in a heartbeat". Each id maps to its step label —
// the banner line an interrupt leaves in its wake (see `detached`).
const openTools = new Map();
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
let tokOutExact = 0;  // exact output tokens THIS TURN (per-message cumulative, pinned)
let tokMsgBase = 0;   // tokOutExact at the current message's start — message_delta's
                      // usage.output_tokens is a CUMULATIVE running total for its own
                      // message, so += double-counts the earlier part every time a
                      // call emits more than one delta (long thinking turns inflated
                      // the out-count until it 'matched the context'; field report
                      // 0.1.0+77). The number for a message is base + cumulative.
let tokLastMsgOut = 0; // output tokens of the most recent message (for
// the post-turn context figure: the next prompt carries the FULL history,
// so last call's input + last message's output IS tomorrow's context)
let tokChars = 0;     // delta chars since the last exact figure
let tokKind = '';     // 'thinking' | 'answering' | 'calling X'
// The tail of the model's live thinking text (extended thinking). The
// spinner's "thinking" word is only a CLAIM — the honest display is the
// thought itself, so the growing text rides the tally frame as
// `thought` (last ~160 chars, one line: the phone shows a rolling
// window, not the whole chain of thought). A rolling cap keeps the
// frame small no matter how long the model rambles.
let thinkBuf = '';    // last ~400 chars of thinking deltas
const thinkTail = (n) => thinkBuf.slice(-n).replace(/\s+/g, ' ').trim();
// The answer, spoken sentence by sentence instead of block by block:
// text deltas land in the live buffer below, and the first completed
// sentence is TTS-able the moment its period arrives — no waiting for
// the message to close. Buffer state is per live message, per block
// index; `spoken` is the un-relayed watermark (sentence relays AND the
// snapshot's remainder both advance it, so no text is ever said twice
// and none is dropped). The remainder logic in the assistant-snapshot
// path keeps the no-partials fallback exactly the old block-close
// behavior.
let curMsg = null;      // {blocks: {}, seq} for the LIVE message
let lastTextBlk = null; // newest live text block (the draft frame's view)
let lastTextOpen = false; // and whether it can still receive deltas
// The cutter itself moved to sentence_relay.mjs (unit-tested). This
// wrapper only supplies the ring/stdio side: one say frame per
// sentence, journalled by its first 40 chars.
function relaySentences(blk, {force = false} = {}) {
  cutSentences(blk, {
    force,
    emit: (t) => {
      console.error(`  -> say(live) "${t.slice(0, 40)}"`);
      relay('say', {text: t}); // +113: no pre-registration here — the
      // first copy must reach the backlog when the view is down; the
      // heard accounting happens INSIDE relay, on actual delivery.
    },
  });
}
// The un-said part of the live answer, as the draft field of the tally
// frames (mirrors how `thought` rides the thinking tail): the phone
// paints the reply while it is still being written. Rolling cap keeps
// the frame small no matter how long the answer runs.
const draftTail = (n) => lastTextBlk
  ? lastTextBlk.buf.slice(lastTextBlk.spoken).slice(-n).replace(/\s+/g, ' ').trim()
  : '';
let tokSentAt = 0;    // relay throttle clock
// Quiet-token heartbeat period: after this many ms with nothing relayed
// to the heard view (no deltas, no settles), the keep-pinger re-sends
// the tally marked `quiet:true` so the phone can tell "thinking, but
// this upstream gives no numbers" from "hung with nobody home". 0
// disables the quiet frames (pings only). --tok-heartbeat.
const HEARTBEAT_MS = Number(arg('tok-heartbeat', 5000));
// What the CLI ACTUALLY delivered under --include-partial-messages, one
// census per turn: the phone's live counter exists only if these event
// shapes do, and which shapes arrive is entirely the upstream proxy's
// decision. The census logs the first partial the moment it lands,
// tallies every kind, and pronounces the verdict at the `result` —
// "the app shows no progress" is answered from the bridge's own journal
// instead of by guessing what the proxy does with SSE.
let census = newCensus();
function newCensus() {
  // t0 = beginTurn clock: the gap to the first partial is the prefix
  // cache REPORT (sglang never tells this proxy its cached-token count —
  // usage.cache_read is structurally 0 here — so latency IS the
  // measurement: seconds-to-first-token ≈ context/prefill-throughput on
  // a miss, sub-second on a hit).
  return {t0: Date.now(), firstMs: 0, types: {}, deltaChars: 0,
          msgStarts: 0, msgDeltas: 0, usageOut: 0, sawFirst: false};
}
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
// fmtTok lives in sentence_relay.mjs (unit-tested; imported below).
// Every frame leaves stamped with the bridge's wall clock (`_ts`), so the
// phone can log how long a frame sat on the wire by the time it rendered:
// the render side subtracts the clock skew it calibrated from /health's
// own `now`. Replay frames are stamped at replay (the field means "when
// this crossed the wire", not "when the turn event happened").
// A comment line pads every frame past ~1.3 KB. Not aesthetics: on the
// Android tailscale client (tun1 over rmnet) a SMALL, ISOLATED packet
// gets coalesced into oblivion — measured: a tool frame sat 27 s
// (phone-logged `[wire+27316ms]`), surfacing only in the burst when the
// turn's next big write dragged it out, while dense generation streamed
// fine at any ping rate. Padding makes every frame a big write the
// batcher has to move now; frames cost ~1.3 KB apiece, a rounding error
// at our event rate.
const sse = (res, ev, data) => {
  // Stamp at first write, never again: /attach replay pushes the very
  // data objects the turn relayed hours ago, and re-stamping them with
  // NOW would erase the age the phone needs to tell a live reply from
  // an archaeological one.
  const body = JSON.stringify({...data, _ts: data._ts ?? Date.now()});
  const room = 1300 - body.length - ev.length - 6;
  res.write(`event: ${ev}\ndata: ${body}` +
    (room > 0 ? `\n: ${'p'.repeat(room)}\n` : '') + `\n\n`);
};
// Relay a turn event to whoever is listening — the attached client live,
// or the backlog for a future /attach. Transient frames (the ~0.8 s token
// tally, the ctx preview) stay live-only: a reattaching phone re-derives
// them, and a backlog of counters is noise, not memory.
// Monotonic event ring for the PULL transport (GET /poll): the cellular
// path holds server-initiated bytes for seconds (measured wire ages
// 8–14 s, frames surfacing only when the next big burst dragged them
// out) while the phone's own outbound POSTs land in milliseconds — that
// asymmetry IS the diagnosis, so a robust client pulls: every poll is an
// outbound request whose response the path cannot coalesce into
// silence. Every relayed event rides the ring with a sequence number IN
// ADDITION to the live SSE stream (both transports coexist); the poll
// cursor is each client's own reattach state.
const RING_CAP = 2000;
const ring = [];
// Seeded from the wall clock, NOT zero: a client's cursor survives our
// restart (the app kept polling a restarted bridge with a cursor of
// ~200 while the baby ring counted from 1 — forever ahead, forever
// empty, every event silently backlog-bound). An epoch seed makes any
// pre-restart cursor older than any post-restart event.
let ringSeq = Date.now();
// ── wire v2: identity ─────────────────────────────────────────────────
// Every relayed frame is stamped with a message id (_mid — ONE counter,
// so the ring copy, the backlog copy and every live view share it) and
// with the id of the turn that owns it (_turn). Turn ids are RESERVED
// at POST time, so a queue notice and the `started` marker of its
// prompt name the same future turn; `done` and `error` carry the id of
// the turn they close. The phone ACKS each _mid the moment it takes a
// frame (POST /heard) — the unheard backlog is then trimmed by proof of
// hearing, and no side ever infers from text, order or age again.
let msgSeq = Date.now();
let nextTurnId = Date.now();
let curTurnId = 0; // 0 = outside any turn
const relay = (ev, data) => {
  data._ts ??= Date.now();
  // ??=, never =: a re-relayed receipt (heldFinished rides two turns)
  // keeps the identity it was born with — one message, one id.
  data._mid ??= ++msgSeq;
  data._turn ??= curTurnId;
  ring.push({seq: ++ringSeq, ev, data});
  if (ring.length > RING_CAP) ring.splice(0, ring.length - RING_CAP);
  if (curRes) sse(curRes.res, ev, data);
  // +114 (the answered-interruption echo, final form): every `say`
  // keeps EXACTLY ONE copy in the unheard backlog — even one delivered
  // live. Delivery to a view is not proof of hearing: the socket can
  // die between the frame and the speaker, and +112/+113 both learned
  // some version of that the hard way. The phone's ledger — written at
  // audio commit, RETRACTED at wire death for anything that never
  // aired (+114 app side) — is the one authority on heard-or-not, and
  // the replay dedup defers to it. A re-relay of the same sentence
  // retires the parked copy rather than stacking a second.
  if (ev === 'say' && data.text) {
    for (let i = backlog.length - 1; i >= 0; i--) {
      if (backlog[i].ev === 'say' && backlog[i].data.text === data.text) {
        backlog.splice(i, 1);
      }
    }
    backlog.push({ ev, data });
    if (backlog.length > BACKLOG_CAP) backlog.shift();
    if (!curRes) console.error(`  [backlog] say (n=${backlog.length})`);
    return;
  }
  // +157: the started marker is PERMANENT, like a say. It is the
  // phone's ledger boundary — a drain that replays the answer without
  // it falls back to the replay rules and can swallow a reused
  // paragraph whole (field: 'Hello?' answered nothing; the marker rode
  // the POST body, died with the view and never reached the backlog).
  // One copy per prompt: a re-relay replaces the parked one.
  if (ev === 'tool' && data?.name === 'started') {
    for (let i = backlog.length - 1; i >= 0; i--) {
      if (backlog[i].ev === 'tool' && backlog[i].data?.name === 'started'
          && backlog[i].data?.detail === data.detail) {
        backlog.splice(i, 1);
      }
    }
    backlog.push({ ev, data });
    if (backlog.length > BACKLOG_CAP) backlog.shift();
    return;
  }
  // +159: counters are noise, not memory — the law stated at the head
  // of this function ("a reattaching phone re-derives them") now holds
  // for the UNHEARD case too. An unwatched background turn relays a
  // tally every ~0.8 s; against BACKLOG_CAP that flood EVICTS the real
  // memory (says, markers, finished receipts) — the very frames a drain
  // exists to deliver — and every survivor inflated `missed` with a
  // number no ack could ever retire (0.1.0+159: stuck at 197).
  if (ev === 'context' || (ev === 'tool' && data?.name === 'tokens')) return;
  if (curRes) return; // transient frames stay live-only while heard
  backlog.push({ ev, data });
  if (backlog.length > BACKLOG_CAP) backlog.shift();
  console.error(`  [backlog] ${ev} (n=${backlog.length})`);
};
// The wire shape of the spinner's live counter: a display string (for
// anything that only shows text) plus numeric fields so the phone can
// paint the exact number AND keep it growing between relays. out is
// tokens-so-far this turn (estimate, or exact after a message closed),
// in is this API call's context consumption, kind is what the model is
// doing right now ('thinking' | 'answering' | 'calling X' | ''). The
// in-count is the BEST-KNOWN figure (exact message_start once proven,
// else the running preview) — the spinner should carry the honest
// estimate over showing nothing. `quiet: true` marks a frame the
// heartbeat sent because the turn has been silent: with no movement at
// all the detail says so in plain words, so "thinking" on the phone
// never silently degrades into "stuck".
const tokFrame = (out, {quiet = false} = {}) => {
  const o = Math.max(0, Math.round(out));
  const inTok = Math.max(tokIn, estSentIn);
  const parts = [tokKind || 'working', `${fmtTok(o)} out`];
  if (inTok > 0) parts.push(`${fmtTok(inTok)} in`);
  if (quiet) parts.push('no deltas from upstream');
  return {
    name: 'tokens',
    detail: parts.join(' · '),
    out: o, in: inTok, kind: tokKind,
    ...(tokKind === 'thinking' && thinkTail(160)
      ? {thought: thinkTail(160)} : {}),
    // The reply, painted before it is spoken: the un-relayed tail of the
    // live answer rides the same frame the moment the model starts
    // answering. Old clients ignore the field (unknown keys in a tool
    // frame are harmless); the chat window shows it while the text
    // streams. Kept off `quiet` frames — a silent turn has no draft.
    ...(tokKind === 'answering' && !quiet && draftTail(240)
      ? {draft: draftTail(240)} : {}),
    ...(quiet ? {quiet: true} : {}),
  };
};

// The --dump-requests tap: see the flag NOTE up top for why. Forwards to
// the base URL the user's settings.json configures (the tap exists to
// OBSERVE the wire, not to change where it lands), streams responses
// straight through so SSE timing is untouched, and numbers bodies in
// arrival order. 400s and count_tokens calls pass through un-dumped
// (count_tokens bodies are prompt previews, not requests; the 400 pair
// would double every capture).
let tapStarted = false, dumpN = 0;
function startDumpTap() {
  if (tapStarted) return;
  tapStarted = true;
  mkdirSync(dumpDir, { recursive: true });
  let base = 'https://api.anthropic.com';
  try {
    const s = JSON.parse(readFileSync(join(homedir(), '.claude', 'settings.json'), 'utf8'));
    if (s.env && s.env.ANTHROPIC_BASE_URL) base = s.env.ANTHROPIC_BASE_URL;
  } catch {}
  const origin = new URL(base).origin;
  http.createServer((req, res) => {
    const parts = [];
    req.on('data', c => parts.push(c));
    req.on('end', async () => {
      const body = Buffer.concat(parts);
      if (req.method === 'POST' && req.url.includes('/v1/messages') &&
          !req.url.includes('count_tokens')) {
        dumpN += 1;
        const f = join(dumpDir, 'req-' + String(dumpN).padStart(3, '0') +
          '-' + Date.now() + '.json');
        try { writeFileSync(f, body); } catch {}
        console.error('  [dump] #' + dumpN + ' ' + f);
        if (dumpN > 120) {  // bound the dir: delete the oldest captures
          try {
            const olds = readdirSync(dumpDir).filter(n => n.startsWith('req-'))
              .sort().slice(0, dumpN - 120);
            for (const n of olds) rmSync(join(dumpDir, n), { force: true });
          } catch {}
        }
      }
      try {
        const r = await fetch(origin + req.url, {
          method: req.method,
          headers: Object.fromEntries(Object.entries(req.headers)
            .filter(([k]) => !['host', 'connection', 'content-length'].includes(k))),
          body: (req.method === 'GET' || req.method === 'HEAD') ? undefined : body,
          duplex: 'half',
        });
        res.writeHead(r.status, Object.fromEntries(r.headers));
        if (r.body) {
          const { Readable } = await import('node:stream');
          Readable.fromWeb(r.body).pipe(res);
        } else res.end();
      } catch (e) { res.writeHead(502).end(String(e)); }
    });
  }).listen(port + 1, '127.0.0.1', () =>
    console.error('  [dump] tap on 127.0.0.1:' + (port + 1) + ' -> ' +
      origin + ', bodies in ' + dumpDir));
}

function spawnClaude(resume) {
  const args = ['-p', '--input-format', 'stream-json',
    '--output-format', 'stream-json', '--verbose',
    // Live token progress for the spinner (see the stream_event branch of
    // handleEvent): partial message chunks as they arrive.
    '--include-partial-messages',
    '--permission-mode', permMode,
    '--append-system-prompt', sysPrompt];
  if (dumpDir) {
    startDumpTap();
    args.push('--settings', JSON.stringify({env: {
      ANTHROPIC_BASE_URL: 'http://127.0.0.1:' + (port + 1),
      CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: '1',
    }}));
  }
  if (resume) args.push('--resume', resume);
  console.error('  [claude] spawn (resume=' +
    (resume ? resume.slice(0, 8) : 'none — fresh session') + ')');
  // Experimental betas are poison for our prefix cache — captured
  // request bodies + controlled replays, see the "Latency and context
  // size" bullets in docs/claude-code-bridge.md: with betas on, every
  // turn opens with a `thinking.display:"updates"` request that our
  // adapter 400s (then the SDK retries = 2 model requests/turn), and
  // the transcript-reload path re-renders the history's leading
  // environment envelope from a text-block ARRAY back to a plain
  // STRING — a byte change ~1.5k tokens into the prompt
  // that diverges sglang's radix cache and re-prefills the whole rest of the
  // context EVERY turn (measured: same request with the envelope pinned to
  // its prior bytes: 0.20s vs 1.13s at 16k; scaled to a 166k voice session
  // that is the 9-12s per-turn prefill). With betas off both instabilities
  // vanish: envelope is a string from turn 1, no 400, no context_management
  // edits; the cache_control breakpoint still wanders per turn but the
  // adapter does pure longest-prefix radix and ignores marker position
  // (turn-2 replay hit 15,936 cached / 64 new tokens).
  child = spawn(claudeBin, args, { cwd: dir, env: {
    ...process.env,
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: '1',
  } });
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
  child.on('exit', (code, sig) => {
    childDead = true;
    // An exit while a turn is OPEN is news (crash, kill, proxy death):
    // relay it so the phone hears the turn died instead of timing out on
    // silence. An exit while NO turn is open is the normal lifecycle
    // (/new just SIGTERM'd us, or the CLI finished and left between
    // turns) — relaying it poisoned the fresh replay backlog with a
    // spurious `claude exited` the next /attach dutifully spoke. Field
    // note (probe-verified): this CLI re-emits system/init on EVERY user
    // message and re-renders the request each turn, so cross-turn prefix
    // cache misses are its behaviour, not an exit symptom.
    if (turnOpen) relay('error', { error: 'claude exited' });
    console.error(`  [claude] exit code=${code} sig=${sig} ` +
      (turnOpen ? 'MID-TURN (turn was open — phone gets the error)'
                : 'while idle (expected: /new kill or between-turns exit)'));
    turnOpen = false;
    openTools.clear();
    detached.clear(); // a dead process retires no tool: no tool_result
                      // will ever land to say 'finished' — the receipts
                      // are gone, and /health honestly drops to 0
    agentTasks.clear();
    bgTools.clear();
    heldFinished.length = 0; // no flush will ever come to owe them
    proactiveTurn = false;
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
    census.types[e.type] = (census.types[e.type] || 0) + 1;
    if (!census.sawFirst) {
      census.sawFirst = true;
      census.firstMs = Date.now() - census.t0;
      console.error(`  [census] first partial after ${census.firstMs} ms: ` +
        e.type + (e.type === 'message_start'
          ? ` (in=${e.message?.usage?.input_tokens ?? '?'})` : ''));
    }
    if (e.type === 'message_start') {
      census.msgStarts++;
      curMsg = {blocks: {}, seq: 0}; // the sentence buffer starts fresh per call
      tokMsgBase = tokOutExact;     // this message's deltas count from here
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
      // A fresh thinking block starts the rolling window over: the
      // phone only ever shows the CURRENT thought, never an old one.
      if (b.type === 'thinking') thinkBuf = '';
      if (b.type === 'text' && curMsg) {
        // Keyed by OUR insertion order, not the wrapper's index (see the
        // snapshot matcher): a second text block must not overwrite the
        // first's watermark.
        lastTextBlk = curMsg.blocks['b' + ++curMsg.seq] = {buf: '', spoken: 0};
        lastTextOpen = true;
      } else if (b.type === 'thinking' || b.type === 'tool_use') {
        lastTextOpen = false;
      }
      // +107: bare tool name, not 'calling X' — while a call's input
      // streams the label is the tool itself; the moment the snapshot
      // lands it grows the command (see the tool_use relay).
      tokKind = b.type === 'thinking' ? 'thinking'
        : b.type === 'tool_use' ? (b.name ?? 'tool')
        : b.type === 'text' ? 'answering' : tokKind;
    } else if (e.type === 'content_block_delta') {
      const d = e.delta ?? {};
      if (typeof d.thinking === 'string' && d.thinking) {
        thinkBuf = (thinkBuf + d.thinking).slice(-400);
      }
      const n = (d.text ?? d.thinking ?? d.partial_json ?? '').length;
      tokChars += n; census.deltaChars += n;
      if (typeof d.text === 'string' && d.text && lastTextOpen) {
        // The live answer grows — and complete sentences leave the
        // buffer as say frames right here, before the message closes.
        // Deltas are appended to the LAST-OPEN text block: the stream is
        // serial, and the wrapper's block index proved unreliable.
        if (lastTextBlk) { lastTextBlk.buf += d.text; relaySentences(lastTextBlk); }
      }
    } else if (e.type === 'message_delta') {
      census.msgDeltas++;
      const o = e.usage?.output_tokens;
      if (o) {
        census.usageOut += o;
        // The estimate just went exact — settle the phone's counter NOW
        // instead of letting it drift on estimates for another second:
        // one extra frame per closed message is nothing on the wire, and
        // it is the number the app's local growth will be judged against.
        tokOutExact = tokMsgBase + o; tokLastMsgOut = o; tokChars = 0;
        // +75: no curRes gate anymore. 'CurRes' is the PUSH view, and a
        // pull-mode phone never sets one — every later tally frame died
        // behind this if and the ring kept only the turn-start zero
        // (field report: "still see zero token count"). relay() feeds
        // the ring and the view/backlog itself; the ring is capped.
        tokSentAt = Date.now();
        relay('tool', tokFrame(tokOutExact));
      }
    }
    if (e.type === 'message_stop') {
      // +83: the answer's TEXT is final at this instant — everything
      // after it is the phone rendering audio (and the CLI's own
      // accounting before 'result' closes the turn). Without this the
      // spinner kept whoring for a dozen seconds after the last word,
      // honest about the socket being open but lying about there being
      // work left. 'settled' on the tally tells the phone the truth;
      // a still-open tool run means generation WILL continue, so we
      // stay quiet and the wheel keeps its well-earned spin.
      if (!openTools.size) {
        tokKind = 'settled';
        tokSentAt = Date.now();
        // Carry the un-spoken draft tail explicitly: tokFrame only
        // attaches it while 'answering', and the phone needs those
        // sentences on screen until their audio actually lands.
        relay('tool', { ...tokFrame(tokOutExact), draft: draftTail(1300) });
      }
    }
    if (e.type === 'content_block_stop') {
      // The text is final: the sentence buffer must empty completely,
      // including an un-terminated tail the streaming pass would wait
      // on whitespace for forever.
      if (lastTextOpen && lastTextBlk) relaySentences(lastTextBlk, {force: true});
      lastTextOpen = false;
    }
    // One tally line per ~0.8 s of ACTIVE generation, only while someone
    // is listening: no deltas flowing (waiting, running a tool) means
    // no relay, so the last real `tool` line — "Bash npm test" — keeps
    // the spinner label instead of a frozen counter overriding it. A
    // backgrounded turn keeps counting (the counters ride on for
    // whoever attaches next) but relays nothing. Between relays the
    // phone extrapolates at the rate its own consecutive relays taught
    // it, so the displayed number grows smoothly, not in 2-second jumps.
    if (tokChars && Date.now() - tokSentAt >= 800) {
      tokSentAt = Date.now();
      relay('tool', tokFrame(tokOutExact + Math.floor(tokChars / 4)));
    }
    return;
  }
  // Tool-lifecycle bookkeeping runs BEFORE any listener gate: a
  // backgrounded (detached) turn still opens and closes tools, and the
  // open count is what lets a later /talk decide queue-vs-interrupt.
  if (m.type === 'assistant' || m.type === 'user') {
    const content = Array.isArray(m.message?.content) ? m.message.content : [];
    // +159: the harness's OWN task notification ("…task b3xyz has been
    // completed… output written to …b3xyz.output") arrives as a plain
    // user message inside the NEXT turn — often a phone-initiated one,
    // so the proactive-close net below never runs, and nothing else
    // paid the debt until the model happened to Read the file (field
    // report 0.1.0+159: three shells finished; /health kept naming
    // them detached forever; the phone's banner could never retire).
    // Scanned BEFORE the content loop: the LAUNCH receipt is also a
    // user message naming the same id and path — a task must not pay
    // itself at birth. (The tool_use scan below stays the precise
    // trigger for the Read-the-output shape; this is the notification
    // shape.)
    if (m.type === 'user' && agentTasks.size) {
      const hay = typeof m.message?.content === 'string'
        ? m.message.content
        : JSON.stringify(m.message?.content ?? '');
      for (const [id, t] of agentTasks) {
        if ((t.outPath && hay.includes(t.outPath)) ||
            hay.includes(`tasks/${id}.output`) || hay.includes(id)) {
          agentTasks.delete(id);
          console.error(`  -> finished "${t.label}" ` +
            `(task notification in stream)`);
          relay('tool', { name: 'finished', detail: t.label });
        }
      }
    }
    for (const c of content) {
      if (c.type === 'tool_use' && c.id) {
        // Map, not set: the value is the step label ('Bash npm test') —
        // what the phone's banner names, and what a detached tool's
        // 'finished' frame must carry when its result lands late (or
        // in another turn's stream entirely).
        const step = summarize(c);
        const label = step ? `${c.name} ${step}` : String(c.name ?? 'tool');
        openTools.set(c.id, label);
        // +133: the agent backgrounded a shell ITSELF. Its tool_use
        // carries run_in_background; its tool_result returns at once
        // (a start receipt, not a completion), so the tool closes here
        // while the process keeps running. The phone learns NOW — the
        // `tool backgrounded` frame lights the bottom line with no
        // press involved — and the `finished` receipt lands when the
        // harness reports the task in, whichever shape that takes.
        if (c.input?.run_in_background === true) {
          bgTools.set(c.id, label);
          relay('tool', { name: 'backgrounded', detail: label });
        }
        // A Read/BashOutput/monitor of a tracked task's output file IS
        // the completion moment: the model is one block away from
        // speaking its outcome.
        for (const [id, t] of agentTasks) {
          const hay = JSON.stringify(c.input ?? {});
          if ((t.outPath && hay.includes(t.outPath)) ||
              hay.includes(`tasks/${id}.output`) || hay.includes(id)) {
            agentTasks.delete(id);
            console.error(`  -> finished "${t.label}" ` +
              `(agent's own background task)`);
            relay('tool', { name: 'finished', detail: t.label });
          }
        }
      } else if (c.type === 'tool_result' && c.tool_use_id) {
        openTools.delete(c.tool_use_id);
        // The start receipt of the agent's own background shell: the
        // CLI names a task id and an output file — register the debt.
        // This result is NOT a completion: the tool closed, the work
        // did not, so the detached-tool 'finished' below must not
        // fire for it.
        if (bgTools.has(c.tool_use_id)) {
          const bgLabel = bgTools.get(c.tool_use_id);
          bgTools.delete(c.tool_use_id);
          const txt = typeof c.content === 'string'
            ? c.content : JSON.stringify(c.content ?? '');
          const idm = txt.match(/background with ID: ([A-Za-z0-9_-]+)/);
          const om = txt.match(/([^\s'"]+\.output)/);
          agentTasks.set(idm?.[1] ?? c.tool_use_id,
            { label: bgLabel, outPath: om?.[1] ?? null });
          console.error(`  [bg] tracking agent task ` +
            `"${bgLabel}" (id ${idm?.[1] ?? c.tool_use_id})`);
        }
        // The result of a tool the interrupt put into background: the
        // phone's banner promise retires HERE, whatever turn holds the
        // view this lands in (the +99 contract behaviour 2 leans on).
        // The honest verb: an INTERRUPTED tool was killed, not
        // completed — Claude answers a killed call with an error result
        // (is_error / 'Interrupted'), and a 'finished' receipt for it
        // contradicts the agent's own 'the sleep was cancelled' on the
        // phone's screen within the same second.
        const label = detached.get(c.tool_use_id);
        if (label !== undefined) {
          detached.delete(c.tool_use_id);
          const txt = typeof c.content === 'string'
            ? c.content : JSON.stringify(c.content ?? '');
          const cancelled = c.is_error === true ||
            /command (was )?(interrupt|cancel|kill|abort)ed|exit code (130|143)\b/i
              .test(txt);
          const frame = {
            name: 'finished',
            detail: label,
            ...(cancelled ? { kind: 'cancelled' } : {}),
          };
          console.error(`  -> ${cancelled ? 'cancelled' : 'finished'} ` +
            `"${label}"`);
          // While a prompt sits in the queue, the cut's explanation
          // (queued/started) has not been written yet: hold the receipt
          // so the chat reads backgrounded → then its outcome, never
          // the outcome first (see heldFinished).
          if (pending) heldFinished.push(frame);
          else relay('tool', frame);
        }
      }
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
    // A report turn closing: whatever agent background tasks it did
    // not name are paid off anyway — the model may answer straight
    // from the notification without re-reading the output file. (The
    // per-tool_use scan above is the precise trigger; this is the
    // net.) Only on a PROACTIVE close: an unrelated /talk's result
    // must not drain tasks whose shells are still sleeping. The
    // app's receipt note dedups, so an over-eager payment is free.
    if (proactiveTurn) {
      for (const [, t] of agentTasks) {
        console.error(`  -> finished "${t.label}" (drained at report)`);
        relay('tool', { name: 'finished', detail: t.label });
      }
      agentTasks.clear();
      proactiveTurn = false;
    }
    bgTools.clear(); // an unpaired launch receipt dies with its turn
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
    // Per-turn verdict on what the upstream actually delivered (see
    // census): the answer to "the app showed no progress" that is
    // written by the wire, not by hope.
    const cacheVerdict = !census.sawFirst ? 'no first partial observed'
      : census.firstMs < 1500 ? 'PREFIX CACHE HIT (first partial in '
          + `${census.firstMs} ms — prompt prefix reused)`
      : 'PREFIX CACHE MISS (first partial in ' + census.firstMs
          + ` ms — full re-prefill; ~context/prefill-rate. Cross-turn `
          + 'misses are this CLI\'s per-turn re-init: it re-renders the '
          + 'request on every user message — probe-verified)';
    console.error('  [census] ' + (census.sawFirst
        ? `stream_event kinds: ${Object.entries(census.types)
            .map(([k, v]) => `${k}=${v}`).join(' ')} ` +
          `deltaChars=${census.deltaChars} usageOut=${census.usageOut}`
        : 'NO stream_event frames at all') + ' → ' + (
        census.deltaChars > 0
          ? 'LIVE DELTAS: phone ticker streams, heartbeats stay silent'
          : census.usageOut > 0
          ? 'USAGE-ONLY STREAM: numbers settle once per message; quiet '
            + 'heartbeats carry the spinner between them'
          : 'NO LIVE EVENTS: upstream buffers SSE (OpenAI-style or '
            + 'worse); phone gets thinking/heartbeat + elapsed only') +
      ' | ' + cacheVerdict);
    if (m.is_error) {
      // The reason, not just the flag: result carries errors[] / result
      // text on error_during_execution — previously discarded, leaving
      // every interrupted turn looking like an anonymous crash. (A
      // control-request interrupt lands here TOO: an interrupted turn's
      // 'error' is the user's barge-in, not a fault.)
      const why = m.errors ?? m.result ?? m.api_error_status ?? '(no detail)';
      console.error('  [result-error] ' +
        JSON.stringify(why).slice(0, 300).replace(/\\n/g, ' '));
    }
    // +106: a turn the phone CUT to make room for its own waiting
    // prompt gets no funeral notice. The +99 interrupt path always
    // parks the new prompt in `pending` first and marks the cut (see
    // interruptTurn), and only THAT pairing silences the done: a
    // politely-settled turn behind a slide-right queue still closes
    // with done for whoever holds the view, or the old stream just
    // stops lying open. Relaying done over a cut misfires: the phone's
    // reattach chain may already be holding an ATTACH view (or the
    // fresh /talk response is the next stream in line), and the app
    // files the stray done against the NEW bubble it just sent (field
    // report: slide-up over a thinking turn, then the conversation
    // "shows no updates at all" — the fresh turn was born dead ~300 ms
    // in). The queued turn's own frames — and the +81 'started' marker
    // on the ring transport — say everything that needs saying.
    if (!(pending && cutForPrompt)) {
      // The lifecycle receipt for a turn that is ending with NO ear on
      // it — backgrounded by a press, a hide, a dead socket, or the
      // poll transport's mute floor. A HEARD turn's phone holds its own
      // done and needs no marker; a turn CUT for a waiting prompt gets
      // neither (the +106 rule: the new turn's frames are the story).
      // The frame rides the ring and the backlog like every tool frame,
      // so whatever view next listens reads WHEN the out-of-earshot
      // work actually ended and how long it ran — the
      // badge-stayed-lit-long-after-the-work-finished triage question,
      // answered by the wire instead of probe archaeology. It lands
      // ahead of the done, so a replay reads work…, finished, done.
      if (!curRes) {
        const ran = turnBeganAt
            ? Math.max(0, Math.round((Date.now() - turnBeganAt) / 1000))
            : 0;
        relay('tool', {
          name: 'finished',
          detail: m.is_error
            ? `ended after ${ran}s — cut by the interrupt that backgrounded it`
            : `ended after ${ran}s unheard`,
        });
      }
      relay('done', { costUsd: m.total_cost_usd, isError: m.is_error });
    }
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
  // +133: the harness speaking unprompted (background work reporting
  // in). The real CLI runs the completion response as a normal turn —
  // with no /talk behind it. Open it as a background turn: a fresh
  // /talk queues politely, /stop can cut it, and the result path's
  // receipts and done all apply unchanged. Assistant messages only —
  // a stray tool_result is bookkeeping, not a mouth.
  if (!turnOpen && m.type === 'assistant') {
    turnOpen = true;
    proactiveTurn = true;
    turnBeganAt = Date.now();
    console.error('  [proactive] the harness speaks unprompted ' +
      '(background work reporting in)');
  }
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
      for (const [i, c] of content.entries()) {
        if (c.type === 'text' && c.text.trim()) {
          const t = c.text.trim();
          // Within one turn, relay each exact text once. Identical
          // consecutive progress lines lose their second copy — right
          // trade for audio.
          if (spokenTexts.has(t)) continue;
          spokenTexts.add(t);
          // Sentence relays from the live deltas may have spoken most of
          // this block already; the snapshot only owes the watermark's
          // remainder. The live block is found by TEXT MATCH, not by
          // array index: the stream wrapper's block indices are not
          // trustworthy (a thinking block shifts the text block's array
          // position but its deltas may all arrive keyless — that's what
          // the field trace showed), while the spoken prefix is exact.
          // Advancing `spoken` keeps a grew-again snapshot from
          // re-speaking what the first one just said. A block with no
          // deltas (census says some upstreams send none) matches
          // nothing and falls through to the old whole-text relay.
          // The match itself is settleOwed (unit-guarded): it also
          // claims SILENT live blocks, the gap that let a settle and
          // the block-close flush speak one short reply twice.
          const blocks = Object.values(curMsg?.blocks ?? {});
          const owed = settleOwed(blocks, t);
          if (owed.claim >= 0) {
            const blk = blocks[owed.claim];
            blk.spoken = blk.buf.length;
          }
          if (!owed.text) continue;
          console.error(`  -> say "${owed.text.slice(0, 40)}"`);
          relay('say', { text: owed.text });
        }
        if (c.type === 'tool_use' && c.id && !spokenTools.has(c.id)) {
          spokenTools.add(c.id);
          relay('tool', { name: c.name, detail: summarize(c) });
          // +107: the command line BECOMES the activity label — plain,
          // no 'running a command' wrapper — until the next block starts
          // streaming. Without this the tool pause falls back to the
          // last known kind, and a turn dominated by tool calls reads
          // 'Thinking…' over a frozen counter while a minute-long test
          // churns (field report: 'it says thinking but nothing is
          // thinking, paragraphs just drip out of the TTS'). The bare
          // command is the honest answer to what the turn is doing.
          const step = summarize(c);
          tokKind = step ? `${c.name} ${step}` : c.name;
        }
        if (c.type === 'thinking' && typeof c.thinking === 'string' &&
            c.thinking && census.deltaChars === 0) {
          // This upstream sends no partials at all (the census says so),
          // so the snapshot's full thinking block is the only live view
          // the thought ever gets: feed the same rolling window the
          // deltas would have filled and push a tally frame, throttled
          // like every other relay.
          const tailNow = c.thinking.slice(-400);
          if (tailNow !== thinkBuf && Date.now() - tokSentAt >= 800) {
            thinkBuf = tailNow;
            tokSentAt = Date.now();
            relay('tool',
              tokFrame(tokOutExact + Math.floor(tokChars / 4)));
          }
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
// The turn's keep-alive pinger (and quiet-token heartbeat), one interval
// per heard-view object: an SSE comment guards the link (NAT, tailscale,
// Dart clients) against idle-detection on a merely-thinking stream, and
// — since the phone's watchdog treats 24 s of wire-silence as a dead
// socket — at most every 2 s (the cadence doubles as retransmit pressure:
// see the interval note at the bottom). On each tick, if the HEARD view of an OPEN
// turn has relayed nothing for HEARTBEAT_MS and no tool is open (during
// a tool run the real "Bash npm test" line owns the spinner, not a
// frozen counter), push the current tally marked `quiet`: the phone then
// says "thinking · N in · no deltas from upstream" out loud instead of
// wondering. A turn whose upstream streams deltas never hits the
// silence threshold while generating, so this frame is strictly the
// no-progress signal — never a stutter over the live ticker.
function startKeep(res) {
  return setInterval(() => {
    try {
      if (HEARTBEAT_MS > 0 && curRes && curRes.res === res && turnOpen &&
          !openTools.size && Date.now() - tokSentAt >= HEARTBEAT_MS) {
        tokSentAt = Date.now();
        relay('tool', tokFrame(
          tokOutExact + Math.floor(tokChars / 4),
          {quiet: tokChars === 0 && tokOutExact === 0}));
      }
      // Padded like every other frame: a bare ': ping' is exactly the
      // small, isolated write the cellular path coalesces into silence —
      // the receipts proved 2 s pings and 1.3 KB padding each alone
      // insufficient, so the ping is now BOTH frequent AND fat.
      res.write(': ' + 'p'.repeat(1300) + '\n\n');
    } catch {}
  // While a turn is OPEN the pinger runs every 150 ms (~8.7 KB/s): the
  // cellular radio's dormancy timer and the TUN batcher both feed on
  // quiet gaps, and a tool run is exactly a multi-second gap waiting to
  // swallow a lone frame (wire ages measured 8–14 s at turn close even
  // with 2 s pings and padded frames). Continuous fat writes give them
  // nothing to coalesce; the steady dribble outlives the turn's lulls.
  // Outside an open turn, back to the slow heartbeat cadence.
  }, turnOpen ? 150 : Math.min(HEARTBEAT_MS || 15000, 2000));
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
  if (dumpDir) {
    try {
      appendFileSync(join(dumpDir, 'MANIFEST'), new Date().toISOString() +
        ' stdin ' + (text.length > 70 ? text.slice(0, 70) + '…' : text) + '\n');
    } catch {}
  }
}
function summarize(tool) {
  const i = tool.input ?? {};
  return String(i.command ?? i.file_path ?? i.pattern ?? i.url ?? '').slice(0, 80);
}
// In-band turn interrupt via the CLI's control protocol (verified live on
// 2.1.296): a control_request on stdin cancels the OPEN turn — its
// `result` still arrives (is_error: true — that's the interrupt speaking,
// not a fault; see [result-error]) and the process keeps running.
// This replaces SIGINT, which in headless -p mode kills the WHOLE
// process: the next utterance then respawns with --resume and re-hydrates
// the transcript from disk (slower to first token, and the rebuilt
// request is yet one more prefix the cache has never seen). Honest
// caveat from the 2026-10-16 probe: cross-turn cache hits were never on
// offer from this CLI either way — it re-renders the request on every
// user message — so the in-band interrupt buys process survival and
// fast queue flush, not a warm prefix (see the header latency note).
function interruptTurn() {
  if (!child || childDead) return;
  cutForPrompt = true; // this turn's result is a cut, not a close (+106)
  // Whatever tool the cut turn was running becomes the phone's banner
  // promise: its tool_result — whenever it arrives, in whichever turn
  // holds the view then — relays the 'finished' frame that retires the
  // banner. If the harness instead kills the tool with the turn, its
  // error/absent result still clears the banner via /health (nothing
  // open, nothing detached) — the app's dismissal paths admit every
  // honest outcome.
  for (const [id, label] of openTools) detached.set(id, label);
  if (dumpDir) {
    try {
      appendFileSync(join(dumpDir, 'MANIFEST'),
        new Date().toISOString() + ' interrupt\n');
    } catch {}
  }
  try {
    child.stdin.write(JSON.stringify({
      type: 'control_request', request_id: randomUUID(),
      request: { subtype: 'interrupt' },
    }) + '\n');
  } catch {}
}
// Attach `res` as the heard view of a brand-new turn and release the
// prompt to claude. The keep-pinger/heartbeat belongs to the turn object
// now: a backgrounded turn and whatever replaces it each carry their own.
function beginTurn(text, res, keep, markerKind, turnId) {
  if (childDead) spawnClaude(sessionId); // resume our voice conversation if any
  // The id the POST promised this prompt; every frame relayed from here
  // on wears it (proactive turns invent their own — no echo, no queue).
  curTurnId = turnId ?? ++nextTurnId;
  turnStartAt = Date.now() - 5000; // slack: clock skew
  turnBeganAt = Date.now(); // the receipt's honest duration clock
  curRes = { res, keep, turnStart: turnStartAt };
  backlog.length = 0; // a new turn: the old one's buffered frames are stale
  cutForPrompt = false; // a fresh turn closes with its own done (+106)
  turnOpen = true;
  spokenTools.clear(); // every message lives inside one turn
  spokenTexts.clear();
  census = newCensus(); // one wire-shape census per turn
  tokIn = tokOutExact = tokLastMsgOut = tokChars = tokSentAt = tokMsgBase = 0; // fresh tally
  thinkBuf = ''; // no thought survives into the next turn
  curMsg = null; lastTextBlk = null; lastTextOpen = false; // ditto live answer
  // Provisional until the first content_block_start relabels it to truth
  // ('answering', 'calling Bash'): between the prompt landing and the
  // first visible token, 'thinking' IS the honest state — and on an
  // upstream that never shows partials at all, it stays the honest
  // description of the black-box interval, heartbeat frames included.
  tokKind = 'thinking';
  // +155: every turn start announces its pickup — not just the queued
  // flush. The poll transport's replay ledger needs the boundary to
  // retire at, and an idle bridge has no flushPending to give it one:
  // without a marker the phone deduped a live answer that reused a
  // paragraph from minutes ago (field: spinner said 'Rendering
  // audio', the chat stayed silent). kind='background' rides only for
  // a prompt that cut a tool (flushPending passes the tag; the cut's
  // receipts follow below it on the ring).
  relay('tool', {
    name: 'started',
    detail: String(text).slice(0, 60),
    ...(markerKind ? {kind: markerKind} : {}),
  });
  // Preview the coming call's size BEFORE the first message_start (which
  // only lands after the server finishes reading): last turn's exact
  // context + this utterance's own tokens, relayed as the turn's very
  // first frame. A brand-new conversation has no baseline to preview
  // from (0 = nothing honest to say yet; the first message_start will).
  estIn = lastCtx.in > 0 ? lastCtx.in + estTokens(text) : 0;
  estSentIn = estIn;
  if (estIn > 0) ctxPreviewFrame();
  // The turn's first tally frame, ONE RTT after the prompt: the phone's
  // line flips from "Asking the bridge…" to "thinking · …" immediately,
  // before the upstream has proved anything. Whether the number then
  // MOVES is what the census reports at the result; either way the
  // spinner never reads as ignored.
  relay('tool', tokFrame(0)); // ring too: poll clients see every frame
  writeUserMsg(text);
}
// A queued prompt got its slot: hand over the floor the moment the
// backgrounded turn released it (its `result` event, or a process death
// — beginTurn respawns with --resume).
function flushPending() {
  if (!pending) return;
  const p = pending;
  pending = null;
  // The disposition notice and everything after it belong to the
  // RESERVED turn, not the one whose `done` just fired (the result
  // handler relays that farewell BEFORE flushing — it stays stamped
  // with the old id, and the phone's pump tells them apart by it).
  curTurnId = p.turnId;
  // +104: an ended response is NOT an abandoned message. This branch
  // used to eat the utterance silently — field report 'the queued
  // message was lost': the phone's stream died in the queue (quiet-wire
  // watchdog, lifecycle HIDE, Android cutting the socket) and flush
  // dropped the prompt instead of honouring the promise its own
  // 'queued' notice made. A dead stream only decides the TRANSPORT:
  // the turn runs anyway, its frames ride the ring, and the phone's
  // reattach replay catches them when it's back.
  if (p.res.writableEnded && !p.poll) p.poll = true; // ring transport below
  if (p.poll) {
    // Queued POLL prompt: its POST response was closed at queue time, so
    // the turn starts against a mute socket — every frame simply rings —
    // and one endTurn() detaches the view the same tick it appeared.
    const mute = { write: () => true, end: () => {}, on: () => {} };
    endKeep(p);
    // The disposition, re-announced NOW (the enqueue-time notice may
    // have been consumed-and-dropped by the superseded turn's dying
    // poll loop — a shared ring cursor the phone cannot treat as
    // reliable). A tagged started marker carries the background promise;
    // the notice itself repeats verbatim so the phone's 'One moment'
    // bubble survives the race on every transport.
    if (p.interrupt || p.backgrounded) {
      relay('tool', {
        name: 'queued',
        // The tool's FATE is the receipt's verdict (finished or
        // cancelled — the CLI aborts an interrupted call), not this
        // note's guess: 'put into background' stamped a killed sleep
        // with a claim its own receipt contradicted seconds later
        // (field report: 'says put to background incorrectly'). The
        // banner promise rides the kind tag, not the prose.
        detail: p.hadTools
          ? 'the running call was interrupted — the agent is freed to '
            + 'answer you now; the tool outcome reports on its own'
          : 'the thinking was interrupted and aborted; your message '
            + 'goes next',
        ...(p.hadTools ? {kind: 'background'} : {}),
      });
    }
    // +81/+155: the pickup marker now rides inside beginTurn (every
    // turn start announces, so even an idle bridge draws the ledger
    // boundary). The object is built HERE for the backlog re-file
    // below; beginTurn pushes the identical shape to the ring as the
    // turn's first frame. kind='background' below: THIS prompt cut a
    // running tool — the phone's banner promise, delivered where a
    // shared ring cursor cannot lose it.
    const receipts = heldFinished.splice(0);
    beginTurn(p.text, mute, 0, p.backgrounded ? 'background' : undefined,
      p.turnId);
    // The cut's receipts, relayed AFTER the disposition AND after the
    // marker (beginTurn's first frame): the phone's chat reads 'put
    // into background', then the pickup, then the tool's honest
    // outcome (finished/cancelled) — never the outcome over its own
    // explanation (see heldFinished).
    for (const f of receipts) relay('tool', f);
    // (+157: the marker's backlog copy now rides relay() itself —
    // permanent like a say, no re-file needed here.)
    // …and the cut's receipts with it: the drain must be able to
    // retire the banner too, not just the pin (their live copies above
    // may die with a superseded loop the same way the notice's did).
    for (const f of receipts) {
      backlog.push({ ev: 'tool', data: f });
      if (backlog.length > BACKLOG_CAP) backlog.shift();
    }
    endTurn();
    return;
  }
  beginTurn(p.text, p.res, p.keep, // pinger rides on into the new turn
    p.backgrounded ? 'background' : undefined, p.turnId);
  // Same ordering rule on the push transport: receipts follow their
  // explanation. The live view takes these directly; the ring copy is
  // the phone's deduped replay insurance.
  for (const f of heldFinished.splice(0)) relay('tool', f);
}
// [the phone's ear] is pressed to it) or only a BACKGROUNDED turn is
// open. Either way a new prompt never waits on it — it is QUEUED at the
// front (latest wins; the prior pending's response is ended). Two flags
// decide what happens to the turn in flight: `interrupt` (the default —
// typed text, conversation barge-in, PTT slide-UP) cuts the turn with an
// in-band interrupt — thinking AND an in-flight tool call alike (the
// +99 spec: the tool goes to background, the agent is freed to answer
// the new message at once). Nothing but the model's WAITING is aborted:
// the process never dies (no --resume, no cold prefill on the next
// turn) — so its `result` flushes the queue in a heartbeat.
// `cutTool` (behaviour 2, the Queue button) is the middle flavour:
// polite as long as the agent is merely THINKING (the message goes next
// when the turn settles), but the moment the agent is chewing on a TOOL
// CALL it is backgrounded the same way — a queue press during a build
// means "I need the agent now", and the tool's result lands whenever it
// wants (the +99 detached-tool contract). false/false (PTT slide-right,
// the pure polite queue) lets the in-flight turn run to its natural end
// first. Whether the tool's own OS process survives the abort is the
// harness's call — detached tool modes survive, plain foreground waits
// may end with the turn; the phone's notice words stay honest either
// way, and /stop remains the hard flavour it always was.
function talk(text, res, interrupt = true, poll = false, cutTool = false) {
  // SSE comment pinger + quiet-token heartbeat (see startKeep): a
  // 3-minute gradle build emits nothing, and idle-detection on the link
  // (NAT, tailscale, Dart clients — including the app's 24 s quiet-wire
  // watchdog) should not get creative with a stream that is merely
  // thinking.
  const keep = startKeep(res);
  // v2: the turn this prompt will own is decided HERE, before the
  // branch — immediate or queued, the answer is the same number, and
  // the POST echoes it so the phone can name its own turn forever
  // after (a burned id — superseded queue — just skips the sequence).
  const t = ++nextTurnId;
  // NOTE: must listen on the RESPONSE, not the request: a POST's req
  // 'close' fires the instant its body is read, which would end the
  // stream before claude ever answers. res 'close' = client hung up or
  // response finished.
  res.on('close', () => {
    if (curRes && curRes.res === res) { console.error('  (client detached — turn runs background)'); endTurn(); }
    else if (pending && pending.res === res && !pending.poll) {
      // A POLL prompt closes its response AT QUEUE TIME by design (the
      // ring carries its turn) — this close is our own res.end()
      // landing, and dropping pending here silently ate the utterance:
      // the pin froze at 'queued', no 'started' ever rode the ring, and
      // flushPending's poll branch never got to run (field report
      // 0.1.0+90, the message that queued and vanished). +104 reads the
      // SAME event on a live SSE prompt as a dead TRANSPORT, not an
      // abandoned message — the phone only ever discards BEFORE sending
      // (slide-right), so after the 'queued' promise the turn is owed
      // regardless: flip to the poll transport and let flushPending
      // run it on the ring.
      pending.poll = true;
    }
  });
  if (curRes || turnOpen) {
    // Something is in flight — still HEARD (curRes: the phone never let
    // go, e.g. a second client, or the detach's 'close' hasn't landed
    // yet) or backgrounded (turnOpen). Park this prompt at the front of
    // the queue; whichever event frees the floor (the attached turn's
    // `result` closes its stream, or the backgrounded one's) flushes it.
    if (pending) { endKeep(pending); if (!pending.res.writableEnded) pending.res.end(); }
    pending = {
      res, text, keep, poll, interrupt, turnId: t,
      // Remember what the cut decision saw, so the flush can re-announce
      // both the notice wording and the background promise (see above).
      hadTools: openTools.size > 0,
      backgrounded:
        (interrupt || (cutTool && openTools.size > 0)) && openTools.size > 0,
    };
    // The cut decision, once: an interrupt always cuts; a cutTool queue
    // cuts ONLY a running tool (behaviour 2: polite towards thinking,
    // the agent is freed the moment it is chewing on a command).
    const cut = interrupt || (cutTool && openTools.size > 0);
    const note = {
      name: 'queued',
      // +98: the notice names the OUTCOME the interrupt gesture caused
      // — the phone shows this line verbatim and the field report
      // asked to read exactly this: was my interrupt an abort or a
      // backgrounding? A polite queue (interrupt=0, no cuttool)
      // promises neither.
      detail: openTools.size
        ? cut
          ? 'the running call was interrupted — the agent is freed to '
            + 'answer you now; the tool outcome reports on its own'
          : 'a tool call is running; your message goes next when it settles'
        : cut
          ? 'the thinking was interrupted and aborted; '
            + 'your message goes next'
          : 'finishing the current turn; your message goes next',
      ...(openTools.size && cut ? {kind: 'background'} : {}),
      _ts: Date.now(), _mid: ++msgSeq, _turn: t,
    };
    // The ring too (+behaviour 1): the poll client drains its POST
    // response without reading it — without this frame on the ring it
    // never learns WHAT KIND of queue it landed in, and the 'One
    // moment' verdict — the answer to 'did the agent take my message?'
    // — only ever showed on the push transport. Ring-only, never the
    // /attach backlog: a queue notice belongs to the moment it was
    // earned, not to a later replay.
    ring.push({seq: ++ringSeq, ev: 'tool', data: note});
    if (ring.length > RING_CAP) ring.splice(0, ring.length - RING_CAP);
    // v2 transport split: a polled POST answers with a JSON receipt
    // (the notice itself rides the ring below — draining an SSE body
    // only to discard it bought nobody anything); a pushed stream
    // opens by naming its turn, then carries the notice in-band.
    if (poll) {
      res.writeHead(200, {'content-type': 'application/json'});
      try { res.end(JSON.stringify({ok: true, turn: t})); } catch {}
    } else {
      sse(res, 'turn', {turn: t, queued: true});
      sse(res, 'tool', note);
    }
    // +99 (supersedes the +33 rule): the interrupt gesture cuts the
    // TURN even with a tool in flight — the field spec: 'put the
    // running tool into background and free the agent to answer my
    // next message.' The turn aborts within a heartbeat and
    // flushPending hands over the floor immediately; what the tool's
    // own process does next is the harness's business, probed and
    // reported in the commit note. The polite queue (interrupt=0, no
    // cuttool) still waits for the turn to settle on its own.
    if (cut) interruptTurn();
    return;
  }
  if (poll) {
    // v2 pull transport: a JSON receipt closes the POST, and the turn
    // begins against a MUTE floor exactly like the queue flush's poll
    // branch — every frame rings, the marker and every say keep their
    // backlog copies, and nothing hangs on a body the client discards.
    // (The old shape wrote the turn's first frames into the POST and
    // threw them away: the marker died with the view — +157's lost
    // birth certificate started right here.)
    res.writeHead(200, {'content-type': 'application/json'});
    try { res.end(JSON.stringify({ok: true, turn: t})); } catch {}
    endKeep({keep});
    beginTurn(text, {write: () => true, end: () => {}, on: () => {}},
      0, undefined, t);
    endTurn();
    return;
  }
  sse(res, 'turn', {turn: t}); // v2: the push stream opens by naming its turn
  beginTurn(text, res, keep, undefined, t);
}
// tool_use ids already relayed this turn (tool_use ids are unique per
// call and stable across snapshots of the same message). Cleared at
// beginTurn: a turn is the natural lifecycle here and it keeps the set
// from growing forever.
const spokenTools = new Set();
// Exact say texts already relayed this turn (catches replays that arrive
// under fresh message ids, e.g. a resumed transcript). Same lifecycle.
// v2 note: this dedups the CLI's snapshot re-emissions AT THE SOURCE —
// it is not the phone's dedup (that is _mid + /heard, and the phone
// never guesses from text again).
const spokenTexts = new Set();

// ── Phone-side journal: relay, liveness, dial-back bookkeeping ─────────
// The app keeps a seq-numbered event journal of its OWN lifecycle story
// (lib/app_events.dart); see the file header /applog entry for the two
// transports. The pull model was the original design and stays useful
// for dialable peers (desktop dev boxes, LAN): every few seconds we GET
// /applog?since=<watermark> and relay new entries to stderr, putting
// BOTH machines' views of one misbehaving turn into the same
// journalctl stream (the entry carries the phone's own clock —
// inter-machine skew is exactly what a bracketed freeze window should
// be judged against, not guessed at). Pull FAILURE is telemetry too —
// but it is read as 'frozen or killed' ONLY when push is quiet as well;
// an Android phone that refuses dials yet pushes is alive and talking
// (see the push-mode branch of pumpAppLog and the PUSH intake block).
const appLogEveryMs = Number(arg('applog-interval', 5000)); // 0 = off
const appPeer = {host: null, port: 0, seq: 0, fails: 0, down: false, seen: 0};

// ── PUSH intake: the journal transport that always works ──────────────
// Every relayed entry — PULLED (GET /applog, dialed back) or PUSHED (POST
// /applog, the app's own outbound connection) — runs through this ONE
// path, so the two transports can never diverge on watermark, dedupe or
// output format. Push exists because dialing back is a lie we told: the
// Android Tailscale client accepts no inbound connections by default, and
// behind carrier NAT there IS no route to dial — while the phone's
// OUTBOUND to this bridge always works (it carries every turn already).
// The last pushed envelope is also CACHED (phoneJournal): a curl-able
// desktop mirror of a phone nothing can dial, which is what makes
// journalctl-free triage still possible on inbound-refused nodes.
const PHONE_JOURNAL_CAP = 240;
const phoneJournal = {events: [], seq: 0, flags: {}, at: 0};
function ingestAppEnvelope(j, src) {
  if (j.ok !== true || !Array.isArray(j.events)) return false;
  const fresh = j.events
      .filter(e => typeof e.seq === 'number' && e.seq > appPeer.seq)
      .sort((a, b) => a.seq - b.seq);
  const head = Math.max(appPeer.seq, j.seq || 0,
                        ...fresh.map(e => e.seq));
  // Gap before the first fresh entry (rolled off between relays), or a
  // head advance with nothing fresh at all.
  const lost = fresh.length
      ? fresh[0].seq - appPeer.seq - 1
      : head - appPeer.seq;
  appPeer.seq = head; // at-least-once redelivery is deduped right here
  for (const e of fresh) {
    const ts = new Date(e.t || Date.now()).toISOString().slice(11, 23);
    console.error(`  [app ${ts}] #${e.seq}${src === 'push' ? ' (p)' : ''} ${e.msg}`);
  }
  if (lost > 0) {
    console.error(`  [applog] ${lost} phone entries rolled off unread (${src})`);
  }
  appPeer.fails = 0;
  if (appPeer.down) { console.error('  [applog] phone journal REACHABLE again'); appPeer.down = false; }
  if (src === 'push') {
    phoneJournal.at = Date.now();
    const have = new Set(phoneJournal.events.map(e => e.seq));
    for (const e of j.events) if (!have.has(e.seq)) phoneJournal.events.push(e);
    phoneJournal.events = phoneJournal.events.slice(-PHONE_JOURNAL_CAP);
    phoneJournal.seq = Math.max(phoneJournal.seq, j.seq || 0);
    phoneJournal.flags = j.flags || phoneJournal.flags;
  }
  return true;
}
function noteAppPeer(req, url) {
  const host = req.socket.remoteAddress;
  if (!host) return;
  const port = Number(url.searchParams.get('logport')) || appPeer.port || 8733;
  const fresh = !appPeer.host;
  if (fresh) console.error(`  [applog] phone journal target ${host}:${port}`);
  appPeer.host = host;
  appPeer.port = port;
  appPeer.seen = Date.now();
  if (fresh && appLogEveryMs > 0) void pumpAppLog();
}
// Link-local IPv6 peers (fe80::..%wlan0) can't be dialed back without the
// scope, which fetch URLs can't express — drop it and let the route fail
// honestly (Tailscale peers are IPv4 100.x in practice).
const dialHost = (h) => h.includes(':') ? `[${h.split('%')[0]}]` : h;
let appPumpInFlight = false;
let pushModeNoted = false;
async function pumpAppLog() {
  if (!appPeer.host || appPumpInFlight || appLogEveryMs <= 0) return;
  appPumpInFlight = true;
  const {host, port} = appPeer; // snapshot: relearn may move it mid-flight
  try {
    const r = await fetch(
      `http://${dialHost(host)}:${port}/applog` +
      `?token=${encodeURIComponent(token)}&since=${appPeer.seq}`,
      {signal: AbortSignal.timeout(4000)});
    const j = await r.json();
    if (!ingestAppEnvelope(j, 'pull')) throw new Error('bad envelope');
    pushModeNoted = false; // dialable again: the note may apply anew later
  } catch (e) {
    // Tolerate a few misses (the app is legitimately frozen while the OS
    // parks it; a single dropped GET means nothing); log the outage ONCE,
    // and its end, rather than every 5 s. But a phone that PUSHES and
    // refuses to be DIALED (Android tailscale, carrier NAT) is neither
    // frozen nor killed — it is merely unhospitable to the pull model,
    // and its pushes prove life. Note that once, quietly, and let push
    // carry the story.
    if (phoneJournal.at && Date.now() - phoneJournal.at < Math.max(120000, appLogEveryMs * 12)) {
      if (!pushModeNoted) {
        pushModeNoted = true;
        console.error('  [applog] phone refuses inbound dials (Android ' +
          'tailscale or NAT-ed) — PUSH mode active: the phone POSTs its ' +
          'journal; GET /applogs serves the server-side mirror');
      }
      appPeer.fails = 0; // no down/outage noise while push flows
    } else if (++appPeer.fails >= 3 && !appPeer.down) {
      console.error(`  [applog] phone journal at ${host}:${port} not answering ` +
        `(${e.message}) — app frozen or killed?`);
      appPeer.down = true;
    }
  } finally {
    appPumpInFlight = false;
  }
}
setInterval(pumpAppLog, appLogEveryMs || 3600000).unref(); // cheap when off

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname !== '/health' && url.searchParams.get('token') !== token) {
    res.writeHead(401).end('nope\n'); return;
  }
  // The app's requests announce their journal port (?logport=, see
  // lib/app_events.dart); nothing else does, so a desktop curl can never
  // masquerade as the phone. Peer = this connection's source address:
  // the exact route the turn rides, so the return leg needs no DNS, no
  // static lease, no hole-punching.
  if (url.searchParams.has('logport') &&
      ['/health', '/talk', '/attach', '/stop', '/new', '/applog']
          .includes(url.pathname)) {
    noteAppPeer(req, url);
  }
  if (req.method === 'GET' && url.pathname === '/applogs') {
    // Pull the phone's WHOLE journal on demand from the desktop:
    //   curl 'http://127.0.0.1:8732/applogs?token=…&since=0'
    // Fresh PUSH beats a doomed dial (inbound-refused Android): the
    // server-side mirror answers instantly and says source:'push'. A
    // dialable phone gets the live pull (source:'pull') with the pushed
    // mirror as its fallback — triage works from one URL either way.
    const since = Number(url.searchParams.get('since') ?? 0);
    const pushFresh = phoneJournal.at &&
        Date.now() - phoneJournal.at < Math.max(120000, appLogEveryMs * 12);
    const mirror = (fallbackFor) => JSON.stringify({
      ok: true, source: 'push', seq: phoneJournal.seq,
      floor: phoneJournal.events.length ? phoneJournal.events[0].seq : phoneJournal.seq,
      events: phoneJournal.events.filter(e => e.seq > since),
      flags: phoneJournal.flags,
      pushedAt: new Date(phoneJournal.at).toISOString(),
      ...(fallbackFor ? {note: `live pull failed (${fallbackFor})`} : {}),
    });
    if (pushFresh || !appPeer.host) {
      if (!phoneJournal.at) {
        res.writeHead(400).end('no phone journal yet — the app must talk first\n');
        return;
      }
      res.writeHead(200, {'content-type': 'application/json'});
      res.end(mirror(null));
      return;
    }
    const q = new URLSearchParams({token, since: String(since)});
    fetch(`http://${dialHost(appPeer.host)}:${appPeer.port}/applog?${q}`,
      {signal: AbortSignal.timeout(6000)})
        .then(async (r) => {
          const text = await r.text();
          if (!r.ok) { res.writeHead(r.status).end(text); return; }
          let j;
          try { j = JSON.parse(text); } catch { j = null; }
          if (j && j.ok) {
            ingestAppEnvelope(j, 'pull'); // relay + advance the watermark:
            // what curl just read is also in the journal, exactly as the
            // pump would have delivered it moments later
            res.writeHead(200, {'content-type': 'application/json'});
            res.end(JSON.stringify({source: 'pull', ...j}));
          } else res.writeHead(502).end('bad envelope from phone\n');
        })
        .catch((e) => {
          if (phoneJournal.at) {
            res.writeHead(200, {'content-type': 'application/json'});
            res.end(mirror(String(e))); // push mirror under a note
          } else res.writeHead(502).end(`phone unreachable: ${e}\n`);
        });
    return;
  }
  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: true, claudeUp: !childDead, sessionId,
      // Bridge wall clock: the phone calibrates its skew against this
      // (on every /health probe) so frame stamps become honest latencies.
      now: Date.now(),
      turnOpen, queued: !!pending,
      // v2 handshake: ids are law. An app that sees anything else
      // shows one honest error banner instead of guessing.
      proto: 2, turn: curTurnId,
      backgrounded: turnOpen && !curRes,
      // Open tool_use ids an interrupt (or a cuttool queue) parked
      // out-of-earshot, plus the agent's own run_in_background shells
      // (+133) — (+detached): every one owes the phone a
      // `tool finished` frame, until its result lands or the process
      // retires it.
      detached: detached.size + agentTasks.size,
      // Relayed and NOT yet acked by the phone: what /attach will
      // replay, even after the turn itself ended. v2: the phone trims
      // it with /heard, so this is literally the never-heard count —
      // the background banner's data source finally tells the truth.
      missed: backlog.length,
      // Last known phone-journal peer and our relay watermark: visible on
      // the app's Bridge screen (which renders /health) so you can see the
      // loop is closed from either end without touching a terminal.
      appLog: {
        peer: appPeer.host ? `${appPeer.host}:${appPeer.port}` : null,
        seq: appPeer.seq, // relay watermark (shared by both transports)
        down: appPeer.down,
        // 'push': phone POSTs (inbound-refused Android — the common
        // phone case). 'pull': dial-back works (desktop/LAN peers).
        // 'silent': known peer answering neither — frozen or killed.
        mode: (phoneJournal.at &&
                Date.now() - phoneJournal.at < 120000)
            ? 'push'
            : appPeer.host
            ? (appPeer.down ? 'silent' : 'pull')
            : null,
        pushedAt: phoneJournal.at
            ? new Date(phoneJournal.at).toISOString()
            : null,
      },
      // Last known context consumption and the model's window (0s until
      // the first result names them): lets a phone that missed the live
      // events still fill its context bar.
      context: lastCtx,
      // Pull transport available: GET /poll?since=N drains the ring from
      // the caller's cursor. {ring: newest seq, min: oldest retained} —
      // a client whose cursor rolled off jumps to min, not to zero.
      // A/B: BRIDGE_DISABLE_POLL=1 hides the advertisement and every
      // client falls back to the classic SSE push (the ring keeps
      // turning either way, so re-enabling is just a restart).
      ...(process.env.BRIDGE_DISABLE_POLL ? {} : {
        poll: {ring: ringSeq, min: ring.length ? ring[0].seq : ringSeq},
      }),
    }));
    return;
  }
  if (req.method === 'GET' && url.pathname === '/poll') {
    // The PULL transport companion to the event ring: {seq,events} since
    // the caller's cursor, oldest first. Each poll is an OUTBOUND request
    // from the phone's perspective — the one direction the cellular path
    // demonstrably never stalls (journal pushes ack in ms while pushed
    // frames sat 8–14 s), so event latency becomes one round trip.
    const since = Math.max(0, Number(url.searchParams.get('since') || 0));
    const evs = ring.filter((e) => e.seq > since).slice(0, 300);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ok: true, now: Date.now(), seq: ringSeq,
      min: ring.length ? ring[0].seq : ringSeq, events: evs}));
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
    // The pinger doubles as the quiet-heartbeat: an attaching phone
    // (post-zombie-hop!) that gets no deltas either still sees
    // "thinking" move. The curRes identity gate makes the heartbeat lie
    // dormant until this view actually owns the turn (or it never does,
    // if the turn ended and the replayed tail just closes us out).
    const keep = startKeep(res);
    // v2: replay does NOT clear the backlog — /heard does. What the
    // attacher takes gets acked and trimmed within the same second;
    // what it never reaches (a death mid-replay) legitimately waits
    // for the next ear instead of being consumed unseen.
    for (const { ev, data } of backlog) sse(res, ev, data);
    if (!turnOpen) { clearInterval(keep); res.end(); return; }
    // Become the turn's heard view — STEALING it from a (believed) attached
    // previous socket. That previous view's keep-pinger must die with it,
    // or a zombie-socket repair leaks an interval writing into the void
    // forever (the old socket's 'close' hook no longer matches curRes and
    // deliberately does nothing — identity moved on, by design).
    if (curRes) {
      console.error('  (/attach steals the view from the old socket)');
      const old = curRes;
      curRes = null; // endTurn's identity dance, then the new view takes it
      endKeep(old);
      try { old.res.end(); } catch {}
    }
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
      // v2: pushed turns open an SSE stream right here; polled POSTs
      // answer with a JSON receipt the transport writes itself.
      if (url.searchParams.get('poll') !== '1') {
        res.writeHead(200, { 'content-type': 'text/event-stream',
          'cache-control': 'no-cache', connection: 'keep-alive' });
      }
      // ?interrupt=0 = the polite queue (PTT slide-right): let the turn
      // in flight finish instead of interrupting a thinking-only one.
      // ?cuttool=1 = the queue-with-backgrounding (behaviour 2, the
      // app's Queue button): polite towards thinking, but a RUNNING
      // tool is backgrounded so the agent is freed for this prompt.
      // ?poll=1 = pull transport: the response carries the first frames
      // and closes; the rest of the turn rides the ring to GET /poll.
      talk(body.trim(), res, url.searchParams.get('interrupt') !== '0',
        url.searchParams.get('poll') === '1',
        url.searchParams.get('cuttool') === '1');
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
      agentTasks.clear();
      bgTools.clear();
      proactiveTurn = false;
      detached.clear(); // a fresh conversation inherits no banner promise
      heldFinished.length = 0; // …nor a receipt still owed one
      // A reset conversation has nothing unheard: drop the replay backlog
      // or the next /attach (a later cold start, a respawned app) dutifully
      // re-speaks the dead conversation's tail as if it still mattered.
      backlog.length = 0;
      // The dead conversation's size is not the fresh one's: drop the
      // context snapshot (and any preview run) so the bar goes blank
      // instead of wearing old numbers. /health reports in:0 from now
      // on until the new session's first message_start proves itself.
      lastCtx = { in: 0, window: ctxWindow };
      estIn = estSentIn = 0;
      if (pending) { endKeep(pending); if (!pending.res.writableEnded) pending.res.end(); pending = null; }
      heldFinished.length = 0; // the flush that owed them is gone
      endTurn();
      child?.kill('SIGTERM'); child = null; childDead = true;
      res.writeHead(200).end('ok\n');
    } else if (url.pathname === '/heard') {
      // v2: the phone's commit ack. A mid leaves the unheard backlog
      // the moment the phone TAKES the paragraph (speak-path or chat
      // log); a later barge-in does not retract it — dropped is
      // dropped. Idempotent by design: unknown or already-trimmed
      // mids are no-ops, so a lost ack POST simply retries from the
      // phone's ledger and the worst case is one replay the phone's
      // own heard-set swallows.
      let j = null;
      try { j = JSON.parse(body); } catch {}
      const mids = new Set((Array.isArray(j?.mids) ? j.mids : [])
        .map(Number).filter(Number.isFinite));
      for (let i = backlog.length - 1; i >= 0; i--) {
        if (mids.has(backlog[i].data?._mid)) backlog.splice(i, 1);
      }
      console.error(`  [heard] ack=${mids.size} backlog=${backlog.length}`);
      res.writeHead(200, {'content-type': 'application/json'})
        .end(JSON.stringify({ok: true, missed: backlog.length}));
    } else if (url.pathname === '/applog') {
      // PUSHED journal envelope (see ingestAppEnvelope): the transport for
      // phones nothing can dial back into. Body is the exact envelope
      // GET /applog serves; one shared ingest, so push and pull can never
      // diverge. 'ok' only on accept — the app advances its ack watermark
      // on that alone (at-least-once; dedupe by seq on this side).
      let j = null;
      try { j = JSON.parse(body); } catch {}
      const ok = j && ingestAppEnvelope(j, 'push');
      res.writeHead(ok ? 200 : 400).end(ok ? 'ok\n' : 'bad envelope\n');
    } else res.writeHead(404).end();
  });
});
// no claude yet until first spawn
if (!existsSync(claudeBin)) { console.error(`no claude at ${claudeBin}`); process.exit(1); }
if (!token) { console.error('set --token or BRIDGE_TOKEN'); process.exit(1); }
try { sessionId = readFileSync(sidFile, 'utf8').trim(); } catch {}
spawnClaude(sessionId || undefined);
server.listen(port, '0.0.0.0', () => console.log(`voice bridge on :${port} dir=${dir} sid=${sessionId ?? 'new'}`));
