/// The PTT decision, painted across the WHOLE screen.
///
/// +273 (Tim: 'make the cones not bounded by the push-to-talk button
/// and bigger — an overlay so users can clearly see what they are
/// doing'): the +272 cones lived inside the 128-px talk panel, which
/// made them a beautiful detail rather than a legible sign — a fan
/// the size of a thumbnail under a thumb cannot be read at a glance.
/// The overlay lifts the same two cones to the full viewport: apex
/// still fixed at the point the finger went DOWN (the press point,
/// not the current finger point — the cone is a compass rose, not a
/// trail), but reaching a third of a screen at rest and igniting
/// across half of it when armed. Nothing eats touches (IgnorePointer
/// over the whole area: the hold lives in the talk panel, and a
/// finger that wanders off the panel mid-hold must keep steering the
/// cones, not fight them).
///
/// The arm truth is the SAME PttSlide the release decision reads (it
/// rides the projected PttGuide) — the picture can only ever show
/// what releasing right now would do. Straight UP is INTERRUPT
/// (amber); to the RIGHT is DISCARD (error red).
library;

import 'dart:math' show cos, sin;

import 'package:flutter/material.dart';

import '../assistant/state.dart';
import '../assistant/view.dart';

class ConeOverlay extends StatelessWidget {
  const ConeOverlay({
    super.key,
    required this.visible,
    required this.origin,
    required this.guide,
    required this.errorColor,
    required this.idleLabelColor,
  });

  /// Cones exist while a hold is down — the gestures only exist
  /// mid-hold (+220's law, lifted whole).
  final bool visible;

  /// The press point, in THIS overlay's coordinates (the screen fixed
  /// it at the DOWN edge).
  final Offset origin;
  final PttGuide guide;
  final Color errorColor;
  final Color idleLabelColor;

  static const _interruptColor = Color(0xFFFFA000); // amber.shade700

  // The lean the state machine reports is quantised to 4 px and
  // clamped at 72; the arm threshold is 48 (PttHold defaults). The
  // progress mapping stretches 8→72 px to 0→1 so the cone is FULL at
  // the moment the slide arms; the ARMED truth never comes from this
  // math — it rides guide.slide, the release's own predicate.
  static double _prog(double axisPx) => ((axisPx - 8) / 64).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final drag = visible && guide.holdActive ? guide.drag : Offset.zero;
    final slide = visible ? guide.slide : PttSlide.none;
    final upProg = _prog(-drag.dy);
    final rightProg = _prog(drag.dx);
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: visible ? 1 : 0,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            return Stack(
              children: [
                CustomPaint(
                  painter: _ConePainter(
                    origin: origin,
                    prog: upProg,
                    armed: slide == PttSlide.up,
                    color: _interruptColor,
                    up: true,
                    mic: guide.micLevel,
                    screen: size,
                  ),
                  size: size,
                ),
                _label(
                  context,
                  label: 'INTERRUPT',
                  armed: slide == PttSlide.up,
                  prog: upProg,
                  up: true,
                ),
                CustomPaint(
                  painter: _ConePainter(
                    origin: origin,
                    prog: rightProg,
                    armed: slide == PttSlide.right,
                    color: errorColor,
                    up: false,
                    mic: guide.micLevel,
                    screen: size,
                  ),
                  size: size,
                ),
                _label(
                  context,
                  label: 'DISCARD',
                  armed: slide == PttSlide.right,
                  prog: rightProg,
                  up: false,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The word riding its axis at 62% of the live fan radius — the
  /// SAME geometry the painter uses, so glyph and beam cannot drift
  /// apart. A real Text (findable, announced), not painted pixels.
  Widget _label(
    BuildContext context, {
    required String label,
    required bool armed,
    required double prog,
    required bool up,
  }) {
    return LayoutBuilder(
      builder: (context, box) {
        final r = _ConePainter.radiusFor(prog, armed) * 0.62;
        final at = origin + Offset(up ? 0 : r, up ? -r : 0);
        return Align(
          alignment: Alignment(
            (2 * at.dx / box.maxWidth - 1).clamp(-1.0, 1.0),
            (2 * at.dy / box.maxHeight - 1).clamp(-1.0, 1.0),
          ),
          child: Text(
            label,
            style: TextStyle(
              // +292: the armed label is the theme's highest-emphasis
              // ink (the warm near-white — same weight off the
              // amber, no hard blue-white off-palette), and the
              // legibility shadow asks the scheme's shadow role.
              color: armed
                  ? ColorScheme.of(context).onSurface
                  : idleLabelColor.withValues(alpha: 0.9),
              fontWeight: FontWeight.w800,
              fontSize: 15,
              letterSpacing: 3,
              shadows: [
                Shadow(
                  color: ColorScheme.of(context).shadow.withValues(alpha: 0.35),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One cone of light: a ±32° fan of BEAMS from the apex along the
/// gesture axis (up for INTERRUPT, right for DISCARD). Faint always
/// while held; fill, ray weight and rim scale with the lean; the
/// screen-relative size means the choice is readable at a glance from
/// anywhere on the display.
class _ConePainter extends CustomPainter {
  _ConePainter({
    required this.origin,
    required this.prog,
    required this.armed,
    required this.color,
    required this.up,
    required this.mic,
    required this.screen,
  });

  final Offset origin;
  final double prog; // 0..1 lean toward this cone's direction
  final bool armed;
  final Color color;
  final bool up; // axis: straight up, or due right
  final double mic; // beam pulse from the capture meter
  final Size screen;

  static const _halfSpread = 0.559; // ±32°

  /// Screen-scale geometry: a quarter of the shorter edge at rest,
  /// three-quarters at full lean, and a generous ignition margin —
  /// the armed fan unmistakably CLEARS the conversation it overlays.
  static double radiusFor(double prog, bool armed) {
    final base = 140.0;
    return base + 520 * prog + (armed ? 180 : 0);
  }

  double get _axis => up ? -1.5708 : 0.0;

  @override
  void paint(Canvas canvas, Size size) {
    final r = radiusFor(prog, armed);
    final a0 = _axis - _halfSpread;
    final fan = Path()
      ..moveTo(origin.dx, origin.dy)
      ..lineTo(origin.dx + cos(a0) * r, origin.dy + sin(a0) * r)
      ..arcTo(
        Rect.fromCircle(center: origin, radius: r),
        a0,
        _halfSpread * 2,
        false,
      )
      ..close();
    // The fill: bright at the thumb, fading to the rim — and a
    // stronger base when armed, so the decision reads before the
    // word is even parsed.
    canvas.drawPath(
      fan,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 1.0,
          colors: [
            color.withValues(alpha: 0.30 + 0.28 * prog + (armed ? 0.22 : 0)),
            color.withValues(alpha: 0.03 + 0.09 * prog),
          ],
          tileMode: TileMode.clamp,
        ).createShader(Rect.fromCircle(center: origin, radius: r)),
    );
    // The BEAMS: five rays fanning the sector; the meter pulses their
    // weight so the cones breathe with the voice, not just the lean.
    final beam = Paint()
      ..strokeWidth = 1.6 + 3.4 * prog + 1.8 * mic + (armed ? 2.2 : 0)
      ..color = color.withValues(alpha: armed ? 0.85 : 0.20 + 0.45 * prog);
    for (var k = -2; k <= 2; k++) {
      final a = _axis + k * (_halfSpread / 2.4);
      canvas.drawLine(
        origin,
        Offset(origin.dx + cos(a) * r, origin.dy + sin(a) * r),
        beam,
      );
    }
    // The arc rim: only once the fan means it.
    if (armed) {
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: r),
        a0,
        _halfSpread * 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0
          ..color = color.withValues(alpha: 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ConePainter old) =>
      old.prog != prog ||
      old.armed != armed ||
      old.origin != origin ||
      old.mic != mic ||
      old.screen != screen;
}
