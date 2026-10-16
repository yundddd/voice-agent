import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:piper_phonemize/piper_phonemize.dart' as piper;

import 'titl_engine.dart';

import 'audio_dsp.dart';
import 'model_paths.dart';

const double _ln10 = 2.302585092994046;

/// Jobs sent to the worker over its control port.
class _Job {
  final int id; // -1 for fire-and-forget ops
  final String op;
  // 'audio' | 'resetVad' | 'transcribe' | 'synthesize' | 'playing' | 'denoise'
  // | 'useTts'
  final String? text;
  final Float32List? samples;
  final int? sampleRate;
  final TtsSpec? spec; // 'useTts' only
  const _Job.audio(this.samples)
    : id = -1,
      op = 'audio',
      text = null,
      sampleRate = null,
      spec = null;
  const _Job.resetVad()
    : id = -1,
      op = 'resetVad',
      samples = null,
      text = null,
      sampleRate = null,
      spec = null;
  const _Job.playing(bool on)
    : id = -1,
      op = 'playing',
      text = on ? 'on' : 'off',
      samples = null,
      sampleRate = null,
      spec = null;
  const _Job.transcribe(this.id, this.samples, this.sampleRate)
    : text = null,
      op = 'transcribe',
      spec = null;
  const _Job.synthesize(this.id, this.text)
    : samples = null,
      sampleRate = null,
      op = 'synthesize',
      spec = null;
  const _Job.denoise(this.id, this.samples)
    : text = null,
      sampleRate = null,
      op = 'denoise',
      spec = null;
  const _Job.useTts(this.id, this.spec)
    : text = null,
      samples = null,
      sampleRate = null,
      op = 'useTts';
}

/// One-way events pushed from the worker (gated VAD output + diagnostics).
class _Event {
  final String kind; // 'speechStart' | 'speechEnd' | 'segment' | 'note'
  final Float32List? samples;
  final String? note;
  _Event.speechStart() : kind = 'speechStart', samples = null, note = null;
  _Event.speechEnd() : kind = 'speechEnd', samples = null, note = null;
  _Event.segment(Float32List s) : kind = 'segment', samples = s, note = null;
  _Event.note(String s) : kind = 'note', samples = null, note = s;
}

/// Split [text] into speakable chunks of at most 40 words, breaking at
/// sentence ends (. ! ?) and at clause boundaries (, ; :) — a mark only
/// cuts when followed by whitespace, end-of-text, or a closing
/// quote/bracket, so "3.14", "1,000" and "U.S.A." stay intact. A unit
/// still beyond twice the cap is hard-split at word boundaries, and text
/// without any punctuation stays one chunk. Descended from split_for_tts
/// in the vendored neutts crate (same constants), since broadened for
/// streamed prose that is mostly one long comma-spliced sentence.

List<String> splitForTts(String text) {
  const maxWords = 40;
  // 1. Clauses, terminators kept attached; break after [.!?,;:] followed
  //    by whitespace (incl. \r), end-of-text, or a closing quote/bracket.
  //    Runs like "..." or "!\"" stay with their sentence.
  final sentences = <String>[];
  final b = List<int>.from(
    text.codeUnits,
  ); // utf-16 code units; ASCII punctuation matches by code
  var start = 0, i = 0;
  while (i < b.length) {
    final c = b[i];
    final term = c == 0x2E || c == 0x21 || c == 0x3F; // . ! ?
    final clause = c == 0x2C || c == 0x3B || c == 0x3A; // , ; :
    final boundary =
        (term || clause) &&
        (i + 1 == b.length ||
            _isWs(b[i + 1]) ||
            (i + 2 < b.length &&
                (b[i + 1] == 0x22 || b[i + 1] == 0x27 || b[i + 1] == 0x29)));
    if (boundary) {
      var end = i + 1;
      while (end < b.length &&
          (b[end] == 0x2E ||
              b[end] == 0x21 ||
              b[end] == 0x3F ||
              b[end] == 0x2C ||
              b[end] == 0x3B ||
              b[end] == 0x29 ||
              b[end] == 0x22 ||
              b[end] == 0x27)) {
        end += 1;
      }
      sentences.add(text.substring(start, end).trim());
      start = end;
      while (start < b.length && _isWs(b[start])) {
        start += 1;
      }
      i = start;
      continue;
    }
    i += 1;
  }
  if (start < text.length) sentences.add(text.substring(start).trim());
  sentences.removeWhere((s) => s.isEmpty);

  final wordCount = text.trim().isEmpty ? 0 : text.trim().split(_ws).length;
  if (sentences.length <= 1 && wordCount <= maxWords * 2) {
    return [text.trim()];
  }

  // 2. Hard-split oversized sentences at word boundaries.
  final units = <String>[];
  for (final s in sentences) {
    final words = s.split(_ws).where((w) => w.isNotEmpty).toList();
    if (words.length <= maxWords) {
      units.add(s);
    } else {
      for (var w = 0; w < words.length; w += maxWords) {
        units.add(words.skip(w).take(maxWords).join(' '));
      }
    }
  }

  // 3. Greedy-pack sentences up to maxWords per chunk.
  final chunks = <String>[];
  final cur = <String>[];
  var curWords = 0;
  for (final u in units) {
    final n = u.split(_ws).where((w) => w.isNotEmpty).length;
    if (curWords + n > maxWords && cur.isNotEmpty) {
      chunks.add(cur.join(' '));
      cur.clear();
      curWords = 0;
    }
    curWords += n;
    cur.add(u);
  }
  if (cur.isNotEmpty) chunks.add(cur.join(' '));
  return chunks;
}

final RegExp _ws = RegExp(r'\s+');
bool _isWs(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D;

/// A job result coming back from the worker.
class _JobResult {
  final int id;
  final String? text;
  final Float32List? audio;
  final int? sampleRate;
  final String? error;
  final int number; // 'useTts': number of speakers the new engine has
  final bool isChunk; // partial TTS audio; the pending job completes on the
  final bool lastChunk; // last chunk of a stream (rate/flags only, no concat)
  _JobResult.chunk(this.id, this.audio, this.sampleRate, this.lastChunk)
    : isChunk = true,
      text = null,
      error = null,
      number = 0;
  _JobResult.text(this.id, this.text)
    : audio = null,
      sampleRate = null,
      error = null,
      number = 0,
      isChunk = false,
      lastChunk = false;
  _JobResult.audio(this.id, this.audio, this.sampleRate)
    : text = null,
      error = null,
      number = 0,
      isChunk = false,
      lastChunk = false;
  _JobResult.ok(this.id, this.number)
    : text = null,
      audio = null,
      sampleRate = null,
      error = null,
      isChunk = false,
      lastChunk = false;
  _JobResult.error(this.id, this.error)
    : text = null,
      audio = null,
      sampleRate = null,
      number = 0,
      isChunk = false,
      lastChunk = false;
}

/// Which TTS voice the worker should speak with — plain data so it can be
/// sent to the worker isolate at startup or swapped via [SpeechWorker.useTts].
///
/// Kokoro-82M v1.0 (the k2-fsa kokoro-multi-lang-v1_0 pack, fp32 — our A/B
/// measured the int8 build audible-muted AND ~4x slower on CPU (RTF 0.37 vs
/// 0.10): ORT's int8 kernels lose to plain fp32 at this model size). The app
/// ships this one engine only — the Piper/VITS, Pocket, ZipVoice and NeuTTS
/// engines were removed when Kokoro proved the best-sounding by a wide
/// margin. No cold-start ritual, no codec bottleneck: one forward pass,
/// clean heads, so it rides the generic OfflineTts synth arm. [sid] indexes
/// the 54-voice roster (reported by the model itself, so the voice screen's
/// style slider picks it up). [kokoroLexicon] is a comma-joined list of
/// absolute lexicon paths; zh would additionally need the jieba dict, which
/// the Dart binding does not plumb (dictDir is dropped), so we wire English
/// only. espeak-ng under [kokoroDataDir] backs out-of-lexicon words.
class TtsSpec {
  final String engine; // 'kokoro' | 'titl'
  final String kokoroModel, kokoroVoices, kokoroTokens, kokoroDataDir;
  final String kokoroLexicon;
  // Teacher-in-the-loop: the 8M student graph + Kokoro phoneme vocab;
  // espeak data arrives unpacked by the piper_phonemize plugin (its own
  // copy, extracted to app support — independent of the Kokoro pack's).
  final String titlModel, titlVocab, espeakDataDir, espeakVoice;
  final int sid;

  const TtsSpec.kokoro({
    required this.kokoroModel,
    required this.kokoroVoices,
    required this.kokoroTokens,
    required this.kokoroDataDir,
    required this.kokoroLexicon,
    this.sid = 0,
  }) : engine = 'kokoro',
       titlModel = '',
       titlVocab = '',
       espeakDataDir = '',
       espeakVoice = '';

  const TtsSpec.titl({
    required this.titlModel,
    required this.titlVocab,
    required this.espeakDataDir,
    this.espeakVoice = 'en-us',
    this.sid = 0,
  }) : engine = 'titl',
       kokoroModel = '',
       kokoroVoices = '',
       kokoroTokens = '',
       kokoroDataDir = '',
       kokoroLexicon = '';
}

/// One-way speech pipeline notification.
///
/// [speechStarted]/[speechStopped] track the live speech flag — they fire
/// only when Silero AND the SNR gate agree, so neither a door slam nor the
/// app's own TTS echo can fake them. [segment] carries a finished utterance
/// (endpointed after [endpointSilence] seconds of *joint* silence) that also
/// passed the duty-cycle check — clean enough to transcribe. [note] carries
/// periodic gate diagnostics (level/floor in dBFS) for logcat.
class SpeechEvent {
  final bool speechStarted;
  final Float32List? segment;
  final String? note;
  const SpeechEvent.started()
    : speechStarted = true,
      segment = null,
      note = null;
  const SpeechEvent.stopped()
    : speechStarted = false,
      segment = null,
      note = null;
  const SpeechEvent.ofSegment(this.segment)
    : speechStarted = false,
      note = null;
  const SpeechEvent.diagnostic(this.note)
    : speechStarted = false,
      segment = null;
}

/// Owns the on-device models (ASR + TTS + optional VAD) and the noise/echo
/// front end inside a dedicated isolate so inference never blocks the UI.
/// Create with [SpeechWorker.start].
class SpeechWorker {
  SpeechWorker._(this._eventsSub, this.onEvent);

  final StreamSubscription<Object?> _eventsSub;

  /// Receives speech-pipeline notifications; set before awaiting
  /// [SpeechWorker.start] completion via the [onEvent] parameter.
  final void Function(SpeechEvent)? onEvent;

  final Map<int, Completer<_JobResult>> _pending = {};
  final Map<int, void Function(Float32List chunk, int sampleRate)> _chunkFans =
      {};
  int _nextId = 0;
  Isolate? _isolate;
  SendPort? _toWorker;

  static Future<SpeechWorker> start(
    ModelPaths paths, {
    TtsSpec? tts,
    void Function(SpeechEvent)? onEvent,
    double endpointSilence = 1.0,
  }) async {
    // [tts] may be null: the worker then starts with ASR/VAD only and no
    // engine loaded — Kokoro (the only TTS) is a lazy-download pack, so
    // loading anything at startup would demand an absent model. The app
    // always calls [useTts] right after start; synthesize jobs before that
    // come back with an error.
    final ready = Completer<void>();
    final controlPort = ReceivePort();
    late final SpeechWorker worker;

    worker = SpeechWorker._(
      controlPort.listen((message) {
        if (message is _JobResult) {
          if (message.isChunk) {
            worker._chunkFans[message.id]?.call(
              message.audio!,
              message.sampleRate!,
            );
            if (message.lastChunk) {
              worker._chunkFans.remove(message.id);
              worker._pending.remove(message.id)?.complete(message);
            }
          } else {
            worker._pending.remove(message.id)?.complete(message);
          }
        } else if (message is SendPort) {
          worker._toWorker = message;
        } else if (message == 'ready') {
          if (!ready.isCompleted) ready.complete();
        } else if (message is _Event) {
          worker.onEvent?.call(switch (message.kind) {
            'speechStart' => const SpeechEvent.started(),
            'speechEnd' => const SpeechEvent.stopped(),
            'note' => SpeechEvent.diagnostic(message.note ?? ''),
            _ => SpeechEvent.ofSegment(message.samples),
          });
        } else if (message is List && message.length == 2) {
          // Isolate onError: [error, stackTrace]
          worker._failAll('Speech worker error: ${message[0]}');
        } else if (message is int) {
          // Isolate onExit: exit code
          worker._failAll('Speech worker exited ($message)');
        }
      }),
      onEvent,
    );

    worker._isolate = await Isolate.spawn(
      (arg) {
        final (SendPort toParent, (ModelPaths, double, TtsSpec?) cfg) = arg;
        _runWorker(toParent, cfg.$1, cfg.$2, cfg.$3);
      },
      (controlPort.sendPort, (paths, endpointSilence, tts)),
      errorsAreFatal: true,
      onError: controlPort.sendPort,
      onExit: controlPort.sendPort,
    );

    await ready.future;
    return worker;
  }

  /// Feed one microphone chunk (any length) to the VAD. Fire-and-forget.
  void sendAudio(Float32List samples) => _toWorker?.send(_Job.audio(samples));

  /// Drop any in-progress utterance (e.g. when the session is toggled).
  void resetVad() => _toWorker?.send(_Job.resetVad());

  /// Tell the worker our TTS started/stopped playing: while it plays the
  /// gate goes into hard mode (self-interruption protection).
  void setPlaying(bool on) => _toWorker?.send(_Job.playing(on));

  /// Swap the speaking voice (the Kokoro style roster index rides in the
  /// spec). Blocks until the new engine is loaded. Returns the new
  /// engine's speaker count.
  Future<int> useTts(TtsSpec spec) async {
    final result = await _send(_Job.useTts(++_nextId, spec));
    if (result.error != null) throw StateError(result.error!);
    return result.number;
  }

  Future<String> transcribe(Float32List samples, int sampleRate) async {
    final result = await _send(_Job.transcribe(++_nextId, samples, sampleRate));
    if (result.error != null) throw StateError(result.error!);
    return result.text ?? '';
  }

  Future<(Float32List samples, int sampleRate)> synthesize(String text) =>
      synthesizeStream(text);

  /// Synthesises [text] in sentence chunks (see splitForTts), invoking
  /// [onChunk] per chunk AS IT IS RENDERED — a later sentence is still
  /// synthesising while an earlier one already plays. The returned future
  /// resolves with the concatenation once the whole reply is done (used
  /// verbatim when [onChunk] is null). Errors abort the stream the same way
  /// [synthesize] used to.
  Future<(Float32List samples, int sampleRate)> synthesizeStream(
    String text, {
    void Function(Float32List chunk, int sampleRate)? onChunk,
  }) async {
    final id = ++_nextId;
    final parts = <Float32List>[];
    final completer = Completer<_JobResult>();
    _chunkFans[id] = (chunk, rate) {
      parts.add(chunk);
      onChunk?.call(chunk, rate);
    };
    _pending[id] = completer;
    _toWorker!.send(_Job.synthesize(id, text));
    final result = await completer.future;
    _chunkFans.remove(id);
    if (result.error != null) throw StateError(result.error!);
    final total = parts.fold<int>(0, (n, c) => n + c.length);
    final out = Float32List(total);
    var off = 0;
    for (final c in parts) {
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    return (out, result.sampleRate ?? 24000);
  }

  /// Offline cleanup for a finished push-to-talk clip (high-pass + frame
  /// noise gate). The returned audio is what should go to [transcribe].
  Future<Float32List> denoise(Float32List pcm) async {
    final result = await _send(_Job.denoise(++_nextId, pcm));
    if (result.error != null) throw StateError(result.error!);
    return result.audio!;
  }

  Future<_JobResult> _send(_Job job) {
    final completer = Completer<_JobResult>();
    _pending[job.id] = completer;
    _toWorker!.send(job);
    return completer.future;
  }

  void _failAll(String message) {
    _chunkFans.clear(); // abandoned streams; the error results below release
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(_JobResult.error(-1, message));
    }
    _pending.clear();
  }

  void dispose() {
    _failAll('Speech worker disposed');
    _eventsSub.cancel();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
  }
}

// ── Worker isolate entry point ───────────────────────────────────────────

/// The swappable engine handle: the sherpa-wrapped teacher (Kokoro)
/// and the direct-FFI student (teacher-in-the-loop) return identical
/// float PCM, so the sentence-splitting synth arm below keeps exactly
/// one call path. generate() is synchronous by contract: it runs on
/// the worker isolate between chunk sends.
abstract class TtsBackend {
  int get numSpeakers;
  (Float32List, int) generate({required String text, int sid, double speed});
  void free();
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

/// The 8M student: espeak-ng (bundled natives) → Kokoro vocab ids →
/// the small ONNX graph on sherpa's own libonnxruntime. One voice, so
/// numSpeakers is a humble 1; the voice style that IS the model.
class TitlTts implements TtsBackend {
  final TitlEngine engine;
  final String espeakVoice; // 'en-us' today, the Italian pair tomorrow
  TitlTts(this.engine, this.espeakVoice);
  @override
  int get numSpeakers => 1;
  @override
  (Float32List, int) generate({
    required String text,
    int sid = 0,
    double speed = 1.0,
  }) {
    final words = piper.PiperPhonemize.phonemize(text, voice: espeakVoice);
    return (
      engine.synth(
        TitlEngine.phonemesFromWords(words, engine.vocab.keys.toSet()),
        speed: speed,
      ),
      TitlEngine.sampleRate,
    );
  }

  @override
  void free() => engine.dispose();
}

Future<void> _runWorker(
  SendPort toParent,
  ModelPaths p,
  double endpointSilence,
  TtsSpec? spec,
) async {
  await sherpa_onnx.initBindingsAsync();

  final asr = sherpa_onnx.OfflineRecognizer(
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
  );

  // The TTS engine is swappable at runtime ('useTts' job below): the
  // Kokoro teacher (via sherpa) or the teacher-in-the-loop student
  // (direct FFI). It may also be absent entirely until the first
  // useTts (the pack is a lazy download; see [SpeechWorker.start]).
  sherpa_onnx.OfflineTts buildKokoro(TtsSpec s) => sherpa_onnx.OfflineTts(
    sherpa_onnx.OfflineTtsConfig(
      model: sherpa_onnx.OfflineTtsModelConfig(
        // The generic generate() synth arm below already fits — per-
        // piece forward pass, sid selection, clean heads (no prefix/
        // trim/lead-in ritual, no max_frames guard: nothing here can
        // babble). Measured RTF 0.10 at 4 threads on this desktop's
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
  );

  Future<TtsBackend> buildTts(TtsSpec s) async {
    if (s.engine == 'titl') {
      await piper.initBindingsAsync();
      piper.PiperPhonemize.initialize(s.espeakDataDir);
      return TitlTts(
        TitlEngine.load(modelPath: s.titlModel, vocabPath: s.titlVocab),
        s.espeakVoice,
      );
    }
    return SherpaTts(buildKokoro(s));
  }

  TtsBackend? tts = spec == null ? null : await buildTts(spec);

  sherpa_onnx.VoiceActivityDetector? vad;
  if (p.vadModel.isNotEmpty) {
    vad = sherpa_onnx.VoiceActivityDetector(
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
          minSilenceDuration: endpointSilence, // endpoint after N s of silence
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
    );
  }

  // The front end: rumble kill -> noise floor -> SNR gate -> Silero.
  final hp = HighPassFilter();
  final floor = NoiseFloorTracker();
  final gate = SpeechGate(floor);
  final holdFrames = (endpointSilence * 31.25).ceil();
  const confirmStreak = 5; // ~160 ms: filters clicks & AEC lock-in blips
  const confirmStreakPlaying = 14; // ~450 ms mid-reply: an interruption is
  // sustained speech. Raised from 10 after streamed replies revealed two
  // artefacts that ride the +20 dB bar for 300-400 ms but never talk
  // through 450: AEC re-lock leaks when Android stalls capture across a
  // chunk seam, and AGC gain-boost overshoot when our audio resumes after
  // an inter-sentence gap (the auto-gain pumps up during the silence).

  var gateStarted = false; // gate has raised speech for this utterance
  var passStreak = 0; // consecutive gate-passing frames
  var silentFrames = 0; // consecutive jointly-quiet frames (endpoint hold)
  var speechFrames = 0, speechLoud = 0; // utterance duty cycle
  var diagWindows = 0;
  var playing = false; // our TTS reply is audible (barge-in hard mode)

  // A VAD segment is only delivered when it looks like real speech: the
  // utterance must have had enough gate-loud frames (duty cycle). Echo
  // residue and clatter score as speech to Silero but sit near the floor,
  // so their duty cycle collapses. A whole-segment SNR test alone would be
  // useless — endpoint silence pads dilute it — the per-frame duty cycle is
  // the robust signal.
  Float32List? checkSegment(List<double> list) {
    final seg = Float32List.fromList(list);
    if (seg.length < 16000 ~/ 5) return null; // < 0.2 s: tap/breath
    if (speechFrames > 0) {
      final duty = speechLoud / speechFrames;
      if (duty < 0.35) {
        toParent.send(
          _Event.note(
            'segment dropped: duty ${(duty * 100).toStringAsFixed(0)}%',
          ),
        );
        return null;
      }
    } else {
      var sum = 0.0;
      for (final v in seg) {
        sum += v * v;
      }
      final segDb = sum <= 0 ? -100.0 : 10 * math.log(sum / seg.length) / _ln10;
      if (segDb < floor.noiseFloorDb + 6) return null;
    }
    return seg;
  }

  void resetSpeechState() {
    gateStarted = false;
    passStreak = 0;
    silentFrames = 0;
    speechFrames = 0;
    speechLoud = 0;
  }

  void drainSegments() {
    while (vad != null && !vad.isEmpty()) {
      final seg = checkSegment(vad.front().samples);
      vad.pop();
      if (seg != null) toParent.send(_Event.segment(seg));
    }
  }

  final port = ReceivePort();
  toParent.send(port.sendPort);
  toParent.send('ready');

  await for (final message in port) {
    if (message is! _Job) continue;
    try {
      switch (message.op) {
        case 'audio':
          if (vad == null) break;
          // The floor pins (stops tracking) while an utterance or our reply
          // is active, so neither the user's voice nor our own echo can lift
          // the baseline against the *next* utterance.
          final clean = hp.process(message.samples!);
          gate.offer(clean, freezeFloor: gateStarted || playing);
          final passing = gate.passes();
          passStreak = passing ? passStreak + 1 : 0;
          vad.acceptWaveform(clean);
          final detecting = vad.isDetected();
          if (!gateStarted) {
            // Speech begins when Silero and the SNR gate agree — for the
            // first 500 ms of a reply the bar sits +30 dB above the floor,
            // so the AEC lock-in leak can't self-interrupt.
            // While our reply plays, use the longer streak: the bar alone
            // (+20 dB) still lets slow feedback swells through, but none
            // that last under ~320 ms. A real barge-in doesn't mind the
            // third of a second.
            final needed = playing ? confirmStreakPlaying : confirmStreak;
            if (detecting && passStreak >= needed) {
              gateStarted = true;
              silentFrames = 0;
              speechFrames = 0;
              speechLoud = 0;
              if (playing) {
                // This candidate interrupted our reply: name its acoustics
                // so the app's debug view can tell a real cut-in from an
                // echo/AGC leak after the fact (no more guesswork).
                toParent.send(
                  _Event.note(
                    'bargein: lvl=${gate.levelDb.toStringAsFixed(0)} '
                    'floor=${gate.noiseFloorDb.toStringAsFixed(0)} '
                    'streak=$passStreak/$needed',
                  ),
                );
              }
              toParent.send(_Event.speechStart());
            }
          } else {
            // Duty-cycle bookkeeping for the segment check. The VAD's own
            // endpoint rules when speech ends (noise bursts shorter than
            // minSilenceDuration can't cut the user off); the gate only
            // vetoes a *start* — plus the joint-quiet hold below, which ends
            // the utterance when the VAD stays locked (e.g. our own reply's
            // echo holding detection up):
            speechFrames++;
            if (passing) speechLoud++;
            final jointQuiet = !gate.held() && !passing;
            silentFrames = jointQuiet ? silentFrames + 1 : 0;
          }
          if (gateStarted && (!detecting || silentFrames >= holdFrames)) {
            gateStarted = false;
            silentFrames = 0;
            toParent.send(_Event.speechEnd());
          }
          drainSegments();
          if (++diagWindows % 94 == 0) {
            toParent.send(
              _Event.note(
                'level=${gate.levelDb.toStringAsFixed(0)}dB '
                'floor=${gate.noiseFloorDb.toStringAsFixed(0)}dB '
                'pass=${passing ? 1 : 0} streak=$passStreak '
                'play=${playing ? 1 : 0} det=${detecting ? 1 : 0}',
              ),
            );
          }
        case 'playing':
          playing = message.text == 'on';
          if (playing) {
            gate.playbackStarted();
          } else {
            gate.playbackEnded();
          }
        case 'resetVad':
          vad?.reset();
          resetSpeechState();
        case 'denoise':
          final g = denoiseClip(
            message.samples!,
            floor: NoiseFloorTracker(initialDb: -18),
          );
          toParent.send(_JobResult.audio(message.id, g.samples, 16000));
          toParent.send(
            _Event.note(
              'denoise kept ${(g.keptFraction * 100).toStringAsFixed(0)}%',
            ),
          );
        case 'transcribe':
          final stream = asr.createStream();
          stream.acceptWaveform(
            samples: message.samples!,
            sampleRate: message.sampleRate!,
          );
          asr.decode(stream);
          final text = asr.getResult(stream).text;
          stream.free();
          toParent.send(_JobResult.text(message.id, text));
        case 'useTts':
          // Load the new engine *before* freeing the old one, so a bad
          // path leaves the current voice usable.
          final next = message.spec!;
          final old = tts;
          tts = await buildTts(next);
          spec = next;
          old?.free();
          // Drop any half-heard utterance across the switch.
          vad?.reset();
          resetSpeechState();
          toParent.send(_JobResult.ok(message.id, tts.numSpeakers));
        case 'synthesize':
          // Sentence-chunked synthesis: Kokoro streams piece by piece, so
          // the assistant can start playing the first sentence while the
          // rest is still rendering. Non-final pieces get a ~62 ms silent
          // tail: a natural sentence gap that hides the seam.
          if (tts == null || spec == null) {
            toParent.send(
              _JobResult.error(
                message.id,
                'No TTS engine loaded yet — pick a voice first.',
              ),
            );
            break;
          }
          final pieces = splitForTts(message.text!);
          for (var i = 0; i < pieces.length; i++) {
            final piece = pieces[i];
            final isLast = i == pieces.length - 1;
            final (samples, sampleRate) = tts.generate(
              text: piece,
              sid: spec.sid,
              speed: 1.0,
            );
            var data = samples;
            if (!isLast) {
              data = Float32List(samples.length + sampleRate ~/ 16)
                ..setRange(0, samples.length, samples);
            }
            toParent.send(
              _JobResult.chunk(message.id, data, sampleRate, isLast),
            );
          }
      }
    } catch (e, s) {
      toParent.send(_JobResult.error(message.id, '$e\n$s'));
    }
  }
}
