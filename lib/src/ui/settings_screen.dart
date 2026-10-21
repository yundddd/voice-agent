/// +230: ONE settings page. The bridge/harness screen and the
/// assistant-voice screen were two doors to one room — the gear on
/// the main bar now opens a single page that SCROLLS through both:
/// the voice answers first (what the app sounds like), then the
/// bridge (where the brain lives). Each former screen survives as a
/// shrink-wrapped section widget (its state, its /health refresh,
/// its pickers all intact); this file owns the Scaffold, the headers
/// and the order.
library;

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';
import 'bridge_screen.dart';
import 'voice_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.assistant});

  final VoiceAssistant assistant;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _SectionHeader(
            title: 'Voice',
            blurb: 'How the assistant sounds and understands you.',
          ),
          VoiceScreen(assistant: assistant),
          const Divider(height: 1),
          _SectionHeader(
            title: 'Bridge',
            blurb: 'The AI on your computer: address, harness, model, folder.',
          ),
          BridgeScreen(assistant: assistant),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.blurb});
  final String title;
  final String blurb;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          Text(
            blurb,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
