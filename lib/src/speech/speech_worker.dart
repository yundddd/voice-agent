import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'tts_split.dart';
import 'worker_backends.dart';

export 'tts_split.dart';
export 'worker_backends.dart';

import '../audio/audio_dsp.dart';
import 'speech_engine.dart';

export 'speech_engine.dart';
import '../models/model_paths.dart';

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
  final int? sid; // 'synthesize': one-shot speaker override (auditions)
  const _Job.audio(this.samples)
    : id = -1,
      op = 'audio',
      text = null,
      sampleRate = null,
      spec = null,
      sid = null;
  const _Job.resetVad()
    : id = -1,
      op = 'resetVad',
      samples = null,
      text = null,
      sampleRate = null,
      spec = null,
      sid = null;
  const _Job.playing(bool on)
    : id = -1,
      op = 'playing',
      text = on ? 'on' : 'off',
      samples = null,
      sampleRate = null,
      spec = null,
      sid = null;
  const _Job.transcribe(this.id, this.samples, this.sampleRate)
    : text = null,
      op = 'transcribe',
      spec = null,
      sid = null;
  const _Job.synthesize(this.id, this.text, this.sid)
    : samples = null,
      sampleRate = null,
      op = 'synthesize',
      spec = null;
  const _Job.denoise(this.id, this.samples)
    : text = null,
      sampleRate = null,
      op = 'denoise',
      spec = null,
      sid = null;
  const _Job.useTts(this.id, this.spec)
    : text = null,
      samples = null,
      sampleRate = null,
      op = 'useTts',
      sid = null;
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

/// Owns the on-device models (ASR + TTS + optional VAD) and the noise/echo
/// front end inside a dedicated isolate so inference never blocks the UI.
/// Create with [SpeechWorker.start].
class SpeechWorker implements SpeechEngine {
  SpeechWorker._(this._eventsSub, this.onEvent);

  final StreamSubscription<Object?> _eventsSub;

  /// Receives speech-pipeline notifications; set before awaiting
  /// [SpeechWorker.start] completion via the [onEvent] parameter.
  final void Function(SpeechEvent)? onEvent;

  final Map<int, Completer<_JobResult>> _pending = {};
  final Map<int, void Function(Float32List chunk, int sampleRate)> _chunkFans =
      {};
  int _nextId = 0;
  int _ttsNumSpeakers = 0;
  Isolate? _isolate;
  SendPort? _toWorker;

  /// Speaker count of the engine loaded at [start] (0 = none yet).
  /// `useTts` keeps its own return value authoritative after swaps.
  @override
  int get ttsNumSpeakers => _ttsNumSpeakers;

  static Future<SpeechWorker> start(
    ModelPaths paths, {
    TtsSpec? tts,
    void Function(SpeechEvent)? onEvent,
    double endpointSilence = 1.0,
    WorkerBackends backends = const RealBackends(),
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
        } else if (message is String && message.startsWith('ready:')) {
          worker._ttsNumSpeakers = int.tryParse(message.substring(6)) ?? 0;
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
        final (
          SendPort toParent,
          (ModelPaths, double, TtsSpec?, WorkerBackends) cfg,
        ) = arg;
        _runWorker(toParent, cfg.$1, cfg.$2, cfg.$3, cfg.$4);
      },
      (controlPort.sendPort, (paths, endpointSilence, tts, backends)),
      errorsAreFatal: true,
      onError: controlPort.sendPort,
      onExit: controlPort.sendPort,
    );

    await ready.future;
    return worker;
  }

  /// Feed one microphone chunk (any length) to the VAD. Fire-and-forget.
  @override
  void sendAudio(Float32List samples) => _toWorker?.send(_Job.audio(samples));

  /// Drop any in-progress utterance (e.g. when the session is toggled).
  @override
  void resetVad() => _toWorker?.send(_Job.resetVad());

  /// Tell the worker our TTS started/stopped playing: while it plays the
  /// gate goes into hard mode (self-interruption protection).
  @override
  void setPlaying(bool on) => _toWorker?.send(_Job.playing(on));

  /// Swap the speaking voice (the Kokoro style roster index rides in the
  /// spec). Blocks until the new engine is loaded. Returns the new
  /// engine's speaker count.
  @override
  Future<int> useTts(TtsSpec spec) async {
    final result = await _send(_Job.useTts(++_nextId, spec));
    if (result.error != null) throw StateError(result.error!);
    return _ttsNumSpeakers = result.number;
  }

  @override
  Future<String> transcribe(Float32List samples, int sampleRate) async {
    final result = await _send(_Job.transcribe(++_nextId, samples, sampleRate));
    if (result.error != null) throw StateError(result.error!);
    return result.text ?? '';
  }

  @override
  Future<(Float32List samples, int sampleRate)> synthesize(
    String text, {
    int? sid,
  }) => synthesizeStream(text, sid: sid);

  /// Synthesises [text] in sentence chunks (see splitForTts), invoking
  /// [onChunk] per chunk AS IT IS RENDERED — a later sentence is still
  /// synthesising while an earlier one already plays. The returned future
  /// resolves with the concatenation once the whole reply is done (used
  /// verbatim when [onChunk] is null). Errors abort the stream the same way
  /// [synthesize] used to.
  @override
  Future<(Float32List samples, int sampleRate)> synthesizeStream(
    String text, {
    void Function(Float32List chunk, int sampleRate)? onChunk,
    int? sid,
  }) async {
    final id = ++_nextId;
    final parts = <Float32List>[];
    final completer = Completer<_JobResult>();
    _chunkFans[id] = (chunk, rate) {
      parts.add(chunk);
      onChunk?.call(chunk, rate);
    };
    _pending[id] = completer;
    _toWorker!.send(_Job.synthesize(id, text, sid));
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
  @override
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

  @override
  void dispose() {
    _failAll('Speech worker disposed');
    _eventsSub.cancel();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
  }
}

// Worker isolate entry point

Future<void> _runWorker(
  SendPort toParent,
  ModelPaths p,
  double endpointSilence,
  TtsSpec? spec,
  WorkerBackends backends,
) async {
  // Everything native sits behind these seams (worker_backends.dart):
  // tests hand in FakeBackends and the whole pipeline below — the job
  // protocol, the noise gate, the endpointing choreography, the
  // sentence-chunked synthesis — runs unchanged, no libonnxruntime.
  final asr = await backends.buildAsr(p);
  VadBackend? vad = await backends.buildVad(p, endpointSilence);

  // The TTS engine is swappable at runtime ('useTts' job below): the
  // Kokoro teacher (via sherpa) or the teacher-in-the-loop student
  // (direct FFI). It may also be absent entirely until the first
  // useTts (the pack is a lazy download; see [SpeechWorker.start]).
  TtsBackend? tts = spec == null ? null : await backends.buildTts(spec);

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
      final seg = checkSegment(vad.frontSamples());
      vad.pop();
      if (seg != null) toParent.send(_Event.segment(seg));
    }
  }

  final port = ReceivePort();
  toParent.send(port.sendPort);
  // The ready handshake carries the speaker count of the engine we just
  // loaded: the app must know whether the current voice has a style
  // roster (Kokoro: 54) before the user ever calls useTts.
  toParent.send('ready:${tts?.numSpeakers ?? 0}');

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
          toParent.send(
            _JobResult.text(
              message.id,
              // +236: a chunked decode lifts each finished piece to the
              // parent as a 'partial:' note BEFORE the job result —
              // cumulative text, in order, so the placeholder bubble
              // fills while the rest is still in Whisper.
              asr.transcribe(
                message.samples!,
                message.sampleRate!,
                onPartial: (t) => toParent.send(_Event.note('partial:$t')),
              ),
            ),
          );
        case 'useTts':
          // Load the new engine *before* freeing the old one, so a bad
          // path leaves the current voice usable.
          final next = message.spec!;
          final old = tts;
          tts = await backends.buildTts(next);
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
          // One-shot speaker override (style-picker auditions): valid sids
          // ride this call only; the engine keeps its configured speaker.
          final sid =
              message.sid != null &&
                  message.sid! >= 0 &&
                  message.sid! < tts.numSpeakers
              ? message.sid!
              : spec.sid;
          for (var i = 0; i < pieces.length; i++) {
            final piece = pieces[i];
            final isLast = i == pieces.length - 1;
            final (samples, sampleRate) = tts.generate(
              text: piece,
              sid: sid,
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
