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

- `POST /talk?token=…` — body = the utterance text → SSE stream:
  `say` {text} (a complete assistant message, speak it), `tool`
  {name,detail} (the harness is running something — speak a short
  progress line or ignore), `done` {isError} (turn over), `error`.
- `POST /stop` — barge-in: SIGINT only while a turn is in flight (SIGINT
  on an *idle* process kills it; next `/talk` respawns and `--resume`s,
  context intact — both paths verified).
- `POST /new` — forget the conversation; `GET /health` — liveness.
- Session id persists to `<dir>/.claude_bridge_session`, so a bridge
  restart resumes the same voice conversation.

Verified end-to-end on this machine:
- two utterances, one process, second answered in-context (secret word);
- a real `Bash` tool run narrated as `tool` events + a spoken result;
- claude's auto-memory wrote the secret word to its memory file and
  recalled it across turns *and* across a bridge restart;
- bridge restart → `--resume` → same session, no context loss;
- `--permission-mode acceptEdits` + our voice system prompt (spoken
  sentences, no markdown/emoji — the TTS reads lists terribly).

Cost note: the `total_cost_usd` fields are the client's estimates
against Anthropic pricing — on the local `flash-next` proxy they're
fiction. One caveat found: `unrecognized_model` on stderr at startup is
harmless probe noise here (turns still succeed).

## App-side plan (Flutter, next task)

The pieces all exist already; this swaps the *text source* of a reply.

1. `BridgeClient` (new, `lib/bridge_client.dart`): `http` + streamed
   `POST /talk`, hand-parse the few SSE line shapes (no new package; the
   pack downloader already streams over `http`). Settings UI: base URL +
   token, tested against `/health`.
2. `_startTurn`: after Whisper, if bridge mode is on — instead of
   parroting the transcript — open `/talk` and feed each `say` event's
   text through the *existing* sentence-chunking synth path
   (`_replyQueue` was built exactly for play-while-it-arrives).
   Per-message (not per-token) streaming is the right granularity for
   TTS anyway: sentence chunks, no half-word ever spliced.
3. Barge-in: PTT release/`interrupt()` during a reply additionally POSTs
   `/stop` (the app's echo guard already keeps it from answering itself).
4. `tool` events: speak a one-liner ("running the tests now") when a
   tool starts — the bridge's voice system prompt already asks for a
   narration line, which arrives as its own `say` before the tool_use,
   so even a v1 that ignores `tool` still narrates via `say`.
5. Long task answers: prompt says "1–3 sentences"; belt-and-braces, run
   the final text through a markdown-stripper before TTS (code blocks,
   `**` and bullet lines would otherwise be *spoken*).

Latency: local proxy turn ≈ 1–6 s for chat-ish answers (the bridge
speaks the *first sentence* as soon as the first assistant message
closes; tool-heavy tasks speak the narration line early and the summary
when done). TTS adds ~0.1 × seconds-of-speech. The whole loop lands
well inside conversational feel.

## Run it at boot (systemd user unit)

    # ~/.config/systemd/user/claude-voice-bridge.service
    [Unit]
    Description=Voice agent -> Claude Code bridge
    [Service]
    ExecStart=/usr/bin/node %h/voice-agent/tool/claude_bridge.mjs --dir %h/voice-agent --token CHANGE_ME
    Restart=always
    Environment=BRIDGE_TOKEN=CHANGE_ME
    [Install]
    WantedBy=default linger
    # systemctl --user enable --now claude-voice-bridge && loginctl enable-linger $USER

## Open questions for the user

- Which project dir should the harness live in by default? (prototype
  ran against a scratch dir; `--dir` is the whole story.)
- Should permission prompts round-trip to the phone (Agent SDK
  `canUseTool` — "can I run npm test?" heard and answered by voice), or
  is voice-driving a sandboxed scratch dir with `acceptEdits` enough?
- Confirm the harness identity intended is Claude Code (not this
  OpenCode); `opencode serve` gives the same bridge for it.
