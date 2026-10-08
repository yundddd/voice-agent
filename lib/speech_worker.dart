import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'model_paths.dart';

/// Jobs sent to the worker over its control port.
class _Job {
  final int id; // -1 for fire-and-forget ops
  final String op; // 'audio' | 'resetVad' | 'transcribe' | 'synthesize'
  final String? text;
  final Float32List? samples;
  final int? sampleRate;
  const _Job.audio(this.samples)
      : id = -1,
        op = 'audio',
        text = null,
        sampleRate = null;
  const _Job.resetVad()
      : id = -1,
        op = 'resetVad',
        samples = null,
        text = null,
        sampleRate = null;
  const _Job.transcribe(this.id, this.samples, this.sampleRate)
      : text = null,
        op = 'transcribe';
  const _Job.synthesize(this.id, this.text)
      : samples = null,
        sampleRate = null,
        op = 'synthesize';
}

/// One-way events pushed from the worker (VAD output).
class _Event {
  final String kind; // 'speechStart' | 'speechEnd' | 'segment'
  final Float32List? samples;
  _Event.speechStart()
      : kind = 'speechStart',
        samples = null;
  _Event.speechEnd()
      : kind = 'speechEnd',
        samples = null;
  _Event.segment(Float32List s)
      : kind = 'segment',
        samples = s;
}

/// A job result coming back from the worker.
class _JobResult {
  final int id;
  final String? text;
  final Float32List? audio;
  final int? sampleRate;
  final String? error;
  _JobResult.text(this.id, this.text)
      : audio = null,
        sampleRate = null,
        error = null;
  _JobResult.audio(this.id, this.audio, this.sampleRate)
      : text = null,
        error = null;
  _JobResult.error(this.id, this.error)
      : text = null,
        audio = null,
        sampleRate = null;
}

/// One-way VAD notification. `speechStarted`/`speechStopped` track the live
/// speech flag; `segment` carries a finished utterance (endpointed after
/// [endpointSilence] seconds of silence), ready for transcription.
class SpeechEvent {
  final bool speechStarted;
  final Float32List? segment;
  const SpeechEvent.started()
      : speechStarted = true,
        segment = null;
  const SpeechEvent.stopped()
      : speechStarted = false,
        segment = null;
  const SpeechEvent.ofSegment(this.segment) : speechStarted = false;
}

/// Owns the on-device models (ASR + TTS + optional VAD) inside a dedicated
/// isolate so inference never blocks the UI. Create with [SpeechWorker.start].
class SpeechWorker {
  SpeechWorker._(this._eventsSub, this.onEvent);

  final StreamSubscription<Object?> _eventsSub;

  /// Receives VAD notifications; set before awaiting [SpeechWorker.start]
  /// completion via the [onEvent] parameter.
  final void Function(SpeechEvent)? onEvent;

  final Map<int, Completer<_JobResult>> _pending = {};
  int _nextId = 0;
  Isolate? _isolate;
  SendPort? _toWorker;

  static Future<SpeechWorker> start(
    ModelPaths paths, {
    void Function(SpeechEvent)? onEvent,
    double endpointSilence = 1.0,
  }) async {
    final ready = Completer<void>();
    final controlPort = ReceivePort();
    late final SpeechWorker worker;

    worker = SpeechWorker._(
      controlPort.listen((message) {
        if (message is _JobResult) {
          worker._pending.remove(message.id)?.complete(message);
        } else if (message is SendPort) {
          worker._toWorker = message;
        } else if (message == 'ready') {
          if (!ready.isCompleted) ready.complete();
        } else if (message is _Event) {
          worker.onEvent?.call(
            message.kind == 'speechStart'
                ? const SpeechEvent.started()
                : message.kind == 'speechEnd'
                    ? const SpeechEvent.stopped()
                    : SpeechEvent.ofSegment(message.samples),
          );
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
        final (SendPort toParent, (ModelPaths, double) cfg) = arg;
        _runWorker(toParent, cfg.$1, cfg.$2);
      },
      (controlPort.sendPort, (paths, endpointSilence)),
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

  Future<String> transcribe(Float32List samples, int sampleRate) async {
    final result = await _send(_Job.transcribe(++_nextId, samples, sampleRate));
    if (result.error != null) throw StateError(result.error!);
    return result.text ?? '';
  }

  Future<(Float32List samples, int sampleRate)> synthesize(String text) async {
    final result = await _send(_Job.synthesize(++_nextId, text));
    if (result.error != null) throw StateError(result.error!);
    return (result.audio!, result.sampleRate!);
  }

  Future<_JobResult> _send(_Job job) {
    final completer = Completer<_JobResult>();
    _pending[job.id] = completer;
    _toWorker!.send(job);
    return completer.future;
  }

  void _failAll(String message) {
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

Future<void> _runWorker(
  SendPort toParent,
  ModelPaths p,
  double endpointSilence,
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

  final tts = sherpa_onnx.OfflineTts(
    sherpa_onnx.OfflineTtsConfig(
      model: sherpa_onnx.OfflineTtsModelConfig(
        vits: sherpa_onnx.OfflineTtsVitsModelConfig(
          model: p.vitsModel,
          tokens: p.vitsTokens,
          dataDir: p.espeakDataDir,
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
      maxNumSenetences: 4,
    ),
  );

  sherpa_onnx.VoiceActivityDetector? vad;
  bool wasDetecting = false;
  if (p.vadModel.isNotEmpty) {
    vad = sherpa_onnx.VoiceActivityDetector(
      config: sherpa_onnx.VadModelConfig(
        sileroVad: sherpa_onnx.SileroVadModelConfig(
          model: p.vadModel,
          threshold: 0.5,
          minSilenceDuration: endpointSilence, // endpoint after N s of silence
          minSpeechDuration: 0.25,
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

  final port = ReceivePort();
  toParent.send(port.sendPort);
  toParent.send('ready');

  void drainSegments() {
    while (vad != null && !vad.isEmpty()) {
      final samples = vad.front().samples;
      vad.pop();
      if (samples.length > 16000 ~/ 4) {
        toParent.send(_Event.segment(Float32List.fromList(samples)));
      }
    }
  }

  await for (final message in port) {
    if (message is! _Job) continue;
    try {
      switch (message.op) {
        case 'audio':
          if (vad == null) break;
          vad.acceptWaveform(message.samples!);
          final detecting = vad.isDetected();
          if (detecting != wasDetecting) {
            wasDetecting = detecting;
            toParent.send(
              detecting ? _Event.speechStart() : _Event.speechEnd(),
            );
          }
          drainSegments();
        case 'resetVad':
          vad?.reset();
          wasDetecting = false;
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
        case 'synthesize':
          final audio = tts.generate(text: message.text!, sid: 0, speed: 1.0);
          toParent.send(
            _JobResult.audio(message.id, audio.samples, audio.sampleRate),
          );
      }
    } catch (e, s) {
      toParent.send(_JobResult.error(message.id, '$e\n$s'));
    }
  }
}
