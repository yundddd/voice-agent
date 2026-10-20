// Direct unit tests for BridgeTurn — the ONE harness event loop (the
// /talk listener, control streams, and the /attach replay). The
// orchestrator-level equivalents live in turn_flow_test.dart; these
// drive the turn object ITSELF with no VoiceAssistant, no mic, and no
// device, which is the point of the extraction: a queue/detach/receipt
// rule can now be pinned at the exact level it lives on.
//
// The fakes are the same scripted outer seams (models, speaker) the
// integration suite uses; the assistant-side truth is a recording
// [EnvProbe] so every effect the loop has on the UI/journal/chain is
// asserted, not inferred from a screen.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/activity.dart';
import 'package:voice_agent/src/assistant/bridge_turn.dart';
import 'package:voice_agent/src/assistant/chat_store.dart';
import 'package:voice_agent/src/assistant/hop_tracker.dart';
import 'package:voice_agent/src/assistant/narration_gate.dart';
import 'package:voice_agent/src/assistant/reply_pipeline.dart';
import 'package:voice_agent/src/assistant/state.dart';
import 'package:voice_agent/src/assistant/token_ticker.dart';
import 'package:voice_agent/src/assistant/turn_session.dart';
import 'package:voice_agent/src/bridge/bridge_event.dart';
import 'package:voice_agent/src/bridge/text_rules.dart';
import 'package:voice_agent/src/bridge/transport.dart';
import 'package:voice_agent/src/bridge/wire_lease.dart';
import 'package:voice_agent/src/chat/chat_log.dart';
import 'package:voice_agent/src/common/sinks.dart';
import 'package:voice_agent/src/platform/audio_output.dart';

import 'support/fakes.dart';

Future<void> settle({int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Records every effect the loop has on the assistant side.
class EnvProbe {
  EnvProbe({required this.now});

  DateTime Function() now;
  InteractionMode mode = InteractionMode.pushToTalk;
  bool backgrounded = false, narrate = false;
  AssistantPhase phase = AssistantPhase.transcribing;
  int generation = 1;
  int seq = 1;
  bool busy = true, badge = false, errored = false;

  final List<Activity> statuses = [];
  final List<AssistantPhase> phases = [];
  final List<String> logs = [];
  final List<bool> journaled = [];
  final List<(int, int)> merged = [];
  final List<String> replyTexts = [], unheardSays = [], spoke = [], fails = [];
  final Set<String> dropped = {};
  final List<
    ({int gen, int seq, bool retire, bool resetStep, Duration? firstProbe})
  >
  arms = [];
  final List<(int, int)> drains = [];

  /// wire v2: the loop's heard-ledger seam — what it skipped as a dup
  /// (isHeard input) and what it acked (commitHeard input).
  final Set<int> alreadyHeard = {};
  final List<int> took = [];
  int repaints = 0, firstWords = 0, audioActivity = 0, refreshes = 0;
  String lastReceiptId = ''; // +186: what the finished frame stamped
  bool dropMarkCleared = false, idled = false;

  bool get speaking => phase == AssistantPhase.speaking;

  BridgeTurnEnv get env => BridgeTurnEnv(
    mode: () => mode,
    backgrounded: () => backgrounded,
    narrateOn: () => narrate,
    speakingNow: () => speaking,
    generation: () => generation,
    turnSeq: () => seq,
    busy: () => busy,
    badgeLit: () => badge,
    hasError: () => errored || fails.isNotEmpty,
    mergeContext: (i, w) => merged.add((i, w)),
    setStatus: statuses.add,
    setPhase: (ph) => phases.add(ph),
    markSpeaking: () => phase = AssistantPhase.speaking,
    idleReady: () => idled = true,
    fail: fails.add,
    noteHarnessError: () => errored = true,
    noteReplyText: replyTexts.add,
    noteUnheardSay: unheardSays.add,
    noteSpoken: spoke.add,
    isDropped: dropped.contains,
    blockAired: () => dropMarkCleared = true,
    noteFirstWord: (_) => firstWords++,
    noteAudioActivity: () => audioActivity++,
    refreshSession: () async => refreshes++,
    armReattach:
        ({
          required int gen,
          required int seq,
          bool retire = false,
          bool resetStep = true,
          Duration? firstProbe,
        }) => arms.add((
          gen: gen,
          seq: seq,
          retire: retire,
          resetStep: resetStep,
          firstProbe: firstProbe,
        )),
    drainBacklog: (gen, seq) async => drains.add((gen, seq)),
    ttsOff: () => ttsOff,
    retireBgWork: (d, {bool cancelled = false, String taskId = ''}) {
      lastReceiptId = taskId; // +186: the frame's task id rides the seam
      retiredBg.add((d, cancelled));
      // The assistant's law (see _retireBgWork): the promise is paid,
      // and a lit badge goes with it.
      coord?.clearBgWork();
      if (badge) coord?.retireBadgeAndWork();
    },
    parkCutTrace: (e) => parked = e,
    cutTrace: () => parked,
    promptBumps: () => promptBumps,
    phase: () => phase,
    armBgProbe: ({Duration every = const Duration(seconds: 10)}) => bgProbes++,
    turnOpenOnWire: () async => turnOpen,
    notePickup: () => pickups++,
    awaitingPickup: () => false,
    isHeard: alreadyHeard.contains,
    commitHeard: took.add,
    log: (line, {bool toJournal = true}) {
      logs.add(line);
      journaled.add(toJournal);
    },
    repaint: () => repaints++,
  );

  // Ports of the +131..+133 rules the loop now consults; tests flip
  // these to drive the new branches.
  bool ttsOff = false, turnOpen = false;
  int promptBumps = 0, bgProbes = 0, pickups = 0;
  final List<(String, bool)> retiredBg = [];
  ChatEntry? parked;
  TurnCoordinator? coord;
}

void main() {
  late FakeScheduler time;
  late FakeSpeechEngine engine;
  late FakeAudioOutput out;
  late ChatStore chat;
  late TurnCoordinator turn;
  late EnvProbe probe;
  late List<String> persisted;

  late BridgeTurn turnLoop;
  late StreamController<BridgeEvent> wire;
  late int mySeq;
  late ChatEntry bubble;

  setUp(() {
    time = FakeScheduler(DateTime(2026, 1, 1, 12));
    engine = FakeSpeechEngine();
    out = FakeAudioOutput();
    persisted = [];
    probe = EnvProbe(now: () => time.now);
    chat = ChatStore(
      persist: (json) async => persisted.add(json),
      repaint: () {},
    );
    turn = TurnCoordinator(
      clock: () => time.now,
      log: (m) => probe.logs.add(m),
      hardStop: () async {},
      beforeDetach: () {},
      afterDetach: () {},
      queuedPin: () => chat.queuedBubble != null,
    );
    wire = StreamController<BridgeEvent>();
  });

  tearDown(() {
    // NOT awaited: a single-subscription controller that was never
    // listened to (or whose subscription was cancelled by a detach)
    // completes its close-future only when done is consumed — which a
    // dead view never does.
    if (!wire.isClosed) unawaited(wire.close());
  });

  /// Wires a loop with real collaborators over the fakes.
  void mkTurn({
    BridgeTurnOrigin origin = BridgeTurnOrigin.talk,
    int gen = 1,
    String? ack,
    String utterance = 'go',
  }) {
    mySeq = turn.claimSlot();
    probe.seq = mySeq;
    probe.generation = gen;
    probe.busy = true;
    probe.coord = turn;
    final ticker = TokenTicker(clock: () => time.now, repaint: () {});
    final hops = HopTracker(
      clock: () => time.now,
      scheduler: time,
      repaint: () {},
    );
    final reply = ReplyPipeline(
      output: out,
      worker: () => engine,
      clock: () => time.now,
      scheduler: time,
      repaint: () {},
      userSpeaking: () => false,
      gatePin: (_) {},
      resetVad: () {},
      onNaturalEnd: () {},
      onStopped: () {},
    );
    bubble = chat.beginTurn();
    reply.startStream(); // the producer-side seam the loop feeds
    turnLoop = BridgeTurn(
      origin: origin,
      env: probe.env,
      turn: turn,
      chat: chat,
      ticker: ticker,
      narr: NarrationGate(clock: () => time.now),
      hops: hops,
      reply: reply,
      lease: WireLease(
        scheduler: time,
        clock: () => time.now,
        attached: () => probe.busy,
        paused: () => false,
        audioDraining: () => false,
        onQuiet: (_) {},
      ),
      transport: BridgeTransport(
        scheduler: time,
        clock: () => time.now,
        log: (_) {},
      ),
      scheduler: time,
      // (v2: the in-process airborne set retired — the loop dedups
      // by mid through the env recorder above.)
      gen: gen,
      mySeq: mySeq,
      turnBubble: bubble,
      utterance: utterance,
      ack: ack,
    );
    // The chunk player the loop feeds — the assistant's _startPump twin.
    unawaited(reply.runPump(isStale: () => false));
  }

  group('the heard /talk loop', () {
    test('a say speaks the cleaned text and enters the ledger at the '
        'FIRST SOUND, not at the queue', () async {
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      expect(probe.logs.first, startsWith('TALK open: gen=1 interrupt=1'));
      wire.add(BridgeEvent.forTest('say', text: '**Done** — three files.'));
      wire.add(BridgeEvent.forTest('done'));
      final outcome = await r;
      out.complete();
      await settle();
      expect(outcome.sawDone, isTrue);
      expect(engine.synthesized, ['Done — three files.']);
      expect(bubble.blocks, ['Done — three files.']);
      expect(
        probe.firstWords,
        1,
        reason: 'the strip stamped first-word latency',
      );
      expect(
        probe.logs,
        containsAllInOrder([
          // The live say line mirrors the RAW frame (the loop logs what
          // arrived, speaks the cleaned text — same law as before the
          // extraction).
          contains('msg harness: say "**Done** — three files."'),
          contains('TALK end gen=1: done clean'),
        ]),
      );
      expect(engine.synthesized, [
        'Done — three files.',
      ], reason: 'spoken text is the cleaned one');
      expect(probe.arms, isEmpty, reason: 'a clean done reattaches to nothing');
      expect(probe.drains, [(1, mySeq)], reason: 'every heard turn end drains');
    });

    test('+179: a say that IS tool-call markup: taken, acked, spoken '
        'by nobody', () async {
      // The 13:11 field tape's frame: the upstream wrote its call in
      // prose; the phone's scrubber strips the span (arguments with
      // it — a lone 'flutter test' would promise a run that never
      // happened) and what is left is nothing. Nothing is shown,
      // nothing is said; the frame is still TAKEN (the drain acks
      // ride the id, not the mouthfeel).
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'say',
          mid: 9,
          text:
              '<tool_call>\n<function name="Bash">\n'
              '<parameter name="command">flutter test</parameter>'
              '</function></tool_call>',
        ),
      );
      wire.add(const BridgeEvent.forTest('say', text: 'On it.', mid: 10));
      wire.add(BridgeEvent.forTest('done'));
      final outcome = await r;
      out.complete();
      await settle();
      expect(outcome.sawDone, isTrue);
      expect(engine.synthesized, [
        'On it.',
      ], reason: 'only the prose reaches the mouth');
      expect(bubble.blocks, ['On it.'], reason: 'and only it hits the screen');
      expect(
        probe.logs.any((l) => l.contains('pure tool-call markup')),
        isTrue,
        reason: 'the drop is journalled — future tapes read honest',
      );
    });

    test('+163: a steered pickup makes the turn heard and promises no '
        'banner — the fold law on the phone side', () async {
      // The bridge folded this prompt into the RUNNING turn at a tool
      // boundary: the pickup arrives as a marker tagged kind='steered'
      // carrying OUR reserved id. Neither arm of the old started
      // branch fits it: not 'background' (nothing was cut — no
      // promise, no banner debt), not a bare idle-bridge pickup (the
      // turn was already working). It must simply make the turn heard.
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'queued',
          detail:
              'a tool call is running; your message will steer the '
              'turn at its next pause',
          turn: 77,
          mid: 10,
        ),
      );
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'started',
          detail: 'the steer',
          toolKind: 'steered',
          turn: 77,
          mid: 11,
        ),
      );
      wire.add(
        const BridgeEvent.forTest('say', text: 'Steered answer.', mid: 12),
      );
      wire.add(const BridgeEvent.forTest('done', turn: 77, mid: 13));
      final outcome = await r;
      out.complete();
      await settle();
      expect(outcome.sawDone, isTrue);
      expect(
        probe.pickups,
        1,
        reason: 'the steered marker IS the pickup: the wait ends there',
      );
      expect(probe.logs, contains(contains('queue picked up: "the steer"')));
      expect(
        turn.detachedPromise,
        isFalse,
        reason: 'nothing was cut — no banner promise rides a steer',
      );
      expect(
        turn.bgWork,
        isEmpty,
        reason: 'and the bottom line owes the host turn nothing either',
      );
      expect(
        engine.synthesized,
        contains('Steered answer.'),
        reason: 'the host turn\u2019s continuation is spoken to the steerer',
      );
      expect(
        bubble.blocks,
        contains('Steered answer.'),
        reason: 'and shown (+161), the moment it lands',
      );
    });

    test('+159: consumption IS the ack — every non-say frame the pump '
        'digests is committed, or the bridge backlog never drains', () async {
      // The 0.1.0+159 field loop: the phone digested the replayed
      // backlog but only SAYES got committed, so `missed` stuck at a
      // dead number — the heartbeat read it as a streaming report,
      // re-attached every 10 s, and the thinking box flashed while the
      // banner could never retire (the retire proof demands missed==0).
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'Bash',
          detail: 'cargo build',
          mid: 11,
        ),
      );
      wire.add(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 4242,
          contextWindow: 200000,
          mid: 12,
        ),
      );
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          detail: 'thinking · 1.2k out',
          mid: 13,
        ),
      );
      wire.add(
        const BridgeEvent.forTest('say', text: 'Brief answer.', mid: 14),
      );
      wire.add(const BridgeEvent.forTest('done', mid: 15));
      final outcome = await r;
      out.complete();
      await settle();
      expect(outcome.sawDone, isTrue);
      expect(
        probe.took,
        containsAll(<int>[11, 12, 13, 14, 15]),
        reason:
            'tool, context, tally and farewell frames are TAKEN the '
            'moment they are digested — the bridge trims its backlog '
            'only under /heard',
      );
    });

    test('+161: a say frozen mid-synth is on the screen at the take — '
        'its air adds sound, not a second copy', () async {
      final gate = Completer<void>();
      engine.holdChunks = gate.future;
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(BridgeEvent.forTest('say', text: 'Stuck in the synth.'));
      wire.add(BridgeEvent.forTest('done'));
      await settle();
      expect(
        bubble.blocks,
        ['Stuck in the synth.'],
        reason:
            'the bubble mirrors the WIRE (+161, inverting +116): '
            'received text waits for its audio in the open, so the '
            'reader can see the answer and press past the speaker',
      );
      expect(out.played, isEmpty, reason: 'no audio reached the player');
      gate.complete();
      await r;
      out.complete();
      await settle();
      expect(bubble.blocks, [
        'Stuck in the synth.',
      ], reason: 'stamped once at the take — the air never re-writes it');
    });

    test('a wire death without done arms the reattach chain and leaves '
        'the turn usable (+114 retraction, +111 drain skipped)', () async {
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(BridgeEvent.forTest('say', text: 'Heard, this one.'));
      await settle();
      out.complete();
      wire.add(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'cargo build'),
      );
      await settle();
      expect(probe.statuses.last.text(mode: probe.mode), 'Bash cargo build…');
      wire.add(
        BridgeEvent.forTest(
          'tool',
          toolName: 'Read',
          detail: 'lib/src/bridge.dart',
        ),
      );
      await settle();
      expect(
        probe.statuses.last.text(mode: probe.mode),
        'Read bridge.dart…',
        reason: 'file steps show the BASENAME (eyes keep the line)',
      );
      wire.addError(Exception('socket died')); // no done, no error frame
      final outcome = await r;
      expect(outcome.closedWithoutDone, isTrue);
      expect(
        probe.arms.single.gen,
        1,
        reason: 'UNOWNED: the turn is the bridge\'s to finish',
      );
      expect(probe.drains, isEmpty, reason: 'the chain owns the recovery');
      expect(
        probe.statuses.last,
        isA<StepLine>(),
        reason: 'the last known step still labels the dead view',
      );
      expect(probe.logs.last, contains('UNOWNED, reattach chain armed'));
      expect(bubble.blocks, [
        'Heard, this one.',
      ], reason: 'what aired is heard history');
    });

    test('a superseded teardown bows out to the successor: no release, '
        'no reattach, only the drain', () async {
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      final nextSeq = turn.claimSlot(); // a successor took the slot
      expect(nextSeq, isNot(mySeq));
      probe.generation = 99; // and bumped the generation
      await wire.close(); // the parked loop wakes on the seam and leaves
      final outcome = await r;
      await settle();
      expect(outcome.stale, isTrue);
      expect(turn.busy, isTrue, reason: 'the slot belongs to the successor');
      expect(probe.arms, isEmpty);
      expect(
        probe.drains,
        [(1, mySeq)],
        reason:
            'teardown offers the drain on every non-orphan exit — '
            'the ownership re-check inside the drain is what vetoes it',
      );
      expect(
        probe.statuses,
        isEmpty,
        reason: 'a stale loop paints nothing new',
      );
    });

    test('the queue receipt unpins, retires the badge and re-anchors the '
        'spinner clock', () async {
      mkTurn(utterance: 'parked'); // +155: markers match their prompt
      chat.addUser('parked', queued: true);
      turn.beginHeardTurn();
      turn.becomeHeard();
      turn.noteToolStep('Bash npm test…');
      turn.markBackgrounded();
      probe.badge = true;
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest('tool', toolName: 'started', detail: 'parked'),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(chat.queuedBubble, isNull, reason: 'the pin dissolved on pickup');
      expect(turn.backgrounded, isFalse);
      expect(
        turn.bgWork,
        isEmpty,
        reason: 'a dead step cannot re-surface behind a new pin',
      );
      expect(probe.logs, contains(contains('queue picked up: "parked"')));
    });

    test('the finished receipt dismisses the bottom line; the live '
        'spinner\'s age is not its business', () async {
      mkTurn();
      turn.becomeHeard();
      final since = turn.since;
      time.advance(const Duration(seconds: 12));
      turn.markBackgrounded();
      turn.noteToolStep('Bash npm test…');
      probe.badge = true;
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'ended after 9s unheard',
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(turn.bgWork, isEmpty);
      expect(turn.backgrounded, isFalse);
      // +131: the receipt's retirement (and its naming) is the
      // assistant's law now — the loop just hands the detail over.
      expect(
        probe.retiredBg,
        contains(('ended after 9s unheard', false)),
        reason: 'the finished frame funnels through the retirement hook',
      );
      expect(turn.since, isNull, reason: 'the badge retired WITH the clock');
      expect(since, isNotNull);
    });

    test('+186: a finished frame’s TASK ID rides to the receipt seam — '
        'the dedup’s identity is the stamp, not the text', () async {
      mkTurn();
      turn.becomeHeard();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'Bash sleep 10 && echo done',
          taskId: 'bz960t1as',
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(
        probe.lastReceiptId,
        'bz960t1as',
        reason: 'the frame’s own stamp survives the loop intact',
      );
    });

    test('+110/+146: a queued verdict paints the status line, journals — '
        'and injects NO bubble (the greyed message is the wait '
        'indicator)', () async {
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'tool',
          toolName: 'queued',
          detail:
              'the thinking was interrupted and aborted; your message '
              'goes next',
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(
        probe.statuses.whereType<QueuedVerdict>(),
        hasLength(1),
        reason:
            'the verdict painted the line (whatever the no-speech '
            'teardown line renders after it)',
      );
      expect(
        probe.statuses.whereType<QueuedVerdict>().single.text(mode: probe.mode),
        'One moment — the thinking was interrupted and aborted; your '
        'message goes next.',
      );
      expect(
        chat.containsBlock(
          'One moment — the thinking was interrupted and aborted; your '
          'message goes next.',
        ),
        isFalse,
        reason:
            '+146: no injected system card — the queued message '
            'greys in place instead; the verdict lives in the status '
            'line and the journal',
      );
      expect(
        probe.logs,
        contains(contains('queue verdict')),
        reason: 'the decision is still journalled with its wire stamp',
      );
      expect(
        turn.lastToolStep,
        isEmpty,
        reason:
            'a verdict is not a tool call: it cannot label the '
            'bottom line',
      );
    });

    test('a control turn with nothing to say speaks the ack and owes no '
        'reattach (no /talk connection existed)', () async {
      mkTurn(
        origin: BridgeTurnOrigin.control,
        ack: 'Starting a new conversation.',
      );
      final outcome = await turnLoop.run(Stream<BridgeEvent>.empty());
      await settle();
      out.complete();
      await settle();
      expect(outcome.closedWithoutDone, isTrue);
      expect(engine.synthesized, ['Starting a new conversation.']);
      expect(probe.arms, isEmpty, reason: 'the /new carve-out');
      expect(probe.logs.first, 'CONTROL stream open (no /talk): go');
    });

    test('a done frame carrying the harness error flags the turn', () async {
      mkTurn();
      final r = turnLoop.run(wire.stream);
      wire.add(BridgeEvent.forTest('done', isError: true));
      await r;
      await settle();
      expect(probe.errored, isTrue);
    });
  });

  group('hidden says and the resume promise', () {
    test('+116: while hidden, says log text-only and the MOST RECENT '
        'buffers for the resume — no synth at all', () async {
      mkTurn();
      probe.backgrounded = true;
      final r = turnLoop.run(wire.stream);
      wire.add(BridgeEvent.forTest('say', text: 'First while hidden.'));
      wire.add(BridgeEvent.forTest('say', text: 'The answer itself.'));
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(
        engine.synthesized,
        isEmpty,
        reason: 'no audio is EXPECTED hidden',
      );
      expect(bubble.blocks, ['First while hidden.', 'The answer itself.']);
      expect(probe.unheardSays, [
        'First while hidden.',
        'The answer itself.',
      ], reason: 'the newest is what the resume path speaks');
      expect(
        probe.dropMarkCleared,
        isFalse,
        reason: 'hidden commits never air: nothing outranks a drop mark',
      );
    });

    test('a paragraph marked for the hide skips its AIR, not its words '
        '(+161)', () async {
      mkTurn();
      final cut = cleanForSpeech('Cut mid-play.');
      probe.dropped.add(cut);
      final r = turnLoop.run(wire.stream);
      wire.add(BridgeEvent.forTest('say', text: 'Cut mid-play.'));
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(out.played, isEmpty, reason: 'the chunk guard killed it');
      expect(
        bubble.blocks,
        ['Cut mid-play.'],
        reason:
            'the old law lost a hide-cut answer ENTIRELY (never '
            'aired, never shown, already acked — gone); +161 keeps '
            'the words and skips only the voice',
      );
      expect(probe.dropMarkCleared, isFalse);
    });
  });

  group('the /attach replay loop', () {
    test('backlog frames never fake the pickup: the pin stays', () async {
      mkTurn(origin: BridgeTurnOrigin.attach);
      chat.addUser('parked', queued: true);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(BridgeEvent.forTest('say', text: 'Old turn chatter.'));
      await settle();
      out.complete();
      expect(
        chat.queuedBubble,
        isNotNull,
        reason:
            '+81: a reattach backlog is the OLD turn\'s frames — '
            'only the explicit started marker may dissolve the pin',
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(chat.queuedBubble, isNotNull);
      expect(probe.logs, contains(contains('ATTACH stream open')));
    });

    test('archaeology: a replayed line older than two minutes is filed '
        'silently, never re-voiced', () async {
      mkTurn(origin: BridgeTurnOrigin.attach);
      final ancient = time.now
          .subtract(const Duration(minutes: 3))
          .millisecondsSinceEpoch;
      final r = turnLoop.run(wire.stream);
      wire.add(
        BridgeEvent.forTest(
          'say',
          text: 'Something from before',
          wireMs: ancient,
          mid: 42,
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(engine.synthesized, isEmpty);
      expect(bubble.blocks, contains('Something from before.'));
      expect(probe.logs, contains(contains('logged silently, not spoken')));
      expect(probe.took, contains(42)); // the ack rides even for old text
    });

    test('v2: a redelivered mid is deduped by ID — text plays no part '
        '(not even after cleaning: there is nothing left to match)', () async {
      mkTurn(origin: BridgeTurnOrigin.attach);
      probe.alreadyHeard.add(5); // taken by a view this loop never saw
      final r = turnLoop.run(wire.stream);
      wire.add(
        const BridgeEvent.forTest('say', text: '**Already heard**.', mid: 5),
      );
      // Identical TEXT but a fresh id: a stranger, and it speaks.
      wire.add(
        const BridgeEvent.forTest('say', text: 'Already heard.', mid: 6),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(engine.synthesized, ['Already heard.']);
      expect(probe.logs, contains(contains('dup by id #5')));
      expect(probe.took, contains(6));
    });

    test('nothing narrates and no pulse beats on a replay view', () async {
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'sleep 60'),
      );
      await settle();
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(probe.audioActivity, 0);
      time.advance(const Duration(minutes: 2)); // a heartbeat WOULD have
      await settle(); // fired narrateProgress
      expect(
        engine.synthesized,
        isEmpty,
        reason:
            'a replay never speaks '
            'a step line — only fresh says',
      );
    });

    test(
      'a dying reattach re-arms the chain PACED (no request loop)',
      () async {
        mkTurn(origin: BridgeTurnOrigin.attach);
        final r = turnLoop.run(wire.stream);
        await settle();
        wire.addError(Exception('died again'));
        await r;
        await settle();
        final arm = probe.arms.single;
        expect(arm.resetStep, isFalse, reason: 'the ladder keeps its rung');
        expect(
          arm.firstProbe,
          isNotNull,
          reason: 'pace before the next attach',
        );
        expect(probe.logs.last, contains('chain continues (paced)'));
      },
    );
  });

  group('file frames (bridge -> app deliveries)', () {
    test('a fresh mid files one bubble and commits its id', () async {
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'file',
          fileName: 'app-release.apk',
          filePath: 'dist/app-release.apk',
          fileSize: 12345,
          mid: 78,
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      final filed = chat.entries.where((e) => e.isFile).toList();
      expect(filed, hasLength(1));
      expect(filed.single.fileName, 'app-release.apk');
      expect(filed.single.fileSize, 12345);
      expect(probe.took, contains(78)); // consumption IS the ack
    });

    test('a replay of an already-taken file id is silently skipped', () async {
      probe.alreadyHeard.add(77); // taken by a view this loop never saw
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'file',
          fileName: 'stale.apk',
          filePath: 'dist/stale.apk',
          fileSize: 1,
          mid: 77,
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(
        chat.entries.any((e) => e.isFile),
        isFalse,
        reason: 'the ledger says this phone has the bubble — no second card',
      );
      expect(probe.logs.any((l) => l.contains('file dup by id #77')), isTrue);
    });
  });
}

extension on ChatStore {
  ChatEntry get last => entries.last;
}
