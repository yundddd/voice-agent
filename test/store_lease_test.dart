// The conversation log store (cap, pins, empty turns, persistence) and
// the quiet-wire lease (the zombie watchdog's lease algebra).

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/chat_store.dart';
import 'package:voice_agent/src/chat/chat_log.dart';
import 'package:voice_agent/src/bridge/wire_lease.dart';
import 'package:voice_agent/src/common/sinks.dart';

void main() {
  group('ChatStore', () {
    late List<String> persisted;
    late ChatStore store;
    var repaints = 0;
    setUp(() {
      persisted = [];
      repaints = 0;
      store = ChatStore(
        persist: (entries) async => persisted.add(encodeChatLog(entries)),
        repaint: () => repaints++,
        cap: 4,
      );
    });

    test('user turns and spoken blocks version and persist', () {
      store.addUser('hi');
      final turn = store.beginTurn();
      store.addBlock(turn, 'hello back');
      expect(store.entries.map((e) => e.fromUser).toList(), [true, false]);
      expect(store.version, 3);
      expect(persisted.length, greaterThanOrEqualTo(3));
      expect(repaints, greaterThanOrEqualTo(3));
    });

    test('the cap trims oldest first (the on-screen AND on-disk bound)', () {
      for (var i = 0; i < 6; i++) {
        store.addUser('u$i');
      }
      expect(store.entries, hasLength(4));
      expect(store.entries.first.blocks.single, 'u2');
    });

    test('one pin at a time: a newer press outranks the old (+91 rules)', () {
      store.addUser('first parked', queued: true);
      expect(store.queuedText, 'first parked');
      store.addUser('second parked', queued: true);
      expect(store.queuedText, 'second parked');
      // The old pin is no longer queued in the log either — it shows
      // as plain history (superseded on the wire).
      final old = store.entries.first;
      expect(old.queued, isFalse);
    });

    test('the pickup dissolves the pin in place', () {
      store.addUser('parked', queued: true);
      store.unpinQueued();
      expect(store.queuedBubble, isNull);
      expect(store.entries.first.queued, isFalse);
    });

    test('an empty turn is withdrawn; a spoken one stays', () {
      final t1 = store.beginTurn();
      store.addBlock(t1, 'said');
      final t2 = store.beginTurn();
      store.removeEmptyTurn(t2);
      expect(store.entries, hasLength(1));
      expect(store.containsBlock('said'), isTrue);
      expect(store.containsBlock('never said'), isFalse);
    });

    test('a system note is its own bubble and reloads as history (+110)', () {
      final turn = store.beginTurn();
      store.addSystemNote('One moment — the thinking was interrupted.');
      // Standalone: the open turn stays empty — it will collect the
      // answer; the note stands after it as its own card.
      expect(turn.blocks, isEmpty);
      expect(store.entries.last.fromUser, isFalse);
      expect(
        store.entries.last.blocks.single,
        'One moment — the thinking was interrupted.',
      );
      // On disk it is an ordinary assistant bubble: reloads as history,
      // with no live pin semantics.
      store.load(persisted.last);
      expect(store.entries.last.blocks.single, contains('was interrupted'));
    });

    test('a relayed file is its own bubble; one event, one card', () {
      store.addFile(name: 'app-release.apk', path: 'dist/a.apk', size: 123);
      final e = store.entries.last;
      expect(e.isFile, isTrue);
      expect(e.fileName, 'app-release.apk');
      expect(e.filePath, 'dist/a.apk');
      expect(e.fileSize, 123);
      // Adjacency idempotence (the poll transport's double delivery):
      // the same path back-to-back files ONE bubble.
      store.addFile(name: 'app-release.apk', path: 'dist/a.apk', size: 123);
      expect(store.entries.length, 1);
      // …and a different file (or the same one later) is a new card.
      store.addFile(name: 'notes.txt', path: 'dist/n.txt', size: 7);
      expect(store.entries.length, 2);
    });

    test('a block can be withdrawn; the rest of the bubble stays (+114)', () {
      final t = store.beginTurn();
      store.addBlock(t, 'heard fully');
      store.addBlock(t, 'never aired');
      store.removeBlock(t, 'never aired');
      expect(t.blocks, ['heard fully']);
      // Unknown text is a no-op (double teardown races).
      store.removeBlock(t, 'never aired');
      expect(t.blocks, ['heard fully']);
    });

    test('+185: the receipt dedup EXPIRES — text is never an identity '
        'across time (field: second identical run went silent)', () {
      var t = 1000000;
      final s = ChatStore(
        persist: (_) async {},
        repaint: () {},
        nowMs: () => t,
      );
      s.addSystemNote('Bash sleep 10 && echo done finished.', receipt: true);
      // A redelivery of the SAME receipt half a minute later (the drain
      // belt's double transport): the recent scan still fires — one
      // completion, one period.
      t += 30 * 1000;
      expect(
        s.containsBlockRecent('Bash sleep 10 && echo done finished.'),
        isTrue,
      );
      // The NEXT RUN of the same command, twenty minutes later: the old
      // bubble is in the log, but it belongs to a dead delivery window —
      // the fresh completion must file its own period (the whole-log
      // scan used to answer isTrue here forever).
      t += 20 * 60 * 1000;
      expect(
        s.containsBlockRecent('Bash sleep 10 && echo done finished.'),
        isFalse,
        reason: 'two runs, two receipts',
      );
      expect(
        s.containsBlock('Bash sleep 10 && echo done finished.'),
        isTrue,
        reason: 'the whole-log scan is untouched for its own uses',
      );
    });

    test('+186: receipts dedup by the TASK ID — forever, and only for '
        'that task; the stamp round-trips through disk', () {
      var t = 1000000;
      final s = ChatStore(
        persist: (entries) async => persisted.add(encodeChatLog(entries)),
        repaint: () {},
        nowMs: () => t,
      );
      s.addSystemNote(
        'Bash sleep 10 && echo done finished.',
        receipt: true,
        receiptId: 'aaa',
      );
      expect(s.hasReceiptFor('aaa'), isTrue);
      expect(s.hasReceiptFor('bbb'), isFalse);
      // A year later the identical command runs again: new task, new
      // id — its own period, no window arithmetic involved. (The
      // adjacency guard must not swallow it: same words, different
      // identity.)
      t += 365 * 24 * 3600 * 1000;
      s.addSystemNote(
        'Bash sleep 10 && echo done finished.',
        receipt: true,
        receiptId: 'bbb',
      );
      expect(
        s.entries.where((e) => e.receiptId.isNotEmpty),
        hasLength(2),
        reason: 'two runs, two receipts, ids telling them apart',
      );
      // And the identity survives a restart: dedup keeps its memory.
      s.load(persisted.last);
      expect(s.hasReceiptFor('aaa'), isTrue);
      expect(s.hasReceiptFor('bbb'), isTrue);
    });

    test('+188: the release opens the bubble at once, the transcript '
        'fills it in place; an unfilled placeholder never reloads', () {
      final ph = store.addUserTranscribing();
      expect(ph.transcribing, isTrue);
      expect(store.entries.single.fromUser, isTrue);
      expect(store.entries.single.blocks.single, isEmpty);
      // The words land: same entry, same position, pulse off.
      store.fillUser(ph, 'weather in the morning', queued: true);
      expect(ph.transcribing, isFalse);
      expect(ph.blocks.single, 'weather in the morning');
      expect(ph.queued, isTrue);
      expect(store.queuedText, 'weather in the morning');
      // Machinery like the pin: an unfilled placeholder does not
      // survive the reload (the decoder drops blank user entries).
      final raw = encodeChatLog([
        store.addUserTranscribing(), // nobody ever fills this one
      ]);
      store.load(raw);
      expect(
        store.entries,
        isEmpty,
        reason:
            'a dead mid-ASR bubble reloads as nothing, not as a '
            'blank card',
      );
    });

    test('containsBlock matches how the log stores (whitespace, not case)', () {
      final t = store.beginTurn();
      store.addBlock(t, 'Two   spaces\nand a newline');
      expect(store.containsBlock('Two spaces and a newline'), isTrue);
      expect(
        store.containsBlock('two spaces and a newline'),
        isFalse,
        reason: 'the fold is whitespace-only: case stays honest',
      );
    });

    // (+151): the liveTurn tests retired with ChatStore.liveTurn — the
    // spinner rides no bubble, so the store has no box-placement law left
    // to pin; the bottom row's visibility is AssistantView.showWorkingRow.

    test('load is tolerant: garbage starts a fresh log', () {
      store.addUser('keep me until reload');
      store.load(']not json[');
      expect(store.entries, isEmpty);
      store.load('[{"user":true,"blocks":["restored"]}]');
      expect(store.entries.single.blocks.single, 'restored');
    });

    test('lifecycle stamps + trace lines tell the queue→heard→cut story', () {
      var t = 1000000;
      final lines = <String>[];
      final s = ChatStore(
        persist: (_) async {},
        repaint: () {},
        nowMs: () => t,
        trace: lines.add,
      );
      // Generated on the phone, parked behind live work:
      s.addUser('parked behind a build', queued: true);
      expect(s.entries.first.createdMs, 1000000);
      expect(
        lines,
        contains('msg phone: user "parked behind a build" queued=1'),
      );
      // Harness takes it 47 s later — the queue wait is journaled:
      t = 1047000;
      s.unpinQueued();
      expect(s.entries.first.pickedUpMs, 1047000);
      expect(lines, contains(startsWith('msg queue taken: waited 47s')));
      // The answer lands 1m43s after the prompt was sent:
      final turn = s.beginTurn();
      expect(lines, contains(startsWith('msg turn: assistant bubble open')));
      t = 1103000;
      s.addBlock(turn, 'Build finished, tests pass.');
      expect(turn.deliveredMs, 1103000);
      expect(
        lines,
        contains(
          'msg heard: assistant "Build finished, tests pass." '
          '(sent→heard 1m43s)',
        ),
      );
      s.addBlock(turn, 'Second section.');
      expect(
        lines.where((l) => l.startsWith('msg heard')).length,
        1,
        reason: 'the bubble is stamped DELIVERED once, at its first block',
      );
      // A cut turn stamps its death and says what survived:
      final cut = s.beginTurn();
      t = 1111000;
      s.markInterrupted(cut);
      expect(cut.interruptedMs, 1111000);
      expect(
        lines,
        contains(startsWith('msg cut: turn shortened after 8s with 0')),
      );
    });
  });

  group('WireLease', () {
    late FakeScheduler time;
    late Duration? quietFired;
    late WireLease lease;
    bool attached = true, paused = false, draining = false;

    setUp(() {
      time = FakeScheduler(DateTime(2026, 1, 1, 12));
      quietFired = null;
      attached = true;
      paused = false;
      draining = false;
      lease = WireLease(
        scheduler: time,
        clock: () => time.now,
        attached: () => attached,
        paused: () => paused,
        audioDraining: () => draining,
        onQuiet: (q) => quietFired = q,
      );
    });

    test('a stream that never delivers bytes is a zombie at the window', () {
      lease.armWatch();
      time.advance(const Duration(seconds: 23));
      expect(quietFired, isNull);
      time.advance(const Duration(seconds: 2));
      expect(quietFired, isNotNull);
      expect(quietFired!.inSeconds, greaterThanOrEqualTo(24));
    });

    test('pings keep the lease alive (the quiet window restarts)', () {
      lease.armWatch();
      for (var i = 0; i < 6; i++) {
        time.advance(const Duration(seconds: 15)); // the bridge ping…
        lease.markAlive(); // …lands as a tapped activity callback
      }
      expect(quietFired, isNull);
    });

    test('queued audio outranks the hop (hear it out first)', () {
      draining = true;
      lease.armWatch();
      time.advance(const Duration(seconds: 30));
      expect(quietFired, isNull, reason: 'the reply is still audible');
      draining = false;
      time.advance(const Duration(seconds: 25));
      expect(quietFired, isNotNull);
    });

    test('no turn / hidden app: the check is a no-op', () {
      attached = false;
      lease.armWatch();
      time.advance(const Duration(minutes: 2));
      expect(quietFired, isNull);

      attached = true;
      paused = true;
      time.advance(const Duration(minutes: 2));
      expect(
        quietFired,
        isNull,
        reason: 'resumeConversation re-leases the stream itself',
      );
    });

    test('a dribbling wire re-arms for the remainder, not the full window', () {
      lease.armWatch();
      time.advance(const Duration(seconds: 20));
      lease.markAlive(); // bytes crossed 20 s into the window
      time.advance(const Duration(seconds: 23)); // t=43: fresh lease is 23 s
      expect(quietFired, isNull, reason: 'the re-armed full window is open');
      time.advance(const Duration(seconds: 2)); // t=45: 25 s of silence
      expect(quietFired!.inSeconds, greaterThanOrEqualTo(24));
    });
  });
}
