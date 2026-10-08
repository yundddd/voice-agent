import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'assistant.dart';

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

class _AssistantScreenState extends State<AssistantScreen> {
  final VoiceAssistant _assistant = VoiceAssistant();

  @override
  void initState() {
    super.initState();
    _assistant
      ..addListener(() => setState(() {}))
      ..init();
  }

  @override
  void dispose() {
    _assistant.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = _assistant;
    final scheme = Theme.of(context).colorScheme;

    final (icon, color) = switch (a.phase) {
      AssistantPhase.listening => (Icons.mic, scheme.error),
      AssistantPhase.transcribing => (Icons.graphic_eq, scheme.primary),
      AssistantPhase.speaking => (Icons.volume_up, scheme.primary),
      AssistantPhase.error => (Icons.error_outline, scheme.error),
      AssistantPhase.idle => (Icons.mic_none, scheme.primary),
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Voice Agent')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Expanded(
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
                              style:
                                  Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              _LatencyStrip(assistant: a),
              const SizedBox(height: 24),
              FloatingActionButton.large(
                onPressed: a.phase == AssistantPhase.idle ||
                        a.phase == AssistantPhase.listening ||
                        a.phase == AssistantPhase.error
                    ? a.toggle
                    : null,
                backgroundColor: color,
                foregroundColor: scheme.onPrimary,
                shape: const CircleBorder(),
                child: Icon(icon, size: 40),
              ),
              const SizedBox(height: 8),
              Text(
                a.phase == AssistantPhase.listening ? 'Stop' : 'Talk',
                style: Theme.of(context).textTheme.labelLarge,
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
              Text(label,
                  style: Theme.of(context).textTheme.labelSmall),
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
