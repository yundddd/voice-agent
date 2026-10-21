/// The bridge-turn truth, in one place.
///
/// A bridge turn has exactly three questions to answer at any moment —
/// WHO is listening (the phone's view: attached or detached), WHETHER the
/// harness keeps working (the work: alive on the bridge or cut by a
/// /stop), and WHOSE turn owns the shared slots (the generation and seq
/// ownership tokens). This class is the SINGLE WRITER of that truth: the
/// busy flag, the backgrounded badge, the bottom line's snapshot, the
/// age clock, and the live pump slot.
///
/// Before this class, the same fields lived as ~7 raw flags on
/// [VoiceAssistant] mutated from ~30 sites across 4 flows — which is how
/// the badge/clock rules grew a fix at one teardown and not another
/// (0.1.0+126). Now every mutation is a NAMED TRANSITION here, the
/// invariants are stated once on the method that enforces them, and the
/// assistant only reads (through its delegation getters) and fires the
/// transitions.
///
/// What deliberately stays in the assistant: the machinery a transition
/// ORCHESTRATES (the reattach chain, the reply player, the gateway
/// request). Those arrive as constructor callbacks — the coordinator
/// owns the truth and the ORDER of operations, the assistant owns the
/// machine parts.
library;

import 'dart:async';

import '../bridge/turn_pump.dart';
import '../common/clock.dart';

/// What a takeover means for the harness's WORK.
///
/// The VIEW always leaves the turn (that is what detach means); the
/// question this enum answers is whether the work is left to finish
/// unheard or killed in-band:
///
///  * [detach]  — the connection closes and the bridge BACKGROUNDS the
///    turn: a long tool call finishes its work, a mere thinking turn is
///    cut short in-band by the NEXT prompt's interrupt flag. "I'll
///    steer", not "stop working".
///  * [hardStop] — additionally POSTs /stop, the bridge's in-band
///    interrupt (the CLI process survives — no `--resume` re-prefill).
///    "Stop working."
enum TakeoverStop { detach, hardStop }

/// Every gesture that can land on a live bridge turn and take it away.
/// One value per detach call site — the point of the enum is that the
/// detach-vs-hardStop decision is made EXACTLY once, in [takeoverStop],
/// never re-derived (and re-diverged) per trigger.
enum TurnTrigger {
  /// Spoken takeover while a reply plays (conversation-mode barge-in).
  voiceBargeIn,

  /// Speech while a half-baked response was still transcribing: the
  /// user resumed before the agent said a word.
  speechResumed,

  /// A push-to-talk press over a live turn (the release gesture then
  /// decides what the new prompt does — slide up interrupts in-band,
  /// plain release queues politely).
  pttPress,

  /// A fresh prompt taking the wire (typed text, or the voice path's
  /// defensive detach right before its own /talk).
  newUtterance,

  /// The Stop chip: "stop working".
  stopChip,

  /// Conversation-mode tap-to-cancel while a reply plays.
  cancelTap,

  /// The conversation ended (or the mode switched off it): no ear is
  /// left on the harness.
  conversationClose,

  /// The latency bench takes the speaker: bench timing cannot share
  /// the harness.
  benchStart,

  /// The interaction mode changed with no turn in flight (a no-op by
  /// the busy guard — kept as a trigger so the table stays exhaustive
  /// over every call site).
  modeSwitch,

  /// The quiet-wire watchdog declared the socket dead: give up the
  /// zombie view, the reattach chain will steal a fresh one.
  zombieWire,
}

/// THE interrupt policy, as data. Every trigger maps to its takeover
/// flavour; the switch is exhaustive, so adding a trigger without
/// deciding its meaning is a compile error, and this function is the
/// one place a flavour can change.
///
/// The table in full (trigger → what happens to the WORK):
///
///  | trigger            | work                                    |
///  |--------------------|-----------------------------------------|
///  | voiceBargeIn       | detached — keeps working, backgrounded  |
///  | speechResumed      | detached — keeps working, backgrounded  |
///  | pttPress           | detached — keeps working, backgrounded  |
///  | newUtterance       | detached — the bridge queues/cuts at the next prompt's interrupt flag |
///  | stopChip           | HARD STOP — /stop in-band interrupt     |
///  | cancelTap          | HARD STOP                               |
///  | conversationClose  | HARD STOP — no ear left to come back    |
///  | benchStart         | HARD STOP — the bench owns the speaker  |
///  | modeSwitch         | HARD STOP (no-op unless a turn is live) |
///  | zombieWire         | detached — the work never was the problem, the route was |
TakeoverStop takeoverStop(TurnTrigger trigger) => switch (trigger) {
  TurnTrigger.voiceBargeIn => TakeoverStop.detach,
  TurnTrigger.speechResumed => TakeoverStop.detach,
  TurnTrigger.pttPress => TakeoverStop.detach,
  TurnTrigger.newUtterance => TakeoverStop.detach,
  TurnTrigger.stopChip => TakeoverStop.hardStop,
  TurnTrigger.cancelTap => TakeoverStop.hardStop,
  TurnTrigger.conversationClose => TakeoverStop.hardStop,
  TurnTrigger.benchStart => TakeoverStop.hardStop,
  TurnTrigger.modeSwitch => TakeoverStop.hardStop,
  TurnTrigger.zombieWire => TakeoverStop.detach,
};

/// The single writer of the bridge-turn truth (see the library docs).
///
/// Transitions, in the order they happen in a turn's life:
///
///  * [supersede] — bump the generation: every alive/isStale closure of
///    the old work goes false.
///  * [claimSlot] / [beginHeardTurn] — a new turn takes the busy slot.
///  * [becomeHeard] / [heardPickup] — the ear is on (our turn started,
///    or the work we queued behind proved closed).
///  * [markBackgrounded] — a press detached the turn: the badge lights,
///    the clock keeps counting the WORK.
///  * [noteToolStep] — the newest real tool step, for the bottom line.
///  * [detach] — THE funnel every takeover lands in: snapshot the work,
///    release the slot, detach the pump, and (per [takeoverStop]) send
///    /stop.
///  * [releaseOwnership] / [releasePumpIf] — teardown, bowing out to a
///    successor that already claimed the slot.
///  * [noteAgentWork] — the harness backgrounded a shell on its own:
///  * the bottom line names it (0.1.0+133), receipts and /health clear.
///  * [retireBadge] / [retireBadgeAndWork] / [stopDetachedWork] — the
///    badge goes out because the work provably ended.
final class TurnCoordinator {
  TurnCoordinator({
    required Clock clock,
    required void Function(String message) log,
    required Future<void> Function() hardStop,
    required void Function() beforeDetach,
    required void Function() afterDetach,
    required bool Function() queuedPin,
  }) : _clock = clock,
       _log = log,
       _hardStop = hardStop,
       _beforeDetach = beforeDetach,
       _afterDetach = afterDetach,
       _queuedPin = queuedPin;

  final Clock _clock;
  final void Function(String message) _log;

  /// The bridge's /stop — the hard-stop interrupt (awaited nowhere; it
  /// is fire-and-forget by contract).
  final Future<void> Function() _hardStop;

  /// The assistant's machine parts that run BEFORE anything else in
  /// [detach]: cancel any reattach chain waiting to re-hear this
  /// superseded story (otherwise its delayed attach could steal the
  /// bridge's view right off the queued /talk stream the next prompt
  /// rides).
  final void Function() _beforeDetach;

  /// The assistant's machine parts that run LAST in [detach]: drain and
  /// close the streamed player, so the abandoned loop cannot clobber a
  /// successor's fresh `startStream` set.
  final void Function() _afterDetach;

  /// Whether the channel currently carries a queued-press pin — the
  /// other reason (beside the badge) a tool step labels the bottom line.
  final bool Function() _queuedPin;

  // ── The truth ──────────────────────────────────────────────────────────
  int _generation = 0; // supersedes in-flight work when bumped
  int _seq = 0; // busy-slot ownership token (each turn claims its own)
  bool _busy = false; // a bridge turn is in flight (chips disabled)
  bool _backgrounded = false; // a turn the phone detached keeps working
  // +257: WHOSE turn the machine currently holds. Every `context`
  // frame names its conversation (the bridge's ctxOwner stamp) — the
  // stated truth beats any inference from which tab is looking, and
  // it is what the seat's marker capture signs on: backgrounded work
  // goes home to the conversation that OWNS it, never to whichever
  // tab's claim happened to light the busy slot (the xray volley's
  // last sharing bug: a mail fetch on the wrong tab lit the box for
  // someone else's thoughts).
  String? _workOwner;
  String? get workOwner => _workOwner;
  void noteWorkOwner(String sid) => _workOwner = sid;
  // on the bridge with no ear on it: the terminal badge stays lit until
  // a heard turn starts, /stop lands, or a probe proves nothing open.
  DateTime? _since; // wall clock the in-flight bridge turn started
  String _lastToolStep = ''; // the newest REAL tool step this turn attested
  String _bgWork = ''; // what the harness is doing OUT OF EARSHOT — the
  // bottom line's snapshot; see [detach] and [noteToolStep].
  TurnTrigger? _lastTakeover; // the most recent takeover's trigger:
  // an abandoned turn's teardown reads this to tell a PRESS (whose
  // trace the release gesture decides, +132) from a decided takeover.
  bool _lastTakeoverPolite = false; // the superseding press queued
  // (interrupt=0) instead of interrupting: the turn it abandoned was
  // NOT cut — it settles unheard or keeps working behind the banner,
  // and the teardown's +110 trace must not accuse a polite press of a
  // murder it never committed. Read by the abandoned turn's finally;
  // describes the MOST RECENT takeover (each detach overwrites).
  bool _detachedPromise = false; // a tool THIS press cut into background
  // +133: shells the HARNESS backgrounded ITSELF (the bridge's `tool
  // backgrounded` frame); +140: the LEDGER of every such shell not yet
  // proven over. The bottom line can name only one at a time (the
  // newest), so the ledger keeps the rest until payment — a named
  // `finished` receipt pays its own label, /health proof that nothing
  // is detached pays all. A turn-closed receipt pays NOTHING: it
  // proves the TURN went unheard, not that the process died (the
  // three-sleep field report: the chat called 'Bash sleep 120'
  // finished while all three shells were still running).
  final List<String> _agentDebts = [];
  // (the started marker's kind='background'): the line keeps naming its
  // step even after the pickup made this turn heard, until the tool's
  // own 'finished' receipt pays the promise (behaviours 2/4).
  BridgeTurnPump? _pump; // the live /talk listener — detached to BACKGROUND

  int get generation => _generation;
  int get seq => _seq;
  bool get busy => _busy;
  bool get backgrounded => _backgrounded;
  DateTime? get since => _since;
  String get lastToolStep => _lastToolStep;
  String get bgWork => _bgWork;

  /// The cut-tool promise: the bottom line is warranted even without the
  /// badge or a pin while a tool this phone cut is owed its receipt.
  bool get detachedPromise => _detachedPromise;

  /// The agent's own background work: run_in_background shells the
  /// harness launched and has not reported in yet (0.1.0+133, the
  /// ledger of +140).
  bool get agentWork => _agentDebts.isNotEmpty;

  /// Every owed shell's label, in launch order (a copy — the caller
  /// pays from it while the ledger drains).
  List<String> get agentDebts => List.of(_agentDebts);

  /// The most recent takeover's trigger (null before the first one).
  TurnTrigger? get lastTakeover => _lastTakeover;

  /// Whether the most recent takeover was a POLITE press (interrupt=0):
  /// the superseded turn's teardown reads this to decide whether an
  /// 'Interrupted before answering.' trace would be a lie.
  bool get lastTakeoverPolite => _lastTakeoverPolite;
  BridgeTurnPump? get pump => _pump;

  // ── Transitions ────────────────────────────────────────────────────────

  /// Bump the generation: every `alive:`/`isStale:` closure captured off
  /// the old value goes false, so TTS chunks drop and event loops exit.
  /// Returns the NEW generation for the caller to capture.
  int supersede() => ++_generation;

  /// Claim the busy slot for a new turn. Returns the ownership seq the
  /// teardown must present back to [releaseOwnership].
  int claimSlot() {
    _seq++;
    _busy = true;
    _workOwner = null; // +257: a new claim is unnamed until a frame says whose
    return _seq;
  }

  /// The reattach path claims generation and slot contiguously (no
  /// other turn may interleave between them).
  ({int gen, int seq}) beginHeardTurn() {
    final gen = supersede();
    final seq = claimSlot();
    return (gen: gen, seq: seq);
  }

  /// This turn is HEARD from here on: the badge goes out and the age
  /// clock re-anchors to NOW (the chat spinner counts the live turn,
  /// not the press that preceded it — +126).
  void becomeHeard() {
    _pttPressPending = false; // heard is decided: nothing pending
    _backgrounded = false;
    _since = _clock();
  }

  /// The bridge just picked up work we waited behind (the 'started'
  /// pickup ack, or any frame of our own push stream — the first frame
  /// IS the pickup on a per-turn SSE view). Whatever it waited behind
  /// is closed by definition (the bridge flushes only closed turns):
  /// the badge goes out, the age re-anchors to our live turn, and the
  /// bottom line's snapshot is blanked so a dead step can never
  /// re-surface behind a new pin.
  void heardPickup() {
    becomeHeard();
    _lastToolStep = '';
    _detachedPromise = false;
    // A picked-up turn drops the snapshot, but a PROCESS still running
    // is not unheard by the pickup (+140): the line re-labels to the
    // newest owed shell instead of blanking on it.
    _bgWork = _agentDebts.isNotEmpty ? _agentDebts.last : '';
  }

  /// The cut disposition: the bridge put a running tool into background
  /// for this prompt (+99, behaviours 2/4). The bottom line lights on
  /// the bridge's own word — the enqueue notice or the tagged pickup
  /// marker, whichever arrives (BOTH call this; idempotent, and the
  /// marker is the copy the shared ring cursor cannot lose) — named by
  /// the step the turn was chewing when it left the ear. The promise
  /// retires on the tool's own 'finished' receipt or /health proof that
  /// the receipt is gone.
  void promiseDetachedTool() {
    if (_bgWork.isEmpty) _bgWork = _lastToolStep;
    _detachedPromise = true;
  }

  /// The harness backgrounded a shell itself (+133, the bridge's
  /// `tool backgrounded` frame — live or replayed). The bottom line
  /// names THAT step, not whatever the last snapshot held; the promise
  /// is paid by the report's `finished` receipt or /health proof.
  void noteAgentWork(String label) {
    final name = label.isNotEmpty
        ? label
        : (_lastToolStep.isNotEmpty ? _lastToolStep : 'Background shell');
    if (!_agentDebts.contains(name)) _agentDebts.add(name);
    _bgWork = name;
  }

  /// A named `finished` receipt pays ITS OWN shell and only its own
  /// (+140): the label leaves the ledger and the line re-labels to the
  /// newest still-owed shell, blanking only when the ledger runs dry.
  /// Returns the label the line now names ('' when none). A cut tool's
  /// label is not in the ledger: the call is then a no-op.
  String payAgentDebt(String label) {
    _agentDebts.remove(label);
    _bgWork = _agentDebts.isNotEmpty ? _agentDebts.last : '';
    return _bgWork;
  }

  /// A press detached this very turn: the badge lights. The clock is
  /// deliberately NOT touched — it keeps counting the WORK the user was
  /// watching, not the press (+126: the press must not visually kill
  /// the spinner).
  /// A push-to-talk PRESS over a heard turn detaches it so the mic can
  /// open — but the BANNER must not blink on the press: the release
  /// gesture decides whether the turn is actually out of the ear
  /// (queue → the successor pump hears the tail; cut → the promise and
  /// its receipt tell; discard / no-words → genuinely unheard). While
  /// the verdict is pending the badge is real but silent (+146): the
  /// spinner law and /stop bookkeeping read the raw flag, the bottom
  /// line reads [backgroundUnheard].
  void markBackgrounded({bool verdictPending = false}) {
    _backgrounded = true;
    _pttPressPending = verdictPending;
  }

  /// The press's release happened: the banner shows the badge if it is
  /// still lit (discard, no-words), or nothing (queue retired it, cut
  /// rides the promise from the wire).
  void resolveBackgroundVerdict() {
    _pttPressPending = false;
  }

  bool _pttPressPending = false;

  /// Badge lit AND the release verdict settled: work the phone is not
  /// hearing — the ONLY banner shape a press may produce (+146).
  bool get backgroundUnheard => _backgrounded && !_pttPressPending;

  /// A real tool step arrived on the live turn: it is what the bottom
  /// line names if this turn leaves the ear NOW. Steps landing behind a
  /// queue pin — or behind the badge, from the turn this prompt queued
  /// after — belong to the backgrounded work they wait on: keep that
  /// line current. Tally frames and queue verdicts never label it (a
  /// counter is not a tool call) — the caller filters those.
  void noteToolStep(String stepLine) {
    _lastToolStep = stepLine;
    if (_queuedPin() || _backgrounded) {
      _bgWork = stepLine;
    }
  }

  /// The turn is over; its step labels are history.
  void clearLastToolStep() {
    _lastToolStep = '';
  }

  /// The bottom line's snapshot goes, but the badge and the clock stay:
  /// a LIVE turn owns the slot here (this arrives on its view as a
  /// replayed receipt for the work it queued behind), and its spinner's
  /// age must never be zeroed by a frame about OLDER work.
  void clearBgWork() {
    _detachedPromise = false; // the receipt paid it
    // The SNAPSHOT goes; an owed process does not (+140) — the ledger
    // re-labels the line, and only a real payment clears a debt.
    _bgWork = _agentDebts.isNotEmpty ? _agentDebts.last : '';
  }

  /// The badge goes out and the clock stops, but the snapshot is KEPT:
  /// the too-short tap-stop path only proves the badge stale, and the
  /// post-detach sweep must not blank a snapshot another flow owns.
  void retireBadge() {
    _backgrounded = false;
    _pttPressPending = false; // the badge is gone; the verdict is moot
    _since = null;
    _detachedPromise = false; // no badge, no promise: work proven over
  }

  /// Badge out, clock stopped, snapshot blanked: retired work is not
  /// background work any more (an orphan retire, or a /stop proven to
  /// have landed).
  void retireBadgeAndWork() {
    retireBadge();
    _bgWork = '';
    _agentDebts.clear(); // retired work is not owed work any more
  }

  /// The Stop chip over a DETACHED turn: /stop lands on invisible work
  /// just the same, the badge goes out, and the snapshot blanks — no
  /// stale step to re-surface behind the next pin.
  /// Returns true when there WAS detached work to stop, so the caller
  /// can speak the outcome only then.
  bool stopDetachedWork() {
    if (!_backgrounded) return false;
    unawaited(_hardStop());
    retireBadgeAndWork();
    _log('user STOP: /stop sent to the DETACHED turn (badge cleared)');
    return true;
  }

  /// THE detach funnel — every takeover lands here, exactly once.
  ///
  /// Sequence (order preserved from the original inline helper, where
  /// each step's comment explains why it sits where it sits):
  ///
  ///  1. bow out unless the busy slot is ours to give up;
  ///  2. `_beforeDetach` — the reattach chain goes quiet first;
  ///  3. snapshot the working step for the bottom line;
  ///  4. journal the detach (and what it backgrounded);
  ///  5. [takeoverStop]: a hard stop adds the /stop interrupt;
  ///  6. release the busy slot;
  ///  7. a SOFT detach keeps the elapsed clock (the badge is lit: the
  ///     turn is working on the bridge exactly as before — pressing the
  ///     mic must not visually kill the spinner the user is watching,
  ///     0.1.0+72); a hard stop, or a detach into the void, zeroes it —
  ///     and blanks the snapshot too, so a stopped step can never
  ///     re-surface on the bottom line behind some later pin;
  ///  8. the pump slot empties and its connection cancels mid-tool-run
  ///     (the bridge backgrounds the turn);
  ///  9. `_afterDetach` — the streamed player goes with the turn.
  /// [polite] records the superseding press's flavour for the abandoned
  /// turn's teardown (+132): a queue press interrupts NOTHING — the
  /// work it leaves behind settles or continues out of the ear, so the
  /// takeover must not stamp 'Interrupted before answering.' on it.
  void detach(TurnTrigger trigger, {bool polite = false}) {
    if (!_busy) return;
    final hardStop = takeoverStop(trigger) == TakeoverStop.hardStop;
    _lastTakeover = trigger;
    _lastTakeoverPolite = polite && !hardStop;
    // +146: a press's verdict stays pending across the detach — the
    // zero-delay steal-back probe (or the release, whichever lands
    // first) is what decides the banner.
    _beforeDetach();
    _bgWork = _lastToolStep;
    if (_backgrounded) {
      _log(
        'msg bg: ${_bgWork.isEmpty ? 'the turn keeps' : '"$_bgWork" keeps'} '
        'working unheard',
      );
    }
    _log(
      'bridge view detached on purpose (hardStop=$hardStop, '
      '${trigger.name}): reattach chain silenced, sub cancelled, loop '
      'parked — turn keeps working unheard'
      '${hardStop ? ', /stop interrupt sent too' : ''}',
    );
    if (hardStop) unawaited(_hardStop());
    _busy = false;
    if (!_backgrounded) {
      _since = null;
      _bgWork = '';
    }
    final pump = _pump;
    _pump = null;
    pump?.detach();
    _afterDetach();
  }

  /// Teardown: release the busy slot IF this turn still owns it. If a
  /// newer utterance took the slot, the seq moved on and the stale
  /// teardown must not stomp the new owner's state. A SOFT detach keeps
  /// the elapsed clock (same rule as [detach] step 7): zeroing it here
  /// is what froze the bottom line's age at 0s for a press over a
  /// tool-only turn (+126).
  void releaseOwnership(int mySeq) {
    if (_seq != mySeq) return;
    _busy = false;
    if (!_backgrounded) _since = null;
  }

  /// Teardown: hand back the pump slot, IF this loop still owns it (an
  /// abandoned turn may be cleaned up after a successor turn has
  /// already installed its own subscription and wake hook).
  bool releasePumpIf(BridgeTurnPump pump) {
    final ours = identical(_pump, pump);
    if (ours) _pump = null;
    return ours;
  }

  /// Install the live /talk listener in the shared slot.
  void installPump(BridgeTurnPump pump) {
    _pump = pump;
  }
}
