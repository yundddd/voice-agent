/// Claude Code-style working line for the chat window: the braille glyph
/// wheel the CLI spins while it thinks (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) beside the live
/// harness status and a wall-clock readout, e.g.
/// "⠹ Edit foo.dart…  ·  12s  ·  tap Stop to
/// interrupt". Painted inside the in-flight assistant bubble (chat view)
/// for as long as a bridge turn runs — the one place "the agent is
/// still working" belongs to the conversation instead of the status
/// strip. Owns its 120 ms tick: the assistant only notifies when a say
/// lands or a tool event fires, so a harness thinking for minutes would
/// otherwise freeze the glyph mid-frame.
///
/// Reads [AssistantView] through a [ViewSource] — every state decision
/// (visibility, settle, label, meter) is already projected; the widget
/// owns only the wheel frame and the paint.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../assistant/view.dart';

class HarnessSpinner extends StatefulWidget {
  const HarnessSpinner({super.key, required this.source});

  /// Re-projects the live view on every tick — the token estimate moves
  /// on this widget's clock, not on notifications.
  final ViewSource source;

  @override
  State<HarnessSpinner> createState() => _HarnessSpinnerState();
}

class _HarnessSpinnerState extends State<HarnessSpinner> {
  static const _wheel = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  late final Timer _tick;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 120), (_) {
      // Spin ONLY while the agent works. Mid-reply the wheel used to
      // whirl through every spoken chunk — busywork theater while the
      // harness was merely talking (or quiet between streamed
      // paragraphs), so the user couldn't tell 'still computing' from
      // 'reading me a book'. But with the live sentence relay the agent
      // keeps working WHILE speaking (later sentences synthesise, more
      // tools run after the first chunk is already playing), and a
      // phase-based freeze silenced the wheel mid-task — which read as
      // 'it stopped working' when it hadn't. So the visibility law is
      // the projection's (AssistantView.spinnerVisible): freeze only
      // when the harness is PURELY talking — speaking phase with no
      // open bridge turn (harnessElapsed goes to zero the instant
      // `done` closes it). A live turn keeps the wheel turning through
      // its own voice.
      final v = widget.source();
      if (!v.spinnerVisible) return;
      // +84: the bridge says the TEXT is done and only audio rendering
      // remains ('settled'): nothing left to compute, so the wheel
      // stops even though the socket hasn't closed yet. (The old
      // dozen-seconds of honest-socket dishonest-spinner this kills.)
      if (v.token.settled) return;
      setState(() => _frame = (_frame + 1) % _wheel.length);
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
    final v = widget.source();
    final secs = v.harnessElapsed.inSeconds;
    // While the harness is GENERATING, the live token tally owns this
    // line — and it grows on the spinner's own 120 ms tick, not on the
    // bridge's ~0.8 s relays: the assistant extrapolates the count
    // between relays at the rate its own consecutive relays taught it
    // (and snaps to the bridge's exact number when a frame or a
    // message-close settles it). Monospace so the growing digits never
    // reflow the line; the tool-name labels stay the plain style.
    // Two-line working display, per request: LINE ONE is what the
    // harness is doing — the status label, which for a Bash step now
    // carries the real command — on a single ellipsized row; LINE TWO
    // is the meter: tokens out, tokens in, seconds working. The old
    // one-liner crammed label, counts and the 'tap Stop to interrupt'
    // litany into a single wrapping string.
    final meter = v.token.meter(secs);
    // The frozen frame is also dimmed: motion OR color, never neither,
    // is the honest way to say "the agent is not churning right now".
    // Same rule as the tick guard and the pure-playback hide: a still-
    // open bridge turn means it works WHILE speaking — keep the wheel
    // live through its own voice.
    if (!v.spinnerVisible) {
      return const SizedBox.shrink();
    } // pure playback: voice is the status
    // +97: the thought moved UP onto line one, right behind its label —
    // 'Thinking… · weighing the two splits' — ellipsized to that single
    // row. On its own third row it grew line by line mid-thought and
    // every growth shoved the whole conversation around (the height
    // wobble this kills). The answer draft keeps the third row: it is
    // the reply painting itself, and watching it appear is the point.
    final thought = v.token.thought;
    final shown = v.token.draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _wheel[_frame],
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                // settled = frozen AND dimmed: motion or color, never
                // neither (the +57 honesty rule, extended to the new
                // resting state).
                color: v.token.settled ? scheme.outline : scheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                // The tally-translated activity ('Thinking…') with the
                // live thought riding behind it in italics (+97) — the
                // thought used to own a third row and shove the whole
                // chat with every streamed line. Not the raw status:
                // 'Asking the bridge' must not squat on the line for a
                // minute of actual thinking (+85).
                TextSpan(
                  children: [
                    TextSpan(text: v.token.activityLabel),
                    if (thought.isNotEmpty)
                      TextSpan(
                        text: ' · $thought',
                        style: const TextStyle(fontStyle: FontStyle.italic),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 34, top: 2),
          child: Text(
            meter,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFamily: 'monospace',
            ),
          ),
        ),
        if (shown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 34, top: 2),
            child: Text(
              // The answer painting itself before it is spoken (the draft
              // tail). The thought that used to share this row moved
              // inline (+97).
              shown,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurface),
            ),
          ),
      ],
    );
  }
}
