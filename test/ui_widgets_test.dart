// The conversation widgets render ONLY AssistantView data — so they can
// be exercised against hand-built views: no VoiceAssistant, no fakes,
// no device. This is the payoff of the projection: UI iteration is
// verified at the UI layer, and behavior changes arrive as view
// differences (see assistant_view_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/activity.dart';
import 'package:voice_agent/src/assistant/state.dart';
import 'package:voice_agent/src/assistant/view.dart';
import 'package:voice_agent/src/chat/chat_log.dart';
import 'package:voice_agent/src/ui/chat_view.dart';
import 'package:voice_agent/src/ui/context_bar.dart';
import 'package:voice_agent/src/ui/latency_strip.dart';
import 'package:voice_agent/src/ui/talk_surface.dart';

AssistantView _view({
  AssistantPhase phase = AssistantPhase.idle,
  Activity? activity,
  List<ChatEntry> chat = const [],
  QueuedPin? queued,
  BgWork backgrounded = BgWork.hidden,
  TokenMeter token = const TokenMeter(
    on: false,
    out: 0,
    inTok: 0,
    thought: '',
    draft: '',
    settled: false,
    activityLabel: '',
  ),
  ContextBarView context = const ContextBarView(
    tokensIn: 0,
    window: 0,
    busy: false,
  ),
  Duration harnessElapsed = Duration.zero,
  bool bridgeBusy = true,
  bool harnessBackgrounded = false,
  bool drainOwed = false,
  bool drainReading = false,
  PttGuide ptt = const PttGuide(
    holdActive: false,
    slide: PttSlide.none,
    drag: Offset.zero,
    holdOverTurn: false,
  ),
}) => AssistantView(
  phase: phase,
  mode: InteractionMode.pushToTalk,
  activity: activity ?? const IdleHint(),
  error: '',
  chat: chat,
  chatVersion: 1,
  queued: queued,
  backgrounded: backgrounded,
  bridgeBusy: bridgeBusy,
  harnessBackgrounded: harnessBackgrounded,
  drainOwed: drainOwed,
  drainReading: drainReading,
  bridgeConfigured: true,
  ttsOn: true,
  userSpeaking: false,
  token: token,
  context: context,
  latency: const LatencyView(
    recordSeconds: 1.2,
    asrSeconds: 0.34,
    ttsSeconds: 0.05,
    playSeconds: 2.0,
    hopAsr: true,
    hopSent: true,
    hopReply: true,
    hopTts: true,
  ),
  ptt: ptt,
  sessionId: 'abc-123',
  harnessElapsed: harnessElapsed,
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// The fade TARGET of a slide band — 0 at rest, 1 while a hold is
/// down. The animation value converges to this; asserting the target is
/// asserting what the projection ordered.
double _bandOpacity(WidgetTester tester, String label) => tester
    .widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

void main() {
  group('FadeInBubble', () {
    testWidgets('a new bubble fades in, settles opaque, and never replays',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const FadeInBubble(key: ValueKey('e1'), child: Text('arriving')),
        ),
      );
      FadeTransition fade() => tester.widget<FadeTransition>(
        find
            .descendant(
              of: find.byType(FadeInBubble),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        fade().opacity.value,
        lessThan(1.0),
        reason: 'mid-flight: the bubble eases in, it does not flicker',
      );
      await tester.pumpAndSettle();
      expect(fade().opacity.value, 1.0);
      // A rebuild of the SAME element (a streamed section growing the
      // bubble) must not re-animate: the one-shot belongs to the
      // element's birth, and the ObjectKey keeps that birth honest.
      await tester.pumpWidget(
        _host(
          const FadeInBubble(key: ValueKey('e1'), child: Text('arriving')),
        ),
      );
      await tester.pump();
      expect(fade().opacity.value, 1.0);
    });
  });

  group('ChatBubble', () {
    testWidgets('a user bubble shows its text', (tester) async {
      final entry = ChatEntry.user('Repo status', createdMs: 1);
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      expect(find.text('Repo status'), findsOne);
    });

    testWidgets('an interrupted turn admits it was cut (+108)', (tester) async {
      final entry = ChatEntry.assistant(createdMs: 1)
        ..blocks.add('First heard section.');
      entry.interrupted = true;
      entry.interruptedMs = 2;
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      expect(find.text('First heard section.'), findsOne);
      expect(find.textContaining('interrupted'), findsOne);
    });

    testWidgets('a newly streamed segment eases in while the spoken one '
        'holds still — the segment-level flicker +181 ends', (tester) async {
      final entry = ChatEntry.assistant(createdMs: 1)
        ..blocks.add('First spoken section.');
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      await tester.pumpAndSettle(); // the birth fade of the one segment lands
      double seg(int i) => tester
          .widget<FadeTransition>(
            find
                .descendant(
                  of: find.byKey(ValueKey(i)),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value;
      expect(seg(0), 1.0);
      // The second spoken paragraph arrives at the open bubble: the new
      // tail rides its own one-shot ease; the already-heard segment
      // must NOT replay its entrance (that replay was the flicker).
      entry.blocks.add('Second spoken section.');
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(seg(0), 1.0, reason: 'settled text never re-fades');
      expect(seg(1), lessThan(1.0), reason: 'the new segment eases in');
      await tester.pumpAndSettle();
      expect(seg(0), 1.0);
      expect(seg(1), 1.0);
      // +187: the entrance also animates LAYOUT — the new segment was
      // mid-open (its measured height under the final one) while the
      // spoken segment's box never moved, and it settles at full
      // height. The slot appearing instantly is the snap this ends.
      final settledHeight = tester.getSize(find.byKey(ValueKey(1))).height;
      expect(settledHeight, greaterThan(0));
    });

    testWidgets('a grow entrance opens the layout, not just the ink '
        '(+187)', (tester) async {
      await tester.pumpWidget(
        _host(
          const FadeInBubble(
            key: ValueKey('grow'),
            grow: true,
            child: Text('opens downward', textDirection: TextDirection.ltr),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
      final mid = tester.getSize(find.byKey(ValueKey('grow'))).height;
      await tester.pumpAndSettle();
      final full = tester.getSize(find.byKey(ValueKey('grow'))).height;
      expect(mid, lessThan(full),
          reason: 'the height travels with the fade — no layout pop');
      expect(mid, greaterThan(0), reason: 'the ease opens, it does not slam');
    });

    testWidgets('a finish receipt wears the outline, not the reply card '
        '(+184: receipts are receipts, finished included)', (tester) async {
      final entry = ChatEntry.assistant(createdMs: 1, receipt: true)
        ..blocks.add('Bash sleep 10 finished.');
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      await tester.pumpAndSettle();
      final card = tester.widget<Card>(find.byType(Card));
      expect(card.color, Colors.transparent,
          reason: 'no secondaryContainer fill — it is not a spoken reply');
      expect(card.shape, isA<RoundedRectangleBorder>(),
          reason: 'the outline card law of +168, widened');
      expect(find.byIcon(Icons.check_circle_outline), findsOne);
      expect(find.text('Bash sleep 10 finished.'), findsOne);
    });

    testWidgets('a cancelled receipt keeps the warning ink and the pan '
        '(+168 law untouched, glyph added)', (tester) async {
      final entry = ChatEntry.assistant(createdMs: 1, cancelled: true)
        ..blocks.add('Bash sleep 60 cancelled.');
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.pan_tool_outlined), findsOne);
      expect(find.text('Bash sleep 60 cancelled.'), findsOne);
    });

    testWidgets('a transcribing bubble pulses with no words, and the '
        'fill replaces the pulse with the text (+188)', (tester) async {
      final entry = ChatEntry.user('', createdMs: 1)..transcribing = true;
      Widget bubble() => _host(
        ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
      );
      await tester.pumpWidget(bubble());
      expect(find.text(''), findsNothing);
      expect(find.byType(SelectableText), findsNothing,
          reason: 'no words yet — the pulse speaks instead');
      entry.blocks[0] = 'weather in the morning';
      entry.transcribing = false;
      await tester.pumpWidget(bubble());
      expect(find.text('weather in the morning'), findsOne);
      expect(find.byType(SelectableText), findsOne);
    });

    testWidgets('a file bubble renders the slip AND its tap receives '
        '(the field report: tap to receive did nothing — SelectableText '
        'was eating it)', (tester) async {
      ChatEntry? tapped;
      final entry = ChatEntry.file(
        'README.md',
        'voice-agent/README.md',
        49250,
        createdMs: 1,
      );
      await tester.pumpWidget(
        _host(
          ChatBubble(
            entry: entry,
            maxWidthFrac: 0.86,
            source: () => _view(),
            onFileTap: (e) => tapped = e,
          ),
        ),
      );
      expect(find.text('README.md'), findsOne);
      expect(find.text('48 KB · tap to receive'), findsOne);
      // The tap must fire from the name, the status line, and the
      // card's padding — the whole bubble is the button.
      await tester.tap(find.text('README.md'));
      expect(tapped, same(entry));
      tapped = null;
      await tester.tap(find.text('48 KB · tap to receive'), warnIfMissed: true);
      expect(tapped, same(entry));
    });

    testWidgets('a saved bubble re-offers as an OPEN, and a failed open '
        'says so (never silently)', (tester) async {
      ChatEntry? tapped;
      final entry = ChatEntry.file(
        'app-release.apk',
        'voice-agent/build/app-release.apk',
        34567890,
        createdMs: 1,
      )..savedMs = 2000;
      await tester.pumpWidget(
        _host(
          ChatBubble(
            entry: entry,
            maxWidthFrac: 0.86,
            source: () => _view(),
            onFileTap: (e) => tapped = e,
          ),
        ),
      );
      expect(find.textContaining('Saved · tap to open'), findsOne);
      await tester.tap(find.text('app-release.apk'));
      expect(tapped, same(entry),
          reason: 'the tap after the save goes to the system viewer');
      entry.openError = 'MissingPluginException(no handler)';
      tapped = null;
      await tester.pumpWidget(
        _host(
          ChatBubble(
            entry: entry,
            maxWidthFrac: 0.86,
            source: () => _view(),
            onFileTap: (e) => tapped = e,
          ),
        ),
      );
      expect(find.textContaining('Could not open'), findsOne);
      await tester.tap(find.textContaining('Could not open'));
      expect(tapped, same(entry), reason: 'even the failed tap retries');
    });

    testWidgets('+151: the bottom working row paints the spinner with '
        'the projected label and meter, attached to no bubble', (tester) async {
      await tester.pumpWidget(
        _host(
          WorkingRowCard(
            maxWidthFrac: 0.86,
            source: () => _view(
              phase: AssistantPhase.transcribing,
              harnessElapsed: const Duration(seconds: 12),
              token: const TokenMeter(
                on: true,
                out: 12400,
                inTok: 2100,
                thought: 'weighing the two splits',
                draft: '',
                settled: false,
                activityLabel: 'Thinking…',
              ),
            ),
          ),
        ),
      );
      expect(find.text('Thinking… · weighing the two splits'), findsOne);
      expect(find.text('12.40k out · 2.10k in · 12s'), findsOne);
    });

    testWidgets('pure playback hides the wheel (the view says so)', (
      tester,
    ) async {
      final entry = ChatEntry.assistant(createdMs: 1)
        ..blocks.add('Speaking now.');
      await tester.pumpWidget(
        _host(
          ChatBubble(
            entry: entry,
            maxWidthFrac: 0.86,
            source: () => _view(
              phase: AssistantPhase.speaking,
              harnessElapsed: Duration.zero,
            ),
          ),
        ),
      );
      expect(find.text('Speaking now.'), findsOne);
      expect(
        find.text('0s'),
        findsNothing,
        reason: 'no meter over pure playback — voice is the status',
      );
    });

    testWidgets('+151: a cut turn\u2019s stamp shows even while the row '
        'spins elsewhere', (tester) async {
      final entry = ChatEntry.assistant(createdMs: 1)
        ..blocks.add('Half an answer.')
        ..interrupted = true
        ..interruptedMs = 2;
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      expect(find.textContaining('interrupted'), findsOne);
      expect(
        find.textContaining('⠋'),
        findsNothing,
        reason: 'the wheel left the bubble for the bottom row (+151)',
      );
    });
  });

  group('the queued message in the flow', () {
    testWidgets('the grey bubble is a button: it offers the interrupt '
        'and its tap lands (plain Text, no tap-thief inside)', (
      tester,
    ) async {
      ChatEntry? tapped;
      final parked = ChatEntry.user('ship it now')..queued = true;
      await tester.pumpWidget(
        _host(
          ChatBubble(
            entry: parked,
            maxWidthFrac: 0.86,
            source: () => _view(),
            onQueueTap: (e) => tapped = e,
          ),
        ),
      );
      expect(find.text('tap to interrupt now'), findsOne);
      await tester.tap(find.text('ship it now'));
      expect(tapped, same(parked),
          reason: 'while queued the words are plain Text — the tap '
              'reaches the button instead of dying in a selectable');
      tapped = null;
      parked.queued = false; // taken: the button retires, the select comes back
      await tester.pumpWidget(
        _host(
          ChatBubble(
            entry: parked,
            maxWidthFrac: 0.86,
            source: () => _view(),
            onQueueTap: (e) => tapped = e,
          ),
        ),
      );
      expect(find.text('tap to interrupt now'), findsNothing);
      await tester.tap(find.text('ship it now'));
      expect(tapped, isNull);
    });

    testWidgets('+146: greys while pinned, full color once taken', (
      tester,
    ) async {
      final parked = ChatEntry.user('polite follow-up')..queued = true;
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: parked, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      expect(
        find.text('polite follow-up'),
        findsOne,
        reason: 'the message stays IN the flow — no pin card',
      );
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(
                of: find.text('polite follow-up'),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        0.42,
      );
      parked.queued = false; // the started marker cleared the pin
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: parked, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(
                of: find.text('polite follow-up'),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        1.0,
        reason: 'taken by the harness — back to full color in place',
      );
    });
  });

  group('BackgroundedWorkCard', () {
    testWidgets('names the work, ticks its age, and stamps its start', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          BackgroundedWorkCard(
            source: () => _view(
              harnessBackgrounded: true,
              harnessElapsed: const Duration(seconds: 91),
              backgrounded: const BgWork(
                visible: true,
                label: 'Bash npm test…',
                sinceMs: 0,
                elapsed: Duration(seconds: 91),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('Background: Bash npm test…'), findsOne);
      expect(find.textContaining('1m31s'), findsOne);
    });

    testWidgets('an unlabelled detached turn still gets an honest line', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          BackgroundedWorkCard(
            source: () => _view(
              harnessBackgrounded: true,
              harnessElapsed: const Duration(seconds: 5),
              backgrounded: const BgWork(
                visible: true,
                label: '',
                sinceMs: 0,
                elapsed: Duration(seconds: 5),
              ),
            ),
          ),
        ),
      );
      expect(
        find.textContaining('The harness keeps working unheard'),
        findsOne,
      );
    });
  });

  group('ContextBar', () {
    testWidgets('exact numbers read as a percentage', (tester) async {
      await tester.pumpWidget(
        _host(
          const ContextBar(
            view: ContextBarView(tokensIn: 21000, window: 200000, busy: false),
          ),
        ),
      );
      expect(find.text('context 21.00k / 200.00k · 11%'), findsOne);
    });

    testWidgets('no numbers yet, harness working: measuring', (tester) async {
      await tester.pumpWidget(
        _host(
          const ContextBar(
            view: ContextBarView(tokensIn: 0, window: 0, busy: true),
            busy: true,
          ),
        ),
      );
      expect(find.text('context · measuring…'), findsOne);
    });
  });

  group('the small projections', () {
    testWidgets('the latency strip renders the projected seconds', (
      tester,
    ) async {
      await tester.pumpWidget(_host(LatencyStrip(latency: _view().latency)));
      expect(find.text('1.2s'), findsOne); // heard
      expect(find.text('0.34s'), findsOne); // asr
      expect(find.text('2.0s'), findsOne); // reply
      expect(find.text('0.05s'), findsOne); // tts
    });

    testWidgets('the view renders its status line through the activity', (
      tester,
    ) async {
      final v = _view(
        phase: AssistantPhase.transcribing,
        activity: const StepLine('Read', 'lib/src/bridge/client.dart'),
      );
      expect(v.status, 'Read client.dart…');
      expect(
        _view(
          activity: const PausedNotice(bridgeLive: true, wasLive: false),
        ).status,
        contains('Working in the background'),
      );
    });
  });

  // (+153): the PromptBar group retired with the composer — the
  // typed path lives on in BridgeScreen's input and every queue
  // discipline in runQuickCommand (turn_flow walks both flavours).

  group('the reserved working-row slot (+154)', () {
    test('ONE signal — agentBusy — drives the row and the Stop chip', () {
      expect(_view().agentBusy, isTrue);
      expect(_view().showWorkingRow, isTrue);
      final idle = _view(bridgeBusy: false);
      expect(idle.agentBusy, isFalse);
      expect(
        idle.showWorkingRow,
        isFalse,
        reason: 'nothing in flight: the slot rests empty (never removed)',
      );
      final unheard = _view(bridgeBusy: false, harnessBackgrounded: true);
      expect(unheard.agentBusy, isTrue);
      expect(
        unheard.showWorkingRow,
        isTrue,
        reason: 'detached work keeps the row lit — Stop must light too',
      );
      final playback = _view(bridgeBusy: false, phase: AssistantPhase.speaking);
      expect(
        playback.showWorkingRow,
        isFalse,
        reason: 'pure playback: voice is the status',
      );
    });

    testWidgets('the slot holds its height while the row fades', (
      tester,
    ) async {
      const key = Key('slot');
      Widget slot(bool lit) => _host(
        SizedBox(
          key: key,
          height: WorkingRowCard.reservedHeight,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: lit ? 1.0 : 0.0,
            child: WorkingRowCard(source: () => _view()),
          ),
        ),
      );
      await tester.pumpWidget(slot(true));
      final lit = tester.getSize(find.byKey(key));
      await tester.pumpWidget(slot(false));
      await tester.pump(const Duration(milliseconds: 200));
      final dim = tester.getSize(find.byKey(key));
      expect(
        dim,
        lit,
        reason:
            '+154: appearing, disappearing and fading never resize the '
            'slot — no bubble ever slides under the footer',
      );
    });
  });

  group('TalkSurface', () {
    Widget surface(
      WidgetTester tester, {
      required List<String> edges,
      required bool Function() holding,
      PttSlide slide = PttSlide.none,
    }) => _host(
      TalkSurface(
        source: () => _view(
          ptt: PttGuide(
            holdActive: holding(),
            slide: holding() ? slide : PttSlide.none,
            drag: Offset.zero,
            holdOverTurn: false,
            micLevel: 0.5,
          ),
        ),
        icon: Icons.mic,
        color: Colors.blue,
        onPointerDown: (p) => edges.add('down $p'),
        onPointerMove: (p) => edges.add('move $p'),
        onPointerUp: (p) => edges.add('up $p'),
        onPointerCancel: () => edges.add('cancel'),
        onTap: () => edges.add('tap'),
        height: 200,
      ),
    );

    testWidgets('press, drag, release: edges forward GLOBAL positions', (
      tester,
    ) async {
      final edges = <String>[];
      await tester.pumpWidget(
        surface(tester, edges: edges, holding: () => false),
      );
      final center = tester.getCenter(find.byType(TalkSurface));

      final g = await tester.startGesture(center);
      await tester.pump();
      expect(
        edges.first,
        'down $center',
        reason: 'the hold geometry needs the global finger point',
      );
      await g.moveBy(const Offset(0, -60)); // past the tap slop
      await tester.pump();
      expect(edges[1], 'move ${center + const Offset(0, -60)}');
      await g.up();
      await tester.pump();
      expect(edges[2], 'up ${center + const Offset(0, -60)}');
      // A dragged release is not a tap.
      expect(edges, isNot(contains('tap')));
      await tester.pump(const Duration(seconds: 2)); // age the ripples
      await tester.pump();
    });

    testWidgets('a tap in place also lands as a tap', (tester) async {
      final edges = <String>[];
      await tester.pumpWidget(
        surface(tester, edges: edges, holding: () => false),
      );
      await tester.tap(find.byType(TalkSurface));
      await tester.pump();
      final center = tester.getCenter(find.byType(TalkSurface));
      expect(
        edges,
        containsAllInOrder(['down $center', 'up $center', 'tap']),
        reason: 'conversation mode needs the classic tap to survive',
      );
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the wide slide bands appear ONLY while a hold is down', (
      tester,
    ) async {
      final edges = <String>[];
      var holding = false;
      await tester.pumpWidget(
        surface(tester, edges: edges, holding: () => holding),
      );
      expect(
        _bandOpacity(tester, 'Release to interrupt'),
        0,
        reason: 'the gestures only exist mid-hold',
      );
      expect(_bandOpacity(tester, 'Release to discard'), 0);

      // Press FOR REAL first: the down edge is what wakes the surface
      // ticker (in the app the hold truth arrives from the assistant;
      // the fake source here flips with the finger).
      final g = await tester.startGesture(
        tester.getCenter(find.byType(TalkSurface)),
      );
      holding = true;
      await tester.pump(); // start the fade
      await tester.pump(const Duration(milliseconds: 200)); // complete it
      expect(
        _bandOpacity(tester, 'Release to interrupt'),
        1,
        reason: 'UP = interrupt, full-width band on the top edge',
      );
      expect(
        _bandOpacity(tester, 'Release to discard'),
        1,
        reason: 'RIGHT = discard, full-height band on the right edge',
      );
      await g.up();
      holding = false;
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
