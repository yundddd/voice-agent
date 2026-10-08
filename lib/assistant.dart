import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'audio_io.dart';
import 'model_packs.dart';
import 'model_paths.dart';
import 'speech_worker.dart';

enum AssistantPhase { idle, listening, transcribing, speaking, error }

/// Orchestrates the voice round trip:
///   mic -> PCM16 buffer -> Whisper (ASR) -> text -> Piper VITS (TTS) -> WAV -> speaker
class VoiceAssistant extends ChangeNotifier {
  SpeechWorker? _worker;
  AudioRecorder? _recorder;
  final AudioPlayer _player = AudioPlayer();

  List<Float32List> _chunks = [];
  StreamSubscription<Uint8List>? _recSub;
  int _generation = 0;

  AssistantPhase _phase = AssistantPhase.idle;
  String _status = 'Loading models…';
  String _transcript = '';
  String _error = '';
  double _recordSeconds = 0;
  double _asrSeconds = 0;
  double _ttsSeconds = 0;
  double _playSeconds = 0;
  final Stopwatch _sw = Stopwatch();

  AssistantPhase get phase => _phase;
  String get status => _status;
  String get transcript => _transcript;
  String get error => _error;
  double get recordSeconds => _recordSeconds;
  double get asrSeconds => _asrSeconds;
  double get ttsSeconds => _ttsSeconds;
  double get playSeconds => _playSeconds;

  Future<void> init() async {
    try {
      final modelsDir = await unpackModels(onProgress: (label, done, total) {
        _status = total > 0
            ? 'Downloading $label: '
              '${(done / (1024 * 1024)).toStringAsFixed(1)} / '
              '${(total / (1024 * 1024)).toStringAsFixed(1)} MB'
            : '$label…';
        notifyListeners();
      });
      _worker = await SpeechWorker.start(ModelPaths.fromModelsDir(modelsDir));
      _phase = AssistantPhase.idle;
      _status = 'Models loaded. Tap the mic and speak.';
      notifyListeners();
    } catch (e) {
      _fail('Model init failed: $e');
    }
  }

  void _fail(String message) {
    _phase = AssistantPhase.error;
    _error = message;
    _status = 'Error. Tap the mic to retry.';
    notifyListeners();
  }

  Future<void> startListening() async {
    if (_phase == AssistantPhase.listening) return;
    if (_worker == null) return; // still loading
    try {
      final rec = _recorder ??= AudioRecorder();
      if (!await rec.hasPermission()) {
        _fail('Microphone permission denied');
        return;
      }
      const encoder = AudioEncoder.pcm16bits;
      if (!await rec.isEncoderSupported(encoder)) {
        _fail('PCM16 capture not supported on this platform');
        return;
      }
      await _player.stop();
      _generation++; // abandon any in-flight transcribe/speak
      _chunks = [];
      _sw
        ..reset()
        ..start();
      final stream = await rec.startStream(
        const RecordConfig(
          encoder: encoder,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _phase = AssistantPhase.listening;
      _error = '';
      _status = 'Listening… tap to stop.';
      notifyListeners();

      _recSub = stream.listen(
        (bytes) => _chunks.add(pcm16ToFloat32(bytes)),
        onError: (Object e) => _fail('Recording error: $e'),
      );
    } catch (e) {
      _fail('Could not start recording: $e');
    }
  }

  Future<void> stopAndRespond() async {
    if (_phase != AssistantPhase.listening) return;
    await _recSub?.cancel();
    await _recorder?.stop();
    _recordSeconds = _sw.elapsedMilliseconds / 1000.0;

    final total = _chunks.fold<int>(0, (n, c) => n + c.length);
    if (total < 16000 ~/ 4) {
      // Less than a quarter second of audio.
      _phase = AssistantPhase.idle;
      _status = 'Heard nothing. Tap the mic and speak.';
      notifyListeners();
      return;
    }
    final pcm = Float32List(total);
    var offset = 0;
    for (final c in _chunks) {
      pcm.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    _chunks = [];

    final generation = ++_generation;
    _phase = AssistantPhase.transcribing;
    _status = 'Transcribing…';
    notifyListeners();

    try {
      final swAsr = Stopwatch()..start();
      final text = await _worker!.transcribe(pcm, 16000);
      swAsr.stop();
      if (generation != _generation) return; // superseded
      _asrSeconds = swAsr.elapsedMilliseconds / 1000.0;
      _transcript = text.trim();

      if (_transcript.isEmpty) {
        _phase = AssistantPhase.idle;
        _status = 'No speech recognized. Try again.';
        notifyListeners();
        return;
      }

      _phase = AssistantPhase.speaking;
      _status = 'Speaking: “$_transcript”';
      notifyListeners();

      final swTts = Stopwatch()..start();
      final (samples, sampleRate) =
          await _worker!.synthesize(_transcript);
      swTts.stop();
      if (generation != _generation) return;
      _ttsSeconds = swTts.elapsedMilliseconds / 1000.0;

      _playSeconds = samples.length / sampleRate;
      await _playWav(samples, sampleRate);

      _phase = AssistantPhase.idle;
      _status = 'Done. Tap the mic to go again.';
      notifyListeners();
    } catch (e) {
      _fail('Round trip failed: $e');
    }
  }

  Future<void> _playWav(Float32List samples, int sampleRate) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, 'reply_${DateTime.now().millisecondsSinceEpoch}.wav'),
    );
    await file.writeAsBytes(encodeWav(samples, sampleRate));
    final done = Completer<void>();
    final sub = _player.onPlayerComplete.listen((_) => done.complete());
    await _player.play(DeviceFileSource(file.path));
    await done.future;
    await sub.cancel();
    try {
      await file.delete();
    } catch (_) {}
  }

  Future<void> toggle() => _phase == AssistantPhase.listening
      ? stopAndRespond()
      : startListening();

  @override
  void dispose() {
    _recSub?.cancel();
    _recorder?.dispose();
    _player.dispose();
    _worker?.dispose();
    super.dispose();
  }
}
