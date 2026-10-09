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
import 'tts_voices.dart';

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

  // ── Voice selection & cloning ────────────────────────────────────────────
  String _modelsDir = '';
  TtsPrefs _prefs = TtsPrefs();
  String _activeVoiceId = 'lessac';
  int _ttsNumSpeakers = 1; // >1 when the loaded engine has several speakers
  String _voiceStatus = ''; // one-line feedback for the voice screen
  bool _voiceBusy = false; // download / engine swap / sample processing
  bool _cloneCapturing = false; // recording a clone sample right now
  bool _cloneResumeOnDone = false; // conversation to restore after capture
  double _cloneSeconds = 0;
  Timer? _cloneTimer;
  final List<Float32List> _cloneChunks = [];
  Completer<void>? _previewDone; // set while a preview line plays

  StreamSubscription<Uint8List>? _recSub;
  final List<Float32List> _chunks = []; // push-to-talk buffer
  final BytesBuilder _vadBuf = BytesBuilder(copy: false); // 512-sample aligner
  StreamSubscription<void>? _playSub;
  String? _playFile;
  Float32List? _asrAudio; // exact audio the last ASR call consumed
  int _asrAudioRate = 16000;
  Float32List? _lastTts; // exact audio the last synth produced (reply/preview)
  int _lastTtsRate = 16000;
  bool _debugPlaying = false;
  // ── Streamed reply playback: chunks synthesise while earlier ones play ──
  final List<(Float32List, int)> _replyQueue = [];
  bool _replyStreamDone = true; // no stream in flight until _startTurn
  Completer<void>? _replyWake; // pokes the player loop
  Completer<void>? _replyChunkDone; // resolves when the current chunk ends
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

  /// Exact audio the TTS engine last generated (reply or voice preview) —
  /// the raw engine output, before playback; for replay/diagnostics.
  Float32List? get lastTtsAudio => _lastTts;
  double get lastTtsSeconds =>
      _lastTts == null ? 0 : _lastTts!.length / _lastTtsRate;

  /// Keep the most recent synth output for [playTtsAudio].
  void _noteTts(Float32List audio, int rate) {
    _lastTts = audio;
    _lastTtsRate = rate;
  }

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

  // ── Voice selection API (see lib/voice_screen.dart) ─────────────────────
  List<TtsVoice> get voices => ttsVoices;
  String get modelsDir => _modelsDir;
  String get ttsVoiceId => _activeVoiceId;
  int get ttsSid => _prefs.sid;
  int get ttsNumSpeakers => _ttsNumSpeakers;
  String get voiceStatus => _voiceStatus;
  bool get voiceBusy => _voiceBusy;
  bool get cloneCapturing => _cloneCapturing;
  double get cloneSeconds => _cloneSeconds;
  String get cloneSampleText => _prefs.sampleText;
  bool get hasCloneSample =>
      _prefs.sampleWav.isNotEmpty && File(_prefs.sampleWav).existsSync();

  TtsSpec _spec(TtsVoice v, {int sid = 0}) => v.specIn(
    _modelsDir,
    sid: sid,
    referenceWav: _prefs.sampleWav,
    referenceText: _prefs.sampleText,
  );

  // ── Lifecycle ────────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      final modelsDir = await unpackModels(onProgress: _modelProgress);
      _modelsDir = modelsDir;
      _prefs = await loadTtsPrefs(modelsDir);
      // The saved voice must be fully on disk (pack present and, for the
      // clone, its reference wav too); otherwise fall back to the default,
      // which downloads on first run just like before.
      var voice = voiceById(_prefs.voiceId) ?? voiceById('lessac')!;
      if (!await voice.installedIn(modelsDir) ||
          (voice.isClone && !hasCloneSample)) {
        voice = voiceById('lessac')!;
      }
      _prefs.voiceId = voice.id;
      await voice.ensureIn(modelsDir, onProgress: _modelProgress);
      _worker = await SpeechWorker.start(
        ModelPaths.fromModelsDir(modelsDir),
        tts: _spec(voice, sid: _prefs.sid),
        onEvent: _onSpeechEvent,
        endpointSilence: _endpointSilence,
      );
      _activeVoiceId = voice.id;
      _idleReady();
    } catch (e) {
      _fail('Model init failed: $e');
    }
  }

  void _modelProgress(String label, int done, int total) {
    _status = total > 0
        ? 'Downloading $label: '
              '${(done / (1024 * 1024)).toStringAsFixed(1)} / '
              '${(total / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '$label…';
    notifyListeners();
  }

  // ── Voice selection & cloning ────────────────────────────────────────────

  /// Switch the speaking voice, downloading its pack first if needed
  /// (progress shows in [voiceStatus]). [sid] picks a speaker for models
  /// that have several; pass `force` to re-apply the current voice (e.g.
  /// after editing the clone transcript).
  Future<void> selectVoice(
    String id, {
    int sid = -1,
    bool force = false,
  }) async {
    if (_worker == null || _voiceBusy) return;
    final v = voiceById(id);
    if (v == null) return;
    final newSid = sid < 0 ? _prefs.sid : sid;
    if (!force && id == _activeVoiceId && newSid == _prefs.sid) return;
    if (v.isClone && !hasCloneSample) {
      _voiceStatus = 'Record a voice sample first (button below).';
      notifyListeners();
      return;
    }
    _voiceBusy = true;
    _voiceStatus = 'Setting up ${v.label}…';
    notifyListeners();
    try {
      await v.ensureIn(_modelsDir, onProgress: _voiceProgress);
      _ttsNumSpeakers = await _worker!.useTts(_spec(v, sid: newSid));
      _activeVoiceId = v.id;
      _prefs.voiceId = v.id;
      _prefs.sid = newSid;
      await saveTtsPrefs(_modelsDir, _prefs);
      _voiceStatus = '';
    } catch (e) {
      _voiceStatus = 'Could not switch voice: $e';
    } finally {
      _voiceBusy = false;
      notifyListeners();
    }
  }

  void _voiceProgress(String label, int done, int total) {
    _voiceStatus = total > 0
        ? 'Downloading $label: '
              '${(done / (1024 * 1024)).toStringAsFixed(1)} / '
              '${(total / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '$label…';
    notifyListeners();
  }

  /// Free the disk space of a voice's downloaded pack (the one in use and
  /// the built-in Lessac default stay protected).
  Future<void> deleteVoice(String id) async {
    final v = voiceById(id);
    if (v == null || _voiceBusy) return;
    if (id == _activeVoiceId) {
      _voiceStatus = 'Switch to another voice before deleting this one.';
      notifyListeners();
      return;
    }
    _voiceBusy = true;
    try {
      await v.deleteIn(_modelsDir);
      _voiceStatus = '';
    } finally {
      _voiceBusy = false;
      notifyListeners();
    }
  }

  /// Record the reference clip the clone will speak with: takes the mic from
  /// any running capture (auto-stops at 20 s). Finish with [stopCloneCapture]
  /// — the clip is saved and Whisper transcribes it (ZipVoice needs the text
  /// of the reference audio).
  Future<void> startCloneCapture() async {
    if (_worker == null || _cloneCapturing || _voiceBusy) return;
    _cloneResumeOnDone = _micStreamWanted; // conversation/PTT we displaced
    _generation++; // abandon any in-flight turn
    _shutdownAudio();
    _cloneChunks.clear();
    _cloneSeconds = 0;
    _cloneCapturing = true; // _onMicData routes bytes into the sample
    _phase = AssistantPhase.listening;
    _error = '';
    _status = 'Recording your voice sample…';
    _voiceStatus = 'Read one sentence clearly, about 8–15 seconds.';
    _cloneTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_cloneCapturing) return;
      _status =
          'Recording your voice sample… '
          '${_cloneSeconds.toStringAsFixed(1)}s (stop between 2 and 20 s)';
      notifyListeners();
    });
    notifyListeners();
    try {
      await _openMicStream(); // reuses the watchdog-protected capture path
    } catch (e) {
      _cloneCapturing = false;
      _cloneTimer?.cancel();
      _cloneTimer = null;
      _fail('Could not open the mic: $e');
    }
  }

  Future<void> stopCloneCapture() async {
    if (!_cloneCapturing) return;
    _cloneCapturing = false; // first: ignores trailing stream data
    _cloneTimer?.cancel();
    _cloneTimer = null;
    _micWatchdog?.cancel();
    _micWatchdog = null;
    await _recSub?.cancel();
    _recSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    _phase = AssistantPhase.idle;
    final total = _cloneChunks.fold<int>(0, (n, c) => n + c.length);
    _cloneSeconds = total / 16000.0;
    if (total < 32000) {
      // under 2 seconds: nothing worth cloning
      _cloneChunks.clear();
      _voiceStatus = 'That was too short — record at least 2 seconds.';
      notifyListeners();
      _afterCapture();
      return;
    }
    _voiceBusy = true;
    _status = 'Saving your voice sample…';
    notifyListeners();
    try {
      final pcm = Float32List(total);
      var off = 0;
      for (final c in _cloneChunks) {
        pcm.setRange(off, off + c.length, c);
        off += c.length;
      }
      _cloneChunks.clear();
      final wavPath = p.join(_modelsDir, 'clone_reference.wav');
      await File(wavPath).writeAsBytes(encodeWav(pcm, 16000));
      _status = 'Transcribing the sample…';
      notifyListeners();
      final text = (await _worker!.transcribe(pcm, 16000)).trim();
      if (text.split(' ').length < 3) {
        throw StateError(
          'I could not understand the sample — speak a bit louder and '
          'try again.',
        );
      }
      _prefs.sampleWav = wavPath;
      _prefs.sampleText = text;
      await saveTtsPrefs(_modelsDir, _prefs);
      _voiceStatus =
          'Sample saved (${_cloneSeconds.toStringAsFixed(1)}s). Press '
          '"Use my voice" to download the cloning model (about 155 MB, '
          'one time) and hear it speak.';
      _status = 'Voice sample saved.';
    } catch (e) {
      _cloneChunks.clear();
      _voiceStatus = 'Clone failed: $e';
      _status = 'Voice sample failed — tap the voices screen to retry.';
    } finally {
      _voiceBusy = false;
      notifyListeners();
    }
    _afterCapture();
  }

  Future<void> cancelCloneCapture() async {
    if (!_cloneCapturing) return;
    _cloneCapturing = false;
    _cloneTimer?.cancel();
    _cloneTimer = null;
    _cloneChunks.clear();
    _shutdownAudio();
    _phase = AssistantPhase.idle;
    _status = 'Sample recording cancelled.';
    notifyListeners();
    _afterCapture();
  }

  /// Correct what Whisper heard in the reference clip (ZipVoice speaks the
  /// reference *transcript*, so a mis-heard word colors the clone).
  Future<void> updateCloneSampleText(String text) async {
    if (_voiceBusy) return;
    _prefs.sampleText = text.trim();
    await saveTtsPrefs(_modelsDir, _prefs);
    if (_activeVoiceId == 'clone') {
      await selectVoice('clone', force: true); // reload the reference
    }
    notifyListeners();
  }

  Future<void> deleteCloneSample() async {
    if (_voiceBusy) return;
    _voiceBusy = true;
    try {
      await File(_prefs.sampleWav).delete();
    } catch (_) {}
    _prefs.sampleWav = '';
    _prefs.sampleText = '';
    _voiceBusy = false;
    _voiceStatus = 'Voice recording deleted.';
    if (_activeVoiceId == 'clone') {
      _activeVoiceId = ''; // force the switch past the same-voice guard
      await selectVoice('lessac', force: true);
    }
    await saveTtsPrefs(_modelsDir, _prefs);
    notifyListeners();
  }

  /// Synthesize + play a demo line with the *current* engine (no phase
  /// changes; the gate is pinned so a hot mic cannot hear it as speech).
  Future<void> previewVoice({
    String text = 'Hi! This is how your assistant will sound with this voice.',
  }) async {
    if (_worker == null || _voiceBusy) return;
    _voiceBusy = true;
    _voiceStatus = 'Making the preview…';
    _stopDebugPlayback();
    _stopPlayback(); // a live reply would fight the preview for the speaker
    notifyListeners();
    try {
      _worker!.setPlaying(true); // hard-mode gate while we hear ourselves
      _status = '';
      notifyListeners();
      final (audio, sampleRate) = await _worker!.synthesize(text);
      _noteTts(audio, sampleRate); // voice preview counts as TTS output too
      _voiceStatus = '';
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'voice_preview.wav'));
      await file.writeAsBytes(encodeWav(audio, sampleRate));
      // Treat it like a reply for stop/barge-in bookkeeping (but keep the
      // phase — the screen's buttons must not change while it plays).
      _playerPlaying = true;
      final done = _previewDone = Completer<void>();
      final sub = _player.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
      });
      try {
        await _player.play(DeviceFileSource(file.path));
        await done.future.timeout(
          const Duration(seconds: 120),
          onTimeout: () {},
        );
      } finally {
        await sub.cancel();
        _previewDone = null;
        unawaited(file.delete().catchError((_) => file));
      }
    } catch (e) {
      _voiceStatus = 'Preview failed: $e';
    } finally {
      _playerPlaying = false;
      _worker?.setPlaying(false);
      _voiceBusy = false;
      notifyListeners();
    }
  }

  void _afterCapture() {
    final resume = _cloneResumeOnDone;
    _cloneResumeOnDone = false;
    if (resume && _mode == InteractionMode.conversation && !_backgrounded) {
      unawaited(_beginConversation());
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
    // A clone sample in flight dies with the app going hidden (the mic is
    // yanked); remember whether a conversation waited behind it.
    var live =
        _mode == InteractionMode.conversation &&
        (_phase == AssistantPhase.listening ||
            _phase == AssistantPhase.transcribing ||
            _phase == AssistantPhase.speaking);
    final cloneDropped = _cloneCapturing;
    if (_cloneCapturing) {
      live = _cloneResumeOnDone; // listening phase belongs to the capture
      _cloneCapturing = false;
      _cloneTimer?.cancel();
      _cloneTimer = null;
      _cloneChunks.clear();
    }
    _cloneResumeOnDone = false;
    _conversationWasLive = live;
    _backgrounded = true;
    _generation++; // abandon any in-flight turn: no talking to an empty app
    _shutdownAudio();
    _phase = AssistantPhase.idle;
    _status = cloneDropped
        ? 'Voice sample cancelled — the app went to the background.'
        : live
        ? 'Paused — I\'ll resume when you\'re back.'
        : _mode == InteractionMode.conversation
        ? 'Tap the mic to start a conversation. Pause about a second and I\'ll answer.'
        : 'Ready. Hold the button, speak, release to send.';
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

  // ── Push-to-talk hold wiring (mic lives ONLY while the button is held) ──
  // Raw pointer edges from a Listener around the button: unlike a gesture
  // recognizer these never contest (or lose to) the button's own tap, and
  // the pointer stays bound to this path from down to up, so releasing a
  // few centimetres off the button still closes the mic.

  int _pttPointers = 0; // one hold; extra fingers are ignored
  Timer? _pttMaxTimer; // a lost release must not latch the mic on
  /// Debug counters (shown under the button in debug mode): press/release
  /// edges observed — proves on-device whether holds reach the Listener.
  int pttEdgeCount = 0;

  void pttDown() {
    pttEdgeCount++;
    debugPrint(
      'PTT-DOWN mode=${_mode.name} phase=${_phase.name} '
      'worker=${_worker != null} ptr=$_pttPointers',
    );
    if (_mode != InteractionMode.pushToTalk || _worker == null) return;
    if (_phase == AssistantPhase.transcribing ||
        _phase == AssistantPhase.speaking) {
      return; // 'One moment…': the button is disabled right now anyway
    }
    _pttPointers++;
    if (_pttPointers > 1) return;
    // Android can renumber pointers mid-sequence (index reassignment when a
    // second finger lifts) and may drop the matching release; rather than
    // record forever, close the mic ourselves after a generous cap.
    _pttMaxTimer?.cancel();
    _pttMaxTimer = Timer(const Duration(minutes: 2), () {
      if (_pttPointers > 0) pttCancel();
    });
    unawaited(_startListening());
  }

  void pttUp() {
    pttEdgeCount++;
    debugPrint('PTT-UP ptr=$_pttPointers');
    if (_pttPointers == 0) return;
    _pttPointers--;
    if (_pttPointers > 0) return; // still holding with another finger
    _pttMaxTimer?.cancel();
    _pttMaxTimer = null;
    unawaited(_stopAndRespond());
  }

  void pttCancel() {
    // Back gesture / system interruption: behave exactly like a release,
    // so the mic can never be left open.
    _pttPointers = 0;
    _pttMaxTimer?.cancel();
    _pttMaxTimer = null;
    unawaited(_stopAndRespond());
  }

  void _idleReady() {
    if (_worker == null) return;
    _phase = AssistantPhase.idle;
    _status = _mode == InteractionMode.conversation
        ? 'Tap the mic to start a conversation. Pause about a second and I\'ll answer.'
        : 'Ready. Hold the button, speak, release to send.';
    notifyListeners();
  }

  void _fail(String message) {
    _phase = AssistantPhase.error;
    _error = message;
    _status = _mode == InteractionMode.conversation
        ? 'Error. Tap the mic to retry.'
        : 'Error. Hold the button to retry.';
    notifyListeners();
  }

  // ── Microphone plumbing (shared by both modes) ─────────────────────────

  /// Whether a live mic stream is expected right now (drives the watchdog).
  /// In conversation mode the mic must stay alive through our reply, both for
  /// barge-in and so capture recovers if Android kills it during playback.
  /// Clone-sample capture counts too (same stream, different sink).
  bool get _micStreamWanted =>
      _cloneCapturing ||
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
      // Reopening the capture mid-reply is an AEC re-lock event: the fresh
      // stream leaks speaker echo hard for a few hundred ms, and streamed
      // replies make this common (Android stalls capture across the media
      // hand-off of every chunk seam). Without the re-arm, the leak rides
      // the +20 dB playback bar and our own reply interrupts itself.
      if (_playerPlaying || _replyQueue.isNotEmpty || !_replyStreamDone) {
        _worker?.setPlaying(true);
      }
      // Don't seed a fresh VAD while the user is mid-utterance: their
      // in-progress segment lives in the VAD ring and stays valid.
      if (!_userSpeaking) _worker?.resetVad();
      if (_phase == AssistantPhase.listening) {
        _status = _mode == InteractionMode.conversation
            ? 'Listening — just talk.'
            : 'Listening… release to send.';
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
    if (_cloneCapturing) {
      // Voice-sample recorder: buffer instead of feeding VAD/PTT chunks.
      final c = pcm16ToFloat32(bytes);
      _cloneChunks.add(c);
      _cloneSeconds += c.length / 16000.0;
      if (_cloneSeconds >= 20) unawaited(stopCloneCapture()); // hard cap
      return;
    }
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
  Future<void> playAsrAudio() => _playDebugWav(
    _asrAudio,
    _asrAudioRate,
    'asr_replay.wav',
    'Playing back what I heard…',
  );

  /// Replays the raw bytes the TTS engine generated for the last reply (or
  /// voice preview) — engine artifacts become tellable apart from playback
  /// and automatic-gain effects. Tap again to stop.
  Future<void> playTtsAudio() => _playDebugWav(
    _lastTts,
    _lastTtsRate,
    'tts_replay.wav',
    'Replaying my last reply…',
  );

  Future<void> _playDebugWav(
    Float32List? audio,
    int rate,
    String fileName,
    String playingStatus,
  ) async {
    if (_debugPlaying) {
      _stopDebugPlayback();
      return;
    }
    if (audio == null) return;
    _debugPlaying = true;
    var failed = false;
    var finished = false;
    _stopPlayback();
    _status = playingStatus;
    notifyListeners();
    final done = _debugCompleted = Completer<void>();
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(encodeWav(audio, rate));
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
              : 'Stopped. Hold the button to speak.';
        } else if (_mode == InteractionMode.conversation) {
          _phase = AssistantPhase.listening;
          _status = 'Listening — just talk.';
        } else {
          _phase = AssistantPhase.idle;
          _status = 'Ready. Hold the button to speak.';
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
      _lastSpoken = text;

      // Streamed reply: the worker renders sentence chunks and we play
      // each one the moment it lands, so the reply STARTS speaking while
      // later sentences are still synthesising (and no VITS pass can run
      // long enough to hit its length cap). The status still quotes the
      // whole reply — the text is final, only the audio streams.
      final swTts = Stopwatch()..start();
      _replyQueue.clear();
      _replyStreamDone = false;
      var sawFirstChunk = false;
      unawaited(
        _worker!
            .synthesizeStream(
              text,
              onChunk: (chunk, sampleRate) {
                if (gen != _generation) return; // superseded: drop on the floor
                if (!sawFirstChunk) {
                  sawFirstChunk = true;
                  _phase = AssistantPhase.speaking;
                  _status = 'Speaking: “$text” — jump in any time.';
                  notifyListeners();
                }
                _replyQueue.add((chunk, sampleRate));
                _replyWake?.complete();
                _replyWake = null;
              },
            )
            .then((result) {
              swTts.stop();
              _noteTts(result.$1, result.$2); // full audio: debug replay
              if (gen != _generation) return;
              _ttsSeconds = swTts.elapsedMilliseconds / 1000.0;
              _playSeconds = result.$1.length / result.$2;
              _replyStreamDone = true;
              _replyWake?.complete();
              _replyWake = null;
            })
            .catchError((Object e) {
              _replyStreamDone = true;
              _replyWake?.complete();
              _replyWake = null;
              if (gen == _generation) _fail('Round trip failed: $e');
            }),
      );
      await _playReplyChunks(gen);
    } catch (e) {
      _fail('Round trip failed: $e');
    }
  }

  /// Plays streamed reply chunks in order as they arrive. Sequential
  /// playback leaves audio-identical boundaries (the worker appends a short
  /// silence to every non-final chunk), while the player being momentarily
  /// idle between chunks never loosens the gate: [_playerPlaying] stays set
  /// for the whole stream, so barge-in treats mid-synthesis gaps exactly
  /// like a held reply.
  Future<void> _playReplyChunks(int gen) async {
    var firstChunk = true;
    while (true) {
      while (_replyQueue.isEmpty && !_replyStreamDone) {
        await (_replyWake ??= Completer<void>()).future;
      }
      if (gen != _generation) {
        _replyQueue.clear();
        return;
      }
      if (_replyQueue.isEmpty) break; // stream drained and closed
      final (chunk, sampleRate) = _replyQueue.removeAt(0);
      firstChunk = false;
      _replyChunkDone = Completer<void>();
      await _playWav(
        chunk,
        sampleRate,
        gen,
        onComplete: () {
          if (!_replyChunkDone!.isCompleted) _replyChunkDone!.complete();
        },
      );
      if (gen != _generation) return; // user resumed: drop the rest
      await _replyChunkDone!.future; // ends on natural end... or a stop
      if (!_playerPlaying) return; // barge-in won: _stopPlayback cleaned up
    }
    if (firstChunk) return; // engine produced nothing (error path covers)
    _onPlaybackNaturalEnd();
  }

  Future<void> _playWav(
    Float32List samples,
    int sampleRate,
    int gen, {
    void Function()? onComplete,
  }) async {
    if (onComplete == null) _stopPlayback(); // one-shot mode safety
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, 'reply_${DateTime.now().millisecondsSinceEpoch}.wav'),
    );
    await file.writeAsBytes(encodeWav(samples, sampleRate));
    _playFile = file.path;
    _playerPlaying = true;
    // _replyStartedAt marks only the FIRST chunk: the 450 ms AEC guard must
    // not re-arm per chunk (a chunk boundary would otherwise re-open the
    // "too early to trust an interruption" window every few seconds).
    if (_phase != AssistantPhase.speaking ||
        DateTime.now().difference(_replyStartedAt).inMilliseconds > 2000) {
      _replyStartedAt = DateTime.now();
    }
    _worker?.setPlaying(true); // gate goes hard-mode while we hear ourselves
    await _playSub?.cancel();
    _playSub = _player.onPlayerComplete.listen((_) {
      if (onComplete != null) {
        onComplete(); // streamed mode: _playReplyChunks decides on end
      } else if (gen == _generation) {
        _onPlaybackNaturalEnd();
      }
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
    _replyQueue.clear(); // streamed reply: drop everything not yet audible
    final cd = _replyChunkDone;
    _replyChunkDone = null;
    if (cd != null && !cd.isCompleted) cd.complete(); // unblock the loop
    unawaited(_player.stop());
    // Stop, not natural end: release any preview waiter right away.
    final d = _previewDone;
    if (d != null && !d.isCompleted) d.complete();
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
      _status = 'Listening… release to send.';
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
      _status = 'Heard nothing. Hold the button and speak.';
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
    _cloneTimer?.cancel();
    _cloneTimer = null;
    if (_cloneCapturing) {
      // Something else took the mic away mid-capture (conversation closed,
      // mode switch, error path): the partial sample is worthless.
      _cloneCapturing = false;
      _cloneChunks.clear();
      _voiceStatus = 'Sample recording cancelled — the mic was closed.';
    }
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
