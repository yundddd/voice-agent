// The conversation log store (cap, pins, empty turns, persistence) and
// the quiet-wire lease (the zombie watchdog's lease algebra).

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/chat_store.dart';
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
        persist: (json) async => persisted.add(json),
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

    test('liveTurn: the last assistant bubble, under a queued pin (+91)', () {
      final t = store.beginTurn();
      store.addUser('press over live work', queued: true);
      expect(
        store.liveTurn(turnRunning: true),
        same(t),
        reason: 'the pin rides the card, not the spinner',
      );
      expect(store.liveTurn(turnRunning: false), isNull);
    });

    test('liveTurn: parkedBehind keeps the spinner on the RUNNING work '
        "(+148: a queued press's placeholder must not steal the box)", () {
      final work = store.beginTurn();
      store.addBlock(work, 'Bash still chewing');
      store.addUser('press', queued: true);
      store.beginTurn(); // the parked prompt's bubble
      expect(
        store.liveTurn(turnRunning: true),
        same(work),
        reason: '+150: the work has content, the placeholder does not',
      );
      expect(
        store.liveTurn(turnRunning: true, parkedBehind: true),
        same(work),
        reason: 'parked: the tool-call box stays where the work is',
      );
    });

    test('liveTurn: empty shells never host the spinner while content '
        'survives (+150: the drain that dragged the box)', () {
      final answer = store.beginTurn();
      store.addBlock(answer, 'Done — clean finish.');
      // A backlog drain whose replay deduped to nothing: an empty
      // shell, positionally newer than the content.
      final shell = store.beginTurn();
      store.addUser('press', queued: true);
      store.beginTurn(); // the parked prompt's placeholder
      expect(
        store.liveTurn(turnRunning: true, parkedBehind: true),
        same(answer),
        reason: 'parked: content rides, shells wait',
      );
      expect(
        store.liveTurn(turnRunning: true),
        same(answer),
        reason: '+150: the content law needs no parking to hold',
      );
      // All-empty (a thinking story): the RUNNING turn's bubble rides,
      // not the placeholder parked on top of it.
      final fresh = ChatStore(
        nowMs: () => 0,
        persist: (_) async {},
        repaint: () {},
      );
      final work = fresh.beginTurn();
      fresh.addUser('press', queued: true);
      final parked = fresh.beginTurn();
      expect(fresh.liveTurn(turnRunning: true, parkedBehind: true), same(work));
      expect(fresh.liveTurn(turnRunning: true), same(parked));
      // Nothing but the shell's own answer: it rides like always.
      answer.blocks.add('more');
      expect(store.liveTurn(turnRunning: true), same(answer));
      expect(shell.blocks, isEmpty); // the shell stays the drain's grave
    });

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
