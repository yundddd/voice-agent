import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'assistant.dart';
import 'bridge.dart';
import 'bridge_screen.dart';
import 'voice_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await sherpa_onnx.initBindingsAsync();
  runApp(const VoiceAgentApp());
}

class VoiceAgentApp extends StatelessWidget {
  const VoiceAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Agent',
      // The official Claude dark palette: pure-black canvas with the
      // #D97757 Claude orange as the accent (same family as the chat
      // window's harness spinner). Forced dark — the mimicry is the
      // point, so system light mode must not wash it back to Material
      // default; with no darkTheme set, `theme` is the whole app.
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        // fromSeed tonally shifts the seed, so its `primary` would be a
        // pastel wash of orange rather than the real #D97757. Pin the
        // roles the UI actually draws (primary/onPrimary for buttons and
        // the mic, tertiary for the listening glyph, the warm greys for
        // chips, borders and secondary text) to hand-picked Claude Code
        // values instead: black canvas, true Claude orange, warm-neutral
        // ink.
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: const Color(0xFFD97757),
              brightness: Brightness.dark,
            ).copyWith(
              surface: Colors.black, // scaffold, appbar, dialogs
              background: Colors.black,
              onSurface: const Color(0xFFF0EDE6), // warm near-white
              onBackground: const Color(0xFFF0EDE6),
              primary: const Color(0xFFD97757), // official Claude orange
              onPrimary: Colors.black,
              primaryContainer: const Color(0xFF41231A),
              onPrimaryContainer: const Color(0xFFF2B89B),
              secondary: const Color(0xFFE0A183),
              onSecondary: Colors.black,
              secondaryContainer: const Color(0xFF5A3427),
              onSecondaryContainer: const Color(0xFFF2B89B),
              // Same orange family (dusty copper): the app is black-and-
              // orange, so the listening indicator must not drift off-hue.
              tertiary: const Color(0xFFC97A55),
              onTertiary: Colors.black,
              surfaceContainer: const Color(0xFF14110E),
              surfaceContainerHigh: const Color(0xFF1F1B16),
              surfaceContainerHighest: const Color(0xFF1F1B16),
              outline: const Color(0xFF7A6F63), // warm grey text/borders
              outlineVariant: const Color(0xFF3A342C),
              onSurfaceVariant: const Color(0xFFB3AA9C),
            ),
      ),
      home: const AssistantScreen(),
    );
  }
}

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen>
    with WidgetsBindingObserver {
  static const _chipIcons = {
    '/new': Icons.restart_alt, // same glyph as the settings-page reset
    '/compact': Icons.compress,
  };

  final VoiceAssistant _assistant = VoiceAssistant();
  bool _debugMode = false;
  final ScrollController _scroll = ScrollController();
  int _seenChatVersion = 0; // drives auto-follow while chat grows

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _assistant
      ..addListener(() => setState(() {}))
      ..init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _assistant.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Raw OS state into the journal BEFORE the folding below: the exact
    // order of these callbacks (hidden+paused on the way down, hidden
    // again on the way up) is half of what a resume bug triage is about.
    _assistant.logLifecycle(state.name);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _assistant.pauseConversation();
      case AppLifecycleState.resumed:
        unawaited(_assistant.resumeConversation());
      case AppLifecycleState.inactive:
        break; // transient (notification shade, permission prompt)
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _assistant;
    final scheme = Theme.of(context).colorScheme;

    // Auto-follow the conversation: when the log grows (new bubble or a
    // new spoken section), pin the scroll to the bottom (post-frame: the
    // new height exists only after layout). A deliberate scroll-up to
    // re-read history stops the follow until the next stream event.
    if (a.chatVersion != _seenChatVersion) {
      _seenChatVersion = a.chatVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (!_scroll.position.outOfRange) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }

    // The in-flight harness turn: while a bridge turn runs, its bubble is
    // the last (possibly still empty) assistant entry — where the Claude
    // Code-style working line (below the last spoken block) gets painted.
    final liveTurn = a.bridgeBusy && a.chat.isNotEmpty && !a.chat.last.fromUser
        ? a.chat.last
        : null;

    final (icon, color) = switch ((a.phase, a.userSpeaking)) {
      (AssistantPhase.error, _) => (Icons.error_outline, scheme.error),
      (AssistantPhase.listening, true) => (Icons.graphic_eq, scheme.tertiary),
      (AssistantPhase.listening, false) => (Icons.mic, scheme.error),
      (AssistantPhase.transcribing, _) => (
        Icons.psychology_alt,
        scheme.primary,
      ),
      (AssistantPhase.speaking, _) => (Icons.volume_up, scheme.primary),
      (AssistantPhase.idle, _) => (Icons.mic_none, scheme.primary),
    };

    final (fabEnabled, hint) = switch (a.mode) {
      InteractionMode.pushToTalk => switch (a.phase) {
        // A hold that opened over a harness turn (pttDown detached it
        // into the background — the tool call keeps working): the
        // release gesture routes the new prompt.
        AssistantPhase.listening => (
          true,
          // Past a slide threshold the hint stops teaching and confirms:
          // it names what releasing NOW does (the lit pill beside the
          // button says the same with an arrow).
          switch (a.pttSlide) {
            PttSlide.up => 'Release to interrupt',
            PttSlide.right => 'Release to discard',
            PttSlide.none => a.pttHoldOverTurn
                ? 'Release to queue — up to interrupt — right to dismiss'
                : 'Release to send — right to dismiss',
          },
        ),
        AssistantPhase.transcribing || AssistantPhase.speaking => (
          true,
          // A press now records over the harness too: short tap = hard
          // stop, a hold queues (slide up cuts a thinking turn; an open
          // tool always finishes first — your message goes next).
          a.bridgeBusy
              ? 'Working — press and hold to steer'
              : 'Interrupt — press and talk',
        ),
        _ => (
          true,
          a.harnessBackgrounded
              ? 'Hold to talk — the harness keeps working unheard'
              : 'Hold to talk',
        ),
      },
      InteractionMode.conversation => switch (a.phase) {
        AssistantPhase.listening => (true, 'End conversation'),
        AssistantPhase.transcribing || AssistantPhase.speaking => (
          true,
          a.bridgeBusy ? 'Stop the harness' : 'Stop my reply',
        ),
        _ => (true, 'Start conversation'),
      },
    };

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Voice Agent'),
            // The conversation's fingerprint, directly under the title: a
            // steady id across many talks is the continuity proof (the
            // bridge --resume's this one after its own restart); a change
            // means /new or a respawn moved it. The Bridge screen shows the
            // same value with its claudeUp/turn detail.
            Text(
              a.sessionId == null || a.sessionId!.isEmpty
                  ? 'no session yet'
                  : 'session ${a.sessionId}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontFamily: 'monospace',
                    color: a.bridgeBusy ? scheme.primary : scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Claude Code bridge',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => BridgeScreen(assistant: a)),
            ),
            icon: Badge(
              // Lit while a turn is heard (spinner covers it) *and* while
              // a detached turn keeps working unheard: the badge is the
              // only sign of invisible background work (plus the hint
              // text under the button).
              isLabelVisible: a.bridgeBusy || a.harnessBackgrounded,
              child: const Icon(Icons.terminal),
            ),
          ),
          IconButton(
            tooltip: 'Assistant voice',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => VoiceScreen(assistant: a)),
            ),
            icon: const Icon(Icons.record_voice_over_outlined),
          ),
          IconButton(
            tooltip: 'Debug tools',
            isSelected: _debugMode,
            onPressed: () => setState(() => _debugMode = !_debugMode),
            icon: const Icon(Icons.bug_report_outlined),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Center(
              child: SegmentedButton<InteractionMode>(
                segments: const [
                  ButtonSegment(
                    value: InteractionMode.conversation,
                    icon: Icon(Icons.forum_outlined),
                    label: Text('Conversation'),
                  ),
                  ButtonSegment(
                    value: InteractionMode.pushToTalk,
                    icon: Icon(Icons.touch_app_outlined),
                    label: Text('Push to talk'),
                  ),
                ],
                selected: {a.mode},
                onSelectionChanged: (s) => _assistant.setMode(s.first),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    controller: _scroll,
                    // Long harness answers grew the reply card without
                    // bounds until it smeared over the chips and metrics:
                    // the text block now scrolls inside this region and
                    // auto-follows the reply while it streams.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              a.status,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (a.error.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                a.error,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.error),
                              ),
                            ],
                            const SizedBox(height: 16),
                            // The conversation itself: user bubbles right,
                            // assistant bubbles left with one block per spoken
                            // section. Persistent — turns no longer replace
                            // each other, and the log reloads with the app.
                            // The in-flight harness turn renders even while
                            // still block-free: its bubble carries the live
                            // working line (below the last spoken block).
                            for (final e in a.chat)
                              if (e.fromUser ||
                                  e.blocks.isNotEmpty ||
                                  identical(e, liveTurn))
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Align(
                                          alignment: e.fromUser
                                              ? Alignment.centerRight
                                              : Alignment.centerLeft,
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth:
                                                  constraints.maxWidth * 0.86,
                                            ),
                                            child: Card(
                                              color: e.fromUser
                                                  ? scheme.primaryContainer
                                                  : scheme.secondaryContainer,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 10,
                                                    ),
                                                child: e.fromUser
                                                    ? SelectableText(
                                                        e.blocks.join(' '),
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodyLarge
                                                            ?.copyWith(
                                                              color: scheme
                                                                  .onPrimaryContainer,
                                                            ),
                                                      )
                                                    : Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          for (final (i, s)
                                                              in e
                                                                  .blocks
                                                                  .indexed) ...[
                                                            if (i > 0)
                                                              const Divider(
                                                                height: 24,
                                                              ),
                                                            SelectableText(
                                                              s,
                                                              style:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .textTheme
                                                                      .bodyLarge,
                                                            ),
                                                          ],
                                                          if (identical(
                                                            e,
                                                            liveTurn,
                                                          )) ...[
                                                            const SizedBox(
                                                              height: 12,
                                                            ),
                                                            _HarnessSpinner(
                                                              assistant: a,
                                                              label: a.status,
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (a.bridgeConfigured) ...[
                // Session housekeeping: /new and /compact (see
                // VoiceAssistant.bridgeControl for what each does on the
                // wire). Taps deliberately interrupt any voice reply
                // mid-flight (runQuickCommand supersedes), which is the
                // right feel: a chip press means "do THIS now". The old
                // canned-prompt chips are gone — a harness you can talk to
                // outloud doesn't need buttons holding its hoof.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      for (final chip in VoiceAssistant.controlChips)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            avatar: Icon(_chipIcons[chip], size: 18),
                            label: Text(chip),
                            onPressed: a.bridgeBusy
                                ? null
                                : () => a.bridgeControl(chip),
                          ),
                        ),
                      if (a.bridgeBusy)
                        ActionChip(
                          avatar: const Icon(
                            Icons.stop_circle_outlined,
                            size: 18,
                          ),
                          label: const Text('Stop'),
                          onPressed: a.bridgeStop,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _LatencyStrip(assistant: a),
              if (_debugMode && (a.asrAudioSeconds > 0 || a.lastTtsSeconds > 0))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    children: [
                      if (a.asrAudioSeconds > 0)
                        TextButton.icon(
                          onPressed: a.playAsrAudio,
                          icon: Icon(
                            a.debugPlaying
                                ? Icons.stop_circle_outlined
                                : Icons.play_circle_outline,
                            size: 22,
                          ),
                          label: Text(
                            a.debugPlaying
                                ? 'Stop replay'
                                : 'Replay exactly what the ASR heard '
                                      '(${a.asrAudioSeconds.toStringAsFixed(1)}s)',
                          ),
                        ),
                      if (a.lastTtsSeconds > 0)
                        TextButton.icon(
                          onPressed: a.playTtsAudio,
                          icon: Icon(
                            a.debugPlaying
                                ? Icons.stop_circle_outlined
                                : Icons.record_voice_over_outlined,
                            size: 22,
                          ),
                          label: Text(
                            a.debugPlaying
                                ? 'Stop replay'
                                : 'Replay my last reply, raw TTS out '
                                      '(${a.lastTtsSeconds.toStringAsFixed(1)}s)',
                          ),
                        ),
                    ],
                  ),
                ),
              // Bottom-anchored block sits in a bottom SafeArea: with edge-to-edge
              // Android (targetSdk 35) the system reserves the bottom edge for
              // navigation gestures, and a HOLD starting in that strip is taken by
              // the system (a bare tap is not) — which is why the old tap-to-latch
              // button seemed fine right where hold-to-talk now sits idle.
              SafeArea(
                top: false,
                bottom: true,
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    // Claude Code-style context-usage readout, right
                    // above the talk button where eyes already sit
                    // mid-turn. Fed by live `context` events (and the
                    // post-turn /health merge), so it ticks up the
                    // moment the harness starts an API call and survives
                    // app restarts via the bridge's snapshot.
                    if (a.bridgeConfigured && (a.contextIn > 0 || a.bridgeBusy))
                      _ContextBar(assistant: a),
                    // In push-to-talk the mic is driven by press/release edges,
                    // observed as raw pointer events so the button's own tap (and
                    // its ripple) stay untouched; conversation mode keeps the
                    // plain tap-to-toggle. Move edges only feed the hold guide's
                    // live lean — the release gesture itself is classified
                    // against the press point inside VoiceAssistant.pttUp.
                    Listener(
                      onPointerDown: (e) => _assistant.pttDown(e.position),
                      onPointerMove: (e) => _assistant.pttMove(e.position),
                      onPointerUp: (e) => _assistant.pttUp(e.position),
                      onPointerCancel: (_) => _assistant.pttCancel(),
                      child: _PttHoldGuide(
                        assistant: a,
                        icon: icon,
                        color: color,
                        onPrimary: scheme.onPrimary,
                        onPressed: !fabEnabled
                            ? null
                            : _assistant.mode ==
                                  InteractionMode.pushToTalk
                            ? () {
                                // Press/release edges (pttDown/pttUp) now
                                // own every hold over a harness turn:
                                // short-tap-to-stop is handled inside the
                                // release path, long-hold gestures queue
                                // or interrupt the new prompt. This tap
                                // only still fires when the hold could
                                // not open the mic (e.g. models loading),
                                // where the classic hard stop remains.
                                if (a.bridgeBusy) a.bridgeStop();
                              }
                            : _assistant.toggle,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(hint, style: Theme.of(context).textTheme.labelLarge),
                    if (_debugMode)
                      Text(
                        'hold edges: ${_assistant.pttEdgeCount}  '
                        'pointers: ${_assistant.mode == InteractionMode.pushToTalk ? "ptt" : "conv"}',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: scheme.outline),
                      ),
                    const SizedBox(height: 8),
                    if (_debugMode && a.debugLog.isNotEmpty)
                      SelectableText(
                        a.debugLog.reversed.take(14).join('\n'),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                          fontFamily: 'monospace',
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Push-to-talk hold choreography. While a hold is down the mic button
/// leans toward the finger and the two release slides appear beside it:
/// UP interrupts the turn in flight, RIGHT discards the recording
/// un-sent (VoiceAssistant.pttUp routes both). The pill for whichever
/// slide the finger has passed lights up and tips the button that way
/// with a coloured halo — the arm thresholds are the very ones release
/// reads (both through one predicate in VoiceAssistant), so the picture
/// is always exactly "what letting go now would do". At rest, or in
/// conversation mode (which never holds), everything animates away and
/// the button is just the button.
class _PttHoldGuide extends StatelessWidget {
  const _PttHoldGuide({
    required this.assistant,
    required this.icon,
    required this.color,
    required this.onPrimary,
    required this.onPressed,
  });

  final VoiceAssistant assistant;
  final IconData icon;
  final Color color;
  final Color onPrimary;
  final VoidCallback? onPressed;

  /// The button is FloatingActionButton.large — 96 logical px, which the
  /// pill offsets and the lean fractions below are measured against.
  static const double _fab = 96;
  static const Duration _anim = Duration(milliseconds: 130);

  /// One release slide: a capsule with an arrow and a word, faded and
  /// shrunk away when no hold is down, ghosted while it is only near
  /// (0.92), and popping lit in [armedColor] once its slide is armed.
  Widget _pill({
    required IconData icon,
    required String label,
    required Color armedColor,
    required bool shown,
    required bool armed,
    required ColorScheme scheme,
  }) {
    return AnimatedOpacity(
      duration: _anim,
      opacity: shown ? (armed ? 1 : 0.6) : 0,
      child: IgnorePointer(
        child: AnimatedScale(
          duration: _anim,
          curve: Curves.easeOutBack,
          scale: shown ? (armed ? 1.15 : 0.92) : 0.5,
          child: AnimatedContainer(
            duration: _anim,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: armed ? armedColor : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: armed ? Colors.white : scheme.onSurface,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: armed ? Colors.white : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hold = assistant.pttHoldActive;
    final slide = hold ? assistant.pttSlide : PttSlide.none;
    // The quantised drag, already clamped by pttMove: a flick beyond the
    // threshold leans no further than a just-past-the-line drag.
    final drag = hold ? assistant.pttDrag : Offset.zero;
    // Drift a third of the way after the finger, then tip a further
    // 14 px once a slide is armed — springy rubber band, never dodging
    // out from under the thumb.
    final lean =
        drag * 0.35 +
        switch (slide) {
          PttSlide.up => const Offset(0, -14),
          PttSlide.right => const Offset(14, 0),
          PttSlide.none => Offset.zero,
        };
    final turns =
        (drag.dx / _fab) * 0.08 +
        (slide == PttSlide.up
            ? -0.02
            : slide == PttSlide.right
            ? 0.03
            : 0.0);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // Halo behind the button, painted first so the button itself
        // sits on it: clear at rest, the armed slide's colour while a
        // slide is on (orange cuts, red discards). Same box as the
        // button (the shadow paints beyond it), so the Stack keeps the
        // button's exact footprint in the column.
        AnimatedContainer(
          width: _fab,
          height: _fab,
          duration: _anim,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:
                    switch (slide) {
                      PttSlide.up => Colors.orange.shade700,
                      PttSlide.right => scheme.error,
                      PttSlide.none => color,
                    }.withValues(alpha: hold ? 0.5 : 0.0),
                blurRadius: 30,
                spreadRadius: hold ? 6 : -24,
              ),
            ],
          ),
        ),
        AnimatedRotation(
          turns: hold ? turns : 0.0,
          duration: _anim,
          curve: Curves.easeOut,
          child: AnimatedSlide(
            offset: hold
                ? Offset(lean.dx / _fab, lean.dy / _fab)
                : Offset.zero,
            duration: _anim,
            curve: Curves.easeOutBack,
            child: AnimatedScale(
              scale: hold ? 1.06 : 1.0,
              duration: _anim,
              child: FloatingActionButton.large(
                onPressed: onPressed,
                backgroundColor: color,
                foregroundColor: onPrimary,
                shape: const CircleBorder(),
                child: Icon(icon, size: 40),
              ),
            ),
          ),
        ),
        // The two slides. A Stack this size spans only the button, so
        // the pills get their room by hanging negative insets over an
        // unclipped edge: interrupt floats above the tip, cancel to
        // the right of it.
        Positioned(
          left: -_fab,
          right: -_fab,
          bottom: _fab + 16,
          child: Center(
            child: _pill(
              icon: Icons.arrow_upward,
              label: 'Interrupt',
              armedColor: Colors.orange.shade700,
              shown: hold,
              armed: slide == PttSlide.up,
              scheme: scheme,
            ),
          ),
        ),
        Positioned(
          left: _fab + 16,
          right: -_fab * 2,
          top: -24,
          bottom: -24,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _pill(
              icon: Icons.arrow_forward,
              label: 'Cancel',
              armedColor: scheme.error,
              shown: hold,
              armed: slide == PttSlide.right,
              scheme: scheme,
            ),
          ),
        ),
      ],
    );
  }
}

class _LatencyStrip extends StatelessWidget {
  const _LatencyStrip({required this.assistant});

  final VoiceAssistant assistant;

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, String value) => Column(
      children: [
        Text(value, style: Theme.of(context).textTheme.titleSmall),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
    // A hop that completed shows lit; the road ahead waits in grey.
    Widget arrow(bool done) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Icon(
        Icons.arrow_forward,
        size: 14,
        color: done ? Colors.green : Theme.of(context).disabledColor,
      ),
    );
    final lit = assistant.hopReply; // the PC wakes when the first byte back lands

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        cell('heard', '${assistant.recordSeconds.toStringAsFixed(1)}s'),
        arrow(assistant.hopAsr),
        cell('asr', '${assistant.asrSeconds.toStringAsFixed(2)}s'),
        arrow(assistant.hopSent),
        Icon(
          Icons.computer,
          size: 18,
          color: lit ? Colors.green : Theme.of(context).disabledColor,
        ),
        arrow(assistant.hopReply),
        cell('reply', '${assistant.playSeconds.toStringAsFixed(1)}s'),
        arrow(assistant.hopTts),
        cell('tts', '${assistant.ttsSeconds.toStringAsFixed(2)}s'),
      ],
    );
  }
}

/// Claude Code-style working line for the chat window: the braille glyph
/// wheel the CLI spins while it thinks (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) beside the live
/// harness status and a wall-clock readout, e.g.
/// "⠹ Edit foo.dart…  ·  12s  ·  tap Stop to
/// interrupt". Painted inside the in-flight assistant bubble (main chat
/// loop) for as long as a bridge turn runs — the one place "the agent is
/// still working" belongs to the conversation instead of the status strip.
/// Owns its 120 ms tick: the assistant only notifies when a say lands or a
/// tool event fires, so a harness thinking for minutes would otherwise
/// freeze the glyph mid-frame.
/// Context-usage status bar above the talk button — the voice-app
/// mirror of Claude Code's context meter: a token count, the model's
/// window, a percentage, and a fill that goes indeterminate while a
/// turn runs with no window figure yet, and warms toward error colors
/// as the conversation fills up. Numbers arrive on `context` SSE
/// events — exact at every message_start and at `result`, PREVIEWED at
/// turn start and on every fresh tool_result (the in-count grows while
/// the model reads, not only once the API proves it) — plus every
/// /health read (exact only) — see VoiceAssistant._mergeContext.
class _ContextBar extends StatelessWidget {
  const _ContextBar({required this.assistant});

  final VoiceAssistant assistant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = assistant;
    final frac = a.contextFrac;
    final pct = frac * 100;
    final label = a.contextIn == 0
        ? 'context · measuring…'
        : frac > 0
        ? 'context ${_fmtTok(a.contextIn)} / ${_fmtTok(a.contextWindow)} · '
              '${pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1)}%'
        : 'context ${_fmtTok(a.contextIn)} · window unknown';
    final fill = frac >= 0.90
        ? scheme.error
        : frac >= 0.70
        ? scheme.tertiary
        : scheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
      child: SizedBox(
        width: MediaQuery.sizeOf(context).width * 0.62,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: a.bridgeBusy ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                // No window yet but the harness is working: an honest
                // indeterminate shimmer instead of a fake zero.
                value: frac > 0 ? frac : (a.bridgeBusy ? null : 0),
                minHeight: 4,
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(fill),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 12400 -> '12.4k', 467232 -> '467k', 1_250_000 -> '1.3M' (the bridge
/// library owns the shared shape — see fmtTokenCount).
String _fmtTok(int n) => fmtTokenCount(n);

class _HarnessSpinner extends StatefulWidget {
  const _HarnessSpinner({required this.assistant, required this.label});

  final VoiceAssistant assistant;
  final String label;

  @override
  State<_HarnessSpinner> createState() => _HarnessSpinnerState();
}

class _HarnessSpinnerState extends State<_HarnessSpinner> {
  static const _wheel = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  late final Timer _tick;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => setState(() => _frame = (_frame + 1) % _wheel.length),
    );
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = widget.assistant;
    final secs = a.harnessElapsed.inSeconds;
    // While the harness is GENERATING, the live token tally owns this
    // line — and it grows on the spinner's own 120 ms tick, not on the
    // bridge's ~0.8 s relays: VoiceAssistant extrapolates the count
    // between relays at the rate its own consecutive relays taught it
    // (and snaps to the bridge's exact number when a frame or a
    // message-close settles it). Monospace so the growing digits never
    // reflow the line; the tool-name labels stay the plain style.
    final live = a.tokenTickerOn;
    final label = live ? a.tokenTickerLabel : widget.label;
    // Whatever the line says, the phone's best-known input figure
    // rides at its end the moment it exists — including during the
    // long silent reads (prefill after a fat tool output, a slow first
    // token) where no deltas flow and the ticker has nothing to grow.
    // The bridge feeds this from exact message_start numbers AND from
    // previews (previous turn's exact size + the bytes of each fresh
    // tool_result, relayed the instant they cross the stream), so
    // "Asking the bridge…" is never the whole truth for twenty seconds
    // while the model chokes on a test log. The live ticker already
    // carries its own in-number, so only the frozen states append it.
    final shownIn = live ? 0 : a.contextIn;
    final line = '$label${shownIn > 0 ? '  ·  ${_fmtTok(shownIn)} in' : ''}'
        '  ·  ${secs}s  ·  tap Stop to interrupt';
    final working = Row(
      children: [
        Text(
          _wheel[_frame],
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(color: scheme.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            line,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFamily: live || shownIn > 0 ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
    // The thinking, spelled out: while the tally says 'thinking' AND the
    // bridge streamed thinking text, the rolling tail of the thought
    // renders as a second line under the working line — proof of life
    // with words instead of a spinner pretending to be patient. Silent
    // thinkers (no thinking deltas, or the model just answers) keep the
    // line alone: kind 'thinking' with no thought is still the honest
    // state for the pre-first-token interval (prefill) the census logs.
    // Max two lines so a rambling thought never shoves the chat around.
    // And the answer, painted before it is spoken: while the tally says
    // 'answering' and the bridge streamed the reply, the un-spoken tail
    // rides the same second line — in plain (not italic) type, because
    // this is the answer itself arriving, not the deliberations. The
    // say frame at block close replaces it with the confirmed text.
    final thought = a.tokenThought;
    final draft = a.tokenDraft;
    if (thought.isEmpty && draft.isEmpty) return working;
    final shown = thought.isNotEmpty ? thought : draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        working,
        Padding(
          padding: const EdgeInsets.only(left: 34, top: 2),
          child: Text(
            shown,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: thought.isNotEmpty
                  ? scheme.onSurfaceVariant
                  : scheme.onSurface,
              fontStyle: thought.isNotEmpty ? FontStyle.italic : null,
            ),
          ),
        ),
      ],
    );
  }
}
