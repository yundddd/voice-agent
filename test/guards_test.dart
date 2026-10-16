// Regression guards for this session's fixes — one test per field
// report, mirroring tool/sentence_relay.test.mjs on the JS side.
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/bridge.dart';
import 'package:voice_agent/chat_log.dart';

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

  group('live-turn bubble (0.1.0+91: the press must not hide the spinner)', () {
    test('a queued pin pressed over live work keeps the work bubble', () {
      final chat = [
        ChatEntry.user('first question'),
        ChatEntry.assistant()..blocks.add('spoken block'),
        ChatEntry.user('queued press', queued: true),
      ];
      // The pin rides the card below, out of the flow — the assistant
      // entry is still the bubble the working line belongs on.
      expect(liveTurnFor(chat, turnRunning: true), same(chat[1]));
    });
    test('no running turn, no bubble', () {
      final chat = [ChatEntry.user('q'), ChatEntry.assistant()];
      expect(liveTurnFor(chat, turnRunning: false), isNull);
    });
    test('a turn with no assistant bubble yet has none to show', () {
      expect(liveTurnFor([ChatEntry.user('q')], turnRunning: true), isNull);
    });
  });

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
