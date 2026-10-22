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

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../models/model_paths.dart';
import 'asr_chunk.dart';
import 'espeak_exec.dart';
import 'lexicon_pronouncer.dart';
import 'speech_engine.dart';
import 'titl_engine.dart';

/// A finished utterance's text, or null while nothing is ready. The
/// sherpa recognizer's create→accept→decode→getResult dance collapses
/// into one call: every real use transcribes a whole clip at once.
abstract interface class AsrBackend {
  /// Transcribes a whole clip. Chunking backends (long holds decoded
  /// piece by piece) call [onPartial] with the CUMULATIVE text each
  /// time another piece finishes, so the UI can show the decode
  /// landing while the rest is still in Whisper. Whole-clip backends
  /// have nothing early to say and simply don't call it.
  String transcribe(
    Float32List samples,
    int sampleRate, {
    void Function(String partialSoFar)? onPartial,
  });
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
      // Long-clip chunking rides the SAME silero file the endpointer
      // already ships with; empty path (or a 16k mismatch at the call)
      // degrades to today's whole-clip decode, minus nothing.
      // maxSpeechDuration mirrors the live endpointer's 20 s: a clip
      // of unbroken talk still cuts inside Whisper's 30 s window.
      chunkVadModel: p.vadModel,
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
      final t = TitlTts(
        models: s.titlModels.split(','),
        vocabs: s.titlVocabs.split(','),
        lexiconPaths: s.lexiconPaths,
        espeakBin: s.espeakBin,
        espeakDataDir: s.espeakDataDir,
      );
      // First speech used to pay for everything lazily — the ~300 ms
      // dictionary parse, the ORT session build (graph optimization
      // over the int8 graph), and the first Run's kernel + arena
      // setup — so the voice picked a second ago went silent for a
      // beat. warm() moves all three into THIS await, which the
      // boot/useTts busy state already covers; a failure here stays
      // non-fatal (the first utterance repeats the attempt and gets
      // to report it loudly, as before).
      t.warm(s.sid);
      return t;
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
    this.partialGroups = const [],
    this.vadStartsAt = 1,
    this.vadEndsAt = 4,
    this.ttsChunkSamples = 800,
    this.ttsSampleRate = 24000,
    this.ttsNumSpeakers = 1,
    this.ttsSpinMicros = 0,
  });

  final List<String> transcripts;
  final List<List<String>> partialGroups;
  final int vadStartsAt;
  final int vadEndsAt;
  final int ttsChunkSamples;
  final int ttsSampleRate;
  final int ttsNumSpeakers;
  final int ttsSpinMicros;

  @override
  Future<AsrBackend> buildAsr(ModelPaths p) async =>
      FakeAsr(transcripts, partials: partialGroups);

  @override
  Future<VadBackend?> buildVad(ModelPaths p, double endpointSilence) async =>
      FakeVad(startsAt: vadStartsAt, endsAt: vadEndsAt);

  @override
  Future<TtsBackend> buildTts(TtsSpec s) async => FakeTts(
    chunkSamples: ttsChunkSamples,
    sampleRate: ttsSampleRate,
    numSpeakersValue: ttsNumSpeakers,
    spinMicros: ttsSpinMicros,
  );
}

// ── Real wrappers ─────────────────────────────────────────────────────────

class SherpaAsr implements AsrBackend {
  final sherpa_onnx.OfflineRecognizer _rec;

  /// Lazily built (the model loads once per worker life, not once per
  /// ASR build): chunks clips longer than [_windowSeconds] of audio so
  /// Whisper's 30-second window never amputates a long hold. Empty
  /// model path disables chunking outright.
  final String chunkVadModel;
  SherpaVad? _chunker;

  SherpaAsr(this._rec, {this.chunkVadModel = ''});

  /// Decode whole below this much audio: Whisper's window minus a
  /// 4-second belt (feature padding, endpoint pad slop, clock drift).
  static const double _windowSeconds = 26.0;

  @override
  String transcribe(
    Float32List samples,
    int sampleRate, {
    void Function(String partialSoFar)? onPartial,
  }) {
    if (chunkVadModel.isEmpty ||
        sampleRate != 16000 ||
        samples.length <= (_windowSeconds * sampleRate).round()) {
      return _decode(samples, sampleRate);
    }
    final vad = _chunker ??= SherpaVad(
      sherpa_onnx.VoiceActivityDetector(
        config: sherpa_onnx.VadModelConfig(
          sileroVad: sherpa_onnx.SileroVadModelConfig(
            model: chunkVadModel,
            // Same opening posture as the live endpointer: raise early,
            // let the word attack survive; this clip already passed the
            // SNR gate on the way in.
            threshold: 0.35,
            // +236: half a second, not three tenths — the 0.3 belt cut a
            // counting session between 'twenty-eight' and 'twenty-nine'
            // and the word died in the seam (field tape: 24 doubled, 29
            // gone). A transcribe split should cost a word only at a
            // REAL pause; the 20 s maxSpeechDuration still forces a cut
            // through unbroken talk inside Whisper's window.
            minSilenceDuration: 0.5,
            minSpeechDuration: 0.25,
            maxSpeechDuration: 20.0,
            windowSize: 512,
          ),
          sampleRate: 16000,
          numThreads: 1,
          debug: false,
          provider: 'cpu',
        ),
        bufferSizeInSeconds: 60,
      ),
    );
    // Cut where the window forces it, not where a breath landed: the
    // VAD segments are re-packed into ~18 s decode blobs (an
    // over-sized single segment — the 20 s forced cut — still rides
    // alone, inside the 26 s belt). Each finished blob lifts the
    // cumulative text to the caller as it lands.
    final soFar = <String>[];
    final blobs = packSegments(
      chunkForWhisper(vad, samples, sampleRate),
      (18 * sampleRate).round(),
    );
    for (final blob in blobs) {
      final t = _decode(blob, sampleRate).trim();
      if (t.isEmpty) continue;
      soFar.add(t);
      onPartial?.call(soFar.join(' '));
    }
    final parts = soFar.join(' ').trim();
    // A clip this long with no detectable speech is noise; decode it
    // whole anyway — that's exactly what today's path does with it,
    // truncated by the window, and silence beats a wrong word.
    return parts.isEmpty ? _decode(samples, sampleRate) : parts;
  }

  String _decode(Float32List samples, int sampleRate) {
    final stream = _rec.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    _rec.decode(stream);
    final text = _rec.getResult(stream).text;
    stream.free();
    return text;
  }

  @override
  void free() {
    _chunker?.free();
    _rec.free();
  }
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

/// The 8M students: Kokoro's own lexicon files through the
/// espeak-free front-end (lib/lexicon_pronouncer.dart) → Kokoro vocab
/// ids → small ONNX graphs on sherpa's own libonnxruntime. Each student
/// IS one voice, so the roster is one graph per sid — loaded lazily the
/// first time that sid is spoken (a 9 MB load, no pack required until
/// picked: a missing pack surfaces as a clear engine-load error at
/// audition) and cached for the worker's life.
class TitlTts implements TtsBackend {
  TitlTts({
    required this.models,
    required this.vocabs,
    required this.lexiconPaths,
    this.espeakBin = '',
    this.espeakDataDir = '',
  });

  final List<String> models;
  final List<String> vocabs;
  final String lexiconPaths;

  /// +238: the out-of-process rule engine (see espeak_exec.dart). When
  /// the binary and its data are BOTH present it is the front-end —
  /// letter names and all; otherwise the +224 lexicon ladder speaks.
  final String espeakBin;
  final String espeakDataDir;
  EspeakExec? _espeak;
  final Map<int, TitlEngine> _engines = {};
  LexiconPronouncer? _pron;

  @override
  int get numSpeakers => models.length;

  /// Pre-pay the first-utterance costs: parse the dictionary, build
  /// the picked sid's ORT session, and run one padded no-op sentence
  /// so the kernels and arenas wake before any listener is waiting.
  /// Never throws — warm is a courtesy; the first real synth is the
  /// messenger for a broken pack.
  void warm(int sid) {
    try {
      // Warm the front-end this voice will ACTUALLY use: the exec when
      // it can run (first child-process spawn + dict load, ~50 ms),
      // the dictionary parse otherwise.
      final es = _espeak ??= EspeakExec(
        binPath: espeakBin,
        dataDir: espeakDataDir,
      );
      if (es.usable) {
        es.ipa('warm up.');
      } else {
        _pronouncer();
      }
      final at = sid % models.length;
      final engine = _engines.putIfAbsent(
        at,
        () => TitlEngine.load(modelPath: models[at], vocabPath: vocabs[at]),
      );
      engine.synth('.'); // '.' is a vocab stop: one id, one tiny run
    } catch (_) {
      // Loud at first speech, not at warm.
    }
  }

  /// The lexicon is parsed on first use (one dictionary load,
  /// mirroring the graphs' lazy one). A missing pack is a loud error,
  /// not a silent espeak detour: the plugin is out of the APK, and
  /// 'student voice silent' must name its own cause.
  LexiconPronouncer _pronouncer() {
    return _pron ??=
        LexiconPronouncer.loadAll(
          lexiconPaths.split(',').where((p) => p.trim().isNotEmpty),
        ) ??
        (throw TitlException(
          'student lexicon pack missing — re-download the voice '
          '(tts-lexicon-en.zip)',
        ));
  }

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
    // +238 law: the rule engine speaks when it can run — espeak's
    // output goes through the Misaki fold, the same table the graph
    // was trained under from +167 to +223. Where it cannot (no binary,
    // no exec right), the dictionary ladder — and it says so once per
    // engine load in the warm diagnostics, never mid-sentence.
    final es = _espeak ??= EspeakExec(
      binPath: espeakBin,
      dataDir: espeakDataDir,
    );
    final String phonemes;
    if (es.usable) {
      phonemes = EspeakExec.phonemesFromIpa(
        es.ipa(text),
        engine.vocab.keys.toSet(),
      );
    } else {
      // Lexicon entries are the trained alphabet verbatim (flap and
      // glottal folded at parse time), so the assembly pass needs no
      // aliases and no folds — just the vocab filter and the stop rule.
      phonemes = TitlEngine.phonemesFromWords(
        _pronouncer().phonemize(text),
        engine.vocab.keys.toSet(),
      );
    }
    return (engine.synth(phonemes, speed: speed), TitlEngine.sampleRate);
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
  FakeAsr(this.transcripts, {this.partials = const []});
  final List<String> transcripts;

  /// Cumulative partials this fake 'decodes' on the way to each
  /// transcript — one list per transcribe call, delivered to onPartial
  /// before the result, exactly as the chunking SherpaAsr does.
  final List<List<String>> partials;
  int _i = 0;
  final List<Float32List> calls = [];

  @override
  String transcribe(
    Float32List samples,
    int sampleRate, {
    void Function(String partialSoFar)? onPartial,
  }) {
    calls.add(samples);
    if (partials.isNotEmpty) {
      for (final p
          in partials[_i < partials.length ? _i : partials.length - 1]) {
        onPartial?.call(p);
      }
    }
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
    this.spinMicros = 0,
  });
  final int chunkSamples;
  final int sampleRate;
  final int numSpeakersValue;

  /// Synchronous busy-work per generate, standing in for real model
  /// seconds: a piece this slow makes the worker loop hold its message
  /// queue between pieces — the window the +B cancel rides.
  final int spinMicros;
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
    if (spinMicros > 0) {
      final sw = Stopwatch()..start();
      while (sw.elapsedMicroseconds < spinMicros) {}
    }
    return (Float32List.fromList(List.filled(chunkSamples, v)), sampleRate);
  }

  @override
  void free() {}
}
