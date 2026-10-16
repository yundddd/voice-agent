import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/chat_log.dart';

void main() {
  test('user and sectioned-assistant entries round-trip through json', () {
    final entries = [
      ChatEntry.user('what changed recently?'),
      ChatEntry.assistant()
        ..blocks.addAll(['Running git log now', 'Two files, tests pass.']),
      ChatEntry.user('Repo status'),
      ChatEntry.assistant()..blocks.add('One file has changes.'),
    ];
    final back = decodeChatLog(encodeChatLog(entries));
    expect(back.length, 4);
    expect(back[0].fromUser, isTrue);
    expect(back[0].blocks.single, 'what changed recently?');
    expect(back[1].fromUser, isFalse);
    expect(back[1].blocks, ['Running git log now', 'Two files, tests pass.']);
    expect(back[3].blocks.single, 'One file has changes.');
    expect(back[2].isEmpty, isFalse);
  });

  test('an open assistant turn reports itself empty (UI hides it)', () {
    expect(ChatEntry.assistant().isEmpty, isTrue);
  });

  test('garbage or newer-format files start a fresh log, never throw', () {
    expect(decodeChatLog('not json at all'), isEmpty);
    expect(decodeChatLog('{"objects":"instead of lists"}'), isEmpty);
    expect(decodeChatLog('[{"user":true},{"nope":1}]').length, 2); // tolerant
    expect(decodeChatLog('[]'), isEmpty);
  });

  test('encode of the live list keeps user/assistant kind distinct', () {
    final json = encodeChatLog([
      ChatEntry.user('a'),
      ChatEntry.assistant()..blocks.add('b'),
    ]);
    expect(json.contains('"user":true'), isTrue);
    expect(json.contains('"user":false'), isTrue);
  });
}
