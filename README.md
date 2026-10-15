# Voice Agent

On-device voice assistant prototype in Flutter: you speak, the app transcribes
your speech **on-device**, and speaks the transcription back — the full
speech-to-text → text → speech-to-text round trip runs with no network.

A future gateway (remote LLM that returns the *text* reply) plugs in between
the ASR and TTS stages; only that hop goes over the network. Both speech models
stay on the phone.

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
| TTS | **Piper VITS** (`en_US-lessac-medium`, this prototype; `amy-low` also downloaded — swap by replacing the asset zip); Matcha-icefall (smaller/faster, phoneme lexicon, no espeak dir); Kokoro-82M (top quality at ≈330 MB int8 on mobile, too heavy for now); MeloTTS (multilingual); **Pocket TTS** (Kyutai 100M zero-shot clone — shipped as a downloadable voice, sherpa-onnx support since v1.12.24); silero/supertonic (commercial license traps) | Piper medium is the quality/size sweet spot (61 MB model + 19 MB espeak-ng-data) and runs ~20–70× faster than real time on desktop CPU; expect real-time or better even on mid-range phones. Pocket TTS adds reference-voice cloning inside sherpa itself; Kokoro is the remaining upgrade path |
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
  Backgrounding the app **pauses the conversation** (mic released, in-flight
  turn abandoned); returning to the foreground resumes it automatically.
- **Push to talk.** Tap to start, tap to stop and send — the original
  behavior. Switchable at the top of the screen; both modes share the same
  worker, ASR and TTS path.

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
  Anna, Jean, Michael, Alba, Bill Boerst — CC-BY-4.0), zipped to ~105 MB
  with a `pack-v1.ok` sentinel and uploaded to our GitHub release; the app
  again only ever downloads anonymously. Like the NeuTTS presets, the six
  voices ride the speaker slider (`useTts` returns the reference count);
  the native layer resamples each reference to 24 kHz and caps it at 10 s,
  so presets of any upstream rate are fine. Output is 24 kHz, generated
  with 2 flow steps (the decoder ships one-step distilled). Cloning your
  own voice through this engine only needs the wav — no transcript — so
  wiring the record UI to a pocket spec is a small follow-up.
  One port caveat to know before judging a recording: the k2-fsa ONNX
  export cold-starts differently from the PyTorch reference (sherpa's
  NaN initial latent maps to zeros, and the voice prompt is fed without
  the learned BOS embedding that `insert_bos_before_voice` prescribes —
  see kyutai's `flow_lm.py::VoicePrompt`). The reference emits a clean
  ~0.5 s silence pre-roll before the first word; the export emits a low
  growl that swallows the attack, so speech seemed cut off at sample 0.
  Worked around in `SpeechWorker` (pocket arm): `mergePocketChunks`
  (runt pieces misbehave — a 2-word piece garbles the first syllable
  and a missed EOS decodes 40 s of babble), a per-piece `max_frames`
  cap, and `pocketLeadIn` (drop the first 250 ms of growl, 30 ms fade,
  100 ms of air before speech). After that the body of every sentence
  is clean at RTF ~0.1; the first syllable of the first word can still
  be soft on some draws — re-audition if kyutai or k2-fsa fix the
  export, then the workaround can retire (`pocketLeadIn` is a single
  function). The official PyTorch renders under `ref6_*.wav` make the
  A/B audition trivial.

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
