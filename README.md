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
| VAD | **Silero VAD** (0.6 MB, already a dependency) | Not wired in yet; next step for auto end-of-utterance detection so the user does not have to press stop |

Measured on this dev machine (Intel, 4 threads, debug FFI — phones will be slower but still far under real-time):

```
ASR: 6.6 s of speech → text in 150 ms   (RTF ≈ 0.02)
TTS: text → 5.1 s audio in 111 ms       (RTF ≈ 0.02)
```

Shipped footprint: ~60 MB ASR zip + ~64 MB TTS zip in assets (each expands
once into app-support storage). For production, ship nothing and **download
the same zips from the gateway/CDN on first run** — the unpack code path
(`lib/model_packs.dart`) is identical.

## App structure

```
lib/
  main.dart           UI: mic button, transcript, latency strip
  assistant.dart      State machine: listen → transcribe → speak; mic capture
  speech_worker.dart  Isolate owning both models (FFI calls never touch UI isolate)
  model_paths.dart    Model file locations (injected → testable)
  model_packs.dart    Asset zips → app support dir (first run only)
  audio_io.dart       PCM16↔float32, WAV encode/decode
test/roundtrip_test.dart  Headless round trip on a wav fixture
```

Flow: `record` (PCM16, 16 kHz mono stream, AEC/AGC) → float32 buffer →
Whisper small-stream decode in worker isolate → transcript → Piper VITS
generate → WAV → `audioplayers` → speaker. TTS currently just repeats the
transcription; a gateway text reply later replaces `_transcript` before
`synthesize`.

## Run

```bash
flutter pub get
flutter run -d android        # phone attached; mic permission prompted
# iOS: run from macOS (flutter run -d <iphone-or-simulator>)
```

Models are in `assets/models/` (from the tarballs under `models/`, which are
kept uncompressed for the headless test).

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

- Silero VAD endpointing (auto-stop), streaming partial ASR (Moonshine/zipformer).
- Wake-word before the full recognizer (e.g. sherpa keyword spotter).
- Gateway call between ASR and TTS; TTS sentence-streaming for lower first-audio latency.
- Model download manager (same zip format) instead of bundled assets; per-ABI splits.
- iOS: microphone entitlement done (Info.plist); verify pod on macOS.
