import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'audio_io.dart';
import 'model_packs.dart';
import 'model_paths.dart';
import 'speech_worker.dart';

/// Interaction styles.
enum InteractionMode {
  /// Hands-free: the mic runs continuously; an utterance ends when the user
  /// pauses for a second; talking over the reply mutes it right away.
  conversation,

  /// Classic push-to-talk: the mic only records while the user holds the floor
  /// open with the button.
  pushToTalk,
}

enum AssistantPhase { idle, listening, transcribing, speaking, error }

/// Orchestrates the voice round trip:
///   mic -> VAD endpointing -> Whisper (ASR) -> text -> Piper VITS (TTS) -> speaker
/// in two interaction modes (see [InteractionMode]).
class VoiceAssistant extends ChangeNotifier {
  VoiceAssistant() {
    _recorder = AudioRecorder();
    _player.onPlayerComplete.listen((_) => _onPlaybackNaturalEnd());
  }

  // Silence duration that ends an utterance in conversation mode.
  static const _endpointSilence = 1.0;

  final AudioPlayer _player = AudioPlayer();
  late final AudioRecorder _recorder;
  SpeechWorker? _worker;

  InteractionMode _mode = InteractionMode.conversation;
  AssistantPhase _phase = AssistantPhase.idle;
  String _status = 'Loading models…';
  String _transcript = '';
  String _error = '';
  String _lastSpoken = '';
  double _recordSeconds = 0;
  double _asrSeconds = 0;
  double _ttsSeconds = 0;
  double _playSeconds = 0;

  StreamSubscription<Uint8List>? _recSub;
  final List<Float32List> _chunks = []; // push-to-talk buffer
  final BytesBuilder _vadBuf = BytesBuilder(copy: false); // 512-sample aligner
  StreamSubscription<void>? _playSub;
  String? _playFile;
  bool _playerPlaying = false;
  bool _userSpeaking = false; // live VAD flag (conversation mode)
  bool _segEchoRisk = false; // current utterance started while we were talking
  bool _segGotAudio = false; // current utterance produced a VAD segment
  int _generation = 0; // cancels in-flight responses when bumped
  Timer? _micWatchdog;
  DateTime _lastMicAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _micRecovering = false;
  bool _disposed = false;

  InteractionMode get mode => _mode;
  AssistantPhase get phase => _phase;
  String get status => _status;
  String get transcript => _transcript;
  String get error => _error;
  bool get userSpeaking => _userSpeaking;
  bool get sessionActive =>
      _phase == AssistantPhase.listening ||
      _phase == AssistantPhase.transcribing ||
      _phase == AssistantPhase.speaking;
  double get recordSeconds => _recordSeconds;
  double get asrSeconds => _asrSeconds;
  double get ttsSeconds => _ttsSeconds;
  double get playSeconds => _playSeconds;

  // ── Lifecycle ────────────────────────────────────────────────────────────

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
      _worker = await SpeechWorker.start(
        ModelPaths.fromModelsDir(modelsDir),
        onEvent: _onSpeechEvent,
        endpointSilence: _endpointSilence,
      );
      _idleReady();
    } catch (e) {
      _fail('Model init failed: $e');
    }
  }

  void setMode(InteractionMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _shutdownAudio();
    _generation++;
    _idleReady();
  }

  /// Big-button action, interpreted per mode + phase.
  Future<void> toggle() async {
    switch (_mode) {
      case InteractionMode.conversation:
        switch (_phase) {
          case AssistantPhase.idle:
          case AssistantPhase.error:
            await _beginConversation();
          case AssistantPhase.listening:
            await _endConversation('Conversation closed. Tap to talk again.');
          case AssistantPhase.transcribing:
          case AssistantPhase.speaking:
            _cancelResponse('Got it. Tap to close, or just keep talking.');
        }
      case InteractionMode.pushToTalk:
        if (_phase == AssistantPhase.listening) {
          await _stopAndRespond();
        } else {
          await _startListening();
        }
    }
  }

  void _idleReady() {
    if (_worker == null) return;
    _phase = AssistantPhase.idle;
    _status = _mode == InteractionMode.conversation
        ? 'Tap the mic to start a conversation. Pause about a second and I\'ll answer.'
        : 'Ready. Tap the mic, speak, tap again to send.';
    notifyListeners();
  }

  void _fail(String message) {
    _phase = AssistantPhase.error;
    _error = message;
    _status = 'Error. Tap the mic to retry.';
    notifyListeners();
  }

  // ── Microphone plumbing (shared by both modes) ─────────────────────────

  /// Whether a live mic stream is expected right now (drives the watchdog).
  /// Only the listening phase needs capture: during transcribing/speaking we
  /// already have the segment, and restarting capture mid-reply would only
  /// confuse AEC.
  bool get _micStreamWanted => _phase == AssistantPhase.listening;

  Future<void> _openMicStream() async {
    _chunks.clear();
    _vadBuf.clear();
    if (!await _recorder.hasPermission()) {
      throw Exception('Microphone permission denied');
    }
    const encoder = AudioEncoder.pcm16bits;
    if (!await _recorder.isEncoderSupported(encoder)) {
      throw Exception('PCM16 capture not supported on this platform');
    }
    // Clean stop first: makes reopening idempotent (watchdog restarts,
    // retries after errors, mode switches).
    await _recSub?.cancel();
    _recSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    // voiceCommunication source + AEC/AGC: lets the mic hear the user while
    // our own TTS plays through the speaker (barge-in). Note: we deliberately
    // do NOT force AudioManagerMode.modeInCommunication — the plugin's mode
    // juggling around our media playback revokes communication mode and can
    // silently kill capture after the first reply; the source alone still gets
    // us the platform AEC.
    const config = RecordConfig(
      encoder: encoder,
      sampleRate: 16000,
      numChannels: 1,
      autoGain: true,
      echoCancel: true,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceCommunication,
        speakerphone: true,
      ),
    );
    final stream = await _recorder.startStream(config);
    _lastMicAt = DateTime.now();
    _recSub = stream.listen(
      _onMicData,
      // Android can close the capture stream when our playback changes audio
      // focus/mode/routing — that is exactly what the watchdog is for.
      onError: (Object e) => unawaited(_recoverMic('error: $e')),
      onDone: () => unawaited(_recoverMic('ended')),
    );
    _startMicWatchdog();
  }

  void _startMicWatchdog() {
    _micWatchdog?.cancel();
    _micWatchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_micRecovering || !_micStreamWanted) return;
      if (DateTime.now().difference(_lastMicAt) > const Duration(seconds: 3)) {
        unawaited(_recoverMic('stalled'));
      }
    });
  }

  /// Reopen the mic after the OS ends, pauses or stalls the capture stream
  /// (common after our own playback: focus/mode/routing changes).
  Future<void> _recoverMic(String why) async {
    if (_micRecovering || !_micStreamWanted) return;
    _micRecovering = true;
    debugPrint('mic stream $why — reopening');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_disposed) return;
    try {
      await _openMicStream(); // also resets _lastMicAt and the watchdog
      _worker?.resetVad();
      _userSpeaking = false;
      if (_phase == AssistantPhase.listening) {
        _status = _mode == InteractionMode.conversation
            ? 'Listening — just talk.'
            : 'Listening… tap again to send.';
        notifyListeners();
      }
    } catch (e) {
      _fail('Mic restart failed: $e');
    } finally {
      _micRecovering = false;
    }
  }

  void _onMicData(Uint8List bytes) {
    _lastMicAt = DateTime.now();
    if (_mode == InteractionMode.pushToTalk) {
      if (_phase == AssistantPhase.listening) {
        _chunks.add(pcm16ToFloat32(bytes));
      }
      return;
    }
    // Conversation: feed the VAD in exactly 512-sample windows.
    _vadBuf.add(bytes);
    var bytesPending = _vadBuf.toBytes(); // no-op when empty
    while (bytesPending.length >= 512 * 2) {
      final window = Uint8List.sublistView(bytesPending, 0, 512 * 2);
      bytesPending = bytesPending.sublist(512 * 2);
      _worker?.sendAudio(pcm16ToFloat32(window));
    }
    _vadBuf.clear();
    _vadBuf.add(bytesPending);
  }

  // ── Conversation mode ────────────────────────────────────────────────────

  Future<void> _beginConversation() async {
    try {
      await _openMicStream();
      _phase = AssistantPhase.listening;
      _error = '';
      _status = 'Listening — just talk.';
      notifyListeners();
    } catch (e) {
      _fail('$e');
    }
  }

  Future<void> _endConversation(String message) async {
    _shutdownAudio();
    _userSpeaking = false;
    _generation++;
    _phase = AssistantPhase.idle;
    _status = message;
    notifyListeners();
  }

  void _cancelResponse(String message) {
    _generation++; // abandon any in-flight turn
    _stopPlayback();
    _worker?.resetVad();
    _phase = AssistantPhase.listening;
    _status = message;
    notifyListeners();
  }

  void _onSpeechEvent(SpeechEvent event) {
    if (event.speechStarted) {
      // Barge-in: mute our own reply the instant the user talks.
      _segEchoRisk = _playerPlaying;
      _segGotAudio = false;
      _userSpeaking = true; // set first: keeps _stopPlayback from resetting
      if (_playerPlaying) {
        _stopPlayback();
        _generation++; // abandon the response we were speaking
        _status = 'Interrupted — go ahead.';
      } else if (_phase == AssistantPhase.transcribing) {
        _generation++; // user resumed; drop the half-baked response
      }
      if (_phase != AssistantPhase.listening &&
          _phase != AssistantPhase.error) {
        _phase = AssistantPhase.listening;
      }
      notifyListeners();
      return;
    }
    if (event.segment != null) {
      _userSpeaking = false;
      _segGotAudio = true;
      _recordSeconds = event.segment!.length / 16000.0;
      unawaited(_startTurn(event.segment!));
      return;
    }
    // Speech stopped but no segment followed (too short): nudge the user.
    _userSpeaking = false;
    if (!_segGotAudio && _phase == AssistantPhase.listening) {
      _status = 'I heard a bit — say a little more?';
      notifyListeners();
    }
  }

  // ── Turn processing (shared by both modes) ─────────────────────────────

  Future<void> _startTurn(Float32List samples) async {
    final gen = ++_generation; // any newer turn supersedes this one
    _phase = AssistantPhase.transcribing;
    _status = 'Thinking…';
    notifyListeners();
    try {
      final swAsr = Stopwatch()..start();
      final text = (await _worker!.transcribe(samples, 16000)).trim();
      swAsr.stop();
      if (gen != _generation) return; // superseded
      _asrSeconds = swAsr.elapsedMilliseconds / 1000.0;

      if (text.isEmpty) {
        _status = 'Didn\'t catch that — try again?';
        _phase = _mode == InteractionMode.pushToTalk
            ? AssistantPhase.idle
            : AssistantPhase.listening;
        notifyListeners();
        return;
      }
      if (_segEchoRisk && _looksLikeEcho(text, _lastSpoken)) {
        _segEchoRisk = false;
        _status = 'That was my own voice — I\'m listening.';
        _phase = AssistantPhase.listening;
        notifyListeners();
        return;
      }
      _segEchoRisk = false;
      _transcript = text;

      final swTts = Stopwatch()..start();
      final (audio, sampleRate) = await _worker!.synthesize(text);
      swTts.stop();
      if (gen != _generation) return; // user resumed during synthesis
      _ttsSeconds = swTts.elapsedMilliseconds / 1000.0;
      _playSeconds = audio.length / sampleRate;

      _lastSpoken = text;
      _phase = AssistantPhase.speaking;
      _status = 'Speaking: “$text” — jump in any time.';
      notifyListeners();
      await _playWav(audio, sampleRate, gen);
    } catch (e) {
      _fail('Round trip failed: $e');
    }
  }

  Future<void> _playWav(
    Float32List samples,
    int sampleRate,
    int gen,
  ) async {
    _stopPlayback(); // safety: never overlap replies
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, 'reply_${DateTime.now().millisecondsSinceEpoch}.wav'),
    );
    await file.writeAsBytes(encodeWav(samples, sampleRate));
    _playFile = file.path;
    _playerPlaying = true;
    _playSub = _player.onPlayerComplete.listen((_) {
      if (gen == _generation) _onPlaybackNaturalEnd();
    });
    try {
      await _player.play(DeviceFileSource(file.path));
    } catch (e) {
      _playSub?.cancel();
      _playSub = null;
      _playerPlaying = false;
      _cleanupPlayFile();
      rethrow;
    }
  }

  void _onPlaybackNaturalEnd() {
    if (!_playerPlaying) return;
    _playerPlaying = false;
    _cleanupPlayFile();
    // Any utterance the VAD formed from the tail of our own reply must not
    // leak into the next turn (the user talking over the reply keeps theirs).
    if (!_userSpeaking) _worker?.resetVad();
    if (_phase == AssistantPhase.speaking) {
      _phase = AssistantPhase.listening;
      _status = 'Listening — just talk.';
      notifyListeners();
    }
  }

  void _stopPlayback() {
    if (!_playerPlaying) return;
    _playerPlaying = false;
    unawaited(_player.stop());
    _cleanupPlayFile();
    if (!_userSpeaking) _worker?.resetVad();
  }

  void _cleanupPlayFile() {
    final f = _playFile;
    _playFile = null;
    unawaited(_playSub?.cancel() ?? Future.value());
    _playSub = null;
    if (f != null) {
      unawaited(File(f).delete().catchError((_) => File(f)));
    }
  }

  // ── Push-to-talk mode ────────────────────────────────────────────────────

  Future<void> _startListening() async {
    if (_phase == AssistantPhase.listening || _worker == null) return;
    try {
      _stopPlayback();
      await _openMicStream();
      _phase = AssistantPhase.listening;
      _error = '';
      _status = 'Listening… tap again to send.';
      notifyListeners();
    } catch (e) {
      _fail('$e');
    }
  }

  Future<void> _stopAndRespond() async {
    if (_phase != AssistantPhase.listening) return;
    _micWatchdog?.cancel();
    _micWatchdog = null;
    await _recSub?.cancel();
    _recSub = null;
    await _recorder.stop();
    _recordSeconds = 0;
    for (final c in _chunks) {
      _recordSeconds += c.length / 16000.0;
    }
    final total =
        _chunks.fold<int>(0, (n, c) => n + c.length);
    if (total < 16000 ~/ 4) {
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
    _chunks.clear();
    await _startTurn(pcm);
  }

  // ── Utilities ────────────────────────────────────────────────────────────

  void _shutdownAudio() {
    _micWatchdog?.cancel();
    _micWatchdog = null;
    _stopPlayback();
    unawaited(_recSub?.cancel() ?? Future.value());
    _recSub = null;
    unawaited(_recorder.stop());
    _worker?.resetVad();
    _chunks.clear();
    _vadBuf.clear();
  }

  /// Word-overlap test: did the mic just pick up our own TTS output?
  static bool _looksLikeEcho(String heard, String spoken) {
    Set<String> words(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toSet();
    final a = words(heard);
    final b = words(spoken);
    if (a.isEmpty || b.isEmpty) return false;
    final overlap = a.intersection(b).length;
    return overlap / (a.length < b.length ? a.length : b.length) >= 0.75;
  }

  @override
  void dispose() {
    _disposed = true;
    _shutdownAudio();
    _player.dispose();
    _recorder.dispose();
    _worker?.dispose();
    super.dispose();
  }
}
