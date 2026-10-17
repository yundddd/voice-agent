import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/chat/chat_log.dart';

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

  test('a queue pin round-trips on disk but dies with the reload', () {
    final json = encodeChatLog([
      ChatEntry.user('behind the live turn', queued: true),
    ]);
    expect(json.contains('"queued":true'), isTrue); // saved, so a crash
    // mid-queue can still see the message in its log...
    final back = decodeChatLog(json);
    // ...but the pin itself is a live-turn contract: nobody holds it
    // after a restart, so it must not hang at the channel bottom.
    expect(back.single.queued, isFalse);
    expect(ChatEntry.user('plain').queued, isFalse);
    expect(ChatEntry.assistant().queued, isFalse);
  });

  test('an interrupted stamp survives a reload — it is history (+108)', () {
    final dead = ChatEntry.assistant()
      ..blocks.add('The first sections it got to speak');
    expect(dead.interrupted, isFalse); // born clean
    dead.interrupted = true;
    final json = encodeChatLog([dead]);
    expect(json.contains('"interrupted":true'), isTrue);
    final back = decodeChatLog(json);
    expect(back.single.interrupted, isTrue); // unlike the pin, the cut stays
    expect(back.single.blocks.single, dead.blocks.single); // text untouched
    // Turns that finished normally never carry the field at all.
    expect(
      encodeChatLog([ChatEntry.assistant()..blocks.add('done clean')]),
      isNot(contains('interrupted')),
    );
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

  test('lifecycle stamps round-trip; legacy entries decode stamp-free', () {
    final turn = ChatEntry.assistant(createdMs: 1000)..blocks.add('heard!');
    turn.deliveredMs = 2500;
    final cut = ChatEntry.user('queued press', createdMs: 10);
    cut.pickedUpMs = 45000;
    cut.interrupted = true;
    cut.interruptedMs = 500;
    final back = decodeChatLog(encodeChatLog([turn, cut]));
    expect(back[0].createdMs, 1000);
    expect(back[0].deliveredMs, 2500);
    expect(back[0].pickedUpMs, 0);
    expect(back[1].createdMs, 10);
    expect(back[1].pickedUpMs, 45000);
    expect(back[1].interruptedMs, 500);
    // A zero stamp never lands in the JSON (keeps the file lean and the
    // absent-vs-known distinction honest), and files from before the
    // feature decode with 0s rather than throwing.
    final raw = encodeChatLog([ChatEntry.assistant()..blocks.add('x')]);
    expect(raw.contains('"t":'), isFalse);
    expect(decodeChatLog(raw).single.createdMs, 0);
    expect(
      decodeChatLog('[{"user":true,"blocks":["a"],"t":"junk"}]').single,
      isNotNull,
    ); // tolerant
  });

  test('formatBubbleClock / formatWait render compactly', () {
    final t = DateTime(2026, 10, 17, 9, 5, 3);
    expect(formatBubbleClock(t.millisecondsSinceEpoch), '09:05:03');
    expect(formatBubbleClock(0), ''); // unknown stamp renders no caption
    expect(formatWait(999), '0s');
    expect(formatWait(47_500), '47s');
    expect(formatWait(125_000), '2m05s');
    expect(formatWait(7_260_000), '2h01m');
  });
}
