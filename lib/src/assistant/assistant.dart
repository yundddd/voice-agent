/// The voice round-trip orchestrator.
///
///   mic -> VAD endpointing -> Whisper (ASR) -> text -> TTS -> speaker
///
/// in two interaction modes (see [InteractionMode]), with a Claude Code
/// bridge turn layered in place of the local echo when configured.
///
/// What this class is NOT anymore: a monolith. The pieces that grew
/// rules (and field-report scar tissue) each live in their own unit
/// behind a seam this file wires together:
///
///  * [ChatStore] — the conversation log, its pins, and persistence.
///  * [TokenTicker] — the live spinner counter (rate-learned extrapolation).
///  * [HopTracker] — the latency strip's flow pulses.
///  * [NarrationGate] — the step-narration quiet/heartbeat rules.
///  * [PttHold] — the push-to-talk pointer/slide state machine.
///  * [MicPipeline] behind [MicSource] — capture, watchdog, reopens.
///  * [ReplyPipeline] behind [AudioOutput] — streamed chunk playback.
///  * [BridgeTurnPump] / [WireLease] / [BridgeTransport] behind
///    [HarnessGateway] — the harness event loop, its zombie watchdog,
///    and the push-vs-pull transport negotiation.
///
/// What stays here is precisely the part that is not separable without
/// splitting the meaning: the generation-counter supersede policy, the
/// phase machine the UI mirrors, the hide/resume snapshot dance, and
/// the turn dispatch — the conversation about WHEN, delegated to
/// collaborators that know HOW.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui'
    show Offset; // PTT release-gesture geometry (Listener positions)

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../common/clock.dart';
import '../common/sinks.dart';
import './chat_store.dart';
import './hop_tracker.dart';
import './mic_pipeline.dart';
import './narration_gate.dart';
import './ptt_hold.dart';
import './reply_pipeline.dart';
import './state.dart';
import './token_ticker.dart';
import './turn_session.dart';
import '../bridge/bridge_event.dart';
import '../bridge/client.dart';
import '../bridge/gateway.dart';
import '../bridge/prefs.dart';
import '../bridge/text_rules.dart';
import '../bridge/transport.dart';
import '../bridge/turn_pump.dart';
import '../bridge/wire_lease.dart';
import '../chat/chat_log.dart';
import '../journal/app_events.dart';
import '../models/model_packs.dart';
import '../models/model_paths.dart';
import '../platform/audio_output.dart';
import '../platform/file_player_output.dart';
import '../platform/mic_source.dart';
import '../platform/record_mic_source.dart';
import '../speech/kokoro_voices.dart';
import '../speech/speech_worker.dart';
import '../speech/tts_voices.dart';

export '../assistant/state.dart';
export '../assistant/turn_session.dart'
    show TakeoverStop, TurnCoordinator, TurnTrigger, takeoverStop;
export '../bridge/bridge_event.dart' show BridgeEvent;
export '../bridge/gateway.dart' show BridgeException, HarnessGateway;
export '../bridge/text_rules.dart'
    show fmtTokenCount, activityLabelFor, stepIsSilentFor, cleanForSpeech;
export '../bridge/turn_pump.dart' show BridgeTurnPump, PumpOutcome;
export '../chat/chat_log.dart' show ChatEntry;
export '../journal/app_events.dart' show AppEventJournal, kAppLogDefaultPort;
export '../models/model_packs.dart' show unpackModels;
export '../models/model_paths.dart' show ModelPaths;
export '../platform/audio_output.dart' show AudioOutput;
export '../platform/mic_source.dart' show MicSource;
export '../speech/speech_worker.dart' show SpeechEvent, SpeechWorker, TtsSpec;
export '../speech/tts_voices.dart'
    show TtsVoice, TtsPrefs, loadTtsPrefs, saveTtsPrefs, ttsVoices, voiceById;

/// Orchestrates the voice round trip and every state the chat screen
/// renders. One instance per app; the screens talk to it (and only it).
class VoiceAssistant extends ChangeNotifier {
  /// Every collaborator is injectable: production defaults to the real
  /// plugin-backed [MicSource]/[AudioOutput]/wall clock; tests hand in
  /// the fakes from src/platform/ and src/common/ and drive the whole
  /// turn lifecycle without a device.
  VoiceAssistant({
    MicSource? micSource,
    AudioOutput? audioOutput,
    HarnessGateway Function(String url, String token)? gatewayFactory,
    Scheduler? scheduler,
    Clock? clock,

    /// Test seam: run the orchestrator against a fake [SpeechEngine]
    /// without the model isolate (init() overwrites it with the real
    /// worker when it loads).
    SpeechEngine? worker,
  }) {
    _clock = clock ?? wallClock;
    _scheduler = scheduler ?? const WallScheduler();
    _gatewayFactory = gatewayFactory;
    _worker = worker;

    _hops = HopTracker(
      clock: _clock,
      scheduler: _scheduler,
      repaint: notifyListeners,
    );
    _ticker = TokenTicker(clock: _clock, repaint: notifyListeners);
    _narr = NarrationGate(clock: _clock);
    _ptt = PttHold(clock: _clock);
    _transport = BridgeTransport(
      scheduler: _scheduler,
      clock: _clock,
      log: _logDebug,
    );
    _chat = ChatStore(
      persist: _persistChat,
      repaint: notifyListeners,
      trace: _logDebug,
    );
    _lease = WireLease(
      scheduler: _scheduler,
      clock: _clock,
      attached: () => _bridgeBusy,
      paused: () => _backgrounded,
      audioDraining: () => _reply.playing || _reply.queuedCount > 0,
      onQuiet: _wireQuietFired,
    );
    _reply = ReplyPipeline(
      output: audioOutput ?? FilePlayerAudioOutput(),
      worker: () => _worker,
      clock: _clock,
      scheduler: _scheduler,
      repaint: notifyListeners,
      userSpeaking: () => _userSpeaking,
      gatePin: (on) => _worker?.setPlaying(on),
      resetVad: () => _worker?.resetVad(),
      onNaturalEnd: _handleNaturalEnd,
      onStopped: () => _mic.fastCheck(), // lazy: _mic is assigned below
      onAudible: _onChunkAudible,
    );
    _mic = MicPipeline(
      source: micSource ?? RecordMicSource(),
      scheduler: _scheduler,
      clock: _clock,
      log: _logDebug,
      streamWanted: () => _micStreamWanted,
      route: () => _micRoute,
      paused: () => _backgrounded,
      audioBusy: () => _reply.playing || _reply.queuedCount > 0,
      onRaw: _onPcm,
      onVadWindow: (w) => _worker?.sendAudio(w),
      gatePin: (on) => _worker?.setPlaying(on),
      resetVad: () => _worker?.resetVad(),
      userSpeaking: () => _userSpeaking,
      reopened: _onMicReopened,
      failed: _fail,
      disposed: () => _disposed,
    );
    _reply.log = _logDebug;
    // The bridge-turn truth (busy slot, backgrounded badge, the bottom
    // line's snapshot, the generation/seq tokens) lives in the
    // coordinator; this class reads it and fires its named transitions.
    // The machine parts a transition orchestrates arrive as callbacks —
    // the coordinator owns the truth and the ORDER, this class owns the
    // reattach chain and the reply player those callbacks pull.
    _turn = TurnCoordinator(
      clock: _clock,
      log: _logDebug,
      hardStop: () async {
        await _gateway?.stop();
      },
      beforeDetach: _cancelReattachChain,
      afterDetach: _reply.clearAndClose,
      queuedPin: () => _chat.queuedBubble != null,
    );
  }

  // Silence duration that ends an utterance in conversation mode.
  static const _endpointSilence = 1.0;

  late final Clock _clock;
  late final Scheduler _scheduler;
  late final HarnessGateway Function(String url, String token)? _gatewayFactory;
  SpeechEngine? _worker;
  late final MicPipeline _mic;
  late final ReplyPipeline _reply;
  late final HopTracker _hops;
  late final TokenTicker _ticker;
  late final NarrationGate _narr;
  late final ChatStore _chat;
  late final BridgeTransport _transport;
  late final WireLease _lease;
  late final PttHold _ptt;
  Timer? _pttMaxTimer; // a lost release must not latch the mic on

  InteractionMode _mode = InteractionMode.conversation;
  AssistantPhase _phase = AssistantPhase.idle;
  String _status = 'Loading models…';
  String _transcript = '';
  String _error = '';
  String _lastSpoken = '';
  double _recordSeconds = 0;
  double _asrSeconds = 0;
  double _ttsSeconds = 0;
  bool _ttsFirstTimed = false; // first-word latency already stamped
  final List<Float32List> _chunks = []; // push-to-talk buffer
  Float32List? _asrAudio; // exact audio the last ASR call consumed
  int _asrAudioRate = 16000;
  bool _userSpeaking = false; // live VAD flag (conversation mode)
  bool _segEchoRisk = false; // current utterance started while we were talking
  bool _segGotAudio = false; // current utterance produced a VAD segment
  bool _disposed = false;

  InteractionMode get mode => _mode;
  AssistantPhase get phase => _phase;
  String get status => _status;
  String get transcript => _transcript;
  String get error => _error;
  bool get userSpeaking => _userSpeaking;
  bool get debugPlaying => _reply.debugPlaying;
  bool get sessionActive =>
      _phase == AssistantPhase.listening ||
      _phase == AssistantPhase.transcribing ||
      _phase == AssistantPhase.speaking;
  double get recordSeconds => _recordSeconds;
  double get asrSeconds => _asrSeconds;

  /// First-word latency: seconds from the first reply block arriving to
  /// its first audio chunk — the dead air the user actually hears before
  /// the voice starts. (Was a cumulative synth-time sum; that number
  /// measured the machine, this one measures the wait.)
  double get ttsSeconds => _ttsSeconds;
  double get playSeconds => _reply.playSeconds;

  /// Exact audio the most recent ASR call consumed (VAD segment or gated PTT
  /// buffer) — what Whisper actually heard, for replay/diagnostics.
  Float32List? get asrAudio => _asrAudio;
  double get asrAudioSeconds =>
      _asrAudio == null ? 0 : _asrAudio!.length / _asrAudioRate;

  /// Exact audio the TTS engine last generated (reply or voice preview) —
  /// the raw engine output, before playback; for replay/diagnostics.
  Float32List? get lastTtsAudio => _reply.lastTtsAudio;
  double get lastTtsSeconds => _reply.lastTtsSeconds;

  // ── Latency strip moments (see HopTracker) ─────────────────────────────
  bool get hopAsr => _hops.hopAsr;
  bool get hopSent => _hops.hopSent;
  bool get hopReply => _hops.hopReply;
  bool get hopTts => _hops.hopTts;

  // ── Voice selection & cloning ───────────────────────────────────────────
  String _modelsDir = '';
  TtsPrefs _prefs = TtsPrefs();
  String _activeVoiceId = 'kokoro';
  int _ttsNumSpeakers = 0; // engine roster size; 0 = none loaded yet
  String _voiceStatus = ''; // one-line feedback for the voice screen
  bool _voiceBusy = false; // download / engine swap in progress

  List<TtsVoice> get voices => ttsVoices;
  String get modelsDir => _modelsDir;
  String get ttsVoiceId => _activeVoiceId;
  int get ttsSid => _prefs.sid;
  int get ttsNumSpeakers => _ttsNumSpeakers;
  String get voiceStatus => _voiceStatus;
  bool get voiceBusy => _voiceBusy;

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

  bool get benchCapturing => _benchCapturing;
  bool get benchBusy => _benchBusy;
  double get benchSeconds => _benchSeconds;
  String get benchNote => _benchNote;
  List<BenchRun> get benchRuns => List.unmodifiable(_benchRuns);

  /// Speaker-style names for the picker, from the active voice: the
  /// student roster is fixed (one graph per style), Kokoro's comes from
  /// the shipped sid→name table sized by what the engine reports.
  List<KokoroSpeaker> get ttsRoster {
    final v = voiceById(_activeVoiceId);
    return v?.staticRoster ?? kokoroRoster(_ttsNumSpeakers);
  }

  /// Label of the voice the bench echoes with (the one currently in use),
  /// named down to the speaker style when the engine has a roster.
  String get benchVoiceLabel {
    for (final v in voices) {
      if (v.id == _activeVoiceId) {
        if (_ttsNumSpeakers > 1) {
          for (final s in ttsRoster) {
            if (s.sid == _prefs.sid) return '${v.label} · ${s.name}';
          }
        }
        return v.label;
      }
    }
    return 'current voice';
  }

  // ── Claude Code bridge (src/bridge/, docs/claude-code-bridge.md) ───────
  BridgePrefs _bridgePrefs = BridgePrefs();
  HarnessGateway? _gateway;
  // ── Bridge-turn truth (owned by TurnCoordinator — see turn_session.dart) ──
  // This class only READS the truth (below) and fires the coordinator's
  // named transitions; the old raw fields' meaning now lives on those
  // methods' docs. What each getter answers:
  late final TurnCoordinator _turn;

  /// A bridge turn is in flight (chips disabled).
  bool get _bridgeBusy => _turn.busy;

  /// A turn the phone detached keeps working on the bridge with no ear
  /// on it: the terminal badge stays lit until a heard turn starts,
  /// /stop lands, or /new resets it.
  bool get _harnessBackgrounded => _turn.backgrounded;

  /// Wall clock the in-flight bridge turn started.
  DateTime? get _harnessSince => _turn.since;

  /// Busy-flag ownership token (turns claim it via the coordinator).
  int get _bridgeTurnSeq => _turn.seq;

  /// Cancels in-flight responses when bumped (via [TurnCoordinator.supersede]).
  int get _generation => _turn.generation;

  /// What the harness is doing OUT OF EARSHOT — the bottom line's
  /// snapshot, fed by [TurnCoordinator.detach] and [TurnCoordinator.noteToolStep].
  String get _bgWork => _turn.bgWork;
  // ── Stream reattach: surviving a background→foreground blink ──────────
  // The quiet-wire lease lives in [WireLease]; the retry ladder exists
  // here because waking phones wake their NETWORK late: one failed
  // probe must never drop a live turn.
  Timer? _reattachTimer; // next probe of the retry chain
  int _reattachStep = 0; // ladder rungs spent on the current orphan
  bool _reattachRetire =
      false; // chain end = retire the spinner (zombie hop failed)
  int _reattachGen = -1,
      _reattachSeq = -1; // the orphaned turn a chain belongs to

  // Screenshot-able event ring for barge-in/edge forensics: every worker
  // diagnostic note that matters (barge-in candidates), chunk seams, and
  // mic lifecycle, newest last. See the debug view.
  final List<String> _debugLog = [];
  List<String> get debugLog => _debugLog;
  // ── Phone-side journal (src/journal/) — the same notes mirrored
  // to disk AND served over HTTP for the bridge to poll: the desktop half
  // of "background → foreground and nothing happened" triage needs the
  // phone's OWN account of hide/resume/stream-death timing, in the same
  // journalctl the bridge's relays land in. Started in init(); null until
  // the models dir (its home) exists, and survivably null after if the
  // bind failed — the app never needs its own journal to function.
  AppEventJournal? _events;
  int _eventsPort = 0; // what /health & friends announce; 0 = not served
  void _logDebug(String what, {bool toJournal = true}) {
    final t = _clock();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    _debugLog.add('$hh:$mm:$ss $what');
    while (_debugLog.length > 80) {
      _debugLog.removeAt(0);
    }
    if (toJournal) unawaited(_events?.log(what));
    notifyListeners();
  }

  /// main.dart routes every OS lifecycle callback here BEFORE the folding
  /// (hidden+paused+detached all collapse onto pauseConversation) — the
  /// raw sequence is exactly what stream-reattach triage needs: e.g. the
  /// SECOND hidden that fires on the way back up, and which event wins
  /// the race against a dead socket's error delivery. The flag snapshot
  /// on each line says what the app BELIEVED at that instant.
  void logLifecycle(String state) => _logDebug(
    'lifecycle $state: busy=$_bridgeBusy hidden=$_backgrounded '
    'detached=$_harnessBackgrounded phase=${_phase.name} '
    'gen=$_generation seq=$_bridgeTurnSeq',
  );

  /// Live state shipped in every journal response: reading the events is
  /// one thing, knowing what the app currently believes is the other.
  Map<String, Object> _journalFlags() => {
    'phase': _phase.name,
    'mode': _mode.name,
    'bridgeBusy': _bridgeBusy,
    'hidden': _backgrounded,
    'harnessDetached': _harnessBackgrounded,
    'gen': _generation,
    'turnSeq': _bridgeTurnSeq,
    'wireQuietMs': _lease.quietFor.inMilliseconds,
    'reattachStep': _reattachStep,
    'micOpen': _mic.isOpen,
    'playerPlaying': _reply.playing,
    'replyQueued': _reply.queuedCount,
    'bench': _benchBusy || _benchCapturing,
    'workerReady': _worker != null,
  };

  /// What the phone looks like from the network — logged once at startup
  /// so triage can match the bridge's learned peer address to an
  /// interface (tailscale 100.x vs LAN) without guesswork.
  static Future<String> _ifaceIps() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final i in ifs)
          for (final a in i.addresses) '${a.address}/${i.name}',
      ].join(' ');
    } on Object {
      return 'ips?';
    }
  }

  // ── The conversation (see ChatStore) ───────────────────────────────────
  List<ChatEntry> get chat => _chat.entries;
  int get chatVersion => _chat.version;
  ChatEntry? get queuedBubble => _chat.queuedBubble;
  String? get queuedText => _chat.queuedText;

  /// The bubble carrying the in-flight working line. Delegates to
  /// [liveTurnFor] so the mapping is unit-guarded: a queued pin
  /// pressed over live work must not drop the spinner — the background
  /// turn keeps working, and (+91) now keeps showing.
  ChatEntry? get liveTurnBubble =>
      _chat.liveTurn(turnRunning: bridgeBusy || harnessBackgrounded);

  String get _chatPath => p.join(_modelsDir, 'chat_log.json');

  Future<void> _persistChat(String json) async {
    if (_modelsDir.isEmpty) return;
    try {
      await File(_chatPath).writeAsString(json);
    } catch (_) {} // chat history must never break a conversation
  }

  void _loadChat() {
    try {
      _chat.load(File(_chatPath).readAsStringSync());
    } catch (_) {} // first run (or unreadable): fresh log
  }

  // ── Bridge config API (settings UI in bridge_screen.dart) ──────────────
  bool get bridgeConfigured => _gateway != null;
  bool get bridgeBusy => _bridgeBusy;
  bool get harnessBackgrounded => _harnessBackgrounded;

  /// The persistent bottom line's label: the last real tool step the
  /// out-of-earshot work attested to, and ONLY while a line is actually
  /// warranted — the badge (detached turn still working) or the queue
  /// pin (a press parked behind that work). Every completion path
  /// clears one of those two, so the empty string IS the auto-dismiss:
  /// /stop, an orphan retire, a health probe that finds nothing open,
  /// or the 'started' pickup ack proving the tool finished.
  String get backgroundedWork =>
      _harnessBackgrounded || _chat.queuedBubble != null ? _bgWork : '';

  /// Start of the backgrounded turn (epoch ms, 0 = unknown) for the
  /// bottom line's 'since HH:MM:SS'; its live age is [harnessElapsed].
  int get harnessSinceMs =>
      _harnessSince == null ? 0 : _harnessSince!.millisecondsSinceEpoch;

  /// How long the in-flight bridge turn has been working (zero when idle):
  /// the elapsed readout on the chat window's Claude Code-style spinner.
  Duration get harnessElapsed => _harnessSince == null
      ? Duration.zero
      : _clock().difference(_harnessSince!);
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
  double get contextFrac =>
      _contextWindow > 0 ? (_contextIn / _contextWindow).clamp(0.0, 1.0) : 0;

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
    final h = await _gateway?.healthInfo();
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

  // ── Live token ticker API (see TokenTicker) ────────────────────────────
  bool get tokenTickerOn => _ticker.isOn;
  String get tokenThought => _ticker.thought;
  String get tokenDraft => _ticker.draft;
  bool get turnSettled => _ticker.settled;
  String get activityLabel => _ticker.activityLabel(_status);
  String get tokenTickerLabel => _ticker.label;
  int get tokensOut => _ticker.tokensOut;
  int get tokensIn => _ticker.tokensIn;

  /// 'Speak to Claude Code' switch: when on, PTT/conversation utterances
  /// go to the harness instead of being repeated back.
  Future<void> setBridgeVoice(bool on) async {
    _bridgePrefs.voice = on;
    await _saveBridgePrefs();
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
    await _saveBridgePrefs();
    notifyListeners();
  }

  /// Prefs live in the models dir — a toggle flipped before init
  /// finished (or in tests) flips the in-memory pref without a disk
  /// write, rather than littering the process's cwd.
  Future<void> _saveBridgePrefs() => _modelsDir.isEmpty
      ? Future.value()
      : saveBridgePrefs(_modelsDir, _bridgePrefs);

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
    _rebuildGateway();
    _sessionId = null; // the old bridge's pointer is not this bridge's
    unawaited(_refreshSession());
    await _saveBridgePrefs();
    notifyListeners();
  }

  void _rebuildGateway() {
    _gateway = _bridgePrefs.configured
        ? (_gatewayFactory?.call(_bridgePrefs.url, _bridgePrefs.token) ??
              BridgeClient(_bridgePrefs.url, _bridgePrefs.token))
        : null;
    // Every request the app makes then announces where the bridge may
    // poll the phone's side of the story (see src/journal/).
    _gateway?.journalPort = () => _eventsPort;
  }

  /// Probes /health for the settings screen: null = alive and healthy.
  Future<String?> bridgeCheck() async =>
      _gateway?.health() ?? 'bridge not configured — set url and token';

  /// The bridge's raw /health payload (sessionId, claudeUp, turnOpen…) for
  /// the Bridge screen's session row; null when unreachable or unconfigured.
  /// One session serves every utterance (see claude_bridge.mjs: the id is
  /// persisted and --resume'd across restarts), so this is the fingerprint
  /// that proves two talks shared a brain — or, once it changes, that
  /// /new or a respawn moved the conversation onto a new one.
  Future<Map<String, Object>?> bridgeHealth() async =>
      await _gateway?.healthInfo();

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
    final gateway = _gateway;
    if (gateway == null) {
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
    // A prompt that goes behind a HEARD live turn wears the pin until
    // the harness starts on it — the queue exists to protect an answer
    // the ear is holding. A prompt that goes behind a turn already OUT
    // OF EARSHOT (the badge alone; +126 field report) protects nothing:
    // the press shows in the flow right away and the bottom line keeps
    // carrying the wait. Capture both verdicts before the abandon,
    // which clears _bridgeBusy and would launder an audible detach into
    // a silent continuation.
    final detachedContinuation = _harnessBackgrounded && !_bridgeBusy;
    final queuedBehindLiveTurn = !interrupt && _bridgeBusy;
    _turn.supersede();
    _turn.detach(TurnTrigger.newUtterance);
    if (_worker == null) {
      _fail('Models are still loading — try again in a moment.');
      return;
    }
    if (bubble != null && bubble.trim().isNotEmpty) {
      _chat.addUser(bubble.trim(), queued: queuedBehindLiveTurn);
    }
    // One assistant bubble for the whole turn, sections appended as each
    // say's audio queues (text follows the voice, never leads it). An
    // interrupted turn keeps the sections actually spoken — that IS what
    // the conversation was. A turn that never spoke is removed at the end.
    final turn = _chat.beginTurn();
    final gen = _turn.supersede(); // supersedes any in-flight voice reply
    _reply.stopPlayback(); // cut the current audio, like the voice preview does
    final mySeq = _turn.claimSlot(); // claim the busy flag for this turn
    // A heard turn clears the badge; a detached continuation keeps it —
    // the tool really is still running unheard, and the pickup ack (or
    // /stop, or a nothing-open probe) is what proves it closed. The age
    // clock counts the WORK, not the latest press: re-anchor only when
    // this very turn becomes the ear.
    if (!detachedContinuation) {
      _turn.becomeHeard(); // this turn is heard, not invisible
    }
    // This utterance supersedes whatever a reattach chain was about to
    // re-hear: its own stream is the ear now, and a chain attach landing
    // later would steal the view from the QUEUED turn the bridge is
    // about to hand this very /talk.
    _cancelReattachChain();
    _error = '';
    _transcript = utterance;
    _phase = AssistantPhase.transcribing;
    _status = status ?? 'Asking the bridge…';
    _ticker.resetForTurn();
    notifyListeners();
    _reply.warmUpRoute(); // hold the output route while the harness thinks
    _reply.startStream();
    _ttsSeconds = 0; // the strip tallies per turn: reset, then the
    _ttsFirstTimed = false; // first spoken block stamps the tts number
    _reply.playSeconds = 0; // once (first-word latency) and play time accrues
    _dropAfterHide = null; // a fresh turn buries any hide-marked paragraph
    _startPump(gen);
    final spoken = StringBuffer();
    // ── Progress narration ── the rules (8 s reply outrank, 45 s
    // heartbeat) live in NarrationGate; this loop just consults it at
    // every step event and on the 15 s pulse below. Progress lines ride
    // the same speak() path — heard, and logged as bubble blocks:
    // text-follows-audio, history being exactly what the room heard.
    String latestWork =
        ''; // newest tool-step progress line, e.g. 'Edit foo.dart…'
    // +114: what this turn committed to the ledger, and which of those
    // paragraphs ever had audio START. A wire death retracts the
    // unheard commits (see the finally) so a block in the ledger means
    // HEARD — the replay dedup leans entirely on that promise.
    final committed = <String>[];
    final aired = <String>{};
    // Speak one answer block end-to-end. +116 returns to the owner's
    // exact words — 'mark it when it STARTS speaking': the ledger write
    // lands at the first audio chunk, the moment sound genuinely begins
    // (not merely enqueues). +109's enqueue-time write fed the ledger
    // lies a process death could not take back: an APK swap between
    // commit and first chunk left a persisted block for words that
    // never sounded, and every later replay skipped them as 'already
    // heard' (two field reports on the install). The double-voice race
    // +109 was built for is covered INSTEAD by the in-flight set below:
    // live in memory for the live process, gone with a dead one — the
    // honest half of the ledger's truth. Until air, the bubble shows
    // the draft tail the tally frames already carry, so the screen
    // speaks no words the speaker has not said.
    Future<void> speak(String text) async {
      _narr.audioActivity(); // audio just became active: hush
      _lastReplyText = text;
      if (_backgrounded) {
        // App is hidden: keep drinking the harness's firehose but skip
        // synth and audio entirely (the speaker is gone anyway). The
        // block still lands like everywhere else — no audio is EXPECTED
        // while hidden, so a text stamp is not a lie — and the most
        // recent one is what [_speakResumedPending] speaks on resume.
        spoken.write('$text ');
        _chat.addBlock(turn, text);
        _resumeReplyText = text;
        return;
      }
      committed.add(text); // +114: audio-path commitment only — hidden
      // turns buffer their text on purpose and answer that accounting
      // with _speakResumedPending instead
      _inFlight.add(text); // +115: not heard UNTIL it airs
      await _reply.speakBlock(
        text,
        alive: () => gen == _generation,
        drop: () => text == _dropAfterHide, // hide cut this paragraph
        // mid-play: skip it whole — its chunks die here, no replay
        onAir: (sinceText) {
          aired.add(text); // +114: the ear has it, the ledger may keep it
          _inFlight.remove(text); // +115: the ledger is the truth from here
          // +116: the ledger stamp itself, at true first sound:
          spoken.write('$text ');
          _chat.addBlock(turn, text);
          _dropAfterHide = null; // this block's air outranks the mark
          _phase = AssistantPhase.speaking;
          _hops.tts(); // reply→audio hop crossed: the first chunk of a
          // spoken block is on its way to the ear.
          // No echo of the words being spoken here: the conversation
          // bubble already shows them. And no 'Speaking — tap to cut me
          // off' either (0.1.0+71): while the turn is open the strip
          // keeps naming the WORK in progress — which is what is
          // actually happening while the first sentence plays — and in
          // pure playback the whole line hides anyway.
          if (!_ttsFirstTimed) {
            _ttsFirstTimed = true;
            _ttsSeconds = sinceText.inMilliseconds / 1000.0;
          }
        },
      );
    }

    Future<void> narrateProgress(String line) async {
      _narr.narrated(line); // the gate dedups against the RAW line —
      // it's what latestWork repeats on the heartbeat, too
      // Same markdown/filename-dot cleaning the reply path gets: the
      // espeak fallback says the literal word 'period' for the dot in
      // 'pubspec.yaml', and progress lines are full of file names.
      await speak(cleanForSpeech(line));
    }

    bool narrateAllowed() => _narr.quiet(
      enabled: _bridgePrefs.narrate,
      backgrounded: _backgrounded,
      speaking: _phase == AssistantPhase.speaking,
      playing: _reply.playing,
    );

    final pump = BridgeTurnPump(
      beforeEvent: (ev) {
        _hops.reply(); // harness→reply hop crossed: bytes arrived
        // Push view: our stream is silent until the flush, so ANY
        // frame is the pickup. Poll view: the ring also carries the
        // turn we queued BEHIND — only the bridge's explicit 'started'
        // marker (tool branch below) may dissolve the pin there.
        // Pickup also proves whatever left the ear is CLOSED (the
        // bridge flushes only closed turns), so it retires the
        // backgrounded badge and re-anchors the age to our live turn.
        if (!_transport.turnViaPoll) {
          _chat.unpinQueued();
          _turn.heardPickup();
        }
      },
      isStale: () => gen != _generation,
      onEvent: (ev) async {
        if (ev.isSay && ev.text.trim().isNotEmpty) {
          _ticker.markSpoken(); // the answer closed and is being spoken;
          // nothing is generating to grow a counter over
          // Harness-generated text just crossed the wire: journal it
          // with its skew-corrected delivery age, so a delayed or
          // dropped paragraph shows up as a gap in this stamp trail.
          final said = ev.text.trim();
          _logDebug(
            'msg harness: say "${said.length > 48 ? '${said.substring(0, 48)}…' : said}"'
            '${_transport.wireTag(ev)}',
          );
          await speak(cleanForSpeech(said));
        } else if (ev.kind == 'context') {
          // message_start also moves the ticker's `in` number (the
          // context frame and the tally frame ride the same field).
          if (ev.inputTokens != _ticker.rawInputTokens) {
            _ticker.noteInputTokens(ev.inputTokens);
            notifyListeners();
          }
          // Live context consumption (message_start / post-result) for
          // the bar above the button — and the finally-block /health
          // re-read catches anything this stream never heard (a detached
          // turn updates lastCtx server-side regardless of the ear).
          _logDebug('bridge context ${ev.inputTokens}/${ev.contextWindow}');
          _mergeContext(ev.inputTokens, ev.contextWindow);
        } else if (ev.kind == 'tool') {
          if (ev.toolName == 'started') {
            // The queue's pickup ack (bridge +81): Claude Code has the
            // prompt NOW. Dissolve the pin, journal the hand-off — and
            // retire the backgrounded-work line: the tool it named is
            // done by definition (the bridge flushes only a closed
            // turn), so the bottom row has nothing left to promise.
            _chat.unpinQueued();
            _turn.heardPickup(); // the turn we waited behind is
            // closed; the spinner times ours now
            _logDebug(
              'queue picked up: "${ev.detail}"${_transport.wireTag(ev)}',
            );
            return;
          }
          if (ev.toolName == 'finished') {
            // The bridge's receipt for a turn that ended with NO ear on
            // it — backgrounded by a press, a hide, or a dead socket (a
            // heard turn's own done is its receipt; a turn cut for a
            // waiting prompt gets none, +106). It proves the
            // out-of-earshot work is OVER: the bottom line dismisses
            // itself. A live turn owns the slot here (this rides its
            // view as a ring/backlog replay), so the spinner's clock is
            // never touched — only the stale snapshot goes.
            _turn.clearBgWork();
            if (_harnessBackgrounded) _turn.retireBadgeAndWork();
            _logDebug(
              'backgrounded work finished '
              '(${ev.detail})${_transport.wireTag(ev)}',
            );
            notifyListeners();
            return;
          }
          final tally = ev.toolName == 'tokens';
          _logDebug(
            'bridge tool ${ev.toolName} ${ev.detail}${_transport.wireTag(ev)}',
            // Token tallies ride every ~0.8 s: fine for the on-screen ring,
            // but in the journal they would flush the 240-entry story of
            // the turn we're actually trying to troubleshoot.
            toJournal: !tally,
          );
          if (tally) {
            // Live token tally from the bridge ("thinking · 1.2k out ·
            // 21k in"): rewrites the spinner label only — latestWork (the
            // heartbeat narration) and the narrate gate stay untouched,
            // or the voice would ticker-tape a counter every relay.
            _ticker.onFrame(ev);
          } else {
            _ticker.markToolStep(); // a real step (Bash npm test…) froze
            // the counter: the estimate stopped being about live generation
            // 'queued' (from the bridge's talk()) gets the human wording:
            // the instant an utterance parks behind a running tool, the
            // phone says 'one moment' and what happens next, instead of
            // the old silent 200 seconds of spinner.
            final stepLine = ev.toolName == 'queued'
                ? 'One moment — ${ev.detail}.'
                : ev.toolName == 'Bash'
                // The command ITSELF on the spinner line (the bridge
                // truncates the relay), ellipsized to fit one line by
                // the widget — 'basename of a command line' was
                // mangling it into nonsense anyway. The VOICE still gets
                // its generic 'Running a command…' below.
                ? 'Bash ${ev.detail}…'
                : '${ev.toolName}'
                      '${ev.detail.isEmpty ? '' : ' ${p.basename(ev.detail)}'}…';
            _status = stepLine;
            if (ev.toolName != 'queued') {
              // The newest REAL step: what the bottom line names if this
              // turn leaves the ear now. Steps landing behind a queue
              // pin — or behind the badge, from the turn this prompt
              // queued after — belong to the backgrounded work they wait
              // on: keep that line current (the /attach loop already
              // did). Pure-plumbing steps still get label-only voice
              // treatment below (+73/+94): the eyes keep the full line.
              _turn.noteToolStep(stepLine);
            }
            // Pure-plumbing steps get label-only treatment: the eyes see
            // 'Read bridge.dart…', the ears get nothing — no immediate
            // narration AND no heartbeat line (latestWork stays empty so
            // the 15 s pulse has nothing to re-speak). +73 silenced Bash
            // and the web tools; +94 adds the file tools after the field
            // report named them: a Read or an Edit is plumbing, not news.
            // The list is stepIsSilentFor, unit-guarded; custom tools
            // stay speakable. Eyes keep the full line either way — for a
            // minute-long build the spinner IS the honest label of which
            // command is chewing.
            if (ev.toolName == 'queued') {
              // +99: the interrupt verdict is CONVERSATION, not a
              // caption — it stays through backgrounded builds,
              // reattach replays, and app restarts, where a spinner
              // line gets overwritten by the next frame. +110 gives it
              // its OWN bubble instead of a block inside whichever
              // turn happens to be open: the verdict is about the
              // interruption, not the answer, and it must not vanish
              // with (or pollute) either turn. Eyes-only, as ever.
              _chat.addSystemNote(stepLine);
              latestWork = '';
            } else {
              latestWork = stepIsSilentFor(ev.toolName) ? '' : stepLine;
            }
            // No step line in the conversation any more: the spinner's
            // working line (and the narration switch, for those who want
            // steps spoken) carry tool progress; the journal keeps every
            // step with its wire stamp. The chat log is for words.
            notifyListeners();
            if (_narr.wantStep(
              latestWork,
              enabled: _bridgePrefs.narrate,
              backgrounded: _backgrounded,
              speaking: _phase == AssistantPhase.speaking,
              playing: _reply.playing,
            )) {
              unawaited(narrateProgress(latestWork));
            }
          }
        } else if (ev.isDone) {
          if (ev.isError && gen == _generation) {
            _error = 'the harness reported an error';
          }
        } else if (ev.kind == 'error') {
          // a relayed bridge error IS the turn's end
          _fail('Bridge: ${ev.text}');
        }
      },
    );
    _turn.installPump(pump);
    _lease.armWatch(); // this connection is watched for quiet from here on
    _hops.sent(); // asr→harness hop crossed: the words are on the wire
    _logDebug(
      events == null
          ? 'TALK open: gen=$gen interrupt=${interrupt ? 1 : 0} '
                '"${utterance.length > 40 ? '${utterance.substring(0, 40)}…' : utterance}"'
          : 'CONTROL stream open (no /talk): $utterance',
    );
    // The long-silent-step heartbeat: while this turn still owns the
    // busy slot, every 15 s take the pulse — the gate hushes it around
    // any real audio, and a same-line repeat under 45 s old keeps one
    // long build to a steady 'still on it' cadence rather than a
    // stutter. Superseded turns (gen moved on) stop re-arming.
    Timer? pulse;
    void rearmPulse() {
      pulse = _scheduler.after(const Duration(seconds: 15), () {
        if (gen != _generation) return;
        if (latestWork.isEmpty || // the pulse only repeats WORK; there
            // is no news when no speakable step has been seen
            narrateAllowed() ||
            !_narr.wantHeartbeat(
              latestWork,
              enabled: _bridgePrefs.narrate,
              backgrounded: _backgrounded,
              speaking: _phase == AssistantPhase.speaking,
              playing: _reply.playing,
            )) {
          rearmPulse();
          return;
        }
        unawaited(narrateProgress(latestWork));
        rearmPulse();
      });
    }

    rearmPulse();
    var outcome = const PumpOutcome(
      stale: true,
      sawDone: false,
      sawErrorFrame: false,
      streamError: null,
      detached: false,
    );
    try {
      outcome = await pump.run(
        events?.call() ??
            _transport.turn(
              gateway,
              utterance,
              interrupt,
              onActivity: _lease.markAlive,
            ),
      );
      final err = outcome.streamError;
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
      pulse?.cancel(); // no pulse outliving its turn
      // The pointer may have moved during this turn (a death-resume
      // forks; /new cleared it): re-read it after the bridge's result
      // event has written the sid file, so every exit path of every
      // bridge turn leaves the top-row id current.
      unawaited(_refreshSession());
      // Only release the shared detach slots if they still belong to US:
      // an abandoned turn may be cleaned up after a successor turn (from
      // the voice barge-in it just triggered) has already installed its
      // own subscription and wake hook.
      final stillOurs = _turn.releasePumpIf(pump);
      // Did this turn die UNOWNED — the socket errored or hit EOF with no
      // `done` and no bridge `error`? Compute while still holding the busy
      // flag: a barge-in / stop / new-prompt detach went through
      // _turn.detach first (busy already cleared: the user CHOSE
      // that exit), and the /new chip's custom stream never had a /talk
      // connection to rejoin. An unowned death means the turn is likely
      // still alive on the bridge: the reattach chain below goes get it.
      final wireOrphan =
          events == null &&
          outcome.closedWithoutDone &&
          !outcome.detached &&
          _bridgeBusy &&
          _bridgeTurnSeq == mySeq &&
          gen == _generation;
      if (stillOurs) _lease.cancel(); // the watchdog dies with its stream
      // Release the busy slot only if we still own it — a superseded
      // turn must not stomp a new owner's state, and a SOFT detach
      // keeps the elapsed clock (+126; see TurnCoordinator.releaseOwnership).
      _turn.releaseOwnership(mySeq);
      // +108: a turn superseded by the user's own newer press died
      // mid-answer — stamp the bubble so the visualization admits it
      // (see ChatEntry.interrupted). A merely DETACHED turn is NOT
      // stamped: it is still running, and a reattach may deliver its
      // real done. An empty dead turn gets removed below either way.
      // +114: a wire that died mid-turn owes the user nothing it never
      // got to say. Every paragraph committed but never aired comes OUT
      // of the ledger: the bubble mirrors the ear, and the bridge's
      // always-kept replay copy (+114 bridge) can voice it honestly to
      // the next view instead of being deduped against a fake "heard".
      if (!outcome.sawDone) {
        for (final t in committed) {
          if (!aired.contains(t)) _chat.removeBlock(turn, t);
        }
      }
      _inFlight.removeAll(committed); // +115: this turn's flight is over
      if (!outcome.sawDone && gen != _generation) {
        // +110: a cut that never got to speak still leaves a bubble.
        // The interruption of a bare thinking run or a tool call used
        // to vanish with its empty turn — erasing the very event the
        // user's own press caused. One line, stamped, permanent.
        if (turn.isEmpty) {
          _chat.addBlock(turn, 'Interrupted before answering.');
        }
        _chat.markInterrupted(turn);
      }
      if (turn.isEmpty) _chat.removeEmptyTurn(turn);
      if (gen == _generation) {
        // Natural end of the current turn (done event / stream close /
        // error): tear down the streamed-player machinery here. An
        // abandoned turn had it torn down by _turn.detach already,
        // and a turn superseded by a barge-in successor must NOT close
        // the queue its successor's player loop is now feeding.
        _reply.closeStream();
        _turn.clearLastToolStep(); // the turn is over; its step labels are history
      }
      final said = spoken.toString().trim();
      if (said.isNotEmpty) _lastSpoken = said;
      // An interrupted turn no longer POSTs /stop here: every interrupt
      // site calls _turn.detach, and that decides — voice barge-in
      // DETACHES (the harness keeps working as a background turn, long
      // tools finish, the next prompt queues behind them), the stop-chip
      // adds a hard stop via its hardStop flag.
      if (gen == _generation && spoken.isEmpty && _error.isEmpty) {
        // (spoken, not sawFirstChunk: a turn answered entirely while
        // hidden buffered text without ever synthesising audio)
        _status = 'The harness ran, but had nothing to say.';
        _phase = AssistantPhase.idle;
      }
      notifyListeners();
      _logDebug(
        'TALK end gen=$gen: ${outcome.streamError != null
            ? 'SOCKET DIED (${outcome.streamError})'
            : outcome.sawErrorFrame
            ? 'bridge error frame'
            : outcome.sawDone
            ? 'done clean'
            : 'CLOSED WITHOUT DONE'}'
        '${wireOrphan
            ? ' — UNOWNED, reattach chain armed'
            : gen != _generation
            ? ' — superseded'
            : outcome.detached
            ? ' — detached on purpose'
            : outcome.sawDone
            ? ''
            : ' — closed by the server'}',
      );
      if (wireOrphan) {
        // Our view died mid-turn (the classic background→foreground
        // casualty: the hide killed the socket, the death event merely
        // arrived AFTER the resume callback had trusted _bridgeBusy).
        // The turn is the bridge's problem to finish and our problem to
        // rejoin: probe /health and reattach, retries and all.
        _reattachGen = gen;
        _reattachSeq = mySeq;
        _startReattachChain();
      } else {
        unawaited(_drainStrandedBacklog(gen, mySeq));
      }
    }
  }

  /// +111: the answered interruption. The user's press silenced the
  /// reattach chain, the bridge went on answering into the void, and
  /// the finished reply is stranded in the unheard backlog — the field
  /// report's "my message doesn't look like it's being processed", and
  /// the same frames that later burst back as yesterday's answer. At
  /// every turn's teardown, ask the bridge if it still holds frames;
  /// if it does, arm one reattach pass NOW: the replay path files
  /// archaeology silently by age and dedups against the commit-time
  /// ledger (+109), so draining can neither drown the user in old
  /// audio nor re-voice a paragraph already heard. Skipped under a
  /// live PTT hold (the mic owns the moment), while hidden (the resume
  /// probes cover it), and once a newer turn owns the wire (its own
  /// teardown drains then).
  Future<void> _drainStrandedBacklog(int gen, int mySeq) async {
    if (pttHoldActive || _backgrounded) return;
    final h = await _gateway?.healthInfo();
    if (h == null) return;
    final missed = (h['missed'] as num?)?.toInt() ?? 0;
    if (missed < 1) return;
    if (gen != _generation || _bridgeTurnSeq != mySeq) return;
    // +124: the field's last mid-word cut. The bridge's `missed` is the
    // backlog LENGTH — a replayable history that only the heard-dedup
    // filters — so this verdict fires at nearly every turn end, and it
    // fires while our own final paragraph is still on the speaker (the
    // wire finishes long before the voice does). The chain it armed
    // opens with stopPlayback: the drain cut a paragraph that was
    // never going to be re-voiced (the ledger already owns it), and
    // the listener heard the tail of the answer die at the spinner's
    // dismissal while the replay babbled on. Park the verdict instead:
    // _handleNaturalEnd re-runs it the moment the speaker is honestly
    // silent, and every guard (PTT, hidden, ownership, missed) is
    // re-checked then.
    if (_reply.playing) {
      _drainAfterSpeech = (gen: gen, mySeq: mySeq);
      _logDebug(
        'stranded backlog: missed=$missed — audio still on air; '
        'drain parked to the natural end',
      );
      return;
    }
    _drainAfterSpeech = null;
    _logDebug('stranded backlog: missed=$missed — draining via reattach');
    _reattachGen = gen;
    _reattachSeq = mySeq;
    _startReattachChain(retire: true, firstProbe: Duration.zero);
  }

  /// A drain verdict the teardown parked behind on-air audio (+124);
  /// consumed by [_handleNaturalEnd], superseded by any newer verdict.
  ({int gen, int mySeq})? _drainAfterSpeech;

  void _startPump(int gen) =>
      unawaited(_reply.runPump(isStale: () => gen != _generation));

  // Voice barge-in (or any takeover) while a harness turn is in flight
  // goes through TurnCoordinator.detach — THE funnel every trigger lands
  // in, with the detach-vs-hardStop policy decided once in takeoverStop.
  // The old inline helper (_abandonBridgeTurn) was exactly this funnel
  // with the flag matrix scattered around it; its semantics and their
  // reasons now live on the coordinator's methods (turn_session.dart).

  /// Stop chip / conversation-mode stop during a bridge turn: silence the
  /// speaker, hard-stop the harness's WORK (a /stop interrupt, not just
  /// detach), and
  /// leave the conversation usable — a follow-up utterance goes straight
  /// out, the interrupted session context carries over.
  void bridgeStop() {
    if (_turn.stopDetachedWork()) {
      _status = 'Stopped the harness — the detached turn was cut short.';
      notifyListeners();
    }
    if (!_bridgeBusy) return;
    _turn.supersede();
    _reply.stopPlayback();
    // Hard stop incl. the streamed-player teardown inside the funnel.
    _turn.detach(TurnTrigger.stopChip);
    _turn.retireBadge(); // nothing left working invisibly
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
        ack: 'Starting a new conversation.',
        events: () {
          _logDebug('bridge: new session');
          unawaited(_gateway?.reset());
          // The phone forgets too: the app's chat log is the other half
          // of a fresh start (the spoken ack stays brief; the wipe speaks
          // for itself on screen). Wipe memory and disk
          // so the screen goes blank exactly when the harness drops its
          // session — both bubbles this chip just added included; a
          // /new that leaves its own tombstone on screen is not blank.
          _chat.clearAll();
          // And the meter goes blank with the chat, not into a
          // monotonic decline from last week's number: /health will now
          // answer in:0 (the bridge cleared its snapshot), and
          // _mergeContext ignores zeros, so the reset has to happen
          // here. The first message_start of the new conversation puts
          // an honest number back on the bar.
          _contextIn = 0;
          _ticker.resetAll();
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

  // ── Lifecycle ───────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      final modelsDir = await unpackModels(onProgress: _modelProgress);
      _modelsDir = modelsDir;
      _prefs = await loadTtsPrefs(modelsDir);
      _bridgePrefs = await loadBridgePrefs(modelsDir);
      _loadChat(); // restore the on-screen conversation (file read is tiny)
      // The journal comes up BEFORE anything else can go wrong, and it
      // loads its disk mirror first: when Android killed this process
      // mid-turn last time, the events leading up to the kill — and the
      // reattach that (didn't) happen after — are exactly what a poll
      // from the desktop should find waiting.
      final j = AppEventJournal(dir: modelsDir);
      await j.load();
      _events = j;
      _eventsPort = await j.serve(
        preferredPort: kAppLogDefaultPort,
        tokenProvider: () => _bridgePrefs.token,
        flagsProvider: _journalFlags,
      );
      final carried = j.seq > 0
          ? ' — carried over $j.seq events across the process gap'
          : '';
      await j.log(
        'app start: journal ${_eventsPort > 0 ? 'on :$_eventsPort' : 'BIND '
                  'FAILED'} (${await _ifaceIps()})$carried',
      );
      // PUSH transport: the journal rides an ordinary outbound POST /applog
      // (batched, acked, backoffed — all handled inside the journal; this
      // closure is just the wire). Push exists because phones are hard to
      // dial: Android tailscale refuses inbound and carrier NAT has no
      // route — while this exact outbound path already carries every
      // turn. The pull server above stays up for dialable dev peers.
      j.transport = (env) async {
        final g = _gateway;
        return g != null && await g.pushJournal(env);
      };
      unawaited(j.flushNow()); // a reloaded mirror may still hold events
      // the dying process never managed to deliver
      _rebuildGateway();
      unawaited(_refreshSession()); // chat-screen top row knows the id
      // The saved voice must be fully on disk (pack present); otherwise
      // fall back to the default, which downloads on first run just like
      // before.
      var voice = voiceById(_prefs.voiceId) ?? voiceById('kokoro')!;
      if (!await voice.installedIn(modelsDir)) {
        voice = voiceById('kokoro')!;
      }
      _prefs.voiceId = voice.id;
      // Only the saved style's graph for student rosters — the rest
      // download on pick, like every other pack here.
      await voice.ensureIn(
        modelsDir,
        onProgress: _modelProgress,
        sid: _prefs.sid,
      );
      _worker = await SpeechWorker.start(
        ModelPaths.fromModelsDir(modelsDir),
        tts: await _spec(voice, sid: _prefs.sid),
        onEvent: _onSpeechEvent,
        endpointSilence: _endpointSilence,
      );
      // The engine loaded at start carries its own roster size: Kokoro
      // must show its style picker on a cold launch, not only after the
      // first useTts (the old slider hid itself exactly the same way).
      _ttsNumSpeakers = _worker!.ttsNumSpeakers;
      _activeVoiceId = voice.id;
      _idleReady();
      // +120: open the output route AT LAUNCH, once, before any press
      // exists to race it (see ReplyPipeline.warmUpRoute).
      _reply.warmUpRoute();
      // Cold start while a turn runs (or just finished) on the bridge —
      // Android killed the process mid-turn: adopt it. Nothing to do when
      // the bridge has nothing open; the health gate inside decides. If
      // the bridge cannot be reached AT ALL the chain keeps re-probing
      // with backoff — a phone that woke its network late (Tailscale
      // re-handshakes after sleep) must not silently lose a live turn.
      unawaited(() async {
        if (!await reattachBackgroundTurn()) _startReattachChain();
      }());
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

  // ── Voice selection & cloning ──────────────────────────────────────────

  Future<TtsSpec> _spec(TtsVoice v, {int sid = 0}) =>
      v.specIn(_modelsDir, sid: sid);

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
    // A different voice starts at style 0: student sids are pack
    // indexes, Kokoro sids are style embeddings — the numbers mean
    // nothing across engines. Same-voice calls keep the picked sid.
    final newSid = sid < 0 ? (id == _activeVoiceId ? _prefs.sid : 0) : sid;
    if (!force && id == _activeVoiceId && newSid == _prefs.sid) return;
    _voiceBusy = true;
    _voiceStatus = 'Setting up ${v.label}…';
    notifyListeners();
    try {
      // Student rosters download only the picked style's graph (9 MB
      // each); single-pack voices just download their one pack.
      await v.ensureIn(_modelsDir, onProgress: _voiceProgress, sid: newSid);
      _ttsNumSpeakers = await _worker!.useTts(await _spec(v, sid: newSid));
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

  /// Synthesize + play a demo line with the *current* engine (no phase
  /// changes; the gate is pinned so a hot mic cannot hear it as speech).
  /// [sid] tries one speaker style without committing to it.
  Future<void> previewVoice({String? text, int? sid}) async {
    if (_worker == null || _voiceBusy) return;
    final line =
        text ?? 'Hi! This is how your assistant will sound with this voice.';
    _voiceBusy = true;
    _voiceStatus = 'Making the preview…';
    _reply.stopDebug();
    _reply
        .stopPlayback(); // a live reply would fight the preview for the speaker
    notifyListeners();
    try {
      _worker!.setPlaying(true); // hard-mode gate while we hear ourselves
      _status = '';
      notifyListeners();
      // playOnce treats it like a reply for stop/barge-in bookkeeping
      // (but keeps the phase — the screen's buttons must not change while
      // it plays) and hands the raw audio back for debug replay.
      await _reply.playOnce(line, sid: sid);
      _voiceStatus = '';
    } catch (e) {
      _voiceStatus = 'Preview failed: $e';
    } finally {
      _worker?.setPlaying(false);
      _voiceBusy = false;
      notifyListeners();
    }
  }

  // ── Latency bench (voice screen panel) ─────────────────────────────────

  /// Start a bench recording: takes the mic (whatever capture it displaces
  /// resumes when the run ends) — the buffer feeds the timed echo turn.
  /// Release with [finishBenchCapture]; a lost release auto-closes at 20 s.
  Future<void> benchDown() async {
    if (_worker == null || _benchCapturing || _voiceBusy) {
      return;
    }
    _captureResumeOnDone = _micStreamWanted;
    _turn.supersede(); // abandon any in-flight reply turn
    _turn.detach(
      TurnTrigger.benchStart,
    ); // bench timing can't share the harness
    _shutdownAudio();
    _benchChunks.clear();
    _benchSeconds = 0;
    _benchFirstAudioMs = 0;
    _benchT0 = null;
    _benchCapturing = true; // the mic route feeds the bench buffer
    _phase = AssistantPhase.listening;
    _error = '';
    _status = 'Bench listening… release when done.';
    void tick() {
      if (!_benchCapturing) return;
      _status = 'Bench listening… ${_benchSeconds.toStringAsFixed(1)}s';
      notifyListeners();
      _benchTimer = _scheduler.after(const Duration(milliseconds: 250), tick);
    }

    _benchTimer = _scheduler.after(const Duration(milliseconds: 250), tick);
    notifyListeners();
    try {
      await _mic.open(); // watchdog-protected capture path
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
    await _mic.close();
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
    _reply
        .warmUpRoute(); // the route rides the wait exactly like a real PTT turn
    _benchNote = 'Transcribing…';
    notifyListeners();
    final gen = _generation; // stays ours unless a newer turn supersedes it
    try {
      final text = (await _worker!.transcribe(pcm, 16000)).trim();
      final asrMs = _benchT0!.elapsedMilliseconds;
      if (text.isEmpty) throw StateError("Didn't catch that — try again?");
      _benchNote = 'Synthesising the echo…';
      _status = '';
      notifyListeners();
      final swTts = Stopwatch()..start();
      _reply.startStream();
      var sawFirstChunk = false;
      final playTask = _reply.runPump(isStale: () => gen != _generation);
      await _reply.speakBlock(
        text,
        alive: () => gen == _generation,
        onAir: (_) {
          // [_benchFirstAudioMs] itself is stamped in the pipeline's
          // audible hook: the honest figure is when the PLAYER got the
          // bytes, not when we queued them (the temp-wav write in
          // between is real latency the user hears as dead air).
          if (sawFirstChunk) return;
          sawFirstChunk = true;
          _phase = AssistantPhase.speaking;
          _status = 'Echoing: “$text”';
          notifyListeners();
        },
      );
      swTts.stop();
      _ttsSeconds =
          swTts.elapsedMilliseconds / 1000.0; // keeps the strip honest
      final secs = _reply.lastTtsAudio!.length / 24000.0;
      _reply.closeStream();
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
      _reply.closeStream();
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
      unawaited(_mic.close());
      _phase = AssistantPhase.idle;
      notifyListeners();
    } else {
      _shutdownAudio();
      _turn.supersede(); // abandon any in-flight voice turn
      _turn.detach(TurnTrigger.modeSwitch);
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
      _logDebug(
        'pause IGNORED (already hidden — the double event on the way up)',
      );
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
    // remaining says keep flowing into speak()'s backgrounded branch. A
    // paragraph that was AUDIBLE when the hide cut it is deliberately not
    // seeded into the resume buffer — the old behavior replayed the whole
    // half-heard paragraph on the way back, which reads as amnesia. It is
    // marked for complete silence instead: the chunk guards drop its
    // remaining synthesised chunks, the resume paths find no pending text,
    // and a later reattach dedup already bows out on the chat-log copy.
    // Only says that landed UNHEARD while hidden (backgrounded speak())
    // earn the "speak the last one when you're back" promise.
    final bridgeLive = _bridgeBusy;
    _logDebug(
      'HIDE: busy=$bridgeLive micLive=$live phase=${_phase.name} '
      'queue=${_reply.queuedCount} — '
      '${bridgeLive ? 'stream STAYS attached' : 'audio/mic down'}',
    );
    if (bridgeLive &&
        _phase == AssistantPhase.speaking &&
        _lastReplyText != null) {
      _dropAfterHide = _lastReplyText;
      _logDebug('hide mid-paragraph: the cut block is skipped, not replayed');
    }
    // Snapshot the spinner's working line before the status below overwrites
    // it with the "when you're back" notice: [resumeConversation] puts it
    // back so a background/foreground blink is invisible to the turn.
    if (bridgeLive) _pausedWorking = _status;
    _conversationWasLive = live;
    _backgrounded = true;
    if (!bridgeLive) _turn.supersede(); // no talking to an empty app
    _shutdownAudio();
    _phase = AssistantPhase.idle;
    _status = bridgeLive
        ? "Working in the background — I'll show every reply and speak "
              "the last one when you're back."
        : live
        ? "Paused — I'll resume when you're back."
        : _mode == InteractionMode.conversation
        ? "Tap the mic to start a conversation. Pause about a second and I'll answer."
        : 'Ready. Hold the button, speak, release to send.';
    // Push the HIDE record NOW, bypassing the debounce: within seconds
    // the OS may freeze this isolate, and the timer that would otherwise
    // deliver it is exactly what dies first. Freeze windows are measured
    // by push timestamps — the hide/resume pair IS the record.
    unawaited(_events?.flushNow());
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
    _logDebug(
      'RESUME: busy=$_bridgeBusy replay=${pending != null} '
      'spinner=${working != null} relisten=$restart',
    );
    unawaited(_events?.flushNow()); // this half of the freeze-window
    // bracket, out as soon as the (just-woken) network will have it; a
    // failure re-arms inside the journal at the slow cadence
    if (_bridgeBusy) {
      // Still streaming as we return. Put the working line back — the
      // spinner and its elapsed readout must carry through a background
      // blink as if it never happened, not sit there quoting the "when
      // you're back" notice while we ARE back. (Transcribing rather than
      // the snapshot's possible speaking phase: hide cut any audible
      // chunk, so "working" is the honest state until audible audio
      // flips it to speaking for real.)
      if (working != null) {
        _status = working;
        _phase = AssistantPhase.transcribing;
      }
      // The hide's stopPlayback kills the queue pump at its seam (and
      // mid-play it died on the cleared field's null check — see
      // [ReplyPipeline.runPump]'s captured seam). Without a live pump the
      // survived turn would stream as text-only forever: respawn it, and
      // only when none runs (a pump parked on the wake hook must not get
      // a twin competing for the chunk queue).
      if (!_reply.pumpAlive) _startPump(_generation);
      // Keep the hide's promise ("I'll show every reply and speak the
      // last one when you're back"): says that landed DURING the hide
      // were logged text-only — the backgrounded branch of speak() skips
      // synth entirely — and if one of those was the turn's answer, it
      // would otherwise never get a voice (the next say, if any, is
      // audible from here on; the answer usually IS the last say, and
      // `done` closes the turn right behind it). [_speakResumedPending]
      // synthesises it into the queue this pump just revived, under the
      // live turn's generation — no supersede, no orphaned turn.
      if (pending != null && _worker != null) {
        unawaited(_speakResumedPending(pending, _generation));
      }
      // Re-lease the quiet-wire watchdog for the stream we're trusting to
      // have survived the hide. If it's alive, the kernel's buffered
      // events (and the 15 s pings) burst in within moments and keep
      // renewing the lease. If it died, its error/close event lands a beat
      // later and the teardown hook chains a reattach; if it died SILENTLY
      // (black-holed route — no event ever lands), this watchdog fires at
      // 24 s of silence, hops us to a fresh /attach view, and the replay
      // backlog covers whatever the zombie lost. A background/foreground
      // blink therefore never strands a running turn on a dead socket.
      _lease.markAlive();
      _logDebug(
        'resume: view believed ALIVE — wire watchdog re-leased (24 s '
        'of silence will expose a zombie and hop to a fresh /attach)',
      );
      notifyListeners();
      if (restart) unawaited(_beginConversation());
      return;
    }
    // A stream that DIED while hidden (process death, OS-dropped socket)
    // is the one state the branch below cannot restore: the turn ran on
    // unheard, and what it said AFTER the drop sits in the bridge's
    // backlog. Reattach with the buffered reply in hand: the backlog
    // never re-delivers what the dead view already received, so without
    // this the last heard-of-but-unspoken block would go to the grave in
    // text-only (reattach's gen bump supersedes any replay we'd run
    // ourselves — the text rides into the reattach instead, spoken
    // ahead of the backlog lines so the story stays in order).
    final Map<String, Object>? probe = _gateway == null
        ? null
        : await _gateway!.healthInfo();
    _logDebug('resume probe: ${_transport.noteHealth(probe)}');
    if (await reattachBackgroundTurn(health: probe, replayFirst: pending)) {
      return;
    }
    if (bridgeReattachNeeded(probe) != false) {
      // Unreachable (null): cannot tell "no turn" from "network still
      // waking up around a live turn" — the chain re-probes with backoff
      // instead of dropping it. A true verdict that the reattach itself
      // declined (bench or a fast re-hide raced it) rides the same ladder.
      _reattachGen = _generation;
      _reattachSeq = _bridgeTurnSeq;
      _startReattachChain();
    }
    if (pending != null && _worker != null) {
      unawaited(_replayPendingReply(pending, thenListen: restart));
      return;
    }
    if (!restart) return;
    unawaited(_beginConversation());
  }

  /// A bridge turn still wants hearing but our view of it died: probe
  /// /health NOW, and where the answer cannot be told (bridge
  /// unreachable — the waking network is usually still re-building its
  /// tunnel), re-probe up the [kReattachDelays] ladder, ~63 s in all.
  /// [retire] marks a chain born from a ZOMBIE stream: a definite
  /// "nothing open, nothing unheard" verdict (or a spent ladder) must
  /// also retire the spinner the dead view was still pretending to watch.
  /// [firstProbe] delays the first probe — used when the chain is born
  /// from a REATTACHED stream dying again, so a flaky link pays backoff
  /// between attach attempts instead of request-looping at RTT pace.
  void _startReattachChain({
    bool retire = false,
    bool resetStep = true,
    Duration? firstProbe,
  }) {
    if (_gateway == null || _worker == null) return;
    if (resetStep) _reattachStep = 0;
    _reattachRetire = retire || _reattachRetire;
    _reattachTimer?.cancel();
    _reattachTimer = null;
    if (firstProbe != null) {
      _reattachTimer = _scheduler.after(firstProbe, _reattachPump);
      return;
    }
    unawaited(_reattachPump());
  }

  void _cancelReattachChain() {
    _reattachTimer?.cancel();
    _reattachTimer = null;
    _reattachStep = 0;
    _reattachRetire = false;
  }

  /// The quiet-wire watchdog verdict ([WireLease] fired): a listening
  /// socket that has delivered not one byte — no events, no 15 s pings —
  /// for a full quiet window while we believe we're attached is a ZOMBIE:
  /// the route died quietly (Wi-Fi handoff, deep sleep, tailnet re-key)
  /// and no FIN or RST will ever arrive to tell us. Stop reading it, and
  /// let the reattach chain take a fresh view before the harness relays
  /// more of the turn into the void.
  void _wireQuietFired(Duration quiet) {
    _logDebug('bridge wire quiet ${quiet.inSeconds}s: presumed dead socket');
    _reattachGen = _generation;
    _reattachSeq = _bridgeTurnSeq;
    _turn.detach(TurnTrigger.zombieWire); // give up on the zombie view (parked loop retires
    // exactly as any abandoned turn's does — see its docs)
    _startReattachChain(retire: true);
    _logDebug(
      'zombie hop: /attach will STEAL the bridge view back; spinner '
      'retires if the probe says nothing is open any more',
    );
  }

  Future<void> _reattachPump() async {
    _reattachTimer = null;
    final gateway = _gateway;
    if (gateway == null || _worker == null || _bridgeBusy) return;
    final probe = await gateway.healthInfo();
    if (_bridgeBusy) return; // a resume or a chip attached while we probed
    final need = bridgeReattachNeeded(probe);
    final verdict = need == null
        ? 'UNREACHABLE (network may still be waking), will retry'
        : need
        ? 'ATTACH'
        : 'nothing open, nothing unheard: go idle';
    _logDebug(
      'reattach probe ${_reattachStep + 1}/${kReattachDelays.length + 1}: '
      '${_transport.noteHealth(probe)} → $verdict',
    );
    if (need == false) {
      _retireOrphanTurn(); // definite verdict: nothing left to hear
      return;
    }
    if (need == true) {
      if (await reattachBackgroundTurn(health: probe)) {
        _reattachRetire = false;
        _reattachStep = 0;
        return; // heard again — its own watchdog and teardown take over
      }
      // Hidden, bench in the way, or the attach raced a teardown: the
      // next rung on the ladder will try again (and the resume path
      // probes for itself, so a backgrounded chain may simply end here
      // — foregrounding restarts the whole recovery).
    }
    final next = reattachDelay(_reattachStep++);
    if (next == null) {
      _retireOrphanTurn(); // ladder spent; the network never came up
      return;
    }
    _reattachTimer = _scheduler.after(next, _reattachPump);
  }

  /// End a reattach chain that heard nothing, and — for a chain born from
  /// a zombie stream — retire the spinner that was quoting a dead view:
  /// the turn is over (or the network never proved it alive), so stop
  /// claiming it is still streaming and hand the UI back to the user.
  void _retireOrphanTurn() {
    _reattachTimer = null;
    final retire = _reattachRetire;
    _reattachRetire = false;
    if (!retire || _bridgeBusy) return;
    if (_reattachGen != _generation || _reattachSeq != _bridgeTurnSeq) return;
    if (_ptt.pointers > 0) {
      // A finger is DOWN right now (the press that detached this very
      // turn): its hold owns the phase, and the mic is already open
      // beneath this chain. Retiring the badge is honest; calling
      // _idleReady here is not — the field bug: DOWN over a speaking
      // turn, zero-delay probe finds nothing, idle-stomp races the mic
      // open, and the release lands on 'phase=idle not listening' with
      // eleven seconds of speech thrown away.
      _turn.retireBadgeAndWork(); // retired work is not background work any more
      _logDebug('orphan retired DURING a live press — phase left alone');
      return;
    }
    _turn.retireBadgeAndWork(); // the bridge just said nothing is open (or
    // we stopped listening on its only channel) — the badge must not lie
    _idleReady();
    _status = 'Lost the bridge mid-turn — its answer ended unheard.';
    _logDebug('ORPHAN retired: spinner cleared, answer gone unheard');
    notifyListeners();
  }

  /// The bridge is running a turn — or finished one — with NO listener:
  /// the phone's stream died while the app was hidden (Android killed the
  /// process, or the OS dropped the socket, or the route black-holed into
  /// a zombie connection the watchdog hopped off). Reattach: the bridge
  /// replays everything that happened unheard (says are spoken, tool lines
  /// land in the chat with their glyphs, context frames refill the bar),
  /// the working line comes back, and the turn's remainder is heard live.
  /// /attach STEALS the heard view, so it also heals the case the server
  /// can't see: a turn it still believes our dead socket is listening to.
  /// This is the fix for "background → foreground and nothing happens".
  /// Returns true when a reattach actually started (the caller must then
  /// NOT also run a pending-reply replay — the gen bump here would
  /// supersede it, and the backlog already covers the missed window).
  /// [replayFirst] is the caller's buffered unheard reply (the resume
  /// path hands over the block that reached the OLD view as text while
  /// the app was hidden — the backlog can't replay what was already
  /// delivered): it is spoken through [_speakResumedPending] before the
  /// /attach view opens, so one synth runs at a time and its audio leads
  /// the backlog's own replayed says.
  /// [health] lets the retry chain reuse the /health snapshot it already
  /// holds instead of paying a second probe.
  Future<bool> reattachBackgroundTurn({
    Map<String, Object>? health,
    String? replayFirst,
  }) async {
    final gateway = _gateway;
    if (gateway == null || _worker == null) return false;
    if (_bridgeBusy ||
        _backgrounded ||
        _benchCapturing ||
        _benchBusy ||
        // A finger is DOWN: the user is recording, and the reattach's
        // first act is to set phase=transcribing — which lands on the
        // open mic like the +52 orphan stomp's bigger sibling (field
        // journal: swipe-up barge-in, reattach replaying 13 missed
        // frames, release met by 'phase=transcribing not listening',
        // eleven seconds of speech discarded). The ladder will retry;
        // by the next rung the release will have made its own /talk
        // this turn's successor, and the cut-off backlog stays silent
        // by the +53/+51 age rules anyway.
        _ptt.pointers > 0) {
      return false;
    }
    // Ask the bridge, not our dead socket, whether anything is to hear:
    // an OPEN turn (even one the server still believes our zombie stream
    // was hearing — /attach steals the view) or a non-empty unheard
    // backlog both qualify; an unreachable bridge is "cannot tell", and
    // the chain keeps probing (a waking phone wakes its network late).
    final probe = health ?? await gateway.healthInfo();
    if (bridgeReattachNeeded(probe) != true) return false;
    _logDebug(
      'REATTACH start: ${_transport.noteHealth(probe)} — replaying backlog',
    );
    final claim = _turn.beginHeardTurn();
    final gen = claim.gen;
    final mySeq = claim.seq; // claim the busy flag for this turn
    _turn.becomeHeard(); // heard again from here on
    _error = '';
    _ticker.resetForTurn();
    _phase = AssistantPhase.transcribing;
    _status = 'Reattached — working…';
    notifyListeners();
    _reply.warmUpRoute();
    // A fresh bubble continues the story: the pre-drop blocks live in the
    // old one (the chat log is the history, not this loop's state).
    final turn = _chat.beginTurn();
    _reply.stopPlayback(); // cut any current audio, like the voice preview does
    _reply.startStream();
    _startPump(gen);
    final spoken = StringBuffer();

    // One replayed or live say, end-to-end — and like the main turn
    // loop's speak (+109), the ledger stamp lands when the block is
    // COMMITTED, before its audio queues: the whole point of the replay
    // dedup is that nothing already promised to the speaker ever gets
    // voiced twice, and an on-air stamp left the in-flight paragraphs
    // invisible to it.
    // +114: the replay gets the same heard-accounting the live turn
    // has: commit at call, retract at wire death if the audio of it
    // never started — otherwise a half-delivered backlog permanently
    // fakes "heard" and the sentence dies mid-replay twice over.
    final rCommitted = <String>[];
    final rAired = <String>{};
    Future<void> speak(String text) async {
      _lastReplyText = text;
      rCommitted.add(text);
      _inFlight.add(text); // +115: a replayed paragraph is equally
      // unheard until its own audio starts
      await _reply.speakBlock(
        text,
        alive: () => gen == _generation,
        drop: () => text == _dropAfterHide, // same skip contract as
        // speak(): a paragraph the hide cut is never re-voiced here
        onAir: (sinceText) {
          rAired.add(text);
          _inFlight.remove(text); // +115
          // +116: ledger stamp at first sound, same law as the live turn:
          spoken.write('$text ');
          _chat.addBlock(turn, text);
          _dropAfterHide = null; // this block's air outranks the mark
          _phase = AssistantPhase.speaking;
          _hops.tts(); // reply→audio hop crossed
          if (!_ttsFirstTimed) {
            _ttsFirstTimed = true;
            _ttsSeconds = sinceText.inMilliseconds / 1000.0;
          }
        },
      );
    }

    unawaited(() async {
      // The caller's unheard reply leads the backlog (see [replayFirst]):
      // synthesised through THIS reattach's gen into the queue the pump
      // above drains — awaited before the view opens, so exactly one
      // synth ever races the worker and the resumed block's audio comes
      // out ahead of the replayed says, story order intact. A supersede
      // during the synth (new /talk took the ear) drops the audio and
      // the whole attach with it.
      if (replayFirst != null && replayFirst.trim().isNotEmpty) {
        await _speakResumedPending(replayFirst, gen);
        if (gen != _generation) return; // superseded mid-replay
      }

      final pump = BridgeTurnPump(
        beforeEvent: (ev) {
          _hops.reply(); // harness→reply hop crossed (reattach view)
          // No unpin here on +81: a reattach backlog is by definition
          // the OLD turn's frames. Only the 'started' marker (tool
          // branch below) proves OUR queued prompt was taken.
        },
        isStale: () => gen != _generation,
        onEvent: (ev) async {
          // One cleaning up front, then every branch — dedup test, log
          // add, and speak — sees the SAME string the live path stored.
          // The bug this kills: the chat log keeps the cleaner's OUTPUT
          // (markdown folded, ': '→', ', clauses capitalized), while
          // dedup compared the cleaner's INPUT — any paragraph the
          // cleaner touched missed, and a heard paragraph rode the
          // replay back out of the speaker. Match like you store.
          final sayText = ev.isSay && ev.text.trim().isNotEmpty
              ? cleanForSpeech(ev.text.trim())
              : '';
          if (sayText.isNotEmpty &&
              _transport.wireAgeMs(ev) > 120000 &&
              // (unless it's also in the chat log or in the speaker —
              // then the dedup branch below silently drops it instead
              // of duplicating)
              !_chat.containsBlock(sayText) &&
              !_inFlight.contains(sayText)) {
            // Archaeology, not news: the backlog replayed a line from
            // before the app went away (an APK update, a kill — the
            // frames are minutes or hours old). It belongs in the
            // conversation as text, never in the speaker again — the
            // user already lived through this exchange.
            _chat.addBlock(turn, sayText);
            final ageSec = ev.wireMs == 0
                ? 'unstamped'
                : '${_transport.wireAgeMs(ev) ~/ 1000}s old';
            _logDebug('replay $ageSec: logged silently, not spoken');
          } else if (sayText.isNotEmpty &&
              (_chat.containsBlock(sayText) ||
                  _inFlight.contains(sayText))) {
            // Already heard — or already airborne in this process.
            // +116 makes the first half TRUE: the persisted log only
            // ever carries blocks whose audio started, so containsBlock
            // means heard, full stop — and _inFlight (+115) covers the
            // seconds before that first chunk for the process doing the
            // speaking, dying with it so a crash cannot fossilise a lie
            // (the install-day reports). One trade kept from the old
            // law: a paragraph cut off MID-audio counts as heard and
            // its tail is not repeated — never re-listening beats
            // never not-listening, said every chat client ever.
            _logDebug('replay dedup: paragraph already in chat — skipped');
          } else if (sayText.isNotEmpty) {
            _ticker.markSpoken();
            _logDebug(
              'msg harness: say (replay) "${sayText.length > 48 ? '${sayText.substring(0, 48)}…' : sayText}"'
              '${_transport.wireTag(ev)}',
            );
            await speak(sayText);
          } else if (ev.kind == 'context') {
            if (ev.inputTokens != _ticker.rawInputTokens) {
              _ticker.noteInputTokens(ev.inputTokens);
              notifyListeners();
            }
            _logDebug('bridge context ${ev.inputTokens}/${ev.contextWindow}');
            _mergeContext(ev.inputTokens, ev.contextWindow);
          } else if (ev.kind == 'tool') {
            if (ev.toolName == 'started') {
              _chat.unpinQueued();
              _turn.heardPickup(); // the named background tool finished —
              // the bottom line dismisses with the pin; heard again
              _logDebug(
                'queue picked up: "${ev.detail}"${_transport.wireTag(ev)}',
              );
              return;
            }
            if (ev.toolName == 'finished') {
              // Same receipt rule as the /talk loop (see there): the
              // backgrounded work this replay carries is provably over.
              _turn.clearBgWork();
              if (_harnessBackgrounded) _turn.retireBadgeAndWork();
              _logDebug(
                'backgrounded work finished '
                '(${ev.detail})${_transport.wireTag(ev)}',
              );
              notifyListeners();
              return;
            }
            final tally = ev.toolName == 'tokens';
            _logDebug(
              'bridge tool ${ev.toolName} ${ev.detail}${_transport.wireTag(ev)}',
              toJournal: !tally, // token tallies: ring yes, journal no
            );
            if (tally) {
              _ticker.onFrame(ev);
            } else {
              _ticker.markToolStep();
              final stepLine = ev.toolName == 'Bash'
                  ? 'Bash ${ev.detail}…' // real command, see /talk loop
                  : '${ev.toolName}'
                        '${ev.detail.isEmpty ? '' : ' ${p.basename(ev.detail)}'}…';
              _status = stepLine;
              if (ev.toolName != 'queued') {
                // A replayed backlog re-names the work the phone missed
                // while it was away — the bottom line stays honest
                // about what the backgrounded turn is actually on.
                _turn.noteToolStep(stepLine);
              }
              // No step line in the bubble here either — same policy as
              // the /talk loop: the strip labels the step, the journal
              // remembers it, the chat log is for words.
              notifyListeners();
            }
          } else if (ev.isDone) {
            if (ev.isError && gen == _generation) {
              _error = 'the harness reported an error';
            }
          } else if (ev.kind == 'error') {
            // the bridge's own farewell: the turn is over
            _fail('Bridge: ${ev.text}');
          }
        },
      );
      _turn.installPump(pump);
      _lease.armWatch(); // the quiet-wire watchdog rides this connection
      _hops.sent(); // rejoining counts as reached-the-harness too
      _logDebug('ATTACH stream open: gen=$gen backlog replay, then live');
      var outcome = const PumpOutcome(
        stale: true,
        sawDone: false,
        sawErrorFrame: false,
        streamError: null,
        detached: false,
      );
      try {
        outcome = await pump.run(gateway.attach(onActivity: _lease.markAlive));
        final err = outcome.streamError;
        if (err != null && gen == _generation) {
          _fail(err is BridgeException ? err.message : '$err');
        }
      } finally {
        // Same teardown discipline as runQuickCommand: never touch a
        // successor turn's pump, or busy flag.
        unawaited(_refreshSession());
        final stillOurs = _turn.releasePumpIf(pump);
        // An UNOWNED death of the reattached stream (socket, no done, no
        // error frame) — the turn is still the bridge's to finish: the
        // chain rejoins it without resetting the retry ladder, so a
        // flaky network can cycle attach-dies-reattach only a bounded
        // number of times per orphaned turn.
        final wireOrphan =
            outcome.closedWithoutDone &&
            !outcome.detached &&
            _bridgeBusy &&
            _bridgeTurnSeq == mySeq &&
            gen == _generation;
        if (stillOurs) _lease.cancel();
        // Release the busy slot only if we still own it (see
        // TurnCoordinator.releaseOwnership for the +126 clock rule).
        _turn.releaseOwnership(mySeq);
        // +114, replay side: a view that dies mid-replay withdraws the
        // paragraphs whose audio never started — the backlog copy for
        // them lives until a view actually speaks them.
        if (!outcome.sawDone) {
          for (final t in rCommitted) {
            if (!rAired.contains(t)) _chat.removeBlock(turn, t);
          }
        }
        _inFlight.removeAll(rCommitted); // +115: replay flight over
        // Same stamp as the heard-stream teardown (+108): an attach
        // view closed under a newer press leaves its bubble marked.
        if (!outcome.sawDone && gen != _generation && !turn.isEmpty) {
          _chat.markInterrupted(turn);
        }
        if (turn.isEmpty) _chat.removeEmptyTurn(turn);
        if (gen == _generation) {
          _reply.closeStream();
        }
        final said = spoken.toString().trim();
        if (said.isNotEmpty) _lastSpoken = said;
        if (gen == _generation && spoken.isEmpty && _error.isEmpty) {
          _idleReady();
        }
        notifyListeners();
        _logDebug(
          'ATTACH end gen=$gen: ${outcome.streamError != null
              ? 'SOCKET DIED (${outcome.streamError})'
              : outcome.sawErrorFrame
              ? 'bridge error frame'
              : outcome.sawDone
              ? 'done clean'
              : 'CLOSED WITHOUT DONE'}'
          '${wireOrphan
              ? ' — UNOWNED, chain continues (paced)'
              : gen != _generation
              ? ' — superseded'
              : ''}',
        );
        if (wireOrphan) {
          _reattachGen = gen;
          _reattachSeq = mySeq;
          // This chain itself came from an attach that died: pace the
          // next attempt so a flaky link can't request-loop through the
          // ladder at connection-attempt speed.
          _startReattachChain(
            resetStep: false,
            firstProbe: kReattachDelays.first,
          );
        }
      }
    }());
    return true;
  }

  bool _conversationWasLive = false;
  bool _backgrounded = false;
  /// +115: paragraphs this process has committed to the ledger whose
  /// audio has NOT started — mid-synth or queued. The replay dedup
  /// consults this beside the log: after a process death (an APK swap
  /// landing between commit and first chunk) the set is gone while the
  /// on-disk commit survives, so the relaunched app re-voices the tail
  /// the old process never got out of the speaker instead of skipping
  /// it as heard — the field report of the plus-fourteen install.
  final Set<String> _inFlight = {};
  String? _pausedWorking; // spinner working line snapshotted at hide time
  String? _resumeReplyText; // newest bridge reply buffered while hidden
  String? _dropAfterHide; // paragraph audible when the hide cut it: skip
  // it whole on return — half-heard beats replayed, and its still
  // synthesising chunks drop on the floor (see pauseConversation)
  String? _lastReplyText; // newest block speak() has fed to the log

  /// Speak a bridge reply that landed while the app was hidden. The text is
  /// already in the chat log (buffered there by runQuickCommand's speak()),
  /// so this only feeds the speaker — no new bubble, no double text.
  /// Speak the reply a hide left unheard — the app came back and the
  /// stream is (or is about to be) still owned by a live event loop, so
  /// unlike [_replayPendingReply] this bumps NO generation: a bump would
  /// supersede that loop and hand a perfectly healthy turn to the bridge
  /// as a background turn, which is the opposite of coming back. The
  /// chunks ride the live turn's own queue (the pump at
  /// [resumeConversation]'s respawn covers it), and the text does NOT
  /// re-enter the log: the block already sits there from the hidden
  /// branch of speak() — this is the audio the room was promised.
  /// [gen] is the caller's turn generation: a superseded replay drops
  /// its chunks exactly like a superseded speak would.
  Future<void> _speakResumedPending(String text, int gen) async {
    if (_worker == null) return;
    try {
      await _reply.speakBlock(
        text,
        alive: () => gen == _generation,
        onAir: (sinceText) {
          _phase = AssistantPhase.speaking; // first audible chunk flips
          // the status, like speak()
          _hops.tts(); // reply→audio hop crossed
          if (!_ttsFirstTimed) {
            _ttsFirstTimed = true;
            _ttsSeconds = sinceText.inMilliseconds / 1000.0;
          }
          _lastReplyText = text; // the re-hide seed sees this replay as
          // the last reply (re-playing a block hides audio again =
          // pauseConversation's own restart-the-block rule)
          _chat.touch();
        },
      );
      if (gen != _generation) return; // superseded mid-replay: chunks dropped
      _lastSpoken = text; // echo guard: this voice coming back is ours
    } catch (e) {
      _logDebug('resume replay failed: $e');
      return;
    }
    if (_backgrounded) return; // hidden again mid-replay: pause owns the UI
    // A `done` that landed mid-replay closed the stream and may have
    // drained the pump dry at its seam: respawn (only when none runs — a
    // parked pump must not get a twin) so the replayed chunks actually
    // reach the speaker and the natural-end hook eventually idles the UI.
    if (gen == _generation && _reply.queuedCount > 0 && !_reply.pumpAlive) {
      _startPump(gen);
    }
  }

  Future<void> _replayPendingReply(
    String text, {
    required bool thenListen,
  }) async {
    final worker = _worker;
    if (worker == null) return;
    final gen = _turn.supersede(); // supersede whatever half-state survived
    _reply.stopPlayback();
    _error = '';
    _phase = AssistantPhase.transcribing;
    _status = 'Picking up where the bridge left off…';
    notifyListeners();
    _reply.warmUpRoute(); // hold the output route through the synth wait
    _reply.startStream();
    _startPump(gen);
    // The buffered reply's text is old (it arrived before the app went
    // away), so received-to-ear isn't meaningful here; the first-chunk
    // elapsed measures the wait the user feels NOW.
    _ttsSeconds = 0;
    _ttsFirstTimed = false;
    try {
      await _reply.speakBlock(
        text,
        alive: () => gen == _generation,
        onAir: (sinceText) {
          _phase = AssistantPhase.speaking;
          _hops.tts(); // reply→audio hop crossed
          if (!_ttsFirstTimed) {
            _ttsFirstTimed = true;
            _ttsSeconds = sinceText.inMilliseconds / 1000.0;
          }
          notifyListeners();
        },
      );
      if (gen != _generation) return; // cut off mid-replay: user moved on
      _lastSpoken = text; // echo guard: this voice coming back is ours
      _reply.closeStream();
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

  /// Big-button action, interpreted per mode + phase.
  Future<void> toggle() async {
    // The big-button story, journalled (0.1.0+79): a tap that produced
    // no message after a reinstall left no trace of WHICH branch it
    // took — pushToTalk's gesture arm eats the tap before this method
    // ever sees it (pttUp's 'press never landed' is all the journal
    // said). One line per dispatch pins the mode, phase and busy flags
    // at the moment the finger lifted.
    _logDebug(
      'TOGGLE: mode=${_mode.name} phase=${_phase.name} '
      'busy=$_voiceBusy worker=${_worker != null}',
    );
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
  // few centimetres off the button still closes the mic. The pointer/
  // slide/lean geometry is [PttHold]'s; what each edge DOES is below.

  /// Debug counters (shown under the button in debug mode): press/release
  /// edges observed — proves on-device whether holds reach the Listener.
  int get pttEdgeCount => _ptt.edgeCount;

  /// A push-to-talk hold whose mic opened on top of a running harness
  /// turn — the UI says "release to queue / slide up to interrupt" while
  /// this is set and the button is being held.
  bool get pttHoldOverTurn => _ptt.holdOverTurn;

  PttSlide get pttSlide => _ptt.slide;
  Offset get pttDrag => _ptt.drag;

  /// A push-to-talk hold is down right now (conversation mode never
  /// reaches this: its taps don't open these edges).
  bool get pttHoldActive =>
      _mode == InteractionMode.pushToTalk && _ptt.pointers > 0;

  void pttMove(Offset at) {
    // Quantised to 4-px steps inside PttHold and notified only on
    // change: a 120-Hz finger stream must not rebuild the screen at
    // 120 Hz.
    if (_ptt.move(at)) notifyListeners();
  }

  void pttDown([Offset? at]) {
    _ptt.edgeCount++;
    // Journal every edge (not just logcat): the field bug — "sometimes
    // the message is not sent and the chat shows nothing" — needs the
    // press/release/decision story with phone timestamps, relayed.
    _logDebug(
      'ptt DOWN #${_ptt.edgeCount}: mode=${_mode.name} phase=${_phase.name} '
      'worker=${_worker != null} ptr=${_ptt.pointers} busy=$_bridgeBusy '
      'bgd=$_harnessBackgrounded',
    );
    if (_mode != InteractionMode.pushToTalk || _worker == null) return;
    final firstPointer = _ptt.down(at);
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
      _ptt.bridgeHold = _bridgeBusy;
      if (_ptt.bridgeHold) _turn.markBackgrounded();
      _turn.supersede();
      if (_ptt.bridgeHold) {
        _logDebug(
          'ptt DOWN over a live turn: detached it — the open tool '
          'keeps working (badge lit), release gesture routes the prompt',
        );
      }
      _reply.stopDebug();
      _reply.stopPlayback();
      _turn.detach(TurnTrigger.pttPress);
      if (_ptt.bridgeHold) {
        // The detach used to mean UNSEEN, not just unheard: every tool
        // line and context frame of the backgrounded turn piled into the
        // bridge's backlog and burst onto the screen in one replay when
        // the turn closed (field journal: two Bash relays six seconds
        // apart on the wire, landed 5 ms apart). Re-arm the reattach
        // chain NOW — it probes /health, /attach steals the view back,
        // and the remainder of the turn streams live while the mic
        // stays free. A new utterance supersedes the chain the same way
        // it always has; `retire` clears the badge if the turn closed
        // in the probe's window.
        _reattachGen = _generation;
        _reattachSeq = _bridgeTurnSeq;
        _startReattachChain(retire: true, firstProbe: Duration.zero);
      }
    } else {
      _ptt.bridgeHold = false;
    }
    if (!firstPointer) return;
    // Android can renumber pointers mid-sequence (index reassignment when a
    // second finger lifts) and may drop the matching release; rather than
    // record forever, close the mic ourselves after a generous cap.
    _pttMaxTimer?.cancel();
    _pttMaxTimer = _scheduler.after(const Duration(minutes: 2), () {
      if (_ptt.pointers > 0) pttCancel();
    });
    unawaited(_startListening());
  }

  void pttUp([Offset? at]) {
    final ptrsBefore = _ptt.pointers;
    _ptt.edgeCount++;
    final r = _ptt.release(at);
    // held only reads true when a press was actually recorded: on the
    // stray branch the press clock still wears the epoch, and printing
    // its difference produced the nonsense 'held=1792195121943ms' that
    // made a dropped press look like a two-week hold.
    final held = r.heldMs < 0 ? 'n/a' : '${r.heldMs}ms';
    _logDebug(
      'ptt UP #${_ptt.edgeCount}: ptr=$ptrsBefore slideup=${r.up} '
      'dismiss=${r.right} held=$held',
    );
    if (r.stray) {
      // A release with no recorded press (dropped event, double release):
      // loud in the journal, because this is one way a message vanishes
      // without a trace.
      _logDebug('ptt UP ignored: no pointer down — the press never landed?');
      if (r.redraw) notifyListeners(); // keep the stale-drag reading harmless
      // +80: in conversation mode that trace vanished TWICE on cold
      // starts (22:42:10 and 22:59:57, the second one on the very build
      // that added the TOGGLE journal — the line never printed, so the
      // widget's tap branch never ran: the hold guide's recognizers eat
      // the press-and-hold-then-release before a tap can resolve).
      // Conversation mode has no hold semantics anyway, so the release
      // itself IS the classic tap: dispatch it here, unasked.
      if (_mode == InteractionMode.conversation) {
        _logDebug('conv-mode release → fallback toggle dispatch');
        unawaited(toggle());
      } else if (_phase == AssistantPhase.idle) {
        // +95: the push-to-talk flavour of the same swallow was THE
        // vanishing-message trace — field report: 'the app blocks, a
        // press-release drops the message, which does not show up in
        // the conversation.' Nothing was ever recorded, so no bubble
        // CAN appear — but the button must not be silent about it.
        // Tell the user on the line they were watching, and only while
        // idle so this never stomps a live phase's status (a stray
        // double-release over working machinery must not claim the
        // machinery failed).
        _status = "That press didn't land — nothing was recorded. Hold again.";
        notifyListeners();
      }
      return;
    }
    if (_ptt.pointers > 0) return; // still holding with another finger
    _pttMaxTimer?.cancel();
    _pttMaxTimer = null;
    if (r.redraw) notifyListeners(); // the guide snaps back the moment
    // the hold ends
    _reply.warmUpRoute(); // connect the output route while we transcribe
    if (r.right) {
      // Slide-right release: throw the recording away unsent.
      unawaited(_stopAndRespond(discard: true));
    } else {
      unawaited(_stopAndRespond(interrupt: r.up));
    }
  }

  void pttCancel() {
    // Back gesture / system interruption: behave exactly like a release
    // with no slide (never discard the recording, never a hard stop by
    // accident), so the mic can never be left open.
    _logDebug('ptt CANCEL (system interruption) — treated as plain release');
    final wasVisible = !_ptt.visualsClear;
    _ptt.cancel();
    _pttMaxTimer?.cancel();
    _pttMaxTimer = null;
    _reply.warmUpRoute();
    if (wasVisible) notifyListeners();
    unawaited(_stopAndRespond());
  }

  void _idleReady() {
    if (_worker == null) return;
    _phase = AssistantPhase.idle;
    _status = _mode == InteractionMode.conversation
        ? "Tap the mic to start a conversation. Pause about a second and I'll answer."
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

  // ── Microphone plumbing (see MicPipeline; shared by both modes) ───────

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

  MicRoute get _micRoute {
    if (_reply.debugPlaying) return MicRoute.mute; // stream stays live
    // for the watchdog only
    if (_benchCapturing) return MicRoute.raw;
    if (_mode == InteractionMode.pushToTalk) return MicRoute.raw;
    return MicRoute.vad;
  }

  /// Raw PCM16 chunks (PTT buffer / bench capture) — the sink checks the
  /// phase exactly like the original inline router: a PTT buffer only
  /// fills while listening; bench hard-caps at 20 s.
  void _onPcm(Float32List c) {
    if (_benchCapturing) {
      // Latency bench: mic hand-off feeding the timed echo turn in
      // finishBenchCapture instead of a sample file.
      _benchChunks.add(c);
      _benchSeconds += c.length / 16000.0;
      if (_benchSeconds >= 20) unawaited(finishBenchCapture()); // hard cap
      return;
    }
    if (_mode == InteractionMode.pushToTalk &&
        _phase == AssistantPhase.listening) {
      _chunks.add(c);
    }
  }

  /// The stream is back up (the pipeline re-pinned the gate and reset the
  /// VAD while the user wasn't talking): the status line says so.
  void _onMicReopened() {
    if (_phase == AssistantPhase.listening) {
      _status = _mode == InteractionMode.conversation
          ? 'Listening — just talk.'
          : 'Listening… release to send.';
      notifyListeners();
    }
  }

  /// The bench's release→first-audio figure: bytes enter the player NOW
  /// (the route warm-up from the release is included — a real PTT round
  /// trip pays that latency too, and pretending otherwise would flatter
  /// the panel's headline number).
  void _onChunkAudible() {
    if (_benchBusy && _benchFirstAudioMs == 0) {
      _benchFirstAudioMs = _benchT0?.elapsedMilliseconds ?? 0;
    }
  }

  // ── Debug replay API (see ReplyPipeline.replayDebug) ──────────────────

  /// Replays the exact bytes ASR saw for the last turn (VAD segment or gated
  /// PTT buffer, post pre-roll/gating). Capture stays open but is muted while
  /// it plays, so nothing leaks back into the VAD. Tap again to stop.
  Future<void> playAsrAudio() => _playDebugWav(
    _asrAudio,
    _asrAudioRate,
    'asr_replay',
    'Playing back what I heard…',
  );

  /// Replays the raw bytes the TTS engine generated for the last reply (or
  /// voice preview) — engine artifacts become tellable apart from playback
  /// and automatic-gain effects. Tap again to stop.
  Future<void> playTtsAudio() {
    final audio = _reply.lastTtsAudio;
    if (audio == null) return _playDebugWav(null, 16000, '', '');
    return _playDebugWav(
      audio,
      _reply.lastTtsRate,
      'tts_replay',
      'Replaying my last reply…',
    );
  }

  Future<void> _playDebugWav(
    Float32List? audio,
    int rate,
    String tag,
    String playingStatus,
  ) async {
    if (_reply.debugPlaying) {
      _reply.stopDebug(); // the second tap is the stop; the in-flight
      // call unwinds through the restore below
      return;
    }
    if (audio == null) return;
    _status = playingStatus;
    notifyListeners();
    try {
      await _reply.replayDebug(audio, rate, tag: tag);
    } catch (e) {
      _fail('Debug playback failed: $e');
      return;
    }
    if (_disposed) return;
    // Replay over: back to a live pipeline (the gate's hard mode is
    // already gone; only the conversation state is ours to restore).
    _phase = _mode == InteractionMode.conversation
        ? AssistantPhase.listening
        : AssistantPhase.idle;
    _status = _mode == InteractionMode.conversation
        ? 'Listening — just talk.'
        : 'Ready. Hold the button to speak.';
    _worker?.resetVad();
    notifyListeners();
  }

  // ── Conversation mode ────────────────────────────────────────────────────

  Future<void> _beginConversation() async {
    _reply.stopDebug();
    try {
      await _mic.open();
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
    _turn.supersede();
    // No ear left on the harness: hard-stop its in-flight turn too.
    _turn.detach(TurnTrigger.conversationClose);
    _phase = AssistantPhase.idle;
    _status = message;
    notifyListeners();
  }

  void _cancelResponse(String message) {
    _turn.supersede(); // abandon any in-flight turn
    // Tap = explicit stop: hard-quit the harness's work too (a spoken
    // barge-in detaches/backgrounds instead — see TurnCoordinator.detach).
    _turn.detach(TurnTrigger.cancelTap);
    _reply.stopDebug();
    _reply.stopPlayback();
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
    if (_reply.debugPlaying)
      return; // don't let the replay re-enter the pipeline
    if (event.speechStarted) {
      // Barge-in: the SNR gate already forced this speech to sit well above
      // the echo/noise floor, so muting our reply here is safe.
      _segEchoRisk = _reply.playing;
      _segGotAudio = false;
      if (_reply.playing) {
        if (_reply.tooYoungToTrust) {
          // Too early to trust: AEC has not locked yet, so this "speech" may
          // be our own reply. Keep talking; the word-overlap echo guard still
          // discards the resulting text, and a genuine interruption a few
          // hundred ms later mutes us as usual.
          notifyListeners();
          return;
        }
        _userSpeaking = true; // set first: keeps stopPlayback from resetting
        _logDebug(
          'kill reply after ${_reply.audibleFor.inMilliseconds}ms of reply',
        );
        _reply.stopPlayback();
        _turn.supersede(); // abandon the response we were speaking
        // Spoken takeover = DETACH (no hard stop): the harness keeps
        // working behind the scenes — a long tool call runs on, and the
        // utterance landing in a moment queues behind it (or cuts the
        // thinking turn short at the bridge). That is Claude Code's
        // background-the-long-task flow, voice-native edition.
        _turn.detach(TurnTrigger.voiceBargeIn);
        _status = 'Interrupted — go ahead.';
      } else if (_phase == AssistantPhase.transcribing) {
        _userSpeaking = true;
        _turn.supersede(); // user resumed; drop the half-baked response
        _turn.detach(TurnTrigger.speechResumed); // same detach semantics as above
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
      _reply.warmUpRoute(); // connect the output route while we transcribe
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
    final gen = _turn.supersede(); // any newer turn supersedes this one
    _ptt.bridgeHold = false; // the hold is over: the turn owns the choice now
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
      if (gen != _generation) {
        _logDebug(
          'message SWALLOWED: superseded during ASR (gen $gen → $_generation)'
          ' — transcript "${text.substring(0, text.length < 40 ? text.length : 40)}" '
          'went nowhere',
        );
        return;
      }
      _asrSeconds = swAsr.elapsedMilliseconds / 1000.0;
      _hops.asr(); // heard→asr hop crossed: a transcript exists
      _logDebug(
        'asr ✓ "${text.length > 60 ? '${text.substring(0, 60)}…' : text}" '
        '(${text.length} chars in ${swAsr.elapsedMilliseconds}ms)',
      );

      if (text.isEmpty) {
        _status = "Didn't catch that — try again?";
        _phase = _mode == InteractionMode.pushToTalk
            ? AssistantPhase.idle
            : AssistantPhase.listening;
        notifyListeners();
        return;
      }
      if (_segEchoRisk && _looksLikeEcho(text, _lastSpoken)) {
        _segEchoRisk = false;
        _logDebug('asr result rejected as TTS echo — nothing sent');
        _status = "That was my own voice — I'm listening.";
        _phase = AssistantPhase.listening;
        notifyListeners();
        return;
      }
      _segEchoRisk = false;
      _transcript = text;
      _lastSpoken = text;
      // The conversation log keeps everything: what we heard lands as a
      // user bubble now (in either mode), the answer as assistant
      // bubbles section by section as it is spoken. A polite-queue
      // press (slide-up off, interrupt=false) over a live turn wears
      // the pin instead: the card sits at the bottom of the channel
      // until the harness begins this turn, then the message joins the
      // flow right where its answer will follow.
      _chat.addUser(
        text,
        // _bridgeBusy alone lies here: the DOWN-time detach cleared it
        // while the bridge turn lives on (badge = _harnessBackgrounded)
        // — behind THAT is what a polite release queues.
        queued: !interrupt && (_bridgeBusy || _harnessBackgrounded),
      );

      if (_gateway != null && _bridgePrefs.voice) {
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
        _turn.detach(TurnTrigger.newUtterance);
        _logDebug(
          '→ harness: bubble added, POSTing /talk (interrupt=$interrupt)',
        );
        unawaited(runQuickCommand(text, interrupt: interrupt));
        return;
      }

      // Streamed reply: the worker renders sentence chunks and we play
      // each one the moment it lands, so the reply STARTS speaking while
      // later sentences are still synthesising (and no VITS pass can run
      // long enough to hit its length cap). The status still quotes the
      // whole reply — the text is final, only the audio streams.
      _reply.playSeconds = 0;
      _ttsSeconds = 0;
      _ttsFirstTimed = false;
      _reply.startStream();
      unawaited(
        _reply
            .speakBlock(
              text,
              alive: () => gen == _generation,
              drop: () => text == _dropAfterHide, // hide cut this
              // reply mid-play: skip the rest whole, no replay on return
              onAir: (sinceText) {
                _dropAfterHide = null; // this block's air outranks the mark
                _phase = AssistantPhase.speaking;
                _hops.tts(); // first audio of the reply (see strip)
                // _ttsSeconds holds the FIRST-WORD latency —
                // received-to-ear — stamped on the first chunk, where the
                // pause the user actually feels lives.
                if (!_ttsFirstTimed) {
                  _ttsFirstTimed = true;
                  _ttsSeconds = sinceText.inMilliseconds / 1000.0;
                }
                notifyListeners();
              },
            )
            .then((_) {
              if (gen != _generation) return;
              _reply.closeStream();
            })
            .catchError((Object e) {
              _reply.closeStream();
              if (gen == _generation) _fail('Round trip failed: $e');
            }),
      );
      await _reply.runPump(isStale: () => gen != _generation);
    } catch (e) {
      _fail('Round trip failed: $e');
    }
  }

  // ── Natural-end aftermath (the pipeline's other half) ──────────────────
  // The pipeline has already dropped the playing flag, unpinned the gate,
  // freed the temp file and (unless the user is talking over the tail)
  // reset the VAD. What belongs here is the CONVERSATION decision.

  void _handleNaturalEnd() {
    // If capture went silent during our reply (our playback is a common
    // trigger for Android tearing it down), reopen right now.
    _mic.flushPending();
    // Any utterance the VAD formed from the tail of our own reply must not
    // leak into the next turn (the user talking over the reply keeps theirs).
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
    final parked = _drainAfterSpeech;
    _drainAfterSpeech = null;
    if (parked != null) {
      // +124: the speaker fell silent on its own terms; the parked
      // backlog verdict gets its second look (a barge-in's stop is not
      // a natural end, so a parked verdict that dies this way is
      // simply re-formed by the next turn's teardown — self-healing).
      unawaited(_drainStrandedBacklog(parked.gen, parked.mySeq));
    }
    _mic.fastCheck();
  }

  void _shutdownAudio() {
    _reply.stopDebug();
    _reply.stopPlayback();
    _shutdownMic();
  }

  /// The INPUT half of [_shutdownAudio]: watchdog, recorder, VAD
  /// buffers, and any in-flight bench capture. Split out so a mode
  /// switch during a live bridge turn can close the mic without touching
  /// the streamed reply player — stopping the player there would silence
  /// the harness mid-turn and (via the queue clear) drop the say-chunks
  /// already synthesised, making the survive-vs-abandon choice
  /// depend on whether a chunk happened to be audible at tap time.
  void _shutdownMic() {
    unawaited(_mic.close());
    _worker?.resetVad();
    _chunks.clear();
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

  // ── Push-to-talk mode ────────────────────────────────────────────────────

  Future<void> _startListening() async {
    if (_phase == AssistantPhase.listening || _worker == null) return;
    _reply.stopDebug();
    try {
      _reply.stopPlayback();
      await _mic.open();
      _phase = AssistantPhase.listening;
      _error = '';
      _status = 'Listening… release to send.';
      notifyListeners();
    } catch (e) {
      _fail('$e');
    }
  }

  Future<void> _stopAndRespond({
    bool interrupt = false,
    bool discard = false,
  }) async {
    if (_phase != AssistantPhase.listening) {
      // Another silent sinkhole for a vanishing message: the mic was not
      // actually open by the time the release arrived (press raced a
      // mode switch, the watchdog closed the stream, a duplicate call).
      _logDebug(
        'release dropped: phase=${_phase.name} not listening '
        '(discard=$discard interrupt=$interrupt)',
      );
      return;
    }
    // Snapshot the hold's context before any await: was this recording
    // made OVER an in-flight harness turn (pttDown detached it into a
    // background turn already), and how long was the button held (a
    // quick tap on top of a turn is the hard stop, the old tap-Stop).
    final bridgeHold = _ptt.bridgeHold;
    _ptt.bridgeHold = false;
    final heldMs = _ptt.heldMs;
    _reply.stopDebug();
    await _mic.close();
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
      _logDebug('release: slide-right DISCARD — ${total}B dropped unsent');
      notifyListeners();
      return;
    }
    if (total < 16000 ~/ 4) {
      _phase = AssistantPhase.idle;
      _logDebug(
        'release: too short — ${total}B over ${heldMs}ms (bridgeHold=$bridgeHold'
        ' interrupt=$interrupt)',
      );
      if (bridgeHold) {
        // The hold opened over a harness turn but nothing speakable came
        // out. A quick tap is the hard stop the button always was mid-
        // turn: /stop cuts the (already detached, still running) turn.
        // A longer hold with no words leaves the background work ALONE —
        // it finishes on its own and the next release queues behind it.
        if (interrupt || heldMs < _ptt.tapStopMs) {
          unawaited(_gateway?.stop());
          _turn.retireBadge();
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
    _logDebug('release → denoise+ASR: ${total}B held ${heldMs}ms');
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
      _logDebug(
        'message SWALLOWED: superseded during cleanup (gen $gen → '
        '$_generation, pointers=${_ptt.pointers}) — the recording died untranscribed',
      );
      if (_ptt.pointers == 0) _idleReady();
      return;
    }
    // A slide-right release is the POLITE queue (interrupt: false): if
    // the bridge still has a turn in flight (the one this hold detached,
    // or an older one backgrounded unheard), this prompt waits for it to
    // finish. Everything else keeps the established takeover flavour.
    await _startTurn(cleaned, interrupt: interrupt || !bridgeHold);
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

  // ── Test seams ─────────────────────────────────────────────────────────

  /// Lets a [SpeechEngine] double drive the conversation exactly like
  /// the real worker's VAD events do (the wiring init() installs).
  @visibleForTesting
  void Function(SpeechEvent) get debugSpeechEvents => _onSpeechEvent;

  /// Re-read /health and fold it into the transport (clock skew, poll
  /// capability) the way the cold-start reattach probe does — so tests
  /// that skip init() (and the model download) can still exercise the
  /// pull transport.
  @visibleForTesting
  Future<void> debugProbeTransport() async =>
      _transport.noteHealth(await _gateway?.healthInfo());

  @override
  void notifyListeners() {
    // The original guarded post-await repaints with `if (!_disposed)`
    // at each site (the debug-replay finally, the reattach teardown);
    // this is the same rule where every repaint actually funnels.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _hops.dispose();
    _lease.cancel();
    _reattachTimer?.cancel();
    _pttMaxTimer?.cancel();
    _ptt.cancel();
    unawaited(() async {
      await _events?.log('app dispose (UI went away)');
      await _events?.stop();
    }());
    _shutdownAudio();
    unawaited(_reply.dispose());
    _worker?.dispose();
    super.dispose();
  }
}
