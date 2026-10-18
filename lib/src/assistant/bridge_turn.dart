/// One bridge turn's event loop, as an object.
///
/// Both harness loops the orchestrator used to run inline (the /talk
/// loop in runQuickCommand, the /attach replay loop in
/// reattachBackgroundTurn) are the SAME conversation with the wire:
/// speak each say the moment it lands (ledger first, +109/+114/+116),
/// label each tool step, honour the queue receipts, and tear down
/// without ever stomping a successor turn's slots. They were a
/// 350-line copy-paste pair with SUBTLY divergent bug fixes — the exact
/// shape [BridgeTurnPump] exists to prevent, regrown one level up. This
/// class is the shared loop; the real differences are declared once, as
/// [BridgeTurnOrigin]:
///
///  * [BridgeTurnOrigin.talk] — the heard live turn: queue-pin pickup on
///    any frame of its own view, narration with the 15 s heartbeat
///    pulse, hidden says buffered for the resume promise, a stranded
///    backlog drain at teardown, and a permanent note for a cut that
///    never spoke (+110).
///  * [BridgeTurnOrigin.control] — a caller-supplied stream (/new's
///    reset): like talk, but its teardown may not call the turn an
///    unowned death — there was never a /talk connection to rejoin
///    (+106's /new carve-out).
///  * [BridgeTurnOrigin.attach] — a reattach replay: beforeEvent may
///    NOT dissolve the pin (backlog frames are the OLD turn's; only the
///    explicit 'started' marker proves pickup, +81), archaeology rules
///    apply (a >2-minute-old paragraph is history, not news — logged
///    silently, never re-voiced), nothing narrates, and a dying view
///    re-arms the chain paced instead of fresh.
///
/// The assistant owns the machinery the loop pulls (player, lease,
/// gateway) and the UI truth it updates, through [BridgeTurnEnv] — so a
/// queue/detach/receipt rule can be tested by driving a BridgeTurn with
/// fakes directly, without a whole orchestrator, mic, or device.
library;

import 'dart:async';

import '../bridge/bridge_event.dart';
import '../bridge/gateway.dart';
import '../bridge/text_rules.dart';
import '../bridge/transport.dart';
import '../bridge/turn_pump.dart';
import '../bridge/wire_lease.dart';
import '../chat/chat_log.dart';
import '../common/sinks.dart';
import 'activity.dart';
import 'chat_store.dart';
import 'hop_tracker.dart';
import 'narration_gate.dart';
import 'reply_pipeline.dart';
import 'state.dart';
import 'token_ticker.dart';
import 'turn_session.dart';

/// Which wire this turn rode — the ONLY axis the two old loops truly
/// differed on (see the library docs).
enum BridgeTurnOrigin { talk, control, attach }

/// The assistant-side surface a turn loop pulls: the UI truth (status,
/// phase, error, context), the hide/resume bookkeeping, and the
/// teardown follow-ups (reattach chain, backlog drain). Function
/// tear-offs in production; plain lambdas and recorder lists in tests.
final class BridgeTurnEnv {
  const BridgeTurnEnv({
    required this.mode,
    required this.backgrounded,
    required this.narrateOn,
    required this.speakingNow,
    required this.generation,
    required this.turnSeq,
    required this.busy,
    required this.badgeLit,
    required this.hasError,
    required this.mergeContext,
    required this.setStatus,
    required this.setPhase,
    required this.markSpeaking,
    required this.idleReady,
    required this.fail,
    required this.noteHarnessError,
    required this.noteReplyText,
    required this.noteUnheardSay,
    required this.noteSpoken,
    required this.noteFirstWord,
    required this.noteAudioActivity,
    required this.isDropped,
    required this.blockAired,
    required this.refreshSession,
    required this.armReattach,
    required this.drainBacklog,
    required this.log,
    required this.repaint,
    required this.ttsOff,
    required this.retireBgWork,
    required this.parkCutTrace,
    required this.cutTrace,
    required this.promptBumps,
    required this.phase,
    required this.armBgProbe,
    required this.turnOpenOnWire,
    required this.notePickup,
    required this.awaitingPickup,
  });

  final InteractionMode Function() mode;
  final bool Function() backgrounded, narrateOn, speakingNow;
  final int Function() generation, turnSeq;
  final bool Function() busy, badgeLit, hasError;
  final void Function(int tokens, int window) mergeContext;
  final void Function(Activity a) setStatus;
  final void Function(AssistantPhase p) setPhase;

  /// The first audible chunk of a block flipped the UI to speaking.
  final void Function() markSpeaking;
  final void Function() idleReady;
  final void Function(String message) fail;

  /// A `done` frame carrying the harness's own error flag.
  final void Function() noteHarnessError;

  /// Hide/resume bookkeeping (see HideResume): the newest block fed to
  /// the speaker, a say that landed unheard while hidden, the drop
  /// mark a hide cut mid-play, and a block whose air outranks it.
  final void Function(String text) noteReplyText, noteUnheardSay;
  final bool Function(String text) isDropped;
  final void Function() blockAired;

  /// The whole spoken text of a finished turn (the echo guard's memory).
  final void Function(String text) noteSpoken;

  /// The latency strip's first-word number (received-to-ear), stamped
  /// once per turn at the first audible chunk.
  final void Function(Duration sinceText) noteFirstWord;

  /// Reply audio just became active: the narration gate hushes.
  final void Function() noteAudioActivity;

  /// This turn is over (every exit): the teardown /health re-read that
  /// keeps the session row and the context bar current.
  final Future<void> Function() refreshSession;

  /// Our view died UNOWNED mid-turn: the turn is the bridge's to
  /// finish and ours to rejoin — arm the retry chain.
  final void Function({
    required int gen,
    required int seq,
    bool retire,
    bool resetStep,
    Duration? firstProbe,
  })
  armReattach;

  /// A heard turn ended: ask the bridge whether it still holds frames
  /// this turn never heard (+111's stranded-backlog drain).
  final Future<void> Function(int gen, int seq) drainBacklog;

  /// The TTS kill switch (BridgePrefs.tts): replies are text-only —
  /// nothing synthesises, and the ledger write happens at the block
  /// itself (the containsBlock answer IS the dedup ledger, no audio
  /// debt to retract).
  final bool Function() ttsOff;

  /// The bridge's `finished` receipt: the proof-of-completion the
  /// background banner waits for (named tool → permanent note; a
  /// lifecycle receipt → journal dismissal only). See the assistant's
  /// _retireBgWork (behaviours 2/4, +133). [cancelled] rides the
  /// frame's kind: the tool did not finish — the cut killed it — and
  /// the chat says so (the field's 'finished AND cancelled AND
  /// backgrounded all at once' contradiction, resolved at the wire).
  final void Function(String detail, {bool cancelled}) retireBgWork;

  /// +132: a push-to-talk PRESS took this turn out of the ear; the
  /// release gesture has not decided its trace yet. Park the bubble's
  /// paperwork (withdrawn while empty, untouched while it has text)
  /// until the release applies or drops it.
  final void Function(ChatEntry bubble) parkCutTrace;

  /// The bubble whose +110 paperwork is parked (null when none): the
  /// teardown must not withdraw it for being empty — the release
  /// decides.
  final ChatEntry? Function() cutTrace;

  /// Count of NEW USER PROMPTS sent (runQuickCommand openings): a
  /// queue turn's teardown drops its pin on supersede only when a
  /// NEWER PROMPT moved this number — a /stop bump must not, the
  /// bridge still flushes the pinned prompt (+104).
  final int Function() promptBumps;
  final AssistantPhase Function() phase;

  /// The bottom line is lit: arm the +133 heartbeat (once is enough —
  /// the wake re-arms its own successor).
  final void Function({Duration every}) armBgProbe;

  /// The bridge's own word on whether a turn is open RIGHT NOW: the
  /// attach replay consults it at each `done` — a farewell that rides
  /// ahead of a proactive report's receipts is history, not a period
  /// (+133: an answered turn must not strand the news the wake came
  /// for).
  final Future<bool> Function() turnOpenOnWire;

  /// Is a prompt currently PARKED (awaiting the bridge's pickup)? Its
  /// frames belong to the turn queued behind until the started marker
  /// says otherwise (+149, see [_beforeEvent]).
  final bool Function() awaitingPickup;

  /// The parked prompt was TAKEN (push view's first live frame, or the
  /// bridge's started marker): the wait is over, the answer's bubble
  /// may take the spinner box (+148).
  final void Function() notePickup;

  final void Function(String line, {bool toJournal}) log;
  final void Function() repaint;
}

class BridgeTurn {
  BridgeTurn({
    required this.origin,
    required this.env,
    required this.turn,
    required this.chat,
    required this.ticker,
    required this.narr,
    required this.hops,
    required this.reply,
    required this.lease,
    required this.transport,
    required this.scheduler,
    required this.inFlight,
    required this.gen,
    required this.mySeq,
    required this.turnBubble,
    this.utterance = '',
    this.interrupt = true,
    this.cutTool = false,
    this.pinnedEntry,
    this.myPromptBumps = 0,
    this.ack,
  });

  final BridgeTurnOrigin origin;
  final BridgeTurnEnv env;
  final TurnCoordinator turn;
  final ChatStore chat;
  final TokenTicker ticker;
  final NarrationGate narr;
  final HopTracker hops;
  final ReplyPipeline reply;
  final WireLease lease;
  final BridgeTransport transport;
  final Scheduler scheduler;

  /// Paragraphs committed to the speaker but not yet audible — process-
  /// wide (+115): a replay consults it beside the ledger so a block
  /// mid-flight in EITHER loop is never voiced twice.
  final Set<String> inFlight;

  /// This turn's ownership tokens, claimed by the opener.
  final int gen, mySeq;

  /// The assistant bubble this turn's spoken blocks land in (the
  /// opener created it; teardown retracts the unheard commits and may
  /// mark it interrupted).
  final ChatEntry turnBubble;

  /// The utterance for the open journal line (/new's chip text for a
  /// control stream; empty for a bare replay).
  final String utterance;

  /// The queue flavour this turn was opened with (journal fidelity).
  final bool interrupt;

  /// Queue-with-backgrounding (+98 behaviour 2): this polite prompt cut
  /// a RUNNING tool into background. Only meaningful with interrupt
  /// false; the bridge makes the call, the phone just pays for the
  /// banner promise the disposition notices then carry.
  final bool cutTool;

  /// The chat pin THIS send may have placed (a queued bubble): dropped
  /// at teardown only when a NEWER PROMPT superseded it — the bridge's
  /// single pending slot is latest-wins and a replaced prompt never
  /// hears its 'started' (the fossilised-pin field complaint, +131).
  final ChatEntry? pinnedEntry;
  final int myPromptBumps;

  /// Spoken when the turn produced no speech at all (silent-success
  /// controls like /compact whose signal is a system event).
  final String? ack;

  late final BridgeTurnPump pump = BridgeTurnPump(
    beforeEvent: _beforeEvent,
    isStale: () => gen != env.generation(),
    onEvent: _onEvent,
    // +133: only a REPLAY may be taught history by a `done` — its
    // backlog can carry the launch turn's farewell ahead of the report
    // the wake came for, and the bridge's own turnOpen says whether a
    // period is real. The /talk loop's done is its own, always.
    keepOpenOnDone: isAttach ? () => env.turnOpenOnWire() : null,
  );

  bool get isLive => origin != BridgeTurnOrigin.attach;
  bool get isAttach => origin == BridgeTurnOrigin.attach;

  final StringBuffer spoken = StringBuffer();

  // What this turn committed to the ledger, and which of those
  // paragraphs ever had audio START (+114). A wire death retracts the
  // unheard commits so a block in the ledger means HEARD — the replay
  // dedup leans entirely on that promise.
  final List<String> committed = [];
  final Set<String> aired = {};

  // The newest tool-step progress line, e.g. 'Edit foo.dart…' — what
  // the heartbeat repeats while a long build says nothing.
  String _latestWork = '';
  Timer? _pulse;

  /// Runs the turn: install the pump, arm the wire watchdog, run the
  /// loop to done/error/death, and tear down under the ownership rules
  /// (a superseded turn never stomps its successor's slots).
  Future<PumpOutcome> run(Stream<BridgeEvent> source) async {
    turn.installPump(pump);
    lease.armWatch(); // this connection is watched for quiet from here on
    hops.sent(); // asr→harness hop crossed: the words are on the wire
    env.log(_openLine());
    if (isLive) _rearmPulse();
    var outcome = const PumpOutcome(
      stale: true,
      sawDone: false,
      sawErrorFrame: false,
      streamError: null,
      detached: false,
    );
    try {
      outcome = await pump.run(source);
      final err = outcome.streamError;
      if (err != null && gen == env.generation()) {
        env.fail(err is BridgeException ? err.message : '$err');
      }
      // A control turn that completed silently (/compact succeeded —
      // its progress signal is a system event, not narration) still
      // owes the ear a confirmation. An errored turn does not: the
      // failure status speaks for itself.
      if (ack != null &&
          spoken.isEmpty &&
          !env.hasError() &&
          gen == env.generation()) {
        await speak(ack!);
      }
    } finally {
      _teardown(outcome);
    }
    return outcome;
  }

  String _openLine() => switch (origin) {
    BridgeTurnOrigin.talk =>
      'TALK open: gen=$gen interrupt=${interrupt ? 1 : 0} '
          '"${_trunc(utterance, 40)}"',
    BridgeTurnOrigin.control => 'CONTROL stream open (no /talk): $utterance',
    BridgeTurnOrigin.attach =>
      'ATTACH stream open: gen=$gen backlog replay, then live',
  };

  // ── Event dispatch ──────────────────────────────────────────────────────

  // The push view's first-frame pickup happens exactly ONCE per turn
  // (+133): re-running heardPickup on every frame used to blank the
  // bottom line's snapshot — and the cut-tool promise riding on it —
  // the moment the first answer paragraph landed, so a tts-on phone
  // lost its banner for a tool that was still running.
  bool _pickupDone = false;

  void _beforeEvent(BridgeEvent ev) {
    hops.reply(); // harness→reply hop crossed: bytes arrived
    // Push view: our stream is silent until the flush, so the FIRST
    // frame is the pickup — EXCEPT the bridge's 'queued' notice, which
    // is the OPPOSITE promise (behaviour 1: a busy bridge answers a
    // queue POST with that frame the instant it parks, and the pin
    // must keep watching the bottom of the channel until the turn
    // actually starts), EXCEPT a 'started' tagged kind='background' —
    // a pickup AND a promise: the tool branch below raises it with the
    // abandoned step it must name, and a heardPickup here would blank
    // that step first (the marker claims this frame's pickup itself).
    // Poll view: the ring also carries the turn we queued BEHIND —
    // only the bridge's explicit 'started' marker may dissolve the pin
    // there. A reattach backlog is by definition the OLD turn's
    // frames, so it never unpins either.
    if (!isLive || transport.turnViaPoll) return;
    final isTool = ev.kind == 'tool';
    if (isTool && ev.toolName == 'queued') return;
    if (env.awaitingPickup() && !(isTool && ev.toolName == 'started')) {
      // +149: while the prompt is PARKED its push view is NOT silent —
      // it relays the turn queued BEHIND: that turn's step frames, its
      // tail say, the done the armor eats. Field journal 22:50: the
      // old turn's Bash-step frame 300 ms after a queue release was
      // read as 'my answer began', dissolved the pin (grey gone) and
      // migrated the spinner into the placeholder — before the answer
      // it now seemed to be waiting for had even finished speaking.
      // Only the started marker takes the pickup; these frames merely
      // prove the ear is back, so the unheard badge retires on them.
      turn.becomeHeard();
      return;
    }
    chat.unpinQueued();
    if (_pickupDone) return;
    if (isTool && ev.toolName == 'started' && ev.toolKind == 'background') {
      return; // the started case below claims the pickup
    }
    _pickupDone = true;
    turn.heardPickup();
  }

  Future<void> _onEvent(BridgeEvent ev) async {
    if (ev.isSay && ev.text.trim().isNotEmpty) {
      await _onSay(ev);
    } else if (ev.kind == 'context') {
      // message_start also moves the ticker's `in` number (the context
      // frame and the tally frame ride the same field). Live context
      // consumption for the bar above the button — and the teardown
      // /health re-read catches anything this stream never heard (a
      // detached turn updates lastCtx server-side regardless of ear).
      if (ev.inputTokens != ticker.rawInputTokens) {
        ticker.noteInputTokens(ev.inputTokens);
        env.repaint();
      }
      env.log('bridge context ${ev.inputTokens}/${ev.contextWindow}');
      env.mergeContext(ev.inputTokens, ev.contextWindow);
    } else if (ev.kind == 'tool') {
      await _onTool(ev);
    } else if (ev.isDone) {
      if (ev.isError && gen == env.generation()) env.noteHarnessError();
    } else if (ev.kind == 'error') {
      // a relayed bridge error IS the turn's end
      env.fail('Bridge: ${ev.text}');
    }
  }

  Future<void> _onSay(BridgeEvent ev) async {
    if (isLive && !transport.turnViaPoll) {
      // The answer closed and is being spoken: nothing is generating to
      // grow a counter over. Harness-generated text just crossed the
      // wire: journal it (RAW — the say line mirrors what arrived) with
      // its skew-corrected delivery age, so a delayed or dropped
      // paragraph shows up as a gap in this stamp trail. On the PUSH
      // view this stream is OUR conversation: every frame is news by
      // construction, and it speaks.
      ticker.markSpoken();
      final said = ev.text.trim();
      env.log('msg harness: say "${_trunc(said, 48)}"${transport.wireTag(ev)}');
      await speak(cleanForSpeech(said));
      return;
    }
    // Everything else may carry HISTORY: the /attach replay, and — the
    // case this branch lost bubbles over (field report: "when I queue
    // or interrupt, messages show up AGAIN") — a live /talk view riding
    // the POLL ring. On the ring, the frames ahead of our POST are the
    // PREVIOUS turn's, and the previous turn may well have been heard
    // already through a push view (the cursor catches up before the
    // POST, but a press that supersedes a polling view mid-drain leaves
    // it behind, and the flush re-announces). "My view = my news" is
    // push-only law; on a shared ring the LEDGER decides, so these
    // frames get the replay rules: ONE cleaning up front, then every
    // branch — dedup test, log add, and speak — sees the SAME string
    // the live path stored. The bug this kills: the chat log keeps the
    // cleaner's OUTPUT while dedup compared its INPUT — any paragraph
    // the cleaner touched missed, and a heard paragraph rode the ring
    // back out of the speaker. Match like you store.
    final via = isAttach ? 'replay' : 'ring';
    final sayText = cleanForSpeech(ev.text.trim());
    final age = transport.wireAgeMs(ev);
    if (age > 120000 &&
        !chat.containsBlock(sayText) &&
        !inFlight.contains(sayText)) {
      // Archaeology, not news: a line from BEFORE the app went away
      // (an APK update, a kill) belongs in the conversation as text,
      // never in the speaker again — the user already lived through
      // this exchange.
      chat.addBlock(turnBubble, sayText);
      final ageSec = ev.wireMs == 0 ? 'unstamped' : '${age ~/ 1000}s old';
      env.log('$via $ageSec: logged silently, not spoken');
    } else if (chat.containsBlock(sayText) || inFlight.contains(sayText)) {
      // Already heard — or already airborne in this process. +116 makes
      // the first half TRUE: the persisted log only ever carries blocks
      // whose audio started, so containsBlock means heard, full stop —
      // and _inFlight (+115) covers the seconds before that first
      // chunk. One trade kept from the old law: a paragraph cut off
      // MID-audio counts as heard and its tail is not repeated — never
      // re-listening beats never not-listening.
      env.log('$via dedup: paragraph already in chat — skipped');
    } else {
      ticker.markSpoken();
      env.log(
        'msg harness: say ($via) "${_trunc(sayText, 48)}"'
        '${transport.wireTag(ev)}',
      );
      await speak(sayText);
    }
  }

  Future<void> _onTool(BridgeEvent ev) async {
    if (ev.toolName == 'started') {
      // The queue's pickup ack (bridge +81): Claude Code has the prompt
      // NOW. Dissolve the pin and journal the hand-off. (Push view:
      // this frame claims the turn's one pickup — the beforeEvent gate
      // let the background-tagged marker through precisely so the
      // abandoned step survives to be named by the promise just below.)
      // A marker tagged kind='background' says THIS prompt cut a
      // running tool: raise the banner promise (on the poll transport
      // this is the disposition's reliable delivery — the enqueue
      // notice rides a shared cursor the dying turn can consume and
      // drop). Otherwise the prior turn settled before the flush: the
      // tool that predates a polite pickup is closed by definition, so
      // retire the line now.
      chat.unpinQueued();
      env.notePickup();
      if (ev.toolKind == 'background') {
        // THIS prompt cut a running tool: the turn it waited behind
        // closed (that is what flushed the queue), but the tool did
        // not — the bottom line keeps naming it until the detached
        // tool's own 'finished' receipt lands (behaviours 2/4, and the
        // one delivery of that promise that a shared ring cursor
        // cannot lose).
        if (isLive && !transport.turnViaPoll) {
          turn.becomeHeard(); // heard now; the step snapshot
          // belongs to the promise — the beforeEvent gate kept it
          // alive to here
        }
        turn.promiseDetachedTool();
      } else {
        turn.heardPickup(); // the turn we waited behind is
        // closed; the spinner times ours now
      }
      env.log('queue picked up: "${ev.detail}"${transport.wireTag(ev)}');
      return;
    }
    if (ev.toolName == 'finished') {
      // The bridge's receipt that the out-of-earshot work is OVER —
      // the lifecycle receipt of a backgrounded turn (+128) and/or the
      // late tool_result of a tool this press cut into background
      // (behaviour 2): either way the bottom line dismisses itself,
      // and only a NAMED tool gets its period in the chat (the receipt
      // rule lives behind the env hook, identical for both origins).
      env.retireBgWork(ev.detail, cancelled: ev.toolKind == 'cancelled');
      return;
    }
    if (ev.toolName == 'backgrounded') {
      // +133: the harness backgrounded a shell on ITS OWN (Bash
      // run_in_background) — nobody pressed anything, but the out-of-
      // earshot work is real: light the bottom line with the bridge's
      // own word for it, live or replayed (a phone that missed the
      // frame still learns the work exists). The `finished` receipt
      // retires it; the heartbeat keeps watching for the UNPROMPTED
      // report turn meanwhile.
      turn.noteAgentWork(ev.detail);
      env.log(
        'agent backgrounded "${ev.detail}" — banner lit'
        '${transport.wireTag(ev)}',
      );
      env.armBgProbe(every: const Duration(seconds: 4));
      env.repaint();
      return;
    }
    final tally = ev.toolName == 'tokens';
    env.log(
      'bridge tool ${ev.toolName} ${ev.detail}${transport.wireTag(ev)}',
      // Token tallies ride every ~0.8 s: fine for the on-screen ring,
      // but in the journal they would flush the 240-entry story of the
      // turn we're actually trying to troubleshoot.
      toJournal: !tally,
    );
    if (tally) {
      // Live token tally ("thinking · 1.2k out · 21k in"): rewrites the
      // spinner label only — the heartbeat line and the narrate gate
      // stay untouched, or the voice would ticker-tape a counter every
      // relay.
      ticker.onFrame(ev);
      return;
    }
    ticker.markToolStep(); // a real step froze the counter: the estimate
    // stopped being about live generation
    // 'queued' (from the bridge's talk()) gets the human wording: the
    // instant an utterance parks behind a running tool, the phone says
    // 'one moment' and what happens next, instead of the old silent
    // 200 seconds of spinner. (+99: the verdict is CONVERSATION, not a
    // caption — it lands as its own bubble (+110) so neither turn can
    // swallow it; one event, one bubble: addSystemNote's adjacency
    // guard absorbs the poll transport's double delivery. Eyes-only,
    // as ever.)
    final queued = ev.toolName == 'queued';
    if (queued &&
        (ev.toolKind == 'background' ||
            ev.detail.toLowerCase().contains('background'))) {
      // (In the /talk loop this frame arrives mid-poll-view: the prior
      // turn's farewell is behind us; the promise stands on its own.)
      // The bridge's cut notice (+98 wording): the tool this press was
      // waiting behind is OUT OF EARSHOT now — the banner's warrant
      // lights on the bridge's own word (or, replayed: the bridge is
      // still owing that receipt), surviving the pin's dissolve and
      // the badge's fall until the completion receipt lands.
      turn.promiseDetachedTool();
    }
    final act = queued && !isAttach
        ? QueuedVerdict(ev.detail)
        : StepLine(ev.toolName, ev.detail);
    final stepLine = act.text(mode: env.mode());
    env.setStatus(act);
    if (!queued) {
      // The newest REAL step: what the bottom line names if this turn
      // leaves the ear now. Steps landing behind a queue pin — or
      // behind the badge, from the turn this prompt queued after —
      // belong to the backgrounded work they wait on: keep that line
      // current (the /attach loop already did). Pure-plumbing steps
      // still get label-only voice treatment (+73/+94): the eyes keep
      // the full line.
      turn.noteToolStep(stepLine);
    }
    if (!isAttach) {
      if (queued) {
        // +146: NO bubble. The queue verdict used to inject 'One
        // moment — …' as a system card between the pinned message and
        // the answer — narration of a state the channel already
        // shows: the queued message sits GREYED in the flow until the
        // agent takes it, and that IS the wait indicator. The verdict
        // still paints the transient status line above the orb and
        // journals with its wire stamp (the adjacency guard keeps
        // absorbing the poll transport's double delivery for anything
        // that still files).
        env.log(
          'queue verdict: "${_trunc(ev.detail, 48)}"${transport.wireTag(ev)}',
        );
        _latestWork = '';
      } else {
        // No step line in the conversation any more: the spinner's
        // working line (and the narration switch, for those who want
        // steps spoken) carry tool progress; the journal keeps every
        // step with its wire stamp. The chat log is for words.
        _latestWork = stepIsSilentFor(ev.toolName) ? '' : stepLine;
      }
    }
    env.repaint();
    if (isLive &&
        narr.wantStep(
          _latestWork,
          enabled: env.narrateOn(),
          backgrounded: env.backgrounded(),
          speaking: env.speakingNow(),
          playing: reply.playing,
        )) {
      unawaited(narrateProgress(_latestWork));
    }
  }

  // ── The voice half ──────────────────────────────────────────────────────

  Future<void> narrateProgress(String line) async {
    narr.narrated(line); // the gate dedups against the RAW line —
    // it's what _latestWork repeats on the heartbeat, too
    // Same markdown/filename-dot cleaning the reply path gets: the
    // espeak fallback says the literal word 'period' for the dot in
    // 'pubspec.yaml', and progress lines are full of file names.
    await speak(cleanForSpeech(line));
  }

  /// Speak one answer block end-to-end (+116: the ledger write lands at
  /// the first audio CHUNK, the moment sound genuinely begins — not
  /// merely enqueues; until air, the bubble shows only the draft tail
  /// the tally frames carry, so the screen speaks no words the speaker
  /// has not said).
  Future<void> speak(String text) async {
    if (isLive) env.noteAudioActivity(); // audio just became active: hush
    env.noteReplyText(text);
    if (env.ttsOff()) {
      // Eyes-only mode: the words land in the bubble NOW (screen is
      // the ear), and the heard-ledger is written here exactly like
      // the first-audio commit of the spoken path — so a later ring
      // or backlog replay dedups against it and never duplicates the
      // paragraph into a second bubble. No audio debt exists to
      // retract: the containsBlock answer IS the ledger.
      spoken.write('$text ');
      chat.addBlock(turnBubble, text);
      return;
    }
    if (isLive && env.backgrounded()) {
      // App is hidden: keep drinking the harness's firehose but skip
      // synth and audio entirely (the speaker is gone anyway). The
      // block still lands like everywhere else — no audio is EXPECTED
      // while hidden, so a text stamp is not a lie — and the most
      // recent one is what the resume path speaks on return.
      spoken.write('$text ');
      chat.addBlock(turnBubble, text);
      env.noteUnheardSay(text);
      return;
    }
    committed.add(text); // +114: audio-path commitment only — hidden
    // turns buffer their text on purpose and answer that accounting
    // with the resume replay instead
    inFlight.add(text); // +115: not heard UNTIL it airs
    await reply.speakBlock(
      text,
      alive: () => gen == env.generation(),
      drop: () => env.isDropped(text), // hide cut this paragraph
      // mid-play: skip it whole — its chunks die here, no replay
      onAir: (sinceText) {
        aired.add(text); // +114: the ear has it, the ledger may keep it
        inFlight.remove(text); // +115: the ledger is the truth from here
        // +116: the ledger stamp itself, at true first sound:
        spoken.write('$text ');
        chat.addBlock(turnBubble, text);
        env.blockAired(); // this block's air outranks the hide mark
        env.markSpeaking();
        hops.tts(); // reply→audio hop crossed: the first chunk of a
        // spoken block is on its way to the ear. No echo of the words
        // being spoken here: the conversation bubble already shows
        // them.
        env.noteFirstWord(sinceText); // first-word latency, once per turn
      },
    );
  }

  bool _narrateAllowed() => narr.quiet(
    enabled: env.narrateOn(),
    backgrounded: env.backgrounded(),
    speaking: env.speakingNow(),
    playing: reply.playing,
  );

  /// The long-silent-step heartbeat: while this turn still owns the
  /// busy slot, every 15 s take the pulse — the gate hushes it around
  /// any real audio, and a same-line repeat under 45 s old keeps one
  /// long build to a steady 'still on it' cadence rather than a
  /// stutter. Superseded turns (gen moved on) stop re-arming.
  void _rearmPulse() {
    _pulse = scheduler.after(const Duration(seconds: 15), () {
      if (gen != env.generation()) return;
      if (_latestWork.isEmpty || // the pulse only repeats WORK; there
          // is no news when no speakable step has been seen
          _narrateAllowed() ||
          !narr.wantHeartbeat(
            _latestWork,
            enabled: env.narrateOn(),
            backgrounded: env.backgrounded(),
            speaking: env.speakingNow(),
            playing: reply.playing,
          )) {
        _rearmPulse();
        return;
      }
      unawaited(narrateProgress(_latestWork));
      _rearmPulse();
    });
  }

  // ── Teardown — the ownership discipline ─────────────────────────────────

  void _teardown(PumpOutcome outcome) {
    _pulse?.cancel(); // no pulse outliving its turn
    // The pointer may have moved during this turn (a death-resume
    // forks; /new cleared it): re-read it after the bridge's result
    // event has written the sid file, so every exit path of every
    // bridge turn leaves the top-row id current.
    unawaited(env.refreshSession());
    // Only release the shared detach slots if they still belong to US:
    // an abandoned turn may be cleaned up after a successor turn (from
    // the voice barge-in it just triggered) has already installed its
    // own subscription and wake hook.
    final stillOurs = turn.releasePumpIf(pump);
    // Did this turn die UNOWNED — the socket errored or hit EOF with no
    // `done` and no bridge `error`? Compute while still holding the
    // busy flag: a barge-in / stop / new-prompt detach went through
    // TurnCoordinator.detach first (busy already cleared: the user
    // CHOSE that exit), and a control stream never had a /talk
    // connection to rejoin. An unowned death means the turn is likely
    // still alive on the bridge: the reattach chain goes get it.
    final wireOrphan =
        !isControl &&
        outcome.closedWithoutDone &&
        !outcome.detached &&
        env.busy() &&
        env.turnSeq() == mySeq &&
        gen == env.generation();
    if (stillOurs) lease.cancel(); // the watchdog dies with its stream
    // Release the busy slot only if we still own it — a superseded turn
    // must not stomp a new owner's state, and a SOFT detach keeps the
    // elapsed clock (+126; see TurnCoordinator.releaseOwnership).
    turn.releaseOwnership(mySeq);
    // +108: a turn superseded by the user's own newer press died
    // mid-answer — stamp the bubble so the visualization admits it. A
    // merely DETACHED turn is NOT stamped: it is still running, and a
    // reattach may deliver its real done. An empty dead turn gets
    // removed below either way.
    // +114: a wire that died UNOWNED mid-turn owes the user nothing it
    // never got to say. Every paragraph committed but never aired comes
    // OUT of the ledger: the bubble mirrors the ear, and the bridge's
    // always-kept replay copy can voice it honestly to the next view
    // instead of being deduped against a fake "heard".
    if (!outcome.sawDone) {
      for (final t in committed) {
        if (!aired.contains(t)) chat.removeBlock(turnBubble, t);
      }
    }
    inFlight.removeAll(committed); // +115: this turn's flight is over
    if (!outcome.sawDone && gen != env.generation()) {
      // +110: a cut that never got to speak still leaves a bubble.
      // The interruption of a bare thinking run or a tool call used
      // to vanish with its empty turn — erasing the very event the
      // user's own press caused. One line, stamped, permanent —
      // UNLESS the press that took the turn was a QUEUE (+132): a
      // polite supersede interrupts nothing (the tool it abandons is
      // backgrounded and finishes on its own — a sleep still sleeps,
      // a build still builds, and the 'finished' receipt proves it),
      // so stamping 'Interrupted' on the silent turn accused the
      // user's own Queue press of a murder it never committed; and a
      // PUSH-TO-TALK PRESS defers the whole verdict (+132): the
      // slide that ends the hold is the decision — up cuts, the
      // motionless tap stops, right dismisses as if nothing
      // happened, and only the first two owe this bubble a trace.
      if (isLive && turn.lastTakeover == TurnTrigger.pttPress) {
        env.parkCutTrace(turnBubble); // paperwork until the release
      } else if (isLive) {
        final wasCut = !(turn.lastTakeoverPolite && turnBubble.isEmpty);
        if (turnBubble.isEmpty && wasCut) {
          chat.addBlock(turnBubble, 'Interrupted before answering.');
        }
        if (wasCut || !turnBubble.isEmpty) chat.markInterrupted(turnBubble);
      } else if (!turnBubble.isEmpty) {
        // The replay's established rule: a partly-spoken abandoned
        // view admits the takeover; an empty one was never news.
        chat.markInterrupted(turnBubble);
      }
      // A queue press that never reached the harness before a NEWER
      // PROMPT superseded it: its promise died with the bridge's
      // single pending slot (latest wins), so retire the pin — an
      // orphaned pin is the fossilised 'queued' bubble the field
      // reports call redundancy. A supersede by /stop (no newer
      // prompt) keeps it: the bridge still flushes, and the 'started'
      // marker retires the pin then.
      if (env.promptBumps() != myPromptBumps) chat.dropPin(pinnedEntry);
    }
    // A bubble whose +110 paperwork is merely PARKED (the release
    // gesture has not decided yet, +132) stays on screen: the release
    // either files its trace or withdraws it with the recording.
    if (turnBubble.isEmpty && !identical(env.cutTrace(), turnBubble)) {
      chat.removeEmptyTurn(turnBubble);
    }
    if (gen == env.generation()) {
      // Natural end of the current turn (done event / stream close /
      // error): tear down the streamed-player machinery here. An
      // abandoned turn had it torn down by the detach funnel already,
      // and a turn superseded by a barge-in successor must NOT close
      // the queue its successor's player loop is now feeding.
      reply.closeStream();
      if (!isAttach) turn.clearLastToolStep(); // the turn is over
    }
    final said = spoken.toString().trim();
    if (said.isNotEmpty) env.noteSpoken(said);
    // An interrupted turn no longer POSTs /stop here: every interrupt
    // site goes through TurnCoordinator.detach, and THAT decides —
    // voice barge-ins DETACH (the harness keeps working as a background
    // turn), the stop chip adds a hard stop via its flavour.
    if (gen == env.generation() && spoken.isEmpty && !env.hasError()) {
      // (spoken, not sawFirstChunk: a turn answered entirely while
      // hidden buffered text without ever synthesising audio)
      if (isAttach) {
        env.idleReady();
      } else {
        env.setStatus(
          const StatusText('The harness ran, but had nothing to say.'),
        );
        env.setPhase(AssistantPhase.idle);
      }
    } else if (gen == env.generation() &&
        !reply.playing &&
        env.phase() != AssistantPhase.idle) {
      // +133: an answered turn owes the spinner no survival. A
      // text-only answer (TTS off — or any path whose audio never
      // made it to the speaker) has no natural-end event coming to
      // clear the phase, and the field-truth of +133 proved it: the
      // orb sat on 'Stop my reply' at a turn long closed. A reply
      // STILL on air keeps the spinner until _handleNaturalEnd — the
      // voice path is untouched.
      env.idleReady();
    }
    env.repaint();
    env.log(_endLine(outcome, wireOrphan));
    if (wireOrphan) {
      // Our view died mid-turn (the classic background→foreground
      // casualty): the turn is the bridge's problem to finish and our
      // problem to rejoin — probe /health and reattach, retries and
      // all. A chain born of a DYING REATTACH pays the first rung's
      // delay before its next attach attempt (paced, not reset): a
      // flaky link must not request-loop at connection-attempt speed.
      env.armReattach(
        gen: gen,
        seq: mySeq,
        resetStep: !isAttach,
        firstProbe: isAttach ? kReattachDelays.first : null,
      );
    } else if (!isAttach) {
      unawaited(env.drainBacklog(gen, mySeq));
    }
  }

  bool get isControl => origin == BridgeTurnOrigin.control;

  String _endLine(PumpOutcome outcome, bool wireOrphan) {
    final how = outcome.streamError != null
        ? 'SOCKET DIED (${outcome.streamError})'
        : outcome.sawErrorFrame
        ? 'bridge error frame'
        : outcome.sawDone
        ? 'done clean'
        : 'CLOSED WITHOUT DONE';
    final why = wireOrphan
        ? isAttach
              ? ' — UNOWNED, chain continues (paced)'
              : ' — UNOWNED, reattach chain armed'
        : gen != env.generation()
        ? ' — superseded'
        : isAttach
        ? ''
        : outcome.detached
        ? ' — detached on purpose'
        : outcome.sawDone
        ? ''
        : ' — closed by the server';
    return '${isAttach ? 'ATTACH' : 'TALK'} end gen=$gen: $how$why';
  }

  static String _trunc(String s, int n) =>
      s.length > n ? '${s.substring(0, n)}…' : s;
}
