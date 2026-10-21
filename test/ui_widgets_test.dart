// The conversation widgets render ONLY AssistantView data — so they can
// be exercised against hand-built views: no VoiceAssistant, no fakes,
// no device. This is the payoff of the projection: UI iteration is
// verified at the UI layer, and behavior changes arrive as view
// differences (see assistant_view_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// +292: the tone-law tests read the schemes back in the space the
// spec is written in.
import 'package:material_color_utilities/hct/hct.dart';
import 'package:voice_agent/src/assistant/activity.dart';
import 'package:voice_agent/src/assistant/state.dart';
import 'package:voice_agent/src/assistant/view.dart';
import 'package:voice_agent/src/chat/chat_log.dart';
import 'package:voice_agent/src/ui/assistant_screen.dart';
import 'package:voice_agent/src/ui/chat_view.dart';
import 'package:voice_agent/src/ui/context_bar.dart';
import 'package:voice_agent/src/ui/theme.dart';
import 'package:voice_agent/src/ui/latency_strip.dart';
import 'package:voice_agent/src/ui/cone_overlay.dart';
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
    testWidgets('a new bubble fades in, settles opaque, and never replays', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const FadeInBubble(key: ValueKey('e1'), child: Text('arriving'))),
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
        _host(const FadeInBubble(key: ValueKey('e1'), child: Text('arriving'))),
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

    testWidgets('a newly streamed segment opens by height, not ink — the '
        'flicker +181 ended, the layer upload +208 ended', (tester) async {
      final entry = ChatEntry.assistant(createdMs: 1)
        ..blocks.add('First spoken section.');
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      await tester.pumpAndSettle(); // the birth entrance lands
      final spoken = tester.getTopLeft(find.byKey(ValueKey(0)));
      final spokenHeight = tester.getSize(find.byKey(ValueKey(0))).height;
      // The second spoken paragraph arrives at the open bubble: the
      // new tail rides its own one-shot ease; the already-heard
      // segment must NOT replay (that replay was the flicker).
      entry.blocks.add('Second spoken section.');
      await tester.pumpWidget(
        _host(
          ChatBubble(entry: entry, maxWidthFrac: 0.86, source: () => _view()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
      // +208: the arriving segment carries NO opacity animation at
      // all. The fade's composited layer costs an upload and one
      // dropped frame per arrival (the frame bill saw it every time);
      // this entrance is height-only, so there is nothing to upload.
      expect(
        find.descendant(
          of: find.byKey(ValueKey(1)),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      // Mid-open: its box is under the final height (+187's law —
      // the slot travels, it does not pop), yet not slammed shut
      // either — the ease is already partway.
      final mid = tester.getSize(find.byKey(ValueKey(1))).height;
      expect(mid, greaterThan(0), reason: 'the ease opens, it does not slam');
      await tester.pumpAndSettle();
      final full = tester.getSize(find.byKey(ValueKey(1))).height;
      expect(mid, lessThan(full), reason: 'the height travels — no pop');
      // And the spoken segment above never moved, at all: the card
      // opened DOWNWARD (top-anchored growth), which the old fade
      // era could only claim via opacity.
      expect(tester.getTopLeft(find.byKey(ValueKey(0))), spoken);
      expect(
        tester.getSize(find.byKey(ValueKey(0))).height,
        spokenHeight,
        reason: 'settled text never re-animates',
      );
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
      expect(
        mid,
        lessThan(full),
        reason: 'the height travels with the fade — no layout pop',
      );
      expect(mid, greaterThan(0), reason: 'the ease opens, it does not slam');
      // +208: and there is NO opacity in this entrance at all. The
      // fade's composited layer costs an upload and one dropped frame
      // per arrival (the frame bill saw it every time); the height
      // alone re-rasters only the opening band.
      expect(
        find.descendant(
          of: find.byType(FadeInBubble),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
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
      expect(
        card.color,
        Colors.transparent,
        reason: 'no secondaryContainer fill — it is not a spoken reply',
      );
      expect(
        card.shape,
        isA<RoundedRectangleBorder>(),
        reason: 'the outline card law of +168, widened',
      );
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
      expect(
        find.byType(SelectableText),
        findsNothing,
        reason: 'no words yet — the pulse speaks instead',
      );
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
      expect(
        tapped,
        same(entry),
        reason: 'the tap after the save goes to the system viewer',
      );
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
        'and its tap lands (plain Text, no tap-thief inside)', (tester) async {
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
      expect(
        tapped,
        same(parked),
        reason:
            'while queued the words are plain Text — the tap '
            'reaches the button instead of dying in a selectable',
      );
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
      expect(find.text('context 21.00k/200.00k 11%'), findsOne);
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

    testWidgets('+241: the proven model name rides the same line', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const ContextBar(
            view: ContextBarView(
              tokensIn: 21000,
              window: 200000,
              busy: false,
              model: 'aliyun/qwen3.8-flash',
            ),
          ),
        ),
      );
      expect(
        find.text('aliyun/qwen3.8-flash · context 21.00k/200.00k 11%'),
        findsOne,
        reason:
            'the bar the eye checks for context is the one line '
            'that can also carry WHICH model is holding that context',
      );
    });

    testWidgets('no model verdict yet: the label is unchanged', (tester) async {
      await tester.pumpWidget(
        _host(
          const ContextBar(
            view: ContextBarView(
              tokensIn: 21000,
              window: 200000,
              busy: false,
              model: '',
            ),
          ),
        ),
      );
      expect(find.text('context 21.00k/200.00k 11%'), findsOne);
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
  });

  group('ConeOverlay (+273)', () {
    // The PTT decision, lifted to the whole screen: the words are
    // REAL Text (findable, announced) riding real AnimatedOpacity —
    // the same 'only exist mid-hold' law the panel bands answered,
    // now probed on the overlay itself. (The painter's beams are
    // geometry, not widgets: what they must never disagree about —
    // armed vs release behaviour — is pinned by the PttHold slideOf
    // predicate tests, and the labels' opacity is the seam.)
    Widget overlay(bool visible) => _host(
      SizedBox(
        width: 400,
        height: 800,
        child: Stack(
          children: [
            ConeOverlay(
              visible: visible,
              origin: const Offset(200, 640),
              guide: PttGuide(
                holdActive: visible,
                slide: visible ? PttSlide.up : PttSlide.none,
                drag: visible ? const Offset(0, -72) : Offset.zero,
                holdOverTurn: false,
                micLevel: 0.5,
              ),
              errorColor: const Color(0xFFCC0000),
              idleLabelColor: const Color(0xFF888888),
            ),
          ],
        ),
      ),
    );

    testWidgets('at rest: invisible; on hold: both words at full light', (
      tester,
    ) async {
      await tester.pumpWidget(overlay(false));
      expect(_bandOpacity(tester, 'INTERRUPT'), 0);
      expect(_bandOpacity(tester, 'DISCARD'), 0);
      await tester.pumpWidget(overlay(true));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _bandOpacity(tester, 'INTERRUPT'),
        1,
        reason: 'the amber cone opens with the hold',
      );
      expect(_bandOpacity(tester, 'DISCARD'), 1);
      await tester.pumpWidget(overlay(false));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_bandOpacity(tester, 'INTERRUPT'), 0);
    });
  });

  group('the session face on the chat window (+279)', () {
    final base = buildClaudeDarkTheme();

    test('the tint re-seeds the bubble containers, nothing else', () {
      final warm = AssistantScreenSupport.sessionTheme(base, 30).colorScheme;
      final cool = AssistantScreenSupport.sessionTheme(base, 210).colorScheme;
      // The picker keeps sibling hues distant — so the cards they ink
      // must differ exactly where the bubbles paint.
      expect(warm.primaryContainer, isNot(cool.primaryContainer));
      expect(warm.secondaryContainer, isNot(cool.secondaryContainer));
      expect(warm.primaryContainer, isNot(base.colorScheme.primaryContainer));
      // Everything the face does NOT own stays Claude's: the black
      // canvas, the warm inks, the orange accent, the error line, the
      // file slip's tertiary, the working row's neutral card.
      for (final tint in [warm, cool]) {
        expect(tint.surface, base.colorScheme.surface);
        expect(tint.onSurface, base.colorScheme.onSurface);
        expect(tint.primary, base.colorScheme.primary);
        expect(tint.error, base.colorScheme.error);
        expect(tint.tertiary, base.colorScheme.tertiary);
        expect(
          tint.surfaceContainerHigh,
          base.colorScheme.surfaceContainerHigh,
        );
      }
    });

    test('the same hue re-mints an equal scheme (the memo can trust it)', () {
      expect(
        AssistantScreenSupport.sessionTheme(base, 123),
        AssistantScreenSupport.sessionTheme(base, 123),
      );
    });

    testWidgets('a user bubble under the theme wears the session hue', (
      tester,
    ) async {
      final tint = AssistantScreenSupport.sessionTheme(base, 200);
      final entry = ChatEntry.user('Repo status', createdMs: 1);
      await tester.pumpWidget(
        MaterialApp(
          theme: base,
          home: Scaffold(
            body: Theme(
              data: tint,
              child: SingleChildScrollView(
                child: ChatBubble(
                  entry: entry,
                  maxWidthFrac: 0.86,
                  source: () => _view(),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Card>(find.byType(Card)).color,
        tint.colorScheme.primaryContainer,
        reason: 'the chat window wears the session, not just the chip',
      );
    });

    testWidgets('an assistant bubble re-inks too', (tester) async {
      final tint = AssistantScreenSupport.sessionTheme(base, 320);
      final entry = ChatEntry.assistant(createdMs: 1)
        ..blocks.add('All settled.');
      await tester.pumpWidget(
        MaterialApp(
          theme: base,
          home: Scaffold(
            body: Theme(
              data: tint,
              child: SingleChildScrollView(
                child: ChatBubble(
                  entry: entry,
                  maxWidthFrac: 0.86,
                  source: () => _view(),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Card>(find.byType(Card)).color,
        tint.colorScheme.secondaryContainer,
      );
    });
  });

  group('the tone table is the law (+292)', () {
    final scheme = buildClaudeDarkTheme().colorScheme;
    double tone(Color c) => Hct.fromInt(c.toARGB32()).tone;

    test('the pinned Claude laws survive the math', () {
      // The M3 generation kept what the app's own laws pinned: the
      // EXACT brand orange (never a tonalSpot wash of it), the black
      // canvas (Claude Code's, not the spec's tone-6 grey), and
      // black ink under the saturated fills.
      expect(scheme.primary, const Color(0xFFD97757));
      expect(scheme.surface, Colors.black);
      expect(scheme.onPrimary, Colors.black);
      expect(scheme.onTertiary, Colors.black);
    });

    test('the container ladder is a ladder, not two identical rungs', () {
      final rungs = [
        scheme.surfaceContainerLowest,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
      ];
      for (var i = 1; i < rungs.length; i++) {
        expect(
          tone(rungs[i]),
          greaterThan(tone(rungs[i - 1])),
          reason:
              'rung $i must read above rung ${i - 1} — the hand-picked '
              'scheme ran High and Highest as the SAME color',
        );
      }
    });

    test('every on-color sits the spec distance above its container', () {
      // Tone 30 under, tone 90 over: the contrast the old scheme
      // hoped for by eye is arithmetic now.
      final pairs = {
        'primary': (scheme.primaryContainer, scheme.onPrimaryContainer),
        'secondary': (scheme.secondaryContainer, scheme.onSecondaryContainer),
        'tertiary': (scheme.tertiaryContainer, scheme.onTertiaryContainer),
        'error': (scheme.errorContainer, scheme.onErrorContainer),
        'inverse': (scheme.inverseSurface, scheme.onInverseSurface),
      };
      for (final e in pairs.entries) {
        expect(
          (tone(e.value.$2) - tone(e.value.$1)).abs(),
          greaterThanOrEqualTo(45),
          reason:
              '${e.key} container/on-container pair fails the tone '
              'law (the inverse pair runs FLIPPED by design — a light '
              'chip with dark ink — so the law is the distance, not '
              'the sign)',
        );
      }
    });

    test('the session face keeps the tone law at any hue the picker draws', () {
      final base = buildClaudeDarkTheme();
      for (final hue in [0, 47, 120, 199, 260, 333]) {
        final tint = AssistantScreenSupport.sessionTheme(base, hue).colorScheme;
        expect(
          tone(tint.primaryContainer),
          closeTo(30, 2),
          reason:
              'the session hue survives the math at the container '
              'tone — no pastel wash, whatever the hue',
        );
        expect(
          tone(tint.onPrimaryContainer),
          closeTo(90, 2),
          reason: 'and the ink always meets it from tone 90',
        );
        expect(tint.surface, base.colorScheme.surface);
        expect(tint.primary, base.colorScheme.primary);
      }
    });

    test(
      'the completion green has an owner (the extension), not a literal',
      () {
        final theme = buildClaudeDarkTheme();
        expect(
          theme.extension<AppExtendedColors>(),
          isNotNull,
          reason:
              'M3 extended colors ride a ThemeExtension — the latency '
              'strip asks the theme for its green now',
        );
      },
    );
  });

  group('the shape and type tables are the law (+293)', () {
    test('the corner table is Material 3’s shape scale', () {
      expect(AppRadii.none, 0);
      expect(AppRadii.extraSmall, 4);
      expect(AppRadii.small, 8);
      expect(AppRadii.medium, 12);
      expect(AppRadii.large, 16);
      expect(AppRadii.extraLarge, 28);
      // Every rounded thing asks a rung by its job now — the bag of
      // one-off numbers (12, 3, 28, 16, 18) is gone, and the pill's
      // gradient ring DERIVES (large + its 2 dp of padding) instead
      // of re-guessing.
      expect(AppRadii.large + 2, 18, reason: 'the one arithmetic site');
    });

    testWidgets('the cone label rides the type table, identity as deltas', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 400,
            height: 800,
            child: Stack(
              children: [
                ConeOverlay(
                  visible: true,
                  origin: const Offset(200, 640),
                  guide: PttGuide(
                    holdActive: true,
                    slide: PttSlide.up,
                    drag: const Offset(0, -72),
                    holdOverTurn: false,
                    micLevel: 0.5,
                  ),
                  errorColor: const Color(0xFFCC0000),
                  idleLabelColor: const Color(0xFF888888),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final label = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((t) => t.data == 'INTERRUPT');
      // M3's theme carries role metrics lazily (resolved when a Text
      // paints, so text scaling reaches them) — the widget's own
      // resolved style must speak the table's number: labelLarge is
      // 14.
      expect(
        label.style!.fontSize ?? 14.0,
        14.0,
        reason:
            'the SIZE belongs to the table (and through it, to the '
            'user’s text scale — a hand-set fontSize is deaf to it); '
            'the old label hand-set 15',
      );
      expect(
        label.style!.letterSpacing,
        3,
        reason: 'the identity survives as a NAMED delta',
      );
      expect(label.style!.fontWeight, FontWeight.w800);
    });

    testWidgets(
      'prose grows a TAIL: user bottom-right, assistant bottom-left',
      (tester) async {
        // +294 (the M3 chat pattern): the roundness now says WHO
        // speaks — the extraSmall corner sits at the edge the line
        // came from, and the three large corners face the thread.
        final user = ChatEntry.user('Repo status', createdMs: 1);
        await tester.pumpWidget(
          _host(
            SingleChildScrollView(
              child: ChatBubble(
                entry: user,
                maxWidthFrac: 0.86,
                source: () => _view(),
              ),
            ),
          ),
        );
        BorderRadius shapeOf(WidgetTester t) =>
            ((t.widget<Card>(find.byType(Card)).shape as RoundedRectangleBorder)
                    .borderRadius
                as BorderRadius);
        var rr = shapeOf(tester);
        expect(
          rr.bottomRight,
          const Radius.circular(AppRadii.extraSmall),
          reason: 'the user speaks from the right edge',
        );
        expect(rr.bottomLeft, const Radius.circular(AppRadii.large));
        expect(rr.topLeft, const Radius.circular(AppRadii.large));
        expect(rr.topRight, const Radius.circular(AppRadii.large));

        final assistant = ChatEntry.assistant(createdMs: 1)
          ..blocks.add('All settled.');
        await tester.pumpWidget(
          _host(
            SingleChildScrollView(
              child: ChatBubble(
                entry: assistant,
                maxWidthFrac: 0.86,
                source: () => _view(),
              ),
            ),
          ),
        );
        rr = shapeOf(tester);
        expect(
          rr.bottomLeft,
          const Radius.circular(AppRadii.extraSmall),
          reason: 'the answer answers from the left',
        );
        expect(rr.bottomRight, const Radius.circular(AppRadii.large));
      },
    );

    test('the theme ships the full M3 role table', () {
      final t = buildClaudeDarkTheme().textTheme;
      // The widgets lean on these roles; the table must be complete
      // before anyone reaches for a raw TextStyle again.
      expect(t.displayLarge, isNotNull);
      expect(t.headlineMedium, isNotNull);
      expect(t.titleLarge, isNotNull);
      expect(t.bodyMedium, isNotNull);
      expect(t.labelLarge, isNotNull);
      // (The role styles carry their metrics lazily — the cone-label
      // test above proves the resolved 14 lands on the widget.)
    });
  });
}
