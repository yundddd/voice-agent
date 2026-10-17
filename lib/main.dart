library;

/// Entry point: bind the native speech libs, start the app. All UI lives
/// in src/ui/, all behaviour in src/ — see src/assistant/assistant.dart
/// for the orchestrator and lib/voice_agent.dart for the public surface.
import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'src/ui/assistant_screen.dart';
import 'src/ui/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The onnxruntime bindings power ASR + TTS inside the speech isolate;
  // init them before the first worker can spawn.
  await sherpa_onnx.initBindingsAsync();
  runApp(const VoiceAgentApp());
}

class VoiceAgentApp extends StatelessWidget {
  const VoiceAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Agent',
      // The official Claude dark palette (see src/ui/theme.dart): forced
      // dark — the mimicry is the point, so system light mode must not
      // wash it back to Material default; with no darkTheme set, `theme`
      // is the whole app.
      themeMode: ThemeMode.dark,
      theme: buildClaudeDarkTheme(),
      home: const AssistantScreen(),
    );
  }
}
