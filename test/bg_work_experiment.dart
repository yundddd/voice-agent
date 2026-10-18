// Experiments on the detached-tool-call visualization (+125, corrected by
// the +126 field report). Each probe drives the real state machine over
// the scripted fakes and DUMPS what every UI surface would render, to
// walk the report back: "spinner box empty, my press pinned under it,
// the background Bash line under that — I expected the press to show
// right away."
//
// The three findings the first run produced, now pinned as regressions:
//  1. The /talk pump's finally zeroed _harnessSince unconditionally,
//     even for the soft detach that intends to keep it — the card named
//     the step forever at a frozen 0s with no 'since'.
//  2. A queued press re-anchored the age to ITS dispatch — the line
//     aged the press, not the work.
//  3. The pin rule parked presses behind DETACHED work too: the press
//     vanished from the flow to protect an answer no ear held. Presses
//     behind unheard work now show immediately; the bottom line carries
//     the wait (the badge survives the dispatch until a pickup ack,
//     /stop, or a nothing-open probe retires it).
//
// Run with:
//   flutter test test/bg_work_experiment.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/assistant.dart';
import 'package:voice_agent/src/common/sinks.dart';
import 'package:voice_agent/src/platform/audio_output.dart';

import 'support/fakes.dart';

Future<void> settle({int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeScheduler time;
  late FakeSpeechEngine engine;
  late FakeHarness harness;
  late FakeMic mic;
  late FakeAudioOutput out;
  late VoiceAssistant a;

  setUp(() async {
    time = FakeScheduler(DateTime(2026, 10, 17, 16, 44, 0));
    engine = FakeSpeechEngine();
    harness = FakeHarness();
    // The fake CLAIMS the open turn by default: a /health without
    // turnOpen means "nothing open", and the ladder's first probe
    // legitimately retires the badge. Tests that want retirement flip
    // this or leave it to the finger-down suppress.
    harness.healthState = {'ok': true, 'claudeUp': true, 'turnOpen': true};
    mic = FakeMic();
    out = FakeAudioOutput();
    a = VoiceAssistant(
      worker: engine,
      micSource: mic,
      audioOutput: out,
      gatewayFactory: (_, _) => harness,
      scheduler: time,
      clock: () => time.now,
    );
    engine.onEvent = a.debugSpeechEvents;
  });

  tearDown(() => a.dispose());

  Future<void> withBridge() async {
    await a.setBridge(url: 'http://harness.test', token: 'tok');
    await settle();
  }

  void dump(String when) {
    // ignore: avoid_print
    print('┌─ $when');
    // ignore: avoid_print
    print('│ status      : "${a.status}"');
    // ignore: avoid_print
    print(
      '│ phase       : ${a.phase.name}  busy=${a.bridgeBusy}  '
      'badge=${a.harnessBackgrounded}',
    );
    // ignore: avoid_print
    print(
      '│ line        : "${a.backgroundedWork}" '
      '· ${a.harnessElapsed.inSeconds}s · since ${a.harnessSinceMs}',
    );
    // ignore: avoid_print
    print('│ pin         : "${a.queuedText}"');
    // ignore: avoid_print
    print(
      '│ chat        : ${a.chat.map((e) => '${e.fromUser ? 'user' : 'asst'}'
          '${e.queued ? '(pinned)' : ''}[${e.blocks.length}]').join(' ')}',
    );
    // ignore: avoid_print
    print('└─');
  }

  /// 'go' -> Bash step -> barge-in press, finger stays DOWN (the press
  /// of the field report). Returns the epoch the detached work began.
  Future<int> detachOverBash() async {
    await withBridge();
    unawaited(a.runQuickCommand('go'));
    await settle();
    harness.emit(
      BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'sleep 60'),
    );
    await settle();
    final started = a.harnessSinceMs;
    a.setMode(InteractionMode.pushToTalk);
    a.pttDown(Offset.zero);
    await settle();
    return started;
  }

  test('field repro: the detached line AGES (was frozen at 0s)', () async {
    final started = await detachOverBash();
    dump('after the detach press');
    expect(started, isNonZero, reason: 'dispatch armed the spinner clock');
    expect(
      a.harnessSinceMs,
      started,
      reason:
          'the /talk finally must not zero what the detach keeps '
          '(+126: the card sat at 0s forever)',
    );
    expect(a.backgroundedWork, 'Bash sleep 60…');

    time.advance(const Duration(seconds: 47));
    await settle();
    dump('47 s into the detached sleep (finger still down)');
    expect(
      a.harnessBackgrounded,
      isTrue,
      reason:
          'finger-down suppresses the ladder reattach; the badge '
          'proves the work still runs',
    );
    expect(a.harnessElapsed, const Duration(seconds: 47));
  });

  test(
    'a polite press behind detached work shows in the flow immediately',
    () async {
      final started = await detachOverBash();
      time.advance(const Duration(seconds: 47));
      unawaited(
        a.runQuickCommand(
          'cute message',
          bubble: 'cute message',
          interrupt: false,
        ),
      );
      await settle();
      dump('the press the field report wanted visible');
      expect(
        a.queuedText,
        isNull,
        reason: 'nothing audible to protect — no pin (+126)',
      );
      final user = a.chat.where((e) => e.fromUser).last;
      expect(user.queued, isFalse, reason: 'the bubble rides the flow at once');
      expect(
        a.backgroundedWork,
        'Bash sleep 60…',
        reason: 'the bottom line keeps carrying the wait',
      );
      expect(
        a.harnessSinceMs,
        started,
        reason: 'the age counts the WORK, not the latest press',
      );
      expect(a.harnessElapsed, const Duration(seconds: 47));
    },
  );

  test('the pickup ack retires the line and re-ages the heard turn', () async {
    await detachOverBash();
    time.advance(const Duration(seconds: 47));
    unawaited(
      a.runQuickCommand(
        'cute message',
        bubble: 'cute message',
        interrupt: false,
      ),
    );
    await settle();
    harness.emit(
      BridgeEvent.forTest('tool', toolName: 'started', detail: 'cute message'),
    );
    await settle();
    time.advance(const Duration(seconds: 5)); // age the re-anchored clock
    await settle();
    dump('pickup ack: the bash proved closed');
    expect(a.backgroundedWork, isEmpty);
    expect(a.harnessBackgrounded, isFalse);
    expect(
      a.harnessElapsed,
      const Duration(seconds: 5),
      reason: 'the spinner now times OUR turn from the ack',
    );
  });

  test('/stop blanks the line', () async {
    await detachOverBash();
    a.bridgeStop();
    await settle();
    expect(a.backgroundedWork, isEmpty);
    expect(a.harnessBackgrounded, isFalse);
  });

  test('a nothing-open ladder probe retires the line', () async {
    await detachOverBash();
    harness.healthState = {'ok': true, 'claudeUp': true, 'turnOpen': false};
    time.advance(const Duration(seconds: 1)); // fire the armed probe
    await settle();
    expect(
      a.harnessBackgrounded,
      isFalse,
      reason: 'the bridge said nothing is open — the badge must not lie',
    );
    expect(a.backgroundedWork, isEmpty);
  });

  test('a pin behind an AUDIBLE turn still works (unchanged rule)', () async {
    await withBridge();
    unawaited(a.runQuickCommand('go'));
    await settle();
    harness.emit(
      BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'npm test'),
    );
    await settle();
    unawaited(
      a.runQuickCommand(
        'polite follow-up',
        bubble: 'polite follow-up',
        interrupt: false,
      ),
    );
    await settle();
    expect(
      a.queuedBubble,
      isNotNull,
      reason: 'an in-ear answer is still worth queueing behind',
    );
    harness.emit(
      BridgeEvent.forTest(
        'tool',
        toolName: 'started',
        detail: 'polite follow-up',
      ),
    );
    await settle();
    expect(a.queuedBubble, isNull);
    expect(a.backgroundedWork, isEmpty);
  });
}
