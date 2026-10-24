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
  String? errorWhy;
  String?
  errorSession; // +275: who the verdict was filed for // +219: the reason the wire carried must arrive

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
  String lastReceiptId = '';
  String? receiptSession; // +279 // +186: what the finished frame stamped
  bool dropMarkCleared = false, idled = false;

  bool get speaking => phase == AssistantPhase.speaking;

  // +253: the focus seams — a watermark (0 = none) and the seated id
  // (null = single-thread world, every view at home). The walks that
  // pin the watermark law set them; every older walk rides the defaults.
  int focusMs = 0;
  String? seatedNow;

  /// +257: every done-driven marker retirement the pump reported.
  final List<String> workHomed = [];

  /// +274: every away-band filing — and WHOSE tab it was filed for.
  final List<(String?, Object)> awayBands = [];

  /// The foreign-say ledger (mid → sid, preview): what refusals write,
  /// what takes claim — the drain-pickup trace's memory.
  final Map<int, (String?, String)> refusedSays = {};

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
    noteHarnessError: (why, session) {
      errored = true;
      errorWhy = why;
      errorSession = session; // +275: the stamp must name the hearer
    },
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
    retireBgWork:
        (d, {bool cancelled = false, String taskId = '', String? session}) {
          receiptSession = session; // +279: the receipt names its speaker
          lastReceiptId = taskId; // +186: the frame's task id rides the seam
          retiredBg.add((d, cancelled));
          // The assistant's law (see _retireBgWork): the promise is paid,
          // the OWING row settles (+279.1), and a lit badge goes with it.
          coord?.clearBgWork();
          coord?.payAgentDebt(d, sid: session);
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
    noteRefusedSay: (mid, sid, preview) => refusedSays[mid] = (sid, preview),
    claimRefusedSay: (mid) => refusedSays.remove(mid) != null,
    focusAtMs: () => focusMs,
    seatedSession: () => seatedNow,
    noteWorkHome: workHomed.add,
    cacheAwayBand: (sid, act) => awayBands.add((sid, act)),
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
      persist: (entries) async => persisted.add(encodeChatLog(entries)),
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

    test('+253: the focus watermark files the backlog you land on; only '
        'words written after you sit down speak', () async {
      // Tim's swipe law, at the pump: /attach replay brings the
      // unheard paragraphs a conversation owed BEFORE the switch —
      // filed, acked, visible, mute. The next paragraph, born after
      // the landing, gets the normal voice.
      // Stamps live on the fake clock's own epoch: the backlog frame
      // is 6 s old AND older than the landing (5 s ago) — the watermark
      // silences it while the 120 s age law still considers it news.
      final t0 = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
      probe.focusMs = t0 - 5000; // the swipe landed 5 s ago
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'say',
          text: 'owed from before the swipe.',
          mid: 1,
          wireMs: t0 - 6000,
        ),
      );
      wire.add(
        BridgeEvent.forTest(
          'say',
          text: 'new since you landed.',
          mid: 2,
          wireMs: t0,
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
      expect(engine.synthesized, [
        'new since you landed.',
      ], reason: 'the backlog you swiped onto never interrupts the welcome');
      expect(bubble.blocks, [
        'owed from before the swipe.',
        'new since you landed.',
      ], reason: 'the thread is complete either way');
      expect(
        probe.took,
        containsAll(<int>[1, 2]),
        reason: 'received means acked — mute included',
      );
      expect(
        probe.logs.any((l) => l.contains('pre-focus backlog: logged silently')),
        isTrue,
        reason: 'the silence has a name on the tape',
      );
    });

    test('+253: a backgrounded session answers into its thread without '
        'interrupting the tab on screen', () async {
      // The +246 backgrounding kept the stream alive; this is what it
      // does with a paragraph now: the conversation the seat left
      // behind files its says silently — age irrelevant, live frames
      // included. The gear badge is its sign; the thread, its delivery.
      probe.seatedNow = 'ses-X'; // the view opens while X is on screen
      mkTurn();
      final r = turnLoop.run(wire.stream);
      await settle();
      probe.seatedNow = 'ses-Y'; // swipe away mid-turn
      wire.add(
        const BridgeEvent.forTest(
          'say',
          text: 'answered out of earshot.',
          mid: 3,
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
      expect(
        engine.synthesized,
        isEmpty,
        reason: 'the tab you are watching keeps its peace',
      );
      expect(bubble.blocks, ['answered out of earshot.']);
      expect(
        probe.took,
        contains(3),
        reason: 'the take rides — coming back must not re-speak it',
      );
      expect(
        probe.logs.any(
          (l) => l.contains('unfocused conversation: logged silently'),
        ),
        isTrue,
      );
    });

    test('+253: a birth turn learns its name from the context frame, '
        'and only THEN can a swipe mute its says', () async {
      // A view that opens nameless is the conversation watching it
      // born (every say at home); the message_start that names the id
      // gives the gate its subject — from that frame on, a seat move
      // is visible to the pump.
      mkTurn(); // seatedNow null: the birth turn's name coming
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 100,
          contextWindow: 200,
          ctxSession: 'ses-newborn',
        ),
      );
      await settle();
      probe.seatedNow = 'ses-other-tab';
      wire.add(
        const BridgeEvent.forTest(
          'say',
          text: 'born nameless, muted by name.',
          mid: 4,
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
      expect(engine.synthesized, isEmpty);
      expect(
        probe.logs.any(
          (l) => l.contains('unfocused conversation: logged silently'),
        ),
        isTrue,
        reason: 'the ctx frame named the conversation; the gate read it',
      );
      expect(probe.workHomed, [
        'ses-newborn',
      ], reason: '+257: the done of the named conversation retires its marker');
    });

    test("+259: a backgrounded thread's tool frames keep the band of "
        'the tab on screen — ledger current, band silent', () async {
      // The band leak Tim's tape caught: work backgrounded in X, eyes
      // on Y — X's 'Bash …' must not squat on Y's top line. The step
      // still feeds every ledger it fed before (the backgrounded row's
      // label, the journal); only the paint is gated — the same owner
      // law as the meter (+249) and the shimmer (+256).
      probe.seatedNow = 'ses-Y'; // watching Y; this view is away work in X
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 10,
          contextWindow: 20,
          ctxSession: 'ses-X',
        ),
      );
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'Bash',
          detail: 'make build',
        ),
      );
      await settle();
      expect(
        probe.statuses.whereType<StepLine>(),
        isEmpty,
        reason: "the away command must not paint the watching tab's band",
      );
      expect(
        probe.logs.any((l) => l.contains('unfocused conversation: band kept')),
        isTrue,
        reason: 'the silence has a name on the tape, like the mute path',
      );
      expect(
        turn.lastToolStep,
        'Bash make build…',
        reason: 'the backgrounded row still knows exactly what works',
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
    });

    test('+C: a nameless home is NO VERDICT at the band gate — a stamped '
        'step paints on a view that has not learned its name', () async {
      // +290 stated the law ('nameless = no-verdict, not foreignness')
      // for the say and file gates; the tool/band gate was left behind
      // (review C): with NEITHER the seat nor this view named — the
      // fresh resume probe whose /health name the phone has not worn,
      // the nameless birth — an otherwise-ordinary stamped frame of
      // THIS conversation classified foreign on the coin toss of the
      // missing local ids, and the fresh tab showed no status and no
      // step ledger for its own work. The mirror of _onSay's clause:
      // without a POSITIVE home to contradict, there is no stranger
      // to point at; the stamp is the only truth on the table.
      mkTurn(origin: BridgeTurnOrigin.attach); // seatedNow null, no
      // context frame claimed: both local identities unnamed
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'Bash',
          detail: 'flutter test',
          session: 'ses-first',
        ),
      );
      await settle();
      expect(
        probe.statuses.whereType<StepLine>(),
        isNotEmpty,
        reason: 'an uncontradicted stamp paints, it does not silence',
      );
      expect(
        probe.awayBands,
        isEmpty,
        reason: 'nothing files away — no home was contradicted',
      );
      expect(
        turn.lastToolStep,
        'Bash flutter test…',
        reason: 'the pump\'s own ledger learns its own turn\'s step',
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
    });

    test('+259: unstamped views paint the band on trust, as ever', () async {
      // An old bridge that cannot name sessions: no subject for the
      // gate, so the single-thread behaviour stands untouched.
      probe.seatedNow = 'ses-Y';
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'Read',
          detail: 'a/b/c.dart',
        ),
      );
      await settle();
      expect(
        probe.statuses.whereType<StepLine>(),
        hasLength(1),
        reason: 'nameless frames merge on trust (+249 clause, kept)',
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
    });

    test('+274: a frame STAMPED for another conversation is neither '
        'taken nor filed here', () async {
      // Tim's two-session tape: the poll ring carries BOTH threads,
      // the +253 context-frame learning ping-ponged, and the chat
      // mixed. The stamp ends the guessing: a foreign say must not be
      // ACKed (its backlog copy is the owner tab's debt) and must not
      // squat on this thread.
      probe.seatedNow = 'ses-Y'; // watching Y
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'say',
          text: 'answer born in the other thread.',
          mid: 11,
          session: 'ses-X', // X is neither the seat nor this view
        ),
      );
      await settle();
      expect(engine.synthesized, isEmpty);
      expect(
        bubble.blocks,
        isEmpty,
        reason: 'a foreign say does not contaminate this thread',
      );
      expect(
        probe.took,
        isNot(contains(11)),
        reason: 'not taken — the owner tab has not heard it yet',
      );
      expect(
        probe.logs.any(
          (l) => l.contains('foreign conversation: say left unheard'),
        ),
        isTrue,
      );
      // The SAME conversation's frame, stamped honestly: normal law.
      wire.add(
        const BridgeEvent.forTest(
          'say',
          text: 'mine, at home.',
          mid: 12,
          session: 'ses-Y',
        ),
      );
      await settle();
      expect(engine.synthesized, ['mine, at home.']);
      expect(probe.took, contains(12));
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
    });

    test('+A: the refusal names its say, and the drain\u2019s pickup '
        'closes the story', () async {
      // The 10:16 tape: a fresh reply's both says refused as foreign,
      // then played \u2014 two unrelated ends on the tape, the middle
      // missing. The refusal now names the say (mid, sid, first words),
      // and the take of a previously refused mid journals the pickup.
      probe.seatedNow = 'ses-Y'; // a stranger's pump is watching at refusal time
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'say',
          text: 'the greeting born abroad.',
          mid: 21,
          session: 'ses-X',
        ),
      );
      await settle();
      expect(
        probe.logs.any(
          (l) =>
              l.contains('foreign conversation: say left unheard') &&
              l.contains('say#21') &&
              l.contains('sid ses-X'),
        ),
        isTrue,
        reason: 'the refusal names WHOSE paragraph the owner drain owes',
      );
      expect(probe.refusedSays.keys, contains(21));
      wire.add(BridgeEvent.forTest('done'));
      await r; // turn 1's part is played: the say is in the ledger, refused
      // The OWNER's own thread reattaches: a fresh pump, born at X's
      // address (+331 \u2014 a named pump's home is its birth address, so the
      // pickup needs the owner's own drain, exactly as the tape ran it).
      probe.seatedNow = 'ses-X';
      wire = StreamController<BridgeEvent>();
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r2 = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'say',
          text: 'the greeting born abroad.',
          mid: 21,
          session: 'ses-X',
        ),
      );
      await settle();
      expect(
        probe.logs.any(
          (l) =>
              l.contains('say #21 refused earlier as foreign') &&
              l.contains('served now'),
        ),
        isTrue,
        reason: 'the missing middle between refusal and playback',
      );
      expect(probe.took, contains(21));
      expect(
        engine.synthesized,
        contains('the greeting born abroad.'),
        reason: 'and the law proceeds: the served say speaks',
      );
      wire.add(BridgeEvent.forTest('done'));
      await r2;
      out.complete();
      await settle();
    });

    test('+290: a named say reaches a nameless phone — no home to '
        'contradict, no foreign verdict', () async {
      // The hide/foreground tape, gate-sized: the resume drain was
      // born while the phone's seat pointer named nobody, and every
      // paragraph of the phone's OWN answer \u2014 honestly stamped for
      // the conversation it was born in \u2014 read as FOREIGN: not
      // taken, not filed, nothing in the thread ('no response until
      // I set a hello'). The stamp verdict needs a positive home to
      // contradict; with neither seat nor view named, the watermark
      // and the age laws judge the frame on its merits.
      probe.seatedNow = null; // the phone cannot name its seat\u2026
      mkTurn(
        origin: BridgeTurnOrigin.attach,
      ); // \u2026so this view is born nameless
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'say',
          text: 'the answer that was only lost, not foreign.',
          mid: 13,
          session: 'ses-answered', // an honest stamp, an unknown home
        ),
      );
      await settle();
      expect(
        probe.logs.any(
          (l) => l.contains('foreign conversation: say left unheard'),
        ),
        isFalse,
        reason: "the phone's amnesia is not the frame's foreignness",
      );
      expect(
        probe.took,
        contains(13),
        reason: 'taken \u2014 this drain pays it',
      );
      expect(
        engine.synthesized,
        contains('the answer that was only lost, not foreign.'),
        reason: 'and the law proceeds: fresh unstamped frames speak',
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
    });

    test('+274: a foreign tool band files to the OWNER\u2019s tab, '
        'not the one on screen', () async {
      probe.seatedNow = 'ses-Y';
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'Bash',
          detail: 'flutter build apk',
          session: 'ses-X',
        ),
      );
      await settle();
      expect(
        probe.statuses.whereType<StepLine>(),
        isEmpty,
        reason: 'the watching tab keeps its peace',
      );
      expect(probe.awayBands, hasLength(1));
      expect(
        probe.awayBands.single.$1,
        'ses-X',
        reason: 'the band files for the thread that is working',
      );
      expect(
        turn.lastToolStep,
        isEmpty,
        reason: 'this pump\u2019s ledgers stay its own conversation\u2019s',
      );
      expect(
        probe.logs.any((l) => l.contains('foreign conversation: band kept')),
        isTrue,
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
    });

    test('+279.1: a receipt seen through ANOTHER conversation\u2019s '
        'pump pays the owning thread and stamps for it', () async {
      // The 22:23 tape: voice-agent owed sleep-20 while xray ran a
      // foreground sleep; voice-agent\u2019s finished frame rode xray\u2019s
      // pump, the payment tried xray\u2019s ledger row (miss — the debt
      // kept counting), and the receipt card stamped for xray
      // (\u2018something from the other session\u2019 on screen).
      turn.noteWorkOwner('ses-A');
      turn.noteAgentWork('Bash sleep 20', sid: 'ses-A');
      probe.seatedNow = 'ses-B'; // the pump belongs to the WATCHER
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'Bash sleep 20',
          session: 'ses-A', // the wire names the debt\u2019s thread
        ),
      );
      await settle();
      expect(
        turn.agentWork,
        isFalse,
        reason: 'the payment hits the OWNING row, not the watcher\u2019s',
      );
      expect(
        probe.receiptSession,
        'ses-A',
        reason: 'and the receipt speaks for ses-A\u2019s thread',
      );
      wire.add(const BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
    });

    test('+279: a pump that opens while a debt is owed SPEAKS the '
        'debt\u2019s report (fresh) instead of filing it silently', () async {
      // The tape: the sleep finished while the user was away, the
      // landing\u2019s catch-up attach drained the report, and the
      // focus watermark filed the news in silence \u2014 'the response
      // after the sleep finish didn\u2019t go through tts'. A pump born
      // over an owed ledger is the REPORT\u2019S delivery, owed to the
      // ear; only the 2-minute archaeology rule may silence it.
      turn.noteWorkOwner('ses-X');
      turn.noteAgentWork('Bash sleep 15', sid: 'ses-X');
      probe.seatedNow = 'ses-X'; // the report lands on its own tab
      final frameMs = time.now.subtract(const Duration(seconds: 15));
      mkTurn(origin: BridgeTurnOrigin.attach);
      probe.focusMs = time.now.millisecondsSinceEpoch; // landed AFTER it
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'say',
          text: 'The sleep finished clean.',
          wireMs: frameMs.millisecondsSinceEpoch,
          mid: 77,
        ),
      );
      await settle();
      expect(
        engine.synthesized,
        isNotEmpty,
        reason: 'the debt report speaks \u2014 15 s old, owed an ear',
      );
      expect(
        probe.logs,
        isNot(contains(contains('logged silently'))),
        reason: 'not filed as pre-focus history',
      );
      wire.add(const BridgeEvent.forTest('done'));
      await r;
      out.complete();
      await settle();
    });

    test(
      '+275: pins are per conversation — B\u2019s pickup leaves A\u2019s park alone',
      () async {
        final owner = ['ses-A'];
        final store = ChatStore(
          persist: (_) async {},
          repaint: () {},
          session: () => owner.first,
        );
        store.addUser('parked in A', queued: true);
        owner[0] = 'ses-B';
        store.addUser('parked in B', queued: true);
        expect(
          store.queuedFor('ses-A')?.blocks.single,
          'parked in A',
          reason: 'A keeps its pin while B parks too — isolation',
        );
        expect(store.queuedFor('ses-B')?.blocks.single, 'parked in B');
        store.unpinQueued(session: 'ses-B');
        expect(store.queuedFor('ses-B'), isNull, reason: 'B was taken');
        expect(
          store.queuedFor('ses-A'),
          isNotNull,
          reason: 'A was never taken — its spinner box persists',
        );
      },
    );

    test('+275: the error verdict stamps for the conversation that '
        'heard it, not for the seat the user swiped to', () async {
      // The tape shape: reattached pump of X, user swipes to Y, X's
      // turn dies with a provider error. The receipt card used to be
      // stamped for Y (the live seat) — the wrong-tab error text.
      probe.seatedNow = null; // birth pump, nameless at start
      mkTurn(origin: BridgeTurnOrigin.attach);
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 10,
          contextWindow: 20,
          ctxSession: 'ses-X',
        ),
      );
      await settle();
      probe.seatedNow = 'ses-Y'; // the user moves on while X works
      wire.add(
        const BridgeEvent.forTest(
          'done',
          isError: true,
          text: 'model rejected',
          session: 'ses-X',
        ),
      );
      await r;
      out.complete();
      await settle();
      expect(
        probe.errorSession,
        'ses-X',
        reason: 'the verdict belongs to the thread that heard it',
      );
    });

    test('+275: a nameless birth self-names from its OWN stream, and '
        'the adoption sweep stops stealing strangers', () async {
      final owner = [null];
      final store = ChatStore(
        persist: (_) async {},
        repaint: () {},
        session: () => owner[0] ?? ChatStore.pendingSession,
      );
      // Two nameless births: one prompt typed into each.
      store.addUser('typed into birth A', queued: false);
      final stranger = store.beginTurn(); // another conversation's bubble
      expect(stranger.session, ChatStore.pendingSession);
      // The seat now speaks A's name: only the typed paperwork the
      // seat itself owes adopts it (userOnly sweep); the stranger's
      // assistant bubble keeps its sentinel until ITS wire names it.
      expect(store.adoptPending('ses-A', userOnly: true), 1);
      expect(store.entries.first.session, 'ses-A');
      expect(
        stranger.session,
        ChatStore.pendingSession,
        reason: '+275: no more cross-birth adoption theft',
      );
      // And A's own pump, meeting its ctx frame, self-names its
      // bubble — identity flows from the stream that spoke.
      store.namePendingOf([stranger], 'ses-A');
      expect(stranger.session, 'ses-A');
    });

    test(
      '+274: the parser reads the wire stamp, and absence is trust',
      () async {
        final ev = BridgeEvent.parse(
          'say',
          '{"text":"x","_mid":9,"_sess":"ses-Z","_ts":1}',
        );
        expect(ev.session, 'ses-Z');
        expect(ev.mid, 9);
        final old = BridgeEvent.parse('say', '{"text":"x","_mid":10}');
        expect(
          old.session,
          isNull,
          reason: 'an old bridge keeps the +253 inference path',
        );
      },
    );

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
      expect(probe.logs.first, 'CONTROL stream open (no prompt stream): go');
    });

    test('a done frame carrying the harness error flags the turn', () async {
      mkTurn();
      final r = turnLoop.run(wire.stream);
      wire.add(BridgeEvent.forTest('done', isError: true));
      await r;
      await settle();
      expect(probe.errored, isTrue);
      expect(
        probe.errorWhy,
        isNull,
        reason: 'an old bridge sends the flag alone — no reason, no lie',
      );
      expect(
        probe.logs.any((l) => l.contains('done clean')),
        isTrue,
        reason: 'flag-only still journals as the clean-done shape it is',
      );
    });

    test('+219: a REASONED error-done travels the wire into the status '
        'line and the journal', () async {
      mkTurn();
      final r = turnLoop.run(wire.stream);
      wire.add(
        BridgeEvent.forTest(
          'done',
          isError: true,
          text: 'Access to model denied.',
        ),
      );
      await r;
      await settle();
      expect(probe.errored, isTrue);
      expect(probe.errorWhy, 'Access to model denied.');
      expect(
        probe.logs.any(
          (l) => l.contains('done error: Access to model denied.'),
        ),
        isTrue,
      );
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

    test('+286: a foreign-stamped file stays the owner\'s debt', () async {
      // The tape ('the APK bubble showed up in a different session'):
      // a file born under one conversation was COMMITTED and filed
      // during another tab's backlog replay — the delivery answered
      // to whoever ate it, not to its birth stamp. The say law
      // (+274) now covers deliveries too.
      probe.seatedNow = 'ses-host';
      mkTurn(); // this view belongs to the host conversation
      final r = turnLoop.run(wire.stream);
      await settle();
      wire.add(
        BridgeEvent.forTest(
          'file',
          fileName: 'app-release.apk',
          filePath: 'dist/app-release.apk',
          fileSize: 12345,
          mid: 79,
          session: 'ses-stranger', // born elsewhere
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(
        chat.entries.any((e) => e.isFile),
        isFalse,
        reason: 'no bubble squatting on a stranger\'s thread',
      );
      expect(
        probe.took,
        isNot(contains(79)),
        reason: 'un-acked: the backlog keeps it for the owner\'s drain',
      );
      expect(
        probe.logs.any((l) => l.contains('foreign conversation: file')),
        isTrue,
        reason: 'the refusal is journalled, like the say law',
      );
    });

    test('+334: a file matching the MOVED seat stays foreign to a named '
        'pump (the tape, 14:19:30)', () async {
      // The +331 shape caught by the file relay's own gate: my voice-agent
      // pump sat open, the eye swiped to xray, and xray's /send delivery
      // filed its bubble HERE — the band frame refused ('not painted')
      // one millisecond before the relay gate let the same conversation's
      // file walk in because the SEAT happened to wear its name.
      probe.seatedNow = 'ses-va';
      mkTurn(); // pump born named for the voice-agent conversation
      final r = turnLoop.run(wire.stream);
      await settle();
      probe.seatedNow = 'ses-xray'; // the eye moves while the pump is open
      wire.add(
        BridgeEvent.forTest(
          'file',
          fileName: 'xray-app.apk',
          filePath: 'Downloads/xray-app.apk',
          fileSize: 369051482,
          mid: 80,
          session: 'ses-xray', // born under the tab the seat now wears
        ),
      );
      wire.add(BridgeEvent.forTest('done'));
      await r;
      await settle();
      expect(
        chat.entries.any((e) => e.isFile),
        isFalse,
        reason: 'the seat is an accident of attention, not an address',
      );
      expect(
        probe.took,
        isNot(contains(80)),
        reason: 'un-acked: xray\'s own drain serves its bubble',
      );
      expect(
        probe.logs.any((l) => l.contains('foreign conversation: file')),
        isTrue,
      );
    });
  });
}

extension on ChatStore {
  ChatEntry get last => entries.last;
}
