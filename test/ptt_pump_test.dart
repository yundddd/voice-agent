// The push-to-talk hold geometry (the classifier the guide and the
// release must never disagree with) and the turn pump (the queue+wake
// plumbing both bridge loops share).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/ptt_hold.dart';
import 'package:voice_agent/src/assistant/state.dart';
import 'package:voice_agent/src/bridge/bridge_event.dart';
import 'package:voice_agent/src/bridge/gateway.dart';
import 'package:voice_agent/src/bridge/turn_pump.dart';

void main() {
  group('PttHold', () {
    late PttHold hold;
    var now = DateTime(2026, 1, 1, 12);
    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      hold = PttHold(clock: () => now);
    });

    test('slide classification is exclusive by construction', () {
      expect(hold.slideOf(const Offset(0, -50)), PttSlide.up);
      expect(hold.slideOf(const Offset(60, 0)), PttSlide.right);
      expect(
        hold.slideOf(const Offset(60, -50)),
        PttSlide.right,
        reason: 'horizontal-dominant diagonal reads as the dismiss',
      );
      expect(
        hold.slideOf(const Offset(50, -60)),
        PttSlide.up,
        reason: 'vertical-dominant diagonal reads as the interrupt',
      );
      expect(
        hold.slideOf(const Offset(60, -60)),
        PttSlide.none,
        reason: 'a true tie is neither: both rules need a dominant axis',
      );
      expect(
        hold.slideOf(const Offset(-60, -50)),
        PttSlide.none,
        reason: 'only a clear UPWARD drag cuts; leftward drift does not',
      );
      expect(
        hold.slideOf(const Offset(0, -40)),
        PttSlide.none,
        reason: 'below the 48 px thumb threshold: a rolling press',
      );
      expect(hold.slideOf(const Offset(50, 0)), PttSlide.right);
      expect(hold.slideOf(Offset.zero), PttSlide.none);
    });

    test('the armed state follows the finger and the lean quantises', () {
      expect(hold.down(const Offset(100, 100)), isTrue);
      expect(hold.move(const Offset(100, 60)), isTrue); // 40 up, not armed
      expect(hold.slide, PttSlide.none);
      expect(hold.drag, const Offset(0, -40));

      hold.move(const Offset(100, 40)); // 60 up: armed
      expect(hold.slide, PttSlide.up);

      // A 300 px flick leans no further than 72 (never dodges the thumb).
      hold.move(const Offset(400, 100));
      expect(hold.drag.dx, 72);
      // Sub-4-px jitter: no repaint churn (a 120 Hz finger stream…).
      expect(hold.move(const Offset(400, 101)), isFalse);
    });

    test(
      'a second finger does not re-arm the mic; the last release ends it',
      () {
        expect(hold.down(const Offset(0, 0)), isTrue);
        expect(hold.down(const Offset(5, 5)), isFalse);
        final r1 = hold.release(const Offset(5, 5));
        expect(r1.stray, isFalse);
        expect(hold.pointers, 1); // still holding
        final r2 = hold.release(const Offset(0, 0));
        expect(r2.stray, isFalse);
        expect(hold.pointers, 0);
      },
    );

    test('a release with no press is reported as stray, not slide', () {
      hold.down(const Offset(0, 0));
      hold.move(const Offset(0, -60)); // armed up
      final stray = hold.release(const Offset(0, -60));
      expect(stray.up, isTrue);
      expect(
        stray.redraw,
        isTrue,
        reason: 'the armed pill was on screen and must go now',
      );
      final r = hold.release(const Offset(0, -60)); // the stray twin
      expect(r.stray, isTrue);
      expect(
        r.heldMs,
        -1,
        reason:
            'held only reads true when a press was recorded (+95 '
            'nonsense-clock bug)',
      );
    });

    test('heldMs measures the real hold', () {
      hold.down(const Offset(0, 0));
      now = now.add(const Duration(milliseconds: 700));
      expect(hold.heldMs, 700);
      expect(hold.heldMs < hold.tapStopMs, isFalse); // not a tap
      now = now.add(const Duration(milliseconds: 50));
      expect(hold.release(null).heldMs, greaterThan(700));
    });
  });

  group('BridgeTurnPump', () {
    late List<BridgeEvent> seen;
    late bool stale;
    BridgeTurnPump pump() => BridgeTurnPump(
      onEvent: (ev) async => seen.add(ev),
      isStale: () => stale,
      beforeEvent: (_) {},
    );
    setUp(() {
      seen = [];
      stale = false;
    });

    test('frames queued before the loop even parks still wake it', () async {
      final ctl = StreamController<BridgeEvent>();
      final p = pump();
      final done = p.run(ctl.stream);
      // Events landing WHILE the loop is parked on the wake future —
      // the wake-on-data contract (the "parked frames" bug).
      ctl.add(BridgeEvent.forTest('say', text: 'a'));
      ctl.add(BridgeEvent.forTest('say', text: 'b'));
      await settle();
      ctl.add(BridgeEvent.forTest('done'));
      final out = await done;
      expect(seen.map((e) => e.kind).toList(), ['say', 'say', 'done']);
      expect(out.sawDone, isTrue);
      expect(out.closedWithoutDone, isFalse);
    });

    test('a done frame ends the loop even with more frames queued', () async {
      final ctl = StreamController<BridgeEvent>()
        ..add(BridgeEvent.forTest('done'))
        ..add(BridgeEvent.forTest('say', text: 'after'));
      final out = await pump().run(ctl.stream);
      expect(out.sawDone, isTrue);
      expect(seen, hasLength(1), reason: 'after-done frames are not ours');
    });

    test(
      'an error frame counts as a clean end (not a reattach orphan)',
      () async {
        final ctl = StreamController<BridgeEvent>()
          ..add(BridgeEvent.forTest('error', text: 'boom', isError: true));
        final out = await pump().run(ctl.stream);
        expect(out.sawErrorFrame, isTrue);
        expect(out.closedWithoutDone, isFalse);
      },
    );

    test(
      'a socket that dies without done is reported for the orphan triage',
      () async {
        final ctl = StreamController<BridgeEvent>();
        final p = pump();
        final done = p.run(ctl.stream);
        await settle();
        ctl.addError(BridgeException('socket died'));
        final out = await done;
        expect(out.streamError, isA<BridgeException>());
        expect(out.closedWithoutDone, isTrue);
        expect(out.detached, isFalse);
      },
    );

    test(
      'detach wakes a parked loop immediately (no next-event lottery)',
      () async {
        final ctl = StreamController<BridgeEvent>();
        final p = pump();
        final done = p.run(ctl.stream);
        await settle();
        p.detach(); // long tool run: zero frames pending
        final out = await done; // would hang awaiting the next frame
        expect(out.detached, isTrue);
        expect(out.closedWithoutDone, isTrue);
      },
    );

    test('a superseded turn exits on its own (the generation guard)', () async {
      final ctl = StreamController<BridgeEvent>();
      final p = pump();
      final done = p.run(ctl.stream);
      await settle();
      stale = true;
      ctl.add(BridgeEvent.forTest('say', text: 'late'));
      final out = await done;
      expect(out.stale, isTrue);
      expect(seen, isEmpty, reason: 'the successor owns the conversation');
    });
  });
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
