/// The conversation channel: user bubbles right, assistant bubbles left
/// with one block per spoken section (the bubble mirrors what came out
/// of the speaker). Persistent — turns no longer replace each other, and
/// the log reloads with the app. The in-flight harness turn renders even
/// while still block-free: its bubble carries the live working line
/// ([HarnessSpinner]). A queued press is EXCLUDED from the flow — it
/// rides the pinned card below instead, until the harness starts its
/// turn and the entry dissolves back in at its place.
library;

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';
import 'harness_spinner.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.entry,
    required this.isLiveTurn,
    required this.maxWidthFrac,
    required this.assistant,
  });

  final ChatEntry entry;
  final bool isLiveTurn;
  final double maxWidthFrac;
  final VoiceAssistant assistant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Align(
              alignment: entry.fromUser
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * maxWidthFrac,
                ),
                child: Card(
                  color: entry.fromUser
                      ? scheme.primaryContainer
                      : scheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: entry.fromUser
                        ? SelectableText(
                            entry.blocks.join(' '),
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(color: scheme.onPrimaryContainer),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final (i, s) in entry.blocks.indexed) ...[
                                if (i > 0) const Divider(height: 24),
                                SelectableText(
                                  s,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodyLarge,
                                ),
                              ],
                              if (isLiveTurn) ...[
                                const SizedBox(height: 12),
                                HarnessSpinner(assistant: assistant),
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
    );
  }
}

/// The polite-queue pin: a slide-up-off press that the bridge parked
/// behind the live turn. It stays at the very bottom of the channel —
/// under whatever the current work keeps printing — until Claude Code
/// takes it, at which point the flag clears and the message re-renders
/// in the flow above.
class QueuedBubbleCard extends StatelessWidget {
  const QueuedBubbleCard({
    super.key,
    required this.text,
    required this.maxWidthFrac,
  });

  final String text;
  final double maxWidthFrac;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * maxWidthFrac,
                ),
                child: Card(
                  color: scheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.schedule_outlined,
                              size: 14,
                              color: scheme.onPrimaryContainer
                                  .withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Queued — waiting for the current work',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: scheme.onPrimaryContainer
                                        .withValues(alpha: 0.7),
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          text,
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
