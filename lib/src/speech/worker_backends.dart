/// The native seams behind the speech isolate, and the fakes that
/// replace them in tests.
///
/// The worker ([SpeechWorker]) orchestrates the pipeline — the job
/// protocol, the noise gate, the endpointing choreography, the
/// sentence-chunked synthesis — while everything that actually touches
/// ONNX lives behind [AsrBackend], [VadBackend] and [TtsBackend].
/// [RealBackends] loads sherpa-onnx (and piper for the student voice);
/// [FakeBackends] answers with scripted, deterministic behaviour so the
/// WHOLE isolate path — VAD events, gate streaks, duty-cycle checks,
/// transcription, streamed synthesis — runs in tests with no native
/// library, no models, and no microphone. The descriptor rides to the
/// isolate as plain data and is rebuilt there.
library;

import 'dart:typed_data';

import 'package:piper_phonemize/piper_phonemize.dart' as piper;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../models/model_paths.dart';
import 'speech_engine.dart';
import 'titl_engine.dart';

/// A finished utterance's text, or null while nothing is ready. The
/// sherpa recognizer's create→accept→decode→getResult dance collapses
/// into one call: every real use transcribes a whole clip at once.
abstract interface class AsrBackend {
  String transcribe(Float32List samples, int sampleRate);
  void free();
}

/// The Silero gate's eyes. Mirrors the handful of sherpa VAD methods
/// the worker loop drives, so the fake can script detections purely by
/// window count.
abstract interface class VadBackend {
  void acceptWaveform(Float32List samples);
  bool isDetected();
  bool isEmpty();
  List<double> frontSamples();
  void pop();
  void reset();
  void free();
}

/// The swappable engine handle: the sherpa-wrapped teacher (Kokoro)
/// and the direct-FFI student (teacher-in-the-loop) return identical
/// float PCM, so the synth arm keeps exactly one call path.
/// generate() is synchronous by contract: it runs on the worker
/// isolate between chunk sends.
abstract class TtsBackend {
  int get numSpeakers;
  (Float32List, int) generate({required String text, int sid, double speed});
  void free();
}

/// Which stack the worker builds its models on. Sendable as plain data.
sealed class WorkerBackends {
  const WorkerBackends();

  Future<AsrBackend> buildAsr(ModelPaths p);
  Future<VadBackend?> buildVad(ModelPaths p, double endpointSilence);
  Future<TtsBackend> buildTts(TtsSpec s);
}

class RealBackends extends WorkerBackends {
  const RealBackends();

  @override
  Future<AsrBackend> buildAsr(ModelPaths p) async {
    await sherpa_onnx.initBindingsAsync();
    return SherpaAsr(
      sherpa_onnx.OfflineRecognizer(
        sherpa_onnx.OfflineRecognizerConfig(
          model: sherpa_onnx.OfflineModelConfig(
            whisper: sherpa_onnx.OfflineWhisperModelConfig(
              encoder: p.whisperEncoder,
              decoder: p.whisperDecoder,
              language: 'en',
              task: 'transcribe',
            ),
            tokens: p.whisperTokens,
            modelType: 'whisper',
            numThreads: 4,
            debug: false,
            provider: 'cpu',
          ),
        ),
      ),
    );
  }

  @override
  Future<VadBackend?> buildVad(ModelPaths p, double endpointSilence) async {
    if (p.vadModel.isEmpty) return null;
    return SherpaVad(
      sherpa_onnx.VoiceActivityDetector(
        config: sherpa_onnx.VadModelConfig(
          // 0.35 raises early (weak plosives/fricatives score low at first),
          // and sherpa's C++ layer rewinds segment starts by
          // minSpeechDuration + 2 windows (voice-activity-detector.cc) — so an
          // early raise means the word attack survives into Whisper. False
          // positives used to be fought *here*; they are now the SNR gate's
          // job (see audio_dsp.dart): detection may be jumpy, but speech
          // *start* requires sustained level over the tracked floor.
          sileroVad: sherpa_onnx.SileroVadModelConfig(
            model: p.vadModel,
            threshold: 0.35,
            minSilenceDuration:
                endpointSilence, // endpoint after N s of silence
            minSpeechDuration: 0.15,
            windowSize: 512,
            maxSpeechDuration: 20.0,
          ),
          sampleRate: 16000,
          numThreads: 1,
          debug: false,
          provider: 'cpu',
        ),
        bufferSizeInSeconds: 60,
      ),
    );
  }

  @override
  Future<TtsBackend> buildTts(TtsSpec s) async {
    if (s.engine == 'titl') {
      await piper.initBindingsAsync();
      piper.PiperPhonemize.initialize(s.espeakDataDir);
      return TitlTts(
        models: s.titlModels.split(','),
        vocabs: s.titlVocabs.split(','),
        espeakVoices: s.espeakVoices.split(','),
      );
    }
    return SherpaTts(
      sherpa_onnx.OfflineTts(
        sherpa_onnx.OfflineTtsConfig(
          model: sherpa_onnx.OfflineTtsModelConfig(
            // The generic generate() synth arm on the worker side already
            // fits — per-piece forward pass, sid selection, clean heads (no
            // prefix/trim/lead-in ritual, no max_frames guard: nothing here
            // can babble). Measured RTF 0.10 at 4 threads on this desktop's
            // CPU; expect a phone to land real-time-comfortable too.
            kokoro: sherpa_onnx.OfflineTtsKokoroModelConfig(
              model: s.kokoroModel,
              voices: s.kokoroVoices,
              tokens: s.kokoroTokens,
              dataDir: s.kokoroDataDir,
              lexicon: s.kokoroLexicon,
            ),
            numThreads: 4,
            debug: false,
            provider: 'cpu',
          ),
          maxNumSenetences: 4,
        ),
      ),
    );
  }
}

/// Scripted stand-ins: [transcripts] answers transcribe jobs in order
/// (the last one sticks), the fake VAD "detects" between window counts
/// [vadStartsAt]..[vadEndsAt] (and flushes everything it buffered as a
/// segment when detection falls — sherpa's own endpoint behaviour in
/// miniature), and every synth piece renders as a deterministic tone
/// burst of [ttsChunkSamples] samples so chunk boundaries are checkable
/// byte-exactly.
class FakeBackends extends WorkerBackends {
  const FakeBackends({
    this.transcripts = const ['fake transcript'],
    this.vadStartsAt = 1,
    this.vadEndsAt = 4,
    this.ttsChunkSamples = 800,
    this.ttsSampleRate = 24000,
    this.ttsNumSpeakers = 1,
  });

  final List<String> transcripts;
  final int vadStartsAt;
  final int vadEndsAt;
  final int ttsChunkSamples;
  final int ttsSampleRate;
  final int ttsNumSpeakers;

  @override
  Future<AsrBackend> buildAsr(ModelPaths p) async => FakeAsr(transcripts);

  @override
  Future<VadBackend?> buildVad(ModelPaths p, double endpointSilence) async =>
      FakeVad(startsAt: vadStartsAt, endsAt: vadEndsAt);

  @override
  Future<TtsBackend> buildTts(TtsSpec s) async => FakeTts(
    chunkSamples: ttsChunkSamples,
    sampleRate: ttsSampleRate,
    numSpeakersValue: ttsNumSpeakers,
  );
}

// ── Real wrappers ─────────────────────────────────────────────────────────

class SherpaAsr implements AsrBackend {
  final sherpa_onnx.OfflineRecognizer _rec;
  SherpaAsr(this._rec);

  @override
  String transcribe(Float32List samples, int sampleRate) {
    final stream = _rec.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    _rec.decode(stream);
    final text = _rec.getResult(stream).text;
    stream.free();
    return text;
  }

  @override
  void free() => _rec.free();
}

class SherpaVad implements VadBackend {
  final sherpa_onnx.VoiceActivityDetector _vad;
  SherpaVad(this._vad);

  @override
  void acceptWaveform(Float32List samples) => _vad.acceptWaveform(samples);
  @override
  bool isDetected() => _vad.isDetected();
  @override
  bool isEmpty() => _vad.isEmpty();
  @override
  List<double> frontSamples() => _vad.front().samples;
  @override
  void pop() => _vad.pop();
  @override
  void reset() => _vad.reset();
  @override
  void free() => _vad.free();
}

class SherpaTts implements TtsBackend {
  final sherpa_onnx.OfflineTts _tts;
  SherpaTts(this._tts);
  @override
  int get numSpeakers => _tts.numSpeakers;
  @override
  (Float32List, int) generate({
    required String text,
    int sid = 0,
    double speed = 1.0,
  }) {
    final a = _tts.generate(text: text, sid: sid, speed: speed);
    return (a.samples, a.sampleRate);
  }

  @override
  void free() => _tts.free();
}

/// The 8M students: espeak-ng (bundled natives) → Kokoro vocab ids →
/// small ONNX graphs on sherpa's own libonnxruntime. Each student IS one
/// voice, so the roster is one graph per sid — loaded lazily the first
/// time that sid is spoken (a 9 MB load, no pack required until picked:
/// a missing pack surfaces as a clear engine-load error at audition)
/// and cached for the worker's life. The phonemizer voice is per-sid
/// too (English students read 'en-us', Italian ones 'it').
class TitlTts implements TtsBackend {
  TitlTts({
    required this.models,
    required this.vocabs,
    required this.espeakVoices,
  });

  final List<String> models;
  final List<String> vocabs;
  final List<String> espeakVoices;
  final Map<int, TitlEngine> _engines = {};

  @override
  int get numSpeakers => models.length;

  @override
  (Float32List, int) generate({
    required String text,
    int sid = 0,
    double speed = 1.0,
  }) {
    final at = sid % models.length;
    final engine = _engines.putIfAbsent(
      at,
      () => TitlEngine.load(modelPath: models[at], vocabPath: vocabs[at]),
    );
    final voice = espeakVoices[at % espeakVoices.length];
    final words = piper.PiperPhonemize.phonemize(text, voice: voice);
    return (
      engine.synth(
        TitlEngine.phonemesFromWords(
          words,
          engine.vocab.keys.toSet(),
          // Italian graphs were trained on espeak's own tap; the English
          // fold maps it to Misaki's capital-T flap token. Italian takes
          // no diphthong folds either — Misaki's Italian backend feeds
          // espeak's output nearly verbatim.
          aliases: voice.startsWith('it') ? espeakAliasesIt : espeakAliases,
          folds: voice.startsWith('it') ? null : TitlEngine.foldEspeakEn,
        ),
        speed: speed,
      ),
      TitlEngine.sampleRate,
    );
  }

  @override
  void free() {
    for (final e in _engines.values) {
      e.dispose();
    }
    _engines.clear();
  }
}

// ── Fakes ─────────────────────────────────────────────────────────────────

class FakeAsr implements AsrBackend {
  FakeAsr(this.transcripts);
  final List<String> transcripts;
  int _i = 0;
  final List<Float32List> calls = [];

  @override
  String transcribe(Float32List samples, int sampleRate) {
    calls.add(samples);
    return transcripts[_i < transcripts.length ? _i++ : transcripts.length - 1];
  }

  @override
  void free() {}
}

/// Detects while the accepted-window count sits inside
/// [startsAt]..[endsAt]; on the fall it publishes everything accepted
/// since detection as one ready segment (the real VAD hands back the
/// speech plus its surrounding pads the same way).
class FakeVad implements VadBackend {
  FakeVad({required this.startsAt, required this.endsAt});
  final int startsAt;
  final int endsAt;

  int _windows = 0;
  bool _detected = false;
  final List<double> _buffer = [];
  final List<List<double>> _ready = [];

  @override
  void acceptWaveform(Float32List samples) {
    _windows++;
    final inSpeech = _windows >= startsAt && _windows <= endsAt;
    if (inSpeech) {
      if (!_detected) _buffer.clear();
      _detected = true;
    } else if (_detected) {
      _detected = false;
      _ready.add(List<double>.from(_buffer));
      _buffer.clear();
    }
    if (_detected) _buffer.addAll(samples);
  }

  @override
  bool isDetected() => _detected;
  @override
  bool isEmpty() => _ready.isEmpty;
  @override
  List<double> frontSamples() => _ready.first;
  @override
  void pop() => _ready.removeAt(0);
  @override
  void reset() {
    _windows = 0;
    _detected = false;
    _buffer.clear();
    _ready.clear();
  }

  @override
  void free() {}
}

/// Renders every piece as [chunkSamples] of a fixed value: chunk sizes
/// then encode exactly which piece the splitter produced, and the seam
/// silence the worker appends shows up as a length delta.
class FakeTts implements TtsBackend {
  FakeTts({
    required this.chunkSamples,
    required this.sampleRate,
    this.numSpeakersValue = 1,
  });
  final int chunkSamples;
  final int sampleRate;
  final int numSpeakersValue;
  final List<String> texts = [];
  @override
  int get numSpeakers => numSpeakersValue;

  @override
  (Float32List, int) generate({
    required String text,
    int sid = 0,
    double speed = 1.0,
  }) {
    texts.add(text);
    // Amplitude encodes the piece length AND the sid: a cheap
    // cross-check that no chunk got merged or dropped on the port,
    // and the only way to observe the worker's sid selection from
    // the test side (the fake runs on the isolate). Decode:
    // (v * 100000) % 250 -> sid; floor(v * 400) -> length % 100 + 1.
    final v = ((text.length % 100) + 1) / 400.0 + sid / 100000.0;
    return (Float32List.fromList(List.filled(chunkSamples, v)), sampleRate);
  }

  @override
  void free() {}
}
