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
      expect(activityLabelFor('calling Bash', 'x'), 'Running a command…');
      expect(activityLabelFor('calling Edit', 'x'), 'Calling Edit…');
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
      expect(chatContainsBlock(log, 'first paragraph with a stray newline'), isTrue);
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
      final log = [asst(['the int8 build measured muddier'])];
      expect(chatContainsBlock(log, 'the int8 build measured'), isFalse);
    });
  });

  group('event parsing (0.1.0+81/+84: started and settled frames)', () {
    test('started marker parses as a tool event with the prompt detail', () {
      final ev = BridgeEvent.parse('tool', '{"name":"started","detail":"hello there"}');
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
