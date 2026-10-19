// Guards for the projection: AssistantView is the ONLY thing the
// conversation screens render, so every rule that used to live in a
// widget (spinner visibility, pin card, background row dismissal,
// activity wording) is asserted here as a data difference — no device,
// no pumpWidget. The screen itself is smoke-tested in ui_widgets_test.

import 'dart:typed_data';

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

  setUp(() {
    time = FakeScheduler(DateTime(2026, 1, 1, 12));
    engine = FakeSpeechEngine();
    harness = FakeHarness();
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

  group('idle truths', () {
    test('the at-rest line is the idle HINT, derived from mode — the '
        'same snapshot renders differently for each mode', () async {
      // Models not loaded yet: cold start has its own line.
      expect(a.view.status, 'Loading models…');
      expect(a.view.phase, AssistantPhase.idle);
      expect(a.view.error, isEmpty);
      expect(a.view.chat, isEmpty);
      expect(a.view.queued, isNull);
      expect(a.view.backgrounded.visible, isFalse);
      expect(a.view.showBackgroundedRow, isFalse);
      expect(a.view.sessionId, isNull);
      expect(a.view.context.label, 'context · measuring…');
      expect(a.view.token.meter(7), '7s');
    });

    test('the status line speaks activity, not prose: flipping the mode '
        'flips the hint through the projection', () async {
      a.setMode(InteractionMode.pushToTalk);
      // setMode funnels through the idle transition (a worker exists in
      // this fixture), and the idle HINT re-renders per mode: the same
      // Activity, a different line. Tests assert on the Activity;
      // rewording is no longer a behavior change.
      expect(a.view.activity, isA<IdleHint>());
      expect(a.view.status, 'Ready. Hold the button, speak, release to send.');
    });
  });

  group('a running bridge turn, seen as data', () {
    test(
      'a polite-queue press surfaces as the pin card with its stamp',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('busy turn'));
        await settle();
        unawaited(
          a.runQuickCommand('parked', bubble: 'parked', interrupt: false),
        );
        await settle();
        final v = a.view;
        expect(v.queued?.text, 'parked');
        expect(v.queued!.createdMs, greaterThan(0));
        expect(v.chat.where((e) => e.queued), hasLength(1));
      },
    );

    test('a Bash step is a StepLine on the view — the COMMAND itself, '
        'formatted at the projection edge', () async {
      await withBridge();
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'Bash',
          detail: 'flutter test --plain-output',
        ),
      );
      await settle();
      expect(a.view.activity, isA<StepLine>());
      expect(a.view.status, 'Bash flutter test --plain-output…');
    });

    test('a detached turn lights the badge, names the work, and keeps '
        'the spinner through the press (+91/+126 as view data)', () async {
      await withBridge();
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'npm test'),
      );
      await settle();
      a.setMode(InteractionMode.pushToTalk);
      a.pttDown(const Offset(0, 0)); // the press that detaches
      await settle();
      final v = a.view;
      expect(v.harnessBackgrounded, isTrue);
      expect(
        v.showBackgroundedRow,
        isFalse,
        reason:
            '+146: the press alone never lights the banner — no '
            'blink; the probe verdict decides',
      );
      expect(
        v.backgrounded.label,
        isEmpty,
        reason: 'the label rides the row: dark while pending',
      );
      expect(
        v.showWorkingRow,
        isTrue,
        reason:
            'the press must not hide the spinner it proved wrong '
            '(+151: the box the pin could once steal is now the '
            'channel\u2019s own bottom row — nothing to move)',
      );
      expect(
        v.spinnerVisible,
        isTrue,
        reason: 'the work IS open: elapsed > 0 while it runs unheard',
      );
      expect(
        v.harnessElapsed,
        Duration.zero,
        reason: 'the press re-anchored nothing — age still counts the WORK',
      );
      // The whole hold stays honest: the probe's steal-back defers
      // under the finger (+52), the verdict stays pending, the banner
      // never blinks — while the spinner's clock keeps counting the
      // WORK from the detach (+91). What the release decides (discard
      // lights, queue re-ears, cut rides the wire promise) is pinned
      // by the banner-law tests in turn_flow.
      time.advance(const Duration(seconds: 30));
      await settle();
      expect(
        harness.attachCount,
        0,
        reason: 'no steal-back stomps a live hold',
      );
      expect(a.view.harnessBackgrounded, isTrue);
      expect(
        a.view.showBackgroundedRow,
        isFalse,
        reason: 'still pending: dark through the whole hold',
      );
      expect(
        a.view.harnessElapsed,
        const Duration(seconds: 30),
        reason: 'the age counts the work, not the press',
      );
    });

    test('a detached turn behind a new prompt: the pickup ack dismisses '
        'the row and re-anchors the clock', () async {
      await withBridge();
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'npm test'),
      );
      await settle();
      a.setMode(InteractionMode.pushToTalk);
      a.pttDown(const Offset(0, 0)); // detaches into the background
      await settle();
      expect(
        a.view.showBackgroundedRow,
        isFalse,
        reason: '+146: the press alone never lights the banner',
      );
      // The probe's steal-back defers under the finger (the +52
      // no-stomp rule): nothing is decided while the mic is open.
      time.advance(const Duration(milliseconds: 600));
      await settle();
      a.pttUp(const Offset(300, 0)); // SLIDE-RIGHT discard resolves the
      await settle(); // verdict: genuinely out of the ear now
      expect(
        a.view.showBackgroundedRow,
        isTrue,
        reason: 'the banner lights on the DISCARD — not the press',
      );
      // The next prompt rides a fresh view; the bridge's receipt of the
      // detached work lands on it, and the row dismisses itself.
      unawaited(a.runQuickCommand('follow-up', bubble: 'follow-up'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'started', detail: 'follow-up'),
      );
      await settle();
      expect(a.view.showBackgroundedRow, isFalse);
      expect(a.view.backgrounded.label, isEmpty);
    });

    test("+133: the agent's OWN backgrounded shell lights the row — "
        'no press was ever involved', () async {
      // The warrant the screen law once forgot: a `backgrounded`
      // frame sets coordinator state while the badge stays dark and
      // no pin rides — the row must still appear on the bridge's own
      // word, and go when the finished receipt pays it.
      await withBridge();
      unawaited(a.runQuickCommand('start a sleep'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'backgrounded',
          detail: 'Bash sleep 20',
        ),
      );
      await settle();
      expect(a.view.harnessBackgrounded, isFalse);
      expect(a.view.queued, isNull, reason: 'nobody queued anything');
      expect(a.view.showBackgroundedRow, isTrue);
      expect(a.view.backgrounded.label, 'Bash sleep 20');
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'Bash sleep 20',
        ),
      );
      await settle();
      expect(a.view.showBackgroundedRow, isFalse);
    });

    test('+164: a parked drain keeps row and brake lit through the '
        'on-air chunk — the blink was the bug', () async {
      // The fold's visible seam: the steered follow-on is born AFTER
      // the re-stamped done, so the heard turn closed while the
      // answer to THIS phone's prompt was still owed (missed>0) and
      // the drain sat parked behind on-air audio (+124). The row went
      // dark, blinked on the drain, went dark again — over work that
      // was indeed still running. The owed reply is now the third
      // form of in-flight work.
      await withBridge();
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'turnOpen': false, 'missed': 2, // the steered follow-on, unheard
      };
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'say',
          text: 'Done — the sleep finished cleanly.',
          mid: 40,
        ),
      );
      await settle();
      expect(out.playing, isTrue, reason: 'the chunk is on the speaker');
      harness.emit(const BridgeEvent.forTest('done'));
      await settle();
      final v = a.view;
      expect(v.drainOwed, isTrue, reason: 'missed>0 with audio on air: parked');
      expect(v.agentBusy, isTrue,
          reason: 'the owed reply keeps the BRAKE lit (+164)');
      expect(
        v.showWorkingRow,
        isFalse,
        reason: '+167 supersedes the row half of +164: the agent is '
            'done (done clean closed it) and only the phone speaks — '
            'the box shows agent status, TTS is independent of it. '
            'A real follow-on turn lights the box itself via ATTACH.',
      );
      // The lit brake must LAND: silence, drop the owed second look.
      a.bridgeStop();
      await settle();
      expect(a.view.drainOwed, isFalse, reason: 'skip chosen, debt dropped');
      expect(out.stopCount, greaterThan(0), reason: 'the press silenced it');
      expect(a.phase, AssistantPhase.idle);
    });

    test('+166: muting TTS closes the drain debt — the brake is '
        'independent of the voice switch, it never waits on it', () async {
      // The field report: 'when I press TTS, the Stop chip lights up —
      // the chips should be independent of the TTS button.' The press
      // was not the cause; the +164 projection exposed the culprit.
      // A parked drain (+124) resolves at the speaker's NATURAL END,
      // and a TTS-off world has no speaker — the owed reply could
      // never arrive, and the brake stayed lit forever over work with
      // no ear. Mute must now mean: silence, and settle the debt via
      // the silent drain.
      await withBridge();
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'turnOpen': false, 'missed': 2,
      };
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'say',
          text: 'On the speaker when you muted.',
          mid: 42,
        ),
      );
      await settle();
      harness.emit(const BridgeEvent.forTest('done'));
      await settle();
      expect(a.view.drainOwed, isTrue, reason: 'parked behind live audio');
      a.setBridgeTts(false);
      await settle(); // let the unawaited drain reach _chain.start
      time.advance(const Duration(milliseconds: 100)); // the chain's
      // zero-delay first probe rides the fake clock, not microtasks
      await settle();
      expect(
        out.stopCount,
        greaterThan(0),
        reason: 'mute means silence NOW — the on-air chunk dies',
      );
      expect(
        a.view.drainOwed,
        isFalse,
        reason: 'the debt is CLOSED by the press, not orphaned by it',
      );
      expect(
        harness.attachCount,
        greaterThan(0),
        reason: 'and honoured: the mute world drains via reattach at '
            'once (frames file as text; the lit brake is now the real '
            'reattach, not a stranded promise)',
      );
    });

    test('+165: a settled turn hides the row — rendering audio is not '
        'agent status — and the owed drain re-lights it after the close',
        () async {
      // The field sequence of the steered exchange: the host's text
      // settles (message_stop, no tool open), the farewell closes the
      // turn, and the answer to THIS phone's prompt is born a beat
      // later in the follow-on. The box belongs to the agent: while
      // only the phone's TTS pipeline remained, the row showed a
      // frozen wheel captioned 'Rendering audio…' — the speaker's
      // queue inside the agent's status slot.
      await withBridge();
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'turnOpen': false, 'missed': 2,
      };
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          toolKind: 'settled',
          outTokens: 800,
          inputTokens: 5000,
          draft: 'Done — the sleep finished cleanly.',
        ),
      );
      await settle();
      expect(a.turnSettled, isTrue);
      expect(
        a.view.agentBusy,
        isTrue,
        reason: 'the turn is open — the wire has not closed yet',
      );
      expect(
        a.view.showWorkingRow,
        isFalse,
        reason: 'but nothing computes: settled means only the speaker '
            'is left, and TTS is independent of the box (+165)',
      );
      harness.emit(
        const BridgeEvent.forTest(
          'say',
          text: 'Done — the sleep finished cleanly.',
          mid: 41,
        ),
      );
      harness.emit(const BridgeEvent.forTest('done'));
      await settle();
      expect(a.view.token.settled, isFalse,
          reason: 'the rendering verdict died with the wire');
      expect(a.view.drainOwed, isTrue, reason: 'the +164 debt is owed');
      expect(
        a.view.agentBusy,
        isTrue,
        reason: 'it keeps the BRAKE lit — pressing it silences the tail',
      );
      expect(
        a.view.showWorkingRow,
        isFalse,
        reason: '+167: but the box shows AGENT status — the agent '
            'closed the turn; the owed tail is the phone\'s own '
            'playback, and a real follow-on lights the box itself',
      );
    });

    test(
      'the live tally projects as numbers + settled + thought tail',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('think'));
        await settle();
        harness.emit(
          BridgeEvent.forTest(
            'tool',
            toolName: 'tokens',
            toolKind: 'thinking',
            outTokens: 1200,
            inputTokens: 21000,
            thought: 'weighing the two splits',
          ),
        );
        await settle();
        final t = a.view.token;
        expect(t.on, isTrue);
        expect(t.out, greaterThanOrEqualTo(1200));
        expect(t.thought, 'weighing the two splits');
        expect(t.activityLabel, 'Thinking…');
        expect(t.meter(12), contains('1.20k out'));
        // The context BAR is fed by context frames (and /health), not by
        // tally relays — the tally's `in` only anchors the meter delta.
        harness.emit(
          BridgeEvent.forTest(
            'context',
            inputTokens: 21000,
            contextWindow: 200000,
          ),
        );
        await settle();
        expect(a.view.context.tokensIn, 21000);
        expect(a.view.context.label, contains('21.00k / 200.00k'));
      },
    );
  });

  group('the mic level the talk surface breathes with', () {
    // PCM16 of a steady ±8192 wave: float ±0.25, RMS 0.25 → ×4 = 1.0.
    Uint8List loudBytes(int samples) {
      final b = Uint8List(samples * 2);
      for (var i = 0; i < samples; i++) {
        final v = i.isEven ? 0x2000 : 0xE000; // ±8192
        b[i * 2] = v & 0xFF;
        b[i * 2 + 1] = (v >> 8) & 0xFF;
      }
      return b;
    }

    test('raw PTT chunks meter into the view; the release zeroes it', () async {
      a.setMode(InteractionMode.pushToTalk);
      await a.toggle(); // opens the mic (PTT branch)
      await settle();
      expect(a.view.ptt.micLevel, 0, reason: 'still water at rest');

      mic.emit(loudBytes(1600)); // 100 ms of solid tone
      await settle();
      expect(
        a.view.ptt.micLevel,
        greaterThan(0.5),
        reason: 'fast attack: one chunk of tone lights the meter',
      );

      a.toggle(); // the second toggle closes the hold: mic down, level zeroed
      await settle();
      expect(
        a.view.ptt.micLevel,
        0,
        reason: 'no stream, no level — never a frozen wave',
      );
    });
  });

  group('the spinner visibility law (moved out of the widget)', () {
    test('pure playback hides the wheel; an open turn keeps it through '
        'its own voice', () async {
      await withBridge();
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.emit(BridgeEvent.forTest('say', text: 'Spoken answer.'));
      await settle();
      // First word just landed on the speaker and the turn is still
      // OPEN on the wire: the wheel keeps spinning through its own
      // voice (+151: the law reads the turn flags directly — the old
      // elapsed-clock proxy froze the wheel for a tick every time a
      // pickup re-anchored the age, on work verifiably still running).
      expect(a.view.phase, AssistantPhase.speaking);
      expect(a.view.spinnerVisible, isTrue);
      time.advance(const Duration(seconds: 1));
      expect(a.view.spinnerVisible, isTrue);
      harness.emit(BridgeEvent.forTest('done')); // the wire closes MID-VOICE
      await settle(); // (the +124 shape: the answer's tail is still on air)
      expect(
        a.view.phase,
        AssistantPhase.speaking,
        reason: 'a spoken answer keeps the bubble speaking',
      );
      expect(
        a.view.harnessElapsed,
        Duration.zero,
        reason: 'the done released the clock',
      );
      expect(
        a.view.spinnerVisible,
        isFalse,
        reason: 'pure playback IS the status: voice is the readout',
      );
      out.complete(); // the tail gets its honest end
      await settle();
    });
  });
}

void unawaited(Future<void> f) {}
