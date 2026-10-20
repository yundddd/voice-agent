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

  test('+168: a cancelled receipt stamp survives a reload too', () {
    final note = ChatEntry.assistant(cancelled: true, receipt: true)
      ..blocks.add('Bash sleep 10 cancelled.');
    final json = encodeChatLog([note]);
    expect(json.contains('"cancelled":true'), isTrue);
    final back = decodeChatLog(json);
    expect(back.single.cancelled, isTrue); // the receipt stays a receipt
    expect(back.single.receipt, isTrue);
  });

  test('+184: a COMPLETED receipt carries its stamp too — the field '
      'tape showed two happy "finished." notes arriving in plain prose '
      'clothes', () {
    final json = encodeChatLog([
      ChatEntry.assistant(receipt: true)..blocks.add('Bash x finished.'),
    ]);
    expect(json.contains('"receipt":true'), isTrue);
    final back = decodeChatLog(json);
    expect(back.single.receipt, isTrue, reason: 'history, not machinery');
    expect(back.single.cancelled, isFalse,
        reason: 'finished is not cancelled — the ink says which');
    expect(
      encodeChatLog([ChatEntry.assistant()..blocks.add('spoken prose')]),
      isNot(contains('receipt')),
      reason: 'an ordinary reply bubble carries nothing',
    );
  });

  test('+185: the recent scan walks back to the window and stops — an '
      'unstamped legacy entry ends it too, so pre-history never dedups '
      'today', () {
    ChatEntry note(String b, int t) =>
        ChatEntry.assistant(createdMs: t)..blocks.add(b);
    final entries = [
      note('old echo', 500), // stamp older than any sane window
      note('Bash x finished.', 1000),
      note('new echo', 5000),
    ];
    expect(
      chatRecentlyContains(entries, 'Bash x finished.', nowMs: 6000, withinMs: 5000),
      isTrue,
    );
    expect(
      chatRecentlyContains(entries, 'Bash x finished.', nowMs: 999999, withinMs: 1000),
      isFalse,
      reason: 'outside the window: a different completion',
    );
    final legacy = [
      note('new echo', 5000),
      ChatEntry.assistant()..blocks.add('Bash x finished.'), // createdMs 0
    ];
    expect(
      chatRecentlyContains(legacy, 'Bash x finished.', nowMs: 6000, withinMs: 5000),
      isFalse,
      reason: 'an unstamped receipt is older than anything living',
    );
  });

  test('garbage or newer-format files start a fresh log, never throw', () {
    expect(decodeChatLog('not json at all'), isEmpty);
    expect(decodeChatLog('{"objects":"instead of lists"}'), isEmpty);
    expect(
      decodeChatLog('[{"user":true,"blocks":["x"]},{"nope":1}]').length,
      2,
    ); // tolerant
    expect(decodeChatLog('[{"user":true,"blocks":[""]}]'), isEmpty,
        reason: '+188: a blank user entry is a dead transcribe '
            'placeholder — machinery, dropped on load');
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

  fileBubbleTests();

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

// (appended with the file bubble) ─────────────────────────────────────────
void fileBubbleTests() {
  test('a file bubble round-trips: name, path, size — and the saved stamp',
      () {
    final e = ChatEntry.file('app-release.apk', 'dist/app-release.apk', 99,
        createdMs: 111)
      ..savedMs = 222
      ..savedPath = '/data/user/0/com.voiceagent/files/received/app-release.apk';
    final back = decodeChatLog(encodeChatLog([e])).single;
    expect(back.isFile, isTrue);
    expect(back.fileName, 'app-release.apk');
    expect(back.filePath, 'dist/app-release.apk');
    expect(back.fileSize, 99);
    expect(back.createdMs, 111);
    expect(back.savedMs, 222,
        reason: 'a fetched file stays Saved across a restart — history');
    expect(back.savedPath, contains('received/app-release.apk'));
    // The live download state is memory-only: a reload never shows a
    // frozen percentage from a wire that died with the process.
    expect(back.downloading, isFalse);
  });

  test('a prose entry decodes with the file fields empty', () {
    final back = decodeChatLog(
      encodeChatLog([ChatEntry.assistant(createdMs: 5)..blocks.add('hi')]),
    ).single;
    expect(back.isFile, isFalse);
    expect(back.fileName, '');
    expect(back.savedMs, 0);
  });

  test('formatBytes renders the delivery slip', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(34567890), '33.0 MB');
  });
}
