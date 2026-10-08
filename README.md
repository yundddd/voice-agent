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
                      transcript, latency strip
  assistant.dart      Conversation state machine: endpointing, barge-in, turns
  speech_worker.dart  Isolate owning both models (FFI calls never touch UI isolate)
  model_paths.dart    Model file locations (injected → testable)
  model_packs.dart    Downloaded zips → app support dir (first run only)
  audio_io.dart       PCM16↔float32, WAV encode/decode
test/roundtrip_test.dart  Headless round trip + VAD endpointing on wav fixtures
```

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
- **Push to talk.** Tap to start, tap to stop and send — the original
  behavior. Switchable at the top of the screen; both modes share the same
  worker, ASR and TTS path.

## Run

```bash
flutter pub get
flutter run -d android        # phone attached; mic permission prompted
# iOS: run from macOS (flutter run -d <iphone-or-simulator>)
```

On first launch the app downloads the ASR and TTS zips (~124 MB total, see
`modelPacks` in `lib/model_packs.dart`) from the GitHub release and unpacks
them once into the app-support dir; only the 0.6 MB Silero VAD ships inside
the APK. The raw model tarballs sit in `models/` for the headless test; the
zips live in `assets/models/`.

### Headless round-trip test (no mic, no speaker)

```bash
LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  flutter test test/roundtrip_test.dart
# writes build/roundtrip_reply.wav — listen to hear the TTS reply
```

### Linux desktop (full app with mic)

Needs `clang cmake ninja-build pkg-config libgtk-3-dev`. GStreamer plugins
for audioplayers, PipeWire/Pulse for `record`.

## Next steps

- Streaming partial ASR (Moonshine/streaming zipformer) for lower first-response latency.
- Wake-word before the full recognizer (e.g. sherpa keyword spotter).
- Gateway call between ASR and TTS; TTS sentence-streaming for lower first-audio latency.
- Per-ABI splits (done) → consider an Android App Bundle for Play.
- iOS: microphone entitlement done (Info.plist); verify pod on macOS.
