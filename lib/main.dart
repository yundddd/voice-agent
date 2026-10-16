import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'assistant.dart';
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE)),
        useMaterial3: true,
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
  static const _chipIcons = [
    Icons.account_tree, // Repo status
    Icons.playlist_add_check, // Run tests
    Icons.android, // Build APK
    Icons.auto_stories, // Catch me up
  ];

  final VoiceAssistant _assistant = VoiceAssistant();
  bool _debugMode = false;
  final ScrollController _scroll = ScrollController();
  int _seenReplyLen = 0; // drives auto-follow while the reply streams

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
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _assistant.pauseConversation();
      case AppLifecycleState.resumed:
        _assistant.resumeConversation();
      case AppLifecycleState.inactive:
        break; // transient (notification shade, permission prompt)
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _assistant;
    final scheme = Theme.of(context).colorScheme;

    // Auto-follow the streaming reply: when its text grows, pin the scroll
    // position to the bottom (post-frame: the new height exists only after
    // layout). No-op once the user has flicked away to read the beginning.
    if (a.lastReply.length != _seenReplyLen) {
      _seenReplyLen = a.lastReply.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (!_scroll.position.outOfRange) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }

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
        AssistantPhase.listening => (true, 'Release to send'),
        AssistantPhase.transcribing || AssistantPhase.speaking => (
          a.bridgeBusy, // a harness turn: the greyed button would be dead air
          a.bridgeBusy ? 'Stop the harness' : 'One moment…',
        ),
        _ => (true, 'Hold to talk'),
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
        title: const Text('Voice Agent'),
        actions: [
          IconButton(
            tooltip: 'Claude Code bridge',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => BridgeScreen(assistant: a)),
            ),
            icon: Badge(
              isLabelVisible: a.bridgeBusy,
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
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
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
                      if (a.transcript.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              a.transcript,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                        ),
                      ],
                      // The assistant's answer itself, shown on screen as it
                      // streams (the bridge used to only speak it, so a
                      // harness reply was invisible once the status moved on).
                      if (a.lastReply.isNotEmpty &&
                          a.lastReply != a.transcript) ...[
                        const SizedBox(height: 12),
                        Card(
                          color: scheme.secondaryContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              a.lastReply,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                        ),
                      ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (a.bridgeConfigured) ...[
                // One-tap harness commands. Taps deliberately interrupt any
                // voice reply mid-flight (runQuickCommand supersedes), which
                // is the right feel: a chip press means "do THIS now".
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      for (final (i, cmd)
                          in VoiceAssistant.quickCommands.indexed)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            avatar: Icon(
                              _chipIcons[i % _chipIcons.length],
                              size: 18,
                            ),
                            label: Text(cmd.$1),
                            onPressed: a.bridgeBusy
                                ? null
                                : () => a.runQuickCommand(cmd.$2),
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
                    // In push-to-talk the mic is driven by press/release edges,
                    // observed as raw pointer events so the button's own tap (and
                    // its ripple) stay untouched; conversation mode keeps the
                    // plain tap-to-toggle.
                    Listener(
                      onPointerDown: (_) => _assistant.pttDown(),
                      onPointerUp: (_) => _assistant.pttUp(),
                      onPointerCancel: (_) => _assistant.pttCancel(),
                      child: FloatingActionButton.large(
                        onPressed: !fabEnabled
                            ? null
                            : _assistant.mode == InteractionMode.pushToTalk
                            ? () {
                                // Only reachable as 'Stop the harness'
                                // (bridgeBusy): a plain hold does nothing.
                                if (a.bridgeBusy) a.bridgeStop();
                              }
                            : _assistant.toggle,
                        backgroundColor: color,
                        foregroundColor: scheme.onPrimary,
                        shape: const CircleBorder(),
                        child: Icon(icon, size: 40),
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

class _LatencyStrip extends StatelessWidget {
  const _LatencyStrip({required this.assistant});

  final VoiceAssistant assistant;

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.titleSmall),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );

    return Row(
      children: [
        cell('heard', '${assistant.recordSeconds.toStringAsFixed(1)}s'),
        cell('asr', '${assistant.asrSeconds.toStringAsFixed(2)}s'),
        cell('tts', '${assistant.ttsSeconds.toStringAsFixed(2)}s'),
        cell('reply', '${assistant.playSeconds.toStringAsFixed(1)}s'),
      ],
    );
  }
}
