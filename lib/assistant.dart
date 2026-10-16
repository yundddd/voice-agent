import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset; // PTT release-gesture geometry (Listener positions)

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'audio_io.dart';
import 'bridge.dart';
import 'chat_log.dart';
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

/// One measured round trip of the latency bench (voice screen panel):
/// push-to-talk in, transcript out, transcript echoed by the *current* TTS
/// engine — bridge and LLM deliberately skipped so every number belongs to
/// the models the user picked. All latencies key off the button *release*:
/// [asrMs] is release→text ready, [firstAudioMs] is release→the moment the
/// player got its first chunk (the round-trip figure worth optimising),
/// [synthTotalMs] covers the whole utterance and yields [rtf].
class BenchRun {
  final String voice;
  final double recordedSeconds;
  final String heard;
  final int asrMs;
  final int firstAudioMs;
  final int synthTotalMs;
  final double audioSeconds;
  final double rtf;
  const BenchRun({
    required this.voice,
    required this.recordedSeconds,
    required this.heard,
    required this.asrMs,
    required this.firstAudioMs,
    required this.synthTotalMs,
    required this.audioSeconds,
    required this.rtf,
  });
}

/// Emoji stamp for a tool-call line in the conversation (silent lines, no
/// voice): the glyph reads the kind of work at a glance, before the name.
const Map<String, String> _toolGlyphs = {
  'read': '📖',
  'bash': '📓',
  'write': '✏️',
  'edit': '✏️',
  'multiedit': '✏️',
  'notebookedit': '🗒️',
  'grep': '🔍',
  'glob': '🔍',
  'webfetch': '🌐',
  'websearch': '🌐',
  'task': '🤖',
  'todowrite': '📋',
  'skill': '🪄',
};

String _toolGlyph(String toolName) =>
    _toolGlyphs[toolName.toLowerCase()] ?? '🔧';

/// Orchestrates the voice round trip:
///   mic -> VAD endpointing -> Whisper (ASR) -> text -> Piper VITS (TTS) -> speaker
/// in two interaction modes (see [InteractionMode]).
class VoiceAssistant extends ChangeNotifier {
  VoiceAssistant() {
    _recorder = AudioRecorder();
    // One-shot plays (preview, debug replay) end through this hook. A
    // streamed reply must NOT: at every sentence seam it would clear
    // _playerPlaying and cancel the chunk listener, so _playReplyChunks
    // bailed at the first seam and the rest of the answer appeared as
    // text with no audio (the per-chunk listener owns streamed ends, and
    // the loop calls _onPlaybackNaturalEnd itself once drained).
    _player.onPlayerComplete.listen((_) {
      if (_replyChunkDone == null) _onPlaybackNaturalEnd();
    });
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
  // The conversation, persisted (chat_log.json in the models dir): each
  // heard/spoken-for turn is a user bubble, each harness turn an
  // assistant bubble holding one block per spoken `say` section. This is
  // the on-screen history the reply card used to be — it no longer
  // disappears when the next turn starts; it accumulates like chat.
  final List<ChatEntry> _chat = <ChatEntry>[];
  int _chatVersion = 0; // bumped on every mutation: drives auto-scroll
  double _recordSeconds = 0;
  double _asrSeconds = 0;
  double _ttsSeconds = 0;
  double _playSeconds = 0;

  // ── Voice selection & cloning ────────────────────────────────────────────
  String _modelsDir = '';
  TtsPrefs _prefs = TtsPrefs();
  String _activeVoiceId = 'kokoro';
  int _ttsNumSpeakers = 1; // >1 when the loaded engine has several speakers
  String _voiceStatus = ''; // one-line feedback for the voice screen
  bool _voiceBusy = false; // download / engine swap in progress

  // ── Latency bench (voice screen panel) ─────────────────────────────────
  // Push-to-talk -> whisper -> echo in the CURRENT voice: a mic capture
  // whose reply path is a pure local echo (no bridge, no chat log), so
  // every millisecond the panel shows belongs to the models the user
  // picked. All latencies clock from the button release. History is
  // session-only — it is for feeling out voices back to back, not a record.
  bool _benchCapturing = false, _benchBusy = false;
  final List<Float32List> _benchChunks = [];
  Timer? _benchTimer;
  double _benchSeconds = 0;
  Stopwatch? _benchT0; // release→now, read by the player for [firstAudioMs]
  int _benchFirstAudioMs = 0; // stamped the instant the echo's play() is issued
  String _benchNote =
      'Hold the button, speak, release: the app transcribes you and '
      'repeats the sentence in the selected voice, timed end to end.';
  final List<BenchRun> _benchRuns = [];
  bool _captureResumeOnDone = false; // conversation to restore after capture
  Completer<void>? _previewDone; // set while a preview line plays

  // ── Claude Code bridge (lib/bridge.dart, docs/claude-code-bridge.md) ────
  BridgePrefs _bridgePrefs = BridgePrefs();
  BridgeClient? _bridge;
  bool _bridgeBusy = false; // a bridge turn is in flight (chips disabled)
  bool _harnessBackgrounded = false; // a turn the phone detached keeps
  // working on the bridge with no ear on it: the terminal badge stays lit
  // until a heard turn starts, /stop lands, or /new resets it.
  DateTime? _harnessSince; // wall clock the in-flight bridge turn started
  int _bridgeTurnSeq = 0; // busy-flag ownership token (turns bump it)
  StreamSubscription<BridgeEvent>?
  _bridgeSub; // live /talk listener — cancelled to DETACH
  void Function()? _bridgeDetachWake; // wakes the turn loop when detached

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
  // Screenshot-able event ring for barge-in/edge forensics: every worker
  // diagnostic note that matters (barge-in candidates), chunk seams, and mic
  // lifecycle, newest last. See the debug view.
  final List<String> _debugLog = [];
  List<String> get debugLog => _debugLog;
  bool _micRecoverPending = false;
  void _logDebug(String what) {
    final t = DateTime.now();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    _debugLog.add('$hh:$mm:$ss $what');
    while (_debugLog.length > 80) {
      _debugLog.removeAt(0);
    }
    notifyListeners();
  }

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

  /// The conversation log, oldest first (user / assistant bubbles).
  List<ChatEntry> get chat => _chat;

  /// Changes on every chat mutation — the UI keys its auto-scroll on it.
  int get chatVersion => _chatVersion;

  static const _chatCap = 80; // entries kept on screen and on disk
  void _addUserChat(String text) {
    _chat.add(ChatEntry.user(text));
    _touchChat();
  }

  void _touchChat() {
    while (_chat.length > _chatCap) {
      _chat.removeAt(0);
    }
    _chatVersion++;
    unawaited(_saveChat());
    notifyListeners();
  }

  /// A bridge turn whose assistant bubble stayed empty (error, or "ran
  /// with nothing to say"): take the blank bubble back out of the log.
  void _removeEmptyTurn(ChatEntry turn) {
    if (_chat.remove(turn)) {
      _chatVersion++;
      unawaited(_saveChat());
    }
  }

  String get _chatPath => p.join(_modelsDir, 'chat_log.json');

  Future<void> _saveChat() async {
    if (_modelsDir.isEmpty) return;
    try {
      await File(_chatPath).writeAsString(encodeChatLog(_chat));
    } catch (_) {} // chat history must never break a conversation
  }

  void _loadChat() {
    try {
      _chat
        ..clear()
        ..addAll(decodeChatLog(File(_chatPath).readAsStringSync()));
      _chatVersion++;
    } catch (_) {} // first run (or unreadable): fresh log
  }

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

  // ── Claude Code bridge API (settings UI in bridge_screen.dart) ─────────
  bool get bridgeConfigured => _bridge != null;
  bool get bridgeBusy => _bridgeBusy;

  /// How long the in-flight bridge turn has been working (zero when idle):
  /// the elapsed readout on the chat window's Claude Code-style spinner.
  Duration get harnessElapsed => _harnessSince == null
      ? Duration.zero
      : DateTime.now().difference(_harnessSince!);
  bool get bridgeVoice => _bridgePrefs.voice;
  String get bridgeUrlText => _bridgePrefs.url;
  String get bridgeTokenText => _bridgePrefs.token;

  bool get bridgeNarrate => _bridgePrefs.narrate;

  /// The harness conversation's fingerprint (GET /health sessionId), kept
  /// current for the chat screen's top row: refreshed at boot and at the
  /// end of every bridge turn (the /new chips and /stop path included —
  /// all of them run through runQuickCommand's finally, which re-reads
  /// /health after the bridge's result event has persisted the pointer,
  /// so the app can never see the file before the server wrote it). The
  /// id only moves when /new drops it or a death-resume forks it — an
  /// id that never moves across dozens of talks IS the continuity proof.
  String? _sessionId;
  String? get sessionId => _sessionId;

  // Context consumption for the bar above the talk button: fed by
  // `context` events mid-turn/at turn end and by every /health read
  // (_refreshSession runs at startup, after setBridge, and in
  // runQuickCommand's finally — so the bar survives app restarts and
  // detached turns alike). Window 0 = no `result` has named one yet.
  int _contextIn = 0;
  int _contextWindow = 0;
  int get contextIn => _contextIn;
  int get contextWindow => _contextWindow;

  /// 0..1 fill for the context bar; 0 when the window is still unknown.
  double get contextFrac => _contextWindow > 0
      ? (_contextIn / _contextWindow).clamp(0.0, 1.0)
      : 0;

  void _mergeContext(int tokens, int window) {
    var changed = false;
    if (tokens > 0 && tokens != _contextIn) {
      _contextIn = tokens;
      changed = true;
    }
    if (window > 0 && window != _contextWindow) {
      _contextWindow = window;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> _refreshSession() async {
    final h = await _bridge?.healthInfo();
    final sid = h?['sessionId'];
    final s = (sid is String && sid.isNotEmpty) ? sid : null;
    if (s != _sessionId) {
      _sessionId = s;
      notifyListeners();
    }
    final ctx = h?['context'];
    if (ctx is Map) {
      final i = ctx['in'], w = ctx['window'];
      _mergeContext(i is num ? i.toInt() : 0, w is num ? w.toInt() : 0);
    }
  }

  // ── Live token ticker (spinner line: 'thinking · 1.2k out · 21k in') ──
  // The bridge relays its tally every ~0.8 s of active generation (plus
  // an exact-settling frame whenever a message closes). Between relays
  // this side keeps the number GROWING locally: _tokRate is a
  // tokens-per-second average learned from the app's OWN consecutive
  // relays (EMA, clamped to a believable band), so the eye sees a
  // counting ticker, not a 2-second-lagging step function. The local
  // growth is a display estimate only — the next relay always replaces
  // it with the bridge's authoritative number (which can even snap the
  // readout down when an estimate was over the exact count, exactly as
  // the CLI's own counter does when usage deltas land).
  int _tokOut = 0; // last bridge-sent output figure (est or exact)
  int _tokIn = 0; // context tokens from the same frame
  String _tokKind = ''; // 'thinking' | 'answering' | 'calling X' | ''
  DateTime? _tokAt; // when the last tally frame landed
  double _tokRate = 0; // learned tok/s (0 = nothing learned yet)
  bool _tokLive = false; // ticking ONLY between a `tokens` frame and a
  // competing tool/say event (a running Bash freezes the counter —
  // nothing is generating) or a turn start (a frozen counter riding
  // into the next turn would be a lie).

  bool get tokenTickerOn =>
      _tokLive && _tokAt != null && (_tokOut > 0 || _tokIn > 0);

  /// The growing label. Only meaningful while [tokenTickerOn]; the
  /// spinner asks the assistant for it on every one of its 120 ms
  /// ticks, which is what makes the number move between relays.
  String get tokenTickerLabel {
    final age =
        DateTime.now().difference(_tokAt!).inMilliseconds / 1000.0;
    // A stalled stream (frames stopped coming but nothing said 'tool
    // running' either) must not inflate the estimate forever: growth
    // freezes past a few relay periods of silence.
    final est = _tokOut + (_tokRate * (age > 5 ? 5 : age)).round();
    final kind = _tokKind.isEmpty ? '' : '$_tokKind · ';
    return '$kind${fmtTokenCount(est)} out · ${fmtTokenCount(_tokIn)} in';
  }

  void _onTokensFrame(BridgeEvent ev) {
    final now = DateTime.now();
    final out = ev.outTokens;
    if (out > 0) {
      final dt = _tokAt == null
          ? null
          : now.difference(_tokAt!).inMilliseconds / 1000.0;
      // Only a real step UP while already ticking can teach the rate:
      // the first frame of a turn and down-settling corrections carry
      // no elapsed-generation information (the gap includes tool runs).
      if (_tokLive && dt != null && dt > 0.15 && out > _tokOut) {
        final inst = (out - _tokOut) / dt;
        // ~3 relays to settle toward a step change; believable-speed
        // clamp (fast streaming rarely passes ~300 tok/s, and the
        // floor keeps a flat relay from freezing the ticker).
        _tokRate = _tokRate <= 0 ? inst : _tokRate * 0.6 + inst * 0.4;
        _tokRate = _tokRate.clamp(5.0, 800.0);
      }
      _tokOut = out;
    }
    if (ev.inputTokens > 0) _tokIn = ev.inputTokens;
    _tokKind = ev.toolKind;
    _tokAt = now;
    _tokLive = true;
    // The stepped label also feeds the plain status strip (everything
    // that is not the live bubble's spinner).
    _status = ev.detail;
    notifyListeners();
  }

  /// 'Speak to Claude Code' switch: when on, PTT/conversation utterances
  /// go to the harness instead of being repeated back.
  Future<void> setBridgeVoice(bool on) async {
    _bridgePrefs.voice = on;
    await saveBridgePrefs(_modelsDir, _bridgePrefs);
    notifyListeners();
  }

  /// 'Narrate progress' switch: on, every `tool` event of a harness turn
  /// is spoken as it arrives and long silent steps repeat their line as
  /// a heartbeat (see BridgePrefs.narrate — the event loop in
  /// [runQuickCommand] reads the pref live, so a mid-turn flip applies to
  /// the very next step). Off: silent status text, the answer arrives
  /// when it's ready.
  Future<void> setBridgeNarrate(bool on) async {
    _bridgePrefs.narrate = on;
    await saveBridgePrefs(_modelsDir, _bridgePrefs);
    notifyListeners();
  }

  /// Session-housekeeping chips on the main screen. They replace the old
  /// canned-command set (which asked the harness to do things it does
  /// better when simply told): these two buttons manage the CONVERSATION
  /// itself. See [bridgeControl] for what each one does on the wire.
  static const controlChips = <String>['/new', '/compact'];

  /// Saves bridge settings (empty url disables the feature entirely).
  Future<void> setBridge({required String url, required String token}) async {
    _bridgePrefs
      ..url = url.trim().replaceAll(RegExp(r'/+$'), '')
      ..token = token.trim();
    _rebuildBridge();
    _sessionId = null; // the old bridge's pointer is not this bridge's
    unawaited(_refreshSession());
    await saveBridgePrefs(_modelsDir, _bridgePrefs);
    notifyListeners();
  }

  void _rebuildBridge() {
    _bridge = _bridgePrefs.configured
        ? BridgeClient(_bridgePrefs.url, _bridgePrefs.token)
        : null;
  }

  /// Probes /health for the settings screen: null = alive and healthy.
  Future<String?> bridgeCheck() async =>
      _bridge?.health() ?? 'bridge not configured — set url and token';

  /// The bridge's raw /health payload (sessionId, claudeUp, turnOpen…) for
  /// the Bridge screen's session row; null when unreachable or unconfigured.
  /// One session serves every utterance (see claude_bridge.mjs: the id is
  /// persisted and --resume'd across restarts), so this is the fingerprint
  /// that proves two talks shared a brain — or, once it changes, that
  /// /new or a respawn fork moved the conversation onto a new one.
  Future<Map<String, Object>?> bridgeHealth() async =>
      await _bridge?.healthInfo();

  /// Runs one harness turn: utterance -> /talk (or a caller-supplied
  /// event source) -> speak each `say` event the moment it lands,
  /// streamed through the same chunked player voice replies use. Tool
  /// activity shows up as live status text instead of dead air.
  /// [bubble] is the short text to show as the user message (chip label /
  /// typed text); the voice path passes none because _startTurn already
  /// logged the heard utterance. [ack] is spoken when the turn produced
  /// no speech at all (silent-success controls like /compact, whose
  /// compaction signal is a system event the harness never narrates).
  /// [events] replaces the /talk call — the /new chip uses it to hit
  /// the bridge's reset endpoint and finish with zero events instead.
  /// [interrupt] is the queue flavour if the bridge turns this into a
  /// queued prompt behind a still-running turn: true (default) interrupts a
  /// mere thinking turn in-band (the process survives) so this one starts
  /// at once; false lets the turn
  /// in flight finish first (the push-to-talk slide-right polite queue).
  Future<void> runQuickCommand(
    String utterance, {
    String? bubble,
    String? ack,
    String? status,
    bool interrupt = true,
    Stream<BridgeEvent> Function()? events,
  }) async {
    final bridge = _bridge;
    if (bridge == null) {
      _fail('No bridge — open the terminal icon and set url + token.');
      return;
    }
    // A new prompt never waits on the busy flag — it SUPERSEDES the
    // in-flight turn (voice barge-ins have usually detached it already;
    // this is the typed-text path): detach first and let the bridge
    // queue this text behind an open background tool, or cut a mere
    // thinking turn short and start this one within a heartbeat.
    // (Control chips stay disabled while busy; this path is typed text.)
    // Bump FIRST: an abandoned event loop notices the superseded
    // generation and exits — a bare subscription cancel would leave it
    // parked on the wake future forever.
    _generation++;
    _abandonBridgeTurn();
    if (_worker == null) {
      _fail('Models are still loading — try again in a moment.');
      return;
    }
    if (bubble != null && bubble.trim().isNotEmpty) _addUserChat(bubble.trim());
    // One assistant bubble for the whole turn, sections appended as each
    // say's audio queues (text follows the voice, never leads it). An
    // interrupted turn keeps the sections actually spoken — that IS what
    // the conversation was. A turn that never spoke is removed at the end.
    final turn = ChatEntry.assistant();
    _chat.add(turn);
    _touchChat();
    final gen = ++_generation; // supersedes any in-flight voice reply
    _stopPlayback(); // cut the current audio, like the voice preview does
    final mySeq = ++_bridgeTurnSeq; // claim the busy flag for this turn
    _bridgeBusy = true;
    _harnessBackgrounded = false; // this turn is heard, not invisible
    _harnessSince = DateTime.now(); // the chat spinner counts from here
    _error = '';
    _transcript = utterance;
    _phase = AssistantPhase.transcribing;
    _status = status ?? 'Asking the bridge…';
    _tokLive = false; // counters belong to a turn; this one's tally
    _tokKind = ''; // starts at its first frame (bridge resets too)
    notifyListeners();
    _warmUpRoute(); // hold the output route while the harness thinks
    _replyQueue.clear();
    _replyStreamDone = false;
    _ttsSeconds = 0; // the strip tallies per turn: reset, then every
    _playSeconds = 0; // speak() block below adds its synth/play time
    unawaited(_playReplyChunks(gen));
    final spoken = StringBuffer();
    // ── Progress narration ── 'working towards the goal' means AUDIO
    // while working, not only at the end: the bridge pushes a `tool`
    // event at every step's start (name + command/path summary), and
    // with the Narrate switch on (BridgePrefs.narrate, the factory
    // setting, read live so a mid-turn flip bites at the next event)
    // those events are spoken. The reply's own audio always outranks
    // chatter: narration waits for 8 s of real quiet (nothing
    // synthesising or playing, no narration line in the last 8 s — the
    // gate that keeps a burst of ten Edit calls from machine-gunning
    // the speaker), and a step that goes dark for minutes (one gradle
    // build, zero events) repeats its last known line as a ~45 s
    // heartbeat from a pulse timer instead of dead air. Progress lines
    // ride the same speak() path — heard, and logged as bubble blocks:
    // text-follows-audio, history being exactly what the room heard.
    // While hidden, narration holds off (no synth at all): the answer
    // still buffers for replay and the log has every step as text.
    String latestWork = ''; // newest 'the harness is working…' line
    String lastNarrated = '';
    var lastNarratedAt = DateTime.fromMillisecondsSinceEpoch(0);
    var lastSpokenAt = lastNarratedAt; // reply-audio activity clock
    // Speak one answer block end-to-end: synth streamed into the play
    // queue, and the log entry lands the moment the FIRST audio chunk
    // queues — voice and text enter the conversation together. Waiting
    // for the whole sentence to synthesise (the old order) let the voice
    // win the race on long answers: audible seconds before any text. The
    // first-chunk stamp also can't lead the audio (the chunk still has to
    // reach the player after this), while an interrupted turn keeps the
    // sections whose audio actually started — tail chunks still drop on
    // the gen guard, so the card never grows while the loop has already
    // stopped feeding the player (the old "text with no audio").
    Future<void> speak(String text) async {
      lastSpokenAt = DateTime.now(); // audio just became active: hush
      if (_backgrounded) {
        // App is hidden: keep drinking the harness's firehose but skip
        // synth and audio entirely (the speaker is gone anyway). Every
        // block still lands in the chat bubble — the text-follows-audio
        // ordering only matters while audio is audible — and the most
        // recent one is what [_replayPendingReply] speaks on resume.
        spoken.write('$text ');
        turn.blocks.add(text);
        _lastReplyText = text;
        _resumeReplyText = text;
        _touchChat();
        notifyListeners();
        return;
      }
      final swTts = Stopwatch()..start();
      var blockOnAir = false; // per-BLOCK: every say logs its own text at
      // its own first audio chunk (the voice must never lead the text)
      final (audio, rate) = await _worker!.synthesizeStream(
        text,
        onChunk: (chunk, sampleRate) {
          if (gen != _generation) return;
          if (!blockOnAir) {
            blockOnAir = true;
            _phase = AssistantPhase.speaking;
            _status = 'Speaking the bridge: “$text” — tap to cut me off.';
            spoken.write('$text ');
            turn.blocks.add(text);
            _lastReplyText = text;
            _touchChat(); // persists + notifies with the status flip above
          }
          _replyQueue.add((chunk, sampleRate));
          _replyWake?.complete();
          _replyWake = null;
        },
      );
      if (gen != _generation) return;
      swTts.stop();
      _ttsSeconds += swTts.elapsedMilliseconds / 1000.0;
      _playSeconds += audio.length / rate;
      _noteTts(audio, rate); // last message's raw audio: debug replay
    }

    // Narration gate + line pipeline (declared after speak(): they run
    // it). The gate is the reply-audio outrank + anti-machine-gun rules
    // from the block comment above; narrateProgress pushes one line
    // through speak() — heard, and logged as a bubble block.
    bool narrationQuiet() {
      final now = DateTime.now();
      return _bridgePrefs.narrate &&
          !_backgrounded &&
          _phase != AssistantPhase.speaking &&
          !_playerPlaying &&
          now.difference(lastSpokenAt).inSeconds >= 8 &&
          now.difference(lastNarratedAt).inSeconds >= 8;
    }

    Future<void> narrateProgress(String line) async {
      lastNarrated = line;
      lastNarratedAt = DateTime.now();
      await speak(line);
    }

    // Manual subscription, not await-for: a barge-in must be able to
    // detach the phone from this turn at any moment WITHOUT waiting for
    // the next SSE event to finally break the loop (await-for only
    // reacts when an event lands, and a long tool call is exactly where
    // none land). _abandonBridgeTurn cancels this subscription — the
    // connection closes, the bridge BACKGROUNDS the turn (see
    // claude_bridge.mjs: the harness keeps working, its output goes
    // nowhere, and the next prompt either queues behind the open tool or
    // cuts a mere thinking turn short).
    final q = <BridgeEvent>[];
    var closed = false;
    Object? streamError;
    Completer<void>? wake;
    void wakeNow() {
      final w = wake;
      wake = null;
      w?.complete();
    }

    _bridgeDetachWake = wakeNow;
    final sub =
        (events ?? () => bridge.talk(utterance, interrupt: interrupt))().listen(
      q.add,
      onError: (Object e, StackTrace _) {
        streamError = e is BridgeException ? e : BridgeException('$e');
        closed = true;
        wakeNow();
      },
      onDone: () {
        closed = true;
        wakeNow();
      },
    );
    _bridgeSub = sub; // held locally as well: cleanup must not touch a
    // successor turn's subscription or wake hook (identical() guards below)
    // The long-silent-step heartbeat: while this turn still owns the
    // busy slot, every 15 s take the pulse — narrationQuiet() hushes it
    // around any real audio, and a same-line repeat under 45 s old keeps
    // one long build to a steady 'still on it' cadence rather than a
    // stutter. Superseded turns (gen moved on) cancel themselves.
    final heartbeat = Timer.periodic(const Duration(seconds: 15), (t) {
      if (gen != _generation) {
        t.cancel();
        return;
      }
      if (latestWork.isEmpty || !narrationQuiet()) return;
      if (latestWork == lastNarrated &&
          DateTime.now().difference(lastNarratedAt).inSeconds < 45) {
        return;
      }
      unawaited(narrateProgress(latestWork));
    });
    try {
      while (true) {
        if (gen != _generation) break; // interrupted: drop the rest
        if (q.isEmpty) {
          if (closed) break; // stream ended (done event or close)
          await (wake ??= Completer<void>()).future;
          continue;
        }
        final ev = q.removeAt(0);
        if (ev.isSay && ev.text.trim().isNotEmpty) {
          _tokLive = false; // the answer closed and is being spoken;
          // nothing is generating to grow a counter over
          await speak(cleanForSpeech(ev.text.trim()));
        } else if (ev.kind == 'context') {
          // message_start also moves the ticker's `in` number (the
          // context frame and the tally frame ride the same field).
          if (ev.inputTokens > 0 && ev.inputTokens != _tokIn) {
            _tokIn = ev.inputTokens;
            notifyListeners();
          }
          // Live context consumption (message_start / post-result) for
          // the bar above the button — and the finally-block /health
          // re-read catches anything this stream never heard (a detached
          // turn updates lastCtx server-side regardless of the ear).
          _logDebug('bridge context ${ev.inputTokens}/${ev.contextWindow}');
          _mergeContext(ev.inputTokens, ev.contextWindow);
        } else if (ev.kind == 'tool') {
          _logDebug('bridge tool ${ev.toolName} ${ev.detail}');
          if (ev.toolName == 'tokens') {
            // Live token tally from the bridge ("thinking · 1.2k out ·
            // 21k in"): the progress line for turns that think for a
            // minute. The spinning wheel already says the harness is
            // working, so the tally alone is the label. Rewrites the
            // spinner label only — latestWork (the heartbeat narration)
            // and the narrate gate stay untouched, or the voice would
            // ticker-tape a counter every relay. The frame's numerics
            // also feed the local ticker (see the _tok* fields).
            _onTokensFrame(ev);
          } else {
            _tokLive = false; // a real step (Bash npm test…) froze the
            // counter: the estimate stopped being about live generation
            // 'queued' (from the bridge's talk()) gets the human wording:
            // the instant an utterance parks behind a running tool, the
            // phone says 'one moment' and what happens next, instead of
            // the old silent 200 seconds of spinner.
            latestWork = ev.toolName == 'queued'
                ? 'One moment — ${ev.detail}.'
                : 'The harness is working — ${ev.toolName}'
                      '${ev.detail.isEmpty ? '' : ' ${p.basename(ev.detail)}'}';
            _status = latestWork;
            // The step itself lands in the conversation as a silent line:
            // one block of the live bubble (each gets its own line, divider
            // between), never spoken — the narrate switch owns the audio
            // side of tool progress. 'queued' is our own utterance parking
            // behind a running tool, not a tool call, so it stays out.
            if (ev.toolName != 'queued') {
              final label = ev.detail.isEmpty
                  ? ev.toolName
                  : '${ev.toolName} ${ev.detail}';
              turn.blocks.add('${_toolGlyph(ev.toolName)} $label');
              _touchChat();
            }
            notifyListeners();
            if (narrationQuiet() && latestWork != lastNarrated) {
              unawaited(narrateProgress(latestWork));
            }
          }
        } else if (ev.isDone) {
          if (ev.isError && gen == _generation) {
            _error = 'the harness reported an error';
          }
          break;
        } else if (ev.kind == 'error') {
          _fail('Bridge: ${ev.text}');
          break;
        }
      }
      final err = streamError;
      if (err != null && gen == _generation) {
        _fail(err is BridgeException ? err.message : '$err');
      }
      // A control turn that completed silently (/compact succeeded —
      // its progress signal is a system event, not narration) still
      // owes the ear a confirmation. An errored turn (_error set) does
      // not: the failure status speaks for itself.
      if (ack != null &&
          spoken.isEmpty &&
          _error.isEmpty &&
          gen == _generation) {
        await speak(ack);
      }
    } finally {
      heartbeat.cancel(); // no pulse outliving its turn
      // The pointer may have moved during this turn (a death-resume
      // forks; /new cleared it): re-read it after the bridge's result
      // event has written the sid file, so every exit path of every
      // bridge turn leaves the top-row id current.
      unawaited(_refreshSession());
      // Only release the shared detach slots if they still belong to US:
      // an abandoned turn may be cleaned up after a successor turn (from
      // the voice barge-in it just triggered) has already installed its
      // own subscription and wake hook.
      unawaited(sub.cancel());
      if (identical(_bridgeSub, sub)) _bridgeSub = null;
      if (identical(_bridgeDetachWake, wakeNow)) _bridgeDetachWake = null;
      if (_bridgeTurnSeq == mySeq) {
        // We still own the busy flag (no newer turn claimed it). If
        // _abandonBridgeTurn cleared it and a newer utterance took the
        // slot, _bridgeTurnSeq moved on — do not stomp the new owner.
        _bridgeBusy = false;
        _harnessSince = null;
      }
      if (turn.isEmpty) _removeEmptyTurn(turn);
      if (gen == _generation) {
        // Natural end of the current turn (done event / stream close /
        // error): tear down the streamed-player machinery here. An
        // abandoned turn had it torn down by _abandonBridgeTurn already,
        // and a turn superseded by a barge-in successor must NOT close
        // the queue its successor's player loop is now feeding.
        _replyStreamDone = true;
        _replyWake?.complete();
        _replyWake = null;
      }
      final said = spoken.toString().trim();
      if (said.isNotEmpty) _lastSpoken = said;
      // An interrupted turn no longer POSTs /stop here: every interrupt
      // site calls _abandonBridgeTurn, and that decides — voice barge-in
      // DETACHES (the harness keeps working as a background turn, long
      // tools finish, the next prompt queues behind them), the stop chip
      // adds a hard stop via its hardStop flag.
      if (gen == _generation && spoken.isEmpty && _error.isEmpty) {
        // (spoken, not sawFirstChunk: a turn answered entirely while
        // hidden buffered text without ever synthesising audio)
        _status = 'The harness ran, but had nothing to say.';
        _phase = AssistantPhase.idle;
      }
      notifyListeners();
    }
  }

  /// Voice barge-in (or any takeover) while a harness turn is in flight:
  /// detach the phone from that turn RIGHT NOW instead of waiting for the
  /// next SSE event to break the loop. Cancelling the /talk subscription
  /// closes the connection and the bridge turns it into a BACKGROUND
  /// turn: the harness keeps working (a long-running tool call finishes
  /// its work!), the output goes nowhere, and the queue logic in
  /// claude_bridge.mjs decides what your next utterance does — it waits
  /// behind an open tool, or cuts a mere thinking turn short in-band
  /// and starts within a heartbeat. [hardStop] is the hard-stop variant
  /// (stop-chip taps — "stop working", not "I'll steer"): the harness is
  /// told to quit the turn itself (/stop — an in-band interrupt; the
  /// CLI process survives, so no `--resume` re-prefill next turn).
  /// Mode switches no
  /// longer come through here at all while a turn is live: the bridge
  /// session survives them (see [setMode]).
  void _abandonBridgeTurn({bool hardStop = false}) {
    if (!_bridgeBusy) return;
    if (hardStop) unawaited(_bridge?.stop());
    _bridgeBusy = false;
    _harnessSince = null;
    final sub = _bridgeSub;
    _bridgeSub = null;
    unawaited(sub?.cancel());
    _bridgeDetachWake?.call();
    // The streamed-player machinery goes with the abandoned turn (drain
    // it here so the abandoned loop can't clobber a successor's fresh
    // _replyStreamDone=false set right after this call).
    _replyQueue.clear();
    _replyStreamDone = true;
    _replyWake?.complete();
    _replyWake = null;
  }

  /// Stop chip / conversation-mode stop during a bridge turn: silence the
  /// speaker, hard-stop the harness's WORK (a /stop interrupt, not just
  /// detach), and
  /// leave the conversation usable — a follow-up utterance goes straight
  /// out, the interrupted session context carries over.
  void bridgeStop() {
    if (_harnessBackgrounded) {
      // A turn the phone detached is still working invisibly: /stop hits
      // it too (the interrupt lands whether attached or backgrounded).
      unawaited(_bridge?.stop());
      _harnessBackgrounded = false;
      _status = 'Stopped the harness — the detached turn was cut short.';
      notifyListeners();
    }
    if (!_bridgeBusy) return;
    _generation++;
    _stopPlayback();
    // Hard stop incl. the streamed-player teardown inside the helper.
    _abandonBridgeTurn(hardStop: true);
    _harnessBackgrounded = false; // nothing left working invisibly
    _idleReady();
  }

  /// The '/new' and '/compact' chips: conversation housekeeping with an
  /// audible outcome, run through [runQuickCommand]'s turn machinery
  /// (same bubble pairing, text-follows-audio ordering and busy rules).
  /// '/new' goes to the bridge's reset endpoint rather than a stdin
  /// slash: the stream-json CLI has no /new command (interactive /clear
  /// only), and only the endpoint forgets the persisted session id that
  /// would otherwise re-hydrate the old context on the next respawn.
  /// '/compact' passes as a real slash command (see claude_bridge.mjs:
  /// plain-string content is what makes the CLI execute it, verified on
  /// 2.1.296) and compresses the transcript in-process — a
  /// system/compact_boundary event with zero say narration, hence the
  /// locally-spoken ack.
  Future<void> bridgeControl(String chip) {
    if (chip == '/new') {
      return runQuickCommand(
        chip,
        bubble: chip,
        status: 'Starting a fresh conversation…',
        ack: 'Started a fresh conversation. Our chat history is gone.',
        events: () {
          _logDebug('bridge: new session');
          unawaited(_bridge?.reset());
          // The phone forgets too: the app's chat log is the other half
          // of a fresh start (the ack says as much). Wipe memory and disk
          // so the screen goes blank exactly when the harness drops its
          // session — both bubbles this chip just added included; a
          // /new that leaves its own tombstone on screen is not blank.
          _chat.clear();
          _touchChat();
          // And the meter goes blank with the chat, not into a
          // monotonic decline from last week's number: /health will now
          // answer in:0 (the bridge cleared its snapshot), and
          // _mergeContext ignores zeros, so the reset has to happen
          // here. The first message_start of the new conversation puts
          // an honest number back on the bar.
          _contextIn = 0;
          _tokIn = _tokOut = 0;
          _tokKind = '';
          _tokLive = false;
          _tokRate = 0;
          notifyListeners();
          return Stream<BridgeEvent>.empty();
        },
      );
    }
    return runQuickCommand(
      chip,
      bubble: chip,
      status: 'Asking Claude Code to condense the conversation…',
      ack:
          'Done — the conversation is compacted. I still remember what we '
          'were working on, in summary form now.',
    );
  }

  TtsSpec _spec(TtsVoice v, {int sid = 0}) => v.specIn(_modelsDir, sid: sid);

  // ── Lifecycle ────────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      final modelsDir = await unpackModels(onProgress: _modelProgress);
      _modelsDir = modelsDir;
      _prefs = await loadTtsPrefs(modelsDir);
      _bridgePrefs = await loadBridgePrefs(modelsDir);
      _loadChat(); // restore the on-screen conversation (file read is tiny)
      _rebuildBridge();
      unawaited(_refreshSession()); // chat-screen top row knows the id
      // The saved voice must be fully on disk (pack present); otherwise
      // fall back to the default, which downloads on first run just like
      // before.
      var voice = voiceById(_prefs.voiceId) ?? voiceById('kokoro')!;
      if (!await voice.installedIn(modelsDir)) {
        voice = voiceById('kokoro')!;
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
      // Cold start while a turn runs (or just finished) on the bridge —
      // Android killed the process mid-turn: adopt it. Nothing to do when
      // the bridge has nothing open; the health gate inside decides.
      unawaited(reattachBackgroundTurn());
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
  /// that have several; pass `force` to re-apply the current voice.
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


  // ── Latency bench (voice screen panel) ─────────────────────────────────

  bool get benchCapturing => _benchCapturing;
  bool get benchBusy => _benchBusy;
  double get benchSeconds => _benchSeconds;
  String get benchNote => _benchNote;
  List<BenchRun> get benchRuns => List.unmodifiable(_benchRuns);

  /// Label of the voice the bench echoes with (the one currently in use).
  String get benchVoiceLabel {
    for (final v in voices) {
      if (v.id == _activeVoiceId) return v.label;
    }
    return 'current voice';
  }

  /// Start a bench recording: takes the mic (whatever capture it displaces
  /// resumes when the run ends) — the buffer feeds the timed echo turn.
  /// Release with [finishBenchCapture]; a lost release auto-closes at 20 s.
  Future<void> benchDown() async {
    if (_worker == null || _benchCapturing || _voiceBusy) {
      return;
    }
    _captureResumeOnDone = _micStreamWanted;
    _generation++; // abandon any in-flight reply turn
    _abandonBridgeTurn(hardStop: true); // bench timing can't share the harness
    _shutdownAudio();
    _benchChunks.clear();
    _benchSeconds = 0;
    _benchFirstAudioMs = 0;
    _benchT0 = null;
    _benchCapturing = true; // _onMicData routes bytes into the bench buffer
    _phase = AssistantPhase.listening;
    _error = '';
    _status = 'Bench listening… release when done.';
    _benchTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_benchCapturing) return;
      _status = 'Bench listening… ${_benchSeconds.toStringAsFixed(1)}s';
      notifyListeners();
    });
    notifyListeners();
    try {
      await _openMicStream(); // watchdog-protected capture path
    } catch (e) {
      _benchCapturing = false;
      _benchTimer?.cancel();
      _benchTimer = null;
      _fail('Could not open the mic: $e');
    }
  }

  /// Close the bench mic and run the timed turn: transcribe → echo-synthesise
  /// in the current voice → streamed playback, all clocked from this instant
  /// (the release). The result lands in [benchRuns]; the displaced mic
  /// capture resumes on the way out.
  Future<void> finishBenchCapture() async {
    if (!_benchCapturing) return;
    _benchCapturing = false; // first: ignores trailing stream data
    _benchTimer?.cancel();
    _benchTimer = null;
    _micWatchdog?.cancel();
    _micWatchdog = null;
    await _recSub?.cancel();
    _recSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    _phase = AssistantPhase.idle;
    final total = _benchChunks.fold<int>(0, (n, c) => n + c.length);
    _benchSeconds = total / 16000.0;
    if (total < 16000) {
      // under a second: too short to measure anything honestly
      _benchChunks.clear();
      _benchNote = 'That was too short — hold at least a second.';
      notifyListeners();
      _afterCapture();
      return;
    }
    _benchBusy = true;
    final pcm = Float32List(total);
    var off = 0;
    for (final c in _benchChunks) {
      pcm.setRange(off, off + c.length, c);
      off += c.length;
    }
    _benchChunks.clear();
    _benchT0 = Stopwatch()
      ..start(); // release moment: latencies clock from here
    _warmUpRoute(); // the route rides the wait exactly like a real PTT turn
    _benchNote = 'Transcribing…';
    notifyListeners();
    final gen = _generation; // stays ours unless a newer turn supersedes it
    try {
      final text = (await _worker!.transcribe(pcm, 16000)).trim();
      final asrMs = _benchT0!.elapsedMilliseconds;
      if (text.isEmpty) throw StateError('Didn\'t catch that — try again?');
      _benchNote = 'Synthesising the echo…';
      _status = '';
      notifyListeners();
      final swTts = Stopwatch()..start();
      _replyQueue.clear();
      _replyStreamDone = false;
      var sawFirstChunk = false;
      final playTask = _playReplyChunks(gen);
      final (audio, rate) = await _worker!.synthesizeStream(
        text,
        onChunk: (chunk, sampleRate) {
          if (gen != _generation) return;
          if (!sawFirstChunk) {
            sawFirstChunk = true;
            _phase = AssistantPhase.speaking;
            _status = 'Echoing: “$text”';
            notifyListeners();
          }
          // [_benchFirstAudioMs] itself is stamped in _playWav: the honest
          // figure is when the PLAYER got the bytes, not when we queued them
          // (the temp-wav write in between is real latency the user hears as
          // dead air).
          _replyQueue.add((chunk, sampleRate));
          _replyWake?.complete();
          _replyWake = null;
        },
      );
      swTts.stop();
      _noteTts(audio, rate); // bench audio counts: debug replay can play it
      _ttsSeconds =
          swTts.elapsedMilliseconds / 1000.0; // keeps the strip honest
      final secs = audio.length / rate;
      _playSeconds = secs;
      _replyStreamDone = true;
      _replyWake?.complete();
      _replyWake = null;
      await playTask; // let the echo finish playing before the next press
      final run = BenchRun(
        voice: benchVoiceLabel,
        recordedSeconds: _benchSeconds,
        heard: text,
        asrMs: asrMs,
        firstAudioMs: _benchFirstAudioMs == 0
            ? swTts.elapsedMilliseconds
            : _benchFirstAudioMs,
        synthTotalMs: swTts.elapsedMilliseconds,
        audioSeconds: secs,
        rtf: secs > 0
            ? swTts.elapsedMilliseconds / 1000 / secs
            : double.negativeInfinity,
      );
      _benchRuns.insert(0, run);
      if (_benchRuns.length > 10) _benchRuns.removeLast();
      _benchNote =
          'release→text ${run.asrMs} ms · release→first audio '
          '${run.firstAudioMs} ms · sentence synthesised in '
          '${run.synthTotalMs} ms (RTF ${run.rtf.toStringAsFixed(2)})';
    } catch (e) {
      _replyStreamDone = true;
      _replyWake?.complete();
      _replyWake = null;
      _benchNote = 'Bench run failed: $e';
    } finally {
      _benchBusy = false;
      _benchChunks.clear();
      _benchT0 = null;
      if (gen == _generation) _phase = AssistantPhase.idle;
      notifyListeners();
    }
    _afterCapture();
  }

  /// Abandon a bench recording in progress (panel's cancel path).
  void cancelBenchCapture() {
    if (!_benchCapturing) return;
    _benchCapturing = false;
    _benchTimer?.cancel();
    _benchTimer = null;
    _benchChunks.clear();
    _shutdownAudio();
    _phase = AssistantPhase.idle;
    _benchNote = 'Bench recording cancelled.';
    notifyListeners();
    _afterCapture();
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
    final resume = _captureResumeOnDone;
    _captureResumeOnDone = false;
    if (resume && _mode == InteractionMode.conversation && !_backgrounded) {
      unawaited(_beginConversation());
    }
  }

  void setMode(InteractionMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _conversationWasLive = false;
    if (_bridgeBusy) {
      // A mode switch rewires the INPUT side only; it must not break the
      // harness session or retire its chat spinner mid-turn (the old
      // hard-stop made toggling the control feel like pulling the plug).
      // Same survival rule as pauseConversation: no _generation bump —
      // that would break the turn's event stream — and no hard stop. Close
      // just the mic half: the recorder and the old mode's listeners go,
      // while the streamed reply player deliberately survives the switch
      // (no _stopPlayback: it would also drop the unplayed chunk queue),
      // so the harness keeps narrating its work into the new mode. The
      // turn's own status text stays up; the next event refreshes it.
      _shutdownMic();
      _phase = AssistantPhase.idle;
      notifyListeners();
    } else {
      _shutdownAudio();
      _generation++; // abandon any in-flight voice turn
      _abandonBridgeTurn(hardStop: true);
      _idleReady();
    }
  }

  /// App went to background: tear the conversation down (the mic must not
  /// stay open invisibly), but remember that it was live so [resumeConversation]
  /// can bring it back. A bridge (Claude Code) turn is the exception: the
  /// harness keeps answering while hidden, every say lands in the chat log,
  /// and the last one is buffered to be spoken by [resumeConversation].
  /// Any other in-flight reply (local echo TTS mid-synthesis) is abandoned.
  void pauseConversation() {
    if (_backgrounded) {
      // Already hidden. The lifecycle fires hidden AND paused on the way
      // down — and hidden AGAIN on the way up (paused → hidden → inactive
      // → resumed): a second pass here would snapshot the "when you're
      // back" notice as the working line (_pausedWorking), and the resume
      // would restore it — the spinner quoting the hide notice while we
      // ARE back, the turn looking like it stopped doing anything.
      return;
    }
    var live =
        _mode == InteractionMode.conversation &&
        (_phase == AssistantPhase.listening ||
            _phase == AssistantPhase.transcribing ||
            _phase == AssistantPhase.speaking);
    _captureResumeOnDone = false;
    // A bridge turn in flight survives the hide: no _generation bump (that
    // would break its event stream AND tell the harness to stop), so its
    // remaining says keep flowing into speak()'s backgrounded branch. Seed
    // the resume buffer with the last block heard so far — if the hide cut
    // its audio mid-playback, the replay restarts that block cleanly.
    final bridgeLive = _bridgeBusy;
    if (bridgeLive && _lastReplyText != null) _resumeReplyText = _lastReplyText;
    // Snapshot the spinner's working line before the status below overwrites
    // it with the "when you're back" notice: [resumeConversation] puts it
    // back so a background/foreground blink is invisible to the turn.
    if (bridgeLive) _pausedWorking = _status;
    _conversationWasLive = live;
    _backgrounded = true;
    if (!bridgeLive) _generation++; // no talking to an empty app
    _shutdownAudio();
    _phase = AssistantPhase.idle;
    _status = bridgeLive
        ? 'Working in the background — I\'ll show every reply and speak '
              'the last one when you\'re back.'
        : live
        ? 'Paused — I\'ll resume when you\'re back.'
        : _mode == InteractionMode.conversation
        ? 'Tap the mic to start a conversation. Pause about a second and I\'ll answer.'
        : 'Ready. Hold the button, speak, release to send.';
    notifyListeners();
  }

  /// App came back to the foreground: speak whatever the bridge answered
  /// while hidden (the newest reply only — the chat log already shows all
  /// of them), then reopen the conversation exactly as the user left it
  /// (VAD reseeded, watchdog rearmed — all inside [_beginConversation]).
  Future<void> resumeConversation() async {
    _backgrounded = false;
    final pending = _resumeReplyText;
    _resumeReplyText = null;
    final working = _pausedWorking;
    _pausedWorking = null;
    final restart = _conversationWasLive;
    _conversationWasLive = false;
    if (_bridgeBusy) {
      // Still streaming as we return: no replay (its next says are audible
      // from here on, and the buffered ones stay visible in the log). Put
      // the working line back — the spinner and its elapsed readout must
      // carry through a background blink as if it never happened, not sit
      // there quoting the "when you're back" notice while we ARE back.
      // (Transcribing rather than the snapshot's possible speaking phase:
      // hide cut any audible chunk, so "working" is the honest state until
      // the next say's first chunk flips it to speaking for real.)
      if (working != null) {
        _status = working;
        _phase = AssistantPhase.transcribing;
      }
      // The hide's _stopPlayback kills the queue pump at its seam (and
      // mid-play it died on the cleared field's null check — see
      // [_playReplyChunks]'s captured seam). Without a live pump the
      // survived turn would stream as text-only forever: respawn it, and
      // only when none runs (a pump parked on the wake hook must not get
      // a twin competing for the chunk queue).
      if (!_replyPumpAlive) unawaited(_playReplyChunks(_generation));
      notifyListeners();
      if (restart) unawaited(_beginConversation());
      return;
    }
    // A stream that DIED while hidden (process death, OS-dropped socket)
    // is the one state the branch below cannot restore: the turn ran on
    // unheard, and its output sits in the bridge's backlog. Reattach
    // first — it supersedes a pending replay (the gen bump here would
    // kill it, and the backlog covers everything after the drop; the
    // half-heard pre-hide block is already in the log).
    if (await reattachBackgroundTurn()) return;
    if (pending != null && _worker != null) {
      unawaited(_replayPendingReply(pending, thenListen: restart));
      return;
    }
    if (!restart) return;
    unawaited(_beginConversation());
  }

  /// The bridge is running a turn — or finished one — with NO listener:
  /// the phone's stream died while the app was hidden (Android killed the
  /// process, or the OS dropped the socket). Reattach: the bridge replays
  /// everything that happened unheard (says are spoken, tool lines land
  /// in the chat with their glyphs, context frames refill the bar), the
  /// working line comes back, and the turn's remainder is heard live.
  /// This is the fix for "background → foreground and nothing happens".
  /// Returns true when a reattach actually started (the caller must then
  /// NOT also run a pending-reply replay — the gen bump here would
  /// supersede it, and the backlog already covers the missed window).
  Future<bool> reattachBackgroundTurn() async {
    final bridge = _bridge;
    if (bridge == null || _worker == null) return false;
    if (_bridgeBusy ||
        _backgrounded ||
        _benchCapturing ||
        _benchBusy) {
      return false;
    }
    final h = await bridge.healthInfo();
    final missedCount = h?['missed'];
    final missed = missedCount is num && missedCount > 0;
    if (h?['backgrounded'] != true && !missed) return false;
    final gen = ++_generation;
    final mySeq = ++_bridgeTurnSeq; // claim the busy flag for this turn
    _bridgeBusy = true;
    _harnessBackgrounded = false; // heard again from here on
    _harnessSince = DateTime.now(); // the chat spinner counts from here
    _error = '';
    _tokLive = false;
    _tokKind = '';
    _phase = AssistantPhase.transcribing;
    _status = 'Reattached — the harness is working…';
    notifyListeners();
    _warmUpRoute();
    // A fresh bubble continues the story: the pre-drop blocks live in the
    // old one (the chat log is the history, not this loop's state).
    final turn = ChatEntry.assistant();
    _chat.add(turn);
    _touchChat();
    _stopPlayback(); // cut any current audio, like the voice preview does
    _replyQueue.clear();
    _replyStreamDone = false;
    unawaited(_playReplyChunks(gen));
    final spoken = StringBuffer();

    // One replayed or live say, end-to-end — the same first-chunk block
    // stamp as runQuickCommand's speak (the voice never leads the text).
    Future<void> speak(String text) async {
      final swTts = Stopwatch()..start();
      var blockOnAir = false;
      final (audio, rate) = await _worker!.synthesizeStream(
        text,
        onChunk: (chunk, sampleRate) {
          if (gen != _generation) return;
          if (!blockOnAir) {
            blockOnAir = true;
            _phase = AssistantPhase.speaking;
            _status = 'Speaking the bridge: “$text” — tap to cut me off.';
            spoken.write('$text ');
            turn.blocks.add(text);
            _lastReplyText = text;
            _touchChat();
          }
          _replyQueue.add((chunk, sampleRate));
          _replyWake?.complete();
          _replyWake = null;
        },
      );
      if (gen != _generation) return;
      swTts.stop();
      _ttsSeconds += swTts.elapsedMilliseconds / 1000.0;
      _playSeconds += audio.length / rate;
      _noteTts(audio, rate); // last message's raw audio: debug replay
    }

    unawaited(() async {
      final q = <BridgeEvent>[];
      var closed = false;
      Object? streamError;
      Completer<void>? wake;
      void wakeNow() {
        final w = wake;
        wake = null;
        w?.complete();
      }

      _bridgeDetachWake = wakeNow;
      final sub = bridge.attach().listen(
        q.add,
        onError: (Object e, StackTrace _) {
          streamError = e is BridgeException ? e : BridgeException('$e');
          closed = true;
          wakeNow();
        },
        onDone: () {
          closed = true;
          wakeNow();
        },
      );
      _bridgeSub = sub; // abandon hooks work on this exactly like a /talk
      try {
        while (true) {
          if (gen != _generation) break; // interrupted: drop the rest
          if (q.isEmpty) {
            if (closed) break; // stream ended (done event or close)
            await (wake ??= Completer<void>()).future;
            continue;
          }
          final ev = q.removeAt(0);
          if (ev.isSay && ev.text.trim().isNotEmpty) {
            _tokLive = false;
            await speak(cleanForSpeech(ev.text.trim()));
          } else if (ev.kind == 'context') {
            if (ev.inputTokens > 0 && ev.inputTokens != _tokIn) {
              _tokIn = ev.inputTokens;
              notifyListeners();
            }
            _logDebug('bridge context ${ev.inputTokens}/${ev.contextWindow}');
            _mergeContext(ev.inputTokens, ev.contextWindow);
          } else if (ev.kind == 'tool') {
            _logDebug('bridge tool ${ev.toolName} ${ev.detail}');
            if (ev.toolName == 'tokens') {
              _onTokensFrame(ev);
            } else {
              _tokLive = false;
              _status = 'The harness is working — ${ev.toolName}'
                  '${ev.detail.isEmpty ? '' : ' ${p.basename(ev.detail)}'}';
              final label = ev.detail.isEmpty
                  ? ev.toolName
                  : '${ev.toolName} ${ev.detail}';
              turn.blocks.add('${_toolGlyph(ev.toolName)} $label');
              _touchChat();
              notifyListeners();
            }
          } else if (ev.isDone) {
            if (ev.isError && gen == _generation) {
              _error = 'the harness reported an error';
            }
            break;
          } else if (ev.kind == 'error') {
            _fail('Bridge: ${ev.text}');
            break;
          }
        }
        final err = streamError;
        if (err != null && gen == _generation) {
          _fail(err is BridgeException ? err.message : '$err');
        }
      } finally {
        // Same teardown discipline as runQuickCommand: never touch a
        // successor turn's subscription, wake hook, or busy flag.
        unawaited(_refreshSession());
        unawaited(sub.cancel());
        if (identical(_bridgeSub, sub)) _bridgeSub = null;
        if (identical(_bridgeDetachWake, wakeNow)) _bridgeDetachWake = null;
        if (_bridgeTurnSeq == mySeq) {
          _bridgeBusy = false;
          _harnessSince = null;
        }
        if (turn.isEmpty) _removeEmptyTurn(turn);
        if (gen == _generation) {
          _replyStreamDone = true;
          _replyWake?.complete();
          _replyWake = null;
        }
        final said = spoken.toString().trim();
        if (said.isNotEmpty) _lastSpoken = said;
        if (gen == _generation && spoken.isEmpty && _error.isEmpty) {
          _idleReady();
        }
        notifyListeners();
      }
    }());
    return true;
  }

  /// Speak a bridge reply that landed while the app was hidden. The text is
  /// already in the chat log (buffered there by runQuickCommand's speak()),
  /// so this only feeds the speaker — no new bubble, no double text. When
  /// [thenListen] is set the reply was interrupted a live conversation, so
  /// the mic goes back on the air the moment it ends.
  Future<void> _replayPendingReply(
    String text, {
    required bool thenListen,
  }) async {
    final worker = _worker;
    if (worker == null) return;
    final gen = ++_generation; // supersede whatever half-state survived
    _stopPlayback();
    _error = '';
    _phase = AssistantPhase.transcribing;
    _status = 'Picking up where the bridge left off…';
    notifyListeners();
    _warmUpRoute(); // hold the output route through the synth wait
    _replyQueue.clear();
    _replyStreamDone = false;
    var sawFirstChunk = false;
    unawaited(_playReplyChunks(gen));
    try {
      final (audio, rate) = await worker.synthesizeStream(
        text,
        onChunk: (chunk, sampleRate) {
          if (gen != _generation) return;
          if (!sawFirstChunk) {
            sawFirstChunk = true;
            _phase = AssistantPhase.speaking;
            _status = 'Speaking the bridge: “$text” — tap to cut me off.';
            notifyListeners();
          }
          _replyQueue.add((chunk, sampleRate));
          _replyWake?.complete();
          _replyWake = null;
        },
      );
      if (gen != _generation) return; // cut off mid-replay: user moved on
      _noteTts(audio, rate);
      _lastSpoken = text; // echo guard: this voice coming back is ours
      _replyStreamDone = true;
      _replyWake?.complete();
      _replyWake = null;
      if (_backgrounded) return; // hidden again mid-replay: pause owns UI
      if (thenListen && _mode == InteractionMode.conversation) {
        await _beginConversation();
      } else {
        _idleReady();
      }
    } catch (e) {
      _fail('Could not replay the bridge reply: $e');
    }
  }

  bool _conversationWasLive = false;
  bool _backgrounded = false;
  bool _replyPumpAlive = false; // [_playReplyChunks] queue pump is running
  String? _pausedWorking; // spinner working line snapshotted at hide time
  String? _resumeReplyText; // newest bridge reply buffered while hidden
  String? _lastReplyText; // newest block speak() has fed to the log

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
  //
  // Release GESTURE routes the new prompt when a harness turn is in
  // flight (v0.1.0+25): the press itself detaches that turn (the bridge
  // backgrounds it — the tool call keeps working, output is dropped) and
  // the mic opens over it. Slide the finger UP past a thumb's width and
  // release to INTERRUPT: a mere thinking turn is cut short in-band (bridge
  // `interrupt=1`, the process survives) so your prompt starts in a heartbeat; an open tool
  // still can't be cut and your prompt queues behind it. Release in
  // place or slide RIGHT to QUEUE politely: the turn in flight finishes
  // its work first, then your prompt goes next (`interrupt=0`). A quick
  // tap (< tap-threshold) is the old hard stop: detach + /stop. With no
  // harness turn in flight every release is the plain send-to-local-reply
  // path, exactly as before.

  int _pttPointers = 0; // one hold; extra fingers are ignored
  Timer? _pttMaxTimer; // a lost release must not latch the mic on
  /// Debug counters (shown under the button in debug mode): press/release
  /// edges observed — proves on-device whether holds reach the Listener.
  int pttEdgeCount = 0;
  Offset? _pttDownPos; // press point: the release delta decides the gesture
  DateTime _pttDownAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _pttBridgeHold = false; // this hold opened over an in-flight turn

  /// A push-to-talk hold whose mic opened on top of a running harness
  /// turn — the UI says "release to queue / slide up to interrupt" while
  /// this is set and the button is being held.
  bool get pttHoldOverTurn => _pttBridgeHold && _pttPointers > 0;

  /// A detached harness turn is still working on the bridge unheard.
  bool get harnessBackgrounded => _harnessBackgrounded;

  /// Slide-up-vs-rest distances, logical px: a deliberate thumb drag off
  /// the button, small enough to never trigger from a rolling press.
  static const double _pttSlideUpPx = 48;
  /// Press-and-release faster than this while a turn runs is a TAP: the
  /// hard stop (detach + /stop), the old tap-Stop behaviour, not a hold.
  static const int _pttTapStopMs = 400;

  /// Classifies the release gesture from the press point: `up` — dragged
  /// clearly UPWARD past [_pttSlideUpPx] (vertical-dominant, so a
  /// right-slide or a diagonal drift toward the queue reading never cuts
  /// thinking by accident) — the interrupt slide; `right` — dragged
  /// clearly RIGHTWARD past [_pttSlideRightPx] (horizontal-dominant) —
  /// the DISMISS slide: the recording is thrown away unsent. Both read
  /// the same press point in one pass, so the two are exclusive by
  /// construction.
  static const double _pttSlideRightPx = 48;
  (bool, bool) _pttSlidesAt(Offset? upAt) {
    final start = _pttDownPos;
    _pttDownPos = null;
    if (upAt == null || start == null) return (false, false);
    final d = upAt - start;
    return (
      d.dy < -_pttSlideUpPx && d.dy.abs() > d.dx.abs(),
      d.dx > _pttSlideRightPx && d.dx.abs() > d.dy.abs(),
    );
  }

  void pttDown([Offset? at]) {
    pttEdgeCount++;
    debugPrint(
      'PTT-DOWN mode=${_mode.name} phase=${_phase.name} '
      'worker=${_worker != null} ptr=$_pttPointers busy=$_bridgeBusy',
    );
    if (_mode != InteractionMode.pushToTalk || _worker == null) return;
    _pttDownPos = at;
    _pttDownAt = DateTime.now();
    if (_phase == AssistantPhase.transcribing ||
        _phase == AssistantPhase.speaking ||
        _bridgeBusy) {
      // Press over a working agent (bridge turn or local TTS reply):
      // abandon the in-flight turn (so the synthesiser does not queue
      // more audio), cut anything audible, then let this very hold open
      // the mic. For a BRIDGE turn, abandon = DETACH: the harness keeps
      // working backgrounded (an open tool call finishes its work!),
      // and the release gesture decides whether the new prompt cuts a
      // mere thinking turn short (slide up) or queues politely behind
      // the work (release / slide right). Same supersede semantics as a
      // spoken barge-in in conversation mode — here, per spec, PTT's.
      _pttBridgeHold = _bridgeBusy;
      if (_pttBridgeHold) _harnessBackgrounded = true;
      _generation++;
      _stopDebugPlayback();
      _stopPlayback();
      _abandonBridgeTurn();
    } else {
      _pttBridgeHold = false;
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

  void pttUp([Offset? at]) {
    pttEdgeCount++;
    final (slideUp, slideRight) = _pttSlidesAt(at);
    debugPrint('PTT-UP ptr=$_pttPointers slideup=$slideUp dismiss=$slideRight');
    if (_pttPointers == 0) {
      _pttDownPos = null; // keep the stale-drag reading harmless
      return;
    }
    _pttPointers--;
    if (_pttPointers > 0) return; // still holding with another finger
    _pttMaxTimer?.cancel();
    _pttMaxTimer = null;
    _warmUpRoute(); // connect the output route while we transcribe (see below)
    if (slideRight) {
      unawaited(_stopAndRespond(discard: true));
    } else {
      unawaited(_stopAndRespond(interrupt: slideUp));
    }
  }

  void pttCancel() {
    // Back gesture / system interruption: behave exactly like a release
    // with no slide (never discard the recording, never a hard stop by
    // accident), so the mic can never be left open.
    _pttPointers = 0;
    _pttMaxTimer?.cancel();
    _pttMaxTimer = null;
    _warmUpRoute();
    _pttDownPos = null;
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
  /// Bench capture counts too (same stream, different sink).
  bool get _micStreamWanted =>
      _benchCapturing ||
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
    _micRecoverPending = false; // a fresh stream voids any deferred reopen
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
      if (_micRecovering || _micRecoverPending || !_micStreamWanted) return;
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
    // Reopening a voiceComm capture stream can duck or pause media playback
    // (audio focus churn on many devices) — while our reply is audible that
    // is worse than a temporarily deaf barge-in mic, so the reopen waits for
    // the reply to end. PTT never bites: no stream is wanted while it plays.
    if (_playerPlaying || _replyQueue.isNotEmpty) {
      if (!_micRecoverPending) {
        _micRecoverPending = true;
        _logDebug('mic recover deferred ($why)');
      }
      return;
    }
    _micRecovering = true;
    debugPrint('mic stream $why — reopening');
    _micRecoverPending = false;
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
    if (_benchCapturing) {
      // Latency bench: mic hand-off feeding the timed echo turn in
      // finishBenchCapture instead of a sample file.
      final c = pcm16ToFloat32(bytes);
      _benchChunks.add(c);
      _benchSeconds += c.length / 16000.0;
      if (_benchSeconds >= 20) unawaited(finishBenchCapture()); // hard cap
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
    // No ear left on the harness: hard-stop its in-flight turn too.
    _abandonBridgeTurn(hardStop: true);
    _phase = AssistantPhase.idle;
    _status = message;
    notifyListeners();
  }

  void _cancelResponse(String message) {
    _generation++; // abandon any in-flight turn
    // Tap = explicit stop: hard-quit the harness's work too (a spoken
    // barge-in detaches/backgrounds instead — see _abandonBridgeTurn).
    _abandonBridgeTurn(hardStop: true);
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
      if (event.note!.startsWith('bargein: ')) {
        _logDebug('INTERRUPT ${event.note}');
      }
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
        final heardMs = DateTime.now()
            .difference(_replyStartedAt)
            .inMilliseconds;
        _logDebug('kill reply after ${heardMs}ms of reply');
        _stopPlayback();
        _generation++; // abandon the response we were speaking
        // Spoken takeover = DETACH (no hard stop): the harness keeps
        // working behind the scenes — a long tool call runs on, and the
        // utterance landing in a moment queues behind it (or cuts the
        // thinking turn short at the bridge). That is Claude Code's
        // background-the-long-task flow, voice-native edition.
        _abandonBridgeTurn();
        _status = 'Interrupted — go ahead.';
      } else if (_phase == AssistantPhase.transcribing) {
        _userSpeaking = true;
        _generation++; // user resumed; drop the half-baked response
        _abandonBridgeTurn(); // same detach semantics as above
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
      _warmUpRoute(); // connect the output route while we transcribe
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

  Future<void> _startTurn(Float32List samples, {bool interrupt = true}) async {
    final gen = ++_generation; // any newer turn supersedes this one
    _pttBridgeHold = false; // the hold is over: the turn owns the choice now
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
      // The conversation log keeps everything: what we heard lands as a
      // user bubble now (in either mode), the answer as assistant
      // bubbles section by section as it is spoken.
      _addUserChat(text);

      if (_bridge != null && _bridgePrefs.voice) {
        // Voice -> Claude Code: the utterance becomes a harness turn, and
        // the harness's answer is spoken (progress narrated, barge-in
        // detaches so the work either backgrounds or gets cut short at
        // the bridge) through the same streamed pipeline the chips use.
        // With the toggle off, the app below just repeats. The detach
        // happens HERE too, not only at speechStarted: if the previous
        // turn is somehow still attached (ASR ran while it sat silent —
        // the very long-tool case this feature is about), this takes it
        // out and the bridge queues our fresh text behind its open tool.
        // [interrupt] rides through to the bridge's queue decision: a
        // push-to-talk slide-right release queued this prompt politely
        // (the turn in flight finishes first); anything else cuts a mere
        // thinking turn so the new prompt starts in a heartbeat.
        _abandonBridgeTurn();
        unawaited(runQuickCommand(text, interrupt: interrupt));
        return;
      }

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
    _replyPumpAlive = true;
    try {
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
        // The seam is captured, not re-read: _stopPlayback nulls the
        // shared field and completes it (a hide-mode pause cuts an
        // audible chunk right here), and the old `_replyChunkDone!`
        // re-reads then null-threw the pump stone dead — which is how a
        // survived bridge turn ended up streaming text-only forever.
        final seam = Completer<void>();
        _replyChunkDone = seam;
        await _playWav(
          chunk,
          sampleRate,
          gen,
          onComplete: () {
            if (!seam.isCompleted) seam.complete();
          },
        );
        if (gen != _generation) return; // user resumed: drop the rest
        await seam.future; // ends on natural end... or a stop
        // Seam complete: the loop owns playback again. Clearing the flag
        // re-arms the global end hook for any later one-shot play, and the
        // event that just woke us was already fully dispatched (the global
        // listener ran and skipped before this listener completed us).
        _replyChunkDone = null;
        if (!_playerPlaying) return; // barge-in won: _stopPlayback cleaned up
      }
      if (firstChunk) return; // engine produced nothing (error path covers)
      _onPlaybackNaturalEnd();
    } finally {
      // Dead pump, by whichever exit path: tells [resumeConversation]
      // whether the survived turn's queue needs a respawn to keep an ear
      // on the speaker.
      _replyPumpAlive = false;
    }
  }

  /// Keep the output route BUSY from the moment a turn ends until the first
  /// reply chunk replaces it: a few seconds of INAUDIBLE silence played
  /// through the same player, so Android never gets a chance to idle the
  /// output path (a one-shot 100 ms tick did not survive the wait — the
  /// pipeline power-cycles within a couple hundred ms and the real chunk
  /// paid the connect+ramp cost with its first words anyway; this also
  /// rides through the mic-teardown transition on PTT). Measured: PTT
  /// replies truncated the first word, while the Settings voice preview —
  /// same synthesised bytes, no mic session before it — played clean.
  /// Fire-and-forget: the tick's completion lands while [_playSub] is
  /// deliberately null so it is a no-op; the first real play() simply takes
  /// over, and a dead round ends with silence no one hears.
  void _warmUpRoute() {
    unawaited(() async {
      try {
        final dir = await getTemporaryDirectory();
        final file = File(p.join(dir.path, 'reply_warmup.wav'));
        await file.writeAsBytes(encodeWav(Float32List(48000), 24000)); // 2 s
        final prev = _playSub;
        _playSub = null; // the tick's own completion event must be a no-op
        await prev?.cancel();
        await _player.play(DeviceFileSource(file.path));
        // Same path each round: it just gets overwritten, no litter.
      } catch (_) {}
    }());
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
    // Streamed replies overwrite this once per sentence: delete the
    // previous chunk's wav (its audio is already audible or dropped).
    final prevFile = _playFile;
    _playFile = file.path;
    if (prevFile != null) {
      unawaited(File(prevFile).delete().catchError((_) => File(prevFile)));
    }
    _playerPlaying = true;
    // _replyStartedAt marks only the FIRST chunk: the 450 ms AEC guard must
    // not re-arm per chunk (a chunk boundary would otherwise re-open the
    // "too early to trust an interruption" window every few seconds).
    if (_phase != AssistantPhase.speaking ||
        DateTime.now().difference(_replyStartedAt).inMilliseconds > 2000) {
      _replyStartedAt = DateTime.now();
    }
    _worker?.setPlaying(true); // gate goes hard-mode while we hear ourselves
    if (onComplete != null) {
      _logDebug(
        'chunk play ${(samples.length / sampleRate).toStringAsFixed(1)}s'
        '${_replyQueue.isEmpty ? ' (last)' : ' +${_replyQueue.length}'}',
      );
    }
    await _playSub?.cancel();
    _playSub = _player.onPlayerComplete.listen((_) {
      if (onComplete != null) {
        onComplete(); // streamed mode: _playReplyChunks decides on end
      } else if (gen == _generation) {
        _onPlaybackNaturalEnd();
      }
    });
    try {
      if (_benchBusy && _benchFirstAudioMs == 0) {
        // The bench's release→first-audio figure: bytes enter the player
        // NOW (the route warm-up from the release is included — a real PTT
        // round trip pays that latency too, and pretending otherwise would
        // flatter the panel's headline number).
        _benchFirstAudioMs = _benchT0?.elapsedMilliseconds ?? 0;
      }
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
    if (_micRecoverPending) {
      _logDebug('mic recover flush');
      unawaited(_recoverMic('deferred'));
    }
    _worker?.setPlaying(false); // gate relaxes; floor drops back to room
    _cleanupPlayFile();
    // Any utterance the VAD formed from the tail of our own reply must not
    // leak into the next turn (the user talking over the reply keeps theirs).
    if (!_userSpeaking) _worker?.resetVad();
    if (_phase == AssistantPhase.speaking) {
      // PTT: the mic lives only while the button is held, so a finished
      // reply must drop back to idle — not the always-on listening state
      // (that latch made the button look still-pressed after the 2nd turn).
      // A bench echo behaves the same: its mic was closed at release, and
      // the panel (not auto-listening) is what invites the next hold.
      if (_mode == InteractionMode.pushToTalk || _benchBusy) {
        _idleReady();
      } else {
        _phase = AssistantPhase.listening;
        _status = 'Listening — just talk.';
        notifyListeners();
      }
    }
    _fastMicCheck();
  }

  void _stopPlayback() {
    if (!_playerPlaying) return;
    _playerPlaying = false;
    _worker?.setPlaying(false);
    if (_micRecoverPending) {
      _micRecoverPending = false; // the _recoverMic below reloads it fresh
    }
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
    // During a bench run the mic is deliberately closed (the echo plays to
    // an unplugged mic; _afterCapture reopens conversation afterwards).
    if (_micRecovering || !_micStreamWanted || _benchBusy) return;
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

  Future<void> _stopAndRespond({bool interrupt = false, bool discard = false}) async {
    if (_phase != AssistantPhase.listening) return;
    // Snapshot the hold's context before any await: was this recording
    // made OVER an in-flight harness turn (pttDown detached it into a
    // background turn already), and how long was the button held (a
    // quick tap on top of a turn is the hard stop, the old tap-Stop).
    final bridgeHold = _pttBridgeHold;
    _pttBridgeHold = false;
    final heldMs = DateTime.now().difference(_pttDownAt).inMilliseconds;
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
    if (discard) {
      // Slide-right release: throw the recording away unsent. The mic is
      // closed, the chunks dropped — whatever length they were — and a
      // detached harness turn (if this hold opened over one) keeps
      // working in the background untouched. Never a hard stop: dismissing
      // what I said is not a comment on what the harness is doing.
      _chunks.clear();
      _recordSeconds = 0;
      _phase = AssistantPhase.idle;
      _status = bridgeHold
          ? 'Dismissed — the harness keeps working in the background.'
          : 'Dismissed — nothing sent.';
      notifyListeners();
      return;
    }
    if (total < 16000 ~/ 4) {
      _phase = AssistantPhase.idle;
      if (bridgeHold) {
        // The hold opened over a harness turn but nothing speakable came
        // out. A quick tap is the hard stop the button always was mid-
        // turn: /stop cuts the (already detached, still running) turn.
        // A longer hold with no words leaves the background work ALONE —
        // it finishes on its own and the next release queues behind it.
        if (interrupt || heldMs < _pttTapStopMs) {
          unawaited(_bridge?.stop());
          _harnessBackgrounded = false;
          _status = 'Heard nothing — stopped the harness.';
        } else {
          _status =
              'Heard nothing — the harness keeps working in the background.';
        }
      } else {
        _status = 'Heard nothing. Hold the button and speak.';
      }
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
    final gen = _generation; // a press during cleanup interrupts this turn
    _phase = AssistantPhase.transcribing;
    _status = 'Cleaning up the recording…';
    notifyListeners();
    Float32List cleaned = pcm;
    try {
      cleaned = await _worker!.denoise(pcm);
    } catch (e) {
      debugPrint('denoise failed, using raw audio: $e');
    }
    if (gen != _generation) {
      // The button was pressed again mid-cleanup: that hold owns the mic
      // (and the reply is abandoned); don't resurrect this turn.
      if (_pttPointers == 0) _idleReady();
      return;
    }
    // A slide-right release is the POLITE queue (interrupt: false): if
    // the bridge still has a turn in flight (the one this hold detached,
    // or an older one backgrounded unheard), this prompt waits for it to
    // finish. Everything else keeps the established takeover flavour.
    await _startTurn(cleaned, interrupt: interrupt || !bridgeHold);
  }

  // ── Utilities ────────────────────────────────────────────────────────────

  void _shutdownAudio() {
    _stopDebugPlayback();
    _stopPlayback();
    _shutdownMic();
  }

  /// The INPUT half of [_shutdownAudio]: watchdog, recorder, VAD
  /// buffers, and any in-flight bench capture. Split out so a mode
  /// switch during a live bridge turn can close the mic without touching
  /// the streamed reply player — stopping the player there would silence
  /// the harness mid-turn and (via _stopPlayback's queue clear) drop the
  /// say-chunks already synthesised, making the survive-vs-abandon choice
  /// depend on whether a chunk happened to be audible at tap time.
  void _shutdownMic() {
    _micWatchdog?.cancel();
    _micWatchdog = null;
    unawaited(_recSub?.cancel() ?? Future.value());
    _recSub = null;
    unawaited(_recorder.stop());
    _worker?.resetVad();
    _chunks.clear();
    _vadBuf.clear();
    if (_benchCapturing || _benchBusy) {
      // Same for a bench run in flight: its timing is no longer trustworthy.
      _benchCapturing = false;
      _benchBusy = false;
      _benchTimer?.cancel();
      _benchTimer = null;
      _benchChunks.clear();
      _benchT0 = null;
      _benchNote = 'Bench run cancelled — the mic was taken away.';
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
