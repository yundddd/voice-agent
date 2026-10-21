/// One bridge turn's event loop, as an object.
///
/// Both harness loops the orchestrator used to run inline (the /talk
/// loop in runQuickCommand, the /attach replay loop in
/// reattachBackgroundTurn) are the SAME conversation with the wire:
/// speak each say the moment it lands (text at the take, audio when
/// it's ready — ledger first, +109/+114; bubble-at-air inverted by the
/// +161 field dictate),
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
///
/// Delivery law (wire v2): every say carries `_mid`; it is spoken once
/// per phone because [BridgeTurnEnv.isHeard]/[BridgeTurnEnv.commitHeard]
/// are the dedup and the bridge trims its replay copy on the ack.
/// Farewells and markers are attributed by `_turn`. Text matching is
/// not a fact anywhere in this file.
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

    /// +249: the conversation the seat currently holds — the context
    /// frame's owner check.
    this.seatedSession,
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
    required this.isHeard,
    required this.commitHeard,
    required this.focusAtMs,
    required this.noteWorkHome,
  });

  final InteractionMode Function() mode;
  final bool Function() backgrounded, narrateOn, speakingNow;
  final int Function() generation, turnSeq;
  final bool Function() busy, badgeLit, hasError;
  final void Function(int tokens, int window) mergeContext;
  final String? Function()? seatedSession;
  final void Function(Activity a) setStatus;
  final void Function(AssistantPhase p) setPhase;

  /// The first audible chunk of a block flipped the UI to speaking.
  final void Function() markSpeaking;
  final void Function() idleReady;
  final void Function(String message) fail;

  /// A `done` frame carrying the harness's own error flag.
  final void Function(String? why) noteHarnessError;

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
  /// nothing synthesises; the heard-commit already rode the take in
  /// [_onSay], so the ledger is exact on this path too.
  final bool Function() ttsOff;

  /// The bridge's `finished` receipt: the proof-of-completion the
  /// background banner waits for (named tool → permanent note; a
  /// lifecycle receipt → journal dismissal only). See the assistant's
  /// _retireBgWork (behaviours 2/4, +133). [cancelled] rides the
  /// frame's kind: the tool did not finish — the cut killed it — and
  /// the chat says so (the field's 'finished AND cancelled AND
  /// backgrounded all at once' contradiction, resolved at the wire).
  final void Function(String detail, {bool cancelled, String taskId})
  retireBgWork;

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

  /// wire v2 heard-ledger (see HeardLedger): a message's paragraph is
  /// news UNLESS this phone already TOOK its id. [isHeard] is the whole
  /// dedup — exact, persistent, and text-blind, so a reused paragraph
  /// is never swallowed and a replayed one never re-speaks.
  /// [commitHeard] remembers the take (irrevocably: a barge-in drops,
  /// never re-owes) and acks the bridge so its backlog trims.
  final bool Function(int mid) isHeard;
  final void Function(int mid) commitHeard;

  /// +253 THE FOCUS WATERMARK (Tim's law): the instant (bridge clock —
  /// the same domain as a frame's _ts) the conversation became the one
  /// on screen; 0 = none since boot. A say stamped before it is
  /// backlog the eyes get and the ears don't; a say from a conversation
  /// that is NOT the seated one is out-of-earshot work, whatever its
  /// age — the gear badge is its sign, the thread is its delivery.
  final int Function() focusAtMs;

  /// +257: this view's conversation finished its turn (a done of
  /// _viewSid's own, not an age-out): the assistant retires that
  /// conversation's away-marker — backgrounded work is only background
  /// until it isn't.
  final void Function(String sid) noteWorkHome;

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

  int _myTurn = 0;

  /// +253: the conversation this view's frames belong to — the seat's
  /// id when the view opened (null = the birth turn's honest 'name
  /// coming'; an unnamed turn IS the conversation watching it born),
  /// corrected by any context frame that carries its session. Feeds
  /// the focus gate in [_onSay]: a view whose conversation the seat
  /// left behind files its says silently — the +246 backgrounding kept
  /// the stream alive, and this is what that stream may now do with a
  /// paragraph: land in the thread, never interrupt the tab on screen.
  String? _viewSid;

  bool get isLive => origin != BridgeTurnOrigin.attach;
  bool get isAttach => origin == BridgeTurnOrigin.attach;

  final StringBuffer spoken = StringBuffer();

  // +114's committed/aired ledger pair retired with +161: with the text
  // stamped at the take, the only accounting the loop keeps is what it
  // said (for the echo guard and the 'nothing to say' verdict).

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
    _viewSid = env.seatedSession?.call(); // +253: named at birth, if named
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

  /// wire v2: the turn id the POST receipt reserved for THIS prompt
  /// (from the pump's first `turn` event; 0 on views that never POSTed
  /// — an /attach drain has no name of its own and honours any
  /// marker). Farewells and markers are attributed by it, never by
  /// text or order.

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
    // wire v2: CONSUMPTION is the ack. Only `say` gets its commit at
    // the take (before the speaker — the barge-in-drop law below);
    // every other frame this pump digests — tool lifecycle, context
    // previews, the farewell done — is TAKEN the moment it is digested.
    // A consumed-but-unacked frame stays in the bridge's unheard
    // backlog forever, so `missed` sticks at a dead number and every
    // heartbeat reads it as "a report is still streaming": the chain
    // steals the view, replays the backlog it already ate, dies on its
    // own farewell, and the thinking box flashes on a 10 s cadence
    // while the banner can never retire (0.1.0+159 field report).
    if (ev.kind == 'file') {
      // A file frame is a delivery, like a say — so it gets the same
      // ledger FIRST: news unless this phone already took its id (a
      // drain replay would otherwise file the same APK bubble every
      // attach). Unlike a stale paragraph, it is never demoted to
      // silent-text: the bytes are still on the desktop to fetch, so
      // even archaeology lands as a tappable bubble.
      if (ev.mid != 0 && env.isHeard(ev.mid)) {
        env.log('file dup by id #${ev.mid} — skipped');
        return;
      }
      if (ev.mid != 0) env.commitHeard(ev.mid);
      chat.addFile(name: ev.fileName, path: ev.filePath, size: ev.fileSize);
      env.log('file relayed: "${ev.fileName}"${transport.wireTag(ev)}');
      return;
    }
    if (ev.kind != 'turn' && !ev.isSay && ev.mid != 0) {
      env.commitHeard(ev.mid);
    }
    if (ev.kind == 'turn') {
      // The receipt, arriving in-band: this pump now knows its own
      // name — every later marker and farewell is attributed by it.
      _myTurn = ev.turn;
    } else if (ev.isSay && ev.text.trim().isNotEmpty) {
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
      // +253: the frame that names the pen names the CONVERSATION —
      // a birth turn's view learns its own identity here, and the
      // focus gate below can finally tell 'mine' from 'the one you
      // left' even for streams that opened nameless.
      if (ev.ctxSession != null) {
        _viewSid = ev.ctxSession;
        // +257: the same stamp teaches the COORDINATOR whose turn the
        // machine holds — the seat marker signs THAT, not whichever
        // tab is looking.
        turn.noteWorkOwner(ev.ctxSession!);
      }
      // +249: the bar belongs to the conversation it is seated on. A
      // context frame from a backgrounded thread updates the METER
      // (that turn's own ledger keeps its truth) but not the BAR of a
      // different tab; sessionless frames (old bridges) merge on
      // trust, exactly as before.
      final seated = env.seatedSession?.call();
      final barHome =
          ev.ctxSession == null || seated == null || ev.ctxSession == seated;
      if (barHome) env.mergeContext(ev.inputTokens, ev.contextWindow);
    } else if (ev.kind == 'tool') {
      await _onTool(ev);
    } else if (ev.isDone) {
      if (ev.isError && gen == env.generation()) {
        // +219: the wire's reason, not a generic one — the status line
        // says WHAT the harness said ('Access to model denied…'), the
        // fallback only when an old bridge sent the flag alone.
        env.noteHarnessError(ev.text.isEmpty ? null : ev.text);
      }
    } else if (ev.kind == 'error') {
      // a relayed bridge error IS the turn's end
      env.fail('Bridge: ${ev.text}');
    }
  }

  Future<void> _onSay(BridgeEvent ev) async {
    // wire v2: a paragraph's identity is its id, and the ONLY question
    // at arrival is "did this phone already TAKE it?" — a set lookup.
    // The text ledger (+155's swallowed reused paragraph), the marker
    // boundary (+131/+157's fossilised pins), the airborne set (+115)
    // and the replay/live branches (+156's drain dup) all inferred
    // this answer from text, order or age — and each misfired in its
    // own field report. The id does not: news unless its mid says
    // otherwise.
    final sayText = cleanForSpeech(ev.text.trim());
    final age = transport.wireAgeMs(ev);
    if (ev.mid != 0 && env.isHeard(ev.mid)) {
      // Exact redelivery — live double, drain replay, whatever. Even
      // with identical text, even freshly stamped: it cannot speak
      // twice (today's 'Here.' dup, killed at the root).
      env.log('dup by id #${ev.mid} — skipped');
      return;
    }
    // TAKEN: the commit (and its ack) land NOW, before the speaker —
    // a barge-in from here drops the paragraph, it never re-owes it
    // (user dictum: 'for barge in just drop').
    if (ev.mid != 0) env.commitHeard(ev.mid);
    if (sayText.isEmpty) {
      // +179: the paragraph WAS the markup — once the tags fall there
      // is nothing to show or say (the 13:11 tape's entire 'answer').
      // Consumed like news (the ack above rides anyway, so the wire
      // trims it), spoken by nobody: the empty-turn machinery the
      // 'nothing to say' walk already pins treats the reply as never
      // said.
      env.log(
        'say #${ev.mid} was pure tool-call markup — dropped'
        '${transport.wireTag(ev)}',
      );
      return;
    }
    // +253 THE FOCUS WATERMARK (Tim's law): only the conversation ON
    // SCREEN gets the speaker, and only what was written after you got
    // there. A say stamped before this view's focus landed is the
    // backlog you swiped onto — filed, acked, visible, mute. A say
    // whose conversation the seat left behind is out-of-earshot work
    // whatever its age — the thread delivers it, the gear badge (+230)
    // signs it, and the speaker never interrupts the tab you are
    // watching. (The 120 s rule below is the same honesty for a longer
    // absence; the watermark is the same honesty for this one.)
    final seatedNow = env.seatedSession?.call();
    final viewHome =
        _viewSid == null || seatedNow == null || _viewSid == seatedNow;
    final focusAt = env.focusAtMs();
    if (!viewHome ||
        (focusAt != 0 && ev.wireMs != 0 && ev.wireMs < focusAt)) {
      chat.addBlock(turnBubble, sayText);
      env.log(
        '${viewHome ? 'pre-focus backlog' : 'unfocused conversation'}:'
        ' logged silently, not spoken${transport.wireTag(ev)}',
      );
      return;
    }
    if (ev.mid != 0 && age > 120000) {
      // Never heard AND ancient: lived through while the phone was
      // gone (an APK update, a week offline). Text, never the speaker
      // — one courtesy rule where the old law kept a matrix.
      chat.addBlock(turnBubble, sayText);
      final ageSec = ev.wireMs == 0 ? 'unstamped' : '${age ~/ 1000}s old';
      env.log('backlog $ageSec: logged silently, not spoken');
      return;
    }
    ticker.markSpoken();
    // The PUSH view's say line mirrors the RAW frame (what arrived);
    // other views log the cleaned text — match like you store.
    final logged = (isLive && !transport.turnViaPoll)
        ? ev.text.trim()
        : sayText;
    env.log('msg harness: say "${_trunc(logged, 48)}"${transport.wireTag(ev)}');
    await speak(sayText);
  }

  Future<void> _onTool(BridgeEvent ev) async {
    if (ev.toolName == 'started') {
      // +155: the ring remembers markers for prompts long dead (it is
      // a 2000-event tape) — a stale marker must not fake this view's
      // pickup. v2 says WHOSE by id: the marker was born stamped with
      // the turn its POST reserved. Views that never POSTed (an
      // attach drain, an ack stream) have no name of their own and
      // honour any marker — the backlog they replay is by definition
      // theirs to catch up on.
      final mine = _myTurn == 0 || ev.turn == 0 || ev.turn == _myTurn;
      if (!mine) {
        env.log(
          'stale pickup marker (turn ${ev.turn}, ours $_myTurn) — ignored',
        );
        return;
      }
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
      // +170: a pickup is a turn's birth — counters start fresh, and a
      // `settled` carried over from the prompt this queued BEHIND must
      // not hide the new turn's box until its first tally happens to
      // relay (the bridge resets its counters at beginTurn; the phone
      // mirrors at the marker).
      ticker.resetForTurn();
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
      env.retireBgWork(
        ev.detail,
        cancelled: ev.toolKind == 'cancelled',
        taskId: ev.taskId,
      );
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
      // +170: the harness backgrounded a shell — a tool IS running,
      // whatever the last message's message_stop said.
      ticker.markToolStep();
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

  /// Speak one answer block end-to-end (+161: the TEXT lands in the
  /// bubble the moment it is TAKEN — the +116 law of showing only what
  /// the speaker has said is inverted, by field dictate: chunk-by-chunk
  /// reveals made the reader wait at the speaker's pace, and a user who
  /// could not see the rest of the answer could not decide to skip it.
  /// All three dispositions now share the stamp line: tts-off (the
  /// screen IS the ear), hidden (no audio is expected, so a text stamp
  /// is no lie), and audible (the audio follows when it's ready —
  /// barge-in still drops the REMAINING AUDIO, never the words: the
  /// press that cuts reads as 'I got it, skip the voice', and the ✋
  /// mark keeps that honest). The mid was already committed at the take
  /// in [_onSay], so a redelivery dedups by id whichever way this block
  /// plays out.)
  Future<void> speak(String text) async {
    if (isLive) env.noteAudioActivity(); // audio just became active: hush
    env.noteReplyText(text);
    spoken.write('$text ');
    chat.addBlock(turnBubble, text);
    if (env.ttsOff()) {
      // Eyes-only mode: nothing else to do — no audio debt exists to
      // retract, the ledger is the take, and the take is final.
      return;
    }
    if (isLive && env.backgrounded()) {
      // App is hidden: keep drinking the harness's firehose but skip
      // synth and audio entirely (the speaker is gone anyway) — and
      // the most recent block is what the resume path speaks on
      // return.
      env.noteUnheardSay(text);
      return;
    }
    // +115's in-process airborne set retired with v2: a redelivery of a
    // TAKEN mid is a set lookup, and takes are recorded before the
    // speaker, not after (+114's retraction retires too — the bubble
    // now mirrors the WIRE, and a cut turn says so with its ✋ mark,
    // not by erasing words the phone received).
    await reply.speakBlock(
      text,
      alive: () => gen == env.generation(),
      drop: () => env.isDropped(text), // hide cut this paragraph
      // mid-play: skip it whole — its chunks die here, no replay
      onAir: (sinceText) {
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
    // +257: DONE IS THE PROOF. A view that watched its conversation's
    // turn close retires that conversation's seat marker — backgrounded
    // work has an end, and from the farewell on, every tab is its own
    // face again (never an age-out, never a swipe: the turn's own
    // period). A view that died without one keeps the marker: the work
    // is still running somewhere, and the reattach chain is going to
    // get it.
    if (outcome.sawDone && _viewSid != null) env.noteWorkHome(_viewSid!);
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
    // +114's retraction (the screen mirrored the ear: committed-but-
    // never-aired paragraphs came OUT of the bubble) retires with +161:
    // the bubble mirrors the WIRE. Words the phone received stay on
    // screen even when their audio never aired — the user read them,
    // or pressed past them — and a turn cut mid-answer admits the
    // takeover with its ✋ mark, not with amnesia. The ledger never
    // retracted anyway (v2: the ack rode the take; 'for barge in just
    // drop').
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
      // +165: the audio-rendering verdict dies with the wire. A
      // settled tally is the TURN's state — leaving it standing across
      // the close would hide the +164 drain-debt row behind a caption
      // about an audio pipeline the next phase has nothing to do
      // with. The next turn resets too (runQuickCommand / reattach);
      // this reset covers the gap where a debt is owed between turns.
      ticker.resetForTurn();
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
        ? (outcome.doneError == null
              ? 'done clean'
              : 'done error: ${_trunc(outcome.doneError!, 90)}')
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
