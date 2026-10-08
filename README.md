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
| TTS | **Piper VITS** (`en_US-lessac-medium`, this prototype; `amy-low` also downloaded — swap by replacing the asset zip); Matcha-icefall (smaller/faster, phoneme lexicon, no espeak dir); Kokoro-82M (top quality at ≈330 MB int8 on mobile, too heavy for now); MeloTTS (multilingual); Pocket TTS (new, very small); silero/supertonic (commercial license traps) | Piper medium is the quality/size sweet spot (61 MB model + 19 MB espeak-ng-data) and runs ~20–70× faster than real time on desktop CPU; expect real-time or better even on mid-range phones. Kokoro is the upgrade path |
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
```

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
