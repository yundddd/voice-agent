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
import 'package:voice_agent/src/ui/ptt_hold_guide.dart';

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
  liveTurnBubble: null,
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

void main() {
  group('ChatBubble', () {
    testWidgets('a user bubble shows its text', (tester) async {
      final entry = ChatEntry.user('Repo status', createdMs: 1);
      await tester.pumpWidget(
        _host(
          ChatBubble(
            entry: entry,
            isLiveTurn: false,
            maxWidthFrac: 0.86,
            source: () => _view(),
          ),
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
          ChatBubble(
            entry: entry,
            isLiveTurn: false,
            maxWidthFrac: 0.86,
            source: () => _view(),
          ),
        ),
      );
      expect(find.text('First heard section.'), findsOne);
      expect(find.textContaining('interrupted'), findsOne);
    });

    testWidgets('the live turn paints the spinner with the projected '
        'label and meter', (tester) async {
      final entry = ChatEntry.assistant(createdMs: 1);
      await tester.pumpWidget(
        _host(
          ChatBubble(
            entry: entry,
            isLiveTurn: true,
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
            isLiveTurn: true,
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
  });

  group('QueuedBubbleCard', () {
    testWidgets('the pin names itself and carries the press', (tester) async {
      await tester.pumpWidget(
        _host(
          const QueuedBubbleCard(
            text: 'polite follow-up',
            createdMs: 0,
            maxWidthFrac: 0.86,
          ),
        ),
      );
      expect(find.textContaining('Queued — waiting'), findsOne);
      expect(find.text('polite follow-up'), findsOne);
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

    testWidgets('the hold guide lights the armed slide from the view', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PttHoldGuide(
            guide: const PttGuide(
              holdActive: true,
              slide: PttSlide.up,
              drag: Offset(0, -52),
              holdOverTurn: true,
            ),
            icon: Icons.mic,
            color: Colors.red,
            onPrimary: Colors.white,
            onPressed: () {},
          ),
        ),
      );
      expect(find.text('Interrupt'), findsOne);
      expect(find.text('Cancel'), findsOne);
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
}
