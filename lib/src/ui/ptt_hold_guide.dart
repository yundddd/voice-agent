/// Push-to-talk hold choreography widget. While a hold is down the mic
/// button leans toward the finger and the two release slides appear
/// beside it: UP interrupts the turn in flight, RIGHT discards the
/// recording un-sent (the assistant's pttUp routes both). The pill for
/// whichever slide the finger has passed lights up and tips the button
/// that way with a coloured halo — the arm thresholds are the very ones
/// release reads (both through one predicate in [PttHold]), so the
/// picture is always exactly "what letting go now would do". At rest, or
/// in conversation mode (which never holds), everything animates away
/// and the button is just the button.
library;

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';

class PttHoldGuide extends StatelessWidget {
  const PttHoldGuide({
    super.key,
    required this.assistant,
    required this.icon,
    required this.color,
    required this.onPrimary,
    required this.onPressed,
  });

  final VoiceAssistant assistant;
  final IconData icon;
  final Color color;
  final Color onPrimary;
  final VoidCallback? onPressed;

  /// The button is FloatingActionButton.large — 96 logical px, which the
  /// pill offsets and the lean fractions below are measured against.
  static const double _fab = 96;
  static const Duration _anim = Duration(milliseconds: 130);

  /// One release slide: a capsule with an arrow and a word, faded and
  /// shrunk away when no hold is down, ghosted while it is only near
  /// (0.92), and popping lit in [armedColor] once its slide is armed.
  Widget _pill({
    required IconData icon,
    required String label,
    required Color armedColor,
    required bool shown,
    required bool armed,
    required ColorScheme scheme,
  }) {
    return AnimatedOpacity(
      duration: _anim,
      opacity: shown ? (armed ? 1 : 0.6) : 0,
      child: IgnorePointer(
        child: AnimatedScale(
          duration: _anim,
          curve: Curves.easeOutBack,
          scale: shown ? (armed ? 1.15 : 0.92) : 0.5,
          child: AnimatedContainer(
            duration: _anim,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: armed ? armedColor : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: armed ? Colors.white : scheme.onSurface,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: armed ? Colors.white : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hold = assistant.pttHoldActive;
    final slide = hold ? assistant.pttSlide : PttSlide.none;
    // The quantised drag, already clamped by pttMove: a flick beyond the
    // threshold leans no further than a just-past-the-line drag.
    final drag = hold ? assistant.pttDrag : Offset.zero;
    // Drift a third of the way after the finger, then tip a further
    // 14 px once a slide is armed — springy rubber band, never dodging
    // out from under the thumb.
    final lean =
        drag * 0.35 +
        switch (slide) {
          PttSlide.up => const Offset(0, -14),
          PttSlide.right => const Offset(14, 0),
          PttSlide.none => Offset.zero,
        };
    final turns =
        (drag.dx / _fab) * 0.08 +
        (slide == PttSlide.up
            ? -0.02
            : slide == PttSlide.right
            ? 0.03
            : 0.0);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // Halo behind the button, painted first so the button itself
        // sits on it: clear at rest, the armed slide's colour while a
        // slide is on (orange cuts, red discards). Same box as the
        // button (the shadow paints beyond it), so the Stack keeps the
        // button's exact footprint in the column.
        AnimatedContainer(
          width: _fab,
          height: _fab,
          duration: _anim,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: switch (slide) {
                  PttSlide.up => Colors.orange.shade700,
                  PttSlide.right => scheme.error,
                  PttSlide.none => color,
                }.withValues(alpha: hold ? 0.5 : 0.0),
                blurRadius: 30,
                spreadRadius: hold ? 6 : -24,
              ),
            ],
          ),
        ),
        AnimatedRotation(
          turns: hold ? turns : 0.0,
          duration: _anim,
          curve: Curves.easeOut,
          child: AnimatedSlide(
            offset: hold ? Offset(lean.dx / _fab, lean.dy / _fab) : Offset.zero,
            duration: _anim,
            curve: Curves.easeOutBack,
            child: AnimatedScale(
              scale: hold ? 1.06 : 1.0,
              duration: _anim,
              child: FloatingActionButton.large(
                onPressed: onPressed,
                backgroundColor: color,
                foregroundColor: onPrimary,
                shape: const CircleBorder(),
                child: Icon(icon, size: 40),
              ),
            ),
          ),
        ),
        // The two slides. A Stack this size spans only the button, so
        // the pills get their room by hanging negative insets over an
        // unclipped edge: interrupt floats above the tip, cancel to
        // the right of it.
        Positioned(
          left: -_fab,
          right: -_fab,
          bottom: _fab + 16,
          child: Center(
            child: _pill(
              icon: Icons.arrow_upward,
              label: 'Interrupt',
              armedColor: Colors.orange.shade700,
              shown: hold,
              armed: slide == PttSlide.up,
              scheme: scheme,
            ),
          ),
        ),
        Positioned(
          left: _fab + 16,
          right: -_fab * 2,
          top: -24,
          bottom: -24,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _pill(
              icon: Icons.arrow_forward,
              label: 'Cancel',
              armedColor: scheme.error,
              shown: hold,
              armed: slide == PttSlide.right,
              scheme: scheme,
            ),
          ),
        ),
      ],
    );
  }
}
