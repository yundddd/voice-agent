// The harness switch (+211): the Bridge screen's row that flips the
// bridge between claude and opencode (POST /harness). Three layers,
// each proven the way its kind is proven here: the CLIENT half walks a
// stub server speaking the bridge's contract (folder_picker_test's
// doctrine — the wire side is pinned by tool/bridge_oc_test.mjs), the
// ASSISTANT half walks setBridgeHarness against the scripted gateway,
// and the SCREEN half pumps the real widget: the row renders /health,
// the switch aims at the OTHER harness, an open turn parks it, and a
// pre-switch bridge shows a dead one.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/assistant.dart';
import 'package:voice_agent/src/bridge/client.dart';
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
}
