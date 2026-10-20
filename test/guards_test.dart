// Regression guards for this session's fixes — one test per field
// report, mirroring tool/sentence_relay.test.mjs on the JS side.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/bridge/bridge.dart';
import 'package:voice_agent/src/chat/chat_log.dart';

void main() {
  group('token counts (0.1.0+82: two decimals everywhere)', () {
    test('k and M scale with two decimals', () {
      expect(fmtTokenCount(999), '999');
      expect(fmtTokenCount(12400), '12.40k');
      expect(fmtTokenCount(467232), '467.23k');
      expect(fmtTokenCount(1250000), '1.25M');
    });
  });

  group('activity labels (0.1.0+85: line one says the WORK)', () {
    test('tally kinds translate; numbers never appear', () {
      expect(activityLabelFor('thinking', 'Asking the bridge…'), 'Thinking…');
      expect(activityLabelFor('answering', 'x'), 'Answering…');
      expect(activityLabelFor('settled', 'x'), 'Rendering audio…');
    });
    test('+88: a tool step shows the command, not the theater', () {
      // The step line the tool frame assembled rides the spinner.
      expect(
        activityLabelFor('calling Bash', 'Bash git status --short…'),
        'Bash git status --short…',
      );
      expect(
        activityLabelFor('calling Edit', 'Edit bridge.dart…'),
        'Edit bridge.dart…',
      );
      // The generic wording survives only where no detail exists: the
      // sliver before the tool frame lands, or a frame with no detail.
      expect(activityLabelFor('calling Bash', ''), 'Running a command…');
      expect(activityLabelFor('calling Edit', '  '), 'Calling Edit…');
    });
    test('unknown kinds fall back to the plain status', () {
      expect(activityLabelFor('', 'Asking the bridge…'), 'Asking the bridge…');
    });
  });

  group('chat-log dedup scan (0.1.0+61/+68: heard stays unheard)', () {
    ChatEntry asst(List<String> b) => ChatEntry(fromUser: false, blocks: b);
    test('matches across whitespace churn', () {
      final log = [
        ChatEntry.user('q'),
        asst(['first   paragraph\nwith a stray newline']),
      ];
      expect(
        chatContainsBlock(log, 'first paragraph with a stray newline'),
        isTrue,
      );
    });
    test('scans the WHOLE log, not the last few bubbles', () {
      final log = [
        asst(['ancient but still heard']),
        for (var i = 0; i < 12; i++) asst(['filler $i']),
      ];
      expect(chatContainsBlock(log, 'ancient but still heard'), isTrue);
    });
    test('user entries never satisfy the scan', () {
      final log = [ChatEntry.user('echo me')];
      expect(chatContainsBlock(log, 'echo me'), isFalse);
    });
    test('near-misses miss', () {
      final log = [
        asst(['the int8 build measured muddier']),
      ];
      expect(chatContainsBlock(log, 'the int8 build measured'), isFalse);
    });
  });

  // (+151): the live-turn-bubble group retired with the in-bubble
  // spinner — the working line rides the channel's bottom row now, and
  // AssistantView.showWorkingRow is projected (assistant_view_test).

  group(
    'turn input delta (0.1.0+93: the meter bills the turn, not the world)',
    () {
      test('the first figure anchors the turn; growth is the consumption', () {
        final anchor = turnInAnchor(48000, 0);
        expect(anchor, 48000);
        expect(
          turnInAnchor(49300, anchor),
          anchor,
          reason: 'growth keeps the anchor',
        );
        expect(49300 - anchor, 1300); // the meter's honest number
      });
      test(
        '/compact mid-turn re-anchors: the delta restarts, never negative',
        () {
          final a = turnInAnchor(9000, 48000);
          expect(a, 9000);
          expect(9000 - a, 0);
        },
      );
      test("a fresh turn's opening zero clears the anchor", () {
        expect(turnInAnchor(0, 48000), 0);
        // The next real figure — this turn's first message_start — anchors.
        expect(turnInAnchor(49000, 0), 49000);
      });
    },
  );

  group('step narration silence (0.1.0+94: plumbing is eyes-only)', () {
    test('file, shell and web steps never reach the ears', () {
      for (final t in [
        'Read',
        'Edit',
        'Write',
        'MultiEdit',
        'NotebookEdit',
        'Glob',
        'Grep',
        'Bash',
        'WebFetch',
        'WebSearch',
        'Agent',
        'TodoWrite',
      ]) {
        expect(stepIsSilentFor(t), isTrue, reason: t);
      }
    });
    test('the queue acknowledgment and custom tools still speak', () {
      expect(
        stepIsSilentFor('queued'),
        isFalse,
        reason: "'One moment — …' is news, not plumbing",
      );
      expect(
        stepIsSilentFor('mcp__puppeteer__screenshot'),
        isFalse,
        reason: 'unknown tools are not plumbing by default',
      );
    });
  });

  group('boot restore comes up before the wire (restart keeps the log)', () {
    // init() runs on device plugins (path_provider, rootBundle) that no
    // unit harness can fake, so the LAW is pinned at the source: the
    // history restore and the session-id glance must sit BEFORE the
    // first network-apt step (a model ensureIn can throw on a dead
    // wire, and the catch at the bottom of init used to swallow that
    // into an error banner with NO history and NO session id — while
    // both sat perfectly intact on disk and on the bridge).
    final src = File(
      'lib/src/assistant/assistant.dart',
    ).readAsStringSync();
    final init = src.substring(src.indexOf('Future<void> init() async {'));
    test('_loadChat and the session refresh precede the first ensureIn', () {
      final load = init.indexOf('_loadChat();');
      final refresh = init.indexOf('unawaited(_refreshSession());');
      final ensure = init.indexOf('asr.ensureIn(');
      expect(load, greaterThan(-1));
      expect(refresh, greaterThan(-1));
      expect(load, lessThan(ensure), reason: 'history survives a dead wire');
      expect(refresh, lessThan(ensure), reason: 'the id survives it too');
    });
    test('the log is written atomically (a kill cannot tear it)', () {
      final fn = src.substring(
        src.indexOf('Future<void> _persistChat'),
        src.indexOf('void _loadChat()'),
      );
      expect(fn, contains('writeAsString(json, flush: true)'));
      expect(fn, contains('.rename(_chatPath)'));
      expect(
        fn,
        isNot(contains('File(_chatPath).writeAsString')),
        reason: 'no in-place rewrite of the live log',
      );
    });
  });

  group('status line rides a static band (no jittering the conversation)', () {
    // The centered channel column walks the WHOLE conversation whenever
    // any part of it reflows; the status wording changes HEIGHT as it
    // changes (the idle two-liner, a bare 'Thinking…', a long 'Bash …'
    // command), so the line may no longer size itself to its text.
    // Widget-level layout needs the device harness; the LAW is pinned
    // at the source.
    final ui = File(
      'lib/src/ui/assistant_screen.dart',
    ).readAsStringSync();
    test('the band is computed, font-scale-aware, and fixed-height', () {
      expect(ui, contains('static double _statusBand('));
      expect(
        ui,
        contains('MediaQuery.textScalerOf'),
        reason: 'a big system font must not overflow the band',
      );
      // The render site of the status word: from its band anchor
      // forward a short window — the two-line promise must be INSIDE
      // the banded Text itself, not merely somewhere in the file. (The
      // ellipsis is the promise StepLine always made of "the widget".)
      final at = ui.indexOf('height: _statusBand(context)');
      expect(at, greaterThan(-1));
      final site = ui.substring(at, at + 600);
      expect(site, contains('v.status'));
      expect(site, contains('maxLines: 2'));
      expect(site, contains('TextOverflow.ellipsis'));
    });
    test('the screen renders the status in exactly one place', () {
      // The old bare wrapping Text(v.status) must not return beside
      // (or instead of) the banded one.
      expect(
        RegExp(r'v\.status').allMatches(ui).length,
        1,
        reason: 'one banded render site is the whole law',
      );
    });
  });

  group('the bubble key rides the Column child (+197)', () {
    // The chat list pairs its children POSITIONALLY (a plain Column):
    // with the 80-entry cap live, every arrival evicts the oldest and
    // shifts the whole list one slot — so the identity key MUST be on
    // the Padding the Column sees. +175 had it on the FadeInBubble one
    // level down, the cap turned the pairing into a mass re-mount, and
    // every send replayed all eighty entrances at once (the scroll bug
    // the field reported four times). Pinned at the source: the screen
    // builds the wrapper, and no device harness reaches this layout.
    final ui = File(
      'lib/src/ui/assistant_screen.dart',
    ).readAsStringSync();
    test('ObjectKey(e) keys the Padding, not the FadeInBubble', () {
      final at = ui.indexOf('key: ObjectKey(e),');
      expect(at, greaterThan(-1), reason: 'the key exists');
      // Between the key and the entrance wrapper: the padding argument
      // and comments (this file narrates) — but no CHILD, which would
      // mean the key drifted below the widget the Column pairs.
      final between = ui.substring(
        at + 'key: ObjectKey(e),'.length,
        ui.indexOf('FadeInBubble(', at),
      );
      expect(between.trimRight(), endsWith('child:'),
          reason: 'the ONLY child: between key and entrance — the key '
              'is a sibling argument of the paired Padding, not below');
      // The old shape (key inside FadeInBubble) must be gone.
      expect(
        RegExp(r'FadeInBubble\(\s*(//[^\n]*\n\s*)*key:\s*ObjectKey\(e\)')
            .hasMatch(ui),
        isFalse,
      );
    });
  });

  group('event parsing (0.1.0+81/+84: started and settled frames)', () {
    test('started marker parses as a tool event with the prompt detail', () {
      final ev = BridgeEvent.parse(
        'tool',
        '{"name":"started","detail":"hello there"}',
      );
      expect(ev.kind, 'tool');
      expect(ev.toolName, 'started');
      expect(ev.detail, 'hello there');
    });
    test('settled tally carries its draft tail', () {
      final ev = BridgeEvent.parse(
        'tool',
        '{"name":"tokens","detail":"settled · 0.80k out","out":800,'
            '"in":1000,"kind":"settled","draft":"still unspoken tail"}',
      );
      expect(ev.toolKind, 'settled');
      expect(ev.outTokens, 800);
      expect(ev.draft, 'still unspoken tail');
    });
  });
}
