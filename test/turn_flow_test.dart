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
    test('PTT: a release with no press says so on the status line (+95)',
        () async {
      a.setMode(InteractionMode.pushToTalk);
      a.pttUp(const Offset(10, 10)); // never went down
      expect(a.status, contains("That press didn't land"));
      expect(a.phase, AssistantPhase.idle); // never stomped a live phase
    });

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
      expect(a.status, isNot(contains("That press didn't land")),
          reason: 'only an idle phase may host the swallowed-press notice');
    });

    test('conversation: a swallowed release dispatches the toggle itself '
        '(+80)', () async {
      a.pttUp(Offset.zero); // hold guide ate the press; the release lands
      await settle();
      expect(a.phase, AssistantPhase.listening);
      expect(mic.startCount, 1); // the tap started the conversation
      expect(a.debugLog.any((l) => l.contains('fallback toggle dispatch')),
          isTrue);
    });

    test('every big-button tap journals its dispatch (0.1.0+79)', () async {
      await a.toggle();
      await settle();
      expect(
        a.debugLog.any((l) =>
            l.contains('TOGGLE: mode=conversation phase=') &&
            l.contains('busy=false')),
        isTrue,
      );
    });
  });

  group('harness turns (0.1.0+72, +76, +85, +89, +94)', () {
    test('a press over a live turn detaches it and keeps the spinner',
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
      expect(a.harnessBackgrounded, isTrue,
          reason: 'the badge must stay lit while it works unheard');
      expect(a.liveTurnBubble, isNotNull,
          reason: 'the work bubble must survive the press (+91)');
      expect(harness.viewDetached, isTrue,
          reason: 'the phone must stop reading the old view');
      expect(harness.stops, 0,
          reason: 'a spoken takeover is a detach, never a /stop');
    });

    test('tool steps update the label; plumbing steps are eyes-only',
        () async {
      await withBridge();
      await a.setBridgeNarrate(true);
      unawaited(a.runQuickCommand('go'));
      await settle();

      harness.emit(BridgeEvent.forTest('tool', toolName: 'Bash',
          detail: 'flutter test', toolKind: 'calling Bash'));
      await settle();
      expect(a.status, 'Bash flutter test…'); // the command itself (+89)
      time.advance(const Duration(seconds: 16)); // a full heartbeat pulse
      await settle();
      expect(engine.synthesized.where((t) => t.contains('Bash')), isEmpty,
          reason: 'Bash is eyes-only (+73): no immediate line, no heartbeat');

      // The first speakable step (nothing audible yet this turn):
      harness.emit(BridgeEvent.forTest('tool', toolName: 'Deploy',
          detail: 'eu-west-1'));
      await settle();
      expect(a.status, 'Deploy eu-west-1…');
      expect(engine.synthesized.any((t) => t.contains('Deploy')), isTrue,
          reason: 'a custom tool is news, not plumbing (+94)');

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
      harness.emit(BridgeEvent.forTest('tool', toolName: 'Read',
          detail: 'lib/foo.dart'));
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

    test('say frames speak cleaned text and enter the log with the audio',
        () async {
      await withBridge();
      unawaited(a.runQuickCommand('summary?'));
      await settle();

      harness.emit(BridgeEvent.forTest('say',
          text: '**Done** — three files changed (see `pubspec.yaml`).'));
      await settle();
      expect(
        engine.synthesized,
        contains('Done — three files changed (see pubspec yaml).'),
      );
      // The chat bubble holds the cleaned block, not the raw markdown.
      expect(a.chat.last.blocks.single,
          'Done — three files changed (see pubspec yaml).');
      expect(a.phase, AssistantPhase.speaking);
      expect(a.hopTts, isTrue, reason: 'the reply→audio hop lit');

      out.complete(); // the chunk ran out: the conversation idles again
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      await settle();
      expect(a.bridgeBusy, isFalse);
    });

    test('a turn that ran with nothing to say is not a bubble', () async {
      await withBridge();
      unawaited(a.runQuickCommand('/compact'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      await settle();
      expect(a.chat.where((e) => !e.fromUser), isEmpty,
          reason: 'the blank bubble is taken back out of the log');
      expect(a.status, contains('nothing to say'));
    });
  });

  group('the live token ticker (0.1.0+77, +84, +85, +93)', () {
    test('the counter grows between relays and freezes on tool steps',
        () async {
      await withBridge();
      unawaited(a.runQuickCommand('think hard'));
      await settle();

      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'tokens', toolKind: 'thinking',
          outTokens: 100, inputTokens: 4000, wireMs: 1));
      await settle();
      expect(a.tokenTickerOn, isTrue);
      expect(a.activityLabel, 'Thinking…'); // words only (+85)
      expect(a.tokensOut, 100);

      // The first relay can teach nothing (no previous point); a step-up
      // a second later learns the rate — and then the estimate grows.
      time.advance(const Duration(seconds: 1));
      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'tokens', toolKind: 'thinking',
          outTokens: 200, inputTokens: 4200));
      await settle();
      expect(a.tokensOut, 200); // the bridge's figure is authoritative
      time.advance(const Duration(milliseconds: 500));
      expect(a.tokensOut, greaterThan(200),
          reason: 'the ticker moves between relays');

      // +93: `in` is the turn's delta (4200-4000), not the raw context.
      expect(a.tokensIn, 200);

      // A real step freezes the ticker: nothing is generating.
      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'Bash', detail: 'flutter analyze'));
      await settle();
      expect(a.tokenTickerOn, isFalse);
      time.advance(const Duration(seconds: 30));
      expect(a.tokensOut, 200, reason: 'no inflation while a tool runs');
    });

    test('+93: a smaller in-figure re-anchors (compact mid-turn)',
        () async {
      await withBridge();
      unawaited(a.runQuickCommand('x'));
      await settle();
      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'tokens', toolKind: 'thinking',
          outTokens: 5, inputTokens: 9000));
      await settle();
      expect(a.tokensIn, 0); // anchored at 9000: no delta yet
      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'tokens', toolKind: 'thinking',
          outTokens: 10, inputTokens: 1500));
      await settle();
      expect(a.tokensIn, 0); // re-anchored lower, not negative
      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'tokens', toolKind: 'thinking',
          outTokens: 20, inputTokens: 1800));
      await settle();
      expect(a.tokensIn, 300); // the turn's growth since the re-anchor
    });

    test('+84: the wheel stops when the answer is settled', () async {
      await withBridge();
      unawaited(a.runQuickCommand('answer fast'));
      await settle();
      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'tokens', toolKind: 'answering',
          outTokens: 40, draft: 'Here you go:'));
      await settle();
      expect(a.tokenDraft, 'Here you go:'); // painted before it is spoken
      expect(a.turnSettled, isFalse);

      harness.emit(BridgeEvent.forTest('tool', toolName: 'tokens',
          toolKind: 'settled', draft: 'Here you go:'));
      await settle();
      expect(a.turnSettled, isTrue); // the wheel must stop (+84)
      expect(a.tokenDraft, 'Here you go:',
          reason: '+83: settled keeps the draft until the say claims it');

      harness.emit(BridgeEvent.forTest('say', text: 'Here you go: done.'));
      await settle();
      expect(a.tokenDraft, isEmpty,
          reason: 'the say stops the ticker: the draft getter goes quiet');
      expect(a.turnSettled, isTrue,
          reason: 'settled is the turn’s state until resetForTurn');
    });
  });

  group('the polite queue and its pin (0.1.0+81, +90)', () {
    test('push view: any frame of our own stream dissolves the pin',
        () async {
      await withBridge();
      unawaited(a.runQuickCommand('busy turn'));
      await settle();

      // An interrupt-off press over the live turn parks (pins) instead.
      unawaited(a.runQuickCommand('parked', interrupt: false,
          bubble: 'parked'));
      await settle();
      expect(a.queuedText, 'parked');

      harness.emit(BridgeEvent.forTest('say', text: 'answer'));
      await settle();
      expect(a.queuedText, isNull,
          reason: 'a per-turn SSE view: the first frame IS the pickup');
    });

    test('poll view: the pin waits for the bridge’s explicit started',
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
      unawaited(a.runQuickCommand('parked',
          interrupt: false, bubble: 'parked'));
      await settle();
      expect(a.queuedText, 'parked');
      expect(harness.talkPollCount, greaterThan(0),
          reason: 'the ring is advertised: the prompt rides the pull '
              'transport');

      // A frame of the BUSY turn flows past on the shared ring — on the
      // old push-only rule this dissolved the pin and the queue promise
      // evaporated (+81).
      harness.pollPages.add(FakeHarness.page(11, [
        BridgeEvent.forTest('say', text: 'unrelated turn chatter'),
      ], first: 11));
      time.advance(const Duration(milliseconds: 300));
      await settle();
      expect(a.queuedText, 'parked',
          reason: 'poll frames are not our pickup — the pin stays');

      // The bridge's explicit word that it has the prompt NOW:
      harness.pollPages.add(FakeHarness.page(12, [
        BridgeEvent.forTest('tool', toolName: 'started', detail: 'parked'),
      ], first: 12));
      time.advance(const Duration(milliseconds: 300));
      await settle();
      expect(a.queuedText, isNull);
      expect(
        a.debugLog.any((l) => l.contains('queue picked up')),
        isTrue,
      );
    });
  });

  group('barge-in and the AEC trust window', () {
    test('speech in the first 450 ms is our own leak; later is a cut',
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
    });

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

      expect(out.played.where((c) => c.$1.length == 2400), isEmpty,
          reason: 'the reply audio is still mid-synth (UI blips exempt)');
      expect(a.phase, isNot(AssistantPhase.speaking));
      expect(
        a.chat.any((e) =>
            !e.fromUser && e.blocks.contains('Stuck in the synth.')),
        isTrue,
        reason: 'committed text must be in the bubble AND the dedup '
            'ledger before a single chunk plays',
      );

      gate.complete(); // the speaker gets it after all: once, and only once
      await settle();
      expect(out.played.where((c) => c.$1.length == 2400), hasLength(1));
    });

    test('the queue verdict gets its own bubble, not the turn\'s (+110)',
        () async {
      await withBridge();
      await a.toggle();
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle(); // harness turn opens (empty assistant bubble)
      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'queued',
          detail: 'the thinking was interrupted and aborted; '
              'your message goes next'));
      await settle();

      final verdicts = a.chat
          .where((e) => !e.fromUser && e.blocks.any(
              (b) => b.startsWith('One moment — the thinking')))
          .toList();
      expect(verdicts, hasLength(1));
      expect(verdicts.single.blocks, hasLength(1),
          reason: 'a note all by itself: nothing of the answer, nothing '
              'of the cut turn — its own card in the channel');
      // The answer's own bubble (the empty assistant entry the turn
      // opened) sits BEFORE the note and holds none of it.
      final cutTurn = a.chat[a.chat.indexOf(verdicts.single) - 1];
      expect(cutTurn.fromUser, isFalse);
      expect(cutTurn.blocks, isEmpty);
    });

    test('a cut silent turn still leaves its trace (+110)', () async {
      await withBridge();
      await a.toggle();
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle(); // turn 1 runs, speaks nothing (a tool works)
      harness.emit(BridgeEvent.forTest('tool',
          toolName: 'Bash', detail: 'sleep 60'));
      await settle();

      time.advance(const Duration(milliseconds: 500));
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle(); // turn 2 supersedes turn 1 before its first word

      final cut = a.chat
          .where((e) =>
              !e.fromUser &&
              e.blocks.contains('Interrupted before answering.'))
          .single;
      expect(cut.interrupted, isTrue,
          reason: 'stamped, so the bubble also carries the +108 mark');
    });

    test('the tail of our own echo is rejected before it ever sends',
        () async {
      engine.transcripts = ['hello there', 'hello there again'];
      await a.toggle();
      await settle();
      engine.deliver(SpeechEvent.ofSegment(Float32List(32000)));
      await settle();
      expect(a.chat.any((e) => e.fromUser && e.blocks.first == 'hello there'),
          isTrue);

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
      expect(
        a.debugLog.any((l) => l.contains('reopening')),
        isTrue,
      );
    });

    test('a stalled (silent, never-closed) stream trips the watchdog',
        () async {
      await a.toggle();
      await settle();
      time.advance(const Duration(milliseconds: 1300)); // no bytes at all
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await settle();
      expect(mic.startCount, 2);
    });

    test('a reopen that ducks mid-reply waits for the audio to end',
        () async {
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
      expect(mic.startCount, 2,
          reason: '…and the deferred reopen fires immediately');
    });
  });

  group('zombie wire and reattach (the background→foreground fix)', () {
    test('24 s of silence on a live turn hops to a fresh /attach view',
        () async {
      await withBridge();
      harness.healthState = {'ok': true, 'claudeUp': true, 'turnOpen': true};
      unawaited(a.runQuickCommand('long build'));
      await settle();

      // The bridge pings every 15 s; a full quiet window with NOTHING
      // crossing means the route died quietly. 25 s of silence:
      time.advance(const Duration(seconds: 25));
      await settle();

      expect(a.harnessBackgrounded || a.bridgeBusy, isTrue,
          reason: 'the turn is still alive on the bridge');
      expect(harness.attachCount, 1, reason: 'the chain stole a fresh view');
      expect(a.status, contains('Reattached'));

      // The reattached view speaks the story that went unheard:
      harness.emitAttach(BridgeEvent.forTest('say', text: 'Build done.'));
      await settle();
      expect(engine.synthesized.any((t) => t.contains('Build done')), isTrue);
      expect(a.chat.last.blocks, contains('Build done.'));
    });

    test('an old unheard paragraph is logged, never re-voiced', () async {
      await withBridge();
      harness.healthState = {'ok': true, 'claudeUp': true, 'turnOpen': true};
      unawaited(a.runQuickCommand('go'));
      await settle();
      harness.finishView(); // the view died mid-turn, no done frame
      await settle();
      expect(harness.attachCount, greaterThan(0));

      // An archaeology frame: 5 minutes old and not in the chat log.
      final ancient = time.now
              .subtract(const Duration(minutes: 5))
              .millisecondsSinceEpoch -
          1; // ~300 s wire age after skew ~0
      harness.emitAttach(BridgeEvent.forTest(
          'say', text: 'Something from before', wireMs: ancient));
      await settle();
      expect(a.chat.last.blocks, contains('Something from before.'),
          reason: 'it belongs to the history… (cleaned, as stored)');
      expect(engine.synthesized.any((t) => t.contains('Something from before')),
          isFalse,
          reason: '…but the user already heard it; never re-voice');
    });
  });

  group('latency bench', () {
    test('a bench run transcribes the capture and echoes it, timed',
        () async {
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
      expect(out.played.where((c) => c.$1.length == 2400), hasLength(1),
          reason: 'the echo reached the player (warm-up aside)');
      expect(a.benchBusy, isFalse);
    });
  });
}
