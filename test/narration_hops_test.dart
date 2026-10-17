// The narration gate (the 8 s reply outrank and the 45 s heartbeat) and
// the hop pulse tracker (the latency strip's flow arrows).
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/hop_tracker.dart';
import 'package:voice_agent/src/assistant/narration_gate.dart';
import 'package:voice_agent/src/common/sinks.dart';

void main() {
  late FakeScheduler time;
  late NarrationGate gate;

  bool narrationOn({bool speaking = false, bool playing = false}) =>
      gate.quiet(
        enabled: true,
        backgrounded: false,
        speaking: speaking,
        playing: playing,
      );

  setUp(() {
    time = FakeScheduler(DateTime(2026, 1, 1, 12));
    gate = NarrationGate(clock: () => time.now);
  });

  group('narration gate', () {
    test('a fresh turn is never quiet enough to narrate immediately', () {
      gate.audioActivity(); // turn start stamps the clock
      expect(narrationOn(), isFalse);
      time.advance(const Duration(seconds: 7));
      expect(narrationOn(), isFalse);
      time.advance(const Duration(seconds: 2));
      expect(narrationOn(), isTrue);
    });

    test('while our reply plays or synthesises, the ears are taken', () {
      time.advance(const Duration(seconds: 10));
      expect(narrationOn(speaking: true), isFalse);
      expect(narrationOn(playing: true), isFalse);
    });

    test('narrating a line restarts both windows (+anti-machine-gun)',
        () async {
      time.advance(const Duration(seconds: 10));
      expect(gate.wantStep('Edit a.dart…',
          enabled: true, backgrounded: false, speaking: false,
          playing: false), isTrue);
      gate.narrated('Edit a.dart…');
      gate.audioActivity(); // narration speaks through the reply path
      expect(narrationOn(), isFalse,
          reason: 'ten Edit calls in a row must not gun the speaker');
      time.advance(const Duration(seconds: 9));
      expect(narrationOn(), isTrue);
    });

    test('the same step only repeats as a ~45 s heartbeat', () {
      time.advance(const Duration(seconds: 10));
      gate.narrated('Bash gradle build…');
      // A repeat right away: not yet (quiet() itself also blocks it).
      expect(
        gate.wantHeartbeat('Bash gradle build…',
            enabled: true, backgrounded: false, speaking: false,
            playing: false),
        isFalse,
      );
      // A different line, once quiet, is news again immediately.
      gate.audioActivity();
      time.advance(const Duration(seconds: 9));
      expect(
        gate.wantStep('Bash gradle test…',
            enabled: true, backgrounded: false, speaking: false,
            playing: false),
        isTrue,
      );
      // And the same long build: after 45 s of nothing but it, repeat.
      time.advance(const Duration(seconds: 40));
      expect(
        gate.wantHeartbeat('Bash gradle build…',
            enabled: true, backgrounded: false, speaking: false,
            playing: false),
        isTrue,
        reason: 'one gradle build = a steady still-at-it cadence',
      );
    });

    test('the off switch off kills everything', () {
      time.advance(const Duration(minutes: 5));
      expect(
        gate.wantStep('Deploy…',
            enabled: false, backgrounded: false, speaking: false,
            playing: false),
        isFalse,
      );
      expect(
        gate.wantHeartbeat('Deploy…',
            enabled: false, backgrounded: true, speaking: false,
            playing: false),
        isFalse,
      );
    });
  });

  group('hop tracker', () {
    test('a hop lights for the pulse window, then fades itself', () {
      var repaints = 0;
      final hops = HopTracker(
        clock: () => time.now,
        scheduler: time,
        repaint: () => repaints++,
      );
      expect(hops.hopAsr, isFalse);
      hops.asr();
      expect(hops.hopAsr, isTrue);
      expect(repaints, 1);

      time.advance(const Duration(milliseconds: 400));
      hops.reply(); // a newer hop restamps the shared fade timer
      expect(hops.hopAsr, isTrue); // its own window is still open
      expect(repaints, 2);

      time.advance(const Duration(milliseconds: 400)); // asr: 800 ms old
      expect(hops.hopAsr, isFalse, reason: 'expired arrow, back to grey');
      expect(hops.hopReply, isTrue, reason: 'the newer one lives on');

      time.advance(const Duration(milliseconds: 400)); // reply: 800 ms
      expect(hops.hopReply, isFalse);
      // Exactly three repaints: two pulses + the shared fade. Any hop
      // firing re-arms the ONE fade timer (the asr fade was replaced by
      // the reply's), so a pulse that goes dark behind a newer one
      // never pays its own repaint.
      expect(repaints, 3);
      hops.dispose();
    });
  });
}
