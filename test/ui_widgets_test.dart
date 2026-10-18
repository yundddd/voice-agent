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
import 'package:voice_agent/src/ui/prompt_bar.dart';
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
  bool harnessBackgrounded = false,
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
  bridgeBusy: true,
  harnessBackgrounded: harnessBackgrounded,
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

  group('PromptBar', () {
    late List<(String, bool)> sent;
    Widget bar() => _host(
      PromptBar(onSend: (t, {required interrupt}) => sent.add((t, interrupt))),
    );
    // Located by ICON, not tooltip: a disabled button's tooltip subtree
    // is not a finder guarantee, the button's own icon is.
    IconButton btn(WidgetTester tester, IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));
    const queueTip =
        'Queue \u2014 polite behind the current turn '
        '(a running tool finishes first)';
    const cutTip = 'Interrupt \u2014 cut the thinking turn, this goes now';

    setUp(() => sent = []);

    testWidgets('the two buttons are the two queue flavours', (tester) async {
      await tester.pumpWidget(bar());
      await tester.enterText(find.byType(TextField), '  run the tests  ');
      await tester.pump();

      await tester.tap(find.byTooltip(queueTip));
      await tester.pump();
      expect(sent, [
        ('run the tests', false),
      ], reason: 'queue = interrupt:false: parks behind the running work');

      await tester.enterText(find.byType(TextField), 'stop that');
      await tester.pump();
      await tester.tap(find.byTooltip(cutTip));
      await tester.pump();
      expect(sent[1], (
        'stop that',
        true,
      ), reason: 'interrupt = the /talk interrupt flag');
      expect(
        find.widgetWithText(TextField, 'stop that'),
        findsNothing,
        reason: 'the field clears after a send (it already became a bubble)',
      );
    });

    testWidgets('empty text cannot send; Enter means Interrupt', (
      tester,
    ) async {
      await tester.pumpWidget(bar());
      expect(
        btn(tester, Icons.schedule).onPressed,
        isNull,
        reason: 'nothing typed: no send',
      );

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      expect(btn(tester, Icons.schedule).onPressed, isNotNull);

      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(sent.single, (
        'hello',
        true,
      ), reason: 'the keyboard send is the right-hand flavour');
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
