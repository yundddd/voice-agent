import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/bridge/bridge.dart';

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

    test('tokens tally frames carry the live thinking tail', () async {
      final evs = await parse([
        'event: tool',
        'data: ${jsonEncode({'name': 'tokens', 'detail': 'thinking · 40 out · 21k in', 'out': 40, 'in': 21000, 'kind': 'thinking', 'thought': 'checking the failing test first'})}',
        '',
      ]);
      final e = evs.single;
      expect(e.toolName, 'tokens');
      expect(e.toolKind, 'thinking');
      expect(e.thought, 'checking the failing test first');
    });

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

    test(
      'context PREVIEW frame (extra preview key) decodes like exact',
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
      },
    );

    test(
      'tool tokens frame carries numeric tally; absent fields degrade',
      () async {
        final evs = await parse([
          'event: tool',
          'data: ${jsonEncode({'name': 'tokens', 'detail': 'thinking · 1.2k out · 21k in', 'out': 1234, 'in': 21001, 'kind': 'thinking'})}',
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
      },
    );
  });

  group('ring frame parsing', () {
    test('parseMap decodes a {seq,ev,data} ring frame like an SSE one', () {
      final e = BridgeEvent.parseMap('tool', {
        'name': 'Bash',
        'detail': 'sleep 6',
        '_ts': 1234567,
      });
      expect(e.kind, 'tool');
      expect(e.toolName, 'Bash');
      expect(e.detail, 'sleep 6');
      expect(e.wireMs, 1234567);
    });

    test('parseMap without the bridge stamp leaves wireMs zero', () {
      final e = BridgeEvent.parseMap('say', {'text': 'ok'});
      expect(e.kind, 'say');
      expect(e.wireMs, 0);
    });

    test('file frames carry the delivery slip (name, path, bytes, mid)', () {
      final e = BridgeEvent.parseMap('file', {
        'name': 'app-release.apk',
        'path': 'build/app/outputs/flutter-apk/app-release.apk',
        'size': 34567890,
        '_ts': 999,
        '_mid': 4242,
      });
      expect(e.kind, 'file');
      expect(e.fileName, 'app-release.apk');
      expect(
        e.filePath,
        'build/app/outputs/flutter-apk/app-release.apk',
        reason: 'the root-relative path is exactly what GET /file wants',
      );
      expect(e.fileSize, 34567890);
      expect(e.mid, 4242); // the ledger dedups replays by this id
      expect(e.wireMs, 999);
    });
  });

  group('reattach decision', () {
    test('an open turn always deserves a reattach (view-steal included)', () {
      // Server still working: attach rejoins live — and when the bridge
      // still believes our dead zombie socket is attached (turnOpen with
      // backgrounded=false, missed=0) the steal is exactly the repair.
      expect(
        bridgeReattachNeeded({
          'turnOpen': true,
          'backgrounded': false,
          'missed': 0,
        }),
        isTrue,
      );
      expect(
        bridgeReattachNeeded({
          'turnOpen': true,
          'backgrounded': true,
          'missed': 12,
        }),
        isTrue,
      );
    });

    test('a turn that ended unheard replays its backlog', () {
      // Result already delivered server-side (turnOpen false) but the
      // phone never heard N events: /attach replays the tail, done included.
      expect(bridgeReattachNeeded({'turnOpen': false, 'missed': 3}), isTrue);
    });

    test('nothing open and nothing missed means go idle', () {
      expect(bridgeReattachNeeded({'turnOpen': false, 'missed': 0}), isFalse);
      // Junk/absent missed fields degrade to the same clean verdict:
      expect(bridgeReattachNeeded({'turnOpen': false}), isFalse);
      expect(bridgeReattachNeeded({'turnOpen': false, 'missed': 'x'}), isFalse);
      // An old bridge that never reports missed but has no open turn:
      expect(bridgeReattachNeeded({}), isFalse);
    });

    test('an unreachable bridge is "cannot tell", never "nothing"', () {
      // Waking phones wake their network late (Tailscale especially):
      // null must route into the retry chain, not into dropping the turn.
      expect(bridgeReattachNeeded(null), isNull);
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

    test('+179: tool-call markup emitted AS TEXT is stripped, '
        'arguments and all', () {
      // The 13:11 tape: a degraded upstream wrote its call in prose
      // and the phone spoke 27.6 s of angle-brackets. The call's
      // arguments vanish WITH the tags — a lone 'flutter test' would
      // promise a run that never happened.
      expect(
        cleanForSpeech(
          '<tool_call>\n<function name="Bash">\n'
          '<parameter name="command">flutter test</parameter>\n</function></tool_call>',
        ),
        isEmpty,
        reason: 'a whole call is nothing to say',
      );
      final m = cleanForSpeech(
        'Sure. <antml:invoke name="Read">'
        '<antml:parameter name="path">pubspec.yaml</parameter>'
        '</antml:invoke> Checking now.',
      );
      expect(m, contains('Sure'));
      expect(m, contains('Checking'));
      expect(m, isNot(contains('pubspec')), reason: 'args die with the span');
      expect(m, isNot(contains('<')), reason: 'no tag survives for espeak');
      // A truncated emission (no closer at all) still falls.
      expect(
        cleanForSpeech(
          '<tool_call>\n<function name="Bash">\n'
          '<parameter name="command">flutter test',
        ),
        isEmpty,
      );
    });

    test('dots espeak would say as the word "period" are folded', () {
      // file-extension dots: the lowercase-dot-lowercase case espeak
      // cannot read as sentence punctuation
      final s = cleanForSpeech('Edited pubspec.yaml and main.dart…');
      expect(s, contains('pubspec yaml'));
      expect(s, contains('main dart'));
      expect(s, isNot(contains('…')));
      // the '. ' join before a lowercase clause: capitalizing the next
      // word makes espeak take the dot as a sentence stop, not 'period'
      expect(cleanForSpeech('first line\nsecond line'), contains('. Second'));
      // decimals and versions are digits around the dot: left alone
      expect(cleanForSpeech('took 3.5 s, ships v1.2 today'), contains('3.5'));
      expect(cleanForSpeech('took 3.5 s, ships v1.2 today'), contains('v1.2'));
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
        tts: false,
        mode: 'pushToTalk',
      );
      final q = BridgePrefs.fromJson(p.toJson());
      // The mode tab the user left on must be the one the app reopens on.
      expect(q.mode, 'pushToTalk');
      expect(
        BridgePrefs.fromJson({'url': 'x'}).mode,
        'conversation',
        reason: 'a file with no mode key falls back to the default tab',
      );
      expect(
        BridgePrefs.fromJson({'mode': 'bogus'}).mode,
        'conversation',
        reason: 'an unknown mode (enum rename, hand-edit) falls back',
      );
      expect(q.configured, isTrue);
      expect(
        q.voice,
        isFalse,
      ); // an explicit off must not resurrect the default
      expect(
        q.tts,
        isFalse,
      ); // same law for the speaker (a dropped key here boots a
      // 334 MB voice pack the user explicitly turned off)
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
