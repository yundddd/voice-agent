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
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';

class HarnessSpinner extends StatefulWidget {
  const HarnessSpinner({super.key, required this.assistant});

  final VoiceAssistant assistant;

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
      // 'it stopped working' when it hadn't. So: freeze only when the
      // harness is PURELY talking — speaking phase with no open bridge
      // turn (harnessElapsed goes to zero the instant `done` closes
      // it). A live turn keeps the wheel turning through its own voice.
      final a = widget.assistant;
      if (a.phase == AssistantPhase.speaking &&
          a.harnessElapsed == Duration.zero) {
        return;
      }
      // +84: the bridge says the TEXT is done and only audio rendering
      // remains ('settled'): nothing left to compute, so the wheel
      // stops even though the socket hasn't closed yet. (The old
      // dozen-seconds of honest-socket dishonest-spinner this kills.)
      if (a.turnSettled) return;
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
    final a = widget.assistant;
    final secs = a.harnessElapsed.inSeconds;
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
    final out = a.tokensOut;
    // +93: `in` is the TURN'S DELTA (growth since this turn anchored),
    // not the raw context — the whole-conversation figure belongs to
    // the context bar alone; billing it to the meter made every turn
    // look like it consumed the entire conversation.
    final inTok = a.tokensIn;
    final meter =
        '${(out > 0 || inTok > 0) ? '${_fmtTok(out)} out · ${_fmtTok(inTok)} in · ' : ''}${secs}s';
    // The frozen frame is also dimmed: motion OR color, never neither,
    // is the honest way to say "the agent is not churning right now".
    // Same rule as the tick guard and the pure-playback hide: a still-
    // open bridge turn means it works WHILE speaking — keep the wheel
    // live through its own voice.
    final talking =
        a.phase == AssistantPhase.speaking &&
        a.harnessElapsed == Duration.zero;
    if (talking) {
      return const SizedBox.shrink();
    } // pure playback: voice is the status
    // The thinking, spelled out — and the answer painted before it is
    // spoken — ride a THIRD line when the bridge streamed them (max two
    // lines so a rambling thought never shoves the chat around).
    final thought = a.tokenThought;
    final draft = a.tokenDraft;
    final shown = thought.isNotEmpty ? thought : draft;
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
                color: a.turnSettled ? scheme.outline : scheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                // The tally-translated activity ('Thinking…'), not the
                // raw status: 'Asking the bridge' must not squat on the
                // line for a minute of actual thinking (+85).
                a.activityLabel,
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
              shown,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: thought.isNotEmpty
                    ? scheme.onSurfaceVariant
                    : scheme.onSurface,
                fontStyle: thought.isNotEmpty ? FontStyle.italic : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// 12400 -> '12.4k', 467232 -> '467k', 1_250_000 -> '1.3M' (the bridge
/// library owns the shared shape — see fmtTokenCount).
String _fmtTok(int n) => fmtTokenCount(n);
