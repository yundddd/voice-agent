/// The voice round-trip orchestrator.
///
///   mic -> VAD endpointing -> Whisper (ASR) -> text -> TTS -> speaker
///
/// in two interaction modes (see [InteractionMode]), with a Claude Code
/// bridge turn layered in place of the local echo when configured.
///
/// What this class is NOT anymore: a monolith — or even a large class.
/// Every rule the field reports taught lives in a unit behind a seam
/// this file wires together:
///
///  * [ChatStore] — the conversation log, its pins, and persistence.
///  * [TokenTicker] — the live spinner counter (rate-learned extrapolation).
///  * [HopTracker] — the latency strip's flow pulses.
///  * [NarrationGate] — the step-narration quiet/heartbeat rules.
///  * [PttHold] — the push-to-talk pointer/slide state machine.
///  * [MicPipeline] behind [MicSource] — capture, watchdog, reopens.
///  * [ReplyPipeline] behind [AudioOutput] — streamed chunk playback.
///  * [BridgeTurn] behind [BridgeTurnPump] / [WireLease] /
///    [BridgeTransport] — the ONE harness event loop (the /talk listener,
///    the control streams, and the /attach replay are origins of it),
///    its ledger, receipts and teardown.
///  * [TurnCoordinator] — the bridge-turn truth: busy slot, badge,
///    snapshots, generation/seq ownership, the interrupt policy table.
///  * [HideResume] — the background→foreground dance: the double-hide
///    guard, the cut-paragraph skip, the unheard-say resume promise.
///  * [ReattachChain] — the retry ladder for a view that died mid-turn.
///  * [Activity] — the status line as data, rendered at the projection
///    edge; and [AssistantView] — the whole conversation screen as one
///    immutable snapshot, so UI behavior is assertable without a device.
///
/// What stays here is the WIRING: the intent methods the UI calls, the
/// turn openers (verdicts before a turn starts), the lifecycle folding
/// (OS callbacks → HideResume transitions), the voice/bench/settings
/// plumbing, and the journal flags. The conversation about WHEN lives
/// here; the collaborators know HOW.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui'
    show Offset; // PTT release-gesture geometry (Listener positions)

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import './activity.dart';
import './bridge_turn.dart';
import './chat_store.dart';
import './hide_resume.dart';
import './heard_ledger.dart';
import './hop_tracker.dart';
import './mic_pipeline.dart';
import './narration_gate.dart';
import './ptt_hold.dart';
import './reattach_chain.dart';
import './reply_pipeline.dart';
import './session_channel.dart';
import './state.dart';
import './token_ticker.dart';
import './turn_session.dart';
import './view.dart';
import '../bridge/bridge_event.dart';
import '../bridge/client.dart';
import '../bridge/gateway.dart';
import '../bridge/prefs.dart';
import '../bridge/text_rules.dart';
import '../bridge/transport.dart';
import '../bridge/wire_lease.dart';
import '../chat/chat_log.dart';
import '../common/clock.dart';
import '../common/sinks.dart';
import '../journal/app_events.dart';
import '../models/model_packs.dart';
import '../platform/audio_output.dart';
import '../platform/file_opener.dart';
import '../platform/file_player_output.dart';
import '../platform/mic_source.dart';
import '../platform/record_mic_source.dart';
import '../speech/asr_models.dart';
import '../speech/kokoro_voices.dart';
import '../speech/speech_worker.dart';
import '../speech/tts_voices.dart';

export './activity.dart';
export './bridge_turn.dart' show BridgeTurn, BridgeTurnEnv, BridgeTurnOrigin;
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
export './hide_resume.dart' show HideResume, ResumePlan;
export './reattach_chain.dart' show ReattachChain, ReattachEnv;
export './view.dart';
export '../speech/speech_worker.dart' show SpeechEvent, SpeechWorker, TtsSpec;
export '../speech/asr_models.dart'
    show
        AsrModel,
        AsrPrefs,
        loadAsrPrefs,
        saveAsrPrefs,
        asrModels,
        asrModelById;
export '../speech/tts_voices.dart'
    show TtsVoice, TtsPrefs, loadTtsPrefs, saveTtsPrefs, ttsVoices, voiceById;

/// Orchestrates the voice round trip and every state the chat screen
/// renders. One instance per app; the screens talk to it (and only it) —
/// through [view] for what to paint, and the intent methods for gestures.
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

    /// Test seam for the received-file open (Android channel by
    /// default; VM tests hand in a recorder).
    FileOpener? opener,

    /// Test seam for where received files land (default: app
    /// support/received — the platform the plugin knows).
    Future<String> Function()? receivedDir,
  }) {
    _clock = clock ?? wallClock;
    _scheduler = scheduler ?? const WallScheduler();
    _gatewayFactory = gatewayFactory;
    _worker = worker;
    _opener = opener ?? ChannelFileOpener();
    _receivedDir =
        receivedDir ??
        () async =>
            p.join((await getApplicationSupportDirectory()).path, 'received');

    _hops = HopTracker(
      clock: _clock,
      scheduler: _scheduler,
      repaint: notifyListeners,
    );
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
      // +213: the era a new bubble wears. Null with no bridge at all
      // (the offline demo belongs to every thread) and until /health
      // first names an era; typed sends count — they reach the harness
      // even with the voice toggle off, so the gate is the gateway,
      // not the speaker.
      harness: () => _gateway == null ? null : _bridgeHarness,
      // +223: the session a new bubble belongs to. The sentinel is
      // the birth-turn's honest 'name coming': the id exists first in
      // the harness's result, and adoptPending names every sentinel
      // the moment _refreshSession learns it.
      session: () =>
          _gateway == null ? null : (_sessionId ?? ChatStore.pendingSession),
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
      output: audioOutput ?? FilePlayerAudioOutput(note: _logDebug),
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
      source: micSource ?? RecordMicSource(log: _logDebug),
      scheduler: _scheduler,
      clock: _clock,
      log: _logDebug,
      streamWanted: () => _micStreamWanted,
      route: () => _micRoute,
      paused: () => _backgrounded,
      audioBusy: () => _reply.playing || _reply.queuedCount > 0,
      onRaw: _onPcm,
      onVadWindow: (w) {
        _noteAudioLevel(w); // the ripple meter breathes in both modes
        _worker?.sendAudio(w);
      },
      gatePin: (on) => _worker?.setPlaying(on),
      resetVad: () => _worker?.resetVad(),
      userSpeaking: () => _userSpeaking,
      reopened: _onMicReopened,
      failed: _fail,
      disposed: () => _disposed,
      // +319: capture truly gone → leave Android's call mode and lay a
      // 0.4 s silence so the headset's line release happens against
      // silence, not against the first word of the reply (the field's
      // thin-first-chunk tape). Idle-guarded inside the pipeline.
      onClosed: _reply.holdOutputRoute,
    );
    _reply.log = _logDebug;
    // +298 (+251 step 3): the seat starts on the UNNAMED slot; the
    // map below grows a channel per conversation the ledger names.
    final boot = _openChannel();
    _activeChan = boot;
    _channels[_pendingKey] = boot;
  }

  /// One conversation's wire companions (session_channel.dart): the
  /// turn machine, its meter, its retry ladder. Every env closure binds
  /// THIS channel (the late `chan` binding is what lets the ladder's
  /// env speak of the channel it serves, not whichever tab is seated
  /// when a rung fires): +249..+297's owner gates dissolve into that
  /// binding — a channel can only ever speak for its own conversation.
  SessionChannel _openChannel() {
    final ticker = TokenTicker(clock: _clock, repaint: notifyListeners);
    late final SessionChannel chan;
    late final TurnCoordinator turn; // late: hardStop speaks of the machine
    turn = TurnCoordinator(
      clock: _clock,
      log: _logDebug,
      hardStop: () async {
        // +257: cut the conversation the machine holds (its frames
        // named it), not whichever tab is seated — every conversation
        // has its own floor, and the Stop chip cuts the one this
        // phone is listening to.
        await _gateway?.stop(sid: turn.workOwner ?? chan.sessionId);
      },
      beforeDetach: () => chan.chain.cancel(),
      afterDetach: _reply.clearAndClose,
      // The pin that labels a step for the bottom line is THIS
      // conversation's pin (ChatStore keeps them per session).
      queuedPin: () =>
          _chat.queuedFor(chan.sessionId ?? ChatStore.pendingSession) != null,
    );
    // The retry ladder for views that died mid-turn — per conversation
    // (+287's 'retire only on its OWN clean bill' is now the ladder's
    // shape: it belongs to, and settles, the channel it armed on).
    final chain = ReattachChain(
      scheduler: _scheduler,
      env: ReattachEnv(
        canProbe: () => _gateway != null && _worker != null,
        busy: () => turn.busy,
        generation: () => turn.generation,
        turnSeq: () => turn.seq,
        pointersDown: () => _ptt.pointers > 0,
        probe: () => _gateway?.healthInfo() ?? Future.value(null),
        noteHealth: _transport.noteHealth,
        reattach: (health) => reattachBackgroundTurn(health: health, via: chan),
        retireWork: () {
          // +277: the orphan's band goes with its badge.
          final ownedBy = turn.workOwner ?? chan.sessionId;
          turn.retireBadgeAndWork();
          _clearOwnedBand(ownedBy);
        },
        idleReady: _idleReady,
        setStatus: _setStatus,
        log: _logDebug,
        repaint: notifyListeners,
        // +287: the chain retires only on its OWN conversation's clean
        // bill — the turn's claimed owner first, the signed home
        // marker behind it (the same pair +276's badge gate reads).
        // +298: the marker is gone; the LADDER is the marker.
        ownerSid: () => turn.workOwner,
      ),
    );
    chan = SessionChannel(turn: turn, ticker: ticker, chain: chain);
    return chan;
  }

  // Silence duration that ends an utterance in conversation mode.
  static const _endpointSilence = 1.0;

  late final Clock _clock;
  late final Scheduler _scheduler;
  late final HarnessGateway Function(String url, String token)? _gatewayFactory;
  SpeechEngine? _worker;

  /// The boot's voice arrival (+349): a press landing in the load
  /// window registers and the mic opens — its release WAITS here
  /// (bounded) instead of the press dying as a stray (the field tape:
  /// after a restart the first two presses ate themselves as 'ptt UP
  /// ignored: no pointer down', and the ear read it as something else
  /// holding the mic). Real init completes it at SpeechWorker.start.
  final Completer<void> _voiceReady = Completer<void>();

  /// A conversation segment captured in the load window (+349): held
  /// until the voice arrives, then transcribed — the load window's twin
  /// of the PTT release's wait. (The crash this field prevents was
  /// LATENT on main: a conversation tap opened the mic with no engine,
  /// and the first VAD segment hit `_worker!` bare.)
  Float32List? _heldSegment;
  late final MicPipeline _mic;
  late final ReplyPipeline _reply;
  late final HopTracker _hops;
  late final NarrationGate _narr;
  late final ChatStore _chat;
  late final BridgeTransport _transport;
  late final WireLease _lease;
  late final PttHold _ptt;
  Timer? _pttMaxTimer; // a lost release must not latch the mic on

  InteractionMode _mode = InteractionMode.conversation;
  AssistantPhase _phase = AssistantPhase.idle;
  Activity _activity = const LoadingModels();
  String _transcript = '';
  String _error = '';
  String _lastSpoken = '';

  // ── The foreign-say ledger (mid → sid + first words) ─────────────────
  /// What the +274 gate's refusals owe the tape: the take journals the
  /// drain's pickup from here (the missing middle of a refused-then-
  /// served say), and a turn retired unheard names its refused paragraphs
  /// as its audio fate. Bounded; an entry lives until its say is taken.
  final Map<int, ({String sid, String preview})> _refusedSays = {};
  void _noteRefusedSay(int mid, String? sid, String preview) {
    if (mid == 0) return;
    // +313: a say refused for a conversation with NO home will never
    // be served — the +348 ledger must not hold it as an open story.
    // The gate line is the story's honest end.
    if (sid != null && _channelIfKnown(sid) == null) {
      _logDebug(
        'say#$mid refused for a departed conversation — dies at the '
        'gate: "${preview.length > 24 ? '${preview.substring(0, 24)}…' : preview}"',
      );
      return;
    }
    _refusedSays[mid] = (sid: sid ?? 'unstamped', preview: preview);
    while (_refusedSays.length > 64) {
      _refusedSays.remove(_refusedSays.keys.first);
    }
  }

  /// One-shot: claiming an entry is the take's own trace — it fires the
  /// pickup line once and keeps the retirement fate honest (a served say
  /// is no longer 'closed unheard').
  bool _claimRefusedSay(int mid) =>
      mid != 0 && _refusedSays.remove(mid) != null;

  /// A conversation's death takes its refused says: no owner drain will
  /// ever serve them (+313's 'nothing to pay', now covering the +347
  /// ledger too). Journalled, so the tape says the story ENDED rather
  /// than went missing.
  void _purgeRefusedSays(Iterable<String> sids) {
    final doomed = _refusedSays.entries
        .where((e) => sids.contains(e.value.sid))
        .toList();
    if (doomed.isEmpty) return;
    for (final e in doomed) {
      _refusedSays.remove(e.key);
    }
    _logDebug(
      'departed conversation: ${doomed.length} refused say(s) die with '
      'it (${doomed.map((e) => 'say#${e.key}').join(', ')})',
    );
  }
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

  // ── Input level (the talk surface's ripple breath) ────────────────────
  /// Recent mic energy, 0..1: per-chunk RMS (scaled), fast attack
  /// (speech jumps), per-chunk decay (~0.9 @ 16–32 ms windows ⇒ half
  /// life ~half a second). Fed from EVERY capture route (raw PTT/bench
  /// chunks and conversation VAD windows alike), zeroed whenever the mic
  /// closes so a new press starts from still water. The talk surface
  /// reads it through the view (AssistantView.ptt.micLevel) and turns
  /// it into ripple spawn-rate and size — the waveform you can see.
  double _micLevel = 0;
  double get micLevel => _micLevel;

  void _noteAudioLevel(Float32List samples) {
    if (samples.isEmpty) return;
    var sq = 0.0;
    for (final v in samples) {
      sq += v * v;
    }
    final rms = math.sqrt(sq / samples.length);
    // Speech RMS sits ~0.02–0.25 of full scale through the PCM16 gate;
    // x4 and clamp maps normal talk into a usable 0..1 spread.
    final v = (rms * 4.0).clamp(0.0, 1.0);
    _micLevel = v > _micLevel ? v : _micLevel * 0.90;
  }

  void _resetMicLevel() => _micLevel = 0;

  /// The cold-start model download/pack step FAILED (typically: the app
  /// was backgrounded and Android ate the transfer). Not fatal — the
  /// partial file is on disk, the retry ladder has the rest — but the
  /// worker stays null until one attempt gets through, so every way
  /// back to the network (a foreground, a tap) doubles as a retry
  /// trigger. See init().
  bool _modelsFailed = false;

  /// One re-armed attempt at a time (see [_retryModels]) — two parallel
  /// init() retries would append to the same .part from two sockets.
  bool _modelsRetrying = false;

  /// The background→foreground dance (hidden flag, was-live relisten
  /// intent, the cut-paragraph drop mark, the unheard-say buffer, the
  /// snapshotted working line) as one named-transition unit.
  final HideResume _hide = HideResume();

  InteractionMode get mode => _mode;
  AssistantPhase get phase => _phase;

  /// The status LINE as rendered prose — what the screen paints. The
  /// truth is [activity]; the words are its single render rule.
  String get status => _activity.text(mode: _mode);
  Activity get activity => _activity;
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

  /// Stamp the first-word latency once (the first audible chunk of a
  /// turn is where the pause the user feels actually ends).
  void _noteFirstWordLatency(Duration sinceText) {
    if (_ttsFirstTimed) return;
    _ttsFirstTimed = true;
    _ttsSeconds = sinceText.inMilliseconds / 1000.0;
  }

  // ── The projected screen (see view.dart) ───────────────────────────────
  /// +230: the thread law, tab edition. With a tab ledger the channel
  /// is the ACTIVE TAB's sessions — every id the tab ever wore (a
  /// resumed thread's whole past, a replaced one's history gone with
  /// its id), its still-nameless birth turn while it has none, the
  /// era it belongs to, and the shared prologue (un-owned bubbles:
  /// pre-law history and the offline demo, everyone's). No ledger
  /// (first launch, no bridge) and the pre-tab law stands verbatim:
  /// the live session, its sentinel while nameless, the prologue.
  /// The FILTER REMAINS RENDER-SIDE ONLY — see the +213/223 comment.
  bool _entryVisible(ChatEntry e) {
    if (e.harness != null && e.harness != _bridgeHarness) return false;
    if (e.session == null) return true; // shared prologue, every tab's
    final tab = _tab;
    if (tab == null) {
      return (e.session == ChatStore.pendingSession && _sessionId == null) ||
          e.session == _sessionId;
    }
    if (tab.sessionIds.contains(e.session)) return true;
    // The tab's own birth turn (sentinel) and a first id still in
    // flight (e.session == _sessionId while the ledger has no ids):
    // both belong to a tab that has not been NAMED yet, not to every
    // tab — a nameless one only.
    return tab.sessionIds.isEmpty &&
        (_sessionId == null
            ? e.session == ChatStore.pendingSession
            : e.session == _sessionId);
  }

  /// The pills' row data: one entry per tab, in creation order.
  List<SessionTabInfo> get _tabInfos {
    final t = _bridgePrefs.tabs;
    return [
      for (var i = 0; i < t.length; i++)
        SessionTabInfo(
          index: i,
          harness: t[i].harness,
          label: t[i].label.isEmpty ? t[i].dir : t[i].label,
          dir: t[i].dir,
          currentId: t[i].currentId,
          hue: t[i].hueOrDefault(i), // +271: the pill's AND wash's own
        ),
    ];
  }

  // +297's question — 'may THIS conversation's press laws look at the
  // live work?' — dissolved into the map: the getters the laws read
  // (`_bridgeBusy`, `_harnessBackgrounded`, `_ticker`) are the SEAT's
  // channel's own truth, and a stranger's turn lives in another
  // channel. Parking behind another tab's busy flag became
  // unrepresentable, which is exactly what +297 legislated by hand.

  /// The conversation screen as ONE immutable snapshot: what to paint,
  /// computed from the machine's truth in exactly one place. Widgets
  /// read this (or re-read it on their own tick through a [ViewSource]);
  /// gestures come back as the intent methods below.
  AssistantView get view {
    // +298 (+251 step 3): the snapshot is built FROM the seat's own
    // channel — busy-ness, banner and meter speak for the conversation
    // on screen by construction, so 'is the work's home here' is
    // answered by WHICH CHANNEL these getters read, not by a marker.
    // turnHomeHere stays in the view API (the +249-era widgets and
    // walks read it) and is now, honestly, always true of the channel
    // being projected: an away conversation's work has its own channel
    // and cannot borrow this tab's face. The +256 clause — a null
    // seat is not automatically home — holds too: the fresh tab looks
    // through the unnamed slot, not the work's channel.
    const turnHome = true;
    return AssistantView(
      phase: _phase,
      mode: _mode,
      activity: _activity,
      error: _error,
      // +213/223: the channel shows ONE THREAD: this session's bubbles
      // (which, while no id is known yet, also admits the unnamed
      // birth-turn ones) plus the un-era'd, un-owned prologue. The
      // FILTER IS RENDER-SIDE ONLY — the store underneath stays the
      // whole append-only log, so the reattach dedup, the receipt-by-id
      // law, and the heard ledger keep scanning everything: a task
      // finished under another project is still finished when this
      // one's replay arrives. Switch project or harness and the window
      // follows the conversation — cleared of one thread, restored to
      // the other's, nothing deleted.
      chat: _chat.entries.where(_entryVisible).toList(growable: false),
      chatVersion: _chat.version,
      // +275: the pin shown is the VISIBLE conversation's — another
      // tab may park its own prompt, and both pins stand.
      queued: _chat.queuedFor(_sessionId) == null
          ? null
          : QueuedPin(
              text: _chat.queuedTextFor(_sessionId) ?? '',
              createdMs: _chat.queuedFor(_sessionId)!.createdMs,
            ),
      backgrounded: BgWork(
        // +278: TIM's law, from the sleep-50 tape: the banner
        // PERSISTED across the swipe — and leaked onto the stranger
        // tab while it held. Holding is the state law (the debt is
        // owed wherever the thumb rests); the PAINTING is the
        // session law: the line belongs to the conversation that
        // owes it, so it renders on that tab only.
        visible: showsBackgroundedWork && _bannerAtHome,
        label: backgroundedWork,
        sinceMs: harnessSinceMs,
        elapsed: harnessElapsed,
      ),
      bridgeBusy: _bridgeBusy,
      harnessBackgrounded: _harnessBackgrounded,
      awaitPickup: _awaitPickup, // +295: the pin's own warrant
      // +298: the gear badge's cross-session sign — work alive on
      // another channel (busy, badge, promise or owed shell). Where
      // the marker era gated the paint by name, the map answers it
      // by construction.
      awayWork: _channels.values.any(
        (c) =>
            !identical(c, _chan) &&
            (c.turn.busy ||
                c.turn.backgrounded ||
                c.turn.detachedPromise ||
                c.turn.agentWork),
      ),
      turnHomeHere: turnHome,
      drainOwed: _drainAfterSpeech != null,
      drainReading: _drainReading,
      bridgeConfigured: bridgeConfigured,
      ttsOn: _bridgePrefs.tts,
      userSpeaking: _userSpeaking,
      token: TokenMeter(
        on: tokenTickerOn,
        out: tokensOut,
        inTok: tokensIn,
        thought: tokenThought,
        draft: tokenDraft,
        settled: turnSettled,
        activityLabel: activityLabel,
      ),
      context: ContextBarView(
        tokensIn: _contextIn,
        window: _contextWindow,
        // +256 (the xray tape): the bar belongs to the conversation
        // like the row — and 'busy' here drives the 'measuring…'
        // shimmer, so a STRANGER's open turn may not animate it. The
        // +249 owner gate kept the NUMBERS honest across a switch;
        // this keeps the MOTION honest: the shimmer spins only for
        // work this seat owns. (Numbers already follow the rule: the
        // manual zero at the switch and /health's owner gate blank
        // them together.)
        busy: _bridgeBusy && turnHome,
        model: _barModel, // +241: the name rides the bar it fills
      ),
      latency: LatencyView(
        recordSeconds: _recordSeconds,
        asrSeconds: _asrSeconds,
        ttsSeconds: _ttsSeconds,
        playSeconds: _reply.playSeconds,
        hopAsr: _hops.hopAsr,
        hopSent: _hops.hopSent,
        hopReply: _hops.hopReply,
        hopTts: _hops.hopTts,
      ),
      ptt: PttGuide(
        holdActive: pttHoldActive,
        slide: _ptt.slide,
        drag: _ptt.drag,
        holdOverTurn: _ptt.holdOverTurn,
        micLevel: _micLevel,
      ),
      sessionId: _sessionId,
      harnessElapsed: harnessElapsed,
      // +230: the tab ledger, projected. needsSetup is the first-launch
      // gate (fresh install, configured bridge, empty ledger); canSeat
      // is /health's word that /seat answers here.
      tabs: _tabInfos,
      tabIndex: _bridgePrefs.tabs.isEmpty
          ? 0
          : _bridgePrefs.activeTab.clamp(0, _bridgePrefs.tabs.length - 1),
      needsSetup:
          !_bridgePrefs.installed &&
          bridgeConfigured &&
          _bridgePrefs.tabs.isEmpty,
      canSeat: _seatCap,
    );
  }

  // ── Latency strip moments (see HopTracker) ─────────────────────────────
  bool get hopAsr => _hops.hopAsr;
  bool get hopSent => _hops.hopSent;
  bool get hopReply => _hops.hopReply;
  bool get hopTts => _hops.hopTts;

  // ── Voice selection & cloning ───────────────────────────────────────────
  late final FileOpener _opener;
  late final Future<String> Function() _receivedDir;
  String _modelsDir = '';
  TtsPrefs _prefs = TtsPrefs();
  AsrPrefs _asrPrefs = AsrPrefs();
  String _activeVoiceId = 'titl';
  String _activeAsrId = 'tiny.en';
  int _ttsNumSpeakers = 0; // engine roster size; 0 = none loaded yet
  String _voiceStatus = ''; // one-line feedback for the voice screen
  bool _voiceBusy = false; // download / engine swap in progress

  List<TtsVoice> get voices => ttsVoices;
  List<AsrModel> get asrOptions => asrModels;
  String get modelsDir => _modelsDir;
  String get ttsVoiceId => _activeVoiceId;
  String get asrModelId => _activeAsrId;
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

  /// +230: test seam — assistant-level walks inject the on-disk-shaped
  /// prefs (the boot path loads them inside init(), behind the pack
  /// downloads); the tab law is walked from here.
  @visibleForTesting
  set bridgePrefsForTest(BridgePrefs p) {
    _bridgePrefs = p;
    notifyListeners();
  }

  HarnessGateway? _gateway;
  // ── Bridge-turn truth (owned by TurnCoordinator — see turn_session.dart) ──
  // This class only READS the truth (below) and fires the coordinator's
  // named transitions; the old raw fields' meaning now lives on those
  // methods' docs. What each getter answers:
  //
  // +298 (+251 step 3): the store. One SESSION CHANNEL per conversation
  // — the review's SessionStore[sessionId], turn slice — keyed by the
  // conversation's app id (the bridge's uuid-at-birth, +295). The
  // unnamed slot (ChatStore.pendingSession) houses a conversation
  // before its first name is spoken; _name() re-keys it when the wire
  // speaks one — the exact law ChatStore's pending bubbles follow, for
  // the exact same reason: what must survive naming is the bookkeeping,
  // not the label. `_chan` answers for the SEAT, so every +250-era
  // getter and walk stays intact across the storage move; the marker
  // laws it replaces (turnHomeSid above all) are gone with the concept
  // that needed them.
  final Map<String, SessionChannel> _channels = {};
  SessionChannel? _activeChan;
  static String get _pendingKey => ChatStore.pendingSession;

  /// The channel the seat looks through — the conversation on screen.
  SessionChannel get _chan => _activeChan ??= _channelFor(null);

  /// The channel that speaks for [sid] (the pending slot when unnamed),
  /// minted on first sight. Does NOT move the seat.
  SessionChannel _channelFor(String? sid) {
    final key = (sid == null || sid.isEmpty) ? _pendingKey : sid;
    return _channels.putIfAbsent(key, () {
      final c = _openChannel();
      c.sessionId = sid;
      return c;
    });
  }

  /// Re-key [chan] to wear [id]: the pending slot adopts the name the
  /// wire just spoke (/seat answers, /health glances, the +290 reattach
  /// wear). A channel already wearing that name is the ELDER — the
  /// conversation was seen before — and its life stands; the speaker's
  /// (unnamed) slot resets fresh.
  void _name(SessionChannel chan, String? id) {
    final key = (id == null || id.isEmpty) ? _pendingKey : id;
    final old = chan.sessionId;
    final oldKey = (old == null || old.isEmpty) ? _pendingKey : old;
    if (oldKey == key) {
      chan.sessionId = id;
      return;
    }
    if (_channels[oldKey] == chan) _channels.remove(oldKey);
    final elder = _channels[key];
    if (elder != null && elder != chan) {
      // The life under the name is older than the nameless claim:
      // the ELDER keeps living (its debts, its turn, its meter) and
      // the claim dissolves into it — the seat follows the life, and
      // a fresh unnamed slot stands where the claim was.
      elder.sessionId = id;
      _channels[key] = elder;
      if (identical(chan, _activeChan)) _activeChan = elder;
      chan.sessionId = null;
      _channels[_pendingKey] = chan;
      return;
    }
    chan.sessionId = id;
    _channels[key] = chan;
    if (identical(chan, _activeChan)) _activeChan = chan;
  }

  /// Move the seat's eye to the channel for [id] (created when this app
  /// has not seen that conversation yet).
  SessionChannel _switchToChannel(String? id) => _activeChan = _channelFor(id);

  /// The active channel wears [id] — every former `_sessionId = ...`
  /// door (the seat's name moved; the bookkeeping rides with it).
  void _setSessionId(String? id) => _name(_chan, id);

  /// +298: the tab's ledger is dropping these conversations — their
  /// channels go (debts buried first, so the band cache follows the
  /// receipt path, not a vanish), and a seat left without its channel
  /// lands on the unnamed slot.
  void _purgeChannelsOwned(Iterable<String> ids) {
    for (final c in _channels.values.toList()) {
      c.turn.retireIfOwned({...ids, _pendingKey});
    }
    for (final id in ids) {
      // +313: the tombstone. Deletion is a FACT about the name, not
      // just an event in the map — a late frame must not undo it,
      // and the map alone cannot say 'removed' apart from 'never
      // there'. Bounded by the (small) set of names one phone ever
      // deletes.
      _purgedSids.add(id);
      if (_purgedSids.length > 64) {
        _purgedSids.remove(_purgedSids.first);
      }
      final chan = _channels.remove(id);
      if (chan == null) continue;
      if (identical(chan, _activeChan)) _activeChan = _channelFor(null);
      chan.dispose();
    }
  }

  /// +298: test seam — the per-conversation ledger as the store keys
  /// it (does NOT move the seat; creates on sight, like the wire does).
  @visibleForTesting
  SessionChannel channelForTest(String? sid) => _channelFor(sid);

  /// +313: the non-creating view of the map — a channel is LIVE only
  /// if birth made it and no purge has unmade it. Event paths ask
  /// this; only tab code asks [channelForTest]'s creating cousin.
  SessionChannel? liveChannel(String? sid) =>
      sid == null || sid.isEmpty ? _chan : _channels[sid];

  /// +313: the resolution every FRAME takes. A frame addressed to a
  /// conversation may never RESURRECT it — the channel is its home on
  /// this phone, created by birth (a tab, a landing, a resume) and
  /// destroyed with the tab. The one exception is a still-kept tab
  /// whose channel this process has not opened yet (prefs restored a
  /// ledger the user never visited since boot): its birth already
  /// happened, and paying its own report is opening a door that is
  /// already owed to it. A DELETED tab is not that: the purge took
  /// both the row and the home, and the receipt for a burned-down
  /// house pays nobody.
  final _purgedSids = <String>{};
  SessionChannel? _channelIfKnown(String? sid) {
    final live = liveChannel(sid);
    if (live != null) return live;
    if (sid != null && _purgedSids.contains(sid)) return null; // +313
    if (sid == null ||
        _bridgePrefs.tabs.any((t) => t.sessionIds.contains(sid))) {
      return _channelFor(sid);
    }
    // +298's law holds for the never-seen: a stamped frame may open a
    // ledger for a conversation this phone has no tab for (the meter
    // ticks for work you don't watch). +313's law is that DELETION
    // outranks stamping — the tombstone above is the whole of the
    // difference.
    return _channelFor(sid);
  }

  TurnCoordinator get _turn => _chan.turn;
  TokenTicker get _ticker => _chan.ticker;
  ReattachChain get _chain => _chan.chain;

  /// A bridge turn is in flight (chips disabled).
  bool get _bridgeBusy => _turn.busy;

  /// A turn the phone detached keeps working on the bridge with no ear
  /// on it: the terminal badge stays lit until a heard turn starts,
  /// /stop lands, or /new resets it.
  bool get _harnessBackgrounded => _turn.backgrounded;

  /// Wall clock the in-flight bridge turn started.

  /// Busy-flag ownership token (turns claim it via the coordinator).
  int get _bridgeTurnSeq => _turn.seq;

  /// Cancels in-flight responses when bumped (via [TurnCoordinator.supersede]).
  int get _generation => _turn.generation;

  /// What the harness is doing OUT OF EARSHOT — the bottom line's
  /// snapshot, fed by [TurnCoordinator.detach] and [TurnCoordinator.noteToolStep].
  String get _bgWork => _turn.bgWork;

  /// wire v2: what this phone has TAKEN (mids), on disk, with the
  /// bridge's /heard acks queued until the wire allows. The one dedup
  /// for every view and every replay — loaded with the models dir,
  /// null only before init (isHeard answers false: a fresh install
  /// speaks everything, which is the truth).
  HeardLedger? _heardLedger;

  /// The one ledger. Before init loads the disk copy (or in a test that
  /// never unpacks models) an in-memory one serves: dedup is per-process
  /// truth, persistence only widens it across restarts.
  HeardLedger get _heard => _heardLedger ??= HeardLedger(
    send: (mids) async => await _gateway?.heard(mids) ?? false,
  );

  // ── Phone-side journal (src/journal/) — the same notes mirrored
  // to disk AND served over HTTP for the bridge to poll: the desktop half
  // of "background → foreground and nothing happened" triage needs the
  // phone's OWN account of hide/resume/stream-death timing, in the same
  // journalctl the bridge's relays land in. Started in init(); null until
  // the models dir (its home) exists, and survivably null after if the
  // bind failed — the app never needs its own journal to function.
  AppEventJournal? _events;
  int _eventsPort = 0; // what /health & friends announce; 0 = not served

  /// Screenshot-able event ring for barge-in/edge forensics: every worker
  /// diagnostic note that matters (barge-in candidates), chunk seams, and
  /// mic lifecycle, newest last. See the debug view.
  final List<String> _debugLog = [];
  List<String> get debugLog => _debugLog;

  /// Test seam (+349): hand the assistant its engine LATER — the
  /// press-during-load walk needs the arrival to be a journaled event,
  /// not a constructor fact. Real init arrives at the same place via
  /// [_voiceArrived].
  @visibleForTesting
  void setWorkerForTest(SpeechEngine w) {
    _worker = w;
    _logDebug('voice arrived (test seam) — the waiting release proceeds');
    _voiceArrived();
  }
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
  /// +194: the screen's sticky-bottom follow reports its pins here so
  /// the tape can say what the viewport did around a send (the scroll
  /// complaint relapsed once already; no more fixing by theory).
  void logFollow(String line) => _logDebug('follow: $line');

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
    'reattachStep': _chain.step,
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

  String get _chatPath => p.join(_modelsDir, 'chat_log.json');

  /// +199: persistence is COALESCED. Every mutation used to encode AND
  /// fsync the whole log right now — a streamed answer paid a full disk
  /// round trip per spoken section, and the hitch landed exactly on the
  /// entrances the field is now watching ('the animation is not as
  /// smooth'). The latest snapshot waits 400 ms behind a restartable
  /// timer instead: a burst of sections writes ONCE, and the lifecycle
  /// hook (anything heading for the background flushes first) plus
  /// dispose keep the crash story no worse than atomic-write territory.
  Timer? _chatPersistTimer;
  List<ChatEntry>? _pendingChatEntries;

  Future<void> _persistChat(List<ChatEntry> snapshot) async {
    if (_modelsDir.isEmpty) return;
    _pendingChatEntries = snapshot;
    _chatPersistTimer?.cancel();
    _chatPersistTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_flushChatPersist());
    });
  }

  /// Write the newest snapshot NOW (lifecycle pause, dispose, tests).
  /// +205: the encode crossed the seam with the contract — the store
  /// hands over a list, and the JSON for eighty entries (a 71 ms build
  /// spike the frame bill billed straight to the entrance) is minted
  /// on a worker isolate, once per burst, while the UI thread stays
  /// free to glide.
  Future<void> _flushChatPersist() async {
    _chatPersistTimer?.cancel();
    _chatPersistTimer = null;
    final entries = _pendingChatEntries;
    _pendingChatEntries = null;
    if (entries == null || _modelsDir.isEmpty) return;
    try {
      final json = await Isolate.run(() => encodeChatLog(entries));
      // Atomic: write beside the log, then rename over it. An OS kill
      // mid-write used to leave a half-written chat_log.json, which the
      // tolerant decoder reads as "no history" — and the next bubble
      // persisted that emptiness right back over the file, making the
      // loss real and silent. A rename can't be caught halfway.
      final tmp = File('$_chatPath.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(_chatPath);
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

  /// Whether the channel's bottom line is warranted right now — and
  /// the warrant is UNHEARD work, +145: the badge (a detached turn
  /// the phone stopped listening to), the cut-tool promise (a tool a
  /// cut orphaned, owed its receipt), or the agent's own backgrounded
  /// shell. A queue PIN alone does NOT warrant it: the field caught
  /// the line claiming 'working in the background' for a sleep the
  /// agent was waiting on in the FOREGROUND while the phone's own
  /// parked queue view kept hearing its tail — that wait is told by
  /// the pin card and the spinner, not by a row that lies. Every
  /// completion path clears the three, so the empty string IS the
  /// auto-dismiss: /stop, an orphan retire, a health probe that
  /// finds nothing open, or the tool's 'finished' receipt paying the
  /// promise.
  bool get showsBackgroundedWork =>
      _turn.backgroundUnheard || _turn.detachedPromise || _turn.agentWork;

  /// +278→+279.1: does the lit banner belong to the conversation on
  /// screen? Ownership is resolved PER SEAT: this thread's own owed
  /// row answers yes; a ledger owed ONLY elsewhere answers no (the
  /// oldest debt's tab must show its own banner, not be hidden by a
  /// newer stranger's — 'swipe to the previous session that is also
  /// doing the sleep and the banner is gone'). With no debt rows,
  /// the single-owner badge answers by its stamp; an unstamped badge
  /// (the pre-tab world) belongs to the only conversation there is.
  // +298: STRUCTURAL now — the banner rows live on the channel that
  // owes them; `_turn` is the seat's channel, so every row this getter
  // can see is by construction this conversation's own. The +279/279.1
  // 'per seat, per row' laws survive as the map's shape: another tab's
  // owed shell is in ANOTHER channel and was never visible here.
  bool get _bannerAtHome => true;

  /// The banner's clock: this seat's debt row's launch-time when one
  /// is owed, else the badge's own clock (+279.1 — never a global
  /// _since standing in for another conversation's sleep).
  DateTime? get _bannerSince {
    final d = _turn.debtFor(_sessionId);
    if (d != null) {
      return DateTime.fromMillisecondsSinceEpoch(d.sinceMs);
    }
    return _turn.since;
  }

  String get backgroundedWork {
    if (!showsBackgroundedWork || !_bannerAtHome) return '';
    return _turn.debtFor(_sessionId)?.label ?? _bgWork;
  }

  /// Start of the backgrounded turn (epoch ms, 0 = unknown) for the
  /// bottom line's 'since HH:MM:SS'; its live age is [harnessElapsed].
  int get harnessSinceMs =>
      _bannerSince == null ? 0 : _bannerSince!.millisecondsSinceEpoch;

  /// How long the conversation's work (its banner's debt, or the
  /// in-flight turn) has been running: the elapsed readout on the
  /// chat window's spinner and the backgrounded-work line (+279.1:
  /// the seat's OWN row's age — session B never counts session A's
  /// sleep).
  Duration get harnessElapsed =>
      _bannerSince == null ? Duration.zero : _clock().difference(_bannerSince!);
  bool get bridgeVoice => _bridgePrefs.voice;
  String get bridgeUrlText => _bridgePrefs.url;
  String get bridgeTokenText => _bridgePrefs.token;
  bool get bridgeNarrate => _bridgePrefs.narrate;
  bool get bridgeTts => _bridgePrefs.tts;

  /// Replies speak only when the TTS pref is on (see BridgePrefs.tts):
  /// the text-only gate every audio path consults.
  bool get _ttsOff => !_bridgePrefs.tts;

  /// The harness conversation's fingerprint (GET /health sessionId), kept
  /// current for the chat screen's top row: refreshed at boot and at the
  /// end of every bridge turn (the /new chips and /stop path included —
  /// all of them run through runQuickCommand's finally, which re-reads
  /// /health after the bridge's result event has persisted the pointer,
  /// so the app can never see the file before the server wrote it). The
  /// id only moves when /new drops it or a death-resume forks it — an
  /// id that never moves across dozens of talks IS the continuity proof.
  // +251: the id is CHANNEL state — the delegating pair keeps every
  // call site (and every walk) reading the conversation it focuses.
  String? get _sessionId => _chan.sessionId;
  set _sessionId(String? v) => _chan.sessionId = v;
  String? get sessionId => _sessionId;

  /// +213: which harness /health last said holds the pen ('claude' |
  /// 'opencode'; null = a bridge too old to name one, or none seen
  /// yet). The chat split is keyed on this: every bubble stamps its
  /// era at birth (see ChatStore.harness) and the projected channel
  /// shows only the current era's thread plus the un-era'd prologue.
  /// Read by _refreshSession — every glance at the bridge updates it,
  /// including the bridge's own out-of-band flips.
  String? _bridgeHarness;
  String? get bridgeHarness => _bridgeHarness;

  /// +230: the session-tab ledger's live flags. `_seatCap` is /health's
  /// word on whether THIS bridge answers /seat (feature flag — an
  /// older one keeps the app's single-thread behavior rather than
  /// guessing from a 404); `_seatReconciled` marks this boot's one
  /// seat-vs-ledger reconciliation as spent, so a later out-of-band
  /// flip (a curl, the Bridge row) is the tracker's business, not a
  /// re-seat fight.
  bool _seatCap = false;
  bool _seatReconciled = false;

  /// The freshest /health payload seen (null = none yet / unreachable)
  /// — the sheet's 'use what it already has', the folder row, and the
  /// tab guard read this instead of firing their own glances.
  Map<String, Object>? get bridgeHealthCache => _lastHealth;
  Map<String, Object>? _lastHealth;

  // Context consumption for the bar above the talk button: fed by
  // `context` events mid-turn/at turn end and by every /health read
  // (_refreshSession runs at startup, after setBridge, and in
  // runQuickCommand's finally — so the bar survives app restarts and
  // detached turns alike). Window 0 = no `result` has named one yet.
  // +251: the sizes are CHANNEL state — every conversation owns its
  // own bar; the pair forwards the focused one's numbers.
  int get _contextIn => _chan.contextIn;
  set _contextIn(int v) => _chan.contextIn = v;

  /// +249: the conversation the LIVE work belongs to, when a mid-turn
  /// switch backgrounded it (captured at switchSession from the id the
  /// seat held); null = the work, if any, is the seat's own. Gates the
  /// working row (view.turnHomeHere) and the context merge, so neither
  /// the thought box nor the context bar ever shows one thread's
  /// business on another's face. Cleared whenever the seat itself
  /// starts a turn (runQuickCommand).
  // The marker is CHANNEL state too (its step-3 deletion is planned):
  // it can only ever name an away-work belonging to the channel you
  // are looking through.
  int get _contextWindow => _chan.contextWindow;
  set _contextWindow(int v) => _chan.contextWindow = v;
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
    if (!changed) return;
    // +280 (Tim): the number that just landed is the SEEDED tab's
    // (the wire's barHome gate and the /health owner law both ensure
    // that) — so the tab ledger remembers it. Every later swipe home
    // paints this reading immediately instead of a 'measuring'
    // placeholder, and the next arrival here simply updates it.
    _stashContext(_tab);
    unawaited(_saveBridgePrefs());
    notifyListeners();
  }

  /// +280: file the bar's current numbers into [t]'s ledger. Zeros are
  /// never filed — a blank reading is 'not yet known', not a size (the
  /// same reason the merge ignores zeros).
  void _stashContext(SessionTab? t) {
    if (t == null) return;
    if (_contextIn > 0) t.ctxIn = _contextIn;
    if (_contextWindow > 0) t.ctxWindow = _contextWindow;
  }

  /// +280: the bar lands WEARING the landing tab's own remembered
  /// reading (a fresh tab knows nothing, exactly as it should) — every
  /// landing path calls this before the refresh: the swipe home
  /// (switchSession), a creation (createSession), the cold start
  /// (init). A fresher /health or context frame updates it on arrival;
  /// a bridge that currently says zero leaves the remembered truth
  /// standing, because the merge ignores zeros by law.
  void _landBarOnTab(SessionTab t) {
    _contextIn = t.ctxIn ?? 0;
    _contextWindow = t.ctxWindow ?? 0;
  }

  // ── +230: session tabs ────────────────────────────────────────────────

  /// The tab whose thread the channel paints and whose seat /talk
  /// speaks into; null while the ledger is empty (first launch, or an
  /// app pointed at no bridge). Clamps the stored index on the way
  /// past it, so a deleted tab can never strand the pointer.
  SessionTab? get _tab {
    final t = _bridgePrefs.tabs;
    if (t.isEmpty) return null;
    final i = _bridgePrefs.activeTab.clamp(0, t.length - 1);
    _bridgePrefs.activeTab = i;
    return t[i];
  }

  /// The one-time upgrade seed + the boot reconcile + the id
  /// recording — everything the tab ledger learns from a /health
  /// glance, run at the TOP of _refreshSession so the era/session
  /// bookkeeping below sees a ledger that already knows the truth.
  void _tabsOnHealth(Map<String, Object>? h, String? eraNow, String? sid) {
    _seatCap = h?['seat'] == true;
    if (h == null) return;
    // The seed: an UPGRADE (its prefs predate the tab law) with no
    // tabs, meeting a bridge that names a live seat, converts that
    // seat into tab 1 without a dialog — the thread the user already
    // lives in becomes the first tab. A FRESH install is NOT seeded:
    // the first-launch sheet owns that question.
    if (_bridgePrefs.installed &&
        _bridgePrefs.tabs.isEmpty &&
        eraNow != null &&
        h['dir'] is String) {
      final d = h['dir'] as String;
      _bridgePrefs.tabs.add(
        SessionTab(
          harness: eraNow,
          dir: d,
          model: h['model'] is String ? h['model'] as String : null,
          sessionIds: sid == null ? [] : [sid],
          createdMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      unawaited(_saveBridgePrefs());
      notifyListeners();
      return;
    }
    final tab = _tab;
    if (tab == null) return;
    // The boot reconcile: /health holds a DIFFERENT seat than the
    // active tab describes (a bridge restart landed on a pointer, a
    // sibling app flipped the seat, the phone moved while away) —
    // and nothing is mid-turn to be killed by the move — put the
    // seat back on the user's tab, once, silently.
    if (!_seatReconciled) {
      // The rest law covers the reconcile too: a backlog (missed > 0)
      // means the bridge still owes this phone a replay — re-seating
      // now would resetConversation over it and lose the unseen
      // messages before the resume path can drain them. The flag
      // stays unspent: the next glance reconciles once the replay
      // has landed.
      if (h['turnOpen'] == true ||
          h['queued'] == true ||
          ((h['missed'] as num?)?.toInt() ?? 0) > 0) {
        return;
      }
      final mismatch =
          eraNow != tab.harness ||
          h['dir'] != tab.dir ||
          (tab.currentId != null && sid != tab.currentId);
      if (mismatch && _seatCap) unawaited(_reseatTab('boot reconcile'));
      _seatReconciled = true;
      return;
    }
    // Id recording: a conversation this tab spoke gets filed under
    // it — but only while the SEAT matches the tab (era and dir),
    // or the tab is still nameless (its own birth turn: the id
    // arrives before any switch could have moved the seat). An id
    // seen while riding someone else's seat belongs to THAT rider.
    if (sid != null &&
        !tab.sessionIds.contains(sid) &&
        (eraNow == tab.harness && h['dir'] == tab.dir ||
            tab.sessionIds.isEmpty)) {
      tab.sessionIds.add(sid);
      unawaited(_saveBridgePrefs());
    }
  }

  /// The seat's rest law (+230; retuned by +324, +330 — and by +332,
  /// Tim's 'we should be able to create a new session whenever we
  /// want'). /seat is a RECORD SWAP: a live turn being left BACKGROUNDS
  /// (+246/+248) whether the destination is named or fresh — the
  /// conversation keeps its child, its queue and its backlog IN ITS OWN
  /// RECORD, and its reply stays ADDRESSED to it (+331's say gate), so
  /// mid-turn rests NOTHING. What still rests a seat VERB:
  /// a prompt parked with no open turn to flush it (no backgrounding
  /// can carry it — whatever the bridge resets would drop it), and —
  /// only where a WIPE of the conversation being left actually runs
  /// ([resets]: a fresh seat over a fully resting one, or a doomed
  /// tab's close) — an unheard BACKLOG (missed > 0) that wipe would
  /// silently eat. The refusal is self-healing: it arms the reattach
  /// chain NOW (the same +168 mail-fetch, honest dark), so the replay
  /// lands within a round trip and the next press moves. [doomed] is
  /// the death shape (+323): the doomed row's own live turn or parked
  /// prompt is a deletion's silent eat, so there the old strict verdict
  /// stands. Null = free to move; a string is the reason, in words.
  /// Every verdict, free or refused, journalled with its inputs
  /// (+247) so the field's 'I still see the refusal' reads the exact
  /// clause from /applogs.
  String? _seatRest(
    Map<String, Object>? h, {
    bool resets = false,
    bool doomed = false,
  }) {
    if (h == null) return null; // unreachable: the verb's own error speaks
    final turnOpen = h['turnOpen'] == true;
    final queued = h['queued'] == true;
    final missed = ((h['missed'] as num?)?.toInt() ?? 0) > 0;
    String? rest(String? why) {
      _logDebug(
        'seat rest: turnOpen=$turnOpen queued=$queued missed=${h['missed']} '
        'harness=${h['harness']} resets=$resets -> ${why ?? 'free to move'}',
      );
      return why;
    }

    // +332: mid-turn rests NOTHING for a move or a creation — the
    // flush and the turn ride the backgrounding together. The doomed
    // row keeps +323's strict shape: a death does not background, it
    // discards, so the doomed thread's own live turn or parked prompt
    // refuses its ✕.
    if (doomed && (turnOpen || queued)) {
      return rest(
        'the harness is mid-turn — stop it before switching sessions',
      );
    }
    // A parked prompt rests a move only with NO open turn to flush it:
    // mid-turn the queue belongs to the conversation being backgrounded,
    // and its own turn is still there to flush it (+332 extended this
    // to creation — the bridge backgrounds a live turn fresh:true or
    // not, so the old resets-and-queued asymmetry is gone).
    if (queued && !turnOpen) {
      return rest('a prompt is queued — stop it before switching sessions');
    }
    // +324: only a RESET eats the backlog — the law that refused a
    // plain seat move was a single-conversation relic. Since +257
    // every record carries its OWN backlog: a swipe to a named tab
    // parks the owed mail where it lives, and the return's /attach
    // replays it (+298's every-tab-keeps-its-own-face). Refusing the
    // swipe showed a banner that blocked navigation to protect mail
    // that was never at risk. A wipe does kill it — THAT rests: a
    // fresh seat over a FULLY RESTING conversation (+332: mid-turn,
    // the wipe never runs — the record lives on with its mail, so the
    // refusal would protect nothing), or a doomed tab's close. Drain
    // still starts on the spot either way.
    if (missed && resets && (doomed || !turnOpen)) {
      if (!_bridgeBusy &&
          !_turn.backgrounded &&
          !_benchCapturing &&
          !_benchBusy &&
          _ptt.pointers == 0 &&
          !_chain.armed) {
        _chain.start(
          gen: _generation,
          seq: _bridgeTurnSeq,
          firstProbe: Duration.zero,
        );
      }
      return rest('the bridge owes unheard messages — they land first');
    }
    return rest(null);
  }

  /// The first-launch / swipe-right creation...
  Future<String?> createSession({
    required String harness,
    String? model,
    required String dir,
  }) async {
    final g = _gateway;
    if (g == null) return 'bridge not configured — set url and token';
    // +332: creation mid-turn BACKGROUNDS — the turn being left keeps
    // its life in its own record and its reply stays addressed to it.
    // It still consults the rest law, because a fresh seat over a
    // FULLY RESTING one runs the reset, and that wipe drops the
    // backlog — unseen messages leave with the seat that owed them.
    final rest = _seatRest(await bridgeHealth(), resets: true);
    if (rest != null) return rest;
    final r = await g.seat(
      harness: harness,
      dir: dir,
      model: model,
      fresh: true,
    );
    if (r == null) {
      return 'this bridge has no /seat — session tabs need the new claude_bridge.mjs';
    }
    if (r['ok'] != true) {
      return '${r['error'] ?? 'the bridge refused the seat'}';
    }
    final prefs = _bridgePrefs;
    prefs.tabs.add(
      SessionTab(
        harness: '${r['harness'] ?? harness}',
        dir: '${r['dir'] ?? dir}',
        model: r['model'] is String ? r['model'] as String : model,
        sessionIds: r['sessionId'] is String ? [r['sessionId'] as String] : [],
        createdMs: DateTime.now().millisecondsSinceEpoch,
        // +271: the session's colour is drawn at its birth and kept
        // for life — the seed tab (the upgrade's first seat) and an
        // adopted tab wear the legacy index hue until +271-era tabs
        // prove the random one more legible.
        hue: SessionTab.pickHue([
          for (var i = 0; i < prefs.tabs.length; i++)
            prefs.tabs[i].hueOrDefault(i),
        ]),
      ),
    );
    prefs.activeTab = prefs.tabs.length - 1;
    // +298: the creation names the channel in hand when the sheet sat
    // on an unnamed tab (adopt), and lands on a fresh channel otherwise
    // (the conversation you left keeps its own life).
    final bornId = r['sessionId'] is String ? r['sessionId'] as String : null;
    if (_chan.sessionId == null) {
      _name(_chan, bornId);
    } else {
      _switchToChannel(bornId);
    }
    // +280: a creation is a landing too — and a brand-new tab knows
    // nothing, so the bar it wears is blank, not the numbers the
    // conversation you came from was showing a second ago.
    _landBarOnTab(prefs.tabs.last);
    _noteFocusMoved(); // +253: a landing is a landing, fresh or not
    await _saveBridgePrefs();
    await _refreshSession();
    notifyListeners();
    return null;
  }

  /// Jump the channel (and the bridge's seat) to tab [index]. A
  /// mid-turn switch BACKGROUNDS the live answer (+246; +332 took the
  /// same law onto creation and never-spoken destinations), so the
  /// switch RESTS only on the shapes a move cannot carry: a prompt
  /// parked with no open turn, and owed mail behind a destination that
  /// will wipe. Returns the refusal reason.
  /// [skipRest] is for the death hand-off (removeSessionTab): the
  /// caller has already weighed the rest law against the DOOMED
  /// thread's own row (+323), and the bridge's /seat is a record
  /// swap — a mid-turn move backgrounds the stranger's turn (+246)
  /// and a fresh destination starts blank without touching the
  /// old record's living conversation. Re-running the guard against
  /// the SEAT's global face would let one busy agent veto every
  /// other thread's funerals.
  Future<String?> switchSession(
    int index, {
    bool force = false,
    bool skipRest = false,
  }) async {
    final g = _gateway;
    final prefs = _bridgePrefs;
    if (g == null) return 'bridge not configured';
    if (index < 0 || index >= prefs.tabs.length) return 'no such session tab';
    // `force` re-seats even onto the index the ledger already calls
    // active — removeSessionTab needs it: when the ACTIVE tab dies,
    // the clamped index can land on the neighbour without the seat
    // ever having moved there.
    if (!force && index == prefs.activeTab.clamp(0, prefs.tabs.length - 1)) {
      return null;
    }
    if (!_seatCap) return 'the bridge is too old to switch sessions';
    final h = await bridgeHealth(); // the FRESH glance, not the cached era
    final tab = prefs.tabs[index];
    // +246: same harness => the mid-turn move backgrounds rather than
    // resets (see /seat); the rest guard only bites across harnesses.
    // +256 (the xray tape): an UNNAMED destination is a fresh seat —
    // the verb below sends fresh:true. +332 retired fresh's power to
    // end a LIVE turn (it backgrounds like every other move, so the
    // tape's SIGTERM-under-a-free-to-move hole is closed at the root),
    // but over a fully resting seat the wipe still runs — so the
    // guard still consults the reset law for exactly that shape, and
    // an owed backlog still rests the swipe onto a never-spoken tab.
    final rest = skipRest
        ? null
        : _seatRest(h, resets: tab.currentId == null);
    if (rest != null) return rest;
    // +289 (Tim's field: 'swipe away from a session — the TTS should
    // be paused or stopped IMMEDIATELY, but is still speaking'): the
    // cut rides the COMMIT, not the landing. Every await below is a
    // round trip (/seat, prefs, the refreshing /health) — a speaker
    // that waits them out keeps talking where the thread used to be.
    // A refusal that can still come from /seat itself pays one cut
    // it did not need; the 'ear let go' line names that drop, which
    // is the barge-in law's whole price.
    _cutEarOnSwitch();
    final r = await g.seat(
      harness: tab.harness,
      dir: tab.dir,
      model: tab.model,
      sessionId: tab.currentId,
      fresh: tab.currentId == null,
    );
    if (r == null) return 'this bridge has no /seat';
    if (r['ok'] != true) {
      return '${r['error'] ?? 'the bridge refused the seat'}';
    }
    // +249: if live work rides along, remember WHERE it lives — the
    // id the seat held a moment ago (the /seat response just named the
    // destination; the outgoing conversation keeps its own pointer).
    // The capture only signs for work that lives HERE: if a previous
    // backgrounding already parked the work in another conversation,
    // the busy flags lit now are ITS stream — moving seats again must
    // not re-sign the marker to the tab merely left, or swiping home
    // would hide the row in the very conversation working (the field
    // shape: A working, swipe to B — row gone, correct; swipe back to
    // A — the old capture overwrote the marker with B, orphaning the
    // box again, and a further swipe to B showed it thinking there).
    // +276: _turn.agentWork joins the capture — a turn that CLOSED
    // politely while leaving an owed background shell is still live
    // work with a home to sign for (the sleep-15 tape: the capture
    // read 'no live work', the marker stayed dark, and the spinner
    // had nothing to ride when the user came back).
    if (_bridgeBusy ||
        _turn.backgrounded ||
        _harnessBackgrounded ||
        _ticker.isOn ||
        _turn.agentWork) {
      // +298 (+257's law, taken to its end): there is no marker to
      // sign. The live work STAYS where it is — on the channel of the
      // conversation being left, with its own banner, its own row and
      // its own spinner — and the box you come home to finds it
      // there, because the channel is the marker the +249..+287
      // series kept re-homing. Only the tape line remains.
      _logDebug(
        'work home: busy=$_bridgeBusy detached=${_turn.backgrounded} '
        'ticker=${_ticker.isOn} debts=${_turn.agentWork} '
        '-> home stays on ${_sessionId ?? 'the unnamed seat'}',
      );
      // +255's input set rides the line above; the marker clause it
      // journalled is the concept +298 deletes.
      // +257 (Tim's law, round three): LEAVING IS DROPPING — the
      // speaker's cut and the named drop now ride EVERY landing (see
      // _noteFocusMoved; +259 moved it out of this branch, where a
      // speak tail with fallen flags slipped past it and kept talking
      // on the new tab). Every word still queued for the conversation
      // being left dies unheard (its mid was TAKEN at the take, so
      // the return's mail fetch files it silently and never re-
      // speaks it).
      // The bar belongs to the conversation, like the row: it is
      // blanked and re-seeded at the landing below (+280 moved what
      // was the manual zero here into the uniform landing law);
      // /health's owner gate keeps it honest until the seated
      // conversation's own turn names a fresher size (/mergeContext
      // ignores zeros, so the manual blank is the law's hands — as
      // with /new).
    } else {
      // +255: no live work seen. Say so on the tape: a box lighting
      // the destination after THIS line is a different animal than one
      // after the line above (+298: the marker clause the line used to
      // carry is the concept the map deleted).
      _logDebug(
        'work home: no live work at the seat -> every tab keeps its '
        'own face, seat=${_sessionId ?? 'unnamed'}',
      );
    }
    prefs.activeTab = index;
    final sid = r['sessionId'];
    if (sid is String && !tab.sessionIds.contains(sid)) {
      tab.sessionIds.add(sid);
    }
    // +289: THE SEAT ANSWERED WITH A NAME — WEAR IT NOW. The say
    // gate asks whether the view's conversation IS the seat; until
    // this line the pointer still named the conversation just left,
    // so its freshest paragraph sailed through viewHome, revived the
    // cut pump (the +270 rule) and spoke on the tab you switched TO
    // — for as long as the refreshing /health took to say otherwise.
    // The /seat response already named the destination (+256);
    // createSession has always worn its own. A fresh seat names
    // nobody yet — the pointer goes null exactly as the refreshing
    // /health would report it (nameless birth keeps the old global
    // proof until its first frame speaks a name).
    // +298: the destination's channel takes the seat here — at the
    // LANDING, exactly where the old code moved the single _sessionId:
    // the cut at the commit, the capture and the refusal paths above
    // all still spoke for the conversation being left. The answer now
    // NAMES it (or clears it for a fresh seat).
    _switchToChannel(tab.currentId);
    _setSessionId(sid is String ? sid : null);
    // +280 (Tim, with the control row below): the bar lands WEARING
    // this conversation's own last reading, not a 'measuring'
    // placeholder. The blank is uniform now (the old law zeroed only
    // over live work, so an idle A's numbers could ride onto B); the
    // destination's tab ledger carries what THIS conversation last
    // said, and nothing else may paint on its face. A fresher /health
    // or context frame updates the reading the moment it arrives —
    // and a bridge that currently says zero leaves the remembered
    // truth standing, because the merge ignores zeros by law.
    _landBarOnTab(tab);
    // +253: the watermark lands with the focus — what this conversation
    // already owes is history the eyes get, not the ears.
    _noteFocusMoved();
    await _saveBridgePrefs();
    await _refreshSession();
    // +278: coming HOME to a conversation that owes a background
    // report asks the bridge IMMEDIATELY — the catch-up must not
    // wait for the next heartbeat beat (the report's frames land,
    // the banner pays or relights with its true age, and a fresh
    // enough report speaks).
    if (showsBackgroundedWork) _scheduleBgProbe(every: Duration.zero);
    notifyListeners();
    return null;
  }

  /// +253: the moment this conversation became the one on screen, in
  /// the bridge's clock domain (the same _ts a frame carries — the
  /// transport's calibrated skew makes the comparison honest). A say
  /// stamped BEFORE it is backlog: filed, acked, visible, mute (see
  /// SessionChannel.focusAtMs and BridgeTurn._onSay).
  void _noteFocusMoved() {
    _chan.focusAtMs = _clock().millisecondsSinceEpoch - _transport.skewMs;
    // +289: the cut split from the watermark — switchSession fires it
    // at the COMMIT, and the landing fires it again: a paragraph the
    // /seat round trip managed to revive (the seat pointer has only
    // just moved) dies here too. Same doctrine as the press's
    // 'for barge in just drop', and just as traceable: an in-audio
    // cut with no journal line is the one thing the barge-in spec
    // forbids.
    _cutEarOnSwitch();
  }

  /// +259 (Tim's field round): LEAVING IS DROPPING — for EVERY mouth,
  /// not only the mouth with lit busy flags. +257 hung the cut on the
  /// live-work capture, and the tape caught the half that walked past
  /// it: the speak tail of a turn whose flags had already fallen kept
  /// talking over the new tab ('it's just speaking in the
  /// background'). +289 moved the switch's first strike to the commit
  /// — the moment the verb is sent — because the landing turned out
  /// to be two round trips late.
  void _cutEarOnSwitch() {
    if (!(_reply.playing || _reply.queuedCount > 0)) {
      // The idle-switch hole (review A): a block STILL synthesising has
      // neither playing audio nor a queued chunk, so the old early
      // return let it finish and land on the tab the reader switched
      // TO. Revoke its claim on the ear anyway — the pipeline's epoch
      // gate kills its pieces, and the cancel releases the worker.
      _reply.invalidatePendingAudio();
      return;
    }
    _logDebug(
      'switch: ear let go — ${_reply.queuedCount} queued '
      'block(s) dropped unheard',
    );
    // +270: the paragraph actually on air joins the drop ledger
    // (the hide cut's own door) — its synth tail may not resurrect
    // as a mid-sentence resume when the respawned pump finds the
    // NEXT paragraph; and the flush now happens even landing
    // between chunks, which is where the old early return hid the
    // readerless queue that made the return 'completely silent'.
    _hide.markAudibleCut();
    _reply.stopPlayback();
  }

  /// +266: the band's sweep moved HERE out of the landing itself
  /// (+259's first home): a switch's slide gives the screen ~300 ms
  /// of visible transition, and a band that flipped to 'Ready. Hold
  /// the button…' the moment /seat was SENT played that flip in
  /// front of the reader ('I see a split second of the chat window
  /// showing ready hold button text'). The band belongs to the
  /// thread, so it changes when the THREAD changes — the screen
  /// calls this at the tab-index hand-off, while the thread is
  /// off-screen and the flip's content swap rides the hop. The say
  /// path's watermark (+254) still lands at the landing proper: it
  /// is a law about frames, not about pixels.
  /// The tab whose bubbles are currently on screen — the band cache's
  /// key, and what a frame's owner is compared against.
  int get _activeTab => _bridgePrefs.activeTab;

  /// +266 (Tim's own closing insight: 'we can cache the sessions'
  /// conversation, right? — so the rest line should NEVER flash'):
  /// every tab's band line is its own, remembered. Leaving a tab
  /// files whatever it was showing under ITS key; landing restores
  /// the destination's cached line — the last truth its own stream
  /// painted, which for a working thread is still the command mid-
  /// flight; only a tab that never spoke (a birth, a first visit)
  /// has no cache, and its rest line is not a placeholder, it is
  /// that conversation's honest state. Away frames feed this same
  /// map through [cacheAwayBand], so the cached line stays CURRENT
  /// while you are on another tab — coming home shows what the
  /// harness is doing NOW, not a snapshot of when you left.
  /// +314: the band cache is keyed by the TAB OBJECT, not its index.
  /// The +230-era index key forced a hand-shift on every deletion
  /// (ten lines of 'everything after moves left') and made the cache
  /// a second copy of the tab list's shape; object identity is that
  /// shape's own key — deletions and reorders are structurally free,
  /// and the doomed tab's line dies exactly with it.
  final Map<SessionTab, Activity> _bands = {};

  /// +266: the band's sweep moved HERE out of the landing itself
  /// (+259's first home): a switch's slide gives the screen ~300 ms
  /// of visible transition, and a band that flipped to 'Ready. Hold
  /// the button…' the moment /seat was SENT played that flip in
  /// front of the reader ('I see a split second of the chat window
  /// showing ready hold button text'). The band belongs to the
  /// thread, so it changes when the THREAD changes — the screen
  /// calls this at the tab-index hand-off, while the thread is
  /// off-screen and the flip's content swap rides the hop. The say
  /// path's watermark (+254) still lands at the landing proper: it
  /// is a law about frames, not about pixels.
  void settleBandOnLanding(int fromTab, int toTab) {
    final tabs = _bridgePrefs.tabs;
    if (fromTab >= 0 &&
        fromTab != toTab &&
        fromTab < tabs.length &&
        toTab < tabs.length) {
      _bands[tabs[fromTab]] = _activity; // the leaving tab keeps what
      // was painted as it left — including the departed seat's at-
      // rest line, which is truthfully its own (+314's pin walk
      // caught the old code caching THAT over a survivor's cache).
    }
    if (toTab < 0 || toTab >= tabs.length) return;
    _paintLandingBand(tabs[toTab], toTab);
  }

  /// +314: the landing half of the law, split out with its log lines
  /// intact — the seat paints the line its OWN tab owns, or the
  /// at-rest line, and never the orphan of whatever the seat wore
  /// before. Split because a death re-homes the seat with no slide
  /// hand-off to ride: the deletion must paint the landing itself.
  void _paintLandingBand(SessionTab tab, int toTab) {
    final own = _bands[tab];
    if (own != null) {
      _logDebug(
        'switch: band — tab $toTab resumes on its OWN cached line '
        "('${own.text(mode: _mode)}')",
      );
      _activity = own;
      notifyListeners();
      return;
    }
    if (_activity is StepLine ||
        _activity is TurnWaiting ||
        _activity is QueuedVerdict) {
      _logDebug(
        "switch: band reset — the seat's at-rest line, not "
        "'${_activity.text(mode: _mode)}' borrowed from the tab left",
      );
      _activity = _phase == AssistantPhase.listening
          ? const ListeningHint()
          : const IdleHint();
      notifyListeners();
    }
  }

  /// The screen's call when a DEATH re-homes the seat (removeSessionTab):
  /// paint the new seat's own line, orphans die with the tab.
  void settleBandOnSeat() {
    final tab = _tab;
    if (tab != null) _paintLandingBand(tab, _activeTab);
  }

  /// +266: the away-conversation's frames refresh ITS cache and
  /// leave the painted band alone (the +259 gate in the turn loop
  /// calls this at the same door it declined to paint): the line you
  /// come home to is the CURRENT command, not the one you left.
  void cacheAwayBand(String? sid, Activity act) {
    if (sid == null) return;
    final t = _bridgePrefs.tabs.cast<SessionTab?>().firstWhere(
      (x) => x!.sessionIds.contains(sid),
      orElse: () => null,
    );
    if (t != null && t != _tab) _bands[t] = act;
  }

  /// +230: ✕ on the pill — FORGET A TAB. The tab's bubbles leave with
  /// it (the same replace law as /new: a deleted thread whose store
  /// rows stayed would resurrect under a re-created tab wearing the
  /// same session id); the shared prologue and every OTHER tab stand.
  /// The bridge is only touched when the doomed tab HOLDS the seat
  /// and a neighbour exists to take it — then the move obeys the rest
  /// law (mid-turn / unheard-owed refuses, and the tab stays, because
  /// deleting an active thread behind a live turn's back is exactly
  /// the silent-eat this law exists to stop). Deleting the LAST tab
  /// fires no verb at all: the bridge keeps its seat (it is the
  /// bridge's own memory now), the ledger goes empty, and the fixed
  /// + re-asks the question whenever the user wants a session again.
  Future<String?> removeSessionTab(int index) async {
    final prefs = _bridgePrefs;
    if (index < 0 || index >= prefs.tabs.length) return 'no such session tab';
    final active = prefs.activeTab.clamp(0, prefs.tabs.length - 1);
    final isActive = index == active;
    if (isActive && prefs.tabs.length > 1) {
      // Relieving the seat is a seat verb — but the rest law reads
      // the DOOMED thread's OWN row, not the seat's global face
      // (+323, field: 'whenever one agent is working, I cannot close
      // the other session'). A voice answer streaming in a neighbour
      // is that conversation's business: the seat move it forces
      // here backgrounds the stranger's turn exactly like every
      // other mid-turn switch (+246), so it must not veto a deletion.
      // Only the doomed conversation's own live turn, queued prompt,
      // or unheard debt rests its ✕ — those are the shapes a death
      // would silently eat.
      final h = await bridgeHealth();
      final doomedIds = prefs.tabs[index].sessionIds;
      final row = (h?['sessions'] as List?)
          ?.cast<Map<String, Object?>?>()
          .firstWhere(
            (r) => r?['sid'] != null && doomedIds.contains(r!['sid']),
            orElse: () => null,
          );
      // Unnamed tab: no row, no debt, no veto — there is nothing on
      // the bridge yet that a death could eat.
      if (row != null) {
        // The row's nulls (--resume material a resting record never
        // spoke) are the JSON's honesty, not a verdict — _seatRest
        // reads booleans and counts; hand it exactly those.
        final verdict = Map<String, Object>.fromEntries(
          row.entries.where((e) => e.value != null).map(
            (e) => MapEntry(e.key, e.value as Object),
          ),
        );
        // +332: the death keeps +323's strict shape — a doomed thread's
        // live turn is not backgrounding material, it is being thrown
        // away, so doomed:true refuses the mid-turn ✕ even though the
        // plain seat verbs no longer rest on a turn.
        final rest = _seatRest(verdict, resets: true, doomed: true);
        if (rest != null) return rest;
      }
    }
    final doomed = prefs.tabs.removeAt(index);
    // +314: the doomed tab's cached band rides OUT with the object —
    // the index-shift this line replaces was a ten-line apology for
    // keying a conversation's presentation by its position.
    _bands.remove(doomed);
    // +276: a deleted conversation retires the banner IT owed —
    // nothing will ever report a backgrounded shell whose thread
    // the user threw away.
    _purgeChannelsOwned(doomed.sessionIds);
    // +348: its refused says die with it too — no owner drain will
    // ever serve them, so the ledger's entries leave WITH the tab,
    // on the record (the journal walker reads this line as the
    // refused story's honest end).
    _purgeRefusedSays(doomed.sessionIds);
    _chat.removeSessions({
      ...doomed.sessionIds,
      ChatStore.pendingSession, // its nameless birth turn goes too
    });
    if (!isActive && index < active) prefs.activeTab = active - 1;
    if (prefs.tabs.isEmpty) prefs.activeTab = 0;
    await _saveBridgePrefs();
    notifyListeners();
    if (isActive && prefs.tabs.isNotEmpty) {
      // The seat must live somewhere: the NEIGHBOUR (previous, or the
      // next when the first tab died) — `force`, because the clamped
      // active index can already point at it while the seat never
      // moved there.
      final dest = index == 0 ? 0 : index - 1;
      final err = await switchSession(dest, force: true, skipRest: true);
      if (err != null) return err; // tab gone; the move's reason rides back
      // +314: the inherited seat paints the doomed tab's line OUT of
      // existence — the band belongs to the thread, and the thread
      // is gone. (The switch's own landing paint finds no slide
      // hand-off here: the screen only calls settleBandOnLanding at
      // a transition's flip, and a deletion is not one.)
      settleBandOnSeat();
    }
    return null;
  }

  /// The first-launch sheet's no-wire escape: adopt the bridge's
  /// CURRENT seat as tab 1 exactly as the upgrade seed does — for a
  /// fresh install that just wants what it already has. Refuses
  /// without a bridge to copy.
  String? useCurrentSeat() {
    final h = _lastHealth;
    final era = h?['harness'], d = h?['dir'];
    if (h == null ||
        (era != 'claude' && era != 'opencode') ||
        d is! String ||
        d.isEmpty) {
      return 'the bridge has not named a seat to adopt';
    }
    final sid = h['sessionId'];
    _bridgePrefs.tabs.add(
      SessionTab(
        harness: era as String,
        dir: d,
        model: h['model'] is String ? h['model'] as String : null,
        sessionIds: sid is String && sid.isNotEmpty ? [sid] : [],
        createdMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _bridgePrefs.activeTab = _bridgePrefs.tabs.length - 1;
    unawaited(_saveBridgePrefs());
    notifyListeners();
    return null;
  }

  /// The Bridge screen's rows moved the seat the manual way — the
  /// active tab's description must follow or the next swipe would
  /// drag the old seat back (+230 keeps tab and seat one story).
  void _syncTabFromSeat({String? harness, String? dir, String? model}) {
    final tab = _tab;
    if (tab == null) return;
    var moved = false;
    if (harness != null && tab.harness != harness) {
      tab.harness = harness;
      moved = true;
    }
    if (dir != null && tab.dir != dir) {
      tab.dir = dir;
      moved = true;
    }
    if (model != null && tab.model != model) {
      tab.model = model;
      moved = true;
    }
    if (moved) unawaited(_saveBridgePrefs());
  }

  /// +303 (the boot reconcile's POST, +230, taken out of the one-shot):
  /// the world's seat has drifted off THIS tab — put it back by
  /// NAME. A re-seat of a named tab is a record swap, not a reset
  /// (the +257 law): nothing of the neighbour's life is destroyed,
  /// the globals simply describe the tab the eye is on. The
  /// uuid-at-birth world needs this on EVERY mismatched glance, not
  /// once at boot: the boot-only version is what let the field tape
  /// settle into a mis-named seat.
  Future<void> _reseatTab(String why) async {
    final tab = _tab;
    if (tab == null) return;
    final r = await _gateway?.seat(
      harness: tab.harness,
      dir: tab.dir,
      model: tab.model,
      sessionId: tab.currentId,
      fresh: tab.currentId == null,
    );
    if (r == null || r['ok'] != true) {
      _logDebug('tab re-seat failed ($why): ${r?['error'] ?? 'no /seat'}');
      return;
    }
    _logDebug(
      'tab re-seat ($why): back on ${tab.harness} @ ${tab.dir} '
      '(${tab.currentId ?? 'fresh'})',
    );
    unawaited(_refreshSession());
  }

  Future<void> _refreshSession() async {
    final h = await _gateway?.healthInfo();
    // wire v2 housekeeping on every bridge glance: re-ack whatever the
    // wire swallowed (idempotent both ends), and hold the honest
    // banner while the bridge does not speak ids — v2 has no silent
    // fallback: a wrong-proto bridge gets words, not guessing.
    unawaited(_heard.retry());
    if (h != null && h['proto'] is num && (h['proto'] as num).toInt() != 2) {
      _error = 'Bridge too old — install the new claude_bridge.mjs (wire v2)';
      notifyListeners();
    }
    final sid = h?['sessionId'];
    final s = (sid is String && sid.isNotEmpty) ? sid : null;
    final hm = h?['harness'];
    final eraNow = hm == 'claude' || hm == 'opencode' ? hm as String : null;
    _lastHealth = h;
    // +324: the glance that SEES owed mail arms the drain, wherever
    // the eye sits. The old law refused the swipe instead — a banner
    // that blocked navigation to protect mail that was never at risk
    // (+257 gave every record its own backlog; the replay routes by
    // name and files silently for the away thread). Resting at home
    // it lands the same beat it always did; mid-swipe it lands while
    // you look elsewhere and is painted when you return.
    if (h != null &&
        ((h['missed'] as num?)?.toInt() ?? 0) > 0 &&
        h['turnOpen'] != true &&
        !_bridgeBusy &&
        !_turn.backgrounded &&
        !_benchCapturing &&
        !_benchBusy &&
        _ptt.pointers == 0 &&
        // +124 still rules the air: a drain never cuts a paragraph
        // still on its way out of the speaker.
        !_reply.playing &&
        _reply.queuedCount == 0 &&
        !_chain.armed) {
      _chain.start(
        gen: _generation,
        seq: _bridgeTurnSeq,
        firstProbe: Duration.zero,
      );
    }
    // +230: the tab ledger reads every glance BEFORE the single-thread
    // bookkeeping below — an upgrade's seed creates tab 1 here, the
    // boot reconcile may re-home the seat (and asks for its own
    // re-read), and every id the active tab spoke gets filed.
    _tabsOnHealth(h, eraNow, s);
    // +303: under the bridge's uuid-at-birth declaration the GLOBAL
    // sessionId line is information, not a rename. It describes the
    // record the bridge last sat at or talked to — when the eye sits
    // on a different tab, adopting it re-names the seat after its
    // neighbour (the field tape: the xray tab adopted voice-agent's
    // uuid, two threads shared one address, and the +295 laws began
    // faithfully routing cross-session messages). A name is born at
    // createSession, worn at the landing, learned from ONE'S OWN
    // stream (+299) — never from a census line. The field also
    // covers the null: a bridge between records may not UN-name a
    // living seat. Pre-birth bridges keep the +223 law untouched.
    final atBirth = h?['uuidAtBirth'] == true;
    if (atBirth &&
        s != null &&
        s != _sessionId &&
        _tab?.currentId != null &&
        _seatCap &&
        h!['turnOpen'] != true &&
        h['queued'] != true &&
        ((h['missed'] as num?)?.toInt() ?? 0) == 0) {
      // +303: THE NAMED-NEIGHBOUR CORRECTIVE. The glance speaks for
      // the global (a restart's pointer, another tab's turn, a
      // sibling app); the eye sits on a NAMED tab; nothing is
      // mid-flight to be disturbed (the boot reconcile's rest law,
      // honoured here too). The seat is stale, not the tab: re-post
      // the seat by name. The old law's reflex — adopt the name —
      // is what collapsed two threads into one address on the
      // field tape; under uuid-at-birth only the seat moves.
      unawaited(_reseatTab('glance named $s'));
    }
    if (!atBirth && s != _sessionId) {
      _setSessionId(s);
      if (s != null) {
        // +223: the id has a NAME now — every bubble born under the
        // sentinel (this session's own birth turn) adopts it, and ONCE
        // the pre-law history adopts the session that was already in
        // use. Order matters: stamp first, notify after, so no paint
        // ever shows a thread that just changed owners.
        // +275: sweep only the seat's OWN paperwork (a prompt typed
        // while it had no name). Pump-born bubbles self-name from
        // their stream — a full sweep here would steal another
        // conversation's nameless birth into THIS id.
        _chat.adoptPending(s, userOnly: true);
        if (!_bridgePrefs.sessionBackfilled) {
          _bridgePrefs.sessionBackfilled = true;
          unawaited(_saveBridgePrefs());
          _chat.adoptUnowned(s);
        }
      }
      notifyListeners();
    }
    // +213: the era tracker. The harness may flip while this screen is
    // open (the Bridge row's switch, a curl, a restart's persisted
    // choice) — any /health glance re-arms the thread, and the notify
    // repaints the channel onto the new one. (eraNow was parsed above,
    // where the tab ledger needed it.)
    if (eraNow != _bridgeHarness) {
      _bridgeHarness = eraNow;
      notifyListeners();
    }
    // +214: the one-time chat migration. A pre-split log is all
    // un-era'd, which the split reads as SHARED PROLOGUE — so right
    // after installing, every era's thread shows every harness's
    // history (the field complaint this answers). The first /health
    // that names an era stamps the legacy bubbles ONCE: each by its
    // own birth time against the bridge's harnessHistory when the
    // bridge is new enough to keep one, else wearing the observed
    // era. The flag lives in prefs, so a legitimately un-era'd bubble
    // made LATER (no bridge at all, the offline prologue) is never
    // re-stamped by a returning guess.
    if (eraNow != null && !_bridgePrefs.eraBackfilled) {
      _bridgePrefs.eraBackfilled = true;
      unawaited(_saveBridgePrefs());
      _chat.migrateUnera(
        eraNow,
        timeline: [
          for (final row in (h?['harnessHistory'] as List? ?? const []))
            if (row is Map &&
                row['since'] is num &&
                (row['harness'] == 'claude' || row['harness'] == 'opencode'))
              (
                since: (row['since'] as num).toInt(),
                harness: row['harness'] as String,
              ),
        ],
      );
    }
    final ctx = h?['context'];
    if (ctx is Map) {
      final i = ctx['in'], w = ctx['window'];
      _mergeContext(i is num ? i.toInt() : 0, w is num ? w.toInt() : 0);
    }
    // The banner's safety net: if the bridge reports NOTHING open — no
    // turn, no queue, no detached tool (a harness that killed the tool
    // with the turn never sends 'finished') — the backgrounded-work
    // line has no work left to name and retires on the proof.
    final det = h?['detached'];
    final missedNow = (h?['missed'] as num?)?.toInt() ?? 0;
    // +298: the net runs for a banner owed on ANY tab — the clean
    // report will settle only the channel it names (or journal the
    // hold); an away debt keeps its heartbeat like a home one.
    if (h != null &&
        _anyWorkOwed &&
        h['turnOpen'] != true &&
        h['queued'] != true &&
        (det is num ? det.toInt() : 0) == 0 &&
        missedNow == 0) {
      _settleBannerFromHealth(h, 'health'); // +279 (scoped, partial)
    } else if (h != null &&
        _anyWorkOwed &&
        h['turnOpen'] != true &&
        (det is num ? det.toInt() : 0) == 0 &&
        missedNow > 0) {
      // The report opened and CLOSED between beats: the debt is paid
      // but its words still sit unheard in the bridge's backlog. A
      // line retired over them strands the answer until the next
      // prompt, where it bursts out of sync (field report: 'no
      // response unless I ask'). Hold the line; ask the heartbeat NOW
      // — _bgWake arms the drain that files or speaks them.
      _logDebug('bg line holding for drain: missed=$missedNow');
      _scheduleBgProbe(every: Duration.zero);
    }
    // A turn end (or boot, or setBridge) that leaves the bottom line
    // lit starts the heartbeat: +133's agent-backgrounded work reports
    // UNPROMPTED, and an idle phone has no other channel to hear it.
    if (_anyWorkOwed) _scheduleBgProbe();
  }

  /// +277: a band line lives exactly as long as the work it
  /// describes. When a conversation's background ledger settles —
  /// receipt paid, orphan retired, health-proven closed — the tab's
  /// CACHED working row dies with it: the field tape (21:49:55→5:04)
  /// shows the return landing on 'Bash sleep 15…' long after the
  /// banner retired and the receipt filed, a spinner-shaped lie
  /// about work that stopped existing while the tab was away. If
  /// that tab is on screen, its painted band reverts to the at-rest
  /// line too (only while it still wears the stale WORK caption and
  /// no live turn holds the slot — a fresh command owns the band).
  void _clearOwnedBand(String? sid, {String? settledLabel}) {
    if (sid == null) return;
    // +314: the settled band dies with the TAB that wore it — the
    // object the sid names, whatever position it currently holds.
    for (final t in _bridgePrefs.tabs) {
      if (t.sessionIds.contains(sid)) _bands.remove(t);
    }
    if (sid == _sessionId) {
      final act = _activity;
      // +279.1→+282: the painted stale line ALWAYS goes when it
      // NAMES the debt just settled (the 22:24 tape: xray's pump
      // made the old !_bridgeBusy guard decline, and the very next
      // swipe-away re-stashed the dead 'Bash sleep 20…' into the
      // cache — the tab wore a spinner for a sleep a minute dead).
      // Without a label to match, the conservative form remains:
      // only with no live work holding the band may the at-rest
      // line return.
      final namesSettled =
          settledLabel != null && act.text(mode: _mode) == '$settledLabel…';
      if (namesSettled ||
          (!_bridgeBusy &&
              !_ticker.isOn &&
              (act is StepLine || act is TurnWaiting))) {
        _activity = _phase == AssistantPhase.listening
            ? const ListeningHint()
            : const IdleHint();
      }
    }
    notifyListeners();
  }

  /// +279: the clean-report settlement, shared by the refresh net and
  /// the heartbeat. A /health that proves nothing open retires what
  /// IT CAN SEE: the debts (and badge) owned by the conversation it
  /// names. Each settled debt gets its receipt card stamped for its
  /// own thread and its band line buried (+277); another
  /// conversation's owed debt — invisible to this report — HOLDS the
  /// banner, journalled through the +276 hold line. The banner
  /// retires only when nothing anywhere is owed any more.
  void _settleBannerFromHealth(Map<String, Object> h, String door) {
    final spoke = h['sessionId'] is String ? h['sessionId'] as String : null;
    // +298: a clean bill settles the conversation it NAMES — the
    // spoke's own channel. The +279 'scoped, partial' law is now the
    // map's shape: a stranger's badge lives in another object and was
    // never in reach of this settlement.
    // +313: the clean bill speaks for a conversation this phone has
    // no home for — it settles nothing here.
    final spokeChan = _channelIfKnown(spoke);
    if (spokeChan == null) return;
    final led = spokeChan.turn;
    // Did THIS channel wear a warrant before the settle? (An empty
    // idle stranger must not print 'retired' over a banner owed on
    // another tab.)
    final had =
        led.backgrounded || led.detachedPromise || led.workOwner != null;
    final paid = led.settleDebtsOwnedBy(spoke);
    final othersRemain = led.agentWork;
    final badgeElsewhere = led.badgeOwnedByOtherThan(spoke);
    for (final d in paid) {
      _bgFinishedBubble(d.label, session: d.sid ?? spoke);
      // +277: the stale row follows; +282: by NAME, so a stranger's
      // live pump cannot veto the burial of the line that just died.
      _clearOwnedBand(d.sid ?? spoke, settledLabel: d.label);
    }
    // +298: 'nothing open, none detached' is a verdict ONLY for the
    // conversation the report names — the channel it speaks for must
    // actually be the one wearing a badge to retire; an idle stranger
    // named by the glance proves nothing anywhere and holds on the
    // tape (+276's law, per-channel). A report that names NOBODY
    // keeps the old global proof (the pre-tab world, and bridges too
    // old to speak ids).
    if (!othersRemain && !badgeElsewhere && (had || spoke == null)) {
      final ownedBy = led.workOwner;
      led.retireBadgeAndWork(); // the promise goes with the snapshot
      _logDebug('bg line retired: $door — nothing open, none detached');
      _clearOwnedBand(ownedBy ?? spoke);
    } else if (paid.isEmpty) {
      _healthSpeaksForBadge(h, door); // journals the hold
    } else {
      _logDebug(
        'bg line holding: $door settled this conversation\u2019s debts, '
        'another thread still owes',
      );
    }
    notifyListeners();
  }

  /// +276: does THIS /health report speak for the conversation the
  /// banner owes its work to? A /health names the SEAT — it can only
  /// prove absence in the conversation it describes. The badge's home
  /// is the conversation its own stream stamped (+298: the homes are
  /// the channels wearing warrants; the pair's marker half is gone).
  /// Different conversations, different truths: a
  /// clean report from tab B must never retire tab A's spinner —
  /// the field tape (21:38:28): swiping to an idle tab filed
  /// 'Bash sleep 15 finished.' two seconds into the sleep and took
  /// the backgrounded-work line with it, so coming home showed a
  /// stale band and no box. No owner known (pre-tab worlds, bridges
  /// that name nothing) keeps the old global proof.
  bool _healthSpeaksForBadge(Map<String, Object>? h, String door) {
    final speaks = h?['sessionId'];
    if (speaks is! String) return true; // a nameless report keeps the
    // old global proof (a bridge that names nothing has one seat).
    // +298: the badge's homes are the channels WEARING warrants; a
    // report naming one other than those proves absence where it
    // speaks and nowhere the banner lives.
    String? badgeOwner;
    for (final c in _channels.values) {
      if (!(c.turn.backgrounded ||
          c.turn.detachedPromise ||
          c.turn.agentWork)) {
        continue;
      }
      final key = c.turn.workOwner ?? c.sessionId;
      if (key != null && key != speaks) {
        badgeOwner = key;
        break;
      }
    }
    if (badgeOwner == null) return true;
    // Test ids are short; tape ids are long. Abbreviate honestly.
    String eight(String s) => s.length <= 8 ? s : '${s.substring(0, 8)}…';
    _logDebug(
      'bg line holds: $door said clean for ${eight(speaks)}, '
      'the badge belongs to ${eight(badgeOwner)}',
    );
    return false;
  }

  // ── The background line's heartbeat (0.1.0+133) ────────────────────────
  Timer? _bgProbe; // the 10-ask heartbeat of a lit bottom line — an
  // idle phone has no channel, and the agent's own background work
  // (see the bridge's run_in_background handling) reports UNPROMPTED.
  // While the banner is warranted, this asks /health whether a report
  // turn opened, and wakes the existing reattach chain when one did.

  /// +298: a banner owed on ANY tab warrants the beat — an away
  /// conversation's report must be fetched too (its gear-badge promise
  /// +230 stays honest). At-home warrants it FASTER (see _bgWake).
  bool get _anyWorkOwed => _channels.values.any(
    (c) =>
        c.turn.backgroundUnheard || c.turn.agentWork || c.turn.detachedPromise,
  );

  /// Arm the bottom line's ask-again heartbeat — while the line is
  /// warranted, once is enough (the wake re-arms its own successor).
  Duration _bgProbePace = const Duration(seconds: 10);
  void _scheduleBgProbe({Duration every = const Duration(seconds: 10)}) {
    if (!_anyWorkOwed || _gateway == null) return;
    if (_bgProbe != null) {
      // +305: urgency may PRE-EMPT a pending beat, it may not be
      // swallowed by it. The three 'ask the bridge NOW' callers
      // (the landing at an owed thread, the hold-for-drain verdict,
      // the turn closed with work unpaid) hand a zero delay, and
      // the old coalescing guard treated ANY pending timer as proof
      // a beat is coming — while the beat that was coming was the
      // AWAY pace's 10 s. The field tape: the shell finished at
      // :47, the return saw missed=4 at :50.7, and the news waited
      // the full beat to :60.4 ([wire+13235ms]) — 'it told me 5 to
      // 10 seconds later'. Only ever faster: a slower request never
      // pushes an imminent beat out.
      if (every < _bgProbePace) {
        _bgProbe!.cancel();
        _bgProbe = _scheduler.after(every, () {
          _bgProbe = null;
          unawaited(_bgWake());
        });
        _bgProbePace = every;
      }
      return;
    }
    _bgProbe = _scheduler.after(every, () {
      _bgProbe = null;
      unawaited(_bgWake());
    });
    _bgProbePace = every;
  }

  /// The heartbeat firing: consult /health. Nothing open and nothing
  /// detached retires the line (same proof as [_refreshSession]'s
  /// safety net — the counter now honestly includes the agent's own
  /// tasks); work still owed wakes the EXISTING reattach chain, whose
  /// probe decides ATTACH-vs-idle and whose age rules speak (or
  /// silently file) the report when one is streaming.
  Future<void> _bgWake() async {
    if (!_anyWorkOwed) return;
    // +315: the +164 law of the strand verdict, extended to THIS /health
    // probe — flush heard-acks IN FLIGHT before asking. The field tape:
    // the press's answer was mid-sentence when the beat read `missed=2`
    // — two frames this phone had already TAKEN, their POST /heard a
    // few milliseconds from landing — so the beat called ATTACH on a
    // phantom debt and the chain's stopPlayback cut 7 seconds of
    // paragraph at 0.6 (the text sat in the chat, the voice died:
    // 'your response after a background kickoff does not go through
    // TTS'). An ack racing its own probe must never arm a drain.
    await _heard.retry();
    final h = await _gateway?.healthInfo();
    if (h == null) return;
    final det = h['detached'];
    final missed = (h['missed'] as num?)?.toInt() ?? 0;
    if (h['turnOpen'] != true &&
        h['queued'] != true &&
        (det is num ? det.toInt() : 0) == 0 &&
        missed == 0) {
      // +279: scoped like the refresh net — the beat proves absence
      // for the conversation it NAMES; other threads' debts hold.
      _settleBannerFromHealth(h, 'idle probe');
      if (!_anyWorkOwed) return; // settled where it spoke; other tabs
      // may still owe — the beat holds for them (+298: 'any' is honest
      // cross-channel where the old single-flag check could only see
      // the one conversation that existed).
    }
    // Wake the ear for a report that is STREAMING, and — the case the
    // 10 s beat could miss — for one that already OPENED AND CLOSED
    // between two probes: then nothing is open and none is detached,
    // but its words are the backlog (missed > 0), and a line retired
    // over unheard words strands the answer until the next prompt
    // delivers it out of sync (field report: 'no response unless I
    // ask'). The chain's probe turns a missed>0 verdict into ATTACH;
    // the replay dedups or ages whatever the beat raced.
    // +298: the report names its conversation; the LADDER that wakes
    // belongs to it, not to whichever tab is on screen.
    final owed = _channelIfKnown(
      h['sessionId'] is String ? h['sessionId'] as String : _sessionId,
    );
    if (owed == null) {
      // +313: the report names a conversation nobody here keeps —
      // no ladder to wake (the beat goes on for the debts that ARE
      // owed somewhere).
      _scheduleBgProbe();
      return;
    }
    if ((h['turnOpen'] == true || h['backgrounded'] == true || missed > 0) &&
        !owed.turn.busy &&
        !owed.turn.backgrounded &&
        !_benchCapturing &&
        !_benchBusy &&
        _ptt.pointers == 0 &&
        !owed.chain.armed) {
      // +315: +124's park-to-the-natural-end applies to THIS arm of the
      // chain too — an ATTACH opens with stopPlayback, and the replay
      // that follows can never re-voice a paragraph the ledger already
      // took: cutting on-air audio here kills it for good (text in the
      // chat, silence in the speaker). Park the wake instead; the beat
      // re-arms below and every guard re-checks once the speaker is
      // honestly silent.
      if (_reply.playing) {
        _logDebug('bg wake: audio on air — the ATTACH waits for the '
            'natural end');
      } else {
        owed.chain.start(
          gen: owed.turn.generation,
          seq: owed.turn.seq,
          firstProbe: Duration.zero,
        );
      }
    }
    // +278: the user SITTING on the owed conversation deserves to be
    // TOLD, not to ask: at home the beat tightens to 2 s (the sleep-
    // 50 tape: the shell finished at 42.5, the 10 s beat could not
    // answer before 45+, and 'Did the sleep finish?' at 46.6 beat
    // the phone to the news). Away, the slow beat suffices — the
    // landing's catch-up probe (see switchSession) covers the return.
    _scheduleBgProbe(
      // +298: 'the banner is on THIS tab' is what showsBackgroundedWork
      // now answers (the seat's channel); away debts keep the slow beat.
      every: showsBackgroundedWork
          ? const Duration(seconds: 2)
          : const Duration(seconds: 10),
    );
  }

  /// The proof-of-completion the background banner waits for (bridge
  /// `tool finished` frame — the late tool_result of a cut tool naming
  /// its step, or the +128 lifecycle receipt of a turn that ended
  /// unheard). A NAMED receipt pays its own shell and files the chat
  /// period for THAT label. A lifecycle receipt pays an AGENT debt
  /// with NOTHING (+140): it proves only the TURN went unheard — the
  /// three-sleep field report caught the short-lived +139 rule naming
  /// the newest snapshot ('Bash sleep 120 finished.') seconds after
  /// launch while all three shells were still running — so behind an
  /// owed shell it urges the heartbeat to consult /health NOW, where
  /// the honest detached counter pays the ledger with one bubble per
  /// name. With no agent debt it retires the line journal-only,
  /// exactly as before: no process finished, only an unheard turn
  /// closed. (behaviours 2/4)
  void _retireBgWork(
    String detail, {
    bool cancelled = false,
    String taskId = '',
    // +279: the pump's own conversation — the debt it pays is the
    // one THAT thread launched.
    String? session,
  }) {
    // +298: the receipt pays on the channel of the conversation it
    // STAMPS (the +279 law's end state — where the payment lands was
    // legislated; now it is storage).
    final chan = _channelIfKnown(session);
    if (chan == null) {
      // +313: a receipt for a conversation with no home and no kept
      // tab — the user threw the thread away; the payment dies here.
      _logDebug('bg receipt for a departed conversation — nothing to pay');
      return;
    }
    final led = chan.turn;
    // +277: remember whose band this payment might settle — the
    // retirement clears the owner, so capture it first.
    final wasOwner = led.workOwner ?? chan.sessionId;
    final unnamed = detail.isEmpty || detail.startsWith('ended after');
    if (unnamed && led.agentWork) {
      _logDebug(
        'turn closed unheard with agent work owed — '
        'probing the bridge instead of paying',
      );
      _scheduleBgProbe(every: Duration.zero);
      notifyListeners();
      return;
    }
    led.clearBgWork(); // the promise is paid here (see turn_session)
    if (led.backgrounded) led.retireBadgeAndWork();
    // +277: the LAST debt paid (the ledger released its owner — see
    // turn_session) settles that conversation's band as well.
    if (led.workOwner == null && wasOwner != null) {
      _clearOwnedBand(wasOwner, settledLabel: detail); // +282
    }
    if (unnamed) {
      // The audio fate (the 10:16 tape): a turn closed unheard still owes
      // the journal WHAT it closed with — the paragraphs its +274 gate
      // refused on other pumps' behalf. The drain's pickup lines name
      // them again as they serve, so the story reads end to end.
      final refusedAll = _refusedSays.entries
          .where((e) => session == null || e.value.sid == session)
          .toList();
      final refused = refusedAll
          .take(3)
          .map(
            (e) =>
                'say#${e.key} '
                '"${e.value.preview.length > 24 ? '${e.value.preview.substring(0, 24)}…' : e.value.preview}"',
          )
          .toList();
      _logDebug(
        'backgrounded work finished '
        '(${detail.isEmpty ? 'unnamed turn' : detail})'
        '${refused.isEmpty ? '' : ' — refused by the gate: ${refused.join(', ')}${refusedAll.length > 3 ? ' (+${refusedAll.length - 3} more)' : ''}'}',
      );
      notifyListeners();
      return;
    }
    led.payAgentDebt(detail, sid: session); // +279
    // +277: if that was the final debt, the band is history.
    if (led.workOwner == null && wasOwner != null) {
      _clearOwnedBand(wasOwner, settledLabel: detail); // +282
    }
    // +279.1: the period card stamps for the conversation that OWED
    // the shell (the frame's wire stamp), not the thread that was
    // watching when it landed — 'it shows something from the other
    // session' was this card riding the live seat's name.
    _bgFinishedBubble(
      detail,
      cancelled: cancelled,
      taskId: taskId,
      session: session ?? wasOwner,
    );
  }

  /// The persistent bubble a finished background process earns — the
  /// ONE writer of that law, so every payment path (a named receipt,
  /// or the /health proof draining the ledger) files the same period
  /// per name. Idempotent: a backlog replay may deliver a second
  /// proof after the live view already retired on the first — one
  /// completion, one period. A CUT tool's receipt says CANCELLED, the
  /// verb the agent itself will use seconds later; the period is
  /// still ONE per name whichever verb arrived first (the killed
  /// sleep must not collect 'cancelled.' and 'finished.').
  void _bgFinishedBubble(
    String who, {
    bool cancelled = false,
    String taskId = '',
    // +276: the thread the receipt belongs to — the badge's owner
    // when a scoped proof pays it, never wherever the seat happens
    // to sit when the payment lands.
    String? session,
  }) {
    if (who.isEmpty) return;
    // +186: the strict dedup — the TASK's own id. A task finishes
    // exactly once, so a receipt carrying an id already on file is a
    // redelivery by definition, whenever it lands; no window, no text
    // match, no clock assumptions. +185's RECENT-only text scan stays
    // as the fallback for id-less frames: a bridge too old to stamp,
    // or the /health proof draining the ledger by label (the
    // whole-log version of that scan made text an identity across
    // time and swallowed the second run of an identical command —
    // field: 'it doesn't show up at all').
    if (_chat.hasReceiptFor(taskId) ||
        (taskId.isEmpty &&
            (_chat.containsBlockRecent('$who finished.') ||
                _chat.containsBlockRecent('$who cancelled.')))) {
      _logDebug('msg bg done: "$who" already retired');
      return;
    }
    final note = '$who ${cancelled ? 'cancelled' : 'finished'}.';
    _chat.addSystemNote(
      note,
      cancelled: cancelled,
      receipt: true,
      receiptId: taskId,
      session: session,
    );
    _logDebug(
      'msg bg done: "$who" ${cancelled ? 'cancelled' : 'finished'} '
      '— retired the line',
    );
    notifyListeners();
  }

  // ── Live token ticker API (see TokenTicker) ────────────────────────────
  bool get tokenTickerOn => _ticker.isOn;
  String get tokenThought => _ticker.thought;
  String get tokenDraft => _ticker.draft;
  bool get turnSettled => _ticker.settled;
  String get activityLabel {
    final l = _ticker.activityLabel(status);
    // +171 belt: a LIT box never speaks the at-rest caption. Behind
    // the natural-end guard there are still paths that idle the phase
    // while a claim lives (the 12:31:20 error-frame close with a
    // backgrounded shell running — spinner lit, caption 'Ready. Hold
    // the button…' side by side). Where the box stands, the words
    // must say work-in-progress, so the fallback changes costume.
    if (l.startsWith('Ready.') &&
        ((_bridgeBusy && !_drainReading) ||
            _harnessBackgrounded ||
            showsBackgroundedWork)) {
      return 'On the bridge…';
    }
    return l;
  }

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

  /// +230: 'Debug tools' — the bug icon on the main bar retired into a
  /// setting (see BridgePrefs.debug). On, the main screen shows the
  /// replay buttons, the hold-edge counter and the event log.
  bool get debugUi => _bridgePrefs.debug;
  Future<void> setDebugUi(bool on) async {
    _bridgePrefs.debug = on;
    await _saveBridgePrefs();
    notifyListeners();
  }

  /// 'Narrate progress' switch: on, every `tool` event of a harness turn
  /// is spoken as it arrives and long silent steps repeat their line as
  /// a heartbeat (see BridgePrefs.narrate — the turn loop reads the pref
  /// live through the env, so a mid-turn flip applies to the very next
  /// step). Off: silent status text, the answer arrives when it's ready.
  Future<void> setBridgeNarrate(bool on) async {
    _bridgePrefs.narrate = on;
    await _saveBridgePrefs();
    notifyListeners();
  }

  /// 'Speak replies' switch (see [BridgePrefs.tts]). Off is the
  /// eyes-only mode for testing and degraded links: harness answers
  /// land as chat text, nothing synthesises or plays — and the send
  /// gate stops demanding the audio worker, so a phone with the models
  /// still downloading (or with no TTS pack at all) can still drive
  /// the harness from the text box.
  Future<void> setBridgeTts(bool on) async {
    _bridgePrefs.tts = on;
    await _saveBridgePrefs();
    if (on) {
      // Boot with the switch off skipped the voice pack entirely; back
      // on, put the engine right back on the worker before any reply
      // can want it.
      try {
        await _ensureVoice();
      } catch (e) {
        _fail('Voice could not be loaded: $e');
      }
    } else {
      // +166: a mute press is SILENCE NOW, and it must also close the
      // debt the +164 law projects through the brake and the row: a
      // parked drain verdict (+124) is resolved by the speaker's
      // natural end — the one event a TTS-off world never promises.
      // Stop the on-air voice, then hand any parked verdict its
      // re-check: with no audio pending it drains via reattach at
      // once (the frames file as text; a mute phone hears nothing
      // either way). Without this, toggling off — or muting
      // mid-sentence — left the Stop chip lit forever over a reply
      // whose ear had just been switched off, and the press read as
      // the cause.
      _reply.stopPlayback();
      // +298: a parked drain belongs to the conversation that parked
      // it; the speaker is single, so any channel's verdict that was
      // waiting on this audio runs now — on ITS channel, its guards.
      for (final c in _channels.values.toList()) {
        final parked = c.drainAfterSpeech;
        if (parked == null) continue;
        c.drainAfterSpeech = null;
        unawaited(_drainStrandedBacklog(parked.gen, parked.mySeq, via: c));
      }
      if (_phase == AssistantPhase.speaking &&
          !_bridgeBusy &&
          !_turn.backgrounded) {
        _idleReady(); // the voice died by the switch, not a natural end
      }
    }
    _logDebug('tts ${on ? 'on' : 'off'}');
    notifyListeners();
  }

  /// The worker may carry no engine at all (TTS was off when boot
  /// skipped the voice pack): load the saved voice NOW, before the
  /// first spoken block, so the flip-to-on never drops a reply.
  Future<void> _ensureVoice() async {
    final w = _worker;
    if (w == null || w.ttsNumSpeakers > 0) return;
    final voice = voiceById(_prefs.voiceId) ?? voiceById('titl')!;
    await voice.ensureIn(
      _modelsDir,
      onProgress: _modelProgress,
      sid: _prefs.sid,
    );
    _ttsNumSpeakers = await w.useTts(await _spec(voice, sid: _prefs.sid));
    _activeVoiceId = voice.id;
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
  /// +154: /new remains; the /compact chip retired (its slash still
  /// works through the Bridge screen's typed input), and the Stop chip
  /// is no longer in this list — it lives beside it, permanently, grey
  /// or lit by [AssistantView.agentBusy].
  /// Session housekeeping chips, in row order: they render before the
  /// permanent Stop chip, so this list is the 'in-between' the screen's
  /// row shows (+178, by dictate: the compact button sits between
  /// /new and Stop). /compact retired from the row at +154 because it
  /// parked an ordinary stream mid-turn and the ack was wordless; the
  /// +171 seatless fold (the notice IS the answer) and the typed
  /// slash's ack made it chip-worthy again — and the fold it rides is
  /// the very machinery the field deadlock proved.
  static const controlChips = <String>['/model', '/new', '/compact'];

  /// Saves bridge settings (empty url disables the feature entirely).
  Future<void> setBridge({required String url, required String token}) async {
    _bridgePrefs
      ..url = url.trim().replaceAll(RegExp(r'/+$'), '')
      ..token = token.trim();
    _rebuildGateway();
    _sessionId = null; // the old bridge's pointer is not this bridge's
    _lastHealth = null;
    _seatReconciled = false; // +230: a new bridge gets its own glance
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

  /// One folder level of the bridge's working-folder picker (GET /dirs):
  /// [path] null = the bridge's allowlisted root. Null = unreachable,
  /// refused, or a harness with no folder browser at all.
  Future<Map<String, Object>?> bridgeDirs({String? path}) async =>
      await _gateway?.dirs(path: path);

  /// Move the harness to another working folder (POST /dir): an honest
  /// /new there — the conversation is dropped and the next utterance
  /// spawns the agent inside the picked directory. Returns the failure
  /// reason (shown as-is), null on success.
  Future<String?> setBridgeDir(String path) async {
    final g = _gateway;
    if (g == null) return 'bridge not configured';
    final err = await g.setDir(path);
    if (err == null) {
      _syncTabFromSeat(dir: path); // +230: the tab follows its seat
      unawaited(_refreshSession()); // the dir row re-reads /health
    }
    return err;
  }

  /// The Bridge screen's harness row: switch which harness the bridge
  /// speaks (claude ↔ opencode). The switch drops the LIVE conversation
  /// the way /new does, but the pointers are per-harness — flipping
  /// back resumes exactly where that harness stopped.
  Future<String?> setBridgeHarness(String to) async {
    final g = _gateway;
    if (g == null) return 'bridge not configured';
    final err = await g.setHarness(to);
    if (err == null) {
      _syncTabFromSeat(harness: to); // +230: the tab follows its seat
      // AWAITED: the era tracker (and with it the chat thread and the
      // Bridge row) must move BEFORE this call returns — the switch's
      // own reply is that the screen it left is gone. No channel note
      // is filed (+215): the thread changing under your eyes IS the
      // verdict; a bubble explaining it cluttered the log the split
      // exists to clean, and repeated itself on every flip.
      await _refreshSession();
    }
    return err;
  }

  /// The model picker's menu (GET /models) for whichever harness is
  /// live. Null = unreachable, or a bridge with no picker. +230:
  /// [harness]/[dir] ask the menu of a seat the bridge is NOT on —
  /// the session sheet previews the other harness's catalog (and a
  /// different folder's, where opencode resolves per-directory)
  /// before any of it moves.
  Future<Map<String, Object>?> bridgeModels({
    String? harness,
    String? dir,
  }) async => await _gateway?.models(harness: harness, dir: dir);

  /// Apply a model pick (POST /model) and AWAIT the /health re-read:
  /// the row's current-model label is the truth the moment this call
  /// returns, not eventually. +218: the pick is also REMEMBERED under
  /// the current harness — the app's own memory outlives a bridge
  /// restart, where the bridge's word does not (see BridgePrefs).
  Future<String?> setBridgeModel(String id) async {
    final g = _gateway;
    if (g == null) return 'bridge not configured';
    final err = await g.setModel(id, sessionId: _sessionId);
    if (err != null &&
        err.contains('not in --models') &&
        _bridgeHarness != null &&
        _bridgePrefs.lastModels[_bridgeHarness] == id) {
      // +304: a refusal of the REMEMBERED word is the menu correcting
      // the memory (the field tape's 'flash-next': remembered,
      // re-minted into every fresh /seat record, refused at every
      // picker). The stale word goes; a refusal of some OTHER word
      // leaves the memory standing (the +218 law above it).
      _bridgePrefs.lastModels = {..._bridgePrefs.lastModels}
        ..remove(_bridgeHarness);
      unawaited(_saveBridgePrefs());
      notifyListeners();
    }
    if (err == null) {
      _syncTabFromSeat(model: id); // +230: the tab follows its seat
      final era = _bridgeHarness;
      if (era != null) {
        _bridgePrefs.lastModels = {..._bridgePrefs.lastModels, era: id};
        await _saveBridgePrefs();
      }
      await _refreshSession();
    }
    return err;
  }

  /// The model this harness last answered with, as the app remembers
  /// (null = never picked, or no harness known yet). The picker's
  /// badge and the row's fallback label both defer to the bridge's
  /// CURRENT whenever /health has one.
  String? get bridgeLastModel => _bridgePrefs.lastModels[_bridgeHarness ?? ''];

  /// +281: the name the bar wears. The +241 bar read ONLY the app's
  /// pick-memory — so a seat answering with its created or default
  /// model (never pressed through the picker) showed no name at all,
  /// which is the silence the field just caught. The bridge's own
  /// word wins: the model the seated conversation's /health named is
  /// the same truth the bridge row prints; the remembered pick is
  /// the fallback for a bridge with no current (a restart, opencode
  /// before its first step).
  String? get _barModel {
    final m = _lastHealth?['model'];
    if (m is String && m.isNotEmpty) return m;
    return bridgeLastModel;
  }

  /// The grey queue bubble's tap: cut the in-flight turn so the parked
  /// prompt starts NOW. Just a /stop — NOT the Stop chip's full
  /// bridgeStop: no detach, no supersede, no speaker silencing. This
  /// phone's queued view stays listening; the interrupted turn's
  /// farewell is swallowed by owner attribution (v2: done carries its
  /// turn id), the bridge's flush hands the floor to the parked prompt
  /// one event later, and its answer arrives in the ordinary place.
  Future<void> interruptForQueued() async {
    _logDebug('queue tap: /stop to flush the parked prompt now');
    await _gateway?.stop();
  }

  // ── Files relayed from the bridge (POST /send -> 'file' frames) ────────

  /// The file bubble's tap: OPEN. Saved already? Straight to the
  /// system viewer (the package installer for an APK). Not saved yet?
  /// Fetch first, then open on the same tap — one gesture, one
  /// intent. Saves under app support/received/`name` (a .part from an
  /// interrupted transfer resumes where the wire died); progress
  /// mutates the entry's memory-only fields, so the channel repaints
  /// the percentage without touching disk.
  Future<void> fetchChatFile(ChatEntry e) async {
    if (e.downloading) return;
    if (e.savedMs != 0 && e.savedPath.isNotEmpty) {
      await _openChatFile(e);
      return;
    }
    final g = _gateway;
    if (g == null || e.filePath.isEmpty) return;
    e.downloading = true;
    e.openError = null;
    e.totalBytes = e.fileSize;
    notifyListeners();
    var ok = false;
    var dest = '';
    try {
      final dir = Directory(await _receivedDir());
      await dir.create(recursive: true);
      dest = p.join(dir.path, p.basename(e.fileName));
      ok = await g.downloadFile(
        e.filePath,
        dest,
        onProgress: (done, total) {
          e.downloadBytes = done;
          if (total > 0) e.totalBytes = total;
          notifyListeners();
        },
      );
    } on Object catch (err) {
      _logDebug('file fetch "${e.fileName}" failed: $err');
    }
    e.downloading = false;
    if (ok) {
      e.savedMs = _clock().millisecondsSinceEpoch;
      e.savedPath = dest;
      _chat.touch(); // persist the saved stamp (and repaint)
      await _openChatFile(e); // the tap asked to OPEN it; deliver
    } else {
      notifyListeners();
    }
  }

  /// Hand a saved bubble to the OS. Any failure (no viewer for the
  /// type, no channel on a test host) lands on the bubble's status
  /// line — the tap must never fail silently.
  Future<void> _openChatFile(ChatEntry e) async {
    try {
      await _opener.open(e.savedPath, mime: mimeForFile(e.fileName));
      e.openError = null;
    } on Object catch (err) {
      e.openError = '$err';
      _logDebug('file open "${e.fileName}" failed: $err');
    }
    notifyListeners();
  }

  // ── The harness turn (see bridge_turn.dart for the loop itself) ────────

  /// Runs one harness turn: utterance -> /talk (or a caller-supplied
  /// event source) -> the [BridgeTurn] loop speaks each `say` event the
  /// moment it lands, streamed through the same chunked player voice
  /// replies use. Tool activity shows up as live status text instead of
  /// dead air. [bubble] is the short text to show as the user message
  /// (chip label / typed text); the voice path passes none because
  /// _startTurn already logged the heard utterance. [ack] is spoken when
  /// the turn produced no speech at all (silent-success controls like
  /// /compact, whose compaction signal is a system event the harness
  /// never narrates). [events] replaces the /talk call — the /new chip
  /// uses it to hit the bridge's reset endpoint and finish with zero
  /// events instead. [interrupt] is the queue flavour if the bridge
  /// turns this into a queued prompt behind a still-running turn: true
  /// (default) interrupts a mere thinking turn in-band (the process
  /// survives) so this one starts at once; false lets the turn in flight
  /// finish first (the push-to-talk slide-right polite queue).
  Future<void> runQuickCommand(
    String utterance, {
    String? bubble,
    String? ack,
    String? status,
    bool interrupt = true,
    // Queue-with-backgrounding (behaviour 2): a POLITE queue that also
    // cuts a running tool. The phone stopped sending it at +144 — the
    // field's sleep repro proved the CLI's interrupt KILLS the running
    // call (exit 143) instead of backgrounding it, so 'queue around a
    // build' means WAIT for the build, not destroy it. The wire flag
    // remains for a harness that can genuinely detach a tool; the
    // phone's Queue button is polite full stop.
    bool cutTool = false,
    // +148: this prompt POLITELY PARKS behind work still running even
    // when no pin rides (the PTT queue release over a press-detached
    // turn): the spinner box and its tool-call line stay untouched
    // until the bridge's pickup, whichever transport carries it.
    bool parkBehind = false,
    Stream<BridgeEvent> Function()? events,
  }) async {
    // +249→+257→+298: a turn the SEAT starts is at home here — the
    // claim lands on the seat's OWN channel, and another conversation's
    // backgrounded work cannot be dragged over by this tab deciding to
    // speak (the xray volley's law, now the map's shape).
    final gateway = _gateway;
    if (gateway == null) {
      _fail('No bridge — open the terminal icon and set url + token.');
      return;
    }
    if (_transport.proto != 0 && !_transport.protoV2) {
      // wire v2, no fallback: ids are the delivery law, and a bridge
      // that has never announced proto 2 cannot honour them. One
      // honest banner, no silent guessing.
      _fail('Bridge too old — install the new claude_bridge.mjs (wire v2)');
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
    // +297 (structural via +298): the wait is only real when the turn
    // waited behind is THIS conversation's — `_bridgeBusy` IS this
    // channel's flag.
    final queuedBehindLiveTurn = !interrupt && _bridgeBusy;
    // Pin policy aside, ANY prompt sent while the bridge holds a turn
    // (heard or backgrounded) PARKS at its front — and on the POLL ring
    // the parked pump inherits the busy turn's farewell done, which it
    // must survive to see its own pickup (the bash-sleep field report).
    // The transport's pre-pickup armor is armed off this same
    // before-abandon snapshot.
    final bridgeHadLiveTurn = _bridgeBusy || _harnessBackgrounded;
    // +149: two parked truths, computed once. PARKED (broad): work is
    // live and this prompt waits behind it — the spinner box and its
    // line must survive the send, whichever transport later reports
    // the pickup. GREYED (narrow): the wait will be HEARD (a busy
    // turn, or a queue release whose successor pump re-ears the tail)
    // — only that wait wears the grey, per +126's badge-alone rule.
    final parkedHere = !interrupt && (parkBehind || bridgeHadLiveTurn);
    final greyedHere = !interrupt && (parkBehind || queuedBehindLiveTurn);
    _turn.supersede();
    _turn.detach(TurnTrigger.newUtterance, polite: !interrupt);
    if (_worker == null && !_ttsOff) {
      // TTS off means this send needs no audio machinery at all: the
      // text box answers even while the models are still loading.
      _fail('Models are still loading — try again in a moment.');
      return;
    }
    if (bubble != null && bubble.trim().isNotEmpty) {
      _chat.addUser(bubble.trim(), queued: greyedHere);
    }
    // The bubble this send may have pinned: remembered so a superseded
    // queue-turn can retire the pin instead of fossilising it (the
    // bridge's pending slot is latest-wins — a replaced prompt never
    // gets its 'started'). A wire death of the SAME generation keeps
    // the pin: the bridge still owes the prompt (+104) and the pickup
    // marker will arrive through whatever view returns.
    final ChatEntry? pinnedByMe = greyedHere ? _chat.queuedBubble : null;
    // A pin drops ONLY when a newer PROMPT supersedes this one (the
    // bridge's one pending slot is latest-wins). Bumps from bridgeStop
    // or a reattach do not void the promise — after a /stop the bridge
    // still flushes the queued prompt, whose 'started' unpins then.
    final myPromptBumps = ++_promptBumps;
    // One assistant bubble for the whole turn, sections appended as each
    // say's audio queues (text follows the voice, never leads it). An
    // interrupted turn keeps the sections actually spoken — that IS what
    // the conversation was. A turn that never spoke is removed at the end.
    final turn = _chat.beginTurn();
    final led = _turn; // +302: the ledger THIS gen belongs to
    final gen = led.supersede(); // supersedes any in-flight voice reply
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
    _chainCancel();
    _error = '';
    _transcript = utterance;
    _phase = AssistantPhase.transcribing;
    if (parkedHere) {
      // +147/148: a PARKED prompt leaves the spinner's text box exactly as
      // it found it. The box currently names the work the agent is
      // chewing — 'Bash sleep 10…', its tokens ticking — and
      // overwriting it with 'Asking the bridge…' hid the very wait the
      // greyed pin is telling: the prompt is not asking, it is
      // waiting. New steps of the running turn arrive on this very
      // loop and refresh the line as they land; when the started
      // marker dissolves the pin (un-grey), the answer takes the line
      // over like any heard turn.
      //
      // The ticker keeps counting too: the numbers belong to the
      // conversation, not to the POST — the parked view relays the
      // same turn's tallies.
      _awaitPickup = true;
      _logDebug('parked: spinner line left to the running work');
    } else {
      _activity = TurnWaiting(status ?? 'Asking the bridge…');
      _ticker.resetForTurn();
      _awaitPickup = false;
    }
    _drainReading = false; // +168: a /talk turn is real work by
    // definition — the mail-fetch badge belongs to reattaches only.
    notifyListeners();
    _reply.warmUpRoute(); // hold the output route while the harness thinks
    _reply.startStream();
    _ttsSeconds = 0; // the strip tallies per turn: reset, then the
    _ttsFirstTimed = false; // first spoken block stamps the tts number
    _reply.playSeconds = 0; // once (first-word latency) and play time accrues
    _hide.buryDropMark(); // a fresh turn buries any hide-marked paragraph
    _startPump(gen, led: led);
    await BridgeTurn(
      origin: events == null ? BridgeTurnOrigin.talk : BridgeTurnOrigin.control,
      env: _turnEnv,
      turn: _turn,
      chat: _chat,
      ticker: _ticker,
      narr: _narr,
      hops: _hops,
      reply: _reply,
      lease: _lease,
      transport: _transport,
      scheduler: _scheduler,
      gen: gen,
      mySeq: mySeq,
      turnBubble: turn,
      utterance: utterance,
      interrupt: interrupt,
      cutTool: cutTool && !interrupt,
      pinnedEntry: pinnedByMe,
      myPromptBumps: myPromptBumps,
      ack: ack,
    ).run(
      events?.call() ??
          _transport.turn(
            gateway,
            utterance,
            interrupt,
            // +306: the prompt names ITS conversation — the pump is
            // born at an address (+299) and the wire honours the name
            // even if the world's seat moves before the POST lands
            // (the +303 corrective re-seat, a retry, a sibling).
            sessionId: _chan.sessionId,
            cutTool: cutTool && !interrupt,
            onActivity: _lease.markAlive,
          ),
    );
  }

  /// The assistant-side surface the turn loop drives (see
  /// [BridgeTurnEnv]): the UI truth, the hide/resume bookkeeping, and
  /// the teardown follow-ups. All tear-offs — no assistant-side logic
  /// lives in these closures beyond the field each one owns.
  BridgeTurnEnv get _turnEnv => _envFor(_chan);

  /// Freshly built for every pump (+298): the token arm — generation,
  /// seq, busy, badge, pickup, focus watermark — binds to the pump's
  /// OWN channel at build time, so a swipe after the POST can never
  /// make a live pump compare its generation against another
  /// conversation's counter (the law the single-channel era got for
  /// free and the marker era legislated clause by clause).
  BridgeTurnEnv _envFor(SessionChannel chan) {
    final led = chan.turn;
    return BridgeTurnEnv(
      mode: () => _mode,
      backgrounded: () => _backgrounded,
      narrateOn: () => _bridgePrefs.narrate,
      speakingNow: () => _phase == AssistantPhase.speaking,
      // +298: the pump's tokens read ITS channel (built fresh per pump).
      generation: () => led.generation,
      turnSeq: () => led.seq,
      busy: () => led.busy,
      badgeLit: () => led.backgrounded,
      hasError: () => _error.isNotEmpty,
      mergeContext: _mergeContext,
      seatedSession: () => _sessionId,
      cacheAwayBand: cacheAwayBand, // +266: away frames keep the owner's
      setStatus: _setStatus, // cache current, not the painted band
      setPhase: (ph) => _phase = ph,
      markSpeaking: () => _phase = AssistantPhase.speaking,
      idleReady: _idleReady,
      fail: _fail,
      // +219 showed the provider's words to the STATUS LINE — and Tim's
      // eye, on the CHAT WINDOW, still saw nothing: an assistant bubble
      // that never spoke is hidden by design, and the caption row is
      // not history. +110 already has the law for turn verdicts: the
      // verdict gets its OWN card. The error-done now files one — the
      // provider's own sentence (the bridge's words when an old wire
      // sent only the flag), in the receipt outline (+184: a receipt
      // reads as a receipt, not as prose the agent said), stamped with
      // the era that heard it, so each thread keeps its own failures.
      // Adjacency-idempotent like every note: a replay of one error-done
      // files one card.
      noteHarnessError: (why, session) {
        // +275: the error card belongs to the conversation that HEARD
        // it (the pump's stamp), not to whatever tab the seat paints
        // when the frame lands — the wrong-tab receipt leak.
        _chat.addSystemNote(
          _error = why ?? 'the harness reported an error',
          receipt: true,
          session: session,
        );
      },
      noteReplyText: _hide.noteReplyText,
      noteUnheardSay: _hide.noteUnheardSay,
      noteSpoken: (s) => _lastSpoken = s,
      isDropped: _hide.shouldDrop,
      blockAired: _hide.blockAired,
      noteFirstWord: _noteFirstWordLatency,
      noteAudioActivity: _narr.audioActivity,
      refreshSession: _refreshSession,
      armReattach:
          ({
            required int gen,
            required int seq,
            bool retire = false,
            bool resetStep = true,
            Duration? firstProbe,
          }) => _armReattach(
            gen: gen,
            seq: seq,
            retire: retire,
            resetStep: resetStep,
            firstProbe: firstProbe,
            via: chan,
          ),
      drainBacklog: (g, sq) => _drainStrandedBacklog(g, sq, via: chan),
      log: _logDebug,
      repaint: notifyListeners,
      ttsOff: () => _ttsOff,
      retireBgWork: _retireBgWork,
      parkCutTrace: (e) => _pttCutTrace ??= e,
      cutTrace: () => _pttCutTrace,
      promptBumps: () => _promptBumps,
      phase: () => _phase,
      armBgProbe: _scheduleBgProbe,
      notePickup: () => chan.awaitPickup = false,
      awaitingPickup: () => chan.awaitPickup,
      isHeard: _heard.isHeard,
      commitHeard: _heard.commit,
      // The foreign-say ledger: refusals write, takes read (the drain's
      // pickup line, the retirement's audio fate).
      noteRefusedSay: _noteRefusedSay,
      claimRefusedSay: _claimRefusedSay,
      focusAtMs: () => chan.focusAtMs, // +253: the channel keeps the time
      // +257: DONE IS THE PROOF — the away marker retires when the
      // conversation it guards says its period, and not one frame
      // earlier: a swipe, a supersede, or an age-out must never orphan
      // work that is still thinking. +298: the marker IS the channel —
      // a done speaks for its own thread by construction; the line keeps
      // the tape honest when away work had been signed here.
      noteWorkHome: (sid) {
        // +313: reading a log line is no business of a frame's — it
        // may not open a home.
        final c = _channelIfKnown(sid);
        if (c != null &&
            (c.turn.backgrounded ||
                c.turn.detachedPromise ||
                c.turn.agentWork)) {
          _logDebug(
            'work home: done — marker retired, every tab its '
            'own face again',
          );
        }
      },
      // +298: a frame stamped for another conversation writes ITS OWN
      // ledger instead of being suppressed by the +297 owner gates — the
      // meter keeps ticking for the work you are not watching, and the
      // row you come home to learned what it was doing.
      routeForeignTool: (ev, stepLine) {
        // +313: a stranger's frame may not invent a stranger.
        final c = _channelIfKnown(ev.session);
        if (c == null) return;
        if (ev.toolName == 'tokens') {
          c.ticker.onFrame(ev);
          return;
        }
        if (ev.toolName == 'backgrounded') {
          c.turn.noteAgentWork(ev.detail, sid: ev.session);
          c.ticker.markToolStep();
          return;
        }
        c.ticker.markToolStep();
        if (stepLine.isNotEmpty) c.turn.noteToolStep(stepLine);
      },
      turnOpenOnWire: () async {
        final h = await _gateway?.healthInfo();
        return h != null && h['turnOpen'] == true;
      },
    );
  }

  /// +148: a polite prompt PARKED behind work still running (pin or
  /// badge — the PTT queue release has no pin). While set, the spinner
  /// box stays on the RUNNING work's bubble and its text survives; the
  /// bridge's pickup (whichever transport delivers it) clears the flag
  /// and the answer's bubble takes the box.
  bool get _awaitPickup => _chan.awaitPickup; // +298: the wait is the
  // conversation's, not the machine's
  set _awaitPickup(bool v) => _chan.awaitPickup = v;

  /// +168: this view is a MAIL FETCH — an /attach claimed while /health
  /// said no turn is open, so its replay surfaces history, not work.
  /// Keeps the working box dark while the busy slot and the Stop chip
  /// stay honest (the replay is real and cuttable). Set at the reattach
  /// claim, cleared by any /talk (real work by definition).
  bool get _drainReading => _chan.drainReading;
  set _drainReading(bool v) => _chan.drainReading = v;

  /// +152: a queue verdict may not bump a running tool's line. The
  /// spinner's fallback label (tally kind 'calling X') reads the
  /// status — so every 'One moment — a tool call is running…' notice
  /// that stomped the live StepLine flipped the row from the command
  /// to the announcement of the wait and back on the next step:
  /// 'leave it untouched showing the tool call command we are waiting
  /// on'. The verdict still journals at its call site, and the greyed
  /// message remains the on-screen wait indicator (+146).
  void _setStatus(Activity a) {
    if (a is QueuedVerdict && _activity is StepLine) {
      _logDebug('queue verdict held: the row keeps naming the tool');
      return;
    }
    _activity = a;
    notifyListeners();
  }

  // Queue-prompt bookkeeping: every runQuickCommand (a NEW USER PROMPT)
  // bumps this alongside _generation. A queue turn's finally drops its
  // pin on supersede only when a NEWER PROMPT caused the supersede —
  // bridgeStop/reattach bumps also move _generation, but after a /stop
  // the bridge FLUSHES the pinned prompt (its 'started' unpins then);
  // dropping the pin there would lie about a promise being kept.
  int _promptBumps = 0;

  /// +132: the bubble a push-to-talk PRESS took out of the ear, while
  /// the gesture that decides its trace is still in flight. The press
  /// detaches (the mic must open now); the stamp does not: only the
  /// release knows whether this was a slide-up cut, a motionless tap
  /// stop, a polite queue, or a dismiss that ends 'as if nothing
  /// happened'. The abandoned turn's finally parks its bubble here
  /// (withdrawn while empty, untouched while it has spoken text); the
  /// release applies the trace, or drops it and the bubble with it.
  ChatEntry? _pttCutTrace;

  /// +188: the user bubble opened at the release moment, pulsing while
  /// ASR finds the words. Filled when the transcript lands; withdrawn
  /// (removeEmptyTurn) on every path that never sends — superseded,
  /// discarded, empty, echo, or a failed transcribe.
  ChatEntry? _transcribeBubble;

  void _withdrawTranscribe(String why) {
    final b = _transcribeBubble;
    _transcribeBubble = null;
    if (b != null) {
      _chat.removeEmptyTurn(b);
      _logDebug('transcribe bubble withdrawn ($why)');
    }
  }

  /// +236: a chunked long-hold decode finished another piece. The
  /// placeholder bubble fills progressively — same card, growing —
  /// instead of making the listener wait for the whole retranscription;
  /// the cumulative text is provisional until the final fillUser
  /// replaces it, which is why the pulse stays lit.
  void _onTranscriptPartial(String soFar) {
    final b = _transcribeBubble;
    if (b == null || _phase != AssistantPhase.transcribing) return;
    _chat.progressUser(b, soFar);
    _logDebug(
      'asr partial '
      '"${soFar.length > 40 ? '${soFar.substring(0, 40)}…' : soFar}" '
      '(${soFar.length} chars so far)',
    );
    notifyListeners();
  }

  /// The release decided: this turn WAS cut — file the +110 trace it
  /// owed from press time (a withdrawn-empty bubble comes back wearing
  /// it; a partly-spoken one only gets the ✋ mark).
  void _applyPttCutTrace() {
    final t = _pttCutTrace;
    _pttCutTrace = null;
    if (t == null) return;
    if (t.isEmpty) {
      _chat.reAppend(t);
      _chat.addBlock(t, 'Interrupted before answering.');
    }
    _chat.markInterrupted(t);
  }

  /// The release decided NOTHING was cut AND the moment is over (slide
  /// right): no trace, and the empty bubble that only existed to carry
  /// one is finally withdrawn — 'as if nothing happened'.
  void _dropPttCutTrace() {
    final t = _pttCutTrace;
    _pttCutTrace = null;
    if (t != null && t.isEmpty) _chat.removeEmptyTurn(t);
  }

  /// The release QUEUED behind the turn (+148): no trace is owed — but
  /// the bubble is NOT 'as if nothing happened': the work it names is
  /// still running, and the bubble is its live view. Withdraw it and
  /// the tool-call spinner box vanishes mid-flight (the very symptom
  /// the queue must not cause); keep it, free the paperwork slot.
  void _keepPttCutTrace() {
    _pttCutTrace = null;
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
  Future<void> _drainStrandedBacklog(
    int gen,
    int mySeq, {
    SessionChannel? via,
  }) async {
    // +298: the drain re-runs the OWNING conversation's verdict — its
    // guards read its turn tokens, its park lives on its channel, and
    // the ladder it arms is its own.
    final chan = via ?? _chan;
    if (pttHoldActive || _backgrounded) return;
    // +164: flush heard-acks in flight BEFORE the verdict — a just-
    // spoken reply trims its backlog copies under this POST, and the
    // row must not stay lit for a drain that was only ever racing its
    // own ack. (Since +164 the verdict also drives the working row: a
    // parked drain projects as agentBusy — a false park here would
    // spin through the last sentence.)
    await _heard.retry();
    final h = await _gateway?.healthInfo();
    if (h == null) return;
    final missed = (h['missed'] as num?)?.toInt() ?? 0;
    if (missed < 1) {
      // +166: nothing unheard any more — whatever parked promise this
      // turn left (or a fatter one it re-formed) is PROVEN paid. An
      // early return that left it standing stranded the lit brake
      // whenever another listener (the resume probe, the bg-probe
      // chain) drained the backlog out from under it.
      if (chan.drainAfterSpeech != null) {
        chan.drainAfterSpeech = null;
        notifyListeners();
      }
      return;
    }
    if (gen != chan.turn.generation || chan.turn.seq != mySeq) return;
    // +124: the field's last mid-word cut. The bridge's `missed` is the
    // backlog LENGTH — a replayable history that only the heard-dedup
    // filters — so this verdict fires at nearly every turn end, and it
    // fires while our own final paragraph is still on the speaker (the
    // wire finishes long before the voice does). The chain it arms
    // opens with stopPlayback: the drain cut a paragraph that was
    // never going to be re-voiced (the ledger already owns it), and
    // the listener heard the tail of the answer die at the spinner's
    // dismissal while the replay babbled on. Park the verdict instead:
    // _handleNaturalEnd re-runs it the moment the speaker is honestly
    // silent, and every guard (PTT, hidden, ownership, missed) is
    // re-checked then.
    if (_reply.playing) {
      chan.drainAfterSpeech = (gen: gen, mySeq: mySeq);
      _logDebug(
        'stranded backlog: missed=$missed — audio still on air; '
        'drain parked to the natural end',
      );
      // +164: the parked promise IS in-flight work — repaint so the
      // row (and the brake) light through the on-air chunk instead of
      // blinking at the drain.
      notifyListeners();
      return;
    }
    chan.drainAfterSpeech = null;
    _logDebug('stranded backlog: missed=$missed — draining via reattach');
    chan.chain.start(
      gen: gen,
      seq: mySeq,
      retire: true,
      firstProbe: Duration.zero,
    );
  }

  /// A drain verdict the teardown parked behind on-air audio (+124);
  /// consumed by [_handleNaturalEnd], superseded by any newer verdict.
  /// +251: CHANNEL state — one conversation never parks another's drain.
  ({int gen, int mySeq})? get _drainAfterSpeech => _chan.drainAfterSpeech;
  set _drainAfterSpeech(({int gen, int mySeq})? v) =>
      _chan.drainAfterSpeech = v;

  /// +302: staleness is a relationship between a TURN and its OWN
  /// conversation's ledger. Every `gen == _generation` closure below
  /// compared against WHICHEVER channel the seat looks through now —
  /// sound in a single-channel world, a leak since +298 made the
  /// seat swappable: the field tape's /new pressed its own wipe, the
  /// wipe swapped the active coordinator, and the fresh ack's audio
  /// died 'between chunks' to a generation comparison against a
  /// stranger's zero. Generations are issued by a ledger; ask the
  /// issuer, not the furniture.
  bool Function() _stale(TurnCoordinator led, int gen) =>
      () => gen != led.generation;

  void _startPump(int gen, {required TurnCoordinator led}) =>
      unawaited(_reply.runPump(isStale: _stale(led, gen)));

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
    // +277: a stopped badge's band retires with it.
    final stoppedOwner = _turn.workOwner ?? _sessionId;
    if (_turn.stopDetachedWork()) {
      _clearOwnedBand(stoppedOwner);
      _activity = const StatusText(
        'Stopped the harness — the detached turn was cut short.',
      );
      notifyListeners();
    }
    // +164: a parked drain owes this phone a reply — the chip is lit
    // for it (agentBusy), so the press must land: silence the speaker,
    // drop the owed second look (the drain's own guards would re-check
    // it anyway; dropping it merely admits the user chose 'skip'),
    // and /stop in case the follow-on turn is live on the harness.
    // Nothing is spoken when only the debt was open — the silence the
    // user asked for arrives by doing nothing else.
    final owed = _drainAfterSpeech != null && !_bridgeBusy;
    _drainAfterSpeech = null;
    if (!_bridgeBusy) {
      if (owed || _turn.agentWork) {
        // +170: the press lands on both out-of-band debts. The owed
        // reply: silence, drop the second look, idle. The RUNNING
        // AGENT SHELL (the sleep-300 field shape — a backgrounded
        // task with the turn already closed): the box and the banner
        // both claim work, so the brake must /stop it; the CLI kills
        // the task and its termination receipt pays the banner like
        // any finished frame. Silence-on-press is the +166 law either
        // way.
        // +257: the out-of-earshot debts have an owner too — cut the
        // conversation that owes them, not whoever is seated.
        unawaited(_gateway?.stop(sid: _turn.workOwner ?? _sessionId));
        _reply.stopPlayback();
        if (owed) _idleReady();
      }
      return;
    }
    _turn.supersede();
    _reply.stopPlayback();
    // Hard stop incl. the streamed-player teardown inside the funnel.
    _turn.detach(TurnTrigger.stopChip);
    _turn.retireBadge(); // nothing left working invisibly
    _idleReady();
  }

  /// The chip (and any typed slash): conversation housekeeping with an
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
    // '/model' is a chip but never a bridgeControl verb: the main-screen
    // row intercepts it and pops the picker sheet (assistant_screen,
    // +242) — no prompt crosses the wire to change a model. If it ever
    // arrives here (typed '/model'), it rides the ordinary quick-command
    // path and the harness answers the slash itself.
    if (chip == '/new') {
      return runQuickCommand(
        chip,
        bubble: chip,
        status: 'Starting a fresh conversation…',
        ack: 'Starting a new conversation.',
        events: () {
          _logDebug('bridge: new session');
          // +306: the /new chip resets ITS tab's record by name —
          // 'the CURRENT seat' was whoever the last request left,
          // which after any race was not necessarily this tab.
          unawaited(_gateway?.reset(sessionId: _sessionId));
          // The phone forgets too: the app's chat log is the other half
          // of a fresh start (the spoken ack stays brief; the wipe speaks
          // for itself on screen). Wipe memory and disk
          // so the screen goes blank exactly when the harness drops its
          // session — both bubbles this chip just added included; a
          // /new that leaves its own tombstone on screen is not blank.
          // +230: UNDER A TAB the wipe is the TAB's, not the log's —
          // this tab's sessions and its nameless sentinel leave, every
          // other tab's thread and the shared prologue stand. (The
          // bridge's /new still resets the CURRENT seat, which is this
          // tab's seat by the sync law below — replace-in-place.)
          final tab = _tab;
          if (tab == null) {
            _chat.clearAll();
          } else {
            // +302: rewritten under +295's identity law. /new starts
            // the record FRESH; it does not RENAME it. The old wipe
            // predated that law and purged the live channel with the
            // history: the seat went unnamed, the ack stamped the
            // pending sentinel (invisible to the named tab the
            // adoption had just become), userOnly adoption couldn't
            // rescue an assistant bubble, and the mid-synth reply
            // pump — reading the SWAPPED-IN coordinator's generation
            // — declared the fresh ack stale between chunks (field
            // tape: three presses, no visible ack, no whole word
            // spoken; 'the new button stopped working'). The law
            // again: the HISTORY dies, the IDENTITY stands. The
            // seat's channel retires its warrants IN PLACE (an
            // erased thread's owed shells have no ear to report to,
            // +276 unchanged); the tab's OTHER ids — a resumed
            // thread's predecessors, a forked birth — are truly
            // gone and their channels go with them.
            final here = _sessionId;
            _turn.retireBadgeAndWork();
            _turn.settleDebtsOwnedBy(here);
            final doomed = {
              for (final id in tab.sessionIds)
                if (id != here) id,
            };
            _purgeChannelsOwned(doomed);
            _chat.removeSessions({...tab.sessionIds, ChatStore.pendingSession});
            // The name stands (replace-in-place, +295's way): the
            // uuid survives as the tab's currentId and its one
            // remaining ledger name — the next /health will name
            // this same record anyway. A still-unnamed birth keeps
            // its sentinel as the name, honestly: it has none yet.
            tab.sessionIds
              ..clear()
              ..add(here ?? ChatStore.pendingSession);
            unawaited(_saveBridgePrefs());
          }
          // And the meter goes blank with the chat, not into a
          // monotonic decline from last week's number: /health will now
          // answer in:0 (the bridge cleared its snapshot), and
          // _mergeContext ignores zeros, so the reset has to happen
          // here. The first message_start of the new conversation puts
          // an honest number back on the bar. +280: the tab's CACHED
          // reading goes blank with it — a conversation that was just
          // erased has no yesterday's number to be woken by on the
          // next swipe home.
          _contextIn = 0;
          tab?.ctxIn = null;
          tab?.ctxWindow = null;
          unawaited(_saveBridgePrefs()); // the blanked cache, on disk
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
      _modelsFailed = false;
      final modelsDir = await unpackModels(onProgress: _modelProgress);
      _modelsDir = modelsDir;
      _prefs = await loadTtsPrefs(modelsDir);
      _asrPrefs = await loadAsrPrefs(modelsDir);
      _bridgePrefs = await loadBridgePrefs(modelsDir);
      // +280: the cold start opens on the seated tab's OWN remembered
      // reading — the bar has a number from the first frame, and the
      // first /health glance updates it the moment truth arrives.
      if (_bridgePrefs.tabs.isNotEmpty) _landBarOnTab(_tab!);
      // The mode tab the user last used — a habit, restored, not reset
      // to the factory default every cold start.
      _mode = _bridgePrefs.mode == 'pushToTalk'
          ? InteractionMode.pushToTalk
          : InteractionMode.conversation;
      // The conversation and its fingerprint come up BEFORE anything
      // that can fail on a network: chat_log.json is a tiny local read
      // and /health a best-effort glance. A cold start on a dead or
      // slow wire (the ASR/voice downloads below, the first throw in
      // this try block) must not cost the user their history and
      // session id — both are perfectly intact on disk and on the
      // bridge; the old position after the download only ever LOOKED
      // like the restart had eaten them.
      _loadChat(); // restore the on-screen conversation (file read is tiny)
      _rebuildGateway();
      unawaited(_refreshSession()); // chat-screen top row knows the id
      // The saved ASR pack must be fully on disk (marker present);
      // otherwise fall back to the default (tiny.en), which downloads on
      // first run just like the voice packs below.
      var asr = asrModelById(_asrPrefs.modelId) ?? asrModelById('tiny.en')!;
      if (asr.id != 'tiny.en' && !await asr.installedIn(modelsDir)) {
        asr = asrModelById('tiny.en')!;
      }
      _asrPrefs.modelId = asr.id;
      _activeAsrId = asr.id;
      await asr.ensureIn(modelsDir, onProgress: _modelProgress);
      _heardLedger = await loadHeardLedger(
        modelsDir,
        send: (mids) async => await _gateway?.heard(mids) ?? false,
      );
      // The journal comes up BEFORE anything else can go wrong, and it
      // loads its disk mirror first: when Android killed this process
      // mid-turn last time, the events leading up to the kill — and the
      // reattach that (didn't) happen after — are exactly what a poll
      // from the desktop should find waiting. (Re-entrant: a retry of
      // init() after a failed pack start reuses the journal that
      // already bound its port — re-serving it would fail the bind and
      // quietly take the phone's side of the story offline.)
      final j = _events ??= AppEventJournal(dir: modelsDir);
      await j.load();
      if (_eventsPort == 0) {
        _eventsPort = await j.serve(
          preferredPort: kAppLogDefaultPort,
          tokenProvider: () => _bridgePrefs.token,
          flagsProvider: _journalFlags,
        );
      }
      final carried = j.seq > 0
          ? ' — carried over ${j.seq} events across the process gap'
          : '';
      // +260: the tape must name its own author. The field round that
      // this volley's law needed was read on an UNKNOWN build — every
      // 'where is my ear let go line?' question could only be answered
      // by inferring behavior backwards. No new dependency: the build
      // command stamps it (README), and an unstamped build SAYS SO
      // rather than lying with a stale constant.
      final stamp = const String.fromEnvironment('APP_VERSION');
      await j.log(
        'app start: build ${stamp.isEmpty ? 'UNSTAMPED' : stamp}: journal '
        '${_eventsPort > 0 ? 'on :$_eventsPort' : 'BIND '
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
      // The saved voice must be fully on disk (pack present); otherwise
      // fall back to the default (the students), which downloads on
      // first run just like before.
      var voice = voiceById(_prefs.voiceId) ?? voiceById('titl')!;
      if (!await voice.installedIn(modelsDir)) {
        voice = voiceById('titl')!;
      }
      _prefs.voiceId = voice.id;
      // Only the saved style's graph for student rosters — the rest
      // download on pick, like every other pack here. With TTS off the
      // worker starts voice-less on purpose (the pack can be hundreds
      // of MB): setBridgeTts(true) ensures and hot-swaps it later.
      final ttsOn = _bridgePrefs.tts;
      _logDebug(
        'boot: voice pack ${ttsOn ? 'required' : 'skipped (TTS off — '
                  'setBridgeTts(true) ensures it on demand)'}',
      );
      if (ttsOn) {
        await voice.ensureIn(
          modelsDir,
          onProgress: _modelProgress,
          sid: _prefs.sid,
        );
      }
      _worker = await SpeechWorker.start(
        asr.pathsIn(modelsDir),
        tts: ttsOn ? await _spec(voice, sid: _prefs.sid) : null,
        onEvent: _onSpeechEvent,
        endpointSilence: _endpointSilence,
      );
      // +349: the load window closes — any press that landed in it and
      // any release waiting on it may proceed.
      _voiceArrived();
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
        if (!await reattachBackgroundTurn()) {
          _chain.start(gen: _generation, seq: _bridgeTurnSeq);
        }
      }());
    } catch (e) {
      // The downloader kept the partial pack and the ladder ran out
      // (or the asset itself is missing): mark the state so BOTH ways
      // back to a live network — a foreground, a tap on the big button
      // — re-arm a fresh attempt. The resume re-feeds the partial file
      // from the byte the wire stopped at, so a retry never re-pays a
      // finished stretch.
      _modelsFailed = true;
      _logDebug('model init FAILED: $e');
      _fail('Model init failed: $e');
    }
  }

  /// Re-run the cold-start init after a model fetch failed (background
  /// death, dead network). Every resume and every error-phase tap
  /// funnels here, one attempt in flight at a time; the downloader
  /// side (ensurePack) resumes the partial file where the wire
  /// stopped, so repeated attempts cost only the missing tail.
  void _retryModels() {
    if (_modelsRetrying || _disposed) return;
    _modelsRetrying = true;
    unawaited(init().whenComplete(() => _modelsRetrying = false));
  }

  /// +349: the engine is in — the load window closes. A PTT release
  /// waiting on [_voiceReady] proceeds; a conversation segment held
  /// during the load transcribes now.
  void _voiceArrived() {
    if (!_voiceReady.isCompleted) _voiceReady.complete();
    final held = _heldSegment;
    if (held == null) return;
    _heldSegment = null;
    _logDebug('the voice is up — the held segment transcribes now');
    _reply.warmUpRoute();
    unawaited(_startTurn(held));
  }

  void _modelProgress(String label, int done, int total) {
    _activity = Downloading(label, done, total);
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

  /// Switch the speech-recognition model, downloading its pack first if
  /// needed (progress shows in [voiceStatus]). Unlike TTS, the ASR graph
  /// is baked into the worker isolate at start, so the swap is a worker
  /// restart with the same TTS wiring — a brief mic gap while the new
  /// engine loads.
  Future<void> selectAsr(String id) async {
    if (_worker == null || _voiceBusy) return;
    final m = asrModelById(id);
    if (m == null || id == _activeAsrId) return;
    _voiceBusy = true;
    _voiceStatus = 'Setting up ${m.label}…';
    notifyListeners();
    SpeechWorker? fresh;
    try {
      await m.ensureIn(_modelsDir, onProgress: _voiceProgress);
      final ttsOn = _bridgePrefs.tts;
      final voice = voiceById(_prefs.voiceId) ?? voiceById('titl')!;
      fresh = await SpeechWorker.start(
        m.pathsIn(_modelsDir),
        tts: ttsOn ? await _spec(voice, sid: _prefs.sid) : null,
        onEvent: _onSpeechEvent,
        endpointSilence: _endpointSilence,
      );
      _worker!.dispose(); // old engine out only after the new one is ready
      _worker = fresh;
      _ttsNumSpeakers = fresh.ttsNumSpeakers;
      fresh = null;
      _activeAsrId = m.id;
      _asrPrefs.modelId = m.id;
      await saveAsrPrefs(_modelsDir, _asrPrefs);
      _voiceStatus = '';
    } catch (e) {
      _voiceStatus = 'Could not switch speech model: $e';
    } finally {
      fresh?.dispose(); // start failed mid-flight: don't leak the isolate
      _voiceBusy = false;
      notifyListeners();
    }
  }

  /// Free the disk space of a speech model's pack (the one in use stays
  /// protected).
  Future<void> deleteAsr(String id) async {
    final m = asrModelById(id);
    if (m == null || _voiceBusy) return;
    if (id == _activeAsrId) {
      _voiceStatus = 'Switch to another model before deleting this one.';
      notifyListeners();
      return;
    }
    _voiceBusy = true;
    try {
      await m.deleteIn(_modelsDir);
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
    // +240: no 'Making the preview…' line — the pressed button spins
    // for exactly the duration this flag is set, where the eye already
    // is. The status line keeps only what the spinner cannot say:
    // failures.
    _reply.stopDebug();
    _reply
        .stopPlayback(); // a live reply would fight the preview for the speaker
    notifyListeners();
    try {
      _worker!.setPlaying(true); // hard-mode gate while we hear ourselves
      _activity = const Blank();
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
    _activity = const StatusText('Bench listening… release when done.');
    void tick() {
      if (!_benchCapturing) return;
      _activity = StatusText(
        'Bench listening… ${_benchSeconds.toStringAsFixed(1)}s',
      );
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
    final led = _turn; // +302
    final gen = led.generation; // stays ours unless a newer turn supersedes it
    try {
      final text = (await _worker!.transcribe(pcm, 16000)).trim();
      final asrMs = _benchT0!.elapsedMilliseconds;
      if (text.isEmpty) throw StateError("Didn't catch that — try again?");
      _benchNote = 'Synthesising the echo…';
      _activity = const Blank();
      notifyListeners();
      final swTts = Stopwatch()..start();
      _reply.startStream();
      var sawFirstChunk = false;
      final playTask = _reply.runPump(isStale: _stale(led, gen));
      await _reply.speakBlock(
        text,
        alive: () => gen == led.generation,
        onAir: (_) {
          // [_benchFirstAudioMs] itself is stamped in the pipeline's
          // audible hook: the honest figure is when the PLAYER got the
          // bytes, not when we queued them (the temp-wav write in
          // between is real latency the user hears as dead air).
          if (sawFirstChunk) return;
          sawFirstChunk = true;
          _phase = AssistantPhase.speaking;
          _activity = StatusText('Echoing: “$text”');
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
      if (gen == led.generation) _phase = AssistantPhase.idle;
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
    _bridgePrefs.mode = mode.name;
    unawaited(_saveBridgePrefs());
    _hide.resetRelisten();
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

  // ── Background → foreground (see HideResume) ────────────────────────────

  /// App went to background: tear the conversation down (the mic must not
  /// stay open invisibly), but remember that it was live so [resumeConversation]
  /// can bring it back. A bridge (Claude Code) turn is the exception: the
  /// harness keeps answering while hidden, every say lands in the chat log,
  /// and the last one is buffered to be spoken by [resumeConversation].
  /// Any other in-flight reply (local echo TTS mid-synthesis) is abandoned.
  void pauseConversation() {
    // +199: whatever the rest of the pause decides, the chat log's
    // coalesced write is NOT left behind in the dying foreground —
    // flush the newest snapshot before anything else (the OS may stop
    // our timers the moment this returns).
    unawaited(_flushChatPersist());
    if (_backgrounded) {
      // Already hidden. The lifecycle fires hidden AND paused on the way
      // down — and hidden AGAIN on the way up (paused → hidden → inactive
      // → resumed): a second pass here would snapshot the "when you're
      // back" notice as the working line (_pausedWorking), and the resume
      // would restore it — the spinner quoting the pause notice while we
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
    // remaining says keep flowing into the turn loop's backgrounded
    // branch. The HideResume doc carries the cut-paragraph rule (skip,
    // don't replay) and the unheard-say promise.
    final bridgeLive = _bridgeBusy;
    _logDebug(
      'HIDE: busy=$bridgeLive micLive=$live phase=${_phase.name} '
      'queue=${_reply.queuedCount} — '
      '${bridgeLive ? 'stream STAYS attached' : 'audio/mic down'}',
    );
    final marked = _hide.hide(
      bridgeLive: bridgeLive,
      conversationLive: live,
      phase: _phase,
      status: _activity,
    );
    if (marked.droppedMidPlay) {
      _logDebug('hide mid-paragraph: the cut block is skipped, not replayed');
    }
    if (!bridgeLive) _turn.supersede(); // no talking to an empty app
    _shutdownAudio();
    _phase = AssistantPhase.idle;
    _activity = PausedNotice(bridgeLive: bridgeLive, wasLive: live);
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
    // A cold-start download that backgrounding cut (the screen goes
    // off, the socket dies, the ladder sleeps out): coming back IS the
    // retry trigger — ensurePack's resume picks the partial file up at
    // the exact byte the wire stopped at. The rest of this method then
    // runs on the state as it is NOW (worker still null); when the
    // retry lands, init's own tail brings the app ready.
    if (_modelsFailed && _worker == null) _retryModels();
    final plan = _hide.resume();
    _logDebug(
      'RESUME: busy=$_bridgeBusy replay=${plan.unheardReply != null} '
      'spinner=${plan.workingLine != null} relisten=${plan.relisten}',
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
      if (plan.workingLine case final Activity working) {
        _activity = working;
        _phase = AssistantPhase.transcribing;
      }
      // The hide's stopPlayback kills the queue pump at its seam (and
      // mid-play it died on the cleared field's null check — see
      // [ReplyPipeline.runPump]'s captured seam). Without a live pump the
      // survived turn would stream as text-only forever: respawn it, and
      // only when none runs (a pump parked on the wake hook must not get
      // a twin competing for the chunk queue).
      if (!_reply.pumpAlive) _startPump(_generation, led: _turn);
      // Keep the hide's promise ("I'll show every reply and speak the
      // last one when you're back"): says that landed DURING the hide
      // were logged text-only — the backgrounded branch of the turn
      // loop's speak skips synth entirely — and if one of those was the
      // turn's answer, it would otherwise never get a voice.
      // [_speakResumedPending] synthesises it into the queue this pump
      // just revived, under the live turn's generation — no supersede,
      // no orphaned turn.
      if (plan.unheardReply case final String pending when _worker != null) {
        unawaited(_speakResumedPending(pending, _generation, led: _turn));
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
      if (plan.relisten) unawaited(_beginConversation());
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
    if (await reattachBackgroundTurn(
      health: probe,
      replayFirst: plan.unheardReply,
    )) {
      return;
    }
    if (bridgeReattachNeeded(probe) != false) {
      // Unreachable (null): cannot tell "no turn" from "network still
      // waking up around a live turn" — the chain re-probes with backoff
      // instead of dropping it. A true verdict that the reattach itself
      // declined (bench or a fast re-hide raced it) rides the same ladder.
      _chain.start(gen: _generation, seq: _bridgeTurnSeq);
    }
    if (plan.unheardReply case final String pending when _worker != null) {
      unawaited(_replayPendingReply(pending, thenListen: plan.relisten));
      return;
    }
    if (!plan.relisten) return;
    unawaited(_beginConversation());
  }

  /// Arm the reattach chain (the [ReattachChain] the constructor wired):
  /// probe /health NOW, and where the answer cannot be told (bridge
  /// unreachable — the waking network is usually still re-building its
  /// tunnel), re-probe up the [kReattachDelays] ladder, ~63 s in all.
  /// [retire] marks a chain born from a ZOMBIE stream: a definite
  /// "nothing open, nothing unheard" verdict (or a spent ladder) must
  /// also retire the spinner the dead view was still pretending to watch.
  /// [firstProbe] delays the first probe — used when the chain is born
  /// from a REATTACHED stream dying again, so a flaky link pays backoff
  /// between attach attempts instead of request-looping at RTT pace.
  /// Test seam: the DETACHED-UNHEARD state directly — badge lit, verdict
  /// settled, no steal-back armed. Since +146 a real press reaches this
  /// state only when the immediate probe fails to take the ear back;
  /// the press itself is pinned by the banner-law tests instead of every
  /// receipt/pin test re-enacting a finger.
  @visibleForTesting
  void debugDetachUnheard() {
    _turn.supersede();
    _turn.markBackgrounded();
    _turn.detach(TurnTrigger.zombieWire);
  }

  void _armReattach({
    required int gen,
    required int seq,
    bool retire = false,
    bool resetStep = true,
    Duration? firstProbe,
    SessionChannel? via,
  }) => (via ?? _chan).chain.start(
    gen: gen,
    seq: seq,
    retire: retire,
    resetStep: resetStep,
    firstProbe: firstProbe,
  );

  void _chainCancel() => _chain.cancel();

  /// The quiet-wire watchdog verdict ([WireLease] fired): a listening
  /// socket that has delivered not one byte — no events, no 15 s pings —
  /// for a full quiet window while we believe we're attached is a ZOMBIE:
  /// the route died quietly (Wi-Fi handoff, deep sleep, tailnet re-key)
  /// and no FIN or RST will ever arrive to tell us. Stop reading it, and
  /// let the reattach chain take a fresh view before the harness relays
  /// more of the turn into the void.
  void _wireQuietFired(Duration quiet) {
    _logDebug('bridge wire quiet ${quiet.inSeconds}s: presumed dead socket');
    _turn.detach(
      TurnTrigger.zombieWire,
    ); // give up on the zombie view (parked loop retires
    // exactly as any abandoned turn's does — see its docs)
    _armReattach(gen: _generation, seq: _bridgeTurnSeq, retire: true);
    _logDebug(
      'zombie hop: /attach will STEAL the bridge view back; spinner '
      'retires if the probe says nothing is open any more',
    );
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
    SessionChannel? via,
  }) async {
    // +298: the ladder belongs to the conversation whose view died;
    // every claim, ticker reset and park lands on THAT channel, no
    // matter which tab the eye looks through when the rung fires.
    var chan = via ?? _chan;
    final gateway = _gateway;
    if (gateway == null || _worker == null) return false;
    if (chan.turn.busy ||
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
    // +290 (Tim's field: 'background the app, foreground it — no
    // response until I set a hello'): the probe ALREADY carries the
    // conversation's name, and the old code printed its flags and
    // threw the name away. The tape: the answer's paragraphs came
    // back on the replay stamped for their own conversation, but the
    // pointer still named nobody ('seat=unnamed'), so the +274 stamp
    // verdict could only read the phone's OWN answer as foreign —
    // not taken, not filed, nothing in the thread. Wear the name the
    // /health law already wears everywhere else; the claim line
    // below then answers 'whose backlog are we draining' with the
    // truth, and the drain files the answer where it lives.
    final probeSid = probe?['sessionId'];
    if (probeSid is String &&
        probeSid.isNotEmpty &&
        probeSid != chan.sessionId) {
      if (chan.sessionId == null) {
        // +290: the seat that FORGOT its name wears the one the probe
        // carries — the law, now re-keying bookkeeping instead of a
        // field.
        _name(chan, probeSid);
      } else {
        // +298: the /health described ANOTHER conversation — the
        // backlog it promises is THAT thread's, and the drain moves
        // to its channel. Claiming on the caller's tab would light
        // the wrong box: the +255 law in the map's new shape.
        final known = _channelIfKnown(probeSid); // +313: the report
        // speaks for a conversation nobody here keeps — nothing to
        // reattach to, and nothing to resurrect.
        if (known == null) return false;
        chan = known;
      }
      notifyListeners();
    }
    if (chan.turn.busy) return false; // that view is already heard —
    // nothing to steal (+257's inertness, now checked against the
    // conversation the report actually speaks for).
    if (bridgeReattachNeeded(probe) != true) return false;
    _logDebug(
      'REATTACH start: ${_transport.noteHealth(probe)} — replaying backlog',
    );
    final claim = _turn.beginHeardTurn();
    final gen = claim.gen;
    final mySeq = claim.seq; // claim the busy flag for this turn
    _turn.becomeHeard(); // heard again from here on
    // +168: was this ATTACH a MAIL FETCH? The probe that justified it
    // knows: turnOpen=false means no turn is generating — every frame
    // the replay carries is history the ear already owns or a receipt,
    // and the view dies on the backlog's own farewell. The busy slot
    // and the Stop chip stay honest (the replay can be cut), but the
    // working box stays dark: reading mail is not the agent working
    // (field report on +167: 'spinning box flashes by before showing
    // the last reply' — the 174 ms of an attach that surfaced the
    // steered follow-on's already-generated words). When turnOpen is
    // true the attach rejoins a GENERATING turn — real work, real
    // spin.
    _drainReading = probe!['turnOpen'] != true; // probe is non-null
    // here: an unreachable snapshot answers need=null and the guard
    // above returned.
    // +255: say WHOSE turn the probe says is open — a TRUE here may
    // be a BACKGROUNDED conversation's work, not the seated tab's,
    // and the box gate (turnHomeHere) is what stands between that
    // stranger and this tab's face. The row's journal names the pair
    // so a field tape answers 'whose spin was this' without a guess.
    _logDebug(
      'attach claim: turnOpen=${probe['turnOpen'] == true} '
      'drainReading=${chan.drainReading} '
      'home=${chan.sessionId ?? 'unnamed'} '
      'seat=${_sessionId ?? 'unnamed'}',
    );
    _error = '';
    chan.ticker.resetForTurn();
    _phase = AssistantPhase.transcribing;
    _activity = StatusText(
      _drainReading
          ? 'Replaying what the wire owed…' // +168: mail fetch — no
          // turn is generating; the caption says what it is instead of
          // borrowing the live-turn wording.
          : 'Reattached — working…',
    );
    notifyListeners();
    _reply.warmUpRoute();
    // A fresh bubble continues the story: the pre-drop blocks live in the
    // old one (the chat log is the history, not this loop's state).
    final turn = _chat.beginTurn();
    _reply.stopPlayback(); // cut any current audio, like the voice preview does
    _reply.startStream();
    _startPump(gen, led: chan.turn);
    unawaited(() async {
      // The caller's unheard reply leads the backlog (see [replayFirst]):
      // synthesised through THIS reattach's gen into the queue the pump
      // above drains — awaited before the view opens, so exactly one
      // synth ever races the worker and the resumed block's audio comes
      // out ahead of the replayed says, story order intact. A supersede
      // during the synth (new /talk took the ear) drops the audio and
      // the whole attach with it.
      if (replayFirst != null && replayFirst.trim().isNotEmpty) {
        await _speakResumedPending(replayFirst, gen, led: chan.turn);
        if (gen != chan.turn.generation) return; // superseded mid-replay
      }
      await BridgeTurn(
        origin: BridgeTurnOrigin.attach,
        env: _envFor(chan),
        turn: chan.turn,
        chat: _chat,
        ticker: chan.ticker,
        narr: _narr,
        hops: _hops,
        reply: _reply,
        lease: _lease,
        transport: _transport,
        scheduler: _scheduler,
        gen: gen,
        mySeq: mySeq,
        turnBubble: turn,
      ).run(gateway.attach(onActivity: _lease.markAlive));
    }());
    return true;
  }

  bool get _backgrounded => _hide.hidden;

  /// Speak a bridge reply that landed while the app was hidden. The text is
  /// already in the chat log (buffered there by the turn loop's hidden
  /// branch), so this only feeds the speaker — no new bubble, no double
  /// text. Speak the reply a hide left unheard — the app came back and the
  /// stream is (or is about to be) still owned by a live event loop, so
  /// unlike [_replayPendingReply] this bumps NO generation: a bump would
  /// supersede that loop and hand a perfectly healthy turn to the bridge
  /// as a background turn, which is the opposite of coming back. The
  /// chunks ride the live turn's own queue (the pump at
  /// [resumeConversation]'s respawn covers it), and the text does NOT
  /// re-enter the log: the block already sits there from the hidden
  /// branch of the loop's speak — this is the audio the room was promised.
  /// [gen] is the caller's turn generation: a superseded replay drops
  /// its chunks exactly like a superseded speak would.
  /// +302: takes its ISSUING LEDGER with its generation — a replay
  /// for a conversation the eye left behind answers to THAT
  /// conversation's supersede, not to whatever the seat reads.
  Future<void> _speakResumedPending(
    String text,
    int gen, {
    required TurnCoordinator led,
  }) async {
    if (_worker == null) return;
    try {
      await _reply.speakBlock(
        text,
        alive: () => gen == led.generation,
        onAir: (sinceText) {
          _phase = AssistantPhase.speaking; // first audible chunk flips
          // the status, like the loop's speak
          _hops.tts(); // reply→audio hop crossed
          _noteFirstWordLatency(sinceText);
          _hide.noteReplyText(text); // the re-hide seed sees this replay as
          // the last reply (re-playing a block hides audio again =
          // pauseConversation's own restart-the-block rule)
          _chat.touch();
        },
      );
      if (gen != led.generation) {
        return; // superseded mid-replay: chunks dropped
      }
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
    if (gen == led.generation && _reply.queuedCount > 0 && !_reply.pumpAlive) {
      _startPump(gen, led: led);
    }
  }

  Future<void> _replayPendingReply(
    String text, {
    required bool thenListen,
  }) async {
    final worker = _worker;
    if (worker == null) return;
    final led = _turn; // +302
    final gen = led.supersede(); // supersede whatever half-state survived
    _reply.stopPlayback();
    _error = '';
    _phase = AssistantPhase.transcribing;
    _activity = const StatusText('Picking up where the bridge left off…');
    notifyListeners();
    _reply.warmUpRoute(); // hold the output route through the synth wait
    _reply.startStream();
    _startPump(gen, led: led);
    // The buffered reply's text is old (it arrived before the app went
    // away), so received-to-ear isn't meaningful here; the first-chunk
    // elapsed measures the wait the user feels NOW.
    _ttsSeconds = 0;
    _ttsFirstTimed = false;
    try {
      await _reply.speakBlock(
        text,
        alive: () => gen == led.generation,
        onAir: (sinceText) {
          _phase = AssistantPhase.speaking;
          _hops.tts(); // reply→audio hop crossed
          _noteFirstWordLatency(sinceText);
          notifyListeners();
        },
      );
      if (gen != led.generation) return; // cut off mid-replay: user moved on
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
          case AssistantPhase.error:
            if (_modelsFailed && _worker == null) {
              // The tap that retries a download backgrounding killed
              // (the status line says as much): the mic has no models
              // to feed yet, so this press is the retry, not a listen.
              _retryModels();
              return;
            }
            await _beginConversation();
          case AssistantPhase.idle:
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
    if (_mode != InteractionMode.pushToTalk) return;
    if (_worker == null) {
      // +349: the press landed in the load window — it is REAL. It
      // registers (so the release is never a stray), the mic opens and
      // captures, and the release WAITS for the voice instead of the
      // recording dying. The barge-in branch below stays gated: the
      // supersede machinery belongs to a loaded engine's world, and the
      // load window's own state is idle by construction.
      _logDebug(
        'ptt DOWN during load: the press registers, the mic opens — '
        'the release waits for the voice',
      );
      final firstPointer = _ptt.down(at);
      if (!firstPointer) return;
      _pttMaxTimer?.cancel();
      _pttMaxTimer = _scheduler.after(const Duration(minutes: 2), () {
        if (_ptt.pointers > 0) pttCancel();
      });
      unawaited(_startListening());
      return;
    }
    final firstPointer = _ptt.down(at);
    if (_phase == AssistantPhase.transcribing ||
        _phase == AssistantPhase.speaking ||
        _bridgeBusy) {
      // Press over a working agent (bridge turn or local TTS reply):
      // abandon the in-flight turn (so the synthesiser does not queue
      // more audio), cut anything audible, then let this very hold open
      // the mic. For a BRIDGE turn, abandon = DETACH: the harness keeps
      // working backgrounded (an open tool call finishes its work!),
      // and the release gesture decides what the new prompt does: slide
      // up cuts even the thinking, a plain release queues politely and
      // only backgrounds an open tool (cutTool), and slide right throws
      // the recording away as if nothing happened. No trace is stamped
      // at press for exactly that reason (+132) — the verdict belongs
      // to the release, and _pttCutTrace holds the bubble's paperwork
      // until then. Same supersede semantics as a
      // spoken barge-in in conversation mode — here, per spec, PTT's.
      // +297 (structural via +298): only a turn of THIS conversation
      // can be waited behind; the stranger's busy flag cannot arm the
      // queue flavour — it lives in another channel.
      _ptt.bridgeHold = _bridgeBusy;
      // The press detaches (the mic must open now) but the banner
      // HOLDS: the release gesture decides whether this turn is
      // genuinely out of the ear (+146 — a banner that blinked on
      // every press-down and died on release told the user the press
      // itself had backgrounded their turn). The spinner law and /stop
      // bookkeeping still see the raw badge; only the row waits.
      if (_ptt.bridgeHold) _turn.markBackgrounded(verdictPending: true);
      _turn.supersede();
      if (_ptt.bridgeHold) {
        _logDebug(
          'ptt DOWN over a live turn: detached it — the open tool '
          'keeps working (banner held for the release verdict), the '
          'gesture routes the prompt',
        );
      }
      _reply.stopDebug();
      // +234 (spec): a press may drop everything in flight or arriving
      // before the release — but it must not do it SILENTLY. The field
      // report 'one chunk skips TTS completely' was this cut eating a
      // reply's last sentence between the drain's park (13 ms earlier)
      // and the press, and the tape looked like a TTS failure because
      // nothing said the press was the cause. Count what dies (the
      // un-played queue, the on-air chunk, the parked drain verdict —
      // a drained replay would only re-file it by age anyway), say so
      // in the journal and on the line, THEN cut.
      final dropped = _reply.queuedCount + (_reply.playing ? 1 : 0);
      if (dropped > 0 || _drainAfterSpeech != null) {
        _logDebug(
          'ptt DOWN: barge-in drops the unheard tail — '
          '$dropped inaudible chunk(s), '
          '${_drainAfterSpeech == null ? 'no' : 'a'} parked drain; '
          'in flight or arriving before release is expendable by spec',
        );
        // The caption belongs to the claim (+171): while a tool or a
        // backgrounded turn still owns the line, the journal carries
        // the trace and the row keeps naming the work. The status
        // speaks only when the dropped tail WAS the whole story.
        if (!(_bridgeBusy || _turn.backgrounded || _bgWork.isNotEmpty)) {
          _activity = const StatusText(
            'Cut the reply — its unheard tail was dropped.',
          );
        }
        // The press pays the parked drain by FORGIVING it: the text is
        // already in the chat (frames paint on arrival), the spec says
        // the audio is the press's to take, and leaving the verdict
        // standing would keep the brake lit over a debt the user just
        // cancelled. The next turn's teardown re-arms its own verdict.
        _drainAfterSpeech = null;
        notifyListeners();
      }
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
        _armReattach(
          gen: _generation,
          seq: _bridgeTurnSeq,
          retire: true,
          firstProbe: Duration.zero,
        );
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
        _activity = const StatusText(
          "That press didn't land — nothing was recorded. Hold again.",
        );
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
      unawaited(_stopAndRespond(discard: true, driftPx: r.driftPx));
    } else {
      unawaited(_stopAndRespond(interrupt: r.up, driftPx: r.driftPx));
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
    _activity = const IdleHint();
    notifyListeners();
  }

  void _fail(String message) {
    _awaitPickup = false; // a send that died is not 'parked'
    _phase = AssistantPhase.error;
    _error = message;
    _activity = const FailedHint();
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
    _noteAudioLevel(c); // the ripple meter rides every raw chunk too
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
      _activity = const ListeningHint();
      notifyListeners();
    }
  }

  /// The bench's release→first-audio figure: bytes enter the PLAYER NOW
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
      'Replaying my last reply, raw TTS out…',
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
    _activity = StatusText(playingStatus);
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
    _activity = _mode == InteractionMode.conversation
        ? const ListeningHint()
        : const StatusText('Ready. Hold the button to speak.');
    _worker?.resetVad();
    notifyListeners();
  }

  // ── Conversation mode ────────────────────────────────────────────────────

  Future<void> _beginConversation() async {
    _reply.stopDebug();
    _resetMicLevel(); // a new listen starts from still water
    try {
      await _mic.open();
      _phase = AssistantPhase.listening;
      _error = '';
      // +148: a press over LIVE work leaves the spinner box exactly as
      // it is — the mic's own surface (orb, level) says 'recording';
      // painting 'Listening…' over the running tool's line is the
      // stomp the queue flow keeps inheriting. Idle presses keep the
      // hint: nothing is running, the box has no work to name.
      if (!(bridgeBusy || harnessBackgrounded)) {
        _activity = const ListeningHint();
      }
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
    _activity = StatusText(message);
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
    _activity = StatusText(message);
    notifyListeners();
  }

  void _onSpeechEvent(SpeechEvent event) {
    if (event.note != null) {
      debugPrint('[worker] ${event.note}'); // gate telemetry (level/floor)
      if (event.note!.startsWith('bargein: ')) {
        _logDebug('INTERRUPT ${event.note}');
      }
      // +236: a chunked long-hold decode announcing another finished
      // piece. Cumulative text rides the same note channel as the gate
      // telemetry it predates.
      if (event.note!.startsWith('partial:')) {
        _onTranscriptPartial(event.note!.substring(8));
      }
      // +344: the student's graph feed, journalled — 'what did the
      // engine read' stops being a rebuild question.
      if (event.note!.startsWith('titl fed: ')) {
        _logDebug(event.note!);
      }
      // +350: the pocket split tape — our Generate boundaries
      // ('pocket split:') and each call's fed text with the C++ pass's
      // own seams marked ' | ' ('pocket fed:'), so an unnatural pause
      // names its author instead of being argued from ears.
      if (event.note!.startsWith('pocket split: ') ||
          event.note!.startsWith('pocket fed: ')) {
        _logDebug(event.note!);
      }
      return;
    }
    if (_reply.debugPlaying) {
      return; // don't let the replay re-enter the pipeline
    }
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
        _activity = const Interrupted();
      } else if (_phase == AssistantPhase.transcribing) {
        _userSpeaking = true;
        _turn.supersede(); // user resumed; drop the half-baked response
        _turn.detach(
          TurnTrigger.speechResumed,
        ); // same detach semantics as above
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
      // +349: the load window covers conversation mode too — a segment
      // with no engine waits at the release path's twin, here: the
      // transcribe waits for the voice instead of crashing on `!`.
      if (_worker == null) {
        _logDebug(
          'segment during load: held for the voice '
          '(${event.segment!.length / 16000}s of speech)',
        );
        _heldSegment = event.segment;
        return;
      }
      _reply.warmUpRoute(); // connect the output route while we transcribe
      unawaited(_startTurn(event.segment!));
      return;
    }
    // Speech stopped but no segment followed (too quiet/short to count as a
    // real try): nudge — unless that utterance was likely our own echo.
    _userSpeaking = false;
    if (!_segGotAudio && !_segEchoRisk && _phase == AssistantPhase.listening) {
      _activity = const StatusText('I heard a bit — say a little more?');
      notifyListeners();
    }
    _segEchoRisk = false;
  }

  // ── Turn processing (shared by both modes) ─────────────────────────────

  Future<void> _startTurn(
    Float32List samples, {
    bool interrupt = true,
    bool cutTool = false,
    bool parkBehind = false,
  }) async {
    final led = _turn; // +302
    final gen = led.supersede(); // any newer turn supersedes this one
    _ptt.bridgeHold = false; // the hold is over: the turn owns the choice now
    _phase = AssistantPhase.transcribing;
    if (!parkBehind) {
      // +148: the QUEUE flavour keeps the box: 'Thinking…' would be a
      // lie about the parked prompt — it is not thinking yet, it is
      // WAITING, and the truthful line is the one already there.
      _activity = const StatusText('Thinking…');
    }
    notifyListeners();
    try {
      final swAsr = Stopwatch()..start();
      // What ASR actually heard — kept for the debug replay button.
      _asrAudio = samples;
      _asrAudioRate = 16000;
      final text = (await _worker!.transcribe(samples, 16000)).trim();
      swAsr.stop();
      if (gen != led.generation) {
        _withdrawTranscribe('superseded during ASR');
        _logDebug(
          'message SWALLOWED: superseded during ASR (gen $gen → ${led.generation})'
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
        _withdrawTranscribe('empty transcript');
        _activity = const StatusText("Didn't catch that — try again?");
        _phase = _mode == InteractionMode.pushToTalk
            ? AssistantPhase.idle
            : AssistantPhase.listening;
        notifyListeners();
        return;
      }
      if (_segEchoRisk && _looksLikeEcho(text, _lastSpoken)) {
        _segEchoRisk = false;
        _withdrawTranscribe('own voice');
        _logDebug('asr result rejected as TTS echo — nothing sent');
        _activity = const StatusText("That was my own voice — I'm listening.");
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
      // +188: a release that opened its bubble at the button-up moment
      // FILLS that bubble (pulse gives way to the words, same card,
      // same place); every other route (conversation VAD, typed, chip)
      // keeps adding the bubble here as it always did.
      // +297: same owner law as the typed path's park (structural
      // since +298: `_bridgeBusy` is the seat's own flag).
      final queuedFlavour = !interrupt && (parkBehind || _bridgeBusy);
      final bubble = _transcribeBubble;
      _transcribeBubble = null;
      if (bubble != null) {
        _chat.fillUser(bubble, text, queued: queuedFlavour);
      } else {
        _chat.addUser(
          text,
          // _bridgeBusy alone lies here: the DOWN-time detach cleared
          // it while the bridge turn lives on (badge =
          // _harnessBackgrounded) — behind THAT is what a polite
          // release queues.
          // +149: the press's detach zeroed _bridgeBusy and the queue
          // release retired the badge BEFORE this re-add — reading
          // only those two made every voice queue silently grey
          // (journal 22:50: queued=0). The release already decided:
          // parkBehind.
          queued: queuedFlavour,
        );
      }

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
        _turn.detach(TurnTrigger.newUtterance, polite: !interrupt);
        _logDebug(
          // +321: the line used to name /talk whether or not that was
          // the route — triage read it as proof the press rode the
          // seat when it was named all along. The route's own truth
          // is the sid (or its absence) and the bridge's journal.
          '→ harness: bubble added, prompt POSTed '
          '${_sessionId == null ? '(unnamed — the seat answers)' : '(named)'} '
          '(interrupt=$interrupt cutTool=$cutTool)',
        );
        unawaited(
          runQuickCommand(
            text,
            interrupt: interrupt,
            cutTool: cutTool,
            parkBehind: parkBehind,
          ),
        );
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
              alive: () => gen == led.generation,
              drop: () => _hide.shouldDrop(text), // hide cut this
              // reply mid-play: skip the rest whole, no replay on return
              onAir: (sinceText) {
                _hide.blockAired(); // this block's air outranks the mark
                _phase = AssistantPhase.speaking;
                _hops.tts(); // first audio of the reply (see strip)
                // _ttsSeconds holds the FIRST-WORD latency —
                // received-to-ear — stamped on the first chunk, where the
                // pause the user actually feels lives.
                _noteFirstWordLatency(sinceText);
                notifyListeners();
              },
            )
            .then((_) {
              if (gen != led.generation) return;
              _reply.closeStream();
            })
            .catchError((Object e) {
              _reply.closeStream();
              if (gen == led.generation) _fail('Round trip failed: $e');
            }),
      );
      await _reply.runPump(isStale: _stale(led, gen));
    } catch (e) {
      // +188: a transcribe that threw never fills its bubble — take
      // the pulsing shell back rather than leave it beating on screen.
      _withdrawTranscribe('round trip failed');
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
        // +171: 'the reply ended' is only the whole truth when the TURN
        // ended with it. A polite park behind a running tool (the agent
        // routing /compact through its own wire) keeps the heard turn
        // open while the speaker falls silent — idling the phase there
        // left the box LIT (the claim was honest) but captioned
        // 'Ready' for two minutes (the caption lied): the field tape
        // at 12:30. The caption belongs to the claim, not to the
        // speaker; any phase other than idle keeps the verdict's own
        // wording — 'a tool call is running…' — on the row.
        if (!(_bridgeBusy || _turn.backgrounded || _bgWork.isNotEmpty)) {
          _idleReady();
        }
      } else {
        _phase = AssistantPhase.listening;
        _activity = const ListeningHint();
        notifyListeners();
      }
    }
    // +124: the speaker fell silent on its own terms; every channel's
    // parked backlog verdict gets its second look, consumed on the
    // conversation that parked it (+298 — a barge-in's stop is not a
    // natural end, so a parked verdict that dies this way is simply
    // re-formed by the next turn's teardown — self-healing).
    for (final c in _channels.values.toList()) {
      final parked = c.drainAfterSpeech;
      if (parked == null) continue;
      c.drainAfterSpeech = null;
      unawaited(_drainStrandedBacklog(parked.gen, parked.mySeq, via: c));
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
    _resetMicLevel(); // no stream, no level — never a frozen wave
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
    // +349: the worker clause is gone — the mic opens in the load
    // window too (capture is platform-side; only denoise+ASR needs the
    // engine, and that waits at the release now).
    if (_phase == AssistantPhase.listening) return;
    _reply.stopDebug();
    _resetMicLevel();
    try {
      _reply.stopPlayback();
      await _mic.open();
      _phase = AssistantPhase.listening;
      _error = '';
      // +148: a press over LIVE work leaves the spinner box exactly as
      // it is — the mic's own surface (orb, level) says 'recording';
      // painting 'Listening…' over the running tool's line is the
      // stomp the queue flow keeps inheriting. Idle presses keep the
      // hint: nothing is running, the box has no work to name.
      if (!(bridgeBusy || harnessBackgrounded)) {
        _activity = const ListeningHint();
      }
      notifyListeners();
    } catch (e) {
      _fail('$e');
    }
  }

  Future<void> _stopAndRespond({
    bool interrupt = false,
    bool discard = false,
    double driftPx = double.infinity,
  }) async {
    if (_phase != AssistantPhase.listening) {
      // Another silent sinkhole for a vanishing message: the mic was not
      // actually open by the time the release arrived (press raced a
      // mode switch, the watchdog closed the stream, a duplicate call).
      // The hold did END though: a trace deferred at press resolves as
      // nothing-was-cut — the detached turn keeps working unheard.
      if (_ptt.bridgeHold) {
        _dropPttCutTrace();
        _turn.resolveBackgroundVerdict();
      }
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
    if (bridgeHold && !discard) {
      // +148: the release itself owns this turn's fate from here on —
      // a queue's /talk re-ears the tail in its own successor view, a
      // no-words hold re-arms below, a tap-stop kills the work. None
      // of them may be raced by the deferred steal-back probe climbing
      // the ladder through an ASR-gap await and painting 'Reattached
      // — working…' over the box the release is supposed to leave
      // untouched. (Discard keeps the probe: the badge stays honest —
      // unheard — until a drain clears it.)
      _chainCancel();
    }
    _reply.stopDebug();
    await _mic.close();
    _resetMicLevel(); // the hold is over; the ripples came from this mic
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
      _activity = StatusText(
        bridgeHold
            ? 'Dismissed — the harness keeps working in the background.'
            : 'Dismissed — nothing sent.',
      );
      // Nothing was cut and nothing was sent: the deferred trace dies
      // with the recording (+132's 'as if nothing happened'), and the
      // banner resolves WITH the badge still lit — there is no
      // successor view, the turn really is out of the ear now.
      _dropPttCutTrace();
      _turn.resolveBackgroundVerdict();
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
        _turn.resolveBackgroundVerdict();
        // The hold opened over a harness turn but nothing speakable came
        // out. A MOTIONLESS quick tap is the hard stop the button
        // always was mid-turn: /stop cuts the (already detached, still
        // running) turn, and the trace the press deferred finally
        // lands (+110). A release that drifted at all was a mind
        // half-changed, not a tap — cancelling is not stopping (+132:
        // the gentle right swipe that killed the tool call). A longer
        // hold with no words also leaves the background work ALONE —
        // it finishes on its own and the next release queues behind it.
        if (interrupt ||
            (heldMs < _ptt.tapStopMs && driftPx < _ptt.tapSlopPx)) {
          unawaited(_gateway?.stop());
          _turn.retireBadge();
          _applyPttCutTrace();
          _activity = const StatusText('Heard nothing — stopped the harness.');
        } else {
          _keepPttCutTrace(); // +148: still running — the box stays
          // No /talk successor exists to re-ear: hand the drain probe
          // back (the release cancelled the press's one).
          _armReattach(gen: _generation, seq: _bridgeTurnSeq, retire: true);
          _activity = const StatusText(
            'Heard nothing — the harness keeps working in the background.',
          );
        }
      } else {
        _activity = const StatusText(
          'Heard nothing. Hold the button and speak.',
        );
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
    // +188: the bubble arrives NOW — the release is news, the words
    // are still being computed. Inside it, the transcribe pulse; the
    // fill replaces the pulse with the transcript a heartbeat later.
    _withdrawTranscribe('superseded at new release');
    _transcribeBubble = _chat.addUserTranscribing();
    // Offline cleanup (high-pass + frame noise gate) using the live noise
    // floor — safe here: the user already finished speaking, so gating can
    // never clip utterance onsets, only quiet fill between words.
    final led = _turn; // +302
    final gen = led.generation; // a press during cleanup interrupts this turn
    _phase = AssistantPhase.transcribing;
    if (!(bridgeHold && !interrupt)) {
      // +148: the QUEUE flavour leaves the box alone — even the
      // denoise caption would paint over the running tool's line, and
      // 'cleaning up the recording' is news about the FINGER, not
      // about the work the user is queueing around.
      _activity = const StatusText('Cleaning up the recording…');
    }
    notifyListeners();
    // +349: the hold that landed in the load window — the release
    // waits (bounded) for the voice instead of the recording dying.
    // The wait rides the transcribe bubble the release already opened.
    if (_worker == null) {
      _logDebug(
        'release during load: the transcript waits for the voice '
        '(${(pcm.length / 16000).toStringAsFixed(1)}s held)',
      );
      _activity = const StatusText('Waiting for the voice to finish loading…');
      notifyListeners();
      try {
        await _voiceReady.future.timeout(const Duration(seconds: 30));
        _logDebug('the voice is up — the held recording transcribes now');
      } catch (_) {
        _logDebug(
          'the voice never finished loading — the recording died '
          'untranscribed',
        );
        _withdrawTranscribe('the voice never loaded');
        _activity = const StatusText('The voice did not load — press again.');
        if (_ptt.pointers == 0) _idleReady();
        return;
      }
    }
    Float32List cleaned = pcm;
    try {
      cleaned = await _worker!.denoise(pcm);
    } catch (e) {
      debugPrint('denoise failed, using raw audio: $e');
    }
    if (gen != led.generation) {
      _withdrawTranscribe('superseded during cleanup');
      // The button was pressed again mid-cleanup: that hold owns the mic
      // (and the reply is abandoned); don't resurrect this turn.
      _logDebug(
        'message SWALLOWED: superseded during cleanup (gen $gen → '
        '${led.generation}, pointers=${_ptt.pointers}) — the recording died untranscribed',
      );
      if (_ptt.pointers == 0) _idleReady();
      return;
    }
    // Words made it through: the release gesture's meaning is final.
    // A plain release over the detached turn POLITELY QUEUES (interrupt
    // false — slide-right never reaches here, it discarded the
    // recording): the turn (and any tool inside it) settles on its own
    // and this prompt goes next. +144 retired the release's cutTool:
    // the CLI cannot background a running tool when interrupted — it
    // kills it — so 'queue politely but free the agent from the build'
    // was really 'queue and murder the build'; waiting IS the promise
    // now. Slide-up (or any prompt with no turn behind it) keeps the
    // established cutting flavour — and only a cut owes the abandoned
    // bubble its +110 trace.
    final willCut = interrupt || !bridgeHold;
    if (willCut) {
      _applyPttCutTrace();
      // The cut's banner comes from the WIRE (the tagged disposition
      // and the receipt behind it), not from the press's badge.
      _turn.resolveBackgroundVerdict();
    } else {
      _keepPttCutTrace();
      // +145: the press detached the heard turn and lit the badge —
      // honest while the mic owned the moment. A QUEUE release hands
      // the ear straight back: the successor's pump rides the ring
      // and hears the settling turn's tail (armored, deduped), so
      // 'working unheard' has expired — the greyed message and the
      // spinner carry the wait from here. (Discard deliberately keeps
      // the badge: no successor view exists, the work really is out of
      // earshot until a drain brings it back.)
      _turn.resolveBackgroundVerdict();
      _turn.retireBadge();
    }
    await _startTurn(
      cleaned,
      interrupt: willCut,
      // The queue flavour parks: no pin may ride (the press detached
      // first), so the placeholder-skipping law needs this word.
      parkBehind: bridgeHold && !willCut,
    );
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
    unawaited(_flushChatPersist()); // +199: no pending snapshot dies
    _hops.dispose(); // with the timer
    _lease.cancel();
    for (final c in _channels.values) {
      c.dispose(); // +298: every conversation's ladder, not just the seat's
    }
    _bgProbe?.cancel();
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
