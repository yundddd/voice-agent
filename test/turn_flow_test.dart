// Integration tests for the whole VoiceAssistant state machine: every
// outer seam (models, harness, mic, speaker) is a scripted fake and time
// runs on the FakeScheduler, so the field-report regressions these tests
// name (0.1.0+72 … +95 and the queue/pin honesty rules around them) are
// now guarded at the level they actually happened — the orchestrator.
//
// Each test is titled with the behaviour it pins; the pubspec version
// where the rule was learned is in the comment.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/assistant.dart';
import 'package:voice_agent/src/common/sinks.dart';
import 'package:voice_agent/src/platform/audio_output.dart';

import 'support/fakes.dart';

/// Let all the futures the fakes just woke settle (microtask chains).
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

  (FakeScheduler, FakeSpeechEngine, FakeHarness, FakeMic, FakeAudioOutput)
  build() {
    final sched = FakeScheduler(DateTime(2026, 1, 1, 12));
    final eng = FakeSpeechEngine();
    final h = FakeHarness();
    final m = FakeMic();
    final o = FakeAudioOutput();
    return (sched, eng, h, m, o);
  }

  setUp(() async {
    (time, engine, harness, mic, out) = build();
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

  group('vanished-message class (0.1.0+80, +95)', () {
    test(
      'PTT: a release with no press says so on the status line (+95)',
      () async {
        a.setMode(InteractionMode.pushToTalk);
        a.pttUp(const Offset(10, 10)); // never went down
        expect(a.status, contains("That press didn't land"));
        expect(a.phase, AssistantPhase.idle); // never stomped a live phase
      },
    );

    test('PTT: a stray release over working machinery does not claim the '
        'machinery failed (+95 idle-only rule)', () async {
      a.setMode(InteractionMode.pushToTalk);
      engine.transcripts = ['a real sentence'];
      a.pttDown(Offset.zero);
      await settle();
      mic.emit(FakeMic.audio(10)); // enough audio for a real turn
      await settle(); // the bytes must land in the buffer before release
      a.pttUp(Offset.zero); // the real release -> transcribing/speaking
      await settle();
      a.pttUp(Offset.zero); // a stray twin over live work
      expect(
        a.status,
        isNot(contains("That press didn't land")),
        reason: 'only an idle phase may host the swallowed-press notice',
      );
    });

    test('conversation: a swallowed release dispatches the toggle itself '
        '(+80)', () async {
      a.pttUp(Offset.zero); // hold guide ate the press; the release lands
      await settle();
      expect(a.phase, AssistantPhase.listening);
      expect(mic.startCount, 1); // the tap started the conversation
      expect(
        a.debugLog.any((l) => l.contains('fallback toggle dispatch')),
        isTrue,
      );
    });

    test('every big-button tap journals its dispatch (0.1.0+79)', () async {
      await a.toggle();
      await settle();
      expect(
        a.debugLog.any(
          (l) =>
              l.contains('TOGGLE: mode=conversation phase=') &&
              l.contains('busy=false'),
        ),
        isTrue,
      );
    });
  });

  group('harness turns (0.1.0+72, +76, +85, +89, +94)', () {
    test(
      'a press over a live turn detaches it and keeps the spinner',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('what changed?'));
        await settle();
        expect(a.bridgeBusy, isTrue);
        expect(harness.viewDetached, isFalse);
        harness.emit(BridgeEvent.forTest('say', text: 'Running the tests.'));
        await settle();
        out.complete(); // the spoken block ends; the turn stays open
        await settle();

        a.setMode(InteractionMode.pushToTalk);
        a.pttDown(Offset.zero); // the barge-in press
        await settle();

        // Detached (the bridge keeps working) — not stopped (+72 rule):
        expect(a.bridgeBusy, isFalse);
        expect(
          a.harnessBackgrounded,
          isTrue,
          reason: 'the badge must stay lit while it works unheard',
        );
        expect(
          a.liveTurnBubble,
          isNotNull,
          reason: 'the work bubble must survive the press (+91)',
        );
        expect(
          harness.viewDetached,
          isTrue,
          reason: 'the phone must stop reading the old view',
        );
        expect(
          harness.stops,
          0,
          reason: 'a spoken takeover is a detach, never a /stop',
        );
      },
    );

    test(
      '+146: the banner answers the RELEASE, never the press — and a '
      'silent release over an open turn RE-EARS instead of blinking',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('go'));
        await settle();
        harness.emit(
          BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'npm test'),
        );
        await settle();
        a.setMode(InteractionMode.pushToTalk);

        // Press: detached (spinner law intact) but the banner holds.
        a.pttDown(Offset.zero);
        await settle();
        expect(a.view.harnessBackgrounded, isTrue);
        expect(
          a.view.showBackgroundedRow,
          isFalse,
          reason: 'no blink on press-down',
        );

        // Plain release, no words, turn still open: the app takes the
        // ear back (probe ATTACH) — the unheard claim expires by proof,
        // never by a banner blink.
        time.advance(const Duration(milliseconds: 600));
        a.pttUp(Offset.zero);
        await settle();
        expect(
          harness.attachCount,
          greaterThan(0),
          reason: 'silent release over an open turn re-attaches',
        );
        expect(
          a.view.showBackgroundedRow,
          isFalse,
          reason: 'heard again: never lit at all',
        );
      },
    );

    test('a backgrounded tool call keeps a persistent bottom line that '
        'dismisses when the work is proven done', () async {
      await withBridge();
      unawaited(a.runQuickCommand('go'));
      await settle();
      expect(a.backgroundedWork, isEmpty); // heard: just a live turn
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'flutter test'),
      );
      await settle();
      a.debugDetachUnheard(); // +146 seam: detached unheard — the press
      await settle(); // path itself is pinned by the banner-law test
      expect(a.harnessBackgrounded, isTrue);
      expect(
        a.backgroundedWork,
        'Bash flutter test…',
        reason: 'the bottom line names the work left out of earshot',
      );
      expect(
        a.debugLog.any((l) => l.contains('msg bg: "Bash flutter test…"')),
        isTrue,
        reason: 'the detach journals what it backgrounded, with its clock',
      );
      a.bridgeStop(); // /stop: the turn is over, proven
      await settle();
      expect(a.harnessBackgrounded, isFalse);
      expect(a.backgroundedWork, isEmpty, reason: 'the line dismisses itself');
    });

    test('a press behind an open DETACHED tool shows in the flow (the pin '
        'protects only in-ear answers, +126); the line survives on the '
        'badge and the pickup ack retires it', () async {
      await withBridge();
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'npm test'),
      );
      await settle();
      a.debugDetachUnheard(); // +146 seam: detached unheard
      await settle();
      expect(a.backgroundedWork, 'Bash npm test…');
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
        isNull,
        reason:
            'nothing audible to protect — the press shows right away '
            '(+126: the pin guards only in-ear answers)',
      );
      expect(a.chat.where((e) => e.fromUser).last.queued, isFalse);
      expect(
        a.backgroundedWork,
        'Bash npm test…',
        reason:
            'the badge still carries the wait: the tool IS still '
            'running unheard until the ack proves it closed',
      );
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'started',
          detail: 'polite follow-up',
        ),
      );
      await settle();
      expect(a.backgroundedWork, isEmpty); // auto-dismiss at delivery
      expect(a.harnessBackgrounded, isFalse);
    });

    test('tool steps update the label; plumbing steps are eyes-only', () async {
      await withBridge();
      await a.setBridgeNarrate(true);
      unawaited(a.runQuickCommand('go'));
      await settle();

      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'Bash',
          detail: 'flutter test',
          toolKind: 'calling Bash',
        ),
      );
      await settle();
      expect(a.status, 'Bash flutter test…'); // the command itself (+89)
      time.advance(const Duration(seconds: 16)); // a full heartbeat pulse
      await settle();
      expect(
        engine.synthesized.where((t) => t.contains('Bash')),
        isEmpty,
        reason: 'Bash is eyes-only (+73): no immediate line, no heartbeat',
      );

      // The first speakable step (nothing audible yet this turn):
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Deploy', detail: 'eu-west-1'),
      );
      await settle();
      expect(a.status, 'Deploy eu-west-1…');
      expect(
        engine.synthesized.any((t) => t.contains('Deploy')),
        isTrue,
        reason: 'a custom tool is news, not plumbing (+94)',
      );

      // ...and once that line is audible, the reply owns the speaker:
      // further steps go label-only until the turn's stream drains
      // (reply-audio outrank, the anti-machine-gun gate).
      harness.emit(BridgeEvent.forTest('tool', toolName: 'Notebook'));
      await settle();
      expect(a.status, 'Notebook…');
      expect(engine.synthesized.where((t) => t.contains('Notebook')), isEmpty);

      harness.emit(BridgeEvent.forTest('done'));
      await settle();
      out.complete(); // the turn's audio drains: the UI idles honestly
      await settle();

      // A FRESH turn, quiet from the start: even there, file steps are
      // label-only (+94) — immediate AND on the heartbeat.
      unawaited(a.runQuickCommand('again'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Read', detail: 'lib/foo.dart'),
      );
      await settle();
      expect(a.status, 'Read foo.dart…');
      time.advance(const Duration(seconds: 16));
      await settle();
      expect(
        engine.synthesized.where((t) => t.contains('Read')),
        isEmpty,
        reason: 'file steps are EYES ONLY (+94)',
      );
      harness.emit(BridgeEvent.forTest('done'));
      await settle();
    });

    test(
      'say frames speak cleaned text and enter the log with the audio',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('summary?'));
        await settle();

        harness.emit(
          BridgeEvent.forTest(
            'say',
            text: '**Done** — three files changed (see `pubspec.yaml`).',
          ),
        );
        await settle();
        expect(
          engine.synthesized,
          contains('Done — three files changed (see pubspec yaml).'),
        );
        // The chat bubble holds the cleaned block, not the raw markdown.
        expect(
          a.chat.last.blocks.single,
          'Done — three files changed (see pubspec yaml).',
        );
        expect(a.phase, AssistantPhase.speaking);
        expect(a.hopTts, isTrue, reason: 'the reply→audio hop lit');

        out.complete(); // the chunk ran out: the conversation idles again
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        await settle();
        expect(a.bridgeBusy, isFalse);
      },
    );

    test('a turn that ran with nothing to say is not a bubble', () async {
      await withBridge();
      unawaited(a.runQuickCommand('/compact'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      await settle();
      expect(
        a.chat.where((e) => !e.fromUser),
        isEmpty,
        reason: 'the blank bubble is taken back out of the log',
      );
      expect(a.status, contains('nothing to say'));
    });
  });

  group('the live token ticker (0.1.0+77, +84, +85, +93)', () {
    test(
      'the counter grows between relays and freezes on tool steps',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('think hard'));
        await settle();

        harness.emit(
          BridgeEvent.forTest(
            'tool',
            toolName: 'tokens',
            toolKind: 'thinking',
            outTokens: 100,
            inputTokens: 4000,
            wireMs: 1,
          ),
        );
        await settle();
        expect(a.tokenTickerOn, isTrue);
        expect(a.activityLabel, 'Thinking…'); // words only (+85)
        expect(a.tokensOut, 100);

        // The first relay can teach nothing (no previous point); a step-up
        // a second later learns the rate — and then the estimate grows.
        time.advance(const Duration(seconds: 1));
        harness.emit(
          BridgeEvent.forTest(
            'tool',
            toolName: 'tokens',
            toolKind: 'thinking',
            outTokens: 200,
            inputTokens: 4200,
          ),
        );
        await settle();
        expect(a.tokensOut, 200); // the bridge's figure is authoritative
        time.advance(const Duration(milliseconds: 500));
        expect(
          a.tokensOut,
          greaterThan(200),
          reason: 'the ticker moves between relays',
        );

        // +93: `in` is the turn's delta (4200-4000), not the raw context.
        expect(a.tokensIn, 200);

        // A real step freezes the ticker: nothing is generating.
        harness.emit(
          BridgeEvent.forTest(
            'tool',
            toolName: 'Bash',
            detail: 'flutter analyze',
          ),
        );
        await settle();
        expect(a.tokenTickerOn, isFalse);
        time.advance(const Duration(seconds: 30));
        expect(a.tokensOut, 200, reason: 'no inflation while a tool runs');
      },
    );

    test('+93: a smaller in-figure re-anchors (compact mid-turn)', () async {
      await withBridge();
      unawaited(a.runQuickCommand('x'));
      await settle();
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          toolKind: 'thinking',
          outTokens: 5,
          inputTokens: 9000,
        ),
      );
      await settle();
      expect(a.tokensIn, 0); // anchored at 9000: no delta yet
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          toolKind: 'thinking',
          outTokens: 10,
          inputTokens: 1500,
        ),
      );
      await settle();
      expect(a.tokensIn, 0); // re-anchored lower, not negative
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          toolKind: 'thinking',
          outTokens: 20,
          inputTokens: 1800,
        ),
      );
      await settle();
      expect(a.tokensIn, 300); // the turn's growth since the re-anchor
    });

    test('+84: the wheel stops when the answer is settled', () async {
      await withBridge();
      unawaited(a.runQuickCommand('answer fast'));
      await settle();
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          toolKind: 'answering',
          outTokens: 40,
          draft: 'Here you go:',
        ),
      );
      await settle();
      expect(a.tokenDraft, 'Here you go:'); // painted before it is spoken
      expect(a.turnSettled, isFalse);

      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          toolKind: 'settled',
          draft: 'Here you go:',
        ),
      );
      await settle();
      expect(a.turnSettled, isTrue); // the wheel must stop (+84)
      expect(
        a.tokenDraft,
        'Here you go:',
        reason: '+83: settled keeps the draft until the say claims it',
      );

      harness.emit(BridgeEvent.forTest('say', text: 'Here you go: done.'));
      await settle();
      expect(
        a.tokenDraft,
        isEmpty,
        reason: 'the say stops the ticker: the draft getter goes quiet',
      );
      expect(
        a.turnSettled,
        isTrue,
        reason: 'settled is the turn’s state until resetForTurn',
      );
    });
  });

  group('the polite queue and its pin (0.1.0+81, +90)', () {
    test('push view: any frame of our own stream dissolves the pin', () async {
      await withBridge();
      unawaited(a.runQuickCommand('busy turn'));
      await settle();

      // An interrupt-off press over the live turn parks (pins) instead.
      unawaited(
        a.runQuickCommand('parked', interrupt: false, bubble: 'parked'),
      );
      await settle();
      expect(a.queuedText, 'parked');

      harness.emit(BridgeEvent.forTest('say', text: 'answer'));
      await settle();
      expect(
        a.queuedText,
        isNull,
        reason: 'a per-turn SSE view: the first frame IS the pickup',
      );
    });

    test(
      '+148: a PTT queue release leaves the tool-call box untouched '
      '— spinner, text, place — and it migrates only at the pickup',
      () async {
        await withBridge();
        a.setMode(InteractionMode.pushToTalk);
        engine.transcripts = ['steer please'];
        unawaited(a.runQuickCommand('sleep please'));
        await settle();
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'Bash',
            detail: 'sleep 10',
          ),
        );
        await settle();
        final running = a.view.liveTurnBubble!;
        expect(a.view.token.activityLabel, contains('sleep 10'));

        // Press, record, plain release — the queue flavour.
        a.pttDown(Offset.zero);
        await settle();
        expect(
          a.view.liveTurnBubble,
          same(running),
          reason: 'the press alone moves nothing',
        );
        mic.emit(FakeMic.audio(10));
        await settle();
        time.advance(const Duration(milliseconds: 600));
        a.pttUp(Offset.zero);
        await settle();

        expect(
          a.view.activity,
          isNot(isA<TurnWaiting>()),
          reason: 'no “Asking the bridge…” over a queue release',
        );
        expect(
          a.view.liveTurnBubble,
          same(running),
          reason:
              '+148: the parked placeholder does NOT steal the '
              'spinner — the tool-call box stands untouched',
        );
        expect(
          a.view.token.activityLabel,
          contains('sleep 10'),
          reason: 'the line keeps naming the running tool',
        );

        // A queued NOTICE is still not a pickup; the started marker is —
        // only then may the answer’s bubble take the box.
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'queued',
            detail:
                'a tool call is running; your message goes next '
                'when it settles',
          ),
        );
        await settle();
        expect(a.view.liveTurnBubble, same(running));
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'started',
            detail: 'steer please',
          ),
        );
        await settle();
        expect(
          a.view.liveTurnBubble,
          isNot(same(running)),
          reason: 'taken at last: the spinner migrates to the answer',
        );
      },
    );

    test(
      '+147: a parked prompt leaves the spinner text box on the '
      'running work — and the greyed message un-greys at the pickup',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('sleep please'));
        await settle();
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'Bash',
            detail: 'sleep 10',
          ),
        );
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'tokens',
            outTokens: 4200,
          ),
        );
        await settle();
        expect(
          a.view.token.out,
          4200,
          reason: 'the running turn taught the ticker its number',
        );

        // The Queue press parks.
        unawaited(
          a.runQuickCommand('status?', interrupt: false, bubble: 'status?'),
        );
        await settle();
        expect(a.queuedText, 'status?', reason: 'the pin (and its grey)');
        expect(
          a.view.activity,
          isNot(isA<TurnWaiting>()),
          reason:
              '+147: no “Asking the bridge…” over a '
              'wait that is not asking',
        );
        expect(
          a.view.token.activityLabel,
          contains('sleep 10'),
          reason: 'the spinner line survives the POST unchanged',
        );
        expect(
          a.view.token.out,
          4200,
          reason:
              'the counter is the CONVERSATION’s — a parked '
              'POST does not zero it',
        );

        // The pickup: the pin (grey) clears; the line stays honest until
        // the answer itself takes it over.
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'started',
            detail: 'status?',
          ),
        );
        await settle();
        expect(a.queuedText, isNull);
        expect(
          a.chat.any(
            (e) => e.fromUser && e.queued && e.blocks.contains('status?'),
          ),
          isFalse,
          reason: 'un-greyed in place — taken by the agent',
        );
      },
    );

    test(
      'poll view: the pin waits for the bridge’s explicit started',
      () async {
        await withBridge();
        // Turn 1 rides SSE (the ring is unknown yet — the first talk is
        // push by design, like on a fresh install).
        unawaited(a.runQuickCommand('busy turn'));
        await settle();
        expect(harness.talkCount, 1);
        harness.healthState = {
          'ok': true,
          'claudeUp': true,
          'now': time.now.millisecondsSinceEpoch,
          'poll': {'ring': 10},
        };
        await a.debugProbeTransport(); // the next turn learns the ring

        // An interrupt-off press over the live turn parks (pins).
        unawaited(
          a.runQuickCommand('parked', interrupt: false, bubble: 'parked'),
        );
        await settle();
        expect(a.queuedText, 'parked');
        expect(
          harness.talkPollCount,
          greaterThan(0),
          reason:
              'the ring is advertised: the prompt rides the pull '
              'transport',
        );

        // A frame of the BUSY turn flows past on the shared ring — on the
        // old push-only rule this dissolved the pin and the queue promise
        // evaporated (+81).
        harness.pollPages.add(
          FakeHarness.page(11, [
            BridgeEvent.forTest('say', text: 'unrelated turn chatter'),
          ], first: 11),
        );
        time.advance(const Duration(milliseconds: 300));
        await settle();
        expect(
          a.queuedText,
          'parked',
          reason: 'poll frames are not our pickup — the pin stays',
        );

        // The bridge's explicit word that it has the prompt NOW:
        harness.pollPages.add(
          FakeHarness.page(12, [
            BridgeEvent.forTest('tool', toolName: 'started', detail: 'parked'),
          ], first: 12),
        );
        time.advance(const Duration(milliseconds: 300));
        await settle();
        expect(a.queuedText, isNull);
        expect(a.debugLog.any((l) => l.contains('queue picked up')), isTrue);
      },
    );

    test(
      'poll view: a paragraph the ledger already owns does NOT resurface '
      'as a second bubble (queue/interrupt duplicate-bubble field report)',
      () async {
        await withBridge();
        // Turn 1 rides the PUSH view: heard, spoken, in the ledger.
        unawaited(a.runQuickCommand('go'));
        await settle();
        harness.emit(BridgeEvent.forTest('say', text: 'All done — one copy.'));
        harness.emit(const BridgeEvent.forTest('done'));
        await settle();
        int copies() => a.chat
            .where((e) => e.blocks.contains('All done — one copy.'))
            .length;
        expect(copies(), 1);
        expect(
          engine.synthesized.where((t) => t == 'All done — one copy.').length,
          1,
        );

        // The ring gets advertised; the NEXT press (queue or interrupt —
        // both ride the same /talk) chooses the poll transport. The ring
        // now hands the SAME paragraph again: a superseded polling view
        // left the cursor behind it, or the flush re-announced it. The
        // view says "mine"; only the ledger may say "heard".
        harness.healthState = {
          'ok': true,
          'claudeUp': true,
          'now': time.now.millisecondsSinceEpoch,
          'poll': {'ring': 10},
        };
        await a.debugProbeTransport();
        unawaited(a.runQuickCommand('steer', interrupt: false, cutTool: true));
        await settle();
        harness.pollPages.add(
          FakeHarness.page(11, [
            BridgeEvent.forTest('say', text: 'All done — one copy.'),
          ], first: 11),
        );
        time.advance(const Duration(milliseconds: 300));
        await settle();
        expect(
          copies(),
          1,
          reason:
              'the ring is shared history: dedup is the ledger, not '
              'the view — a heard paragraph must never re-bubble',
        );
        expect(
          engine.synthesized.where((t) => t == 'All done — one copy.').length,
          1,
          reason: 'and it must never re-speak',
        );
        expect(
          a.debugLog.any((l) => l.contains('ring dedup')),
          isTrue,
          reason: 'the skip is journalled under the ring-delivery law',
        );
      },
    );

    test('poll view: the prior turn’s DONE cannot end the queue pump — the '
        'pin dissolves at the started marker BEHIND it (field report: a '
        'queue press over a live bash sleep left the pin frozen)', () async {
      await withBridge();
      // The busy turn opens BEFORE the ring is known — the classic
      // session start, riding SSE.
      harness.turnOpenOnServer = true;
      unawaited(a.runQuickCommand('run bash sleep 10'));
      await settle();

      // Mid-turn, the bridge's /health reveals the ring: from here the
      // phone pulls.
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'now': time.now.millisecondsSinceEpoch,
        'poll': {'ring': 10},
      };
      await a.debugProbeTransport();

      // The Queue button, pressed while the sleep runs: polite, cuts
      // the tool into background. The POST parks; its pump inherits
      // the ring cursor at the head of everything the SSE view already
      // delivered (+81 catch-up) — and NOTHING else has rung since.
      unawaited(
        a.runQuickCommand(
          'status please',
          interrupt: false,
          cutTool: true,
          bubble: 'status please',
        ),
      );
      await settle();
      expect(a.queuedText, 'status please');
      expect(harness.lastCutTool, isTrue);

      // Ten seconds later the sleep settles, and the flush lands on
      // the ring as one batch, in the bridge's own order: the busy
      // turn's done FIRST, then the disposition notice, then the
      // pickup marker. Handing that done to the pump ended the queue
      // turn before its markers — the pin fossilised at 'queued' and
      // the flushed answer strangled in the ring unheard, exactly as
      // reported. The pump must eat the foreign done and keep waiting.
      harness.pollPages.add(
        FakeHarness.page(13, [
          BridgeEvent.forTest('done'),
          BridgeEvent.forTest(
            'tool',
            toolName: 'queued',
            detail:
                'the running call was interrupted — the agent is freed '
                'to answer you now; the tool outcome reports on its '
                'own',
            toolKind: 'background',
          ),
          BridgeEvent.forTest(
            'tool',
            toolName: 'started',
            detail: 'status please',
            toolKind: 'background',
          ),
        ], first: 11),
      );
      time.advance(const Duration(milliseconds: 300));
      await settle();
      expect(a.queuedText, isNull, reason: 'the marker dissolved the pin');
      expect(a.debugLog.any((l) => l.contains('queue picked up')), isTrue);

      // And the surviving pump HEARS the flushed turn — the reply the
      // frozen pump used to strand unheard behind the foreign done.
      harness.pollPages.add(
        FakeHarness.page(14, [
          BridgeEvent.forTest('say', text: 'All green.'),
        ], first: 14),
      );
      time.advance(const Duration(milliseconds: 300));
      await settle();
      expect(
        a.chat.any((e) => !e.fromUser && e.blocks.contains('All green.')),
        isTrue,
        reason: 'own-turn frames after the marker reach the pump alive',
      );
      harness.pollPages.add(
        FakeHarness.page(15, [BridgeEvent.forTest('done')], first: 15),
      );
      time.advance(const Duration(milliseconds: 300));
      await settle();
      expect(a.phase, isNot(AssistantPhase.transcribing));
    });

    test(
      'push view: the bridge’s queued NOTICE is not a pickup — the pin '
      'survives it and dies only when the turn opens (+behaviour 1)',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('busy turn'));
        await settle();
        unawaited(
          a.runQuickCommand('parked', interrupt: false, bubble: 'parked'),
        );
        await settle();
        expect(a.queuedText, 'parked');

        // A busy bridge answers a queue POST with the 'queued' notice the
        // INSTANT it enqueues. Under the old "any frame is the pickup"
        // rule this frame dissolved the pin and the message fell back
        // into the flow while still waiting — the behaviour-1 complaint.
        harness.emit(
          BridgeEvent.forTest(
            'tool',
            toolName: 'queued',
            detail: 'finishing the current turn; your message goes next',
          ),
        );
        await settle();
        expect(
          a.queuedText,
          'parked',
          reason: 'a queued ack is the OPPOSITE of a pickup',
        );
        expect(
          a.chat.any(
            (e) => e.fromUser && e.queued && e.blocks.contains('parked'),
          ),
          isTrue,
          reason:
              'the parked message sits IN the flow, greyed by its '
              'pin flag — the +146 wait indicator',
        );
        expect(
          a.chat.any((e) => e.blocks.any((b) => b.startsWith('One moment'))),
          isFalse,
          reason:
              '+146: the notice injects NO bubble — the parked '
              'message itself greys in the flow until the started '
              'marker un-greys it; the verdict only paints the status '
              'line above the orb',
        );

        // beginTurn's first real frame: NOW the floor is ours.
        harness.emit(
          BridgeEvent.forTest('tool', toolName: 'tokens', outTokens: 12),
        );
        await settle();
        expect(
          a.queuedText,
          isNull,
          reason: 'the turn opening for real dissolves the pin',
        );
      },
    );

    test('the Queue button rides the wire as polite-with-backgrounding '
        '(+behaviour 2)', () async {
      await withBridge();
      unawaited(a.runQuickCommand('busy turn'));
      await settle();
      unawaited(
        a.runQuickCommand(
          'queue me',
          interrupt: false,
          cutTool: true,
          bubble: 'queue me',
        ),
      );
      await settle();
      expect(harness.lastInterrupt, isFalse);
      expect(
        harness.lastCutTool,
        isTrue,
        reason: 'the bridge decides tool-or-polite from its own openTools',
      );
      // And a plain interrupt send never flags it — it cuts regardless:
      unawaited(
        a.runQuickCommand('cut', interrupt: true, cutTool: true, bubble: 'cut'),
      );
      await settle();
      expect(harness.lastInterrupt, isTrue);
      expect(harness.lastCutTool, isFalse);
    });

    test('a queue press superseded by a newer send retires its pin '
        '(+behaviour 5: no fossilised queued bubble)', () async {
      await withBridge();
      unawaited(a.runQuickCommand('busy turn'));
      await settle();
      unawaited(
        a.runQuickCommand('parked', interrupt: false, bubble: 'parked'),
      );
      await settle();
      expect(a.queuedText, 'parked');

      // A third press arrives while the second still waits: the bridge
      // keeps ONE pending slot (latest wins), so 'parked' will never
      // get its 'started' — and its pin must retire with the promise,
      // not fossilise at the bottom of the channel.
      unawaited(a.runQuickCommand('newest', bubble: 'newest'));
      await settle();
      await settle();
      expect(
        a.queuedText,
        isNull,
        reason: 'the superseded queue pin retires with its promise',
      );
      expect(
        a.chat.any((e) => e.fromUser && e.blocks.contains('parked')),
        isTrue,
        reason: 'the message itself stays in the log — it was said',
      );
      expect(a.debugLog.any((l) => l.contains('msg pin dropped')), isTrue);
    });

    test('a /stop keeps the queued pin — the bridge still owes it the '
        'flush, and the started marker retires the pin', () async {
      await withBridge();
      unawaited(a.runQuickCommand('busy turn'));
      await settle();
      unawaited(
        a.runQuickCommand('parked', interrupt: false, bubble: 'parked'),
      );
      await settle();
      expect(a.queuedText, 'parked');
      // Stop chip over the live turn: the turn is cut, the QUEUED
      // prompt survives at the bridge (flush on the cut's result).
      // bridgeStop bumps the generation — that alone must not retire
      // the pin: the promise is still owed.
      a.bridgeStop();
      await settle();
      await settle();
      expect(
        a.queuedText,
        'parked',
        reason:
            'a /stop cuts the TURN, not the queued prompt — the '
            'bridge still owes it the flush and its '
            'started marker retires the pin (unpin path +81)',
      );
    });

    test('a cut tool keeps the banner past the pickup until the finished '
        'frame; then a bubble records it (+behaviour 4)', () async {
      await withBridge();
      // The bridge is telling the truth: a turn is open (the build), and
      // until the cut its tool is NOT yet detached.
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'turnOpen': true,
        'detached': 0,
      };
      unawaited(a.runQuickCommand('long build'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'flutter test'),
      );
      await settle();
      // The Queue press: supersede+detach (the abandon snapshots the
      // step into the banner) and queue WITH backgrounding.
      unawaited(
        a.runQuickCommand(
          'status?',
          interrupt: false,
          cutTool: true,
          bubble: 'status?',
        ),
      );
      await settle();
      expect(a.queuedText, 'status?');
      // The bridge's notice confirms the tool went to background — the
      // banner lights on the bridge's own word (not the phone's guess),
      // and it rides its own warrant from here, not just the pin:
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'turnOpen': true,
        'detached': 1,
      };
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'queued',
          detail:
              'the running call was interrupted — the agent is freed '
              'to answer you now; the tool outcome reports on its own',
          toolKind: 'background',
        ),
      );
      await settle();
      expect(
        a.backgroundedWork,
        'Bash flutter test…',
        reason:
            'waiting behind the cut tool is background work '
            'the moment the bridge says so',
      );
      // Pick-up of the queued prompt must NOT retire the line: the
      // cut tool is precisely what is still running — and the bridge
      // tags this flush's marker with the promise it carries.
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'started',
          detail: 'status?',
          toolKind: 'background',
        ),
      );
      await settle();
      expect(a.queuedText, isNull, reason: 'the pin dissolved at pickup');
      expect(
        a.backgroundedWork,
        'Bash flutter test…',
        reason: 'a cut tool outlives the pickup that replaced its turn',
      );
      // The proof of completion: retire, and file a stamped bubble.
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'Bash flutter test',
        ),
      );
      await settle();
      expect(
        a.backgroundedWork,
        isEmpty,
        reason: 'the finished frame retires the banner',
      );
      expect(
        a.chat.any(
          (e) =>
              !e.fromUser && e.blocks.contains('Bash flutter test finished.'),
        ),
        isTrue,
        reason: 'the tool call gets its period',
      );
    });

    test('a started marker tagged background raises the banner from the '
        'pickup ack alone — no reliance on the enqueue notice', () async {
      await withBridge();
      unawaited(a.runQuickCommand('long build'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'npm test'),
      );
      await settle();
      unawaited(
        a.runQuickCommand(
          'build x',
          interrupt: false,
          cutTool: true,
          bubble: 'build x',
        ),
      );
      await settle();
      expect(a.queuedText, 'build x'); // pinned while it waits
      // The pickup marker carries the disposition (kind='background').
      // NO 'queued' notice is delivered at all: on the pull transport
      // that notice rides a shared ring cursor the dying turn can
      // consume and drop — the started marker is the one delivery that
      // cannot be lost, and this pins that it carries the banner.
      harness.emit(
        BridgeEvent.forTest(
          'tool',
          toolName: 'started',
          detail: 'build x',
          toolKind: 'background',
        ),
      );
      await settle();
      expect(a.queuedText, isNull); // the pickup dissolved the pin
      expect(a.debugLog.any((l) => l.contains('queue picked up')), isTrue);
      expect(
        a.showsBackgroundedWork,
        isTrue,
        reason:
            'the started marker RAISED the banner: no ring notice '
            'ever reached this pump, so only the pickup ack could',
      );
      expect(
        a.backgroundedWork,
        'Bash npm test…',
        reason:
            'the label is the abandoned turn\'s last real step, '
            'snapshotted at the abandon and kept by the background kind',
      );
    });

    test('a pull turn after a pushed one does not replay the heard past '
        '(+behaviour 5: the duplicate-bubble killer)', () async {
      await withBridge();
      final now = time.now.millisecondsSinceEpoch;
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'now': now,
        'poll': {'ring': 40},
      };
      await a.debugProbeTransport(); // cursor seeded at 40, ring known
      // A flaky moment: the ring vanishes from /health → the next turn
      // rides SSE, consuming NOTHING from the ring.
      harness.healthState = {'ok': true, 'claudeUp': true, 'now': now};
      await a.debugProbeTransport();
      unawaited(a.runQuickCommand('pushed turn'));
      await settle();
      harness.emit(BridgeEvent.forTest('say', text: 'Delivered live.'));
      await settle();
      // The ring is back and has grown (41..47 are exactly the frames
      // the SSE view already spoke — re-delivering them as fresh is
      // the field's “redundant bubbles after queue or interrupt”).
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'now': now,
        'poll': {'ring': 47},
      };
      await a.debugProbeTransport();
      unawaited(
        a.runQuickCommand(
          'queued after',
          interrupt: false,
          bubble: 'queued after',
        ),
      );
      await settle(); // let the pull loop register its first _tick
      time.advance(const Duration(milliseconds: 300));
      await settle();
      expect(
        harness.lastPollSince,
        47,
        reason:
            'the cursor caught up to the head BEFORE the POST — '
            'the pushed turn\'s ring copy is not replayed',
      );
      expect(a.queuedText, 'queued after');
    });
  });

  group('eyes-only mode (TTS off)', () {
    test('replies land as chat text; the speaker stays cold', () async {
      await withBridge();
      await a.setBridgeTts(false);
      expect(a.bridgeTts, isFalse);
      unawaited(a.runQuickCommand('quiet turn', bubble: 'quiet turn'));
      await settle();
      final playedBefore = out.played.length; // the warm-up click is fine
      harness.emit(BridgeEvent.forTest('say', text: 'Silent answer.'));
      await settle();
      expect(
        out.played.length,
        playedBefore,
        reason: 'the reply itself never reaches the player',
      );
      expect(engine.synthesized, isEmpty, reason: 'nothing synthesises');
      expect(
        a.chat.any((e) => !e.fromUser && e.blocks.contains('Silent answer.')),
        isTrue,
        reason:
            'the screen is the ear: the block lands the moment it is '
            'heard on the wire',
      );
    });

    test('a typed send needs no audio worker while TTS is off', () async {
      final sched = FakeScheduler(DateTime(2026, 1, 1, 12));
      final noModels = VoiceAssistant(
        micSource: FakeMic(),
        audioOutput: out,
        gatewayFactory: (_, _) => harness,
        scheduler: sched,
        clock: () => sched.now,
        // worker omitted: models "still loading" — the classic
        // cold-start state a text-first user should not be gated on.
      );
      addTearDown(noModels.dispose);
      await noModels.setBridge(url: 'http://harness.test', token: 'tok');
      await noModels.setBridgeTts(false);
      await settle();
      unawaited(
        noModels.runQuickCommand(
          'typing with no models',
          bubble: 'typing with no models',
        ),
      );
      await settle();
      expect(noModels.error, isEmpty, reason: 'no "Models are still loading"');
      expect(harness.talkCount + harness.talkPollCount, 1);
    });
  });

  group('barge-in and the AEC trust window', () {
    test(
      'speech in the first 450 ms is our own leak; later is a cut',
      () async {
        // Local echo mode (no bridge): the reply repeats what was heard.
        await a.toggle(); // conversation, mic on
        await settle();
        expect(a.phase, AssistantPhase.listening);

        engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
        await settle(); // transcribe -> synthesizeStream -> first chunk plays
        expect(a.phase, AssistantPhase.speaking);
        expect(out.played.where((c) => c.$1.length == 2400), hasLength(1));

        // Instant "speech": AEC has not locked — this is the reply leaking
        // back into the mic, not the user. The reply must NOT be killed.
        engine.deliver(const SpeechEvent.started());
        await settle();
        expect(out.stopCount, 0, reason: '450 ms guard: too young to trust');

        // 500 ms of reply later, the same event is a real interruption.
        time.advance(const Duration(milliseconds: 500));
        engine.deliver(const SpeechEvent.started());
        await settle();
        expect(out.stopCount, greaterThan(0));
        expect(a.status, 'Interrupted — go ahead.');
        expect(a.phase, AssistantPhase.listening);
      },
    );

    test('a committed paragraph is in the ledger before its audio lands '
        '(+109: no double voice after an interrupt)', () async {
      // The window the field report lived in: a paragraph promised to
      // the speaker but not yet audible looked unheard to a reattach
      // replay, which then voiced it a second time. The stamp now rides
      // the COMMIT, so the dedup ledger knows the promise immediately.
      final gate = Completer<void>();
      engine.holdChunks = gate.future; // synth frozen before its first
      // chunk: nothing can have reached the player
      await withBridge();
      await a.toggle();
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle();
      harness.emit(BridgeEvent.forTest('say', text: 'Stuck in the synth.'));
      await settle();

      expect(
        out.played.where((c) => c.$1.length == 2400),
        isEmpty,
        reason: 'the reply audio is still mid-synth (UI blips exempt)',
      );
      expect(a.phase, isNot(AssistantPhase.speaking));
      expect(
        a.chat.any(
          (e) => !e.fromUser && e.blocks.contains('Stuck in the synth.'),
        ),
        isFalse,
        reason:
            '+116: the ledger waits for the FIRST SOUND — an '
            'unspoken commit must never fossilise into fake history '
            '(the in-flight set, not the log, guards the queueing gap)',
      );
      expect(harness.view != null, isTrue); // frame WAS taken: it is in

      gate.complete(); // the speaker gets it: heard once, logged once
      await settle();
      expect(out.played.where((c) => c.$1.length == 2400), hasLength(1));
      expect(
        a.chat.any(
          (e) => !e.fromUser && e.blocks.contains('Stuck in the synth.'),
        ),
        isTrue,
        reason: 'air is the stamp (+116)',
      );
    });

    test(
      'the ledger stamp waits for the PLAYER, not the queue (+121)',
      () async {
        // The afternoon's silent-tail killer, unit-caught: onAir used to
        // fire when a synth chunk reached the QUEUE, so paragraphs
        // parked there while the drain bumped the generation were
        // stamped 'heard' and then cleared unheard — the audio stopped
        // exactly when the spinner box dismissed.
        await withBridge();
        harness.healthState = {'ok': true, 'claudeUp': true, 'turnOpen': true};
        unawaited(a.runQuickCommand('go'));
        await settle();
        harness.emit(BridgeEvent.forTest('say', text: 'First, playing.'));
        harness.emit(BridgeEvent.forTest('say', text: 'Second, queued.'));
        await settle();
        expect(out.playing, isTrue); // the player took the first…
        final bubbles = () =>
            a.chat.where((e) => !e.fromUser).expand((e) => e.blocks).toList();
        expect(
          bubbles(),
          contains('First, playing.'),
          reason: 'its audio started: stamped',
        );
        expect(
          bubbles(),
          isNot(contains('Second, queued.')),
          reason:
              'it only sits in the queue — a stale-clear there '
              'must never leave a fake heard mark (+121)',
        );

        out.complete(); // the first ends; the pump hands over the second
        await settle();
        expect(
          bubbles(),
          containsAll(['First, playing.', 'Second, queued.']),
          reason: 'heard now, stamped now',
        );
      },
    );

    test('the queue verdict injects no bubble (+146)', () async {
      await withBridge();
      await a.toggle();
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle(); // harness turn opens (empty assistant bubble)
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'queued',
          detail:
              'the thinking was interrupted and aborted; '
              'your message goes next',
        ),
      );
      await settle();

      // No 'One moment' card anywhere in the channel (+146): the
      // verdict paints only the transient status line and the journal.
      expect(
        a.chat.where(
          (e) => !e.fromUser && e.blocks.any((b) => b.startsWith('One moment')),
        ),
        isEmpty,
        reason:
            'the injected system card is retired — the wait is '
            'shown by the greyed queued message itself',
      );
      final cutTurn = a.chat.last;
      expect(cutTurn.fromUser, isFalse);
      expect(
        cutTurn.blocks,
        isEmpty,
        reason: 'the open turn stays clean of the verdict',
      );
    });

    test('a cut silent turn still leaves its trace (+110)', () async {
      await withBridge();
      await a.toggle();
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle(); // turn 1 runs, speaks nothing (a tool works)
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'sleep 60'),
      );
      await settle();

      time.advance(const Duration(milliseconds: 500));
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle(); // turn 2 supersedes turn 1 before its first word

      final cut = a.chat
          .where(
            (e) =>
                !e.fromUser &&
                e.blocks.contains('Interrupted before answering.'),
          )
          .single;
      expect(
        cut.interrupted,
        isTrue,
        reason: 'stamped, so the bubble also carries the +108 mark',
      );
    });

    test(
      'the answered interruption drains its stranded backlog (+111)',
      () async {
        await withBridge();
        await a.toggle();
        await settle();
        engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
        await settle(); // turn 1 in flight, unheard frames accumulating
        harness.healthState = {
          'ok': true,
          'claudeUp': true,
          'turnOpen': false,
          'backgrounded': false,
          'queued': false,
          'missed': 3,
        };
        // turn 1 closes clean on the (single) view — its teardown is the
        // moment the app learns the bridge still owes it frames.
        harness.emit(BridgeEvent.forTest('done'));
        await settle();
        time.advance(Duration.zero); // the armed first probe
        await settle();
        expect(
          a.debugLog.any((l) => l.contains('stranded backlog')),
          isTrue,
          reason: 'teardown found missed>0 and armed the drain',
        );
        expect(
          harness.attachCount,
          greaterThan(0),
          reason:
              'the drain reattaches; the replay path decides what '
              'is heard again and what files silently',
        );
      },
    );

    test('the drain parks behind the paragraph still on air (+124)', () async {
      // The field's last mid-word cut, unit-caught: `missed` is the
      // backlog's LENGTH, so the teardown verdict fires while the
      // reply's final paragraph is still on the speaker — and the
      // reattach it armed opened with stopPlayback, killing the tail
      // of a perfectly healthy answer at the spinner's dismissal.
      await withBridge();
      await a.toggle();
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle();
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'turnOpen': false,
        'backgrounded': false,
        'queued': false,
        'missed': 3,
      };
      harness.emit(BridgeEvent.forTest('say', text: 'Still on the air.'));
      await settle();
      expect(out.playing, isTrue, reason: 'the chunk is on the speaker');
      harness.emit(BridgeEvent.forTest('done')); // the wire ends mid-voice
      await settle();
      time.advance(Duration.zero);
      await settle();
      expect(
        a.debugLog.any((l) => l.contains('drain parked')),
        isTrue,
        reason: 'the verdict refused to cut audio that had the air',
      );
      expect(
        harness.attachCount,
        0,
        reason:
            'no reattach means no stopPlayback means no trampled '
            'tail — the paragraph gets its own last syllable',
      );

      out.complete(); // the paragraph ends on its own terms
      await settle();
      time.advance(Duration.zero);
      await settle();
      expect(
        harness.attachCount,
        greaterThan(0),
        reason: 'the natural end collects the parked verdict and drains',
      );
    });

    test('the tail of our own echo is rejected before it ever sends', () async {
      engine.transcripts = ['hello there', 'hello there again'];
      await a.toggle();
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle();
      expect(
        a.chat.any((e) => e.fromUser && e.blocks.first == 'hello there'),
        isTrue,
      );

      // While audible, talk over us (first the started edge, then the
      // endpointed segment — it is our own voice coming back).
      time.advance(const Duration(milliseconds: 500));
      engine.deliver(const SpeechEvent.started());
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle();
      expect(a.status, contains("my own voice"));
      expect(a.chat.where((e) => e.fromUser), hasLength(1));
    });
  });

  group('mic lifecycle', () {
    test('a stream the OS killed is reopened by the watchdog', () async {
      await a.toggle();
      await settle();
      expect(mic.startCount, 1);

      mic.kill(); // onDone -> the pipeline recovers (real 150 ms backoff)
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await settle();
      expect(mic.startCount, 2, reason: 'capture reopened automatically');
      expect(a.phase, AssistantPhase.listening);
      expect(a.debugLog.any((l) => l.contains('reopening')), isTrue);
    });

    test(
      'a stalled (silent, never-closed) stream trips the watchdog',
      () async {
        await a.toggle();
        await settle();
        time.advance(const Duration(milliseconds: 1300)); // no bytes at all
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await settle();
        expect(mic.startCount, 2);
      },
    );

    test('a reopen that ducks mid-reply waits for the audio to end', () async {
      await a.toggle();
      await settle();
      // Make audio "busy": start a local echo reply and hold it playing.
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle();
      expect(out.playing, isTrue);

      mic.kill(); // dies while we are audible
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await settle();
      expect(mic.startCount, 1, reason: 'deferred, not reopened');

      out.complete(); // the reply runs out…
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await settle();
      expect(
        mic.startCount,
        2,
        reason: '…and the deferred reopen fires immediately',
      );
    });
  });

  group('zombie wire and reattach (the background→foreground fix)', () {
    test(
      '24 s of silence on a live turn hops to a fresh /attach view',
      () async {
        await withBridge();
        harness.healthState = {'ok': true, 'claudeUp': true, 'turnOpen': true};
        unawaited(a.runQuickCommand('long build'));
        await settle();

        // The bridge pings every 15 s; a full quiet window with NOTHING
        // crossing means the route died quietly. 25 s of silence:
        time.advance(const Duration(seconds: 25));
        await settle();

        expect(
          a.harnessBackgrounded || a.bridgeBusy,
          isTrue,
          reason: 'the turn is still alive on the bridge',
        );
        expect(harness.attachCount, 1, reason: 'the chain stole a fresh view');
        expect(a.status, contains('Reattached'));

        // The reattached view speaks the story that went unheard:
        harness.emitAttach(BridgeEvent.forTest('say', text: 'Build done.'));
        await settle();
        expect(engine.synthesized.any((t) => t.contains('Build done')), isTrue);
        expect(a.chat.last.blocks, contains('Build done.'));
      },
    );

    test(
      'a wire death withdraws unheard commits from the bubble (+114)',
      () async {
        await withBridge();
        harness.healthState = {'ok': true, 'claudeUp': true, 'turnOpen': true};
        unawaited(a.runQuickCommand('go'));
        await settle();
        harness.emit(BridgeEvent.forTest('say', text: 'Heard, this one.'));
        await settle(); // fake synth plays at once: this one AIRED
        expect(a.chat.last.blocks, contains('Heard, this one.'));

        final gate = Completer<void>();
        engine.holdChunks = gate.future; // next paragraph enters the
        // speaker's flight but its audio is frozen before the first chunk
        harness.emit(BridgeEvent.forTest('say', text: 'Never aired.'));
        await settle();
        expect(
          a.chat.last.blocks,
          isNot(contains('Never aired.')),
          reason:
              '+116: no block without sound — and nothing to '
              'retract later either, the lie was never written',
        );

        harness.finishView(); // the wire dies mid-synth: no done frame
        await settle();
        // A newer turn takes the ear (the field shape: the user's next
        // press arrives while the unheard paragraph is still frozen in
        // synth): the dead turn's chunks drop on its alive-guard, and its
        // teardown retracts what never aired.
        unawaited(a.runQuickCommand('next'));
        gate.complete();
        await settle();
        expect(
          a.chat.first.blocks,
          isNot(contains('Never aired.')),
          reason:
              'never heard, so never owed: withdrawn, and the '
              'bridge copy stays replayable for a fresh view',
        );
        expect(
          a.chat.first.blocks,
          contains('Heard, this one.'),
          reason: 'heard text is heard history',
        );

        // The retract must be RECOVERY, not deletion: the chain's attach
        // view (health said turnOpen) meets the same paragraph on the
        // replay stream and must VOICE it — no ledger entry, no flight
        // claim, so dedup bows out of the way.
        harness.emitAttach(BridgeEvent.forTest('say', text: 'Never aired.'));
        await settle();
        expect(
          engine.synthesized.any((t) => t.contains('Never aired')),
          isTrue,
          reason: '+115: the tail the old process never said is said now',
        );
        expect(
          a.chat.first.blocks,
          isNot(contains('Never aired.')),
          reason: 'it belongs to the NEW bubble, not the dead turn',
        );
      },
    );

    test('an old unheard paragraph is logged, never re-voiced', () async {
      await withBridge();
      harness.healthState = {'ok': true, 'claudeUp': true, 'turnOpen': true};
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.finishView(); // the view died mid-turn, no done frame
      await settle();
      expect(harness.attachCount, greaterThan(0));

      // An archaeology frame: 5 minutes old and not in the chat log.
      final ancient =
          time.now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch -
          1; // ~300 s wire age after skew ~0
      harness.emitAttach(
        BridgeEvent.forTest(
          'say',
          text: 'Something from before',
          wireMs: ancient,
        ),
      );
      await settle();
      expect(
        a.chat.last.blocks,
        contains('Something from before.'),
        reason: 'it belongs to the history… (cleaned, as stored)',
      );
      expect(
        engine.synthesized.any((t) => t.contains('Something from before')),
        isFalse,
        reason: '…but the user already heard it; never re-voice',
      );
    });
  });

  group('the backgrounded-work receipt (0.1.0+128)', () {
    test('poll view: the finished receipt dismisses the bottom line '
        'without waiting for a pickup', () async {
      await withBridge();
      unawaited(a.runQuickCommand('busy turn'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'npm test'),
      );
      await settle();
      // The turn leaves the ear unheard (+146 seam — the state a press
      // reaches when its steal-back probe fails): the line names it.
      // The tail waits on the ring, drained by the queued view below.
      a.debugDetachUnheard();
      await settle();

      expect(a.harnessBackgrounded, isTrue);
      expect(a.backgroundedWork, 'Bash npm test…');

      // The next prompt rides the ring (poll): beforeEvent keeps its
      // hands off there, so nothing retires the line until the wire
      // itself proves something. The bridge relays the detached turn's
      // 'finished' receipt the moment its result lands — the ring
      // delivers it to the queued view ahead of any pickup.
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'now': time.now.millisecondsSinceEpoch,
        'poll': {'ring': 10},
      };
      await a.debugProbeTransport();
      unawaited(a.runQuickCommand('follow-up', bubble: 'follow-up'));
      await settle();
      expect(
        a.queuedText,
        isNull,
        reason: 'an interrupt prompt shows right away (+126)',
      );
      expect(
        a.backgroundedWork,
        'Bash npm test…',
        reason: 'the work IS still running unheard until the receipt',
      );

      harness.pollPages.add(
        FakeHarness.page(11, [
          BridgeEvent.forTest(
            'tool',
            toolName: 'finished',
            detail: 'ended after 9s unheard',
          ),
        ], first: 11),
      );
      time.advance(const Duration(milliseconds: 300));
      await settle();
      expect(
        a.backgroundedWork,
        isEmpty,
        reason:
            'the receipt proves the work over — the line dismisses '
            'itself, no pickup required',
      );
      expect(a.harnessBackgrounded, isFalse);
      expect(
        a.debugLog.any(
          (l) =>
              l.contains('backgrounded work finished (ended after 9s unheard)'),
        ),
        isTrue,
        reason: 'the journal keeps WHEN the out-of-earshot work ended',
      );

      // The queue's own pickup ack still does its pin/spinner work after.
      harness.pollPages.add(
        FakeHarness.page(12, [
          BridgeEvent.forTest('tool', toolName: 'started', detail: 'follow-up'),
        ], first: 12),
      );
      time.advance(const Duration(milliseconds: 300));
      await settle();
      expect(
        a.harnessElapsed,
        Duration.zero,
        reason: 'the live turn re-anchored the age clock at pickup',
      );
    });
  });

  group('latency bench', () {
    test('a bench run transcribes the capture and echoes it, timed', () async {
      a.setMode(InteractionMode.pushToTalk);
      await a.benchDown();
      await settle();
      expect(a.benchCapturing, isTrue);
      expect(mic.startCount, 1);

      // 1.2 s of audio, then the release.
      mic.emit(FakeMic.audio(75)); // 75 frames of 16 ms
      await settle();
      final done = a.finishBenchCapture();
      await settle();
      out.complete(); // the echo's chunk runs out…
      await done;
      await settle();

      expect(a.benchRuns, hasLength(1));
      final run = a.benchRuns.first;
      expect(run.heard, 'repeat that');
      expect(run.audioSeconds, closeTo(0.1, 0.01));
      expect(a.benchNote, contains('release→text'));
      expect(
        out.played.where((c) => c.$1.length == 2400),
        hasLength(1),
        reason: 'the echo reached the player (warm-up aside)',
      );
      expect(a.benchBusy, isFalse);
    });
  });

  group('push-to-talk defers its verdict to the release (0.1.0+132)', () {
    // The bug this pins: the press-down detached the running tool call
    // AND stamped 'Interrupted before answering.' before the finger
    // knew what it would do — then a slide-right (or any release that
    // merely failed to cross the slide threshold) fired the mid-turn
    // tap-Stop, killing a tool the user had only tried to walk away
    // from. The press may only take the EAR; the release owes the
    // verdict, and cancelling is not stopping.
    Future<void> busyWithTool() async {
      await withBridge();
      unawaited(a.runQuickCommand('run bash sleep 10'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'sleep 10'),
      );
      await settle();
      a.setMode(InteractionMode.pushToTalk);
      a.pttDown(Offset.zero);
      await settle();
      expect(a.harnessBackgrounded, isTrue);
      expect(
        a.chat.any((e) => e.blocks.contains('Interrupted before answering.')),
        isFalse,
        reason: 'at press time the gesture has decided NOTHING yet',
      );
    }

    test('a slide-right dismiss leaves no trace and stops nothing', () async {
      await busyWithTool();
      a.pttUp(const Offset(300, 0)); // clear right, past the threshold
      await settle();
      expect(harness.stops, 0, reason: 'the dismiss branch never stops');
      expect(
        a.status,
        contains('keeps working in the background'),
        reason: 'as if nothing happened — the tool still sleeps',
      );
      expect(
        a.chat.any((e) => e.blocks.contains('Interrupted before answering.')),
        isFalse,
        reason:
            'the deferred trace died with the recording — the bubble '
            'went back to never having been interrupted',
      );
    });

    test(
      'a gentle right that misses the slide threshold is no tap-stop',
      () async {
        await busyWithTool();
        a.pttUp(const Offset(30, 0)); // drifted, but under 48px: plain
        await settle();
        expect(
          harness.stops,
          0,
          reason:
              'a release that moved was a mind half-changed, not the '
              'old mid-turn tap — this is the reported tool murder',
        );
        expect(
          a.chat.any((e) => e.blocks.contains('Interrupted before answering.')),
          isFalse,
        );
      },
    );
    test('a motionless quick tap still stops — and now stamps', () async {
      await busyWithTool();
      a.pttUp(const Offset(2, 0)); // under slop, under tapStopMs
      await settle();
      expect(harness.stops, 1, reason: 'the tap-Stop the button always was');
      final cut = a.chat
          .where(
            (e) =>
                !e.fromUser &&
                e.blocks.contains('Interrupted before answering.'),
          )
          .single;
      expect(cut.interrupted, isTrue, reason: 'the verdict arrived: stamped');
    });

    test(
      'a slide-up cut over live words stamps the abandoned turn too',
      () async {
        await busyWithTool();
        engine.transcripts = ['status please'];
        mic.emit(FakeMic.audio(10)); // enough audio for a real turn
        await settle(); // the bytes must land before the release
        final talksBefore = harness.talkCount + harness.talkPollCount;
        a.pttUp(const Offset(0, -100)); // clear up: the interrupt
        await settle();
        expect(
          harness.talkCount + harness.talkPollCount,
          greaterThan(talksBefore),
          reason: 'the words were sent',
        );
        expect(
          harness.lastInterrupt,
          isTrue,
          reason: 'slide-up keeps the cutting flavour (+106)',
        );
        expect(
          a.chat.any((e) => e.blocks.contains('Interrupted before answering.')),
          isTrue,
          reason:
              'this release DID cut the tool call — the trace it '
              'deferred at press finally lands',
        );
      },
    );
  });

  group("the agent's own background shell (0.1.0+133)", () {
    // The harness may run_in_background a Bash of its own accord. No
    // press is involved, yet the work leaves the ear: the bridge's
    // `backgrounded` frame lights the bottom line, /health counts the
    // debt, and when the CLI later speaks UNPROMPTED to report the
    // task, an idle phone must wake and hear it.
    test(
      'a backgrounded frame lights the line; the receipt retires it',
      () async {
        await withBridge();
        unawaited(a.runQuickCommand('start a sleep'));
        await settle();
        harness.healthState = {
          'ok': true,
          'claudeUp': true,
          'turnOpen': true,
          'detached': 1,
        };
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'backgrounded',
            detail: 'Bash sleep 20',
          ),
        );
        await settle();
        expect(a.backgroundedWork, 'Bash sleep 20');
        expect(
          a.harnessBackgrounded,
          isFalse,
          reason: 'no press, no badge — the bridge vouched, not a takeover',
        );
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'finished',
            detail: 'Bash sleep 20',
          ),
        );
        await settle();
        expect(a.backgroundedWork, isEmpty);
        harness.emit(const BridgeEvent.forTest('done'));
        await settle();
        expect(
          a.chat.any((e) => e.blocks.contains('Bash sleep 20 finished.')),
          isTrue,
          reason: 'the named receipt gives the shell its period',
        );
        expect(a.backgroundedWork, isEmpty);
      },
    );

    test('a turn-closed receipt pays an agent debt with NOTHING', () async {
      // The three-sleep field report (+140): the launch turn ends
      // unheard a breath after dispatching the shells, and its
      // lifecycle receipt — which names no tool — must NOT be
      // allowed to claim the process died. The line stays lit; the
      // honest detached counter pays later.
      await withBridge();
      unawaited(a.runQuickCommand('start a sleep'));
      await settle();
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'turnOpen': false,
        'queued': false,
        'detached': 1,
      };
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'backgrounded',
          detail: 'Bash sleep 20',
        ),
      );
      await settle();
      expect(a.backgroundedWork, 'Bash sleep 20');
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'ended after 31s unheard',
        ),
      );
      await settle();
      expect(
        a.backgroundedWork,
        'Bash sleep 20',
        reason:
            'the TURN closed unheard; the shell was never '
            'mentioned — the debt keeps the line lit',
      );
      expect(
        a.chat.any((e) => e.blocks.contains('Bash sleep 20 finished.')),
        isFalse,
        reason: 'no bubble while the process may still be running',
      );
      expect(
        a.debugLog.any((l) => l.contains('probing the bridge instead')),
        isTrue,
        reason: 'the receipt urged /health NOW instead of paying',
      );
      // The shell ends with no receipt ever sent: /health now counts
      // zero detached, and THAT pays — with the bubble.
      harness.healthState = {...harness.healthState!, 'detached': 0};
      time.advance(const Duration(seconds: 11));
      await settle();
      expect(a.backgroundedWork, isEmpty);
      expect(
        a.chat.any((e) => e.blocks.contains('Bash sleep 20 finished.')),
        isTrue,
      );
      // The named receipt may still ride in late (backlog replay,
      // proactive report): it cannot mint a second period.
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'Bash sleep 20',
        ),
      );
      await settle();
      expect(
        a.chat
            .where((e) => e.blocks.contains('Bash sleep 20 finished.'))
            .length,
        1,
        reason: 'one completion, one period',
      );
    });

    test(
      'three owed shells are paid three bubbles when the counter clears',
      () async {
        // The banner names only the newest, but the LEDGER remembers
        // them all (+140 — the field case: three sleeps, and the chat
        // said one early nothing and would have said one late nothing
        // too).
        await withBridge();
        unawaited(a.runQuickCommand('start three sleeps'));
        await settle();
        harness.healthState = {
          'ok': true,
          'claudeUp': true,
          'turnOpen': false,
          'queued': false,
          'detached': 3,
        };
        for (final label in ['Bash sleep 45', 'Bash sleep 90']) {
          harness.emit(
            BridgeEvent.forTest(
              'tool',
              toolName: 'backgrounded',
              detail: label,
            ),
          );
          await settle();
        }
        expect(
          a.backgroundedWork,
          'Bash sleep 90',
          reason: 'the line names the newest shell',
        );
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'finished',
            detail: 'ended after 3s unheard',
          ),
        );
        await settle();
        expect(a.chat.any((e) => e.blocks.contains('finished.')), isFalse);
        // One shell reports in by name; the OTHER debt must keep the
        // line lit and re-label onto it.
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'finished',
            detail: 'Bash sleep 45',
          ),
        );
        await settle();
        expect(
          a.chat.any((e) => e.blocks.contains('Bash sleep 45 finished.')),
          isTrue,
          reason: 'the named receipt pays ITS OWN shell',
        );
        expect(
          a.backgroundedWork,
          'Bash sleep 90',
          reason: 'the other debt still owns the line',
        );
        // The counter clears: the rest of the ledger is proven over.
        harness.healthState = {...harness.healthState!, 'detached': 0};
        time.advance(const Duration(seconds: 11));
        await settle();
        expect(a.backgroundedWork, isEmpty);
        expect(
          a.chat.any((e) => e.blocks.contains('Bash sleep 90 finished.')),
          isTrue,
          reason: 'the ledger pays one period per name, not one per banner',
        );
      },
    );

    test('the /health proof of none-detached files the bubble too', () async {
      // A harness that killed the tool with the turn never sends
      // 'finished' at all: the heartbeat's /health proof is then the
      // ONLY completion moment the phone learns, and it owes the
      // chat the same line (+139).
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
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'turnOpen': false,
        'queued': false,
        'detached': 1,
      };
      harness.emit(const BridgeEvent.forTest('done'));
      await settle(); // the launch turn closes, the debt keeps the line
      expect(a.backgroundedWork, 'Bash sleep 20');
      // The process ends without ever sending its receipt: /health
      // now honestly counts zero detached.
      harness.healthState = {...harness.healthState!, 'detached': 0};
      time.advance(const Duration(seconds: 11));
      await settle(); // the heartbeat's proof pays it
      expect(a.backgroundedWork, isEmpty);
      expect(
        a.chat.any((e) => e.blocks.contains('Bash sleep 20 finished.')),
        isTrue,
        reason: 'the lost receipt must not swallow the announcement',
      );
    });

    test('the idle line wakes on the heartbeat when a report opens', () async {
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
      // The launch turn closes; the debt stands. The safety net must
      // KEEP the line lit — /health counts the agent task.
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'turnOpen': false,
        'queued': false,
        'detached': 1,
      };
      harness.emit(const BridgeEvent.forTest('done'));
      await settle();
      expect(
        a.backgroundedWork,
        'Bash sleep 20',
        reason: 'detached 1: the line has work left to name',
      );
      // Ten seconds of idle: the heartbeat reads /health, finds the
      // harness mid-report, and the reattach chain takes the ear.
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'turnOpen': true,
        'backgrounded': true,
        'detached': 1,
      };
      final attaches = harness.attachCount;
      time.advance(const Duration(seconds: 11));
      await settle(); // the heartbeat fires; its chain arms a probe
      time.advance(const Duration(seconds: 1));
      await settle(); // the probe runs and takes the ear
      expect(
        harness.attachCount,
        greaterThan(attaches),
        reason: 'the probe woke the reattach chain for the report',
      );
    });

    test('+144: a queued prompt does NOT arm the bridge cut — the tool '
        'outlives the Queue press', () async {
      await withBridge();
      unawaited(a.runQuickCommand('sleep please'));
      await settle();
      expect(harness.lastCutTool, isFalse);
      unawaited(
        a.runQuickCommand('queued', interrupt: false, bubble: 'queued'),
      );
      await settle();
      expect(harness.lastInterrupt, isFalse);
      expect(
        harness.lastCutTool,
        isFalse,
        reason:
            'the phone stopped asking for cuttool: the CLI aborts '
            'the running call rather than backgrounding it, so Queue '
            'means WAIT, politely and completely',
      );
      expect(a.queuedText, 'queued', reason: 'parked behind the live turn');
      expect(
        a.view.showBackgroundedRow,
        isFalse,
        reason:
            '+145: a queue PIN does not warrant the background line — '
            'the agent waits on its tool in the foreground and the '
            'parked queue view keeps hearing it; that is a wait, not '
            'a background (pin card + spinner tell it)',
      );
    });

    test('+142: a cut tool’s cancelled receipt files “cancelled.” — and '
        'one more replay never files a second period', () async {
      await withBridge();
      unawaited(a.runQuickCommand('sleep please'));
      await settle();
      harness.emit(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'sleep 10'),
      );
      await settle();
      // The killed tool's late result: the bridge relays it kind=
      // cancelled (Claude answered with an error result), and the
      // banner was wearing exactly this step.
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'backgrounded',
          detail: 'Bash sleep 10',
        ),
      );
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'Bash sleep 10',
          toolKind: 'cancelled',
        ),
      );
      await settle();
      expect(
        a.chat.any((e) => e.blocks.contains('Bash sleep 10 cancelled.')),
        isTrue,
        reason:
            'the note carries the verb the agent itself will use — '
            'never finished for a call the cut killed',
      );
      expect(a.backgroundedWork, isEmpty);

      // A backlog replay delivers the same receipt again, and the
      // /health proof then pays the ledger: still exactly one period.
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'Bash sleep 10',
          toolKind: 'cancelled',
        ),
      );
      harness.emit(const BridgeEvent.forTest('done'));
      await settle();
      expect(
        a.chat
            .where((e) => e.blocks.contains('Bash sleep 10 cancelled.'))
            .length,
        1,
      );
      expect(
        a.chat.any((e) => e.blocks.contains('Bash sleep 10 finished.')),
        isFalse,
        reason: 'one completion, one period — whichever verb came first',
      );
    });

    test('a report that opened and CLOSED between heartbeat beats is '
        'drained, not retired over — the answer arrives now, not at the '
        'next prompt (field report: no response unless I ask)', () async {
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
      harness.healthState = {
        'ok': true,
        'claudeUp': true,
        'turnOpen': false,
        'queued': false,
        'detached': 1,
        'missed': 0,
      };
      harness.emit(const BridgeEvent.forTest('done'));
      await settle(); // the launch turn closes; the debt keeps the line
      expect(a.backgroundedWork, 'Bash sleep 20');

      // The report ran and finished BETWEEN beats: nothing open, none
      // detached — but its words are unheard backlog. The proof that
      // would retire the line must not outrank words it never heard.
      harness.healthState = {
        ...harness.healthState!,
        'detached': 0,
        'missed': 2,
      };
      final attaches = harness.attachCount;
      time.advance(const Duration(seconds: 11));
      await settle(); // the heartbeat fires on the missed backlog
      time.advance(const Duration(seconds: 1));
      await settle();
      expect(
        harness.attachCount,
        greaterThan(attaches),
        reason:
            'unheard backlog outranks the retirement proof — drain '
            'first, close the line only when the words have landed',
      );
      expect(a.backgroundedWork, isNotEmpty);

      // The drain delivers the raced report; on the now-clean proof the
      // line retires with its period, and the answer is in the chat.
      harness.emitAttach(
        const BridgeEvent.forTest('say', text: 'The sleep finished, exit 0.'),
      );
      harness.emitAttach(const BridgeEvent.forTest('done'));
      harness.healthState = {...harness.healthState!, 'missed': 0};
      await settle();
      await settle();
      expect(
        a.chat.any((e) => e.blocks.contains('The sleep finished, exit 0.')),
        isTrue,
        reason:
            'the report is HEARD, not left to burst out of a later '
            'prompt\'s replay — out of sync',
      );
      time.advance(const Duration(seconds: 11));
      await settle();
      expect(
        a.backgroundedWork,
        isEmpty,
        reason: 'only now — nothing open, none detached, NOTHING UNHEARD',
      );
    });

    test(
      'the replay lives through a history done to reach the receipt',
      () async {
        await withBridge();
        await a.setBridgeTts(false); // eyes-only, like the field case
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
        harness.healthState = {
          'ok': true,
          'claudeUp': true,
          'turnOpen': true,
          'backgrounded': true,
          'detached': 1,
        };
        harness.emit(const BridgeEvent.forTest('done'));
        await settle(); // the launch turn closes (its done precedes all
        // of the report's frames — the state the phone wakes into)
        time.advance(const Duration(seconds: 5));
        await settle();
        time.advance(const Duration(seconds: 1));
        await settle();
        // The backlog replays the launch turn's farewell FIRST — the
        // report's receipts ride behind it (the device run that found
        // this: the note stayed in the ring and the report went unheard
        // while the banner glowed at nothing).
        harness.emitAttach(const BridgeEvent.forTest('done'));
        await settle();
        harness.emitAttach(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'finished',
            detail: 'Bash sleep 20',
          ),
        );
        harness.emitAttach(
          const BridgeEvent.forTest('say', text: 'The sleep finished.'),
        );
        await settle();
        expect(
          a.chat.any((e) => e.blocks.contains('Bash sleep 20 finished.')),
          isTrue,
          reason: 'a history done must not end the replay early',
        );
        expect(
          a.chat.any((e) => e.blocks.contains('The sleep finished.')),
          isTrue,
          reason: 'the agent\'s report reaches the screen',
        );
        expect(a.backgroundedWork, isEmpty);
        harness.healthState = {
          'ok': true,
          'claudeUp': true,
          'turnOpen': false,
          'detached': 0,
        };
        harness.emitAttach(const BridgeEvent.forTest('done'));
        await settle();
        expect(
          a.chat.any((e) => e.blocks.contains('Bash sleep 20 finished.')),
          isTrue,
          reason: 'one receipt, one period — dedup holds',
        );
        expect(
          a.phase,
          AssistantPhase.idle,
          reason:
              'a text-only answer has no audio to outlive — +133 caught '
              'the orb stuck on Stop my reply through the whole life of '
              'the next shell',
        );
      },
    );

    test('a text-only answer leaves no spinner (+133)', () async {
      await withBridge();
      await a.setBridgeTts(false);
      unawaited(a.runQuickCommand('hello'));
      await settle();
      harness.emit(const BridgeEvent.forTest('say', text: 'All done.'));
      harness.emit(const BridgeEvent.forTest('done'));
      await settle();
      expect(
        a.chat.any((e) => e.blocks.contains('All done.')),
        isTrue,
        reason: 'the words landed — the spoken ledger is non-empty',
      );
      expect(
        a.phase,
        AssistantPhase.idle,
        reason:
            'no audio was ever queued, so nothing may keep the '
            'spinner alive after the done',
      );
    });
  });
}
