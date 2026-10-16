import 'package:flutter/material.dart';

import 'assistant.dart';

/// Bridge settings + live check (the terminal icon). Everything voice-
/// related about the bridge is one tap deep and needs no manual editing
/// once the url/token are set here — see docs/claude-code-bridge.md for
/// how to start the bridge process itself (`node tool/claude_bridge.mjs`).
class BridgeScreen extends StatefulWidget {
  const BridgeScreen({super.key, required this.assistant});
  final VoiceAssistant assistant;

  @override
  State<BridgeScreen> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends State<BridgeScreen> {
  late final TextEditingController _url = TextEditingController(
    text: widget.assistant.bridgeUrlText,
  );
  late final TextEditingController _token = TextEditingController(
    text: widget.assistant.bridgeTokenText,
  );
  final TextEditingController _free = TextEditingController();
  String? _check; // null = unchecked, '' = healthy, else the reason
  bool _checking = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _free.dispose();
    super.dispose();
  }

  Future<void> _saveAndCheck() async {
    setState(() => _checking = true);
    await widget.assistant.setBridge(url: _url.text, token: _token.text);
    _check = await widget.assistant.bridgeCheck();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assistant;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Claude Code bridge'),
        actions: [
          IconButton(
            tooltip: 'Start a fresh conversation (drop history)',
            onPressed: () => a.bridgeControl('/new'),
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      // Rebuild on every assistant change (busy state, toggle persistence):
      body: AnimatedBuilder(
        animation: a,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Point the app at the bridge process started on your desktop:\n'
              'node tool/claude_bridge.mjs --dir <project> --token <token>',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Bridge URL',
                hintText:
                    'http://135.180.96.71:8732  (or tailscale http://100.99.240.112:8732)',
                border: OutlineInputBorder(),
                helperText:
                    'Plain http works on your LAN/tailnet — the bridge '
                    'is LAN-only by convention and carries a shared token.',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              decoration: const InputDecoration(
                labelText: 'Token',
                border: OutlineInputBorder(),
                helperText: 'must match the bridge\'s --token',
              ),
              obscureText: true,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _checking ? null : _saveAndCheck,
                  icon: _checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: const Text('Save & check'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _check == null
                        ? (a.bridgeConfigured
                              ? 'configured (not yet checked)'
                              : 'not configured')
                        : _check!.isEmpty
                        ? 'bridge reachable, claude up'
                        : 'problem: $_check',
                    style: TextStyle(
                      color: _check == null || _check!.isEmpty
                          ? scheme.onSurfaceVariant
                          : scheme.error,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 32),
            // The headline switch: your speech -> the harness -> spoken answer.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: a.bridgeVoice,
              onChanged: (v) => a.setBridgeVoice(v),
              title: const Text('Speak to Claude Code'),
              subtitle: Text(
                a.bridgeConfigured
                    ? 'On (factory): whatever you say in push-to-talk or '
                          'conversation mode goes to the harness, and its '
                          'answer comes back spoken. Off: the app repeats '
                          'your words back like the offline demo.'
                    : 'Set a bridge url and token above first — with no '
                          'bridge reachable, voice stays offline.',
              ),
            ),
            Text(
              'Session controls on the main screen',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final (label, blurb) in const [
              (
                '/new',
                'Forget the conversation on both sides and start over — '
                    'the past no longer fills the context window.',
              ),
              (
                '/compact',
                'Have Claude Code condense the chat into a summary: keep '
                    'the thread, free the window. Same as /compact at a '
                    'desk terminal.',
              ),
            ])
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(label),
                subtitle: Text(
                  blurb,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: 'Run this control now',
                  onPressed: a.bridgeBusy || !a.bridgeConfigured
                      ? null
                      : () {
                          Navigator.of(
                            context,
                          ).pop(); // talk over on the main screen
                          a.bridgeControl(label);
                        },
                ),
              ),
            const Divider(height: 32),
            Text(
              'Say anything',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _free,
              decoration: const InputDecoration(
                labelText: 'Custom command for the harness',
                border: OutlineInputBorder(),
                helperText:
                    'sent verbatim as one utterance; the answer is '
                    'spoken with your assistant voice. A line starting '
                    'with / runs as a real Claude Code command (e.g. '
                    '/context to hear how full the window is)',
              ),
              onSubmitted: (v) {
                if (v.trim().isEmpty) return;
                Navigator.of(context).pop();
                a.runQuickCommand(v.trim(), bubble: v.trim());
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed:
                    a.bridgeBusy ||
                        !a.bridgeConfigured ||
                        _free.text.trim().isEmpty
                    ? null
                    : () {
                        final v = _free.text.trim();
                        _free.clear();
                        Navigator.of(context).pop();
                        a.runQuickCommand(v, bubble: v);
                      },
                icon: const Icon(Icons.send),
                label: const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
