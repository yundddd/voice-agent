// +299: MULTI-SESSION FIELD WALKS, device-free. The same tape has run
// on the phone five seasons running — two conversations, a background
// sleep, a swipe, a receipt, a proactive report, a prompt parked
// behind a tool — and each season it found a NEW leak past a green
// unit suite (the +297 meter, the +297 pin, the +298 marker, the +299
// rename), because every unit walk HAND-AUTHORED its frame sequence:
// the bridge's BEHAVIOUR lived in the author's head, not in the rig.
// These walks say it instead: a behavioural fake of the bridge
// (support/scenario_bridge.dart) owns the queueing, settled, receipt
// and backlog laws, the tests speak in conversation moves, and the
// poll transport (the shape field phones run) delivers whatever the
// fake's laws produce. If a field report ever needs reproducing
// again, it is a few verbs here, not another phone session.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/assistant.dart';
import 'package:voice_agent/src/common/sinks.dart';
import 'package:voice_agent/src/platform/audio_output.dart';

import 'support/fakes.dart';
import 'support/scenario_bridge.dart';

Future<void> settle({int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('multi-session scenarios (the field tape, device-free)', () {
    late ScenarioBridge bridge;
    late VoiceAssistant a;
    late FakeSpeechEngine engine;
    late FakeAudioOutput out;
    late FakeScheduler time;
    // The walks' shared clock: the phone's `clock` reads it, the
    // bridge stamps _ts from it, and pump() moves them together —
    // the one relation the +253 watermark and the wireTag ages turn
    // on (a frozen rig clock makes every replay frame exactly
    // FOCUSED, and the mail speaks).
    DateTime phoneNow = DateTime(2026, 1, 1, 12);

    setUp(() async {
      bridge = ScenarioBridge();
      engine = FakeSpeechEngine();
      out = FakeAudioOutput();
      a = VoiceAssistant(
        worker: engine,
        micSource: FakeMic(),
        audioOutput: out,
        gatewayFactory: (_, _) => bridge,
        scheduler: time = FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => phoneNow,
      );
      await a.setBridge(url: 'http://bridge.test', token: 'tok');
      await settle();
      // The field phones run the PULL transport (the tape's 'poll:'
      // lines): the seam that negotiates it is the one the cold-start
      // reattach probe uses. One glance, and every turn rides /poll.
      await a.debugProbeTransport();
    });
    tearDown(() => a.dispose());

    // The poll transport ticks every 250 ms; the pumps run on the
    // clock, not on microtasks (the +257 doctrine), so the walks
    // advance the fake clock and let the microtasks drain around it.
    Future<void> pump({int beats = 2}) async {
      for (var i = 0; i < beats; i++) {
        time.advance(const Duration(milliseconds: 300));
        phoneNow = phoneNow.add(const Duration(milliseconds: 300));
        bridge.tick(300);
        await settle();
      }
    }

    // Let the WORLD run (a sleep sleeps, a report composes) without
    // pumping the wire: bridge time and phone time move, the poller
    // is not among the frames yet.
    void elapse(int ms) {
      phoneNow = phoneNow.add(Duration(milliseconds: ms));
      bridge.tick(ms);
    }

    Future<ScenarioConv> tab(String dir) async {
      final c = bridge.newConv(dir);
      expect(await a.createSession(harness: 'claude', dir: dir), isNull);
      await settle();
      return c;
    }

    // A creation mid-turn refuses by law (the +259 shape), so walks
    // that background a live turn make BOTH tabs while all is idle
    // and switch, which backgrounds instead of refusing.

    test('the sleep tape, end to end: two conversations, receipts at '
        'home, the report speaks when you return', () async {
      final x = await tab('/proj-x'); // the voice-agent role
      unawaited(a.runQuickCommand('two background sleeps please'));
      await pump();
      bridge.backgrounded(x.uuid, 'Bash sleep 20');
      bridge.backgrounded(x.uuid, 'Bash sleep 45');
      bridge.say(x.uuid, 'Two twenty-second sleeps are running.');
      bridge.endTurn(x.uuid);
      await pump();
      expect(
        a.channelForTest(x.uuid).turn.agentDebts,
        hasLength(2),
        reason:
            'both shells are owed, on THEIR conversation\'s '
            'ledger',
      );
      expect(a.view.backgrounded.visible, isTrue);

      // Tab Y (same label as X's first shell — the +279.1 shape),
      // seated, runs a foreground sleep of its own.
      final y = await tab('/proj-y');
      unawaited(a.runQuickCommand('a foreground sleep please'));
      await pump();
      bridge.toolStep(y.uuid, 'Bash', 'sleep 20');
      await pump();

      // X's first shell reports in WHILE Y is watched: the receipt
      // pays at home, the proactive say is foreign and stays unheard
      // (filed later, by the backlog, like the tape).
      bridge.complete(
        x.uuid,
        'Bash sleep 20',
        report: ['One of the two 20-second sleeps has finished.'],
      );
      await pump();
      expect(
        a.channelForTest(x.uuid).turn.agentDebts,
        hasLength(1),
        reason: 'the receipt paid ITS OWN debt (the +279.1 law)',
      );
      expect(
        a.view.chat.any(
          (e) => e.blocks.any((b) => b.contains('One of the two')),
        ),
        isFalse,
        reason: 'the stranger\'s report did not file on Y\'s thread',
      );
      expect(
        a.debugLog.any(
          (l) => l.contains('foreign conversation: say left unheard'),
        ),
        isTrue,
        reason: 'refused, not adopted — the +274 law, behaviourally',
      );
      expect(a.view.agentBusy, isTrue, reason: 'the gear badge knows');

      // Second shell home, Y closes (the message farewell relays
      // `settled` — openTools just emptied — the +297 foreign shape).
      bridge.complete(x.uuid, 'Bash sleep 45');
      bridge.toolResult(y.uuid, 'Bash sleep 20');
      bridge.endTurn(y.uuid);
      await pump();

      // COME HOME to X. The tape's two-phase honesty (16:51:41 →
      // :44): the MOVE was legal — the pre-seat probe names the
      // conversation you LEAVE, whose ledger is clean; the owed
      // words belong to the conversation you land on, and nothing
      // speaks them yet (the banner heartbeat only beats for owed
      // WORK, and those receipts paid at home). They land on the
      // next seat probe — the self-healing refusal: 'the bridge
      // owes unheard messages', the chain arms NOW, the replay
      // files them silently under the +253 watermark.
      elapse(4000); // the tape's 4 seconds between report and return
      expect(await a.switchSession(0), isNull);
      await pump(beats: 4);
      expect(
        await a.switchSession(1),
        isNotNull,
        reason: 'leaving with unheard words refuses — they land first',
      );
      await pump(beats: 4);
      expect(
        a.view.chat.any(
          (e) => e.blocks.any((b) => b.contains('One of the two')),
        ),
        isTrue,
        reason: 'the backlog delivered the report to ITS thread',
      );
      expect(
        engine.synthesized.any((t) => t.contains('One of the two')),
        isFalse,
        reason: 'filed, acked, visible — and MUTE (the +253 law)',
      );
      expect(
        a.channelForTest(x.uuid).turn.agentWork,
        isFalse,
        reason: 'both receipts paid; the banner retires at home',
      );
    });

    test('parked behind your own tool: settled may not hide the box, '
        'the started marker lifts the wait (+296, behaviourally)', () async {
      final x = await tab('/proj-x');
      unawaited(a.runQuickCommand('first'));
      await pump();
      bridge.toolStep(x.uuid, 'Bash', 'sleep 10');
      await pump();
      expect(a.view.showWorkingRow, isTrue);

      // A POLITE prompt (the PTT queue release flavour), same
      // conversation — the tape's shape. It supersedes the first
      // view (bridge_turn's law even for polite), and the pump's
      // +160 armor rides the before-abandon bridgeHadLiveTurn
      // snapshot, so the foreign farewell cannot end the parked
      // pump before its pickup.
      unawaited(
        a.runQuickCommand('second', interrupt: false, bubble: 'second'),
      );
      await pump();
      expect(a.queuedText, contains('second'));
      expect(
        a.channelForTest(x.uuid).awaitPickup,
        isTrue,
        reason:
            'the WAIT is booked on the conversation whose prompt '
            'parked (the +298 channel field, reached through the seam)',
      );

      // The turn says its period WITHOUT the pickup yet (the exact
      // tape gap): settled + done (foreign farewell — the parked pump
      // must survive it, +160) — and the box STAYS, outvoted by the
      // pin's own warrant (+296).
      bridge.endTurn(x.uuid, pickup: false);
      await pump();
      expect(
        a.view.showWorkingRow,
        isTrue,
        reason:
            'the parked prompt IS proof of an open round — the '
            'settled verdict may not blink the box',
      );
      // Pickup: the marker dissolves the pin, the answer takes over.
      bridge.pickup(x.uuid);
      await pump();
      expect(a.queuedText, isNull, reason: 'started — the pin\'s wait ends');
      bridge.say(x.uuid, 'Both done.');
      bridge.endTurn(x.uuid);
      await pump();
      expect(a.debugLog.any((l) => l.contains('queue picked up')), isTrue);
    });

    test('a prompt to the resting tab STARTS; it never wears the '
        'stranger\'s busy flag (the +257 router law, +297 pin)', () async {
      final x = await tab('/proj-x');
      final y = await tab('/proj-y'); // both made while idle
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('chew this'));
      await pump();
      bridge.toolStep(x.uuid, 'Bash', 'sleep 30');
      await pump();
      expect(await a.switchSession(1), isNull); // backgrounds X (+246)
      unawaited(
        a.runQuickCommand(
          'hello from Y',
          interrupt: false,
          bubble: 'hello from Y',
        ),
      );
      await pump();
      expect(
        a.queuedText,
        isNull,
        reason: 'Y is resting — no park behind a stranger\'s tool',
      );
      bridge.toolStep(y.uuid, 'Bash', 'sleep 10');
      await pump();
      // X's message goes FINAL while its tool still runs, with no
      // foreground tool left to block the verdict — the `settled`
      // relay is foreign to Y's pump; Y's box must not blink
      // (+297's shape, now behavioural, not a hand-pushed frame).
      bridge.toolResult(x.uuid, 'Bash sleep 30');
      bridge.messageFarewell(x.uuid);
      bridge.endTurn(x.uuid, settled: false);
      await pump();
      expect(
        a.view.showWorkingRow,
        isTrue,
        reason: 'Y chews its OWN tool; a stranger\'s settled says nothing',
      );
    });

    test('the interrupt cuts a thinking turn, not a tool\'s floor', () async {
      final x = await tab('/proj-x');
      unawaited(a.runQuickCommand('think first'));
      await pump();
      expect(a.view.bridgeBusy, isTrue);
      // Interrupt over a THINKING turn (no tools): the bridge cuts it
      // and the new prompt runs (fake: done(interrupted) + started).
      unawaited(a.runQuickCommand('steer instead'));
      await pump();
      expect(
        a.view.bridgeBusy,
        isTrue,
        reason: 'a new floor was taken, not an idle tab',
      );
      expect(bridge.conv(x.uuid).turnOpen, isTrue);
      bridge.endTurn(x.uuid);
      await pump();
      expect(a.view.bridgeBusy, isFalse);
    });

    test('the brake answers the conversation whose badge is lit; '
        'an away badge greys the brake HERE (+257/+280)', () async {
      final x = await tab('/proj-x');
      await tab('/proj-y');
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('a long build'));
      await pump();
      bridge.toolStep(x.uuid, 'Bash', 'sleep 30');
      await pump();
      // The swipe BACKGROUNDS the turn (the detach funnel lights the
      // badge on X's channel, not the watching tab's face).
      expect(await a.switchSession(1), isNull);
      expect(a.view.harnessBackgrounded, isFalse, reason: 'Y is not badge-lit');
      expect(
        a.view.stopHere,
        isFalse,
        reason: 'a lit brake must have something to stop HERE',
      );
      expect(a.view.agentBusy, isTrue, reason: 'the cross-session sign');
      expect(await a.switchSession(0), isNull);
      await pump();
      expect(a.view.stopHere, isTrue, reason: 'home, where the work lives');
      a.bridgeStop();
      await pump();
      expect(
        bridge.lastStopSid,
        x.uuid,
        reason: 'the cut is ADDRESSED (+257) — the seat\'s own record',
      );
      // The cancelled receipt still comes (the tool's late result).
      // It sits owed on X's record — and the seat is X: the next
      // glance drains it. Trying to LEAVE first meets the rest law
      // ('the bridge owes unheard messages'), the self-healing
      // refusal arms the drain, and the receipt lands while the
      // phone is still sitting at home.
      bridge.complete(x.uuid, 'Bash sleep 30', cancelled: true);
      await pump();
      expect(
        await a.switchSession(1),
        isNotNull,
        reason: 'a backlog of unheard words stops the move (+254)',
      );
      await pump(beats: 4);
      // The first refusal's replay lands the FAREWELL; the late
      // receipt outlives that pump (its tool's result crossed the
      // wire after the turn's done — chronology, the bridge's
      // heldFinished case). The refusal is self-healing: the next
      // probe owes the same drain, and the receipt files then.
      expect(
        await a.switchSession(1),
        isNotNull,
        reason: 'still owed: the receipt has not landed yet',
      );
      await pump(beats: 4);
      expect(
        a.view.chat.any((e) => e.blocks.any((b) => b.contains('cancelled.'))),
        isTrue,
        reason: 'the cancelled receipt lands in ITS thread, by name',
      );
    });

    test(
      '/new under a stable name: the thread is gone, the tab '
      'keeps its identity, the ack survives and speaks whole (+302)',
      () async {
        // +295 froze the NAME (/new starts the record fresh; it does not
        // rename it), and the old wipe predated that law: it purged the
        // live channel along with the history, so the seat went unnamed,
        // the ack stamped the pending sentinel, userOnly adoption hid it,
        // and the audio chunk got killed between chunks by a staleness
        // closure reading the SWAPPED-IN coordinator's generation (the
        // field tape: three presses in thirty seconds, '[app] reply tail
        // dropped: 1 unplayed chunk(s) — pump superseded between
        // chunks'). The button looked dead because its confirmation
        // was invisible and voiceless.
        final x = await tab('/proj-x');
        unawaited(a.runQuickCommand('remember this please'));
        await pump();
        bridge.say(x.uuid, 'Noted.');
        bridge.endTurn(x.uuid);
        await pump();
        expect(
          a.view.chat.any((e) => e.blocks.contains('Noted.')),
          isTrue,
          reason: 'one exchange on screen before the wipe',
        );
        await a.bridgeControl('/new');
        await pump();
        expect(
          a.view.chat.any((e) => e.blocks.contains('Noted.')),
          isFalse,
          reason: 'the thread is erased',
        );
        expect(
          a.view.chat,
          isEmpty,
          reason:
              "the screen goes BLANK — every bubble, the chip's own "
              'two included (the +230 law: a /new that leaves its '
              'own tombstone is not blank). The wipe IS the visual '
              'word; the confirmation is the (whole, un-cut) voice '
              'and the clean slate the next word meets.',
        );
        expect(
          engine.synthesized.contains('Starting a new conversation.'),
          isTrue,
          reason:
              'and is spoken WHOLE: the wipe may not evict its own '
              'confirmation between chunks',
        );
        expect(
          a.debugLog.any((l) => l.contains('reply tail dropped')),
          isFalse,
          reason: 'no self-truncated farewell on the new button',
        );
        expect(
          a.view.tabs[a.view.tabIndex].currentId,
          x.uuid,
          reason:
              'the tab wears the SAME uuid: +295 identities do not '
              'move when the thread dies',
        );
        // And the fresh start is real: the next words name the same
        // record, on the same tab, with nothing above them.
        unawaited(a.runQuickCommand('first word'));
        await pump();
        expect(bridge.conv(x.uuid).turnOpen, isTrue);
      },
    );

    test('the wire can die; the agent did not (+D, behaviourally)', () async {
      final x = await tab('/proj-x');
      unawaited(a.runQuickCommand('long turn please'));
      await pump();
      bridge.toolStep(x.uuid, 'Bash', 'sleep 40');
      bridge.blackout = true;
      await pump(beats: 10); // eight dead polls name the WIRE
      expect(
        a.debugLog.any((l) => l.contains('transport: bridge unreachable')),
        isTrue,
      );
      expect(
        a.debugLog.any((l) => l.contains('bridge unreachable — retrying')),
        isTrue,
      );
      expect(
        a.view.bridgeBusy,
        isTrue,
        reason: 'a dead carrier is NOT a verdict about the turn',
      );
      // The ring kept growing while the wire was down; the recovered
      // poll resumes at the cursor — no replay, no duplicates.
      bridge.blackout = false;
      bridge.say(x.uuid, 'Still here.');
      bridge.endTurn(x.uuid);
      await pump(beats: 3);
      expect(a.view.bridgeBusy, isFalse, reason: 'the real done closed it');
      expect(
        a.view.chat.any((e) => e.blocks.contains('Still here.')),
        isTrue,
        reason: 'the recovered wire resumed AT the cursor — one copy',
      );
    });

    // +305: the field tape's 13-second farewell. A backgrounded
    // shell finished while the eye sat on another tab; the phone
    // KNEW (missed=4 on the band at :50.7, on the return) yet the
    // news waited the full heartbeat to :60.4 [wire+13235ms]. The
    // three 'ask the bridge NOW' callers hand _scheduleBgProbe a
    // zero delay — and the coalescing guard (a beat already pending)
    // swallowed the urgency: a slow timer standing is treated like
    // a fast one. Urgency must be able to PRE-EMPT a pending beat.
    test('the return to owed words may not wait out the pending '
        'heartbeat (+305)', () async {
      final x = await tab('/proj-x');
      await tab('/proj-y'); // both made while idle
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('sleep 20 in the background'));
      await pump();
      bridge.backgrounded(x.uuid, 'Bash sleep 20');
      bridge.say(x.uuid, 'Running it in the background.');
      bridge.endTurn(x.uuid);
      await pump();
      expect(a.view.agentBusy, isTrue, reason: 'the shell is owed');
      // Stand up BEFORE the report: away, the beat keeps its slow
      // 10 s pace (a fast one would be an interrupting poller).
      expect(await a.switchSession(1), isNull);
      await pump();
      // The shell finishes and the report OPENS AND CLOSES between
      // the beats: nothing open, none detached, but the backlog
      // holds the news (and the unpaid receipt).
      bridge.complete(
        x.uuid,
        'Bash sleep 20',
        report: ['The 20 second sleep has finished.'],
      );
      bridge.endTurn(x.uuid);
      await pump();
      // Come home. The landing sees owed words — the wake request
      // must pre-empt the pending beat, not queue behind it.
      expect(await a.switchSession(0), isNull);
      await pump(beats: 4); // ~1.2 s — the beat's own due date is
      // seconds away; only an URGENT wake can land this inside it.
      expect(
        a.view.chat.any(
          (e) => e.blocks.contains('The 20 second sleep has finished.'),
        ),
        isTrue,
        reason:
            'the report was RINGED before the return — the '
            'landing sees it; it must not be held for the slow '
            'beat that happened to be pending',
      );
      expect(
        a.channelForTest(x.uuid).turn.agentDebts,
        isEmpty,
        reason: 'and the receipt paid at home',
      );
    });

    test('a glance naming the neighbour may not rename the seat '
        '(+303, the tape that re-crossed the sessions)', () async {
      // The field tape: after the bridge restart and a /new, the
      // xray-app tab's seat rows read 'conversation ad47b08b' —
      // the VOICE-AGENT's uuid — and the two threads, routed by uuid
      // through every +295/+298/+299 law, collapsed into one address
      // and started showing each other's messages again. The vector
      // is the +223 law outliving its world: /health's sessionId
      // line describes the GLOBAL — the last-record the bridge sat
      // at or talked to — and the old single-thread phone adopted
      // whatever name it spoke for the seat it sat on. Under
      // uuid-at-birth a name is born (createSession), worn at the
      // landing (tab.currentId, echoed by /seat), or learned from
      // ONE'S OWN stream (+299) — never from a neighbour's census
      // line.
      final x = await tab('/proj-x');
      final y = await tab('/proj-y');
      expect(await a.switchSession(0), isNull);
      await pump();
      unawaited(a.runQuickCommand('work for x'));
      await pump();
      expect(bridge.conv(x.uuid).turnOpen, isTrue);
      // The field move: swipe away MID-TURN; the neighbour finishes
      // behind you, and its own frames re-seated the bridge's focus
      // (the real bridge swapFocuses for the record a talk names).
      expect(await a.switchSession(1), isNull);
      await pump();
      bridge.say(x.uuid, 'X is done.');
      bridge.focusSid = x.uuid; // what the neighbour's turn leaves
      bridge.endTurn(x.uuid);
      await pump();
      // X's pump paid its turn-end housekeeping — a /health glance —
      // while the eye sat on Y. The glance named X. The seat's name
      // did not move.
      expect(
        a.view.tabs[1].currentId,
        y.uuid,
        reason:
            'the seated tab keeps ITS uuid: /health\'s sessionId '
            'is the global, information to file, never a rename for '
            'the tab it does not describe',
      );
      expect(
        a.view.chat.where((e) => e.blocks.contains('X is done.')).length,
        lessThan(2),
        reason:
            'and filed exactly once — into X, not duplicated by '
            'a renamed seat',
      );
      // The words that follow still land where the eye sits.
      unawaited(a.runQuickCommand('hello from y'));
      await pump();
      expect(
        bridge.conv(y.uuid).turnOpen,
        isTrue,
        reason:
            'the prompt rode Y\'s uuid — the collapse would have '
            'sent it to the neighbour\'s record',
      );
      expect(bridge.conv(x.uuid).turnOpen, isFalse);
    });
  });
}
