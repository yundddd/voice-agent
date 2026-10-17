/// Claude Code-style context-usage status bar above the talk button —
/// the voice-app mirror of Claude Code's context meter: a token count,
/// the model's window, a percentage, and a fill that goes indeterminate
/// while a turn runs with no window figure yet, and warms toward error
/// colors as the conversation fills up. Numbers arrive on `context` SSE
/// events — exact at every message_start and at `result`, PREVIEWED at
/// turn start and on every fresh tool_result (the in-count grows while
/// the model reads, not only once the API proves it) — plus every
/// /health read (exact only); see the assistant's context merge.
library;

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';

class ContextBar extends StatelessWidget {
  const ContextBar({super.key, required this.assistant});

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

String _fmtTok(int n) => fmtTokenCount(n);
