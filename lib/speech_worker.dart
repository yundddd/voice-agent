import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'model_paths.dart';

/// A transcribe/synthesize job sent to the worker over its control port.
class _Job {
  final int id;
  final String op; // 'transcribe' | 'synthesize'
  final String? text;
  final Float32List? samples;
  final int? sampleRate;
  const _Job.transcribe(this.id, this.samples, this.sampleRate)
      : text = null,
        op = 'transcribe';
  const _Job.synthesize(this.id, this.text)
      : samples = null,
        sampleRate = null,
        op = 'synthesize';
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

/// Owns the two on-device models (ASR + TTS) inside a dedicated isolate so
/// inference never blocks the UI. Create with [SpeechWorker.start].
class SpeechWorker {
  SpeechWorker._(this._eventsSub);

  final StreamSubscription<Object?> _eventsSub;
  final Map<int, Completer<_JobResult>> _pending = {};
  int _nextId = 0;
  Isolate? _isolate;
  SendPort? _toWorker;

  static Future<SpeechWorker> start(ModelPaths paths) async {
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
        } else if (message is List && message.length == 2) {
          // Isolate onError: [error, stackTrace]
          worker._failAll('Speech worker error: ${message[0]}');
        } else if (message is int) {
          // Isolate onExit: exit code
          worker._failAll('Speech worker exited ($message)');
        }
      }),
    );

    worker._isolate = await Isolate.spawn(
      (arg) {
        final (SendPort toParent, ModelPaths paths) = arg;
        _runWorker(toParent, paths);
      },
      (controlPort.sendPort, paths),
      errorsAreFatal: true,
      onError: controlPort.sendPort,
      onExit: controlPort.sendPort,
    );

    await ready.future;
    return worker;
  }


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

Future<void> _runWorker(SendPort toParent, ModelPaths p) async {
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

  final port = ReceivePort();
  toParent.send(port.sendPort);
  toParent.send('ready');

  await for (final message in port) {
    if (message is! _Job) continue;
    try {
      switch (message.op) {
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
