/// The conversation channel: user bubbles right, assistant bubbles left
/// with one block per spoken section (the bubble mirrors what came out
/// of the speaker). Persistent — turns no longer replace each other, and
/// the log reloads with the app. The in-flight harness turn renders even
/// while still block-free: its bubble carries the live working line
/// ([HarnessSpinner]). A queued press is EXCLUDED from the flow — it
/// rides the pinned card below instead, until the harness starts its
/// turn and the entry dissolves back in at its place.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';
import '../chat/chat_log.dart';
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
    // Compact local clock for the bubble: the moment it was heard/typed
    // (user) or, once anything actually landed, when the reply reached
    // this screen/ear (assistant) — the delivery stamp is what tells a
    // delayed answer apart from a late-asked question on the log.
    final stamp = formatBubbleClock(
      !entry.fromUser && entry.deliveredMs != 0
          ? entry.deliveredMs
          : entry.createdMs,
    );
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
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              SelectableText(
                                entry.blocks.join(' '),
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: scheme.onPrimaryContainer,
                                    ),
                              ),
                              _BubbleStamp(
                                text: stamp,
                                color: scheme.onPrimaryContainer.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final (i, s) in entry.blocks.indexed) ...[
                                if (i > 0) const Divider(height: 24),
                                SelectableText(
                                  s,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ],
                              if (entry.interrupted && !isLiveTurn) ...[
                                // +108: a cut turn says so — the
                                // sections above it are what the speaker
                                // got before the newer press took over.
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.pan_tool_outlined,
                                      size: 14,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'interrupted'
                                      '${formatBubbleClock(entry.interruptedMs).isEmpty ? '' : ' · ${formatBubbleClock(entry.interruptedMs)}'}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            fontStyle: FontStyle.italic,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ],
                              if (isLiveTurn) ...[
                                const SizedBox(height: 12),
                                HarnessSpinner(assistant: assistant),
                              ],
                              _BubbleStamp(
                                text: stamp,
                                color: scheme.onSurfaceVariant,
                                topGap: true,
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

/// The compact HH:MM:SS caption at the bottom of a bubble — dimmed,
/// small, and simply absent for entries written before timestamps
/// existed (no fake clock on old history).
class _BubbleStamp extends StatelessWidget {
  const _BubbleStamp({
    required this.text,
    required this.color,
    this.topGap = false,
  });

  final String text;
  final Color color;
  final bool topGap;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: topGap ? 8 : 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// The persistent bottom row for a backgrounded tool call: names what
/// the harness is doing OUT OF EARSHOT — the last real step the detached
/// turn attested to, with a ticking age and its start clock — so a
/// minute-long build stays visibly in flight even while the phone is
/// hearing something else (or nothing). Auto-dismisses by construction:
/// the row rides the assistant's proof-of-work signals (the
/// [VoiceAssistant.harnessBackgrounded] badge or the queue pin), and
/// every completion path clears one — the 'started' pickup ack (the
/// bridge flushes only a closed turn), /stop, an orphan retire, or a
/// /health that finds nothing open. Owns its 1 s tick for the same
/// reason the spinner owns its wheel: notifications stop exactly when
/// the wire does, which is when an age readout must keep moving.
class BackgroundedWorkCard extends StatefulWidget {
  const BackgroundedWorkCard({
    super.key,
    required this.assistant,
    this.maxWidthFrac = 0.86,
  });

  final VoiceAssistant assistant;
  final double maxWidthFrac;

  @override
  State<BackgroundedWorkCard> createState() => _BackgroundedWorkCardState();
}

class _BackgroundedWorkCardState extends State<BackgroundedWorkCard> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => {});
    });
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
    final work = a.backgroundedWork;
    final since = formatBubbleClock(a.harnessSinceMs);
    final caption =
        '${work.isEmpty ? 'The harness keeps working unheard' : 'Background: $work'}'
        ' · ${formatWait(a.harnessElapsed.inMilliseconds)}'
        '${since.isEmpty ? '' : ' · since $since'}';
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: constraints.maxWidth * widget.maxWidthFrac,
          ),
          child: Card(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.hourglass_empty,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
    this.createdMs = 0,
  });

  final String text;
  final double maxWidthFrac;

  /// When the press happened (epoch ms): the pin card aging is exactly
  /// the queue-delay symptom, so it wears its send-time stamp.
  final int createdMs;

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
                              color: scheme.onPrimaryContainer.withValues(
                                alpha: 0.7,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Queued — waiting for the current work'
                              '${formatBubbleClock(createdMs).isEmpty ? '' : ' · ${formatBubbleClock(createdMs)}'}',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: scheme.onPrimaryContainer.withValues(
                                      alpha: 0.7,
                                    ),
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
