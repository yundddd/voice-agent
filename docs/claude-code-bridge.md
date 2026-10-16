# Talking to the Claude Code harness from the phone

Goal: speak into the voice agent → text goes to a Claude Code harness on
the desktop → the harness's answer comes back and is spoken by the app's
TTS. Researched 2026-10-15; findings below are **verified live on this
machine** (claude 2.1.296, node 22, tailscale installed, local sglang
proxy `flash-next` via `ANTHROPIC_BASE_URL` in `~/.claude/settings.json`).

## The integration surfaces (researched)

| Way | What it is | Verdict |
| --- | ---------- | ------- |
| **Headless CLI stream-json** | `claude -p --input-format stream-json --output-format stream-json` — one process, JSONL in on stdin, JSONL events out. Multi-turn over a single process lifetime; `--resume <session_id>` restarts later with context. | **Verified, recommended core.** Works today; a whole agent (tools, memory, CLAUDE.md, skills) behind a pipe. |
| **One-shot per turn** | `claude -p "<text>" --resume <sid> --output-format json` per utterance, no persistent process. | Simplest, but pays CLI startup + context reload every turn (+1–3 s). Good fallback if the long-lived pipe ever wedges. |
| **Agent SDK (TS/Python)** | `@anthropic-ai/claude-agent-sdk` `query()` with streaming input — the same protocol, wrapped as a library with typed messages, `interrupt()`, and a `canUseTool` callback. | The "official" version of the bridge below. Reach for it when we want permission prompts relayed to the phone ("can I run the tests? yes/no by voice"). |
| Community HTTP/WebUI wrappers | Various OSS projects exposing claude over REST/WebSocket. | Workable, but they own the lifecycle and UI assumptions; a ~150-line bespoke bridge is easier to voice-tune. Skipped. |
| `opencode serve` | The other harness on this box; HTTP + SSE event API for sessions. | Same bridge shape, different backend — if "the harness on my machine" should ever mean *this* OpenCode session, that's a one-function swap. |

The phone-to-bridge transport: **Tailscale** (this machine is already in
the tailnet — the model proxy itself is reached over `*.ts.net`): install
the Android app, address `http://<machine>.<tailnet>.ts.net:8732`, no port
forwarding, no LAN-IP roulette, plus a shared `?token=` since tailscale
ACL, not the bridge, does identity. Plain LAN `http://192.168.x.x:8732`
works too (token still required; traffic is cleartext on the LAN).

## Prototype: `tool/claude_bridge.mjs` (this commit)

Zero-dependency Node bridge (no npm install): holds one long-lived
`claude -p` child, exposes voice-shaped **SSE** events to callers.

    node tool/claude_bridge.mjs --dir ~/some-project --token SECRET [--port 8732]

- `POST /talk?token=…&interrupt=1` — body = the utterance text → SSE
  stream: `say` {text} (a complete assistant message, speak it), `tool`
  {name,detail} (the harness is running something — speak a short
  progress line or ignore), `done` {isError} (turn over), `error`.
  Detaching mid-turn (closing the SSE without `/stop`) does NOT cancel
  the work: the turn goes BACKGROUND — the harness finishes, output is
  dropped, and the session's next `result` frees the slot. The next
  `/talk` while a turn is in flight (heard or backgrounded) is QUEUED
  (never refused): it gets a `tool queued` progress line, then its turn
  arrives. If the open turn has a tool call, the queue waits for it
  either way (Claude Code's "background the long job, type the next
  thing"). If it was only thinking, the `interrupt` flag decides: `1`
  (the default — typed text, spoken barge-in, push-to-talk slide-UP)
  cuts the thinking turn with an IN-BAND interrupt (a `control_request`
  on the CLI's stdin control protocol) and the queue flushes in a
  heartbeat; `0` (push-to-talk slide-right, the polite queue) lets the
  turn in flight run to its natural end first. `/stop` hard-stops an open turn either
  way (attached or backgrounded); a queued prompt then takes over on its
  result. `context {in,window}` frames ride the same stream: exact at
  every API call start and authoritative before `done`, plus PREVIEW
  frames (`preview: true`) whenever the bridge sees the next call's
  input grow (fresh tool_result outputs) while the model is still
  reading. The same numbers snapshot into `GET /health` as `context`,
  so even a phone that never attached gets the reading (the app paints
  it as a context bar above the talk button, Claude Code style).
- Latency and context size, stated plainly (corrected by field probe,
  2026-10-16, docker logs in hand): the serving stack HAS a working
  prefix (radix) cache — intra-turn tool-loop calls log
  `#cached-token: 349k+` with 64–448-token incremental prefills — but
  it cannot serve CROSS-TURN voice utterances: the Claude Code CLI
  re-initializes and re-renders its whole request on every user message
  (a fresh `system/init` per turn, same process — probe: msg2 of a
  two-message session re-prefilled `#new-token: 15936, #cached-token:
  0` with the repo untouched), so the prompt prefix is never
  byte-stable between turns; the Anthropic-compat layer reports
  `cache_read: 0` structurally regardless (which is what made the old
  draft say "no working prompt cache" — right behaviour, wrong
  mechanism), and the hybrid linear-attention server keeps only a few
  cached prefix branches (mamba slots), so a second concurrent session
  flushes the tree (observed: full usage 0.37 → 0.02) and even a
  stable prefix pays one re-prefill after a flush. Net: every voice
  utterance pays ~context/prefill-rate — a 128k chat ~10 s even for
  "hello", ~9 s measured at 156k — and background/foreground churn
  does not change that (the reattach path only changes who is LISTEN-
  ING, never what is SENT). The bridge still does not auto-compact to
  hide this; `/new` and `/compact` remain the user's manual levers
  (app chips), the context bar shows the number that IS latency, and
  the per-turn `[census]` line now prints time-to-first-partial as an
  explicit PREFIX CACHE HIT/MISS verdict — so this paragraph is
  checkable from the journal, not folklore.
- Progress that cannot read as "ignored" (0.1.0+30): a turn's FIRST SSE
  frame is now a `tool {name:"tokens", kind:"thinking"}` tally (out 0,
  in = best known), so the phone's working line flips from "Asking the
  bridge…" to "thinking · … in · Ns" within one RTT of the prompt —
  before the upstream has proved anything. Whether the NUMBER then
  moves is the upstream's decision, and the bridge now measures it
  instead of assuming: a per-turn `[census]` stderr line logs which raw
  CLI event shapes actually arrived under `--include-partial-messages`
  (first partial, per-kind counts, delta chars, usage tokens) and
  pronounces the verdict — LIVE DELTAS (ticker streams normally) /
  USAGE-ONLY (numbers settle once per message; heartbeats carry the
  spinner between settles) / NO LIVE EVENTS (proxy buffers SSE
  wholesale — an OpenAI-style upstream behind the Anthropic facade, or
  a CLI too old for partials — so only elapsed + quiet frames prove the
  turn breathes). And while a heard, model-side (no open tool) turn
  relays nothing for `--tok-heartbeat` ms (default 5000; 0 = off), the
  keep-pinger pushes the tally marked `{quiet:true}` — its detail
  literally ends "no deltas from upstream", so "thinking" never decays
  into "stuck" silently. Quiet frames only fire when nothing else
  moved, so they never stutter over a live ticker; the phone treats the
  frame's number as authoritative including the 0 that opens a turn
  (one turn's tally can never bleed into the next).
- `POST /stop` — in-band interrupt (`control_request` on the CLI's
  stdin control protocol) while any turn is OPEN. The turn ends (its
  `result` arrives with `is_error: true` — an interrupted turn's
  "error" IS the interrupt, and the bridge now logs `[result-error]`
  with the reason text instead of the old anonymous 1588-byte shrug),
  context and the process both survive. SIGINT was the old mechanism —
  in headless `-p` mode it kills the whole process, and the next
  `/talk` then respawns with `--resume`, re-hydrating the transcript
  from disk (slower to first token than an in-band cut, and the
  rebuilt request misses the prefix cache like every other cross-turn
  request from this CLI — see the latency bullet).
- `POST /new` — forget the conversation (also clears a background turn,
  a queued prompt, AND the replay backlog — a later attach must not
  resurrect a discarded conversation's tail); `GET /health` — liveness +
  `turnOpen` / `backgrounded` / `queued` flags + `context` (last known
  EXACT tokens-in-context and the model's window, snapshotted at every
  result; zeroed by `/new`, previews never enter the snapshot) + `appLog`
  (the phone-journal poller: peer address, watermark, reachability).
  `GET /applogs?since=N` — proxy live to the phone app's OWN event
  journal (see app-side item 9): the phone's account of a misbehaving
  turn, curl-able from the desktop. Mid-turn the same numbers reach the
  phone on `context` SSE frames —
  exact at every message_start and at the result, PREVIEWED (a
  `preview: true` frame) at turn start from the last exact figure plus
  the utterance's size, and again on every fresh tool_result: the
  input bar grows while the model is still reading a fat transcript,
  instead of the box sitting on "Asking the bridge…" until the API
  proves the number (and the app's spinner line carries the
  best-known in-count even while frozen over a tool run).
- Session id persists to `<dir>/.claude_bridge_session`, so a bridge
  restart resumes the same voice conversation.

Verified end-to-end on this machine:
- two utterances, one process, second answered in-context (secret word);
- a real `Bash` tool run narrated as `tool` events + a spoken result;
- claude's auto-memory wrote the secret word to its memory file and
  recalled it across turns *and* across a bridge restart;
- bridge restart → `--resume` → same session, no context loss;
- (2026-10-16 re-verification) ONE process survives multiple user
  messages (probe: two messages, exit only on stdin close) — but it
  emits `system/init` per user message and re-renders the request
  every turn: msg2 paid a full `#new-token` prefill with the repo
  untouched between messages. Cross-turn prefix-cache misses are the
  CLI's own behaviour, independent of the bridge, the reattach path,
  or background/foreground; the earlier 'one process kept warm by
  avoiding --resume' framing overstates what stays warm (see latency
  bullet above);
- `--permission-mode bypassPermissions` approves every tool without a
  prompt — the only sane default for voice (verified A/B on 2.1.296:
  under `acceptEdits` WebFetch comes back silently *denied*, under
  bypass it fetches and answers). Explicit `deny` rules still win under
  bypass, so `WebSearch` stays forbidden by your settings either way.
  Tighten with `--permission-mode acceptEdits|dontAsk` if the voice
  ever stops being the only trigger.
- our voice system prompt (spoken sentences, no markdown/emoji — the
  TTS reads lists terribly).

Cost note: the `total_cost_usd` fields are the client's estimates
against Anthropic pricing — on the local `flash-next` proxy they're
fiction. One caveat found: `unrecognized_model` on stderr at startup is
harmless probe noise here (turns still succeed).

## App side (shipped in 0.1.0+8 — lib/bridge.dart, lib/bridge_screen.dart)

All the pieces already existed; this swapped the *text source* of a reply.
Originally shipped as four canned-prompt chips (Repo status / Run tests /
Build APK / Catch me up — `VoiceAssistant.quickCommands`); superseded in
0.1.0+17 by session controls (`/new`, `/compact`, see item 7) plus
**Stop** while a turn flies, and a free-text box on
the Bridge screen. Notes that matter when touching this code:

1. `BridgeClient` (`lib/bridge.dart`): `dart:io` `HttpClient` + streamed
   `POST /talk`, SSE parsed by a pure line state machine
   (`bridgeEventsFromLines`, unit-tested without a socket). No new
   package — the pack downloader already streams over `dart:io`.
   Settings persist next to the TTS prefs (`bridge_prefs.json`).
   Android needed `usesCleartextTraffic="true"` (the bridge is plain
   http; all other app traffic stays https).
2. `VoiceAssistant.runQuickCommand(utterance)` (chips and free text both
   route here): bumps `_generation` (supersedes any live voice reply),
   warms the output route, then feeds each `say` event through the
   *existing* chunked synth path (`_replyQueue`/`_playReplyChunks`) the
   moment it lands — play begins while the harness still composes the
   next message. Per-message (not per-token) granularity is right for
   TTS: whole sentences, no half-word ever spliced.
3. Barge-in has two flavours (`_abandonBridgeTurn`). A SPOKEN takeover —
   VAD speech-start mid-reply, or any new voice/typed turn — DETACHES:
   the generation is bumped and the /talk subscription is cancelled, so
   the bridge backgrounds the turn (the harness keeps *working*: long
   tool calls run to completion; their output is dropped). The utterance
   that follows becomes a fresh `/talk` seconds later and is queued:
   behind an open tool, or ahead of a cut-short thinking turn (the
   bridge cuts those at queue time with an in-band interrupt — the
   process never dies, so no respawn and no transcript re-hydration;
   note this does NOT keep a warm prompt cache across turns either —
   this CLI re-renders its request per user message, see the latency
   bullet above, which is why barge-in costs an interrupt's result,
   not a prefill surprise).
   A TAPPED stop — Stop chip, FAB,
   mode switch, clone/bench takeover — is the hard flavour: same detach
   plus a `/stop` (in-band interrupt) so the harness quits working too
   (verified semantics: mid-turn interrupt ends the turn with context
   and process intact; the conversation resumes on the next chip).
   PUSH-TO-TALK releases steer
   by GESTURE (0.1.0+25, `pttDown`/`pttUp` in `assistant.dart`): the
   press over a running turn detaches it (the tool call backgrounds and
   keeps working, output dropped) and opens the mic; a slide-UP release
   sends the new prompt with `interrupt=1` (a mere thinking turn is cut,
   an open tool still finishes first — the prompt goes next either way);
   a plain or slide-RIGHT release sends with `interrupt=0` (polite
   queue: the turn in flight completes, then the prompt is processed);
   a quick tap stays the hard stop (detach + `/stop`). The terminal-icon
   badge stays lit while a detached turn works unheard
   (`harnessBackgrounded`).
4. `tool` events show as live status text ("The harness is working —
   Bash flutter test"). Tool steps are quiet by default: the bridge's
   voice system prompt only asks the harness for a one-line narration
   *before* each tool pass when started with `--narrate-steps` (that
   line arrives as its own `say`, which the phone always speaks — the
   app's Narrate switch can't hush it), and the app's own `tool`-event
   narration sits behind its Narrate switch, off from the factory.
   With either on, long commands never dead-air.
5. Everything spoken passes `cleanForSpeech`: code blocks → "(code
   omitted)", links → their text, markdown/heading/bullet syntax
   stripped, bullet lines joined with "and", sentence stopper appended
   (Piper reads a comma-final clause oddly). Unit-tested in
   `test/bridge_test.dart`.
6. Voice routing (0.1.0+10): `_startTurn` checks `_bridgePrefs.voice`
   (factory on) and hands the transcript to `runQuickCommand` instead of
   the parrot synth — one code path for typed chips and spoken commands.
   Guards that already existed upstream keep working: the empty/"say a
   little more" filters, and the self-echo check, run before forwarding.
   While a harness turn is in flight the FAB reads "Stop the harness"
   (PTT mode included, where the button used to be greyed out dead air).
7. Session controls (0.1.0+17): the main-screen chips became `/new` and
   `/compact` (`VoiceAssistant.bridgeControl`), and the bridge learned
   to pass slash lines through to the CLI as commands. Wire facts
   verified on 2.1.296: a user message with block-array content goes to
   the *model* even when the text is `/compact` (it rambles about the
   word); only PLAIN-STRING content executes. `/compact` runs in-process
   on the resumed session — proof is a `system/compact_boundary` event
   (relayed as a `tool compact` SSE line so the phone shows live
   progress) and zero narration, so the app speaks a locally composed
   ack; if the CLI does answer (e.g. "No messages to compact" arrives
   as an assistant text block on an empty session) that answer relays
   and the ack suppresses. `/new` is NOT sent over stdin: stream-json
   has no /new, and the bridge's own endpoint must also forget the
   persisted session id or the next respawn re-hydrates the old
   context. The chip also clears the APP's chat log (memory and
   `chat_log.json`) from the same events hook, so "a fresh
   conversation" means a blank screen on the phone exactly when the
   harness drops its session — the spoken ack promises as much. Free
   text with a leading `/` runs any CLI command the same
   way (`/context`, `/usage`, ...) — and the CLI's own error replies
   arrive speakable, so nothing dead-airs.

8. Surviving background → foreground (`0.1.0+28`): a hidden phone kills
   bridge streams three different ways, and each got its own repair. The
   app records *wire liveness* — `talk`/`attach` take an `onActivity`
   callback fired by **every raw chunk**, including the bridge's 15 s
   `: ping` comments, so "no bytes for 24 s" is proof the connection is a
   zombie (a black-holed route sends no FIN, so a plain listener never
   learns); the quiet-wire watchdog then drops the dead view and reattaches.
   A socket that *does* error/EOF mid-turn is caught in the event loop's
   teardown: an **unowned** death (no `done`, no `error` frame, still
   holding the busy flag — a deliberate barge-in/PTT/stop detach always
   clears that first, and `_abandonBridgeTurn` also silences any running
   reattach chain so it can't steal the view off the queued successor)
   triggers the reattach chain instead of just going idle. That chain —
   also run on cold start and on resume — consults `bridgeReattachNeeded`
   (a pure decision fn over the `/health` snapshot, unit-tested): open
   turn or non-empty backlog → GET /attach; nothing open and nothing
   unheard → go idle; bridge unreachable (**null**, because a waking
   phone wakes its *network* late and one failed probe must never drop a
   live turn) → re-probe up a 2/6/15/40 s ladder. `/attach` itself was
   hardened to **steal** the heard view from a socket the bridge still
   believes attached (that's how a zombie repair takes delivery back
   before the harness relays more into the void; the old view's keep-
   pinger is retired on the swap, no leaked interval), and `/new` now
   clears the replay backlog so a later cold-start attach can't resurrect
   a discarded conversation's tail. Says that landed WHILE hidden are
   logged text-only (hidden skips synth entirely), so resume also owes
   the ear the *last* buffered block — the backlog can't replay what was
   already delivered to the dead view. `_speakResumedPending` pays that
   debt with NO generation bump (a bump would supersede the still-live
   /talk loop and orphan it): the stream that survived the hide replays
   it straight into the live turn's chunk queue, and the death-event
   reattach carries it as `replayFirst` and speaks it ahead of its
   backlog lines, story order intact. Net effect: hide the app
   mid-tool-call or mid-answer and foregrounding either keeps streaming
   on the same socket, rejoins via the death-event reattach in ~2 s, or
   hops through the watchdog within one quiet window — and the message
   you were owed is spoken either way.

9. App-side journal + bridge polling (0.1.0+29): the app now records its
   OWN lifecycle story — every raw OS lifecycle callback (before the
   hidden/paused folding, because the ordering is the bug), hide/resume
   decisions with the flag snapshot the app believed, stream opens,
   exactly HOW each stream died (`done clean` / `SOCKET DIED` / `CLOSED
   WITHOUT DONE — UNOWNED`), every reattach probe verdict with the
   turnOpen/backgrounded/missed fields behind it, watchdog zombie hops,
   intentional detaches, ptt takeover, /stop — into `app_events.jsonl`
   (a seq-numbered ring, so an Android process kill cannot erase the
   evidence; the cold-start reattach then literally reads the story of
   its own death). `lib/app_events.dart` serves it to the LAN/tailnet:
   `GET http://<phone>:8733/applog?token=<same bridge token>&since=seq`
   (walks the port upward if occupied; the chosen port is announced to
   the bridge as `?logport=` on every app request, and the peer address
   is simply the request's source — the same route the turn rides, so
   the return leg traverses no NAT puzzle). The bridge (`--applog-interval`,
   default 5000 ms, 0 = off) polls that endpoint and relays new entries
   to its stderr tagged `[app HH:MM:SS.mmm]` — one `journalctl
   -u claude-voice-bridge` now interleaves BOTH machines' views of one
   misbehaving turn, each stamped by its own clock. Poll failure is
   itself telemetry: three consecutive misses (the app frozen by the OS
   cached-process freezer, or killed) log `not answering — app frozen
   or killed?` exactly once, and the recovery line + the burst of
   phone-clock timestamps when the journal refills bracket the freeze
   window from the inside — which is precisely the datum the
   reattach-race triage was missing. `GET /applogs?since=0` on the
   bridge proxies a live full pull for curl, `/health` gained an
   `appLog` block (peer, watermark, reachability — also visible on the
   app's Bridge screen, which renders /health raw), and token-tally
   frames are deliberately kept OUT of the journal (they ride every
   0.8 s and would flush the 240-entry story of the turn being
   troubleshot out of the ring).
   PUSH transport (0.1.0+32) after field testing: the dial-back premise
   FAILED on real phones — the Android Tailscale client accepts no
   inbound connections (the phone's tailnet peer advertised no such
   capability), and behind carrier NAT there is no route to dial at all
   — so bridge→phone polling logged `connection refused` forever,
   indistinguishable from the app being frozen. Every relayed entry now
   runs through ONE ingest path whether PULLED (GET /applog, dialable
   dev peers, polled on --applog-interval) or PUSHED (POST /applog: the
   app sends the same envelope outbound, batched behind a 3 s debounce,
   the watermark advancing only on the bridge's `ok`, backing off while
   unreachable, and force-flushed at the hide/resume bookends — exactly
   the moments a freezing isolate would otherwise swallow, since
   freeze-window measurement turns on those timestamps). At-least-once
   push + seq-dedupe at the bridge = convergent. The last pushed
   envelope is mirrored server-side (240 entries + flags): `GET
   /applogs` answers from the mirror (source:'push') when the phone
   can't be dialed and falls back to the mirror when a live pull fails;
   /health's `appLog.mode` reports push / pull / silent (silent = the
   phone answers neither: frozen or killed), and the pump deliberately
   stays quiet about dial refusals while pushes prove life — an
   inbound-refused Android phone is a normal phone, not an outage.

Latency: local proxy turn ≈ 1–6 s for chat-ish answers (the bridge
speaks the *first sentence* as soon as the first assistant message
closes; tool-heavy tasks with narration enabled — the app's Narrate
switch or the bridge's --narrate-steps — speak a progress line early and
the summary when done; by default they speak only the summary). TTS adds
~0.1 × seconds-of-speech. The whole loop lands
well inside conversational feel.

## Run it at boot (installed on this machine: 2026-10-15)

Installed at `~/.config/systemd/user/claude-voice-bridge.service` (linger
is on, so it runs without an open terminal); token `testtok` to match the
APK's baked-in default. Rotate = edit `--token` here, rebuild or retype
the token in the app's Bridge screen.

    [Unit]
    Description=Voice agent -> Claude Code bridge
    After=network-online.target
    Wants=network-online.target

    [Service]
    # /snap/bin: the harness's Bash tool needs flutter/dart for the
    # test/build chips; ~/.local/bin: the claude launcher itself.
    Environment=PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin:/home/tim/.local/bin
    Environment=LD_LIBRARY_PATH=/home/tim/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64
    ExecStart=/usr/bin/node /home/tim/voice-agent/tool/claude_bridge.mjs --dir %h/voice-agent --token testtok
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=default.target

    # systemctl --user daemon-reload && systemctl --user enable --now claude-voice-bridge
    # journalctl --user -u claude-voice-bridge -f      # live claude stderr/EVT lines

On restart the bridge re-`--resume`s the last session id automatically
(saved to `<dir>/.claude_bridge_session`), so the voice conversation
survives bridge and machine reboots too.

## Open questions for the user

- Which project dir should the harness live in by default? (prototype
  ran against a scratch dir; `--dir` is the whole story.)
- Should permission prompts round-trip to the phone (Agent SDK
  `canUseTool` — "can I run npm test?" heard and answered by voice), or
  is voice-driving a sandboxed scratch dir with `acceptEdits` enough?
- Confirm the harness identity intended is Claude Code (not this
  OpenCode); `opencode serve` gives the same bridge for it.
