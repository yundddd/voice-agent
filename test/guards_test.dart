// Regression guards for this session's fixes — one test per field
// report, mirroring tool/sentence_relay.test.mjs on the JS side.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/chat_store.dart';
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
    final src = File('lib/src/assistant/assistant.dart').readAsStringSync();
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

  group('the status banner is gone (+267)', () {
    // The banner's whole +259..+266 arc — owner, cache, off-screen
    // sweep — ended at Tim's plain verdict: 'I want that banner
    // completely gone.' Every word it showed has a better home (the
    // working row for work, the bottom hint for ear-state, the red
    // line for errors, the tape for the rest), and the pinned
    // HEIGHT the band reserved is the channel's own. The guard is
    // the retirement certificate: the band may never come back by
    // name, and v.status may not be painted on this screen at all.
    final ui = File('lib/src/ui/assistant_screen.dart').readAsStringSync();
    test('no band, no band height, no painted status', () {
      for (final gone in ['_statusBand', 'v.status', 'maxLines: 2']) {
        expect(
          ui,
          isNot(contains(gone)),
          reason: '$gone belonged to the banner Tim deleted',
        );
      }
    });
    test('the projection still SPEAKS status — the row, not a band', () {
      // v.status remains the spinner label's data source (the +89
      // command lives there now); only the painting retired.
      final view = File('lib/src/assistant/view.dart').readAsStringSync();
      expect(view, contains('String get status'));
      final spin = File('lib/src/ui/harness_spinner.dart').readAsStringSync();
      expect(spin, contains('activityLabel'));
    });
  });

  group('the swipe is nothing but a horizontal slide (+264)', () {
    // Tim's third read of the gesture, and the one that ends the
    // redesign cycle: 'it looks like shit. just make it horizontal
    // swiping as simple as that.' Three generations of cleverness
    // (spring, held seam, inherited fractions) each bought its own
    // stutter; the law now is ONE painted offset on ONE axis with
    // the swap hidden in the thread's own absence. Pinned at the
    // source — layout needs the device, the shape of the machinery
    // does not.
    final ui = File('lib/src/ui/assistant_screen.dart').readAsStringSync();
    test('one painted value, one listener, one axis (+269)', () {
      // The +269 perf pass moved the painted X from rebuild-state to
      // a VALUE NOTIFIER (the whole screen no longer rebuilds per
      // pointer event — a fast swipe starved its own frames), and
      // put every leg behind a GENERATION TOKEN (two quick swipes
      // used to interleave their callbacks — old legs steering a new
      // gesture's pixel). The law the +264 volley wrote is
      // unchanged; only the machinery earning it is pinned now.
      expect(ui, contains('final ValueNotifier<double> _paintX'));
      expect(ui, contains('AnimatedBuilder('));
      expect(
        ui,
        isNot(contains('TweenAnimationBuilder')),
        reason: "the rebuild-driven tween is retired — the notifier "
            "does the same job at a fraction of a fast swipe's cost",
      );
      expect(
        RegExp(r'AnimatedSwitcher|SpringSimulation')
            .allMatches(ui)
            .where((m) => m.group(0) == 'AnimatedSwitcher')
            .length,
        0,
        reason: 'the crossfade switcher is retired — it was the '
            'second act every tape blamed',
      );
    });
    test('legs die by token, not by callback luck', () {
      final leg = ui.substring(
        ui.indexOf('void _beginLeg('),
        ui.indexOf('void _beginLeg(') + 900,
      );
      expect(leg, contains('_legGen++'));
      expect(leg, contains('gen != _legGen')); // the stale leg bails
      // The hop's postFrame carries a token too: a second swipe
      // retires the first hand-off's callback instead of letting it
      // stomp the new gesture.
      final hook = ui.substring(
        ui.indexOf('+264 HAND-OFF'),
        ui.indexOf('+264 HAND-OFF') + 2200,
      );
      expect(hook, contains('gen != _legGen'));
    });
    test('the content swap hides off-screen, never mid-slide', () {
      // The hand-off: finish the exit (60 ms — from anywhere, the
      // token decides), hop at the off-screen edge (a zero-duration
      // leg), and let _followTick release the reveal only after the
      // fresh thread has been pinned to its tail for two settled
      // frames. There is nothing painted to stutter.
      expect(ui, contains('Duration.zero')); // the hop
      expect(ui, contains('milliseconds: 60')); // the exit's last leg
      expect(ui, contains('milliseconds: 240')); // the way home
      expect(ui, contains('_flipArmed = false'));
    });
    test('a refusal is the same single value easing home', () {
      expect(ui, contains('void _slideHome()'));
      // _tabTap's error branch must glide the thread back — a
      // refusal that leaves the card parked mid-screen is a lie
      // with extra steps.
      final tap = ui.substring(
        ui.indexOf('void _tabTap('),
        ui.indexOf('void _tabTap(') + 700,
      );
      expect(
        tap,
        contains('_slideHome()'),
        reason: 'the snackbar carries the reason; the thread just returns',
      );
    });
    test('a swipe only MOVES — creation is the + pill, not an edge (+268)', () {
      // Tim's rule: past the end of the strip there is NOTHING, not
      // a question. The right-swipe-at-the-oldest-tab sheet (and the
      // fresh-install variant of it) are retired; the swipe must not
      // reach the creation sheet from a gesture handler — the pill
      // (outside the scroller, always visible) and the boot gate
      // own that door.
      final swipe = ui.substring(
        ui.indexOf('void _onTabSwipe('),
        ui.indexOf('void _onTabSwipe(') + 2400,
      );
      expect(
        swipe,
        isNot(contains('_newSessionTap')),
        reason: 'create-by-compass was a trap dressed as a shortcut',
      );
      expect(ui, contains('_slideHome(); // THAT side is nothing'));
    });
    test('no gesture theatre may return to the drag', () {
      for (final gone in ['_frozenAt', '_swapFrom', '_swapping', '_thaw']) {
        expect(
          ui,
          isNot(contains(gone)),
          reason: '$gone belonged to a design Tim rejected',
        );
      }
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
    final ui = File('lib/src/ui/assistant_screen.dart').readAsStringSync();
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
      expect(
        between.trimRight(),
        endsWith('child:'),
        reason:
            'the ONLY child: between key and entrance — the key '
            'is a sibling argument of the paired Padding, not below',
      );
      // The old shape (key inside FadeInBubble) must be gone.
      expect(
        RegExp(
          r'FadeInBubble\(\s*(//[^\n]*\n\s*)*key:\s*ObjectKey\(e\)',
        ).hasMatch(ui),
        isFalse,
      );
    });
  });

  group('the push-up glides (+200: the follow animates, never teleports)', () {
    // 'When a new bubble or segment shows up, the old content gets
    // pushed up as if scrolled — and that scroll is not smooth.' It
    // was not a scroll at all: a per-frame jumpTo moved the channel up
    // by a whole line, instantly, at every streaming arrival. The pin
    // now eases anything near (long distances still snap — nobody
    // wants to watch a 3000-px commute). The chase is self-owned: the
    // first shape re-targeted an animateTo every frame, and the tape
    // showed why that can never move — a driven activity counts
    // elapsed from its FIRST pulse, so replacing it each tick restarts
    // the glide at zero forever (pin +90, frozen, cont unmoving).
    final ui = File('lib/src/ui/assistant_screen.dart').readAsStringSync();
    test('the pinned branch eases its own chase, time-sized', () {
      expect(
        ui,
        contains('pos.jumpTo(pos.pixels + '),
        reason: 'the chase steps a fraction of the remaining gap',
      );
      expect(
        ui,
        contains('exp(-dtMs /'),
        reason:
            'the fraction is sized by elapsed time, not frames — '
            '25 fps jank and 120 fps silk must glide the same',
      );
      expect(
        ui,
        isNot(contains('pos.animateTo(')),
        reason:
            'near-pins must never hand the viewport to a driven '
            'activity: the elapsed-zero restart is the frozen +90',
      );
    });
    test('the +190 trap stays dead: no isScrollingNotifier anywhere', () {
      // +190 died because its guard skipped re-pins while the view was
      // 'already scrolling' — which its own glide always was. The pin
      // may only ask the touch and the stick STATE.
      expect(
        ui,
        isNot(contains('isScrollingNotifier')),
        reason: 'the geometry proxy that sank +190 must not return',
      );
    });
  });

  group('the bubble cache rev rides every mutator (+202)', () {
    // The frame tax the 25 fps tape charged: one view, one truth
    // rebuilds the whole log per event, and eighty ChatBubble
    // subtrees per rebuild ate the entrance's frames. The screen now
    // hands unchanged entries their SAME widget, trusted on the rev
    // counter — so the law is: every mutation of a live entry bumps
    // it. Proven functionally on the real store, not at the source.
    ChatStore store() =>
        ChatStore(persist: (_) async {}, repaint: () {}, nowMs: () => 1000);
    test('every store mutator bumps the revision', () {
      final s = store();
      final turn = s.beginTurn();
      expect(turn.rev, 0, reason: 'born clean');
      s.addBlock(turn, 'first spoken section');
      expect(turn.rev, 1, reason: 'THE streaming hot path');
      s.addBlock(turn, 'second section');
      expect(turn.rev, 2);
      s.markInterrupted(turn);
      expect(turn.rev, 3, reason: 'the cut stamp rides the face');
      s.removeBlock(turn, 'second section');
      expect(turn.rev, 4, reason: 'a withdrawn block is a smaller bubble');
      final u = s.addUserTranscribing();
      final before = u.rev;
      s.fillUser(u, 'words at last');
      expect(u.rev, greaterThan(before), reason: 'the pulse became text');
      s.addUser('pinned press', queued: true);
      s.unpinQueued();
      expect(
        s.entries.last.rev,
        greaterThan(0),
        reason: 'the lifted pin re-renders without its caption',
      );
    });
    test('the screen trusts the rev and opts live things out', () {
      final ui = File('lib/src/ui/assistant_screen.dart').readAsStringSync();
      expect(
        ui,
        contains('hit.\$1 == e.rev'),
        reason: 'the cache hit is the rev, nothing heuristic',
      );
      expect(
        ui,
        contains('!e.isFile && !e.queued'),
        reason: 'the ticking pin and the churning slip rebuild always',
      );
      expect(
        ui,
        contains('_pruneBubbleCache'),
        reason: 'cap evictions must not leave tombstones in the map',
      );
    });
  });

  group('history encodes off the hot path (+205)', () {
    // The frame bill said: medians of one and two milliseconds, and
    // one 71 ms BUILD spike — the entrance paying for someone else's
    // jsonEncode. The suspect was +199's own compromise: writes were
    // coalesced but the STORE still encoded all eighty entries on the
    // UI isolate at every touch. The contract now carries the list;
    // the encode belongs to the persister, runs once per burst, and
    // runs on a worker isolate.
    final store = File('lib/src/assistant/chat_store.dart').readAsStringSync();
    final asst = File('lib/src/assistant/assistant.dart').readAsStringSync();
    test('the store no longer encodes at all', () {
      expect(
        store,
        isNot(contains('encodeChatLog')),
        reason:
            'touch is every say, every pin, every receipt — it may '
            'copy a list, it may not mint JSON',
      );
    });
    test('the persister encodes once, on a worker isolate', () {
      expect(asst, contains('Isolate.run(() => encodeChatLog(entries))'));
      expect(asst, contains('List<ChatEntry>? _pendingChatEntries'));
    });
  });

  group('the chase reports its frame cost (+203)', () {
    // Thirty-millisecond frames with eighty rebuilds explained was
    // ONE suspect; with the rebuild tax paid it is a mystery, and
    // mysteries get instruments, not guesses. The screen now rides
    // the scheduler's own timings: one 'fps chase' line per push,
    // build and raster halves apart — the field report writes itself.
    final ui = File('lib/src/ui/assistant_screen.dart').readAsStringSync();
    test('the witness is registered, summarised, and unregistered', () {
      expect(ui, contains('addTimingsCallback(_onFrameTimings)'));
      expect(
        ui,
        contains('removeTimingsCallback(_onFrameTimings)'),
        reason: 'a leaked timings callback outlives the screen',
      );
      expect(ui, contains("'fps chase: n"));
      // The window is bounded no matter how chatty frames get.
      expect(ui, contains('_timings.length > 240'));
      expect(
        ui,
        contains('_chaseEndUs'),
        reason: 'the summary is deferred, not inline',
      );
      // +206: the period and UI-side halves are measured ON THE SPOT
      // (Android's FrameTiming batches arrived minutes-late on the
      // +205 tape and every bill read 'lag'); the persistent frame
      // callback cannot be batched away, and raster — the one half
      // that genuinely needs the GPU's report — admits when the batch
      // is still traveling instead of voiding the whole bill.
      expect(ui, contains('addPersistentFrameCallback(_onFrameStart)'));
      expect(
        ui,
        contains('if (!_framesAlive) return;'),
        reason:
            'the scheduler cannot remove a persistent callback — '
            'the witness must disarm itself on dispose',
      );
      expect(ui, contains('_frames.length > 240'));
      expect(ui, contains('raster pending'));
      // +207: the window opens by SEQUENCE NUMBER — a list index
      // into a ring that trims goes stale the moment the cap is hit
      // and every window slices to nothing.
      expect(ui, contains('_framesMark = _framesSeen'));
      expect(ui, contains('mark - (_framesSeen - _frames.length)'));
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
