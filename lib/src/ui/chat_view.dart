/// The conversation channel: user bubbles right, assistant bubbles left
/// with one block per spoken section (the bubble mirrors what came out
/// of the speaker). Persistent — turns no longer replace each other, and
/// the log reloads with the app. +151: a turn's bubble appears only
/// once it has something to say — the live working line ([HarnessSpinner]
/// inside [WorkingRowCard]) rides the channel's bottom row and belongs
/// to no bubble at all. A queued press sits IN the flow where it was
/// said, DIMMED (+146: it used to be pulled out of the channel into a
/// pin card and have 'One moment — …' injected as a second
/// notification of the same fact; the grey bubble is the wait
/// indicator, and it returns to full color the moment the agent takes
/// the turn — one message, one place, one state).
///
/// Every widget here renders [AssistantView] data — no live assistant
/// getters, no derived state in the render path. A behavior change
/// arrives as a view difference (assertable in a VM test); a widget
/// change is testable against a hand-built view.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../assistant/view.dart';
import '../chat/chat_log.dart';
import 'harness_spinner.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.entry,
    required this.maxWidthFrac,
    required this.source,
    this.onFileTap,
    this.onQueueTap,
  });

  final ChatEntry entry;
  final double maxWidthFrac;

  /// Live re-projection for the in-flight spinner (its token estimate
  /// moves on the widget's own tick, not on notifications).
  final ViewSource source;

  /// A file bubble's tap (fetch/inspect): wired to the assistant in
  /// production, null in a bare render test.
  final void Function(ChatEntry)? onFileTap;

  /// A GREY queued bubble's tap: cut the in-flight turn so this parked
  /// prompt starts immediately. Wired to the assistant's /stop path.
  final void Function(ChatEntry)? onQueueTap;

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
                child: Opacity(
                  // +146: the queued wait, shown where the message
                  // lives: a polite-queue press is greyed until the
                  // bridge's started marker clears the pin. No card,
                  // no injected 'One moment' — the message itself
                  // waits in plain sight.
                  opacity: entry.fromUser && entry.queued ? 0.42 : 1.0,
                  child: GestureDetector(
                    // A file bubble is a button: tap pulls the bytes.
                    // OPAQUE behavior — the tap must land anywhere on
                    // the card, and NO SelectableText may live inside a
                    // file bubble: its own tap recognizer wins the
                    // arena over this ancestor and the button looked
                    // dead on the first install (field report: 'the tap
                    // to receive is not working').
                    behavior: HitTestBehavior.opaque,
                    onTap: entry.isFile && !entry.downloading
                        ? () => onFileTap?.call(entry)
                        : entry.queued
                        ? () => onQueueTap?.call(entry)
                        : null,
                    child: Card(
                      color: entry.fromUser
                          ? scheme.primaryContainer
                          // +168: a cancelled background receipt is an
                          // acknowledgement, not prose — outline card,
                          // warning ink. It never dresses in the clothes
                          // of a spoken reply.
                          : entry.cancelled
                          ? Colors.transparent
                          // A relayed file is NEITHER prose nor receipt:
                          // its own surface, outlined in the tertiary
                          // hue — a different style, by dictate.
                          : entry.isFile
                          ? scheme.surfaceContainerHighest
                          : scheme.secondaryContainer,
                      shape: entry.cancelled
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: scheme.error.withValues(alpha: 0.6),
                              ),
                            )
                          : entry.isFile
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: scheme.tertiary.withValues(alpha: 0.6),
                              ),
                            )
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: entry.isFile
                            ? _FileBody(entry: entry, scheme: scheme)
                            : entry.fromUser
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                // While GREY the bubble is a button,
                                // so it renders its words as plain
                                // Text: the same tap-thief law that
                                // killed the file bubble's receive —
                                // a SelectableText inside would win
                                // the arena and the interrupt tap
                                // would look dead. Once taken, the
                                // selectability comes back.
                                if (entry.queued)
                                  Text(
                                    entry.blocks.join(' '),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyLarge?.copyWith(
                                      color: scheme.onPrimaryContainer,
                                    ),
                                  )
                                else
                                  SelectableText(
                                    entry.blocks.join(' '),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyLarge?.copyWith(
                                      color: scheme.onPrimaryContainer,
                                    ),
                                  ),
                                _BubbleStamp(
                                  text: stamp,
                                  color: scheme.onPrimaryContainer.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                                if (entry.queued)
                                  Text(
                                    'tap to interrupt now',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall?.copyWith(
                                      fontStyle: FontStyle.italic,
                                      color: scheme.onPrimaryContainer.withValues(
                                        alpha: 0.8,
                                      ),
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
                                    // +168: receipt italic in warning
                                    // ink (see the outline card).
                                    style: entry.cancelled
                                        ? Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                fontStyle: FontStyle.italic,
                                                color: scheme.error,
                                              )
                                        : Theme.of(
                                            context,
                                          ).textTheme.bodyLarge,
                                  ),
                                ],
                                if (entry.interrupted) ...[
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

/// +151: THE WORKING ROW. The spinner line — wheel, one-line activity,
/// token meter — lives here at the bottom of the channel instead of
/// inside whatever bubble the in-flight turn happened to open. The
/// redesign ends the 'which bubble carries the box' question for good:
/// queue placeholders, backlog-drain shells and superseded turns can
/// no longer move it (there was nowhere to move it TO), and a turn's
/// bubble appears in the flow only when it has something to say. The
/// row's visibility is projected ([AssistantView.showWorkingRow]:
/// heard or unheard work, hidden over pure playback); the paint, the
/// 120 ms wheel and the growing tally are [HarnessSpinner]'s own.
class WorkingRowCard extends StatelessWidget {
  const WorkingRowCard({
    super.key,
    required this.source,
    this.maxWidthFrac = 0.86,
  });

  /// +154: the row's height is a CONSTANT and the screen reserves it
  /// always — the slot never grows, shrinks, appears or disappears,
  /// so no bubble ever slides under a appearing footer (the jitter
  /// this kills; every professional chat app owns its composer/status
  /// band the same way). Label + meter + the one-line draft preview
  /// fit inside; ClipRect is the seatbelt.
  static const reservedHeight = 84.0;

  final ViewSource source;
  final double maxWidthFrac;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: constraints.maxWidth * maxWidthFrac,
          ),
          child: ClipRect(
            child: Card(
              color: scheme.surfaceContainerHigh,
              child: SizedBox(
                // The card's own margins (4+4) eat the rest of the slot.
                height: reservedHeight - 8,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: HarnessSpinner(source: source),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The persistent bottom row for a backgrounded tool call: names what
/// the harness is doing OUT OF EARSHOT — the last real step the detached
/// turn attested to, with a ticking age and its start clock — so a
/// minute-long build stays visibly in flight even while the phone is
/// hearing something else (or nothing). Auto-dismisses by construction:
/// the row rides the projection's proof-of-work signals (the
/// [BgWork.visible] badge or the queue pin), and
/// every completion path clears one — the 'started' pickup ack (the
/// bridge flushes only a closed turn), /stop, an orphan retire, or a
/// /health that finds nothing open. Owns its 1 s tick for the same
/// reason the spinner owns its wheel: notifications stop exactly when
/// the wire does, which is when an age readout must keep moving.
class BackgroundedWorkCard extends StatefulWidget {
  const BackgroundedWorkCard({
    super.key,
    required this.source,
    this.maxWidthFrac = 0.86,
  });

  final ViewSource source;
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
    final bg = widget.source().backgrounded;
    final work = bg.label;
    final since = formatBubbleClock(bg.sinceMs);
    final caption =
        '${work.isEmpty ? 'The harness keeps working unheard' : 'Background: $work'}'
        ' · ${formatWait(bg.elapsed.inMilliseconds)}'
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

/// The file bubble's body: a delivery slip, not a paragraph. Icon by
/// extension, monospace name, and ONE honest status line — the size and
/// the offer before the tap, a live percentage while the bytes ride,
/// the saved moment once they are on this device.
class _FileBody extends StatelessWidget {
  const _FileBody({required this.entry, required this.scheme});

  final ChatEntry entry;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final name = entry.fileName;
    final isApk = name.toLowerCase().endsWith('.apk');
    // ONE honest status line per state: the offer, the live
    // percentage, the open failure, or the tap-that-opens (a saved
    // file's tap goes straight to the system viewer — the installer,
    // for an APK).
    final status = entry.downloading
        ? (entry.totalBytes > 0 && entry.downloadBytes > 0
              ? 'Receiving ${entry.downloadBytes * 100 ~/ entry.totalBytes}%'
              : 'Receiving…')
        : entry.openError != null
        ? 'Could not open · ${entry.openError!.length > 40 ? '${entry.openError!.substring(0, 40)}…' : entry.openError}'
        : entry.savedMs != 0
        ? 'Saved · tap to open'
              '${formatBubbleClock(entry.savedMs).isEmpty ? '' : ' · ${formatBubbleClock(entry.savedMs)}'}'
        : '${formatBytes(entry.fileSize)} · tap to receive';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isApk
              ? Icons.android
              : Icons.description_outlined,
          size: 28,
          color: scheme.tertiary,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                // NOT SelectableText: a selectable runs its own tap
                // recognizer, beats the bubble's GestureDetector in
                // the arena, and swallows the receive. The slip's
                // words are the bridge's own path anyway.
                name,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                status,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
