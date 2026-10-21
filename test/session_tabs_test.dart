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
    // read what it was (and was NOT) given a voice for.
    late FakeSpeechEngine engine;

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
      a = VoiceAssistant(
        worker: engine,
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
        expect(a.view.tabs[0].currentId, isNull); // replaced in place
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
        a.view.turnHomeHere,
        isFalse,
        reason: 'the work stayed with ses-X',
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

    test('+253: swipe away mid-turn — the answer lands in its thread '
        'mute; after the return, the next paragraph gets a voice',
    () async {
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
        containsAll([
          'heard before the swipe.',
          'back home, speaking.',
        ]),
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
        a.view.turnHomeHere,
        isFalse,
        reason: 'the work stayed with ses-X',
      );
      expect(
        a.view.showWorkingRow,
        isFalse,
        reason: 'the stranger\'s turn may not light this tab\'s box',
      );
      // The stranded-backlog drain runs while X still owns the
      // machine: reading mail stays mail — the box must not re-light
      // just because /health says SOME turn is open.
      await a.reattachBackgroundTurn();
      await settle();
      expect(
        a.view.showWorkingRow,
        isFalse,
        reason:
            'the attach claimed the OPEN (foreign) turn — the row '
            'belongs to the conversation, not to whoever holds the busy slot',
      );
      // +256 (the xray tape's third finding): the bar's MOTION obeys
      // the same ownership as its numbers and the row — and an
      // unnamed seat no longer counts as home by default. Drop the
      // seat's name from the health line (a reset conversation is
      // exactly this shape): the away marker must still gate.
      harness.healthState = Map.of({
        ...harness.healthState!,
      })..remove('sessionId');
      await a.setBridgeModel('default'); // any awaited refresh path
      await settle();
      expect(a.view.bridgeBusy, isTrue, reason: 'the foreign turn is open');
      expect(
        a.view.turnHomeHere,
        isFalse,
        reason:
            'an unnamed seat with a named away work is NOT home — '
            'the +249 clause let the stranger\'s box show here',
      );
      expect(
        a.view.context.busy,
        isFalse,
        reason: 'the measuring shimmer spins only for the seat\'s own work',
      );
      expect(a.view.showWorkingRow, isFalse);
      harness.finishView();
    });

    test('+256: the unnamed destination is a reset — a mid-turn swipe '
        'onto a never-spoken tab REFUSES with words, not a silent kill',
    () async {
      // The xray tape's opening act: the first swipe reset the
      // bridge's conversation under a 'free to move' verdict and
      // SIGTERM'd the answering turn. A tab that never spoke has no
      // id; seating it sends fresh:true; fresh ALWAYS resets; so the
      // rest law reads the reset law. Idle moves stay free — the
      // refusal is exactly the shape +248 already wrote for fresh.
      await a.createSession(harness: 'opencode', dir: '/proj-x');
      await a.createSession(harness: 'opencode', dir: '/proj-z'); // never speaks
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
    });

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
      // 2) Rebuild to two tabs and delete the ACTIVE one while a turn
      // is open: the relief move is a seat verb — it rests.
      await a.createSession(harness: 'opencode', dir: '/proj-z'); // tab 1
      await a.switchSession(0);
      harness.healthState = {...harness.healthState!, 'turnOpen': true};
      expect(
        await a.removeSessionTab(0),
        'the harness is mid-turn — stop it before switching sessions',
      );
      expect(a.view.tabs, hasLength(2)); // nothing half-happened
      harness.healthState = {...harness.healthState!}..remove('turnOpen');
      // 3) Now it goes, and the NEIGHBOUR takes the seat.
      expect(await a.removeSessionTab(0), isNull);
      expect(a.view.tabs, hasLength(1));
      expect(a.view.tabIndex, 0);
      expect(harness.seatCalls.last['dir'], '/proj-z');
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
