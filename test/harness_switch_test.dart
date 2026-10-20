// The harness switch (+211): the Bridge screen's row that flips the
// bridge between claude and opencode (POST /harness). Three layers,
// each proven the way its kind is proven here: the CLIENT half walks a
// stub server speaking the bridge's contract (folder_picker_test's
// doctrine — the wire side is pinned by tool/bridge_oc_test.mjs), the
// ASSISTANT half walks setBridgeHarness against the scripted gateway,
// and the SCREEN half pumps the real widget: the row renders /health,
// the switch aims at the OTHER harness, an open turn parks it, and a
// pre-switch bridge shows a dead one.
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
import 'package:voice_agent/src/ui/bridge_screen.dart';

import 'support/fakes.dart';

Future<void> settle({int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('client /harness', () {
    late HttpServer server;
    late BridgeClient client;
    final seen = <String>[];
    String? replyBody;

    // The widget tests in this suite initialise the Flutter binding, and
    // the binding swaps HttpClient for a 400-always stub. The client
    // group takes that override off for the call and puts it straight
    // back (HttpOverrides.global is write-only, so the widget tests —
    // which never dial HTTP — leave it null and stay honest anyway).
    Future<String?> flip(String to) {
      HttpOverrides.global = null;
      return client.setHarness(to);
    }

    setUp(() async {
      seen.clear();
      replyBody = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = BridgeClient('http://127.0.0.1:${server.port}', 'tok');
      server.listen((req) async {
        seen.add('${req.method} ${req.uri}');
        if (req.uri.path == '/harness') {
          final body =
              jsonDecode(await utf8.decodeStream(req)) as Map<String, Object?>;
          if (replyBody != null) {
            req.response.write(replyBody); // the flipped-to name
          } else if (body['to'] != 'claude' && body['to'] != 'opencode') {
            req.response.statusCode = HttpStatus.badRequest;
            req.response.write('to=claude|opencode\n'); // the bridge's own 400
          } else {
            req.response.write('{"ok":true,"harness":"${body['to']}"}');
          }
        }
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('the flip rides the token and names its target', () async {
      expect(await flip('opencode'), isNull);
      expect(seen.single, contains('token=tok'));
      expect(seen.single, startsWith('POST /harness'));
      expect(await flip('claude'), isNull);
    });

    test('a refused to answers with the bridge\u2019s honest line', () async {
      final why = await flip('pi');
      expect(why, contains('to=claude'));
      expect(why, isNot(contains('HTTP'))); // the body beat the bare code
    });

    test('an unreachable bridge is a reason, not a throw', () async {
      await server.close(force: true);
      expect(await flip('claude'), isNotNull);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      await server.close(); // keep tearDown's close a no-op
    });
  });

  group('assistant', () {
    late FakeHarness harness;
    late VoiceAssistant a;

    setUp(() {
      harness = FakeHarness();
      a = VoiceAssistant(
        worker: FakeSpeechEngine(),
        micSource: FakeMic(),
        audioOutput: FakeAudioOutput(),
        gatewayFactory: (_, _) => harness,
        scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
    });

    tearDown(() => a.dispose());

    test('with no bridge configured there is nothing to switch', () async {
      expect(await a.setBridgeHarness('opencode'), 'bridge not configured');
      expect(harness.harnessSwitches, isEmpty);
    });

    test('the flip travels and its reason travels back', () async {
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
      expect(await a.setBridgeHarness('claude'), isNull);
      expect(harness.harnessSwitches, ['claude']);
      harness.setHarnessError = 'to=claude|opencode';
      expect(await a.setBridgeHarness('pi'), 'to=claude|opencode');
    });
  });

  group('BridgeScreen harness row', () {
    late FakeHarness harness;
    late VoiceAssistant a;

    setUp(() {
      harness = FakeHarness();
      a = VoiceAssistant(
        worker: FakeSpeechEngine(),
        micSource: FakeMic(),
        audioOutput: FakeAudioOutput(),
        gatewayFactory: (_, _) => harness,
        scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
    });

    tearDown(() => a.dispose());

    Future<void> openScreen(WidgetTester tester) async {
      // testWidgets runs on a fake clock: microtasks flush through
      // pump(), and settle()'s Future.delayed would wait on a timer
      // nothing advances — so the widget group pumps, plainly.
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await tester.pump();
      await tester.pumpWidget(MaterialApp(home: BridgeScreen(assistant: a)));
      await tester.pump(); // initState's /health fetch
      await tester.pump();
    }

    testWidgets('opencode on the wire, and the switch aims at claude',
        (tester) async {
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'opencode',
        'dir': '/home/tim/voice-agent', 'sessionId': 'ses_oc',
      };
      await openScreen(tester);
      expect(find.text('OpenCode'), findsOneWidget);
      final swap = find.widgetWithIcon(IconButton, Icons.swap_horiz);
      expect(tester.widget<IconButton>(swap).onPressed, isNotNull);
      await tester.tap(swap);
      expect(harness.harnessSwitches, ['claude']);
      // The row is /health's truth: had the bridge come back claude, so
      // would the label (the fake keeps opencode; refresh must not
      // crash the walk).
      await tester.pump();
      expect(find.text('OpenCode'), findsOneWidget);
    });

    testWidgets('a live turn parks the switch', (tester) async {
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', 'sessionId': 'ses_cl', 'turnOpen': true,
      };
      await openScreen(tester);
      expect(find.text('Claude Code'), findsOneWidget);
      // An open turn (any listener's — /health turnOpen is the seat's
      // truth) means a switch would murder live work: park the flip
      // until the seat is free.
      final swap = find.widgetWithIcon(IconButton, Icons.swap_horiz);
      expect(tester.widget<IconButton>(swap).onPressed, isNull);
    });

    testWidgets('a pre-switch bridge shows a dead switch', (tester) async {
      harness.healthState = {
        'ok': true, 'claudeUp': true,
        'dir': '/x', 'sessionId': 'ses_old', // no harness field at all
      };
      await openScreen(tester);
      expect(find.textContaining('too old to switch'), findsOneWidget);
      final swap = find.widgetWithIcon(IconButton, Icons.swap_horiz);
      expect(tester.widget<IconButton>(swap).onPressed, isNull);
    });
  });

  group('chat split', () {
    late FakeHarness harness;
    late VoiceAssistant a;

    setUp(() {
      harness = FakeHarness();
      a = VoiceAssistant(
        worker: FakeSpeechEngine(),
        micSource: FakeMic(),
        audioOutput: FakeAudioOutput(),
        gatewayFactory: (_, _) => harness,
        scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
    });

    tearDown(() => a.dispose());

    test('every ChatStore mutator stamps the era the provider reports', () {
      final store = ChatStore(
        persist: (_) async {},
        repaint: () {},
        harness: () => 'opencode',
      );
      store.addUser('hello');
      store.addUserTranscribing();
      store.addSystemNote('note');
      store.addFile(name: 'x', path: '/tmp/x', size: 1);
      store.beginTurn();
      expect(store.entries, hasLength(5),
          reason: 'five mutators, five entries');
      expect(
        store.entries.map((e) => e.harness),
        everyElement('opencode'),
        reason: 'EVERY birth stamps the era — one missed mutator is a '
            'bubble invisible under exactly one harness',
      );
      // A bridge with no switch answer (null provider): every entry is
      // un-era, and un-era means SHARED — the row's whole point is
      // those bubbles show under every thread.
      final legacy = ChatStore(
        persist: (_) async {}, repaint: () {}, harness: () => null,
      );
      legacy.addUser('un-era\u2019d');
      expect(legacy.entries.single.harness, isNull);
    });

    test('the era round-trips through disk; a legacy line decodes un-era',
        () async {
      final store = ChatStore(
        persist: (_) async {},
        repaint: () {},
        harness: () => 'claude',
      );
      store.addUser('under claude');
      final back = ChatEntry.fromJson(store.entries.single.toJson());
      expect(back.harness, 'claude');
      // A pre-split JSON line carries no 'h' — it must decode un-era
      // (shared), not as any particular era.
      final legacy = ChatEntry.fromJson({'user': true, 'blocks': ['old']});
      expect(legacy.harness, isNull);
      expect(ChatEntry.user('x').toJson().containsKey('h'), isFalse);
    });

    test('+214 migration: legacy bubbles take their era from the bridge\u2019s '
        'timeline, once, and never from a returning guess', () async {
      // The store-level law first: each birth lands between timeline
      // lines, so each gets the era that line opened. A wound clock
      // places the births; the entries keep their stamps final.
      var clock = 0;
      // harness: null — these births replay the PRE-SPLIT app: no era
      // known, so every entry lands un-era and the migration is the
      // first thing to name one.
      final store = ChatStore(
        persist: (_) async {}, repaint: () {}, harness: () => null,
        nowMs: () => clock,
      );
      store.addUser('prehistory'); // born 0 = older than the record
      clock = 2000; // born while opencode held the pen
      store.beginTurn();
      clock = 3500; // born after the flip back to claude
      store.addSystemNote('x');
      final n = store.migrateUnera('opencode', timeline: const [
        (since: 1000, harness: 'opencode'),
        (since: 3000, harness: 'claude'),
      ]);
      expect(n, 3);
      expect(store.entries.map((e) => e.harness),
          ['opencode', 'opencode', 'claude']);
      // A bridge with no timeline (pre-+214): every legacy bubble
      // wears the fallback — the observed era, the best witness left.
      final bare = ChatStore(
        persist: (_) async {}, repaint: () {}, harness: () => null,
      );
      bare.addUser('legacy');
      expect(bare.migrateUnera('claude'), 1);
      expect(bare.entries.single.harness, 'claude');
    });

    test('the migration fires once: a later un-era bubble keeps its null',
        () async {
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', 'sessionId': 'ses_cl',
        'harnessHistory': [
          {'since': 1, 'harness': 'opencode'},
          {'since': 5000, 'harness': 'claude'},
        ],
      };
      a.chat.add(ChatEntry.user('born before the split', createdMs: 2000));
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
      // The first era glance migrated the past: the legacy bubble is
      // opencode's now (it was born between the lines), hidden from
      // the claude thread it used to clutter.
      expect(a.chat.single.harness, 'opencode');
      expect(a.view.chat, isEmpty,
          reason: 'the claude thread no longer wears opencode\u2019s history');
      // A bubble made un-era LATER (bridge torn down → offline
      // prologue) must NOT be re-stamped by the flag-guarded
      // migration: the flag is spent, the prologue stays shared.
      a.chat.add(ChatEntry.user('later offline turn', createdMs: 9000));
      await a.setBridgeHarness('opencode');
      harness.healthState = {
        ...harness.healthState!, 'harness': 'opencode',
      };
      await a.setBridgeHarness('claude');
      await settle();
      final offline = a.chat.firstWhere(
          (e) => e.blocks.contains('later offline turn'));
      expect(offline.harness, isNull,
          reason: 'the migration flag is spent: the shared prologue '
              'stays shared, never re-stamped by a returning guess');
    });

    test('flipping harnesses splits the transcript and keeps the log', () async {
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', 'sessionId': 'ses_cl',
      };
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
      // A shared prologue (a legacy/pre-split line): null = every thread.
      a.chat.add(ChatEntry.user('the shared prologue', createdMs: 1));
      // One Claude turn: a user bubble + its assistant reply block.
      // The send rides an open view until the fake closes it — the
      // turn-flow tests' dance, not an await-through-done.
      unawaited(a.runQuickCommand('claude only', bubble: 'claude only'));
      await settle();
      harness.finishView();
      await settle();
      expect(
        a.view.chat.where((e) => e.blocks.contains('claude only')),
        hasLength(1),
        reason: 'the claude-era bubble is not on the claude thread',
      );

      // The real bridge's /health names the new era the instant
      // /harness answers — the fake moves its answer along too.
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'opencode',
        'dir': '/x', 'sessionId': 'ses_oc',
      };
      await a.setBridgeHarness('opencode');
      await settle();
      // A real opencode turn, so the thread has something of ITS OWN
      // (a flip files nothing — the thread's content is conversations,
      // not announcements).
      unawaited(a.runQuickCommand('opencode only', bubble: 'opencode only'));
      await settle();
      harness.finishView();
      await settle();
      // The log keeps EVERYTHING — the split is render-side only.
      expect(
        a.chat.map((e) => e.harness),
        containsAll(<String?>[null, 'claude', 'opencode']),
      );
      // The thread is the flip's whole statement: prologue and this
      // era's turn in, the other era's bubbles out, no narration
      // filed (+215 — the signpost bubble explained a fact the screen
      // already showed and repeated itself every flip).
      final onThread = a.view.chat.map((e) => e.blocks.join(' ')).join();
      expect(onThread, contains('the shared prologue'));
      expect(onThread, contains('opencode only'));
      expect(onThread, isNot(contains('claude only')));
      expect(onThread, isNot(contains('holds the pen')),
          reason: 'the flip files no signpost bubble');

      // Flip BACK: the claude-era bubbles were never gone — they were
      // only on the other thread.
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', 'sessionId': 'ses_cl',
      };
      await a.setBridgeHarness('claude');
      await settle();
      final back = a.view.chat.map((e) => e.blocks.join(' ')).join();
      expect(back, contains('claude only'));
      expect(back, isNot(contains('opencode only')));
      expect(back, isNot(contains('holds the pen')));
    });
  });

  modelPickerTests();
}

// ── +216: the model picker, phone side ───────────────────────────────
void modelPickerTests() {
  group('model picker client /models + /model', () {
    late HttpServer server;
    late BridgeClient client;
    final seen = <String>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = BridgeClient('http://127.0.0.1:${server.port}', 'tok');
      server.listen((req) async {
        seen.add('${req.method} ${req.uri}');
        if (req.uri.path == '/models') {
          req.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'ok': true,
              'harness': 'claude',
              'current': 'opus',
              'models': [
                {'id': 'default', 'label': 'default'},
                {'id': 'opus', 'label': 'opus'},
              ],
            }));
        } else if (req.uri.path == '/model') {
          final body =
              jsonDecode(await utf8.decodeStream(req)) as Map<String, Object?>;
          if (body['id'] == 'pi') {
            req.response.statusCode = HttpStatus.badRequest;
            req.response.write('could not set the model: not in --models: pi');
          } else {
            req.response.write('{"ok":true,"id":"${body['id']}"}');
          }
        }
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('the menu rides the token and arrives parsed', () async {
      final m = await client.models();
      expect(m, isNotNull);
      expect(m!['current'], 'opus');
      expect((m['models'] as List).length, 2);
      expect(seen.single, startsWith('GET /models'));
      expect(seen.single, contains('token=tok'));
    });

    test('a pick answers null; an off-menu id answers the honest reason',
        () async {
      expect(await client.setModel('opus'), isNull);
      final why = await client.setModel('pi');
      expect(why, contains('not in --models'));
    });

    test('+218 prefs: the lastModels map round-trips; legacy json starts '
        'empty', () {
      final p = BridgePrefs()..lastModels = {'claude': 'opus'};
      final back = BridgePrefs.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back.lastModels, {'claude': 'opus'});
      expect(BridgePrefs.fromJson({}).lastModels, isEmpty);
    });

    test('an unreachable bridge is a null menu and a reason for picks',
        () async {
      await server.close(force: true);
      expect(await client.models(), isNull);
      expect(await client.setModel('opus'), isNotNull);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      await server.close(); // keep tearDown's close a no-op
    });
  });

  group('assistant model methods', () {
    late FakeHarness harness;
    late VoiceAssistant a;

    setUp(() {
      harness = FakeHarness();
      a = VoiceAssistant(
        worker: FakeSpeechEngine(),
        micSource: FakeMic(),
        audioOutput: FakeAudioOutput(),
        gatewayFactory: (_, _) => harness,
        scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
    });

    tearDown(() => a.dispose());

    test('no bridge configured: no menu, and the pick says so', () async {
      expect(await a.bridgeModels(), isNull);
      expect(await a.setBridgeModel('opus'), 'bridge not configured');
    });

    test('a pick lands and the row label is the truth on return', () async {
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', 'model': 'default',
      };
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
      expect(await a.setBridgeModel('opus'), isNull);
      expect(harness.modelPicks, ['opus']);
      // setBridgeModel AWAITED its /health re-read: the screen's next
      // paint already wears the new model, no refresh lag to explain.
      expect((await a.bridgeHealth())!['model'], 'opus');
      // A refused pick keeps the label honest (nothing moved).
      harness.setModelError = 'not in --models: pi';
      expect(await a.setBridgeModel('pi'), contains('not in --models'));
      expect((await a.bridgeHealth())!['model'], 'opus');
      expect(a.bridgeLastModel, 'opus',
          reason: 'a REFUSED pick does not rewrite the memory');
    });

    test('+218 memory is per era: claude remembers its alias, opencode '
        'its provider path', () async {
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', 'model': 'default',
      };
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await settle();
      await a.setBridgeModel('opus');
      expect(a.bridgeLastModel, 'opus');
      // Flip eras: the opencode thread has NO memory yet — last
      // time's claude alias must not haunt it as a suggestion.
      harness.healthState = <String, Object?>{
        ...harness.healthState!, 'harness': 'opencode', 'model': null,
      };
      await a.setBridgeHarness('opencode');
      await settle();
      expect(a.bridgeLastModel, isNull);
      await a.setBridgeModel('acme/beta');
      expect(a.bridgeLastModel, 'acme/beta');
      // Flip BACK: the claude memory is where it was left.
      harness.healthState = {
        ...harness.healthState!, 'harness': 'claude',
      };
      await a.setBridgeHarness('claude');
      await settle();
      expect(a.bridgeLastModel, 'opus');
    });
  });

  group('BridgeScreen model row', () {
    late FakeHarness harness;
    late VoiceAssistant a;

    setUp(() {
      harness = FakeHarness();
      a = VoiceAssistant(
        worker: FakeSpeechEngine(),
        micSource: FakeMic(),
        audioOutput: FakeAudioOutput(),
        gatewayFactory: (_, _) => harness,
        scheduler: FakeScheduler(DateTime(2026, 1, 1, 12)),
        clock: () => DateTime(2026, 1, 1, 12),
      );
    });

    tearDown(() => a.dispose());

    Future<void> openScreen(WidgetTester tester) async {
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await tester.pump();
      await tester.pumpWidget(MaterialApp(home: BridgeScreen(assistant: a)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the row shows the current; the sheet lists the menu '
        'and a pick travels POST /model', (tester) async {
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', 'model': 'default',
      };
      harness.modelsMenu = {
        'ok': true, 'harness': 'claude', 'current': 'default',
        'models': [
          {'id': 'default', 'label': 'default'},
          {'id': 'opus', 'label': 'opus'},
          {'id': 'acme/beta', 'label': 'Acme Beta'},
        ],
      };
      await openScreen(tester);
      expect(find.text('default'), findsWidgets); // the row's label
      final tune = find.widgetWithIcon(IconButton, Icons.tune);
      expect(tester.widget<IconButton>(tune).onPressed, isNotNull);
      await tester.tap(tune);
      await tester.pumpAndSettle();
      // The sheet: the menu, current checked, labels and ids honest.
      expect(find.text('Acme Beta'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget); // on 'default'
      await tester.tap(find.text('Acme Beta'));
      await tester.pumpAndSettle();
      expect(harness.modelPicks, ['acme/beta']);
      await tester.pump(); // the row re-reads /health after the pick
      expect(find.text('acme/beta'), findsWidgets); // row wears the pick
    });

    testWidgets('a pre-+216 bridge: the label admits it, the switch is dead',
        (tester) async {
      harness.healthState = {
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', // NO 'model' field at all
      };
      await openScreen(tester);
      expect(find.textContaining('too old for /model'), findsOneWidget);
      final tune = find.widgetWithIcon(IconButton, Icons.tune);
      expect(tester.widget<IconButton>(tune).onPressed, isNull);
    });
 
    testWidgets('+218: an amnesiac bridge shows the remembered pick — '
        'row and sheet both', (tester) async {
      harness.healthState = <String, Object?>{
        'ok': true, 'claudeUp': true, 'harness': 'claude',
        'dir': '/x', 'model': null, // the bridge has no current
      };
      harness.modelSetsHealth = false; // accepts picks, forgets on restart
      harness.modelsMenu = <String, Object?>{
        'ok': true, 'harness': 'claude', 'current': null,
        'models': [
          {'id': 'default', 'label': 'default'},
          {'id': 'opus', 'label': 'opus'},
          {'id': 'acme/beta', 'label': 'Acme Beta'},
          {'id': 'acme/gamma', 'label': 'Acme Gamma'},
          {'id': 'other/delta', 'label': 'Other Delta'},
        ],
      };
      await a.setBridge(url: 'http://harness.test', token: 'tok');
      await tester.pump();
      await a.setBridgeModel('acme/beta'); // the memory is filed
      // A fresh screen state re-reads /health: model null, but the
      // app remembers — the row wears it labelled as memory, not truth.
      await tester.pumpWidget(
        MaterialApp(home: BridgeScreen(key: UniqueKey(), assistant: a)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('acme/beta (last used)'), findsOneWidget);
      final tune = find.widgetWithIcon(IconButton, Icons.tune);
      await tester.tap(tune);
      await tester.pumpAndSettle();
      // Hierarchical now (acme + other): the provider shelf holding
      // the remembered model wears the HISTORY glyph, and the sheet's
      // caption says 'last used', not 'current'.
      expect(find.text('last used: acme/beta'), findsOneWidget);
      expect(find.byIcon(Icons.history), findsOneWidget); // on 'acme'
      await tester.tap(find.text('acme'));
      await tester.pumpAndSettle();
      // Inside the shelf, the remembered model keeps the history mark.
      expect(find.widgetWithIcon(ListTile, Icons.history), findsOneWidget);
      await tester.tap(find.text('Acme Gamma'));
      await tester.pumpAndSettle();
      expect(harness.modelPicks.last, 'acme/gamma');
    });
  });
}
