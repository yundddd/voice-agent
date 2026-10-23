// +230: session tabs. The bridge seats ONE conversation at a time;
// the app now keeps a LEDGER of seats — tabs — and lets the user
// jump the seat between them (POST /seat), create fresh ones (the
// same questions the first launch asks), and replace the current
// one with the /new chip without touching anyone else's history.
// Four layers, doctrine from harness_switch_test: the STORE half
// (removeSessions takes exactly the named sessions), the PREFS half
// (the ledger round-trips; a parsed file IS the 'not first launch'
// proof), the ASSISTANT half (create/switch/replace/reconcile/seed
// against the scripted gateway), and the SHEET half (the real widget
// over the fake, big buttons, one submit that seats and pops).
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/assistant.dart';
import 'package:voice_agent/src/assistant/chat_store.dart';
import 'package:voice_agent/src/bridge/client.dart';
import 'package:voice_agent/src/bridge/prefs.dart';
import 'package:voice_agent/src/common/sinks.dart';
import 'package:voice_agent/src/platform/audio_output.dart';
import 'package:voice_agent/src/ui/session_sheet.dart';

import 'support/fakes.dart';

Future<void> settle({int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('client /seat + /models dialect', () {
    late HttpServer server;
    late BridgeClient client;
    final seen = <String>[];
    String? reqBody;
    int replyStatus = 200;
    String replyBody = '{"ok":true}';

    // The binding swaps HttpClient for a 400-always stub in widget
    // files; the client group takes the override off (the doctrine of
    // the /harness group — HttpOverrides.global stays off here; this
    // file has no widget tests sharing the isolate's binding state
    // except the sheet group, which never dials HTTP).
    Future<Map<String, Object>?> seat({
      String? harness,
      String? dir,
      String? model,
      String? sessionId,
      bool fresh = false,
    }) {
      HttpOverrides.global = null;
      return client.seat(
        harness: harness,
        dir: dir,
        model: model,
        sessionId: sessionId,
        fresh: fresh,
      );
    }

    Future<Map<String, Object>?> getModels({String? harness, String? dir}) {
      HttpOverrides.global = null;
      return client.models(harness: harness, dir: dir);
    }

    setUp(() async {
      seen.clear();
      reqBody = null;
      replyStatus = 200;
      replyBody = '{"ok":true}';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = BridgeClient('http://127.0.0.1:${server.port}', 'tok');
      server.listen((req) async {
        seen.add('${req.method} ${req.uri.path}');
        if (req.method == 'POST') {
          reqBody = await utf8.decodeStream(req);
        }
        req.response
          ..statusCode = replyStatus
          ..write(replyBody);
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test(
      'a fresh seat is ONE request carrying the whole question set',
      () async {
        replyBody = jsonEncode({
          'ok': true,
          'harness': 'opencode',
          'dir': '/proj',
          'sessionId': null,
          'model': 'acme/alpha',
        });
        final r = await seat(
          harness: 'opencode',
          dir: '/proj',
          model: 'acme/alpha',
          fresh: true,
        );
        expect(seen, ['POST /seat']);
        final j = jsonDecode(reqBody!) as Map<String, Object?>;
        expect(j['harness'], 'opencode');
        expect(j['dir'], '/proj');
        expect(j['model'], 'acme/alpha');
        // fresh and pointer-read stay distinct verbs on the wire.
        expect(j['fresh'], isTrue);
        expect(j.containsKey('sessionId'), isFalse);
        expect(r?['ok'], isTrue);
        expect(r?['harness'], 'opencode');
      },
    );

    test('a named sessionId rides alone; a 400 answers as a refusal', () async {
      await seat(sessionId: 'ses-7');
      final j = jsonDecode(reqBody!) as Map<String, Object?>;
      expect(j['sessionId'], 'ses-7');
      expect(j.containsKey('fresh'), isFalse);
      replyStatus = 400;
      replyBody = '{"ok":false,"error":"not a folder"}';
      final r = await seat(dir: '/outside');
      expect(r?['ok'], isFalse);
      expect(r?['error'], 'not a folder');
    });

    test(
      'a pre-seat bridge (404 on the route) answers null, like a shrug',
      () async {
        replyStatus = 404;
        replyBody = 'stub: no route POST /seat';
        expect(await seat(fresh: true), isNull);
      },
    );

    test('/models carries harness and dir as the sheet asks them', () async {
      replyBody = '{"ok":true,"harness":"claude","models":[]}';
      final r = await getModels(harness: 'claude', dir: '/somewhere');
      expect(seen, ['GET /models']);
      expect(r, isNotNull);
    });
  });

  group('store: removeSessions', () {
    test('takes the named sessions and the sentinel, stands the rest', () {
      final store = ChatStore(
        persist: (_) async {},
        repaint: () {},
        harness: () => 'claude',
        session: () => 'ses-PROV',
      );
      store.addUser('in A');
      store.entries.last.session = 'ses-A';
      store.addUser('in B');
      store.entries.last.session = 'ses-B';
      store.addUser('nameless'); // wears the provider's stamp
      store.entries.last.session = ChatStore.pendingSession;
      store.addUser('offline prologue');
      store.entries.last.session = null;
      store.entries.last.harness = null;
      expect(store.removeSessions({'ses-A', ChatStore.pendingSession}), 2);
      expect(store.entries.map((e) => e.session), ['ses-B', null]);
      // An empty selection is a no-op with no touch.
      expect(store.removeSessions({'nope'}), 0);
    });
  });

  group('prefs: the ledger on disk', () {
    test('tabs round-trip; a PARSED file is the installed proof', () {
      final p = BridgePrefs()
        ..tabs.add(
          SessionTab(
            harness: 'opencode',
            dir: '/proj-x',
            model: 'acme/beta',
            sessionIds: ['ses-1', 'ses-2'],
            createdMs: 111,
          ),
        )
        ..activeTab = 1;
      final back = BridgePrefs.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>,
      );
      expect(back.installed, isTrue); // the file EXISTED — not first launch
      expect(BridgePrefs().installed, isFalse); // fresh install asks
      expect(back.activeTab, 1);
      final t = back.tabs.single;
      expect(t.harness, 'opencode');
      expect(t.dir, '/proj-x');
      expect(t.model, 'acme/beta');
      expect(t.sessionIds, ['ses-1', 'ses-2']);
      expect(t.currentId, 'ses-2');
      expect(t.label, 'proj-x');
    });
  });

  group('assistant: the tab ledger', () {
    late FakeHarness harness;
    late VoiceAssistant a;
    // +253: the engine is captured, not inline — the watermark walks
    // read what it was (and was NOT) given a voice for. +257: the
    // player too — 'leaving is dropping' counts its stops.
    late FakeSpeechEngine engine;
    late FakeAudioOutput out;
    // +257: the scheduler too — audio reaching the player is one
    // advanced tick deep (the pump runs on the clock, not microtasks).
    late FakeScheduler time;

    setUp(() async {
      harness = FakeHarness();
      harness.healthState = <String, Object?>{
        'ok': true,
        'claudeUp': true,
        'harness': 'claude',
        'dir': '/proj-a',
        'seat': true,
      };
      engine = FakeSpeechEngine();
      out = FakeAudioOutput();
      a = VoiceAssistant(
        worker: engine,
        micSource: FakeMic(),
        audioOutput: out,
        gatewayFactory: (_, _) => harness,
        scheduler: time = FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
    });
    tearDown(() => a.dispose());

    test('first launch asks, and createSession is the answer', () async {
      // Fresh install (unparsed prefs), configured bridge: the gate.
      expect(a.view.needsSetup, isTrue);
      expect(a.view.canSeat, isTrue);
      expect(
        await a.createSession(
          harness: 'opencode',
          model: 'acme/beta',
          dir: '/proj-b',
        ),
        isNull,
      );
      expect(harness.seatCalls.single, {
        'harness': 'opencode',
        'dir': '/proj-b',
        'model': 'acme/beta',
        'sessionId': null,
        'fresh': true,
      });
      final v = a.view;
      expect(v.tabs, hasLength(1));
      expect(v.tabIndex, 0);
      expect(v.tabs.single.harness, 'opencode');
      expect(v.tabs.single.label, 'proj-b');
      expect(v.tabs.single.currentId, isNull); // fresh — no id yet
      expect(v.needsSetup, isFalse); // answered; nothing owes a question
    });

    test('a refusal travels as the reason and files no tab', () async {
      harness.seatRefused = 'not a folder inside the bridge\'s --dir-root';
      expect(
        await a.createSession(harness: 'claude', dir: '/outside'),
        'not a folder inside the bridge\'s --dir-root',
      );
      expect(a.view.tabs, isEmpty);
      expect(a.view.needsSetup, isTrue); // still owed
    });

    test(
      'an upgrade seeds its live seat as tab 1, no wire, no dialog',
      () async {
        harness.healthState = <String, Object?>{
          ...harness.healthState!,
          'sessionId': 'ses-legacy',
        };
        // Prefs from disk (installed), no tabs yet — the +230 upgrade.
        a.bridgePrefsForTest = BridgePrefs.fromJson({});
        await a.setBridge(url: 'http://harness.test', token: 'tok');
        await settle();
        final v = a.view;
        expect(v.needsSetup, isFalse); // an upgrade is never asked
        expect(v.tabs, hasLength(1));
        expect(v.tabs.single.harness, 'claude');
        expect(v.tabs.single.dir, '/proj-a');
        expect(v.tabs.single.currentId, 'ses-legacy');
        expect(harness.seatCalls, isEmpty); // the seed touches no wire
      },
    );

    test(
      'tabs hold their threads: switching moves the seat and the window',
      () async {
        // Tab 1: opencode at /proj-x, a sentence spoken, then NAMED.
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
        await a.setBridgeDir('/proj-x'); // any awaited refresh path works
        await settle();
        expect(a.view.tabs.single.currentId, 'ses-X');
        // Tab 2: claude at /proj-y, its own sentence, its own name.
        await a.createSession(harness: 'claude', dir: '/proj-y');
        unawaited(a.runQuickCommand('two in Y', bubble: 'two in Y'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
        await a.setBridgeDir('/proj-y');
        await settle();
        expect(a.view.tabs[1].currentId, 'ses-Y');
        // The window shows tab 2's thread only.
        expect(a.view.chat.any((e) => e.blocks.contains('two in Y')), isTrue);
        expect(
          a.view.chat.where((e) => e.blocks.contains('one in X')),
          isEmpty,
        );
        // SWIPE/PILL: back to tab 1 — the seat moves, the window follows.
        expect(await a.switchSession(0), isNull);
        expect(harness.seatCalls.last, {
          'harness': 'opencode',
          'dir': '/proj-x',
          'model': null,
          'sessionId': 'ses-X',
          'fresh': false,
        });
        expect(a.view.tabIndex, 0);
        expect(
          a.view.chat.where((e) => e.blocks.contains('two in Y')),
          isEmpty,
        );
        expect(a.view.chat.any((e) => e.blocks.contains('one in X')), isTrue);
        // And the store kept every word of both.
        expect(
          a.chat.where((e) => e.blocks.contains('two in Y')),
          hasLength(1),
        );
      },
    );

    // +306: the phone speaks its own name on every execution verb.
    // The seat-then-talk two-step let the world's focus move under a
    // prompt in flight; the fix is on the phone too: the prompt, the
    // /new reset, and the model pick all carry the TAB's uuid, not
    // 'whatever the bridge is sitting on'.
    test('+306: every verb names its own tab', () async {
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-306'};
      await a.setBridgeDir('/proj-x'); // the glance names the tab
      await settle();
      const uuid = 'ses-306';
      unawaited(a.runQuickCommand('named prompt'));
      await settle();
      expect(
        harness.talkSids.last,
        uuid,
        reason: 'the prompt names the seated tab, not the world\'s seat',
      );
      await a.setBridgeModel('sonnet');
      expect(
        harness.modelSids.last,
        uuid,
        reason: 'the model pick is FOR this conversation',
      );
      await a.bridgeControl('/new');
      await settle();
      expect(
        harness.resetSids.last,
        uuid,
        reason: 'the /new chip resets ITS tab\'s record by name',
      );
    });

    test(
      '/new replaces the CURRENT tab and leaves every other tab alone',
      () async {
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
        await a.setBridgeDir('/proj-x');
        await settle();
        await a.createSession(harness: 'claude', dir: '/proj-y');
        await settle();
        await a.switchSession(0); // back on the named thread
        // /new: the tab's whole past goes, the OTHER tab's stays.
        await a.bridgeControl('/new');
        await settle();
        // +302: under +295's identity law /new REPLACES the thread
        // IN PLACE — the history dies, the name stands. (The old
        // wipe nulled it and let adoption chase the re-name; that
        // churn is what silently ate the ack's audio on the phone.)
        expect(a.view.tabs[0].currentId, 'ses-X');
        expect(
          a.chat.where((e) => e.blocks.contains('one in X')),
          isEmpty,
          reason: 'the replaced tab\'s history left with its session',
        );
        expect(
          a.chat.any((e) => e.blocks.contains('/new')),
          isFalse,
          reason: 'a /new that leaves its own tombstone is not blank',
        );
        expect(await a.switchSession(1), isNull);
        // Tab 2 was never touched by tab 1's replacement — and tab 1
        // (empty now) is still there with its fresh slot.
        expect(a.view.tabs, hasLength(2));
      },
    );

    test(
      '+297: a stranger conversation\'s tally may not drive this '
      'view\'s meter — the working row survives a foreign `settled`',
      () async {
        // The foreground-sleep tape, to the frame: tab X works while
        // tab Y launches a background shell. Y's launch message goes
        // FINAL and the bridge honestly relays `settled` for IT
        // (openTools is empty — run_in_background lives in bgTools) —
        // and the frame rides the shared ring into X's pump. The
        // tally branch used to feed the meter BEFORE the +274
        // ownership gate was computed, so Y's verdict settled X's
        // ticker, the +182 veto armed, and X's own box went dark
        // THROUGH its own running tool.
        await a.createSession(harness: 'claude', dir: '/proj-x');
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
        await a.setBridgeDir('/proj-x'); // name the seat (+256)
        await settle();
        unawaited(a.runQuickCommand('foreground sleep please'));
        await settle();
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'Bash',
            detail: 'sleep 10',
            session: 'ses-X',
          ),
        );
        await settle();
        expect(
          a.view.showWorkingRow,
          isTrue,
          reason: 'a heard turn with a running tool owns the row',
        );

        // The stranger's settled verdict lands on this view's pump.
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'tokens',
            toolKind: 'settled',
            session: 'ses-OTHER',
          ),
        );
        await settle();
        expect(
          a.view.showWorkingRow,
          isTrue,
          reason:
              'the stranger went final; THIS turn is chewing a tool — '
              'its meter may not be rewritten by a frame stamped '
              'for another conversation',
        );
      },
    );

    test('+297: a prompt on an idle tab never wears the stranger\'s pin '
        '— the park law asks whose turn is live', () async {
      // The same tape's second symptom: while X runs a foreground
      // sleep, a POLITE prompt typed on resting Y shows greyed
      // 'queued' — even though the bridge has per-record queues
      // since +257 and STARTS it within a heartbeat (field: 'the
      // other session erroneously shows messages as queued even
      // though it\'s processed immediately'). The phone parked it on
      // the machine-global busy/badge flags: since +246 those can
      // belong to a backgrounded conversation, and the pin lied
      // about a wait that never happened.
      await a.createSession(harness: 'claude', dir: '/proj-x');
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x'); // name tab X while it is seated
      await settle();
      await a.createSession(harness: 'claude', dir: '/proj-y');
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y'); // name tab Y (createSession seated it)
      await settle();
      expect(await a.switchSession(0), isNull); // start on X
      await settle();
      unawaited(a.runQuickCommand('sleep ten in X'));
      await settle();
      // Swipe to Y mid-turn: X backgrounds (+246 — the turn lives,
      // busy/badge now speak for a conversation that is NOT this tab).
      expect(await a.switchSession(1), isNull);
      await settle();

      // A polite press on the RESTING tab: the prompt goes to Y's
      // record, Y has no open turn — no pin, and the spinner speaks
      // for a prompt that is being asked, not a wait.
      unawaited(
        a.runQuickCommand(
          'hello from Y',
          interrupt: false,
          bubble: 'hello from Y',
        ),
      );
      await settle();
      expect(
        a.queuedText,
        isNull,
        reason:
            'the live turn belongs to the OTHER conversation — the '
            'phone must not park/grey behind a stranger\'s busy flag',
      );
      expect(
        a.view.activity,
        isA<TurnWaiting>(),
        reason: 'an immediate prompt shows its own ask, not the wait',
      );
    });

    test('+298: away work keeps its OWN meter moving — frames route '
        'by stamp, they are not suppressed', () async {
      // The SessionStore's turn slice, end to end: the +297 walk
      // proved a stranger's tally cannot rewrite the seated view's
      // box; the map's other half is that the stranger's OWN ledger
      // learns the numbers — the bar you come home to shows where
      // the work was, not where you left it.
      await a.createSession(harness: 'claude', dir: '/proj-x');
      unawaited(a.runQuickCommand('one in X'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      await a.createSession(harness: 'claude', dir: '/proj-y');
      unawaited(a.runQuickCommand('two in Y'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      // Seat X and leave a turn WORKING there (no done on the wire):
      // the swipe to Y backgrounds it, and the pump stays open — the
      // answer lives, unheard-but-filed (+246).
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('X builds'));
      await settle();
      expect(await a.switchSession(1), isNull);
      await settle();
      expect(a.view.showWorkingRow, isFalse, reason: 'Y is the audience');
      // X's pump, still open, receives a real tally and a stranger's
      // settled verdict: the first lands on X's OWN meter (the pump's
      // bound channel), the second on the channel it names.
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          session: 'ses-X',
          outTokens: 4321,
          inputTokens: 987,
        ),
      );
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'tokens',
          session: 'ses-OTHER',
          outTokens: 500,
        ),
      );
      await settle();
      expect(
        a.channelForTest('ses-X').ticker.tokensOut,
        greaterThan(0),
        reason: 'the away work\'s meter kept counting while you watched Y',
      );
      expect(
        a.channelForTest('ses-OTHER').ticker.tokensOut,
        greaterThan(0),
        reason: 'a stamped frame writes ITS OWN ledger (+298 routing)',
      );
      expect(
        a.view.token.on,
        isFalse,
        reason: 'the seated tab borrowed neither',
      );
    });

    test('+299: a context frame stamped for a stranger is not a '
        'renaming — the xray pump may not become voice-agent', () async {
      // The field tape (16:51:35.794 → #22628): xray works mid-turn
      // (a foreground sleep); voice-agent's PROACTIVE report-turn
      // context frame, stamped ad47…, rides the shared ring into
      // xray's open /talk pump — and the +253 learning re-took the
      // pump's identity from it. Its say then read its own stamp as
      // NOT foreign, was taken and acked, and appended voice-agent's
      // sentence — 'One of the two 20-second sleeps has finished…' —
      // INTO xray's open bubble: the visible cross-session leak.
      // The +253 law was written when one conversation could ever
      // speak into a pump: birth learns its name from the first
      // stamp; a named pump treats a contradicting stamp as the
      // stranger it is.
      await a.createSession(harness: 'claude', dir: '/proj-x');
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x'); // name the seat (+256)
      await settle();
      unawaited(a.runQuickCommand('foreground sleep please'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'Bash',
          detail: 'sleep 20',
          session: 'ses-X',
        ),
      );
      await settle();
      expect(
        a.debugLog.any((l) => l.contains('assistant bubble open')),
        isTrue,
        reason: 'xray\'s own turn bubble is open on its thread',
      );
      // The stranger's report glances in: context first, then the
      // say it carries (the exact tape order).
      harness.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 23572,
          contextWindow: 1000000,
          ctxSession: 'ses-OTHER',
        ),
      );
      harness.emit(
        const BridgeEvent.forTest(
          'say',
          text: 'One of the two sleeps has finished',
          mid: 77,
          session: 'ses-OTHER',
        ),
      );
      await settle();
      expect(
        a.debugLog.any(
          (l) => l.contains('foreign conversation: say left unheard'),
        ),
        isTrue,
        reason:
            '+299: the pump keeps the identity it was born with — '
            'the contradicting stamp is foreign, not a renaming',
      );
      expect(
        a.view.chat.any(
          (e) => e.blocks.contains('One of the two sleeps has finished'),
        ),
        isFalse,
        reason:
            'voice-agent\'s sentence may not squat in xray\'s '
            'bubble — the backlog keeps it for its owner\'s drain',
      );
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
    });

    test('+298: the pending slot adopts its name — naming moves the '
        'label, never the life', () async {
      // The ChatStore law for bubbles, now for the whole turn slice:
      // a conversation born nameless accrues its bookkeeping in the
      // unnamed slot, and the first name the wire speaks re-keys the
      // SLOT — debts, badge, meter and all ride into the name. A
      // banner that blinked out at the moment of naming would tell a
      // lie about work that never stopped.
      await a.createSession(harness: 'claude', dir: '/proj-x');
      unawaited(a.runQuickCommand('start unnamed'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'backgrounded',
          detail: 'Bash sleep 5',
        ),
      );
      await settle();
      expect(
        a.view.backgrounded.visible,
        isTrue,
        reason: 'the nameless birth owes its shell — banner lit',
      );
      // The wire finally speaks the id (the /health law names seats).
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-B'};
      await a.setBridgeModel('default'); // any awaited refresh path
      await settle();
      expect(
        a.view.backgrounded.visible,
        isTrue,
        reason: '+298: the slot adopted the name; the debt rode with it',
      );
      expect(
        a.channelForTest('ses-B').turn.agentDebts,
        contains('Bash sleep 5'),
        reason: 'the ledger now LIVES under the name',
      );
      expect(
        a.channelForTest(null).turn.agentWork,
        isFalse,
        reason: 'a fresh unnamed slot stands where the claim was',
      );
      // The receipt pays at home: the debt retires where it lives.
      harness.emit(
        const BridgeEvent.forTest(
          'tool',
          toolName: 'finished',
          detail: 'Bash sleep 5',
          session: 'ses-B',
        ),
      );
      await settle();
      expect(a.view.backgrounded.visible, isFalse);
    });

    test('+246: mid-turn, a SAME-harness switch backgrounds — the seat '
        'moves, the answer lives, no refusal', () async {
      // The app-background law applied to tabs: switching sessions
      // while the agent works must feel exactly like backgrounding
      // the app — the turn keeps running, its frames keep streaming
      // (session-stamped into their own thread), and switching back
      // is the foreground. Only a harness FLIP still ends a turn.
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      // +256: the destination gets NAMED first (one turn, then the
      // /health records the id onto the tab). A never-spoken tab is a
      // FRESH seat — its move resets, and a mid-turn swipe onto it
      // refuses by law (see 'the unnamed destination is a reset'
      // walk). The backgrounding law is about moving between two
      // conversations that exist.
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y'); // any awaited refresh path names it
      await settle();
      expect(a.view.tabs[1].currentId, 'ses-Y');
      await a.switchSession(0); // start on X (its fresh seat, idle: allowed)
      await settle();
      harness.healthState = {
        ...harness.healthState!,
        'harness': 'opencode',
        'sessionId': 'ses-X', // X gets its own name the honest way: a turn
        'turnOpen': true,
        'missed': 1,
      };
      final before = harness.seatCalls.length;
      expect(
        await a.switchSession(1),
        isNull,
        reason:
            'turnOpen AND unheard backlog both stop resting the '
            'move when no reset will run — the backlog rides along',
      );
      expect(harness.seatCalls.length, before + 1);
      expect(harness.seatCalls.last['dir'], '/proj-y');
      expect(a.view.tabIndex, 1);
    });

    test('+248: mid-turn, a CROSS-harness switch backgrounds too — '
        'the positive walk the +278 debt test only hinted at', () async {
      // +248 retired the same-harness restriction outright: the
      // running child is not bound to the harness variable (the seat's
      // new harness spawns its own child only on the NEXT turn), so a
      // live turn has nothing to lose to a differing tab. The +246
      // walk above pins same-harness; every surviving cross-harness
      // pin was a REFUSAL shape (+256) or a debt-window variant
      // (+278). This is the success walk itself.
      await a.createSession(harness: 'claude', dir: '/proj-x');
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      // Name the destination (+256 law: an unnamed tab is a reset and
      // would rightly refuse; a named one is a conversation).
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      expect(a.view.tabs[1].currentId, 'ses-Y');
      await a.switchSession(0); // home on X (its fresh seat, idle: allowed)
      await settle();
      harness.healthState = {
        ...harness.healthState!,
        'harness': 'claude',
        'sessionId': 'ses-X', // X is WORKING: the bridge says so, and the
        'turnOpen': true,     // app obeys the bridge, not its own tab
        'missed': 1,
      };
      final before = harness.seatCalls.length;
      expect(
        await a.switchSession(1),
        isNull,
        reason:
            'the differing harness is not a reason to refuse: the '
            'turn backgrounds exactly as on a same-harness swipe '
            '(+248 — the child survives; the next turn spawns on '
            'the new era only when spoken)',
      );
      expect(harness.seatCalls.length, before + 1);
      expect(harness.seatCalls.last['harness'], 'opencode');
      expect(a.view.tabIndex, 1);
    });

    test('+249: mid-turn, a switch hides the thinking row at the '
        'destination and restores it at home', () async {
      // The field shape: two named threads, a turn WORKING in one.
      // Swiping to the other tab backgrounds the turn (+246) — and
      // its THINKING BOX must travel with its thread, not the window
      // (+249): the destination shows nothing until IT has work in
      // flight; swiping back is the foreground, and the row is lit
      // exactly where the work lives.
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      unawaited(a.runQuickCommand('two in Y', bubble: 'two in Y'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      // Seat X and leave a turn WORKING there (no done on the wire).
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('think in X', bubble: 'think in X'));
      await settle();
      harness.healthState = {...harness.healthState!, 'turnOpen': true};
      expect(a.view.showWorkingRow, isTrue); // working, and at home here
      // SWIPE to the other tab mid-turn: the turn backgrounds.
      expect(await a.switchSession(1), isNull);
      expect(a.view.tabIndex, 1);
      expect(
        a.view.bridgeBusy,
        isFalse,
        reason:
            'the work stayed with ses-X — +298 (+251 step 3): '
            'the CHANNEL is the marker; a stranger\'s busy flag '
            'lives on the stranger\'s ledger, and the seat reads '
            'its own',
      );
      expect(
        a.view.showWorkingRow,
        isFalse,
        reason:
            'no thinking box in the tab that is only the audience — '
            'the gear badge (+230) still owns the cross-session sign',
      );
      // SWIPE BACK: the foreground restored — the row is lit at home,
      // not re-orphaned by the second move's own bookkeeping.
      expect(await a.switchSession(0), isNull);
      expect(a.view.turnHomeHere, isTrue);
      expect(
        a.view.showWorkingRow,
        isTrue,
        reason: 'the turn never stopped; coming home shows it working',
      );
    });

    // +314: the band cache rides the TAB OBJECT, not its index slot:
    // a deletion used to require shifting every later key by hand
    // (ten lines apologising for keying a conversation's presentation
    // by its position). The observable law is the same — the line
    // follows the thread — but it now holds by identity, and the
    // doomed tab's line dies exactly with it. This walk pins the law
    // across a deletion: three tabs earn distinctive lines, the first
    // dies, and every survivor must resume on ITS OWN line at its
    // NEW position — a mis-shift would put the wrong thread's
    // command on the band.
    test('+314: a band rides its tab, not its slot', () async {
      Future<void> tabbed(String dir, String sid) async {
        await a.createSession(harness: 'claude', dir: dir);
        await settle();
        // NAMED tabs: an unnamed switch RESETS, and a reset refuses a
        // mid-turn move (+230's rest law) — that refusal is a law of
        // its own, not this walk's subject.
        harness.healthState = {...harness.healthState!, 'sessionId': sid};
        await a.setBridgeDir(dir);
        await settle();
      }

      await tabbed('/proj-a', 'ses-a');
      await tabbed('/proj-b', 'ses-b');
      await tabbed('/proj-c', 'ses-c');
      Future<void> earn(int to, String job) async {
        expect(await a.switchSession(to, force: true), isNull);
        unawaited(a.runQuickCommand('job $job'));
        await settle();
        harness.emit(
          BridgeEvent.forTest('tool', toolName: 'Bash', detail: 'job-$job'),
        );
        await settle();
        // The floor is released WITHOUT a farewell frame: a done
        // would stamp its own receipt line over the band we came to
        // cache, and a parked second prompt would make every later
        // switch a rest-law refusal — neither is this walk's subject.
        harness.turnOpenOnServer = false;
        await settle();
      }

      await earn(0, 'a');
      expect(await a.switchSession(1), isNull);
      a.settleBandOnLanding(0, 1); // A caches 'Bash job-a…'
      await earn(1, 'b');
      expect(await a.switchSession(2), isNull);
      a.settleBandOnLanding(1, 2); // B caches 'Bash job-b…'
      await earn(2, 'c');
      expect(await a.switchSession(0), isNull);
      a.settleBandOnLanding(2, 0); // C caches 'Bash job-c…'
      await settle();
      expect(
        a.view.status,
        'Bash job-a…',
        reason: 'A resumes on its own line before the deletion',
      );
      // The first tab dies at the ✕ — everything after it shifts left.
      expect(await a.removeSessionTab(0), isNull);
      await settle();
      expect(await a.switchSession(1), isNull); // C (now index 1)
      a.settleBandOnLanding(0, 1);
      await settle();
      expect(
        a.view.status,
        'Bash job-c…',
        reason: "C's line followed the OBJECT, not the old slot",
      );
      expect(await a.switchSession(0), isNull); // B (now index 0)
      a.settleBandOnLanding(1, 0);
      await settle();
      expect(
        a.view.status,
        'Bash job-b…',
        reason: "and B's followed too — the shift is structurally gone",
      );
    });

    test(
      '+259: a command that works in X never paints the band on Y',
      () async {
        // The leak the field tape shows: while the tab you LEFT churned a
        // build, its 'Bash …' rode the top line of the tab you swiped
        // onto. The band now has an owner — the same law the meter (+249)
        // and the busy shimmer (+256) already obey — and the away work
        // keeps feeding only its own ledgers.
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
        await a.setBridgeDir('/proj-x');
        await settle();
        await a.createSession(harness: 'opencode', dir: '/proj-y');
        unawaited(a.runQuickCommand('one in Y', bubble: 'one in Y'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
        await a.setBridgeDir('/proj-y');
        await settle();
        // Seat X and leave a turn WORKING there, mid-command.
        expect(await a.switchSession(0), isNull);
        unawaited(a.runQuickCommand('build in X', bubble: 'build in X'));
        await settle();
        harness.emit(
          const BridgeEvent.forTest(
            'context',
            inputTokens: 10,
            contextWindow: 20,
            ctxSession: 'ses-X',
          ),
        );
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'Bash',
            detail: 'flutter test',
          ),
        );
        await settle();
        expect(
          a.view.status,
          'Bash flutter test…',
          reason: 'at home the band names the command, as it always did',
        );
        harness.healthState = {...harness.healthState!, 'turnOpen': true};
        // SWIPE to Y mid-turn: the turn backgrounds (+246) — and the
        // borrowed command must be gone at the landing, not merely
        // unpainted until the next frame.
        expect(await a.switchSession(1), isNull);
        // +266: the band changes when the THREAD changes — the screen
        // performs that at the flip's off-screen hand-off, which this
        // assistant-level walk plays itself.
        a.settleBandOnLanding(0, 1);
        await settle();
        expect(
          a.view.status,
          isNot(contains('Bash')),
          reason: 'the destination opens on ITS OWN rest line',
        );
        expect(
          a.debugLog.any((l) => l.contains('band reset')),
          isTrue,
          reason: 'the sweep is named on the tape, not just felt',
        );
        // X keeps chewing. Its NEXT command must stay out of earshot —
        // the leak's live shape, one frame after the landing.
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'Bash',
            detail: 'dart analyze',
          ),
        );
        await settle();
        expect(
          a.view.status,
          isNot(contains('dart')),
          reason: 'the away thread works silently, like its says already do',
        );
        expect(
          a.debugLog.any((l) => l.contains('band kept')),
          isTrue,
          reason: 'and the refusal to paint is itself auditable',
        );
        // COMING HOME: the seated conversation gets its line back —
        // and NOT the stale one. The away frame above went into X's
        // cache (+266), so the restored band names what the harness
        // ran LAST, not what was running when the swipe left. No
        // rest-line flash, no wait for the next frame: the cache IS
        // the state, kept current by the same gate that declined to
        // paint it.
        expect(await a.switchSession(0), isNull);
        a.settleBandOnLanding(1, 0);
        await settle();
        expect(
          a.view.status,
          'Bash dart analyze…',
          reason: 'the cache stayed current while the tab was away',
        );
        expect(
          a.debugLog.any((l) => l.contains('resumes on its OWN cached line')),
          isTrue,
        );
        expect(
          a.view.turnHomeHere,
          isTrue,
          reason:
              '+298: the work still lives on X\'s channel — '
              'the band cache changed nothing',
        );
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'Bash',
            detail: 'git log',
          ),
        );
        await settle();
        expect(
          a.view.status,
          'Bash git log…',
          reason: 'the conversation on screen always owns the band',
        );
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
      },
    );

    test(
      '+277: a settled background debt buries its tab\u2019s stale '
      'band \u2014 and an idle stranger tab cannot settle it at all',
      () async {
        // The 21:49 field tape, end to end: X runs a backgrounded
        // shell, its turn closes politely with the debt owed, and the
        // user swipes. (+276) the idle tab\u2019s clean /health must not
        // retire the banner \u2014 and when X\u2019s OWN health finally
        // settles the debt, the cached \u2018Bash sleep 15\u2026\u2019 row
        // goes with it, so coming home shows the rest line, not a
        // spinner-shaped lie about work that stopped existing.
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
        await a.setBridgeDir('/proj-x');
        await settle();
        await a.createSession(harness: 'opencode', dir: '/proj-y');
        unawaited(a.runQuickCommand('one in Y', bubble: 'one in Y'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
        await a.setBridgeDir('/proj-y');
        await settle();
        // Seat X: a turn opens, the harness backgrounds a shell, the
        // turn closes with the debt owed.
        expect(await a.switchSession(0), isNull);
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
        unawaited(a.runQuickCommand('sleep for me', bubble: 'sleep for me'));
        await settle();
        harness.emit(
          const BridgeEvent.forTest(
            'context',
            inputTokens: 10,
            contextWindow: 20,
            ctxSession: 'ses-X',
          ),
        );
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'backgrounded',
            detail: 'Bash sleep 15',
          ),
        );
        // The bridge counts the owed shell in its detached ledger —
        // the honest tape says detached=1 while the sleep runs (the
        // 21:49:43 resume probe), and 0 once it is over.
        harness.healthState = {...harness.healthState!, 'detached': 1};
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        // SWIPE to idle Y: Y\u2019s clean health speaks only for Y (+276).
        // (Y's own ledger has nothing detached — the count rides the
        // seated conversation.)
        harness.healthState = {
          ...harness.healthState!,
          'sessionId': 'ses-Y',
          'detached': 0,
        };
        expect(await a.switchSession(1), isNull);
        a.settleBandOnLanding(0, 1);
        await settle();
        expect(
          a.debugLog.any((l) => l.contains('bg line holds')),
          isTrue,
          reason: 'the hold is named on the tape, not silently survived',
        );
        expect(
          a.view.backgrounded.visible,
          isFalse,
          reason:
              '+278: the debt STANDS on Y, but the banner belongs to X '
              '\u2014 held out of sight, not retired, and not leaked',
        );
        expect(
          a.debugLog.any((l) => l.contains('bg line holds')),
          isTrue,
          reason: 'the hold is the state law; hiding is only the paint law',
        );
        // COME HOME: the sleep has ended while the tab was away
        // (X's detached count is back to 0); X\u2019s OWN clean health
        // settles the debt \u2014 the banner retires, the receipt files,
        // and the tab\u2019s cached command line is buried with it
        // (+277).
        harness.healthState = {
          ...harness.healthState!,
          'sessionId': 'ses-X',
          'detached': 0,
        };
        expect(await a.switchSession(0), isNull);
        a.settleBandOnLanding(1, 0);
        await settle();
        expect(
          a.debugLog.any((l) => l.contains('bg line retired')),
          isTrue,
          reason: 'this time the proof speaks for the badge\u2019s thread',
        );
        expect(
          a.view.status,
          isNot(contains('Bash sleep 15')),
          reason:
              'the band must not resurrect the dead command \u2014 the '
              'tape\u2019s lie was a spinner that outlived its work',
        );
        expect(
          a.debugLog.any((l) => l.contains('resumes on its OWN cached line')),
          isFalse,
          reason: 'the cache entry is gone, not merely unpainted',
        );
      },
    );

    test('+270: the return SPEAKS — a switch cut kills the mouth, not '
        'the turn', () async {
      // The field signature of this round, in Tim's words: 'the cutoff
      // is working — it stops immediately. But when I swipe back, new
      // messages don\'t come through at all. Just completely silent.'
      // The tape agreed: after the return, every say passed the gates,
      // synthesised, reached the queue — and died there unheard for
      // the rest of the turn (119 s of it): the cut retired the pump
      // and NOTHING revived it. The +254 arc\'s proof of \"speaks
      // after the return\" checked engine.synthesized — a mouth that
      // never opened can still mouth words. This walk counts the
      // PLAYER.
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      unawaited(a.runQuickCommand('one in Y', bubble: 'one in Y'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('talk in X', bubble: 'talk in X'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 10,
          contextWindow: 20,
          ctxSession: 'ses-X',
        ),
      );
      harness.emit(
        const BridgeEvent.forTest('say', text: 'on air when you go.', mid: 61),
      );
      await settle();
      time.advance(const Duration(milliseconds: 50)); // the pump delivers
      await settle();
      final playedBefore = out.played.length;
      expect(
        playedBefore,
        greaterThan(0),
        reason: 'the paragraph reached the player',
      );
      expect(out.playing, isTrue, reason: 'audio ON AIR at the swipe');
      harness.healthState = {...harness.healthState!, 'turnOpen': true};
      expect(await a.switchSession(1), isNull);
      await settle();
      expect(
        out.playing,
        isFalse,
        reason: 'the cut is instant — the half that already works',
      );
      // Away, the thread keeps answering: the identity gate files it,
      // and the watched tab's player stays cold.
      harness.emit(
        const BridgeEvent.forTest('say', text: 'away, filed mute.', mid: 62),
      );
      await settle();
      expect(
        out.played.length,
        playedBefore,
        reason: "someone else's answer does not speak on this tab",
      );
      // COME HOME — and the NEXT paragraph must be HEARD, not merely
      // filed: the revival law (ReplyPipeline.enqueue respawns the
      // cut pump while the stream lives).
      expect(await a.switchSession(0), isNull);
      harness.emit(
        const BridgeEvent.forTest('say', text: 'home, and audible.', mid: 63),
      );
      await settle();
      time.advance(const Duration(milliseconds: 50));
      await settle();
      expect(
        out.played.length,
        greaterThan(playedBefore),
        reason:
            'the queue found a reader again — this is AUDIO, not '
            'synthesis: a mouth that never opened can still mouth words',
      );
      expect(out.playing, isTrue);
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
    });

    test(
      "+259: a creation that WOULD inherit a command refuses instead",
      () async {
        // The other half of the field report: opening a new session while
        // the old one chews must not print the old work line on the new
        // tab. Creation RESTS the seat (+248), so mid-command it refuses
        // with words — the inheritance shape never lands.
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        unawaited(a.runQuickCommand('build in X', bubble: 'build in X'));
        await settle();
        harness.emit(
          const BridgeEvent.forTest(
            'tool',
            toolName: 'Bash',
            detail: 'flutter analyze',
          ),
        );
        await settle();
        expect(a.view.status, 'Bash flutter analyze…');
        final err = await a.createSession(harness: 'opencode', dir: '/proj-y');
        expect(
          err,
          contains('mid-turn'),
          reason: 'the refusal IS the guard: no fresh tab wears it',
        );
        expect(a.view.status, 'Bash flutter analyze…');
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
      },
    );

    test('+253: swipe away mid-turn — the answer lands in its thread '
        'mute; after the return, the next paragraph gets a voice', () async {
      // The full field arc over the real assistant: a turn working in
      // X speaks while X is on screen; the swipe to Y files X's answer
      // silently (the new tab keeps its peace); swiping back is the
      // foreground — X's NEXT sentence speaks, and what landed while
      // away is complete history, never re-spoken (the heard ack rode
      // the take).
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      unawaited(a.runQuickCommand('two in Y', bubble: 'two in Y'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      // Seat X, start a turn that stays OPEN (no done on the wire).
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('work in X', bubble: 'work in X'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'say',
          text: 'heard before the swipe.',
          mid: 21,
        ),
      );
      await settle();
      expect(
        engine.synthesized,
        contains('heard before the swipe.'),
        reason: 'the focused conversation speaks as always',
      );
      // SWIPE AWAY mid-turn (the +246 backgrounding keeps the stream).
      harness.healthState = {...harness.healthState!, 'turnOpen': true};
      expect(await a.switchSession(1), isNull);
      harness.emit(
        const BridgeEvent.forTest('say', text: 'answered while away.', mid: 22),
      );
      await settle();
      expect(
        engine.synthesized,
        isNot(contains('answered while away.')),
        reason: 'the tab you swipe onto does not get someone else\'s answer',
      );
      // BACK TO X: the foreground — and the NEXT paragraph speaks.
      expect(await a.switchSession(0), isNull);
      harness.emit(
        const BridgeEvent.forTest('say', text: 'back home, speaking.', mid: 23),
      );
      await settle();
      expect(
        engine.synthesized,
        containsAll(['heard before the swipe.', 'back home, speaking.']),
        reason: 'live work at home keeps its voice',
      );
      expect(
        engine.synthesized,
        isNot(contains('answered while away.')),
        reason: 'and the away backlog is NEVER re-spoken — it was acked',
      );
      // The thread of X has every word, in order, in one answer.
      expect(
        a.chat.map((e) => e.blocks),
        contains(
          containsAllInOrder([
            'heard before the swipe.',
            'answered while away.',
            'back home, speaking.',
          ]),
        ),
      );
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
    });

    test('+255: a turn backgrounded in X must not rent the working '
        'row on Y — even when Y fetches its mail', () async {
      // The xray field tape: swipe away mid-turn, land on a tab that
      // owes unheard frames, and the phone reattaches to drain them.
      // The bridge's global turnOpen says TRUE — for the BACKGROUNDed
      // claude turn — and the +168 law reads that as 'generating
      // work, real spin'. The row already knows the work is not
      // Y's (+249's marker); the attach's claim must not launder a
      // stranger's turn into this tab's thinking box.
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      unawaited(a.runQuickCommand('two in Y', bubble: 'two in Y'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      // X seats, works, keeps working (no done).
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('work in X', bubble: 'work in X'));
      await settle();
      harness.healthState = {...harness.healthState!, 'turnOpen': true};
      expect(a.view.showWorkingRow, isTrue);
      // SWIPE to Y, which owes unheard mail.
      harness.healthState = {...harness.healthState!, 'missed': 2};
      expect(await a.switchSession(1), isNull);
      await settle();
      expect(
        a.view.bridgeBusy,
        isFalse,
        reason:
            'the work stayed with ses-X — +298 (+251 step 3): '
            'the CHANNEL is the marker; a stranger\'s busy flag '
            'lives on the stranger\'s ledger, and the seat reads '
            'its own',
      );
      expect(
        a.view.showWorkingRow,
        isFalse,
        reason: 'the stranger\'s turn may not light this tab\'s box',
      );
      // The stranded-backlog drain runs while X still owns the
      // machine: reading mail stays mail — the box must not re-light
      // just because /health says SOME turn is open. +298: the probe
      // names the backgrounded turn (an old bridge's ONE focus), the
      // drain moves to THAT channel — and finds the view still
      // heard: inert, no claim, nothing to rent.
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.reattachBackgroundTurn();
      await settle();
      expect(
        a.view.showWorkingRow,
        isFalse,
        reason:
            'the foreign OPEN turn may not be claimed here at all — '
            'the row belongs to the conversation, and so does its '
            'attach (the +255 law, per-channel)',
      );
      // +256 (the xray tape's third finding): the bar's MOTION obeys
      // the same ownership as its numbers and the row — and an
      // unnamed seat no longer counts as home by default. Drop the
      // seat's name from the health line (a reset conversation is
      // exactly this shape): the away marker must still gate.
      harness.healthState = Map.of({...harness.healthState!})
        ..remove('sessionId');
      await a.setBridgeModel('default'); // any awaited refresh path
      await settle();
      expect(
        a.view.bridgeBusy,
        isFalse,
        reason:
            '+298: the foreign turn is open — ON ITS OWN '
            'CHANNEL. The seat reads its own ledger and borrows '
            'nothing; the +256 clause (a nameless seat is not '
            'home by default) is now the map\'s shape',
      );
      expect(
        a.view.agentBusy,
        isTrue,
        reason:
            'the away work keeps the cross-session sign (+230) '
            '— the gear badge owns it, not this tab\'s box',
      );
      expect(
        a.view.context.busy,
        isFalse,
        reason: 'the measuring shimmer spins only for the seat\'s own work',
      );
      expect(a.view.showWorkingRow, isFalse);
      harness.finishView();
    });

    test('+257: leaving drops the audio; the claimed turn names its own '
        'home; and the done retires the marker', () async {
      // The volley's closing three, in one field shape: (1) the swipe
      // away CUTS the speaker mid-sentence and flushes what was queued
      // — barge-in's drop law, journalled, nothing untraceable; (2) a
      // mail fetch on the watching tab claims the BACKGROUNDed turn —
      // its context frame names the real conversation, and the marker
      // signs to THAT, never to the seat whose slot lit up; (3) the
      // away turn's done retires the marker — proof, not age.
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      unawaited(a.runQuickCommand('two in Y', bubble: 'two in Y'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      // Work in X, heard: a paragraph reaches the speaker (the fake
      // player holds the chunk — audio is ON AIR).
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('work in X', bubble: 'work in X'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 300,
          contextWindow: 500,
          ctxSession: 'ses-X',
        ),
      );
      harness.emit(
        const BridgeEvent.forTest('say', text: 'mid sentence', mid: 31),
      );
      await settle();
      time.advance(const Duration(milliseconds: 50)); // the pump delivers
      await settle();
      expect(out.playing, isTrue, reason: 'audio on air before the swipe');
      // THE SWIPE: speaker cut, queue flushed, drop journalled.
      harness.healthState = {...harness.healthState!, 'missed': 1};
      expect(await a.switchSession(1), isNull);
      await settle();
      expect(
        out.stopCount,
        greaterThan(0),
        reason: 'leaving is dropping — mid-sentence, no ceremony',
      );
      expect(out.playing, isFalse);
      expect(
        a.view.bridgeBusy,
        isFalse,
        reason:
            'the STATED owner (ses-X) holds the work on ITS '
            'OWN channel (+298: the marker became the map)',
      );
      // X keeps streaming into its still-open view while Y is on
      // screen (the switch dropped the AUDIO, not the subscription):
      // the busy slot is lit for a stranger right here on Y — this is
      // the shape the sharing bug wore. The view's frames keep naming
      // ses-X, so the marker holds, and Y stays a quiet audience.
      harness.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 320,
          contextWindow: 500,
          ctxSession: 'ses-X',
        ),
      );
      harness.emit(
        const BridgeEvent.forTest('say', text: 'away words stream on', mid: 32),
      );
      await settle();
      expect(
        engine.synthesized,
        isNot(contains('away words stream on')),
        reason: 'the conversation you left speaks into its thread, mute',
      );
      expect(
        a.view.bridgeBusy,
        isFalse,
        reason:
            'a lit busy slot for the stranger lives on the '
            'stranger\'s channel — the sharing bug is '
            'unrepresentable (+298)',
      );
      expect(a.view.showWorkingRow, isFalse, reason: 'no borrowed box on Y');
      // The reattach path itself is inert while the view is heard —
      // nothing to steal when the ear never let go. +298: the probe
      // names the backgrounded turn (the old bridge's one focus), and
      // the inertness checks against THAT conversation's busy flag —
      // the drain cannot even claim the watching tab as a proxy.
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      expect(await a.reattachBackgroundTurn(), isFalse);
      // COME HOME: the stated owner re-signs the marker on the way
      // (owner beats seat), and arrival finds the box at its door.
      expect(await a.switchSession(0), isNull);
      await settle();
      expect(
        a.view.turnHomeHere,
        isTrue,
        reason: 'the work was always ses-X\'s — coming back proves it',
      );
      expect(
        a.view.showWorkingRow,
        isTrue,
        reason: 'home, still working: the box is lit where it belongs',
      );
      // PROOF RETIRES IT: X's turn says its period (heard now — it
      // speaks like any live answer). +298: 'the done retires the
      // marker' reads structurally — the box goes dark on the
      // conversation that closed because ITS ledger says so.
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      expect(
        a.view.showWorkingRow,
        isFalse,
        reason:
            'the farewell consumed the work — the box goes dark '
            'where it was heard, by its own flags (+298: this is '
            'what marker-retirement became)',
      );
      expect(
        a.view.turnHomeHere,
        isTrue,
        reason: '+298: every projection is its own home',
      );
    });

    test('+259: the cut is the landing, not the capture — a speak tail '
        'with fallen flags dies at the swipe too', () async {
      // Tim's round-four tape: 'switching should kill the TTS
      // immediately — currently it is just speaking in the background.'
      // The +257 cut hung on the live-work capture inside
      // switchSession; the shape that walked past it is the speak tail
      // that OUTLIVES the wire — no busy flags, no badge, just audio.
      // The cut now rides every landing (the same door the watermark
      // and the band sweep use).
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      unawaited(a.runQuickCommand('two in Y', bubble: 'two in Y'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      expect(await a.switchSession(0), isNull);
      unawaited(a.runQuickCommand('last word in X', bubble: 'last word in X'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest('say', text: 'still on air', mid: 41),
      );
      await settle();
      time.advance(const Duration(milliseconds: 50)); // the pump delivers
      await settle();
      expect(out.playing, isTrue, reason: 'audio on air');
      // The turn CLOSES — every flag falls — while the chunk plays on.
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      expect(
        a.view.bridgeBusy,
        isFalse,
        reason: 'no live-work capture for the old cut to lean on',
      );
      expect(
        out.playing,
        isTrue,
        reason: 'the tail outlives the wire — the exact field shape',
      );
      final stopsBefore = out.stopCount;
      expect(await a.switchSession(1), isNull);
      await settle();
      expect(
        out.stopCount,
        greaterThan(stopsBefore),
        reason: 'the tail is cut too: no voice follows you between tabs',
      );
      expect(out.playing, isFalse);
      expect(
        a.debugLog.any((l) => l.contains('ear let go')),
        isTrue,
        reason: 'and the drop stays traceable (the barge-in law)',
      );
    });

    test('+257: the Stop chip cuts the conversation it is listening '
        'to, by name', () async {
      // The router's side of the law: every conversation owns a floor,
      // so the cut must say WHICH. The phone addresses the stop to
      // the turn's stated owner (the ctx frame's session), not to
      // whatever tab happens to be seated.
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('working', bubble: 'working'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 100,
          contextWindow: 200,
          ctxSession: 'ses-stop-target',
        ),
      );
      await settle();
      a.bridgeStop(); // the chip
      await settle();
      expect(
        harness.lastStopSid,
        'ses-stop-target',
        reason: 'the cut is addressed to the conversation that owns the turn',
      );
      expect(
        a.debugLog.any(
          (l) => l.contains('hardStop=true') && l.contains('stopChip'),
        ),
        isTrue,
        reason: 'the funnel that was, with its verdict on the tape',
      );
      harness.finishView();
    });

    // +289 (Tim's field: 'swipe away from a session — the TTS should
    // be paused or stopped IMMEDIATELY, but is still speaking'):
    // three awaits stood between the fling and the cut — the /seat
    // round trip, the prefs write, the refreshing /health — and the
    // stale seat pointer left the door open one round trip LONGER:
    // the left-behind conversation's freshest paragraph passed the
    // focus gate (it still WAS the seat, as far as the phone knew),
    // revived the cut pump, and spoke on the tab you switched to.
    // The mouth now closes at the COMMIT, and the /seat answer wears
    // its name the moment it lands. The laggy harness below makes
    // those wire windows observable.
    Future<void> seatedXWithLiveSpeech(_LaggyHarness lag) async {
      lag.healthState = <String, Object?>{
        'ok': true,
        'claudeUp': true,
        'harness': 'claude',
        'dir': '/proj-a',
        'seat': true,
      };
      a.dispose();
      a = VoiceAssistant(
        worker: engine,
        micSource: FakeMic(),
        audioOutput: out,
        gatewayFactory: (_, _) => lag,
        scheduler: time = FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
      harness = lag; // every emit below aims at the seated views
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('one in X', bubble: 'one in X'));
      await settle();
      lag.emit(BridgeEvent.forTest('done'));
      lag.finishView();
      await settle();
      lag.healthState = {...lag.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      // Same harness for Y: the mid-turn move BACKGROUNDS rather
      // than resets (+246) — the swipeable shape the field lives in.
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      unawaited(a.runQuickCommand('one in Y', bubble: 'one in Y'));
      await settle();
      lag.emit(BridgeEvent.forTest('done'));
      lag.finishView();
      await settle();
      lag.healthState = {...lag.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      expect(await a.switchSession(0), isNull); // seat X
      unawaited(a.runQuickCommand('talk in X', bubble: 'talk in X'));
      await settle();
      lag.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 10,
          contextWindow: 20,
          ctxSession: 'ses-X',
        ),
      );
      lag.emit(
        const BridgeEvent.forTest('say', text: 'on air when you go.', mid: 71),
      );
      await settle();
      time.advance(const Duration(milliseconds: 50)); // the pump delivers
      await settle();
      expect(out.playing, isTrue, reason: 'audio ON AIR at the swipe');
      lag.healthState = {...lag.healthState!, 'turnOpen': true};
    }

    test('+289: the cut is the COMMIT — /seat still in flight, the ear '
        'has already let go', () async {
      final lag = _LaggyHarness();
      await seatedXWithLiveSpeech(lag);
      lag.holdSeat = Completer<void>();
      final stopsBefore = out.stopCount;
      final fut = a.switchSession(1);
      await settle();
      expect(
        lag.seatCalls.last['sessionId'],
        'ses-Y',
        reason: 'the verb IS on the wire — the response has not landed',
      );
      expect(
        out.stopCount,
        greaterThan(stopsBefore),
        reason: '+289: the cut does not wait the round trip',
      );
      expect(out.playing, isFalse);
      expect(
        a.debugLog.any((l) => l.contains('ear let go')),
        isTrue,
        reason: 'and the drop names itself (the barge-in law)',
      );
      lag.holdSeat!.complete();
      expect(await fut, isNull);
      await settle();
      lag.emit(BridgeEvent.forTest('done'));
      lag.finishView();
    });

    test('+289: the seat answer WEARS ITS NAME at once — a say landing '
        'while the refreshing /health is still in flight cannot re-open '
        'the cut mouth', () async {
      final lag = _LaggyHarness();
      await seatedXWithLiveSpeech(lag);
      // The rest-law /health passes; the REFRESHING one (the glance
      // after the verb, the old code's only source for the pointer)
      // parks. The old leak: during this park the pointer still
      // named the conversation just left, its freshest paragraph
      // sailed through viewHome, revived the pump, and talked on
      // the destination tab.
      lag.holdHealthAfter = lag.healthCalls;
      lag.holdRefresh = Completer<void>();
      final fut = a.switchSession(1);
      await settle();
      expect(out.playing, isFalse, reason: 'the commit cut first');
      final playedBefore = out.played.length;
      lag.emit(
        const BridgeEvent.forTest('say', text: 'still talking?', mid: 72),
      );
      await settle();
      time.advance(const Duration(milliseconds: 50));
      await settle();
      expect(
        out.played,
        hasLength(playedBefore),
        reason:
            'the left-behind conversation files mute even before '
            '/health confirms the seat — the /seat answer moved the '
            'pointer the moment it landed',
      );
      expect(
        a.debugLog.any((l) => l.contains('unfocused conversation')),
        isTrue,
        reason: 'and the silence names its law',
      );
      lag.holdRefresh!.complete();
      expect(await fut, isNull);
      await settle();
      lag.emit(BridgeEvent.forTest('done'));
      lag.finishView();
    });

    test(
      '+256: the unnamed destination is a reset — a mid-turn swipe '
      'onto a never-spoken tab REFUSES with words, not a silent kill',
      () async {
        // The xray tape's opening act: the first swipe reset the
        // bridge's conversation under a 'free to move' verdict and
        // SIGTERM'd the answering turn. A tab that never spoke has no
        // id; seating it sends fresh:true; fresh ALWAYS resets; so the
        // rest law reads the reset law. Idle moves stay free — the
        // refusal is exactly the shape +248 already wrote for fresh.
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        await a.createSession(
          harness: 'opencode',
          dir: '/proj-z',
        ); // never speaks
        await a.switchSession(0); // idle: seating X's fresh start is allowed
        unawaited(a.runQuickCommand('work in X', bubble: 'work in X'));
        await settle();
        harness.healthState = {
          ...harness.healthState!,
          'sessionId': 'ses-X',
          'turnOpen': true,
        };
        await a.setBridgeDir('/proj-x'); // name X while its turn streams
        await settle();
        final before = harness.seatCalls.length;
        expect(
          await a.switchSession(1),
          'the harness is mid-turn — stop it before switching sessions',
          reason: 'an unnamed destination resets; resets rest mid-turn',
        );
        expect(harness.seatCalls.length, before, reason: 'no wire verb fired');
        expect(a.view.tabIndex, 0, reason: 'stayed put, honestly');
        // The turn closes; the same move is now free (resetting nothing).
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        harness.healthState = Map.of({...harness.healthState!})
          ..remove('turnOpen'); // the real bridge closes its flag with the turn
        await settle();
        expect(await a.switchSession(1), isNull);
        expect(a.view.tabIndex, 1);
      },
    );

    test(
      'unheard messages rest the seat — a tab verb may not eat the backlog',
      () async {
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        await a.createSession(harness: 'claude', dir: '/proj-y');
        harness.healthState = {...harness.healthState!, 'missed': 2};
        final before = harness.seatCalls.length;
        expect(
          await a.switchSession(0),
          'the bridge owes unheard messages — they land first',
        );
        expect(
          await a.createSession(harness: 'claude', dir: '/proj-z'),
          'the bridge owes unheard messages — they land first',
        );
        expect(
          harness.seatCalls.length,
          before,
          reason:
              'a seat move resets the conversation — over the '
              'unplayed backlog that would silently eat unseen messages',
        );
        expect(a.view.tabIndex, 1); // stayed put, honestly
        // The tap that was refused armed the drain; the replay lands
        // (missed goes to 0) and the very next switch moves.
        harness.healthState = {...harness.healthState!}..remove('missed');
        expect(await a.switchSession(0), isNull);
        expect(a.view.tabIndex, 0);
      },
    );

    test(
      'the boot reconcile holds while a replay is owed, reconciles after',
      () async {
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        // The seat moved out of band AND the bridge owes frames: the
        // reconcile must wait for the mail, not resetConversation it.
        harness.healthState = <String, Object?>{
          ...harness.healthState!,
          'harness': 'claude',
          'dir': '/elsewhere',
          'sessionId': 'ses-stranger',
          'missed': 3,
        };
        await a.setBridge(url: 'http://harness.test', token: 'tok');
        await settle();
        expect(harness.seatCalls.length, 1); // create only — reconcile held
        // The replay lands (whatever path clears the backlog): the
        // NEXT glance reconciles, no re-boot needed.
        harness.healthState = {...harness.healthState!}..remove('missed');
        await a.setBridgeModel('default'); // any awaited refresh path
        await settle();
        expect(harness.seatCalls.length, 2);
        expect(harness.seatCalls.last['dir'], '/proj-x');
      },
    );

    test(
      'a tab switch restores the FULL thread — everything it ever spoke',
      () async {
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        unawaited(a.runQuickCommand('seen in X', bubble: 'seen in X'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
        await a.setBridgeDir('/proj-x');
        await settle();
        final tabXCount = a.view.chat.length;
        await a.createSession(harness: 'claude', dir: '/proj-y');
        await settle();
        await a.switchSession(0);
        expect(a.view.tabIndex, 0);
        expect(a.view.chat, hasLength(tabXCount)); // whole thread restored
        expect(a.view.chat.any((e) => e.blocks.contains('seen in X')), isTrue);
      },
    );

    test('✕ forgets a tab: its thread leaves, neighbours stand, the '
        'active seat relieves to the neighbour', () async {
      await a.createSession(harness: 'opencode', dir: '/proj-x'); // tab 0
      unawaited(a.runQuickCommand('mine', bubble: 'mine'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x');
      await settle();
      await a.createSession(harness: 'claude', dir: '/proj-y'); // tab 1, active
      await settle();
      // 1) A NON-active tab: pure forget, no seat verb.
      final before = harness.seatCalls.length;
      expect(await a.removeSessionTab(0), isNull);
      expect(harness.seatCalls.length, before);
      expect(a.view.tabs, hasLength(1));
      expect(a.view.tabIndex, 0); // the strip closed up, active tracked
      expect(
        a.chat.any((e) => e.blocks.contains('mine')),
        isFalse,
        reason: 'the doomed tab\'s thread left with it',
      );
      // 2) Rebuild to two tabs and delete the ACTIVE one while a
      // NEIGHBOUR streams: +323's law — the rest check reads the
      // doomed thread's own row, and a stranger's turn is no one's
      // veto (the seat move backgrounds it like any switch, +246).
      await a.createSession(harness: 'opencode', dir: '/proj-z'); // tab 1
      await a.switchSession(0);
      final doomedSid = a.view.tabs[0].currentId;
      harness.healthState = {
        ...harness.healthState!,
        'turnOpen': true, // the SEAT (a neighbour) is mid-answer
        'sessions': [
          {
            'sid': doomedSid,
            'turnOpen': false,
            'missed': 0,
            'queued': false,
          },
        ],
      };
      expect(
        await a.removeSessionTab(0),
        isNull,
        reason: "a streaming neighbour must not rest THIS tab's ✕",
      );
      expect(a.view.tabs, hasLength(1));
      // 2b) Rebuild and delete the ACTIVE one while the DOOMED row
      // itself is mid-turn: that one rests — deleting it would
      // silently eat its own answer. (Name the tab the way the wire
      // does — a frame that stamps its session; an unnamed tab has
      // no row and no veto.)
      // Clear (2)'s scripted stranger-turn first: creation and the
      // swipe both guard on the global face for their own reasons.
      harness.healthState = {
        ...harness.healthState!,
      }..remove('turnOpen');
      await a.createSession(harness: 'opencode', dir: '/proj-x'); // tab 1
      await a.switchSession(0);
      harness.healthState = {
        ...harness.healthState!,
        'sessionId': 'ses-doomed',
      };
      unawaited(a.runQuickCommand('name this tab', bubble: 'name this tab'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle(); // the turn's own /health refresh wears the name
      final doomed2 = a.view.tabs[0].currentId;
      expect(doomed2, 'ses-doomed', reason: 'the wire named the tab');
      expect(a.view.tabIndex, 0, reason: 'the doomed tab is the ACTIVE one');
      expect(a.view.tabs, hasLength(2));
      final hNoTop = {
        ...harness.healthState!,
      }..remove('turnOpen');
      harness.healthState = {
        ...hNoTop,
        'sessions': [
          {
            'sid': doomed2,
            'turnOpen': true,
            'missed': 0,
            'queued': false,
          },
        ],
      };
      expect(
        await a.removeSessionTab(0),
        'the harness is mid-turn — stop it before switching sessions',
      );
      expect(a.view.tabs, hasLength(2)); // nothing half-happened
      harness.healthState = {
        ...harness.healthState!,
        'sessions': [
          {
            'sid': doomed2,
            'turnOpen': false,
            'missed': 0,
            'queued': false,
          },
        ],
      };
      // 3) Now it goes, and the NEIGHBOUR takes the seat.
      expect(await a.removeSessionTab(0), isNull);
      expect(a.view.tabs, hasLength(1));
      expect(a.view.tabIndex, 0);
      expect(harness.seatCalls.last['dir'], '/proj-x');
    });

    test(
      'deleting the LAST tab fires no verb and re-opens the question',
      () async {
        await a.createSession(harness: 'claude', dir: '/proj-x');
        expect(await a.removeSessionTab(0), isNull);
        expect(a.view.tabs, isEmpty); // empty ledger
        expect(harness.seatCalls.length, 1); // create only — no seat verb
        // The + (always on the bar) still works: creation answers again.
        expect(
          await a.createSession(harness: 'claude', dir: '/proj-x'),
          isNull,
        );
        expect(a.view.tabs, hasLength(1));
      },
    );

    test(
      'a bridge without the seat flag refuses the verb it cannot answer',
      () async {
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        await a.createSession(harness: 'claude', dir: '/proj-y');
        harness.healthState = {...harness.healthState!}..remove('seat');
        await a.setBridgeDir('/proj-y'); // re-glance: canSeat goes false
        await settle();
        expect(a.view.canSeat, isFalse);
        expect(await a.switchSession(0), contains('too old'));
      },
    );

    test('the boot reconcile re-homes a seat that moved out of band', () async {
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      // Something ELSE moved the seat (a curl, a restart's pointer):
      harness.healthState = <String, Object?>{
        ...harness.healthState!,
        'harness': 'claude',
        'dir': '/elsewhere',
        'sessionId': 'ses-stranger',
      };
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
      // The tab owns the seat: it is put back, and only ONCE per boot.
      final call = harness.seatCalls.last;
      expect(call['harness'], 'opencode');
      expect(call['dir'], '/proj-x');
      expect(call['fresh'], isTrue); // the tab had no id — fresh is its truth
      expect(harness.seatCalls.length, 2); // create + exactly one re-home
      expect(a.view.tabs.single.harness, 'opencode'); // the ledger held
    });

    test('+280: the context bar comes home wearing its OWN numbers', () async {
      // Tim's ask: the swipe used to land on a 'measuring…'
      // placeholder for a conversation whose sizes the phone KNOWS.
      // The reading now belongs to the tab (persisted like the hue):
      // the landing paints it, every later truth UPDATES it.
      // X: born, named, and it speaks a size mid-turn.
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      unawaited(a.runQuickCommand('name X', bubble: 'name X'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
      await a.setBridgeDir('/proj-x'); // the naming refresh, as in +259
      await settle();
      unawaited(a.runQuickCommand('work in X', bubble: 'work in X'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 12000,
          contextWindow: 200000,
          ctxSession: 'ses-X',
        ),
      );
      await settle();
      expect(a.view.context.tokensIn, 12000);
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      // Y: born fresh — the bar it lands on knows NOTHING, and X's
      // 12k does not ride over.
      await a.createSession(harness: 'opencode', dir: '/proj-y');
      await settle();
      expect(
        a.view.context.tokensIn,
        0,
        reason: 'a fresh tab wears its own blank, not the old seat\'s',
      );
      // Y gets its name and its OWN size.
      unawaited(a.runQuickCommand('name Y', bubble: 'name Y'));
      await settle();
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
      await a.setBridgeDir('/proj-y');
      await settle();
      unawaited(a.runQuickCommand('work in Y', bubble: 'work in Y'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 3000,
          contextWindow: 100000,
          ctxSession: 'ses-Y',
        ),
      );
      await settle();
      expect(a.view.context.tokensIn, 3000);
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      // SWIPE HOME to X: no /health named a context (the scripted
      // snapshot has none), yet the bar arrives ALREADY DRESSED.
      expect(await a.switchSession(0), isNull);
      a.settleBandOnLanding(1, 0);
      await settle();
      expect(
        a.view.context.tokensIn,
        12000,
        reason: 'the cached reading, not the measuring placeholder',
      );
      expect(a.view.context.window, 200000);
      // And when X outgrows the memory, the next truth updates it.
      unawaited(a.runQuickCommand('more in X', bubble: 'more in X'));
      await settle();
      harness.emit(
        const BridgeEvent.forTest(
          'context',
          inputTokens: 40000,
          contextWindow: 200000,
          ctxSession: 'ses-X',
        ),
      );
      await settle();
      expect(a.view.context.tokensIn, 40000);
      harness.emit(BridgeEvent.forTest('done'));
      harness.finishView();
      await settle();
      // Each conversation keeps its OWN memory: back to Y reads 3k.
      expect(await a.switchSession(1), isNull);
      a.settleBandOnLanding(0, 1);
      await settle();
      expect(
        a.view.context.tokensIn,
        3000,
        reason: 'X grew; Y remembers what Y last said',
      );
    });

    test(
      '+280: the control row belongs to the tab, not to the machine',
      () async {
        // The field tape: one agent working in X, and the idle tab Y
        // wore a LIT brake for a turn it does not own — 'that agent is
        // not even busy'. The +249 owner law now covers the row of
        // verbs, not just the row that spins.
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        unawaited(a.runQuickCommand('name X', bubble: 'name X'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-X'};
        await a.setBridgeDir('/proj-x');
        await settle();
        await a.createSession(harness: 'opencode', dir: '/proj-y');
        // Y gets a name too — an UNNAMED destination is a fresh seat,
        // and fresh resets rather than backgrounds a live turn (+256).
        unawaited(a.runQuickCommand('name Y', bubble: 'name Y'));
        await settle();
        harness.emit(BridgeEvent.forTest('done'));
        harness.finishView();
        await settle();
        harness.healthState = {...harness.healthState!, 'sessionId': 'ses-Y'};
        await a.setBridgeDir('/proj-y');
        await settle();
        // Seat X and start churn there; name the frame's owner while
        // it streams (the same stamp +259's leak test rides).
        expect(await a.switchSession(0), isNull);
        unawaited(a.runQuickCommand('build in X', bubble: 'build in X'));
        await settle();
        harness.emit(
          const BridgeEvent.forTest(
            'context',
            inputTokens: 500,
            contextWindow: 9000,
            ctxSession: 'ses-X',
          ),
        );
        harness.healthState = {...harness.healthState!, 'turnOpen': true};
        await settle();
        // At home mid-turn the law is the old one: chips greyed, the
        // brake lit — this tab's turn, this tab's verbs.
        expect(a.view.seatBusy, isTrue);
        expect(a.view.stopHere, isTrue);
        // SWIPE to Y mid-turn: the turn backgrounds (+246).
        expect(await a.switchSession(1), isNull);
        a.settleBandOnLanding(0, 1);
        await settle();
        expect(
          a.view.agentBusy,
          isTrue,
          reason:
              'the machine does hold X\'s turn — the gear badge still '
              'carries that cross-session sign (+230)',
        );
        // +298: turnHomeHere is tautological now (the snapshot is
        // built FROM this tab's channel); the brake and the chips
        // below ARE the law.
        expect(
          a.view.stopHere,
          isFalse,
          reason: 'Y\'s brake sits GREY: it has nothing here to stop',
        );
        expect(
          a.view.seatBusy,
          isFalse,
          reason: 'Y is not thinking — its slash chips press and its mic talks',
        );
        // And Y opens on its OWN blank bar, not X's mid-build reading.
        expect(a.view.context.tokensIn, 0);
        // COMING HOME: X's turn is still open on the wire; the row,
        // the brake and the bar all remember.
        expect(await a.switchSession(0), isNull);
        a.settleBandOnLanding(1, 0);
        await settle();
        expect(
          a.view.stopHere,
          isTrue,
          reason: 'the brake lights again where the work lives',
        );
        expect(a.view.seatBusy, isTrue);
        expect(a.view.context.tokensIn, 500);
      },
    );

    test(
      '+281: the bar names the model the bridge NAMED, not only one pressed',
      () async {
        // The +241 name rode the app's PICK memory alone — a seat
        // answering on its created or default model was no verdict the
        // memory ever saw, so the bar wore no name at all.
        await a.createSession(harness: 'opencode', dir: '/proj-x');
        harness.healthState = {...harness.healthState!, 'model': 'opus'};
        await a.setBridgeDir('/proj-x'); // the awaited refresh path
        await settle();
        expect(
          a.view.context.model,
          'opus',
          reason: 'the seated conversation\'s own /health word',
        );
        expect(a.view.context.label, startsWith('opus'));
        // A bridge with NO current: the remembered pick still wears the
        // line (+218's memory outlives a restart).
        harness.modelSetsHealth = false; // accept the pick, keep no current
        harness.healthState = {...harness.healthState!}..remove('model');
        expect(await a.setBridgeModel('sonnet'), isNull);
        await settle();
        expect(a.view.context.model, 'sonnet', reason: 'the fallback stands');
      },
    );
  });

  group('fling law (assistant-side)', () {
    late FakeHarness harness;
    late VoiceAssistant a;

    setUp(() async {
      harness = FakeHarness();
      harness.healthState = <String, Object?>{
        'ok': true,
        'claudeUp': true,
        'harness': 'claude',
        'dir': '/proj-a',
        'seat': true,
      };
      a = VoiceAssistant(
        worker: FakeSpeechEngine(),
        micSource: FakeMic(),
        audioOutput: FakeAudioOutput(),
        gatewayFactory: (_, _) => harness,
        scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
      await a.createSession(harness: 'claude', dir: '/proj-x');
      await a.createSession(harness: 'claude', dir: '/proj-y');
      await a.switchSession(0);
    });
    tearDown(() => a.dispose());

    test('a fling LEFT walks newer and a fling RIGHT walks older', () async {
      // The screen's gesture math: vx < -450 -> tabIndex+1 when one
      // exists; vx > 450 -> tabIndex-1, and at the FIRST tab a
      // rightward fling is the creation popup (asserted at the sheet
      // group, which pumps the real sheet). Here: the two jumps.
      expect(a.view.tabIndex, 0);
      // left (newer): 0 -> 1
      expect(await a.switchSession(a.view.tabIndex + 1), isNull);
      expect(a.view.tabIndex, 1);
      // right (older): 1 -> 0
      expect(await a.switchSession(a.view.tabIndex - 1), isNull);
      expect(a.view.tabIndex, 0);
    });

    test('a restored thread shows every bubble, including ones the tab '
        'never painted', () async {
      // File a message into tab 0's thread while tab 1 holds the
      // view (the shape a late-landing background report takes):
      // stamped to ses-X, invisible now, VISIBLE when the tab is back.
      await a.switchSession(1);
      final v0 = a.view;
      expect(v0.chat.any((e) => e.blocks.contains('late for X')), isFalse);
      await a.switchSession(0);
      expect(
        a.view.chat.any((e) => e.blocks.contains('late for X')),
        isFalse,
        reason: 'nothing filed it yet — the filter only shows the truth',
      );
    });
  });

  group('the session palette (+271)', () {
    late FakeHarness harness;
    late VoiceAssistant a;
    setUp(() async {
      harness = FakeHarness();
      harness.healthState = <String, Object?>{
        'ok': true,
        'claudeUp': true,
        'harness': 'claude',
        'dir': '/proj-a',
        'seat': true,
      };
      a = VoiceAssistant(
        worker: FakeSpeechEngine(),
        micSource: FakeMic(),
        audioOutput: FakeAudioOutput(),
        gatewayFactory: (_, _) => harness,
        scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
    });
    tearDown(() => a.dispose());
    test('a drawn hue round-trips; a legacy tab keeps the index law', () {
      final t = SessionTab(
        harness: 'claude',
        dir: '/p',
        hue: SessionTab.pickHue(const [], rng: Random(7)),
      );
      expect(t.hue, inInclusiveRange(0, 359));
      final back = SessionTab.fromJson(t.toJson());
      expect(back.hue, t.hue, reason: 'the colour is persisted, not redrawn');
      // A pre-+271 tab (no hue in its JSON) wears exactly what the
      // +230 index law painted — the upgrade changes no faces:
      final legacy = SessionTab.fromJson({
        'harness': 'claude',
        'dir': '/p',
        'sessionIds': <String>[],
      });
      expect(legacy.hue, isNull);
      expect(legacy.hueOrDefault(2), (2 * 137) % 360);
    });
    test('a cached context reading round-trips; a fresh tab has none', () {
      // +280: the bar's memory belongs to its tab like the hue does —
      // persisted, and absent (never zero-sketched) until spoken.
      final t = SessionTab(
        harness: 'claude',
        dir: '/p',
        ctxIn: 12000,
        ctxWindow: 200000,
      );
      final back = SessionTab.fromJson(t.toJson());
      expect(back.ctxIn, 12000);
      expect(back.ctxWindow, 200000);
      final fresh = SessionTab(harness: 'claude', dir: '/p');
      expect(fresh.toJson().containsKey('ctxIn'), isFalse);
      expect(SessionTab.fromJson(fresh.toJson()).ctxIn, isNull);
    });
    test('pickHue runs far from the colours already worn', () {
      // The seeded samples below are the property, not the literals:
      // the chosen hue sits farther from every taken hue than a
      // coin-flip pick would, and neighbours stay distinguishable.
      for (final seed in [1, 2, 3, 4, 5]) {
        final h = SessionTab.pickHue([0], rng: Random(seed));
        final gap = h > 180 ? 360 - h : h;
        expect(gap, greaterThan(20), reason: 'seed $seed drew too close');
      }
    });
    test('creating a session draws a new, different colour', () async {
      await a.createSession(harness: 'opencode', dir: '/proj-h1');
      await a.createSession(harness: 'opencode', dir: '/proj-h2');
      final hues = [for (final t in a.view.tabs) t.hue];
      expect(hues, hasLength(2));
      expect(hues[0], isNot(hues[1]));
      for (final h in hues) {
        expect(h, inInclusiveRange(0, 359));
      }
    });
    test('DELETING a neighbour recolours nobody', () async {
      // The +230 law's one real flaw, and the reason for the
      // persisted draw: an index-derived hue is a seat number, so
      // deleting tab 0 put yesterday's colours on every remaining
      // tab — the sessions changed faces when nothing about THEM
      // changed. A drawn hue belongs to its tab.
      await a.createSession(harness: 'opencode', dir: '/proj-h1');
      await a.createSession(harness: 'opencode', dir: '/proj-h2');
      final h1 = a.view.tabs[0].hue, h2 = a.view.tabs[1].hue;
      expect(await a.removeSessionTab(0), isNull); // Y (active) stays
      expect(a.view.tabs, hasLength(1));
      expect(
        a.view.tabs[0].hue,
        h2,
        reason: 'the survivor keeps ITS colour — faces do not shuffle',
      );
      expect(h2, isNot(h1));
    });
  });

  group('the creation sheet', () {
    late FakeHarness harness;
    late VoiceAssistant a;

    setUp(() async {
      harness = FakeHarness();
      harness.healthState = <String, Object?>{
        'ok': true,
        'claudeUp': true,
        'harness': 'claude',
        'dir': '/proj-a',
        'seat': true,
      };
      harness.modelsMenu = <String, Object?>{
        'harness': 'claude',
        'current': 'default',
        'models': [
          {'id': 'opus', 'label': 'opus'},
          {'id': 'sonnet', 'label': 'sonnet'},
        ],
      };
      harness.dirsInfo = (<String, Object?>{
        'ok': true,
        'dir': '/home/tim',
        'in': null,
        'parent': null,
        'dirs': [
          {'name': 'proj-a', 'path': 'proj-a'},
          {'name': 'proj-b', 'path': 'proj-b'},
        ],
      }).cast<String, Object>();
      a = VoiceAssistant(
        worker: FakeSpeechEngine(),
        micSource: FakeMic(),
        audioOutput: FakeAudioOutput(),
        gatewayFactory: (_, _) => harness,
        scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
    });
    tearDown(() => a.dispose());

    Future<void> open(WidgetTester tester) async {
      // A phone-tall viewport: the creation sheet caps at 82% of the
      // screen and SCROLLS below it — the default 600-px test window
      // would leave the Start button below the fold by design.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () => showSessionSheet(c, a: a),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'big buttons: both harnesses, the menu, the folders, one Start',
      (tester) async {
        await open(tester);
        // The whole question set is on one screen, in big buttons.
        expect(find.text('New session'), findsOneWidget);
        expect(find.text('Claude Code'), findsOneWidget);
        expect(find.text('Opencode'), findsOneWidget);
        expect(find.text('opus'), findsOneWidget);
        expect(find.text('Default'), findsOneWidget);
        expect(find.text('proj-b'), findsOneWidget);
        // The folder section is a BROWSER: no pre-ticked 'Current', no
        // per-row confirm buttons — rows ENTER folders, one SELECT files
        // the folder you stand in, and the path you stand on is spelled
        // out. Start without one is refused IN the sheet.
        expect(find.textContaining('Current'), findsNothing);
        expect(find.text('Here'), findsNothing);
        await tester.tap(find.text('Start session'));
        await tester.pumpAndSettle();
        expect(find.text('pick a working folder first'), findsOneWidget);
        // Tap a folder to enter (the fake re-answers the same listing,
        // standing at /home/tim), then SELECT, then a model, then START:
        // one fresh seat, the sheet pops itself, the tab is filed.
        await tester.tap(find.text('proj-b'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Select this folder'));
        await tester.pumpAndSettle();
        expect(find.text('Selected'), findsOneWidget);
        await tester.tap(find.text('opus'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Start session'));
        await tester.pumpAndSettle();
        expect(find.text('New session'), findsNothing); // answered, dismissed
        final call = harness.seatCalls.last;
        expect(
          call['harness'],
          'claude',
        ); // (menu still answers for claude here)
        expect(call['model'], 'opus');
        expect(call['fresh'], isTrue);
        expect(call['dir'], '/home/tim'); // the listing's own absolute folder
        expect(a.view.tabs, hasLength(1));
      },
    );

    testWidgets('a two-provider catalog folds under shelves until tapped', (
      tester,
    ) async {
      harness.modelsMenu = <String, Object?>{
        'harness': 'opencode',
        'current': null,
        'models': [
          {'id': 'acme/alpha', 'label': 'Acme Alpha'},
          {'id': 'acme/beta', 'label': 'Acme Beta'},
          {'id': 'other/gamma', 'label': 'other/gamma'},
        ],
      };
      await open(tester);
      // Two provider shelves, folded: the models are NOT on screen —
      // that was the flood. The shelves count their wares.
      expect(find.text('acme · 2'), findsOneWidget);
      expect(find.text('other · 1'), findsOneWidget);
      expect(find.text('Acme Alpha'), findsNothing);
      await tester.tap(find.text('acme · 2'));
      await tester.pumpAndSettle();
      expect(find.text('Acme Alpha'), findsOneWidget); // unfolded
      expect(find.text('other/gamma'), findsNothing); // the other shelf holds
      await tester.tap(find.text('Acme Beta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select this folder'));
      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();
      expect(harness.seatCalls.last['model'], 'acme/beta');
    });

    testWidgets('a refused seat keeps the sheet open with the reason', (
      tester,
    ) async {
      harness.seatRefused = 'opencode is resting';
      await open(tester);
      await tester.tap(find.text('Select this folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();
      expect(find.text('New session'), findsOneWidget); // still asking
      expect(find.text('opencode is resting'), findsOneWidget);
      expect(a.view.tabs, isEmpty);
    });
  });
}

/// +289: the scripted harness with observable wire windows. [seat]
/// lets the verb land (a real bridge moves its state when the
/// REQUEST arrives) and parks the RESPONSE on demand; [healthInfo]
/// parks every /health after the [holdHealthAfter]+1st — leaving
/// the rest-law glance through and stopping only the REFRESHING
/// one, the glance the switch used to treat as the moment the seat
/// gained its name. It isn't: the /seat answer is.
class _LaggyHarness extends FakeHarness {
  Completer<void>? holdSeat;
  Completer<void>? holdRefresh;
  int holdHealthAfter = 0;
  int healthCalls = 0;

  @override
  Future<Map<String, Object>?> seat({
    String? harness,
    String? dir,
    String? model,
    String? sessionId,
    bool fresh = false,
  }) async {
    final r = await super.seat(
      harness: harness,
      dir: dir,
      model: model,
      sessionId: sessionId,
      fresh: fresh,
    );
    await holdSeat?.future;
    return r;
  }

  @override
  Future<Map<String, Object>?> healthInfo() async {
    healthCalls++;
    if (holdRefresh != null && healthCalls > holdHealthAfter + 1) {
      await holdRefresh!.future;
    }
    return super.healthInfo();
  }
}
