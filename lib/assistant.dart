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
  Float32List? _asrAudio; // exact audio the last ASR call consumed
  int _asrAudioRate = 16000;
  bool _debugPlaying = false;
  Completer<void>? _debugCompleted;
  StreamSubscription<void>? _debugSub;
  String? _playAsrFile;
  bool _playerPlaying = false;
  bool _userSpeaking = false; // live VAD flag (conversation mode)
  bool _segEchoRisk = false; // current utterance started while we were talking
  bool _segGotAudio = false; // current utterance produced a VAD segment
  int _generation = 0; // cancels in-flight responses when bumped
  Timer? _micWatchdog;
  DateTime _lastMicAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _replyStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _micRecovering = false;
  bool _disposed = false;

  InteractionMode get mode => _mode;

  /// Exact audio the most recent ASR call consumed (VAD segment or gated PTT
  /// buffer) — what Whisper actually heard, for replay/diagnostics.
  Float32List? get asrAudio => _asrAudio;
  double get asrAudioSeconds =>
      _asrAudio == null ? 0 : _asrAudio!.length / _asrAudioRate;
  bool get debugPlaying => _debugPlaying;
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
      final modelsDir = await unpackModels(
        onProgress: (label, done, total) {
          _status = total > 0
              ? 'Downloading $label: '
                    '${(done / (1024 * 1024)).toStringAsFixed(1)} / '
                    '${(total / (1024 * 1024)).toStringAsFixed(1)} MB'
              : '$label…';
          notifyListeners();
        },
      );
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
    _conversationWasLive = false;
    _shutdownAudio();
    _generation++;
    _idleReady();
  }

  /// App went to background: tear the conversation down (the mic must not
  /// stay open invisibly), but remember that it was live so [resumeConversation]
  /// can bring it back. An in-flight reply is abandoned either way.
  void pauseConversation() {
    final live =
        _mode == InteractionMode.conversation &&
        (_phase == AssistantPhase.listening ||
            _phase == AssistantPhase.transcribing ||
            _phase == AssistantPhase.speaking);
    _conversationWasLive = live;
    _backgrounded = true;
    _generation++; // abandon any in-flight turn: no talking to an empty app
    _shutdownAudio();
    _phase = AssistantPhase.idle;
    _status = live
        ? 'Paused — I\'ll resume when you\'re back.'
        : _mode == InteractionMode.conversation
        ? 'Tap the mic to start a conversation. Pause about a second and I\'ll answer.'
        : 'Ready. Tap the mic, speak, tap again to send.';
    notifyListeners();
  }

  /// App came back to the foreground: reopen the conversation exactly as the
  /// user left it (VAD reseeded, watchdog rearmed — all inside
  /// [_beginConversation]).
  void resumeConversation() {
    _backgrounded = false;
    if (!_conversationWasLive) return;
    _conversationWasLive = false;
    unawaited(_beginConversation());
  }

  bool _conversationWasLive = false;
  bool _backgrounded = false;

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
  /// In conversation mode the mic must stay alive through our reply, both for
  /// barge-in and so capture recovers if Android kills it during playback.
  bool get _micStreamWanted =>
      _phase == AssistantPhase.listening ||
      (_mode == InteractionMode.conversation &&
          (_phase == AssistantPhase.transcribing ||
              _phase == AssistantPhase.speaking));

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
    _micWatchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_micRecovering || !_micStreamWanted) return;
      if (DateTime.now().difference(_lastMicAt) >
          const Duration(milliseconds: 1250)) {
        unawaited(_recoverMic('stalled'));
      }
    });
  }

  /// Reopen the mic after the OS ends, pauses or stalls the capture stream
  /// (common after our own playback: focus/mode/routing changes).
  Future<void> _recoverMic(String why) async {
    if (_micRecovering || !_micStreamWanted || _backgrounded) return;
    _micRecovering = true;
    debugPrint('mic stream $why — reopening');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (_disposed) return;
    try {
      await _openMicStream(); // also resets _lastMicAt and the watchdog
      // Don't seed a fresh VAD while the user is mid-utterance: their
      // in-progress segment lives in the VAD ring and stays valid.
      if (!_userSpeaking) _worker?.resetVad();
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
    if (_debugPlaying) return; // stream stays live for the watchdog only
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

  /// Replays the exact bytes ASR saw for the last turn (VAD segment or gated
  /// PTT buffer, post pre-roll/gating). Capture stays open but is muted while
  /// it plays, so nothing leaks back into the VAD. Tap again to stop.
  Future<void> playAsrAudio() async {
    if (_debugPlaying) {
      _stopDebugPlayback();
      return;
    }
    final audio = _asrAudio;
    if (audio == null || _debugPlaying) return;
    _debugPlaying = true;
    var failed = false;
    var finished = false;
    _stopPlayback();
    _status = 'Playing back what I heard…';
    notifyListeners();
    final done = _debugCompleted = Completer<void>();
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'asr_replay.wav'));
      await file.writeAsBytes(encodeWav(audio, _asrAudioRate));
      _playAsrFile = file.path;
      _debugSub = _player.onPlayerComplete.listen((_) {
        final d = _debugCompleted;
        if (d != null && !d.isCompleted) d.complete();
      });
      await _player.play(DeviceFileSource(file.path));
      await done.future.timeout(const Duration(seconds: 90), onTimeout: () {});
      finished = true;
    } catch (e) {
      failed = true;
      _fail('Debug playback failed: $e');
    } finally {
      _debugPlaying = false;
      await _debugSub?.cancel();
      _debugSub = null;
      _debugCompleted = null;
      final f = _playAsrFile;
      _playAsrFile = null;
      if (f != null) {
        unawaited(File(f).delete().catchError((_) => File(f)));
      }
      if (!_disposed && !failed) {
        if (!finished) {
          _status = _mode == InteractionMode.conversation
              ? 'Stopped.'
              : 'Stopped. Tap the mic to speak.';
        } else if (_mode == InteractionMode.conversation) {
          _phase = AssistantPhase.listening;
          _status = 'Listening — just talk.';
        } else {
          _phase = AssistantPhase.idle;
          _status = 'Ready. Tap the mic to speak.';
        }
        _worker?.resetVad();
        notifyListeners();
      }
    }
  }

  void _stopDebugPlayback() {
    if (!_debugPlaying) return;
    unawaited(_player.stop().catchError((_) {}));
    if (_debugCompleted != null && !_debugCompleted!.isCompleted) {
      _debugCompleted!.complete();
    }
  }

  // ── Conversation mode ────────────────────────────────────────────────────

  Future<void> _beginConversation() async {
    _stopDebugPlayback();
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
    _stopDebugPlayback();
    _stopPlayback();
    _worker?.resetVad();
    _phase = AssistantPhase.listening;
    _status = message;
    notifyListeners();
  }

  void _onSpeechEvent(SpeechEvent event) {
    if (event.note != null) {
      debugPrint('[worker] ${event.note}'); // gate telemetry (level/floor)
      return;
    }
    if (_debugPlaying) return; // don't let the replay re-enter the pipeline
    if (event.speechStarted) {
      // Barge-in: the SNR gate already forced this speech to sit well above
      // the echo/noise floor, so muting our reply here is safe.
      _segEchoRisk = _playerPlaying;
      _segGotAudio = false;
      if (_playerPlaying) {
        if (DateTime.now().difference(_replyStartedAt).inMilliseconds < 450) {
          // Too early to trust: AEC has not locked yet, so this "speech" may
          // be our own reply. Keep talking; the word-overlap echo guard still
          // discards the resulting text, and a genuine interruption a few
          // hundred ms later mutes us as usual.
          notifyListeners();
          return;
        }
        _userSpeaking = true; // set first: keeps _stopPlayback from resetting
        _stopPlayback();
        _generation++; // abandon the response we were speaking
        _status = 'Interrupted — go ahead.';
      } else if (_phase == AssistantPhase.transcribing) {
        _userSpeaking = true;
        _generation++; // user resumed; drop the half-baked response
      } else {
        _userSpeaking = true;
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
    // Speech stopped but no segment followed (too quiet/short to count as a
    // real try): nudge — unless that utterance was likely our own echo.
    _userSpeaking = false;
    if (!_segGotAudio && !_segEchoRisk && _phase == AssistantPhase.listening) {
      _status = 'I heard a bit — say a little more?';
      notifyListeners();
    }
    _segEchoRisk = false;
  }

  // ── Turn processing (shared by both modes) ─────────────────────────────

  Future<void> _startTurn(Float32List samples) async {
    final gen = ++_generation; // any newer turn supersedes this one
    _phase = AssistantPhase.transcribing;
    _status = 'Thinking…';
    notifyListeners();
    try {
      final swAsr = Stopwatch()..start();
      // What ASR actually heard — kept for the debug replay button.
      _asrAudio = samples;
      _asrAudioRate = 16000;
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

  Future<void> _playWav(Float32List samples, int sampleRate, int gen) async {
    _stopPlayback(); // safety: never overlap replies
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, 'reply_${DateTime.now().millisecondsSinceEpoch}.wav'),
    );
    await file.writeAsBytes(encodeWav(samples, sampleRate));
    _playFile = file.path;
    _playerPlaying = true;
    _replyStartedAt = DateTime.now();
    _worker?.setPlaying(true); // gate goes hard-mode while we hear ourselves
    _playSub = _player.onPlayerComplete.listen((_) {
      if (gen == _generation) _onPlaybackNaturalEnd();
    });
    try {
      await _player.play(DeviceFileSource(file.path));
    } catch (e) {
      _playSub?.cancel();
      _playSub = null;
      _playerPlaying = false;
      _worker?.setPlaying(false);
      _cleanupPlayFile();
      rethrow;
    }
  }

  void _onPlaybackNaturalEnd() {
    if (!_playerPlaying) return;
    _playerPlaying = false;
    _worker?.setPlaying(false); // gate relaxes; floor drops back to room
    _cleanupPlayFile();
    // Any utterance the VAD formed from the tail of our own reply must not
    // leak into the next turn (the user talking over the reply keeps theirs).
    if (!_userSpeaking) _worker?.resetVad();
    if (_phase == AssistantPhase.speaking) {
      _phase = AssistantPhase.listening;
      _status = 'Listening — just talk.';
      notifyListeners();
    }
    _fastMicCheck();
  }

  void _stopPlayback() {
    if (!_playerPlaying) return;
    _playerPlaying = false;
    _worker?.setPlaying(false);
    unawaited(_player.stop());
    _cleanupPlayFile();
    if (!_userSpeaking) _worker?.resetVad();
    _fastMicCheck();
  }

  /// If capture went silent during our reply (our playback is a common
  /// trigger for Android tearing it down), reopen right now instead of
  /// waiting for the next watchdog tick.
  void _fastMicCheck() {
    if (_micRecovering || !_micStreamWanted) return;
    if (DateTime.now().difference(_lastMicAt) >
        const Duration(milliseconds: 750)) {
      unawaited(_recoverMic('post-reply'));
    }
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
    _stopDebugPlayback();
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
    _stopDebugPlayback();
    _micWatchdog?.cancel();
    _micWatchdog = null;
    await _recSub?.cancel();
    _recSub = null;
    await _recorder.stop();
    _recordSeconds = 0;
    for (final c in _chunks) {
      _recordSeconds += c.length / 16000.0;
    }
    final total = _chunks.fold<int>(0, (n, c) => n + c.length);
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
    // Offline cleanup (high-pass + frame noise gate) using the live noise
    // floor — safe here: the user already finished speaking, so gating can
    // never clip utterance onsets, only quiet fill between words.
    _phase = AssistantPhase.transcribing;
    _status = 'Cleaning up the recording…';
    notifyListeners();
    Float32List cleaned = pcm;
    try {
      cleaned = await _worker!.denoise(pcm);
    } catch (e) {
      debugPrint('denoise failed, using raw audio: $e');
    }
    await _startTurn(cleaned);
  }

  // ── Utilities ────────────────────────────────────────────────────────────

  void _shutdownAudio() {
    _micWatchdog?.cancel();
    _micWatchdog = null;
    _stopDebugPlayback();
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
