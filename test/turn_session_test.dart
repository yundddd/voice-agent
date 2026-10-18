// Unit guards for the bridge-turn truth and its single writer,
// TurnCoordinator (turn_session.dart). The orchestrator-level
// equivalents live in turn_flow_test.dart; this file pins the
// transitions THEMSELVES — the flag matrix used to be mutated from ~30
// sites and each rule here used to be enforced (or not) by hand at
// every one of them.
//
// Every test name names the rule it pins; the +126-class rules are
// called out where they live.
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/turn_session.dart';
import 'package:voice_agent/src/bridge/turn_pump.dart';
import 'package:voice_agent/src/common/clock.dart';

void main() {
  late FakeClock time;
  late List<String> logs;
  late int stops;
  late int beforeDetaches;
  late int afterDetaches;
  late bool pinned;
  late TurnCoordinator turn;

  setUp(() {
    time = FakeClock(DateTime(2026, 1, 1, 12));
    logs = [];
    stops = 0;
    beforeDetaches = 0;
    afterDetaches = 0;
    pinned = false;
    turn = TurnCoordinator(
      clock: time.call,
      log: (m) => logs.add(m),
      hardStop: () async {
        stops++;
      },
      beforeDetach: () => beforeDetaches++,
      afterDetach: () => afterDetaches++,
      queuedPin: () => pinned,
    );
  });

  group('the interrupt policy (takeoverStop)', () {
    // The table, restated: a test-side copy on PURPOSE — if the policy
    // changes, this map is forced to change with it, and a NEW trigger
    // trips the length guard below before anything else can silently
    // inherit a flavour.
    final expected = {
      TurnTrigger.voiceBargeIn: TakeoverStop.detach,
      TurnTrigger.speechResumed: TakeoverStop.detach,
      TurnTrigger.pttPress: TakeoverStop.detach,
      TurnTrigger.newUtterance: TakeoverStop.detach,
      TurnTrigger.zombieWire: TakeoverStop.detach,
      TurnTrigger.stopChip: TakeoverStop.hardStop,
      TurnTrigger.cancelTap: TakeoverStop.hardStop,
      TurnTrigger.conversationClose: TakeoverStop.hardStop,
      TurnTrigger.benchStart: TakeoverStop.hardStop,
      TurnTrigger.modeSwitch: TakeoverStop.hardStop,
    };

    test('every trigger has the flavour the table says', () {
      expect(
        TurnTrigger.values.length,
        expected.length,
        reason:
            'a new trigger must be DECIDED in takeoverStop and '
            'pinned here — never silently defaulted',
      );
      for (final t in TurnTrigger.values) {
        expect(takeoverStop(t), expected[t], reason: '$t');
      }
    });

    test(
      'spoken and pressed takeovers keep the work; stop gestures end it',
      () {
        for (final t in [
          TurnTrigger.voiceBargeIn,
          TurnTrigger.speechResumed,
          TurnTrigger.pttPress,
          TurnTrigger.newUtterance,
          TurnTrigger.zombieWire,
        ]) {
          expect(takeoverStop(t), TakeoverStop.detach, reason: '$t');
        }
        for (final t in [
          TurnTrigger.stopChip,
          TurnTrigger.cancelTap,
          TurnTrigger.conversationClose,
          TurnTrigger.benchStart,
          TurnTrigger.modeSwitch,
        ]) {
          expect(takeoverStop(t), TakeoverStop.hardStop, reason: '$t');
        }
      },
    );
  });

  group('ownership tokens', () {
    test('supersede bumps monotonically and hands back the NEW value', () {
      final g0 = turn.generation;
      expect(turn.supersede(), g0 + 1);
      expect(turn.supersede(), greaterThan(g0 + 1));
    });

    test('claimSlot returns a seq that grows per turn and lights busy', () {
      expect(turn.busy, isFalse);
      final s1 = turn.claimSlot();
      expect(turn.busy, isTrue);
      final s2 = turn.claimSlot();
      expect(s2, greaterThan(s1));
    });

    test('beginHeardTurn claims generation and slot contiguously', () {
      final claim = turn.beginHeardTurn();
      expect(claim.gen, 1);
      expect(claim.seq, 1);
      expect(turn.busy, isTrue);
      final next = turn.beginHeardTurn();
      expect(next.gen, greaterThan(claim.gen));
      expect(next.seq, greaterThan(claim.seq));
    });

    test(
      'releaseOwnership with a STALE seq is a no-op (no owner stomping)',
      () {
        final mine = turn.claimSlot();
        turn.claimSlot(); // a successor took the slot
        turn.releaseOwnership(mine);
        expect(turn.busy, isTrue, reason: 'the successor still owns the slot');
      },
    );

    test('releaseOwnership with our own seq frees the slot — and a SOFT '
        'detach keeps the elapsed clock (+126)', () {
      turn.beginHeardTurn();
      turn.markBackgrounded(); // the press detached it; the clock counts
      final since = turn.since;
      time.advance(const Duration(seconds: 5));
      turn.releaseOwnership(turn.seq);
      expect(turn.busy, isFalse);
      expect(turn.backgrounded, isTrue);
      expect(
        turn.since,
        since,
        reason: 'the age counts the WORK, not the press',
      );
    });

    test('releaseOwnership with no badge zeroes the clock', () {
      turn.beginHeardTurn();
      turn.releaseOwnership(turn.seq);
      expect(turn.since, isNull);
    });
  });

  group('detach — the funnel every takeover lands in', () {
    test('a takeover with no turn in flight is a no-op', () {
      turn.detach(TurnTrigger.pttPress);
      expect(stops, 0);
      expect(beforeDetaches, 0);
      expect(afterDetaches, 0);
      expect(logs, isEmpty);
      expect(turn.busy, isFalse);
    });

    test('a SOFT detach frees the slot, detaches the view, and never '
        'touches the gateway', () {
      final seq = turn.claimSlot();
      turn.releaseOwnership(-99); // pretend the pump slot is occupied
      turn.installPump(probePump());
      turn.detach(TurnTrigger.pttPress);
      expect(turn.busy, isFalse);
      expect(stops, 0, reason: 'a spoken takeover is a detach, never a /stop');
      expect(beforeDetaches, 1, reason: 'the reattach chain is silenced first');
      expect(
        afterDetaches,
        1,
        reason: 'the streamed player goes with the turn',
      );
      expect(turn.pump, isNull, reason: 'the view leaves the turn');
      expect(
        turn.seq,
        seq,
        reason:
            'detach releases the slot directly — '
            'releaseOwnership(-99) never ran, and only claimSlot bumps the seq',
      );
    });

    test('a SOFT detach with no badge lit blanks the snapshot and zeroes '
        'the clock — a stopped/detached-into-void step can never '
        're-surface behind a later pin', () {
      turn.claimSlot();
      turn.noteToolStep('Bash npm test…');
      turn.becomeHeard();
      time.advance(const Duration(seconds: 30));
      turn.detach(TurnTrigger.newUtterance);
      expect(turn.bgWork, isEmpty);
      expect(turn.since, isNull);
      expect(turn.backgrounded, isFalse);
    });

    test('a SOFT detach over an ALREADY backgrounded turn keeps the clock '
        'and the snapshot (+72/+126: the press must not kill the spinner '
        'the user is watching)', () {
      turn.claimSlot();
      turn.becomeHeard();
      turn.noteToolStep('Deploy eu-west-1…');
      turn.markBackgrounded();
      final since = turn.since;
      time.advance(const Duration(seconds: 42));
      turn.detach(TurnTrigger.voiceBargeIn);
      expect(turn.backgrounded, isTrue);
      expect(turn.bgWork, 'Deploy eu-west-1…');
      expect(turn.since, since, reason: 'the age keeps counting the work');
      expect(
        logs.where(
          (l) => l.contains(
            'msg bg: "Deploy eu-west-1…" keeps '
            'working unheard',
          ),
        ),
        hasLength(1),
        reason: 'the detach journals what it backgrounded, with its clock',
      );
    });

    test('a HARD stop sends /stop exactly once and blanks the snapshot', () {
      turn.claimSlot();
      turn.becomeHeard();
      turn.noteToolStep('Bash flutter test…');
      turn.detach(TurnTrigger.stopChip);
      expect(stops, 1);
      expect(turn.busy, isFalse);
      expect(turn.since, isNull);
      expect(
        turn.bgWork,
        isEmpty,
        reason:
            'the named step died with the interrupt — no stale '
            'snapshot to re-surface behind the next pin',
      );
      expect(
        logs.any(
          (l) => l.contains(
            'bridge view detached on purpose (hardStop=true, stopChip)',
          ),
        ),
        isTrue,
      );
    });

    test('the detach log names the trigger and the hardStop flavour', () {
      turn.claimSlot();
      turn.detach(TurnTrigger.voiceBargeIn);
      expect(
        logs.any(
          (l) => l.contains(
            'bridge view detached on purpose (hardStop=false, voiceBargeIn)',
          ),
        ),
        isTrue,
      );
    });
  });

  group('heard again / badge rules', () {
    test('promiseDetachedTool lights the promise (named by the newest '
        'step); a paid, blanked or badge-retired line takes it down', () {
      turn.claimSlot();
      turn.noteToolStep('Bash flutter test…');
      turn.detach(TurnTrigger.newUtterance); // badge-off detach:
      // the funnel blanks its own snapshot (+126) — the notice that
      // follows re-lights it from the step, which detach never touched
      turn.promiseDetachedTool();
      expect(turn.detachedPromise, isTrue);
      expect(
        turn.bgWork,
        'Bash flutter test…',
        reason: 'the cut tool is named by the step the turn was chewing',
      );
      // The receipt pays the promise:
      turn.clearBgWork();
      expect(turn.detachedPromise, isFalse);
      expect(turn.bgWork, isEmpty);
      // The badge-retire paths take it down with them (the harness
      // killed the tool with the turn; /health proved it):
      turn.promiseDetachedTool();
      turn.retireBadge();
      expect(turn.detachedPromise, isFalse);
      // And a clean (untagged) pickup blanks everything, promise included:
      turn.promiseDetachedTool();
      turn.heardPickup();
      expect(turn.detachedPromise, isFalse);
      expect(turn.bgWork, isEmpty);
    });

    test('becomeHeard clears the badge and re-anchors the clock', () {
      turn.markBackgrounded();
      time.advance(const Duration(minutes: 3));
      turn.becomeHeard();
      expect(turn.backgrounded, isFalse);
      expect(
        turn.since,
        time.now,
        reason: 'the spinner counts the live turn, not the old press',
      );
    });

    test('heardPickup retires the badge AND the snapshot (the pickup ack '
        'proves the waited-behind work closed)', () {
      turn.markBackgrounded();
      turn.noteToolStep('Bash npm test…');
      turn.clearLastToolStep(); // (the ack clears the live label first)
      turn.heardPickup();
      expect(turn.backgrounded, isFalse);
      expect(
        turn.bgWork,
        isEmpty,
        reason: 'a dead step can never re-surface behind a new pin',
      );
      expect(turn.lastToolStep, isEmpty);
      expect(turn.since, time.now);
    });

    test('detach records the trigger so a PRESS takeover can defer its '
        'trace to the release (+132)', () {
      turn.claimSlot();
      turn.detach(TurnTrigger.pttPress);
      expect(turn.lastTakeover, TurnTrigger.pttPress);
      expect(
        turn.lastTakeoverPolite,
        isFalse,
        reason: 'a press has no flavour yet — that is the point',
      );
      turn.claimSlot();
      turn.detach(TurnTrigger.newUtterance, polite: true);
      expect(turn.lastTakeover, TurnTrigger.newUtterance);
      expect(turn.lastTakeoverPolite, isTrue);
    });

    test('noteAgentWork names the agent\'s own task and survives a tap-stop '
        '(+133)', () {
      turn.claimSlot();
      turn.noteToolStep('Bash make');
      turn.noteAgentWork('Bash sleep 20');
      expect(turn.agentWork, isTrue);
      expect(
        turn.bgWork,
        'Bash sleep 20',
        reason: 'the line names THE step, not the last snapshot',
      );
      turn.retireBadge();
      expect(
        turn.agentWork,
        isTrue,
        reason:
            'stopping the VIEW says nothing about the agent\'s '
            'task — the debt outlives the press',
      );
      turn.clearBgWork();
      expect(
        turn.agentWork,
        isTrue,
        reason:
            '+140: dropping the SNAPSHOT says nothing about the '
            'PROCESS — the ledger outlives the line',
      );
      expect(
        turn.bgWork,
        'Bash sleep 20',
        reason: 'the line re-labels onto the owed shell',
      );
      expect(turn.payAgentDebt('Bash sleep 20'), isEmpty);
      expect(turn.agentWork, isFalse, reason: 'the NAMED receipt paid it');
      expect(turn.bgWork, isEmpty);
    });

    test('markBackgrounded lights the badge WITHOUT touching the clock', () {
      turn.beginHeardTurn();
      turn.becomeHeard();
      final since = turn.since;
      turn.markBackgrounded();
      expect(turn.backgrounded, isTrue);
      expect(turn.since, since);
    });

    test('retireBadge keeps the snapshot; retireBadgeAndWork blanks it', () {
      turn.markBackgrounded();
      turn.noteToolStep('Bash sleep 60…');
      turn.retireBadge();
      expect(turn.backgrounded, isFalse);
      expect(
        turn.bgWork,
        'Bash sleep 60…',
        reason: 'the too-short tap-stop path only proves the badge stale',
      );
      turn.retireBadgeAndWork();
      expect(turn.bgWork, isEmpty);
    });

    test('stopDetachedWork stops invisible work exactly once and clears '
        'badge, clock and snapshot', () {
      turn.markBackgrounded();
      turn.noteToolStep('Bash npm test…');
      expect(turn.stopDetachedWork(), isTrue);
      expect(stops, 1);
      expect(turn.backgrounded, isFalse);
      expect(turn.since, isNull);
      expect(turn.bgWork, isEmpty);
      expect(
        logs.any(
          (l) => l.contains(
            'user STOP: /stop sent to the DETACHED turn (badge cleared)',
          ),
        ),
        isTrue,
      );
    });

    test('stopDetachedWork with no badge lit is a polite no-op', () {
      expect(turn.stopDetachedWork(), isFalse);
      expect(stops, 0);
      expect(logs, isEmpty);
    });
  });

  group('the bottom line (noteToolStep)', () {
    test('a step labels the line behind a queue pin', () {
      pinned = true;
      turn.noteToolStep('Bash npm test…');
      expect(turn.lastToolStep, 'Bash npm test…');
      expect(turn.bgWork, 'Bash npm test…');
    });

    test('a step labels the line behind the badge, too', () {
      turn.markBackgrounded();
      turn.noteToolStep('Bash npm test…');
      expect(turn.bgWork, 'Bash npm test…');
    });

    test("clearBgWork takes the snapshot but never the live spinner's "
        'clock (a receipt about OLDER work rides a live view)', () {
      turn.beginHeardTurn();
      turn.becomeHeard();
      turn.noteToolStep('Bash npm test…'); // the work it queued behind
      final since = turn.since;
      time.advance(const Duration(seconds: 12));
      turn.clearBgWork();
      expect(turn.bgWork, isEmpty);
      expect(
        turn.since,
        since,
        reason: "the live turn's age is not the receipt's business",
      );
      expect(turn.busy, isTrue);
    });

    test('a heard, unpinned turn keeps its step out of the bottom line', () {
      turn.noteToolStep('Bash flutter test…');
      expect(turn.lastToolStep, 'Bash flutter test…');
      expect(
        turn.bgWork,
        isEmpty,
        reason: 'the label is only a promise about OUT-OF-EARSHOT work',
      );
    });
  });

  group('the pump slot', () {
    test(
      'releasePumpIf frees only the owner; a successor installs over it',
      () {
        final probe = probePump();
        turn.installPump(probe);
        expect(turn.releasePumpIf(probe), isTrue);
        expect(turn.pump, isNull);

        turn.installPump(probePump());
        expect(
          turn.releasePumpIf(probe),
          isFalse,
          reason: 'a stale teardown must not stomp a successor pump',
        );
        expect(turn.pump, isNotNull);
      },
    );
  });
}

/// Real pumps (only `detach` is ever called on them here, and that
/// behaviour is unit-guarded in ptt_pump_test.dart) — distinct instances
/// are all the ownership checks need.
BridgeTurnPump probePump() => BridgeTurnPump(
  onEvent: (_) async {},
  isStale: () => false,
  beforeEvent: (_) {},
);
