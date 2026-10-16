import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/bridge.dart';

Future<List<BridgeEvent>> parse(List<String> lines) =>
    bridgeEventsFromLines(Stream.fromIterable(lines)).toList();

void main() {
  group('SSE parser', () {
    test('frames: say, tool, done in order with payloads', () async {
      final evs = await parse([
        'event: say',
        'data: {"text":"hello from claude"}',
        '',
        'event: tool',
        'data: {"name":"Bash","detail":"flutter test"}',
        '',
        'event: done',
        'data: {"isError":false}',
        '',
      ]);
      expect(evs.map((e) => e.kind).toList(), ['say', 'tool', 'done']);
      expect(evs[0].text, 'hello from claude');
      expect(evs[1].toolName, 'Bash');
      expect(evs[1].detail, 'flutter test');
      expect(evs[2].isDone && !evs[2].isError, isTrue);
    });

    test('comments ignored, final frame flushed without blank line', () async {
      final evs = await parse([
        ': keep-alive',
        'event: say',
        'data: {"text":"tail without newline"}',
      ]);
      expect(evs.length, 1);
      expect(evs[0].text, 'tail without newline');
    });

    test('CRLF lines and multi-line data decode as one json', () async {
      final evs = await parse([
        'event: say\r',
        'data: {"text":\r',
        'data: "joined"}\r',
        '\r',
      ]);
      expect(evs.single.text, 'joined');
    });

    test(
      'non-JSON say data passes through as text; other events are errors',
      () async {
        final evs = await parse([
          'event: say',
          'data: plain text line',
          '',
          'event: whatever',
          'data: {"error":"boom"}',
          '',
        ]);
        expect(evs[0].kind, 'say');
        expect(evs[0].text, 'plain text line');
        expect(evs[1].kind, 'error');
        expect(evs[1].text, 'boom');
        expect(evs[1].isError, isTrue);
      },
    );

    test('done with isError surfaces the failure flag', () async {
      final evs = await parse([
        'event: done',
        'data: ${jsonEncode({'isError': true})}',
        '',
      ]);
      expect(evs.single.isDone && evs.single.isError, isTrue);
    });

    test('context frame decodes tokens and window (0 = unknown)', () async {
      final evs = await parse([
        'event: context',
        'data: ${jsonEncode({'in': 48123, 'window': 467232})}',
        '',
        'event: context',
        'data: ${jsonEncode({'in': 15801})}', // window not yet named
        '',
      ]);
      expect(evs[0].kind, 'context');
      expect(evs[0].inputTokens, 48123);
      expect(evs[0].contextWindow, 467232);
      expect(evs[1].inputTokens, 15801);
      expect(evs[1].contextWindow, 0);
    });

    test('context PREVIEW frame (extra preview key) decodes like exact',
        () async {
      // The bridge relays estimated in-token growth with a
      // `preview: true` key; the parser must not care (exact frames
      // simply lack it).
      final evs = await parse([
        'event: context',
        'data: ${jsonEncode({'in': 90123, 'window': 467232, 'preview': true})}',
        '',
      ]);
      expect(evs.single.kind, 'context');
      expect(evs.single.inputTokens, 90123);
      expect(evs.single.contextWindow, 467232);
    });

    test('tool tokens frame carries numeric tally; absent fields degrade',
        () async {
      final evs = await parse([
        'event: tool',
        'data: ${jsonEncode({
              'name': 'tokens',
              'detail': 'thinking · 1.2k out · 21k in',
              'out': 1234,
              'in': 21001,
              'kind': 'thinking',
            })}',
        '',
        'event: tool',
        'data: {"name":"tokens","detail":"500 out · 0 in"}', // old wire
        '',
      ]);
      expect(evs[0].toolName, 'tokens');
      expect(evs[0].outTokens, 1234);
      expect(evs[0].inputTokens, 21001);
      expect(evs[0].toolKind, 'thinking');
      // An old bridge (or a plain tool_use frame) leaves the numerics
      // zeroed — the app still has the display string to show.
      expect(evs[1].outTokens, 0);
      expect(evs[1].toolKind, '');
    });
  });

  group('cleanForSpeech', () {
    test('drops fences, emphasis, headings, and bullets become prose', () {
      final s = cleanForSpeech(
        '## Summary\n'
        'The build **passed** with `_three_` warnings:\n'
        '- the first warning\n'
        '- the second warning\n'
        'See [docs](https://example.com) for more',
      );
      expect(s.contains('*'), isFalse);
      expect(s.contains('#'), isFalse);
      expect(s.contains('http'), isFalse); // link url gone, text kept
      expect(s.contains('docs'), isTrue);
      expect(s.contains('first warning'), isTrue);
      expect(s.contains('\n'), isFalse);
      expect(s.endsWith('.'), isTrue);
    });

    test('code blocks collapse and no trailing punctuation gets a stopper', () {
      final s = cleanForSpeech('done ```\ncargo build\n``` all green');
      expect(s.contains('cargo'), isFalse);
      expect(s.endsWith('.'), isTrue);
    });

    test('plain spoken sentences survive untouched', () {
      final s = cleanForSpeech('Two files changed, tests pass.');
      expect(s, 'Two files changed, tests pass.');
    });
  });

  group('prefs', () {
    test('ship preconfigured with voice routing on: zero-setup chips', () {
      expect(BridgePrefs().configured, isTrue); // fresh install = chips visible
      expect(BridgePrefs().url, BridgePrefs.defaultUrl);
      expect(BridgePrefs().token, 'testtok');
      expect(BridgePrefs().voice, isTrue); // speech goes to the harness
    });

    test('round-trips, cleared fields stay cleared, voice toggle persists', () {
      final p = BridgePrefs(
        url: 'http://100.1.2.3:8732/',
        token: 't',
        voice: false,
      );
      final q = BridgePrefs.fromJson(p.toJson());
      expect(q.configured, isTrue);
      expect(
        q.voice,
        isFalse,
      ); // an explicit off must not resurrect the default
      expect(q.url, 'http://100.1.2.3:8732/');
      // A saved empty token (user cleared it) must NOT resurrect the default:
      expect(
        BridgePrefs.fromJson({'url': 'http://x', 'token': ''}).configured,
        isFalse,
      );
      // A prefs file missing whole keys falls back to the defaults:
      expect(BridgePrefs.fromJson({'url': 'http://x'}).configured, isTrue);
      expect(BridgePrefs.fromJson({'url': 'http://x'}).voice, isTrue);
    });
  });
}
