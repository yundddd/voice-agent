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
- Latency and context size, stated plainly: the upstream proxy has no
  working prompt cache (observed `cache_read_input_tokens: 0` on every
  call, even back-to-back ones), so every request re-prefills the whole
  conversation — a 128k-token chat pays ~10 s even for "hello". The
  bridge does not auto-compact to hide this; `/new` and `/compact`
  remain the user's manual levers (app chips), and the context bar +
  preview frames exist precisely so the number that drives latency is
  visible while it grows.
- `POST /stop` — in-band interrupt (`control_request` on the CLI's
  stdin control protocol) while any turn is OPEN. The turn ends, context
  and the process both survive (SIGINT was the old mechanism — in
  headless `-p` mode it kills the whole process, and the next `/talk`
  then respawns with `--resume`, whose rebuilt request prefix misses the
  prompt cache and pays a full cold prefill; verified both ways).
- `POST /new` — forget the conversation (also clears a background turn
  and a queued prompt); `GET /health` — liveness + `turnOpen` /
  `backgrounded` / `queued` flags + `context` (last known EXACT
  tokens-in-context and the model's window, snapshotted at every
  result; zeroed by `/new`, previews never enter the snapshot). Mid-
  turn the same numbers reach the phone on `context` SSE frames —
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
   process never dies, so the warm prompt-cache prefix keeps working).
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
   Bash flutter test"). The bridge's voice system prompt asks the
   harness for a one-line narration *before* each tool pass, which
   arrives as its own speakable `say` — so long commands never dead-air.
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

Latency: local proxy turn ≈ 1–6 s for chat-ish answers (the bridge
speaks the *first sentence* as soon as the first assistant message
closes; tool-heavy tasks speak the narration line early and the summary
when done). TTS adds ~0.1 × seconds-of-speech. The whole loop lands
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
