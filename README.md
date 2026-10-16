# Voice Agent

On-device voice assistant prototype in Flutter: you speak, the app transcribes
your speech **on-device**, and speaks the transcription back — the full
speech-to-text → text → speech-to-text round trip runs with no network.

That "future gateway" now exists for the desktop Claude Code harness (see
"Claude Code bridge" below): one tap or one spoken command, the harness on
your machine does the thinking, and the answer comes back spoken in your
chosen voice. Both speech models still stay on the phone.

## Research: which on-device models?

Constraint: two models (ASR + TTS) must run on Android **and** iOS phones,
offline, with reasonable latency and footprint.

The stack chosen here is **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
+ its [Flutter plugin](https://pub.dev/packages/sherpa_onnx)** — one Dart FFI
API for both models, onnxruntime bundled per platform (apk/aar splits and an
xcframework for iOS), actively maintained (v1.13.x), MIT licensed. Main
alternatives considered:

| Area | Candidates | Verdict |
|---|---|---|
| Runtime | **sherpa-onnx**; whisper.cpp (+FfiWhisper/whisper_plus); ML Kit (Android STT / iOS Speech — partly server-backed); Vosk (aging, weak TTS story); Picovoice/Cobalt (commercial licensing) | sherpa-onnx covers ASR **and** TTS **and** VAD from one plugin, ONNX-wide model zoo, no licensing issues |
| ASR (English) | **Whisper tiny.en** (~100 MB int8 shipped here); Moonshine tiny (≈20 MB, faster, streaming-capable); NeMo Parakeet TDT 0.6B v2/v3 int8 (~110 MB, best accuracy/latency trade-off, up to 25 EU languages for v3); zipformer transducers (true streaming, small variants); SenseVoice (zh/en/ja/ko/yue) | Started with Whisper tiny.en: robust and simple. For a real assistant, next step is **Moonshine** or a **streaming zipformer transducer** for lower latency partial transcripts; Parakeet v2 if accuracy matters more than size |
| ASR (multilingual) | SenseVoice, Qwen3-ASR 0.6B int8, FireRed ASR 2 CTC, zipformer bilingual | Swap-in via `ModelPaths` + worker config, no other code changes |
| TTS | **Piper VITS** (`en_US-lessac-medium`, this prototype; `amy-low` also downloaded — swap by replacing the asset zip); Matcha-icefall (smaller/faster, phoneme lexicon, no espeak dir); Kokoro-82M (top quality at ≈334 MB fp32 — shipped as the 'Kokoro v1.0' voice; int8 quantization measured worse in both fidelity and CPU speed); MeloTTS (multilingual); **Pocket TTS** (Kyutai 100M zero-shot clone — shipped as a downloadable voice, sherpa-onnx support since v1.12.24); silero/supertonic (commercial license traps) | Piper medium is the quality/size sweet spot (61 MB model + 19 MB espeak-ng-data) and runs ~20–70× faster than real time on desktop CPU; expect real-time or better even on mid-range phones. Pocket TTS adds reference-voice cloning inside sherpa itself; Kokoro is the remaining upgrade path |
| VAD | **Silero VAD** (0.6 MB, bundled in the APK) | Wired in for conversation-mode endpointing (1 s pause = stop) and barge-in detection. Tuned to `threshold 0.35 / minSpeechDuration 0.15`: Silero only raises after speech sustains past the threshold, and sherpa rewinds segment starts by `minSpeechDuration + 2 windows` (`voice-activity-detector.cc`), so a lower threshold raises earlier and the rewind fully covers the attack — no clipped beginnings (`tool/onset_probe.dart` checks exactly this). `minSilenceDuration` remains the endpointing knob |

Measured on this dev machine (Intel, 4 threads, debug FFI — phones will be slower but still far under real-time):

```
ASR: 6.6 s of speech → text in 150 ms   (RTF ≈ 0.02)
TTS: text → 5.1 s audio in 111 ms       (RTF ≈ 0.02)
```

APK footprint: the two model packs (~60 MB ASR + ~64 MB TTS zips) are **not**
in the APK — the app downloads them from the project's GitHub release on first
run and unpacks them once into app-support storage (`lib/model_packs.dart`).
That download path is already the CDN seam: pointing `modelPacks` at the
gateway later is a two-line change. Only the 0.6 MB VAD model is bundled.

## App structure

```
lib/
  main.dart           UI: mode switch (Conversation / Push to talk), mic button,
                    transcript, latency strip, app-lifecycle observer
  assistant.dart    Conversation state machine: endpointing, barge-in, turns,
                    background pause / foreground resume
  speech_worker.dart  Isolate owning both models (FFI calls never touch UI isolate)
  audio_dsp.dart    Mic front end: high-pass, noise floor, speech gate, PTT denoise
  model_paths.dart  Model file locations (injected → testable)
  model_packs.dart  Downloaded zips → app support dir (first run only)
  audio_io.dart     PCM16↔float32, WAV encode/decode
test/roundtrip_test.dart  Headless round trip + VAD endpointing on wav fixtures
test/gate_test.dart       Noise floor / high-pass / gate / denoise unit tests
```

### Signal pre-processing (why it doesn't hear itself, and survives noise)

Every mic window goes through a small DSP chain in the worker isolate
(`audio_dsp.dart` + the state machine in `speech_worker.dart`) **before**
Silero ever sees it:

1. **High-pass (120 Hz, RBJ biquad)** — kills handling rumble, desk
   vibration and AGC DC before they can waste VAD/Whisper bandwidth.
2. **Noise floor tracker** — min-statistics over frame RMS: instant drop,
   ~0.6 dB/s rise, so the estimate always sits at the true room floor
   (speech has syllable gaps; continuous noise of any kind is absorbed).
   The floor is *pinned* while an utterance or our own reply is active, so
   neither the user's loud frames nor TTS echo can lift the baseline that
   the next utterance is measured against.
3. **SNR speech gate** (`SpeechGate`) — Silero alone can't tell a door slam
   or our own speaker bleed from the user's voice (they all score as
   "speech"), and it's the raw VAD threshold that used to be the
   false-interrupt dial. The threshold stays low (0.35 — raises early so
   sherpa's onset rewind preserves word attacks, see below) and the gate is
   the *trust* dial: a new utterance starts only when Silero **and**
   `frame ≥ floor + 8 dB` (and ≥ −55 dBFS absolute) agree for 160 ms.
   Concretely:
   - *No self-interruption:* while the app speaks, `setPlaying(true)` raises
     the bar to +14 dB over the floor, and for the reply's first 500 ms the
     bar is +30 dB — Android's AEC is effectively deaf during its lock-in,
     so no barge-in can trigger on that leak. A muted/ended reply keeps the
     warm-up window armed for its echo re-lock transient too.
   - *Noise, not cut-offs:* endpointing is still pure silence timing
     (minSilenceDuration = 1 s) — a burst that fails the gate simply never
     starts an utterance, so noise can't cut the user off mid-sentence.
   - *Segment duty cycle:* a delivered segment must have had ≥35 %
     gate-loud frames during it; clatter and echo residue score as speech
     to Silero but sit near the floor, so their duty collapses and the
     segment is discarded (the worker reports `segment dropped: duty …`).
   Gate telemetry (`level/floor/pass/streak`, and drop reasons) surfaces as
   `[worker] …` lines in logcat every ~3 s for field debugging.
4. **Push to talk** gets the same high-pass plus an offline frame gate
   (`denoiseClip`) applied *after* the user finished — quiet fill between
   words gets −30 dB, onsets are never clipped. The debug replay button now
   plays back exactly what Whisper actually received.

### Interaction modes

- **Conversation (default).** The mic runs continuously; Silero VAD (0.6 MB,
  bundled in the APK) watches for speech. An utterance is endpointed after
  ~1 s of silence (`minSilenceDuration` in `speech_worker.dart` — tune there)
  and answered. Starting to talk while the assistant speaks **mutes the TTS
  immediately** (barge-in): the recorder uses the voice-communication source
  with platform AEC/AGC so the mic hears the user over the speaker; a
  word-overlap guard drops segments that are just the assistant hearing its
  own reply. Short breaths get a "say a bit more" nudge instead of a turn.
  A watchdog reopens the mic automatically if Android ends the capture
  session (our own media playback can trigger that), so the session
  self-heals within seconds.
  Backgrounding the app **pauses the conversation** (mic released); a local
  echo turn is abandoned, but a **bridge turn keeps running while hidden** —
  the harness is still answering, every say streams into the chat log (no
  synth, no audio), and returning to the foreground **speaks the newest
  reply** then reopens the mic as the user left it. If says are still
  arriving at that moment the stream simply becomes audible from there on.
- **Push to talk.** Tap to start, tap to stop and send — the original
  behavior. Switchable at the top of the screen; both modes share the same
  worker, ASR and TTS path. On turn end (release / endpoint) the assistant
  plays a 100 ms silent tick through the player: Android's output route
  needs a moment to connect after the mic ran, and without the tick that
  warm-up eats the reply's first word (seen as Pocket TTS "truncation at
  the very beginning" in PTT only — the Settings preview, no active mic,
  stayed clean).

### Voices & voice cloning

The voice icon (top right) opens the voice screen (`lib/voice_screen.dart`):

- **Standard voices.** Five Piper VITS voices — Lessac (default), Ryan,
  Amy, Alba, and LibriTTS-R (a slider picks any of its 60 reader styles),
  taken from the k2-fsa sherpa-onnx releases. Downloads are **lazy**:
  nothing lands on disk until the user selects that voice, and any
  downloaded voice can be **deleted** again (trash icon; the voice in use
  is protected — re-selecting simply re-downloads). The worker isolate
  hot-swaps its TTS engine to match (`TtsSpec` + `useTts` job in
  `speech_worker.dart`); the chosen voice and speaker id persist in
  `models/tts_prefs.json`. A headphones button previews any loaded voice.
- **Kokoro v1.0** (82M, fp32). The best-sounding reader in the app: a
  StyleTTS2-lineage one-pass renderer (no neural codec in the path, no
  autoregressive cold start — the first syllable is as clean as the last,
  which the pocket port cannot claim). 54 built-in speaker styles once
  loaded (style slider), American + British English; RTF ~0.10 on desktop
  CPU at 4 threads. Fetched straight from the k2-fsa tts-models release
  (334 MB download, fp32 deliberately: our A/B measured the int8 pack
  audible-muted *and* 4× slower — `tool/kokoro_ab.dart`). Chinese-capable
  in-model but not wired: the Dart binding drops `dictDir`.
- **Clone my voice** (ZipVoice). Record one clear sentence (2–20 s, live
  timer; the mic is handed to the recorder and any running conversation
  resumes when done). On-device Whisper writes the transcript — ZipVoice
  speaks the reference *transcript*, so the UI lets you fix a mis-heard
  word before applying. The cloning engine (ZipVoice distill int8 + the
  Vocos vocoder, ~155 MB total) downloads on first use only. "Use my
  voice" switches all replies to the clone; the preview button speaks a
  test line. Cloned replies are noticeably slower to generate than the
  stock voices (RTF ≈0.2 measured on desktop, so expect replies to take
  a second or two more on the phone). Backgrounding during recording
  cancels the sample; the recording and delete buttons free the disk.
- **NeuTTS Nano** (Neuphonic). A speech-token neural codec voice, running
  through a *second native stack*: `neutts/bridge/` is a small Rust crate
  (C FFI, built by `tool/build_neutts_pack.sh`) over the MIT `neutts`
  crate — a llama.cpp GGUF backbone (Q4), a pure-Rust NeuCodec decoder,
  and a bundled-espeak phonemizer, so inference is self-contained next to
  sherpa-onnx, on the same worker isolate. The bridge `.so`, the GGUF, the
  converted decoder weights and the preset voices all ride **inside the
  voice pack** (zero APK weight, ~520 MB downloaded); four preset reference
  styles (Greta/Jo/Mateo/Juliette — the MIT-licensed reference samples of
  the Rust port) are selected with the same speaker slider used by
  LibriTTS-R. The sampler seed is pinned (upstream re-rolls it per call),
  which keeps each voice's character stable between replies. Android
  (arm64) only: iOS needs a `.xcframework` build of the same crate, and
  user-voice cloning is pending the pure-Rust NeuCodec *encoder* (the
  Rust port still defers reference encoding to Python). Upstream model
  repos are gated on Hugging Face (one-time terms click + login), so the
  pack is mirrored to our GitHub release by the script above — the app
  itself only ever downloads anonymously. The reply audio is 24 kHz;
  expect ~45 tok/s (RTF ≈1) on a mid-range phone (measured RTF 0.9-1.3
  on desktop x86; the Q8_0 backbone measured no better, so Q4 ships).
- **Pocket TTS** (Kyutai). A 100M-parameter zero-shot cloning model that
  runs *inside the existing sherpa-onnx engine* (PocketTTS support since
  v1.12.24) — no second native stack this time: the voice pack is plain
  model data, so the whole APK weight of the feature is one catalogue row.
  `tool/build_pocket_pack.sh` mirrors the public k2-fsa ONNX export of
  `kyutai/pocket-tts` (the HF repo itself is gated behind a terms click —
  one-time, login + acknowledge on the model page; the export is not) and
  six reference wavs from the ungated `kyutai/tts-voices` repo (Jane,
  Anna, Jean, Michael, Alba, Bill Boerst — CC-BY-4.0), zipped with a
  `pack-v2.ok` sentinel and uploaded to our GitHub release; the app
  again only ever downloads anonymously. v1 shipped the int8-quantized
  export at ~105 MB; v2 switched the LM/flow/decoder to the fp32 graphs:
  band forensics showed both variants hit the same ~10 kHz Mimi-codec
  ceiling (quantization bought no bandwidth), but the fp32 renders won
  the listening test and the head-drop rate improved — the cost is the
  download (~205 MB zip vs ~105 MB) and ~1.6x desktop CPU; the round-trip bench
  below measures the honest per-device numbers. Sentinel bumps are how
  the app re-downloads in place; the unpacker wipes the old directory
  first so orphaned graphs can't squat (`model_unpack.dart`).
  Like the NeuTTS presets, the six
  voices ride the speaker slider (`useTts` returns the reference count);
  the native layer resamples each reference to 24 kHz and caps it at 10 s,
  so presets of any upstream rate are fine. Output is 24 kHz, generated
  with 2 flow steps (the decoder ships one-step distilled). Cloning your
  own voice through this engine only needs the wav — no transcript — so
  wiring the record UI to a pocket spec is a small follow-up.
One port caveat to know before judging a recording: the k2-fsa ONNX
  export cold-starts differently from the PyTorch reference (sherpa's NaN
  initial latent maps to zeros, and the voice prompt is fed without the
  learned BOS embedding that `insert_bos_before_voice` prescribes — see
  kyutai's `flow_lm.py::VoicePrompt`). Worse, the single pooled voice
  embedding loses the prompt's trailing-pause state, so the port starts
  speaking ~0.4 s earlier than the reference — inside its own
  growl-corrupted first frames. The reference emits a clean ~0.5 s
  silence pre-roll before the first word; the export emits a low growl
  that swallows the attack, and the first words read as truncated
  (identically in PTT, conversation mode, and debug replay — proving the
  damage is in the *content*, not the playback path). Worked around in
  `SpeechWorker` (pocket arm, validated by whisper-tiny re-transcription
  of all six presets): every Generate call's text gets a `'.... '` prefix
  so the model *itself* opens with a generated pause (kyutai's own FAQ,
  issue #6) — plus `silenceScale: 1.0`, because the Dart default 0.2
  would squash that pause; `mergePocketChunks` (runt pieces misbehave — a
  one-word answer decodes to '[sound]', and a missed EOS babble-decoded
  40 s on michael — and every extra Generate call re-pays this whole
  ritual, so pieces now merge up to ~340 chars: a typical long answer is
  ONE call whose internal sentence pauses come from the model's own
  punctuation instead of our splice points. The per-piece
  `max_frames` cap scales with the merged size (a runaway EOS
  self-limits there, and no call truncates mid-word);
  `pocketLeadIn` (drop the first 250 ms — the growl now
  dies inside the pause; 30 ms fade so the splice adds no click; 300 ms
  inserted silence so the phone's post-capture output ramp — ~150 ms,
  plus mic-teardown mute — lands in silence too, with the
  model-generated pause behind it carrying the protection). The assistant
  additionally holds the output route open with inaudible silence from
  turn end until the first chunk (insurance for the same ramp; helps
  every engine). First phrase then lands intact in re-transcription on
  every measured draw (10/10 heads; RTF unchanged at ~0.11). If kyutai or
  k2-fsa fix the export, these workarounds retire one function at a time;
  the official renders under `ref6_*.wav` make the A/B audition trivial.

### Round-trip latency bench (voice screen)

The bottom card on the voice screen is a measurement rig for the model
pair you actually run: hold the circle, talk, release — the utterance is
transcribed by Whisper and spoken straight back by the *selected* TTS
voice through the same streamed playback path a real reply takes
(warm-up silence, temp-wav hand-off, per-chunk `play()` included), but
with the bridge skipped, so no LLM thinking time pollutes the numbers.
Every figure is clocked from the button release: `release→text` (ASR
cost on your device), `release→first audio` (the round-trip figure worth
optimising — the moment the player got the echo's first chunk),
`synth total (RTF)` for the whole sentence. Runs stay in a session-only
history so you can switch voices (Piper, Kokoro, Pocket int8/fp32…) and
compare rows side by side; the 20 s hold cap and the mic hand-off
identical to the clone recorder keep the bench from colliding with a
live conversation. The latencies that matter — route warm-up,
post-capture output ramp, streamed-chunk playback — are the same ones
the real turn pays, deliberately: the panel should match what your ears
hear in production, not a lab best case.
  

## Claude Code bridge

The app can put the desktop's Claude Code harness between its ASR and TTS:
speak (or tap a chip), the text goes over the LAN/tailnet to a tiny bridge
process next to the harness, and the harness's answer is streamed back and
spoken with the app's selected voice. Start the bridge on the machine that
runs claude (Node, zero dependencies):

```bash
node tool/claude_bridge.mjs --dir ~/voice-agent --token SOMETHING_SECRET
# optional: --claude ~/.local/bin/claude --port 8732
```

In the app: terminal icon → set `http://<machine>:8732` (tailscale IPs
work too) + the token → Save & check. Two session-control chips then
appear above the mic button — `/new` (bridge reset endpoint: forgets the
persisted session so the harness starts blank) and `/compact` (sent as
plain-string content, which the CLI executes natively — it condenses the
transcript into a summary; the bridge relays the resulting
`compact_boundary` as live progress and the app speaks a confirmation
when the turn stays silent) — plus "Stop" while a turn is in flight
(barge-in interrupts the harness turn in-band via the CLI's control
protocol — the conversation AND the process survive, so no `--resume`
re-prefill; verified). The old canned-command chips (*Repo status, Run tests, Build
APK, Catch me up*) are gone: a harness you can converse with takes dictation
better than scripts. The Bridge screen also has a free-text box so
*anything* you type goes to the harness and comes back spoken — a line
starting with `/` executes as a real Claude Code command (`/context`,
`/usage`, ...) — and a restart button for a fresh conversation. **The voice toggle:** the "Speak to Claude Code"
switch (on from the factory, persisted in `bridge_prefs.json`) routes
whatever you say in push-to-talk or conversation mode to the harness
instead of repeating it back — say "what still has uncommitted changes?"
and Claude Code runs the git commands and answers in your assistant
voice. While a harness turn runs, push-to-talk steers by RELEASE
GESTURE (0.1.0+25): the in-flight bubble carries a Claude Code-style
progress line — the braille spinner wheel (⠋⠙⠹⠸⠼…), the live status
(tool activity included), an elapsed-seconds counter (`_HarnessSpinner`
in `main.dart`) — and while the model generates, that status shows a
live token tally ("thinking · 1.2k out · 48k in", exact at every
message boundary, ~4 chars/token in between; `--include-partial-messages`
stream_event deltas in `claude_bridge.mjs`). A context bar above the
button shows conversation consumption vs the model's window (`context`
SSE events + the `/health` snapshot, `_ContextBar` in `main.dart`) —
the same numbers Claude Code's /context prints. And since this
upstream re-prefills the entire chat every request (prompt caching is a
no-op behind the proxy: `cache_read` is verifiably always 0), that
number IS your latency — context size doubles the seconds, triples the
cost, even for "hello". The bridge does not force `/compact` on you:
watch the bar, and use the /new and /compact chips when *you* decide
the conversation has grown heavy enough. A fresh hold *anytime* during that turn detaches
it (the tool call goes to background and finishes its work unheard,
output dropped) and opens the mic right there. Release in place or slide
RIGHT and your words are QUEUED politely: the turn in flight finishes
first, then yours goes next; slide UP and a mere thinking turn is cut
short in-band so your prompt starts in a heartbeat (an open tool call is
still never cut — it finishes, and your prompt goes next); a quick tap
remains the hard stop: detach + `/stop`, the old "Stop the harness".
The terminal-icon badge stays lit while a detached turn keeps working
unheard. In conversation mode the mic button likewise keeps working
mid-turn. `say` events are
synthesised sentence-stream through the same chunked player voice replies
use, and everything the harness answers runs past `cleanForSpeech` first
(a bullet list would otherwise be *spoken*; markdown/emoji are stripped).
Backgrounding a turn does not cancel it: every answer streams into the
chat log unseen and the newest one is spoken when you switch back.
**Barge-in backgrounds too** (0.1.0+20): speaking over a running harness
turn DETACHES the phone from it — the bridge turns it into a *background*
turn (Claude Code style: the harness finishes its work, output is dropped)
— and your new words go out seconds later as a fresh turn, QUEUED behind
an open tool call or ahead of a cut-short thinking turn (the bridge cuts
pure-thinking turns at queue time with an in-band interrupt — the process
never dies, so the warm prefix cache keeps working — when the takeover wants to be heard —
`interrupt=1`, the default for spoken barge-in and PTT slide-up; PTT's
slide-right passes `interrupt=0` and the queue waits politely; in either
flavour a new prompt goes next even while a tool-free answer was
mid-air). Tapping Stop is the hard
flavour: same detach plus a `/stop` so the harness quits working too.
Smoke-tested end-to-end against a stubbed `claude` child: detach-mid-tool
queues and answers after the tool; detach-mid-thinking interrupts and
answers inside ~1.5 s.
**Both sides of a turn are now on the record** (0.1.0+29): the app keeps a
seq-numbered *event journal* of its lifecycle story — raw hide/resume
callbacks with the flag snapshot each saw, every stream open and exactly
how it died, reattach probe verdicts, watchdog zombie hops, detaches —
mirrored to disk (`app_events.jsonl`: an Android kill can't erase the
evidence of its own death) and served over HTTP on the tailnet. The
bridge learns where to dial from the app's own requests and polls the
journal every 5 s, relaying new lines into its stderr: one `journalctl
-u claude-voice-bridge` interleaves the phone's and the desktop's views
of the same misbehaving turn; a frozen or killed phone shows up as
"not answering" and its recovery timestamps bracket the freeze window.
`curl 'http://<bridge>:8732/applogs?token=…&since=0'` pulls the whole
phone journal live; the Bridge screen shows the poller's peer and
reachability via `/health`.
**"Is it thinking?" now has an always-honest answer** (0.1.0+30): every
turn opens with a `thinking` tally frame, so the spinner line leaves
"Asking the bridge…" within one round trip — and if the upstream streams
no partials, quiet heartbeat frames keep saying so in words while a
per-turn `[census]` line in the bridge's journal reports what the wire
actually delivered (live deltas / usage-only settles / no live events).
Which one you get is your proxy's choice; now you can read it instead
of wondering. The journal itself now PUSHES (0.1.0+32) — the Android
tailscale client accepts no dialed-in connections and carrier NAT has
no route at all, so the phone POSTs its journal outbound (batched,
acked, deduped by seq) and the bridge mirrors the latest envelope:
`/applogs` answers from the mirror with `source:'push'`, and
`appLog.mode` in `/health` reads push / pull / silent.
Protocol, verification notes, and the systemd unit: `docs/claude-code-bridge.md`.

## Run

```bash
flutter pub get
flutter run -d android        # phone attached; mic permission prompted
# iOS: run from macOS (flutter run -d <iphone-or-simulator>)
```

On first launch the app downloads the ASR pack plus the selected voice
pack (Lessac by default, ~124 MB total, see `modelPacks` + `ttsVoices` in
`lib/model_packs.dart` / `lib/tts_voices.dart`) from GitHub releases and
unpacks them once into the app-support dir; only the 0.6 MB Silero VAD
ships inside the APK. Extra voices download on demand. The raw model
tarballs sit in `models/` for the headless test; the zips live in
`assets/models/`.

### Building & shipping the Android APK (what to know so it just works)

```bash
# from ~/voice-agent
sed -i 's/^version: .*/version: 0.1.0+N/' pubspec.yaml   # bump the +N: Android
                                                        # refuses to update-install
                                                        # over a lower versionCode
flutter build apk --release --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk  (the phone build, ~46 MB)
```

Hard-won details:

* **The JDK the Gradle daemon runs on** — this box's PATH `java` is a *bare*
  OpenJDK 25 JRE (no javac). Gradle always considers the running JVM as a
  toolchain candidate, so plugin `compileDebugJavaWithJavac` tasks (e.g.
  audioplayers) die with *"does not provide the required capabilities:
  [JAVA_COMPILER]"* unless the daemon is pinned to a full JDK —
  `org.gradle.java.home=/usr/lib/jvm/java-21-openjdk-amd64` in
  `android/gradle.properties` does exactly that (plus
  `installations.auto-detect=false` with explicit 17/21 paths). If a build
  suddenly "fails at task-configuration in 10 s", look here first, not in
  the Dart changes.
* **Signing**: the release build reuses the debug keystore
  (`android/app/build.gradle.kts`) — fine for sideloading to your own phone,
  not for Play.
* **`--split-per-abi`** keeps the arm64 APK under the Telegram bot's 50 MB
  upload cap (the fat APK doesn't; neither does the x86_64 split).
  Install with `adb install -r app-arm64-v8a-release.apk`.
* **Model/voice packs are NOT in the APK**: the app downloads them from the
  `models-v1` release of `yundddd/voice-agent` at runtime, so a new engine
  needs its pack published *before* the APK is useful —
  `tool/build_pocket_pack.sh upload` / `tool/build_neutts_pack.sh upload`
  (needs `gh` auth for the release; NeuTTS additionally needs `HF_TOKEN`
  in `~/.env` + the NDK r25 Rust toolchain, see the script headers).
  If you change a pack's layout, bump its `pack-vN.ok` sentinel name in
  both the script and `lib/tts_voices.dart` so installed apps re-download.
* **Probes must stay flutter-import-free**: the `tool/*_probe.dart` scripts
  run under plain `dart run`, which cannot compile `package:flutter`
  (`dart:ui` lives in the engine). Import `speech_worker.dart`/`audio_io.dart`
  directly and inline constants (e.g. the pocket voice list) rather than
  importing `tts_voices.dart`.
* **Before shipping**: `dart format --set-exit-if-changed lib tool test`,
  `dart analyze`, and the headless tests below (with `LD_LIBRARY_PATH` set,
  and `POCKET_DIR`/`NEUTTS_DIR` pointing at staged packs) must pass; the
  Pocket leg re-hears each preset through Whisper, so borderline scores are
  the judge (Whisper tiny), not the engine — the test uses the most stable
  presets for its second check.

### Headless round-trip test (no mic, no speaker)

```bash
LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  flutter test test/roundtrip_test.dart
# writes build/roundtrip_reply.wav — listen to hear the TTS reply

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  flutter test test/gate_test.dart   # DSP unit tests (no models needed)

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  flutter test test/model_unpack_test.dart  # lazy voice-pack downloads (tar.bz2/raw)

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  dart run tool/onset_probe.dart      # asserts the first word survives endpointing

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  dart run tool/clone_probe.dart      # ZipVoice clone + Whisper intelligibility check

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  dart run tool/pocket_probe.dart     # Pocket TTS presets + Whisper intelligibility check
```

(`tool/build_pocket_pack.sh` stages the Pocket voice pack from the public
k2-fsa ONNX export + ungated kyutai/tts-voices wavs and, with the `upload`
argument, publishes it to the same GitHub release; re-run it before
`pocket_probe.dart` if `/tmp/opencode/pocket-pack` is gone.)

(The clone leg of `roundtrip_test.dart` runs when the extracted ZipVoice
pack + `vocos_24khz.onnx` sit under `/tmp/opencode` — see the k2-fsa
`tts-models` / `vocoder-models` releases; otherwise it skips.)

### Linux desktop (full app with mic)

Needs `clang cmake ninja-build pkg-config libgtk-3-dev`. GStreamer plugins
for audioplayers, PipeWire/Pulse for `record`.

## Next steps

- Streaming partial ASR (Moonshine/streaming zipformer) for lower first-response latency.
- Wake-word before the full recognizer (e.g. sherpa keyword spotter).
- Gateway call between ASR and TTS; TTS sentence-streaming for lower first-audio latency.
- Per-ABI splits (done) → consider an Android App Bundle for Play.
- iOS: microphone entitlement done (Info.plist); verify pod on macOS.
