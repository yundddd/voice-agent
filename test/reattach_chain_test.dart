// Unit guards for the reattach retry ladder (reattach_chain.dart): the
// ~63 s of network-wake grace, the probe verdicts, the zombie-only
// retirement, and the +52 rule that an orphan must never idle-stomp a
// finger that is down. The integration shapes live in turn_flow_test.dart
// (zombie wire hop); this pins the ladder ITSELF on a fake clock.

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/activity.dart';
import 'package:voice_agent/src/assistant/reattach_chain.dart';
import 'package:voice_agent/src/common/sinks.dart';

class ChainProbe {
  ChainProbe(this.scheduler);

  final FakeScheduler scheduler;
  bool canProbe = true, busy = false, pointers = false;
  int generation = 1, seq = 1;
  Map<String, Object>? Function() health = () => null;

  /// What reattach() answers (and how often it was asked).
  bool reattachResult = true;
  int reattachAsked = 0;
  Map<String, Object>? lastHealth;

  final List<String> logs = [];
  final List<Activity> statuses = [];
  int retires = 0, idles = 0, repaints = 0;

  ReattachEnv get env => ReattachEnv(
    canProbe: () => canProbe,
    busy: () => busy,
    generation: () => generation,
    turnSeq: () => seq,
    pointersDown: () => pointers,
    probe: () async => health(),
    noteHealth: (h) =>
        h == null ? 'UNREACHABLE' : 'turnOpen=${h['turnOpen'] == true}',
    reattach: (h) async {
      reattachAsked++;
      lastHealth = h;
      return reattachResult;
    },
    retireWork: () => retires++,
    idleReady: () => idles++,
    setStatus: statuses.add,
    log: logs.add,
    repaint: () => repaints++,
  );

  /// Settle the microtasks the probes park on BEFORE moving the fake
  /// clock (an un-settled re-arm schedules against an already-advanced
  /// now and skews the ladder), then fire due timers, then settle again.
  Future<void> advance(Duration d) async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    scheduler.advance(d);
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

void main() {
  late FakeScheduler time;
  late ChainProbe p;
  late ReattachChain chain;

  setUp(() {
    time = FakeScheduler(DateTime(2026, 1, 1, 12));
    p = ChainProbe(time);
    chain = ReattachChain(scheduler: time, env: p.env);
  });

  group('the ladder', () {
    test('an unreachable bridge re-probes up the full backoff, never '
        'dropping the turn on one failed probe', () async {
      p.health = () => null;
      chain.start(gen: 1, seq: 1);
      await p.advance(Duration.zero);
      expect(p.logs.single, contains('1/5: UNREACHABLE → UNREACHABLE'));
      for (final rung in [2, 6, 15, 40]) {
        await p.advance(Duration(seconds: rung - 1)); // one second short
        expect(p.logs.length, greaterThanOrEqualTo(1));
        await p.advance(const Duration(seconds: 1));
      }
      expect(p.logs.last, contains('5/5:'));
      expect(p.retires, 0, reason: 'not a zombie chain: nothing to retire');
      expect(p.idles, 0);
    });

    test(
      'a spent ladder ends the chain (no timer survives the last rung)',
      () async {
        p.health = () => null;
        chain.start(gen: 1, seq: 1);
        await p.advance(const Duration(seconds: 2)); // probe 2
        await p.advance(const Duration(seconds: 6)); // probe 3
        await p.advance(const Duration(seconds: 15)); // probe 4
        await p.advance(const Duration(seconds: 40)); // ladder spent
        expect(p.logs.length, 5);
        expect(time.pendingCount, 0);
      },
    );

    test(
      'a live turn claimed the slot mid-probe: the chain bows out',
      () async {
        p.busy = true;
        chain.start(gen: 1, seq: 1);
        await p.advance(Duration.zero);
        expect(p.logs, isEmpty, reason: 'not even a probe was worth paying');
        expect(time.pendingCount, 0);
      },
    );
  });

  group('the verdicts', () {
    test('an open turn ATTACHes, and success ends the chain', () async {
      p.health = () => {'turnOpen': true};
      chain.start(gen: 1, seq: 1);
      await p.advance(Duration.zero);
      expect(p.logs.single, contains('→ ATTACH'));
      expect(p.reattachAsked, 1);
      expect(
        p.lastHealth,
        {'turnOpen': true},
        reason:
            'the probe already in hand rides into the attach — one '
            'health read per rung, not two',
      );
      expect(
        time.pendingCount,
        0,
        reason:
            'the reattached turn owns its '
            'own watchdog from here',
      );
    });

    test('a declined ATTACH climbs a rung and tries again', () async {
      p.health = () => {'turnOpen': true};
      p.reattachResult = false; // hidden / bench in the way
      chain.start(gen: 1, seq: 1);
      await p.advance(Duration.zero);
      expect(p.reattachAsked, 1);
      await p.advance(const Duration(seconds: 2));
      expect(p.reattachAsked, 2);
      expect(p.logs.last, contains('2/5:'));
    });

    test('nothing open, nothing unheard: go idle — and a ZOMBIE chain '
        'also retires the spinner', () async {
      p.health = () => {'turnOpen': false, 'missed': 0};
      chain.start(gen: 1, seq: 1, retire: true);
      await p.advance(Duration.zero);
      expect(p.logs.first, contains('nothing open, nothing unheard'));
      expect(p.retires, 1);
      expect(p.idles, 1);
      expect(p.statuses.single, isA<StatusText>());
      expect(p.logs, contains(contains('ORPHAN retired')));
    });

    test(
      'a NON-zombie chain does not retire a spinner it never hopped',
      () async {
        p.health = () => {'turnOpen': false, 'missed': 0};
        chain.start(gen: 1, seq: 1);
        await p.advance(Duration.zero);
        expect(p.retires, 0);
        expect(p.idles, 0);
      },
    );

    test('an unheard backlog qualifies for reattach too', () async {
      p.health = () => {'turnOpen': false, 'missed': 4};
      chain.start(gen: 1, seq: 1);
      await p.advance(Duration.zero);
      expect(p.logs.single, contains('→ ATTACH'));
      expect(p.reattachAsked, 1);
    });
  });

  group('the +52 stomp guard', () {
    test(
      'a finger DOWN: the badge retires but the phase is left alone',
      () async {
        p.pointers = true;
        p.health = () => {'turnOpen': false, 'missed': 0};
        chain.start(gen: 1, seq: 1, retire: true);
        await p.advance(Duration.zero);
        expect(
          p.retires,
          1,
          reason: 'retired work is not background work any more',
        );
        expect(
          p.idles,
          0,
          reason:
              'the idle-stomp races the open mic and the release lands '
              'on "not listening" with the recording thrown away',
        );
        expect(
          p.logs,
          contains(contains('orphan retired DURING a live press')),
        );
      },
    );

    test('a story the user moved on from is not retired for it', () async {
      p.health = () => {'turnOpen': false, 'missed': 0};
      chain.start(gen: 1, seq: 1, retire: true);
      p.generation = 7; // a newer turn owns the truth now
      await p.advance(Duration.zero);
      expect(p.retires, 0);
      expect(p.idles, 0);
    });
  });

  group('re-arming', () {
    test('cancel silences the chain entirely', () async {
      p.health = () => null;
      chain.start(gen: 1, seq: 1);
      await p.advance(const Duration(seconds: 1));
      chain.cancel();
      await p.advance(const Duration(minutes: 2));
      expect(p.logs.length, 1);
      expect(time.pendingCount, 0);
    });

    test('a quieter re-arm keeps an earlier zombie\'s retirement duty '
        '(the retire flag ORs in)', () async {
      p.reattachResult = false;
      p.health = () => {'turnOpen': true};
      chain.start(gen: 1, seq: 1, retire: true);
      await p.advance(Duration.zero); // ATTACH declined, rung 1 armed
      p.health = () => {'turnOpen': false, 'missed': 0};
      chain.start(gen: 1, seq: 1); // a plain re-arm, retire omitted
      await p.advance(Duration.zero);
      expect(p.retires, 1, reason: 'the zombie duty survived the re-arm');
    });

    test('resetStep:false pays the first rung before the next probe '
        '(a dying reattach must not request-loop at RTT)', () async {
      p.health = () => null;
      chain.start(gen: 1, seq: 1, firstProbe: const Duration(seconds: 2));
      await p.advance(const Duration(seconds: 1));
      expect(p.logs, isEmpty);
      await p.advance(const Duration(seconds: 1));
      expect(p.logs.single, contains('1/5:'));
    });
  });
}
