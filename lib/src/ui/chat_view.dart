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
import 'dart:math' as math;

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
    // +184 (widening +168): a receipt is a receipt — the outline card,
    // the italic line, the small status glyph. +168 dressed only the
    // CUT receipt distinct; the field tape shows two happy 'X finished.'
    // notes arriving in ordinary reply clothes, reading like prose the
    // agent never spoke. [cancelled] still picks the ink — warning for
    // the cut, calm outline ink for the completed — and the glyph says
    // which at a glance.
    final isReceipt = entry.receipt || entry.cancelled;
    final receiptInk = entry.cancelled ? scheme.error : scheme.onSurfaceVariant;
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
                          // +168/+184: a receipt is an acknowledgement,
                          // not prose — outline card, ink by outcome
                          // (warning for the cut, quiet for the
                          // completed). It never dresses in the clothes
                          // of a spoken reply.
                          : isReceipt
                          ? Colors.transparent
                          // A relayed file is NEITHER prose nor receipt:
                          // its own surface, outlined in the tertiary
                          // hue — a different style, by dictate.
                          : entry.isFile
                          ? scheme.surfaceContainerHighest
                          : scheme.secondaryContainer,
                      shape: isReceipt
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: receiptInk.withValues(alpha: 0.6),
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
                                // +188: the release opened this bubble
                                // at the button-up moment; while ASR
                                // is still finding the words the card
                                // pulses instead of pretending to be
                                // empty. The fill replaces the pulse
                                // with the text in the same place.
                                if (entry.transcribing)
                                  const _TranscribePulse()
                                else if (entry.queued)
                                  // While GREY the bubble is a button,
                                  // so it renders its words as plain
                                  // Text: the same tap-thief law that
                                  // killed the file bubble's receive —
                                  // a SelectableText inside would win
                                  // the arena and the interrupt tap
                                  // would look dead. Once taken, the
                                  // selectability comes back.
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
                                // One [FadeInBubble] PER SEGMENT, keyed
                                // by position (+181): the bubble's own
                                // entrance (+175) fades the whole card
                                // once, but the blocks stream in AFTER
                                // that — and un-wrapped they popped at
                                // full opacity beside settled text, the
                                // segment-level flicker this ends. Keyed
                                // by index, an
                                // append can only animate the NEW tail:
                                // every already-spoken segment keeps its
                                // completed state and never re-fades. At
                                // boot the whole row of wrappers mounts
                                // on the bubble's first frame — one
                                // group, one settle, as the restored
                                // log always arrived.
                                for (final (i, s) in entry.blocks.indexed)
                                  FadeInBubble(
                                    key: ValueKey(i),
                                    grow: true,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (i > 0) const Divider(height: 24),
                                        // +184: the receipt line — italic
                                        // in its outcome's ink, led by
                                        // the glyph that says which at a
                                        // glance (check for finished, the
                                        // same pan the interrupted stamp
                                        // uses for cancelled).
                                        if (isReceipt)
                                          Row(
                                            children: [
                                              Icon(
                                                entry.cancelled
                                                    ? Icons.pan_tool_outlined
                                                    : Icons
                                                          .check_circle_outline,
                                                size: 14,
                                                color: receiptInk,
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: SelectableText(
                                                  s,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        fontStyle:
                                                            FontStyle.italic,
                                                        color: receiptInk,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          )
                                        else
                                          SelectableText(
                                            s,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyLarge,
                                          ),
                                      ],
                                    ),
                                  ),
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

/// +188, redrawn by +189: the transcribing animation is a SIMPLIFIED
/// NEURAL NETWORK propagating — three layers of nodes (3-4-2, the
/// classic textbook silhouette) wired edge to edge, with a Gaussian
/// activation wave sweeping left to right: each layer ignites as the
/// signal reaches it, the connections light just between them, and a
/// low floor keeps the whole net dimly alive between sweeps. It says
/// "the mic heard you and the network is reading" by showing the
/// reading. Sized to roughly three text lines so the shift when the
/// fill replaces it is a nod, not a jump (the field judged +188's four
/// dots too simple, then +189's silhouette too small to watch — +191
/// stretched it, +193 stretched it again).
class _TranscribePulse extends StatefulWidget {
  const _TranscribePulse();

  @override
  State<_TranscribePulse> createState() => _TranscribePulseState();
}

class _TranscribePulseState extends State<_TranscribePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onPrimaryContainer;
    return SizedBox(
      // +191: stretched at the field's word — the silhouette was
      // painted small enough to miss the very propagation it shows.
      // +193: once more in both axes; the wave deserves a wide stage.
      height: 42,
      width: 110,
      child: AnimatedBuilder(
        animation: _c,
        builder:
            (context, _) => CustomPaint(
              painter: _NetPaint(
                ink: ink,
                // The wave's position in LAYER units, eased across the
                // net with half a layer of lead-in and run-off so the
                // glow fades before it loops — a sweep, not a blink.
                wave: _c.value * (_NetPaint.layers.length + 1) - 0.5,
              ),
            ),
      ),
    );
  }
}

class _NetPaint extends CustomPainter {
  _NetPaint({required this.ink, required this.wave});

  static const layers = [3, 4, 2];

  final Color ink;
  final double wave;

  double _glow(double centre, double width) {
    final d = wave - centre;
    return math.exp(-(d * d) / width).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = layers.length;
    final xs = [
      for (var i = 0; i < n; i++)
        10.0 + (size.width - 20) * (i / (n - 1)),
    ];
    final cols = [
      for (final count in layers)
        [
          for (var j = 0; j < count; j++)
            size.height / 2 +
                (j - (count - 1) / 2) * (size.height - 16) / (count - 1),
        ],
    ];
    final p = Paint()..strokeWidth = 1.2;
    // Edges first: a connection lights as the signal crosses the gap
    // between its two layers.
    for (var i = 0; i < n - 1; i++) {
      p.color = ink.withValues(alpha: 0.08 + 0.5 * _glow(i + 0.5, 0.18));
      for (final y1 in cols[i]) {
        for (final y2 in cols[i + 1]) {
          canvas.drawLine(Offset(xs[i], y1), Offset(xs[i + 1], y2), p);
        }
      }
    }
    // Nodes on top: each layer's activation is a wide Gaussian around
    // the wave, and the ignition grows the dot — energy, not just
    // brightness.
    final fill = Paint();
    for (var i = 0; i < n; i++) {
      final glow = _glow(i.toDouble(), 0.30);
      fill.color = ink.withValues(alpha: 0.15 + 0.8 * glow);
      final r = 2.6 + 1.8 * glow;
      for (final y in cols[i]) {
        canvas.drawCircle(Offset(xs[i], y), r, fill);
      }
    }
  }

  @override
  bool shouldRepaint(_NetPaint oldDelegate) =>
      oldDelegate.wave != wave || oldDelegate.ink != ink;
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

/// New bubbles FADE and RISE into the channel (field dictate: they used
/// to just flicker onto the screen). One-shot by construction: the
/// animation belongs to the element's first build, so an already-open
/// bubble that merely grows a streamed section never re-animates —
/// give each entry a stable ObjectKey and only genuinely-new cards
/// slide in. A boot-reload fades the restored log in as a group, which
/// reads as the screen settling, not strobing.
class FadeInBubble extends StatefulWidget {
  const FadeInBubble({super.key, required this.child, this.grow = false});

  final Widget child;

  /// +187: also animate the LAYOUT height (0 → natural) on the same
  /// ease. Without it the entrance eased only the ink: the slot
  /// appeared at full height on frame one, so a streaming segment
  /// snapped the card open and shoved everything below it — the field
  /// 'it still looks stiff, the segment just flashes in'. Growing the
  /// row open turns the shove into an opening.
  final bool grow;

  @override
  State<FadeInBubble> createState() => _FadeInBubbleState();
}

class _FadeInBubbleState extends State<FadeInBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    Widget w = FadeTransition(
      opacity: t,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(t),
        child: widget.child,
      ),
    );
    if (widget.grow) {
      // Top-anchored: the bottom edge travels, so lines above the new
      // segment never move — only the card opens downward.
      w = ClipRect(
        child: SizeTransition(
          sizeFactor: t,
          alignment: const Alignment(0, -1),
          child: w,
        ),
      );
    }
    return w;
  }
}
