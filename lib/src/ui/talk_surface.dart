/// The bottom of the screen IS the button. Push-to-talk no longer hides
/// behind a 96 px FAB you aim at: the whole panel answers a press from
/// anywhere in it, because the thumb already sits there — making you
/// hunt for a circle in the dark was the old shape, not the good one.
///
/// Three stories it tells at once:
///
///  * THE PRESS. Down anywhere records the hold (the assistant's
///    PttHold classifies the release exactly as before — same
///    thresholds, same queue/interrupt/discard semantics). Where the
///    finger lands seeds a ripple that expands from that point.
///
///  * THE VOICE. While the hold is down, mic energy (the view's
///    ptt.micLevel — capture-meter RMS, fast attack, slow decay) drives
///    the ripple field: silence breathes a slow ~3/s pulse, speech
///    storm-fires up to ~30/s, and size scales with amplitude. The
///    waveform, seen — you watch yourself being heard, which is also
///    the honest mic-is-really-open proof the old FAB never gave.
///
///  * THE GESTURE (+272, Tim's brief replacing the flat bands): two
///    CONES of light open from the finger itself. Straight UP the
///    INTERRUPT cone — amber beams spreading ±30° from the press
///    point; to the RIGHT the DISCARD cone — red beams on the level.
///    They fade in the moment a hold starts (the gestures only exist
///    while you are holding), widen and brighten as the finger leans
///    toward a direction, and IGNITE when the slide arms — and the
///    arm state is read from the same PttHold predicate the release
///    will consult, so the picture can never disagree with what
///    releasing now would do. The words name themselves inside each
///    cone: INTERRUPT, DISCARD — a direction you can see, not a
///    legend you have to remember.
///
/// Ripples and the field keep painting from their own ticker, but the
/// state they paint is the projected view (ptt.holdActive/slide/
/// micLevel) — the widget owns animation, never truth.
library;

import 'dart:math' show cos, sin;

import 'package:flutter/material.dart';

import '../assistant/state.dart';
import '../assistant/view.dart';

class TalkSurface extends StatefulWidget {
  const TalkSurface({
    super.key,
    required this.source,
    required this.icon,
    required this.color,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
    required this.onTap,
    this.height = 208,
  });

  /// Live projection — re-read every animation frame (the mic level
  /// moves on its own clock between screen repaints, like the
  /// spinner's counter does).
  final ViewSource source;

  /// The phase glyph (same law the old FAB painted: mic / graphic_eq /
  /// psychology / volume / error).
  final IconData icon;
  final Color color;

  /// Pointer edges with GLOBAL positions (the assistant's hold geometry
  /// is global; the ripple origin is computed locally inside).
  final ValueChanged<Offset> onPointerDown;
  final ValueChanged<Offset> onPointerMove;
  final ValueChanged<Offset> onPointerUp;
  final VoidCallback onPointerCancel;

  /// The classic tap (conversation toggle / the hard-stop fallback when
  /// the hold could not open the mic).
  final VoidCallback onTap;
  final double height;

  @override
  State<TalkSurface> createState() => _TalkSurfaceState();
}

class _Ripple {
  _Ripple(this.at, this.bornMs, this.strength);
  final Offset at;
  final int bornMs; // clock elapsed at spawn
  final double strength; // 0..1 — the size and light the wave carries

  static const lifeMs = 1200;
}

class _TalkSurfaceState extends State<TalkSurface>
    with SingleTickerProviderStateMixin {
  // The controller is only the frame signal (it repaints the painter);
  // wave ages read a plain stopwatch, because AnimationController.elapsed
  // died with Flutter 3.47 — and a stopwatch is honest about "when the
  // hold began" anyway. It runs ONLY while a hold is down or waves are
  // still alive: an idle screen must not burn frames.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(hours: 1),
  );
  final Stopwatch _stop = Stopwatch();
  final List<_Ripple> _ripples = <_Ripple>[];
  Offset _pointerLocal = Offset.zero; // the ripple origin while held
  double _spawnAcc = 0;
  int _lastFrameMs = 0;

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  void _wakeClock() {
    if (_clock.isAnimating) return;
    // Fresh epoch: the field is empty whenever the clock was parked
    // (_advance only stops it with nothing alive), so a reset never
    // strands a wave with a future birthday.
    _stop
      ..reset()
      ..start();
    _lastFrameMs = 0;
    _clock.repeat();
  }

  void _down(PointerDownEvent e) {
    _pointerLocal = e.localPosition;
    _wakeClock();
    _ripples.add(_Ripple(e.localPosition, _nowMs, 0.9)); // the press wave
    widget.onPointerDown(e.position);
  }

  void _move(PointerMoveEvent e) {
    _pointerLocal = e.localPosition;
    widget.onPointerMove(e.position);
  }

  int get _nowMs => _stop.elapsedMilliseconds;

  /// The per-frame world: age the field, breathe new waves while the
  /// hold is down (rate AND strength follow the meter), and stop the
  /// ticker once nothing is moving any more.
  void _advance(PttGuide ptt) {
    final now = _nowMs;
    final dt = now - _lastFrameMs;
    _lastFrameMs = now;
    if (ptt.holdActive) {
      // Silence = a slow ~3/s heartbeat so the surface reads alive;
      // loud speech storm-fires to ~33/s. Both the rate and the per-
      // wave strength carry the amplitude — the wave IS the meter.
      _spawnAcc += dt * (3.0 + 30.0 * ptt.micLevel) / 1000.0;
      while (_spawnAcc >= 1) {
        _spawnAcc -= 1;
        if (_ripples.length < 64) {
          _ripples.add(_Ripple(_pointerLocal, now, 0.25 + 0.75 * ptt.micLevel));
        }
      }
    } else {
      _spawnAcc = 0;
    }
    _ripples.removeWhere((r) => now - r.bornMs > _Ripple.lifeMs);
    if (_ripples.isEmpty && !ptt.holdActive && _clock.isAnimating) {
      _clock.stop(); // field empty: park both clocks until the next press
      _stop.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: (e) => widget.onPointerUp(e.position),
          onPointerCancel: (_) => widget.onPointerCancel(),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: ColoredBox(
              color: scheme.surfaceContainerLow,
              child: AnimatedBuilder(
                animation: _clock,
                builder: (context, _) {
                  final v = widget.source(); // fresh on EVERY frame
                  _advance(v.ptt);
                  return _body(context, v.ptt, scheme);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PttGuide ptt, ColorScheme scheme) {
    final armed = ptt.holdActive ? ptt.slide : PttSlide.none;
    // The lean the state machine reports (quantised, clamped at
    // leanMaxPx=72 by PttHold.move). The arm threshold is 48 — the
    // progress mapping below stretches 8→72 px to 0→1 so the cone is
    // FULL at the moment the slide arms (the exact threshold number
    // lives on PttHold; this only has to read right, the ARMED truth
    // never comes from here: it rides ptt.slide, the release's own
    // predicate).
    final drag = ptt.holdActive ? ptt.drag : Offset.zero;
    final upProg = ((-drag.dy - 8) / 64).clamp(0.0, 1.0);
    final rightProg = ((drag.dx - 8) / 64).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        // The ripple field, clipped by the rounded panel.
        CustomPaint(
          painter: _RipplePainter(
            ripples: _ripples,
            now: _nowMs,
            base: widget.color,
          ),
        ),
        // The phase glyph: the press answer, dimmed under a live hold
        // (the waves and cones are the conversation now, not the icon).
        Center(
          child: Icon(
            widget.icon,
            size: 44,
            color: ptt.holdActive
                ? widget.color.withValues(alpha: 0.25)
                : widget.color,
          ),
        ),
        // ── UP = INTERRUPT: the amber cone, apex at the finger ──
        _cone(
          context,
          shown: ptt.holdActive,
          prog: upProg,
          armed: armed == PttSlide.up,
          color: Colors.amber.shade700,
          scheme: scheme,
          up: true,
          label: 'INTERRUPT',
          mic: ptt.micLevel,
        ),
        // ── RIGHT = DISCARD: the red cone, same shape on the level ──
        _cone(
          context,
          shown: ptt.holdActive,
          prog: rightProg,
          armed: armed == PttSlide.right,
          color: scheme.error,
          scheme: scheme,
          up: false,
          label: 'DISCARD',
          mic: ptt.micLevel,
        ),
      ],
    );
  }

  /// One gesture cone: invisible at rest, a faint fan of beams the
  /// instant the hold opens, widening and brightening with the lean,
  /// IGNITED (solid fan, bright edge, white word) when armed. The
  /// apex is the press point, so the beam literally comes out from
  /// under the thumb and points where the thumb is going.
  Widget _cone(
    BuildContext context, {
    required bool shown,
    required double prog,
    required bool armed,
    required Color color,
    required ColorScheme scheme,
    required bool up,
    required String label,
    required double mic,
  }) {
    return IgnorePointer(
      // The cones sit INSIDE the talk area — a press landing on one is
      // still a press landing on the button; the labels never eat them.
      ignoring: true,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 130),
        opacity: shown ? 1 : 0,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            final origin = _coneOrigin(size);
            // The word rides the axis at 62% of the live fan radius —
            // the SAME geometry the painter uses, so glyph and beam
            // cannot drift apart.
            final r = _ConePainter.radiusFor(prog, armed) * 0.62;
            final ax = up ? 0.0 : 1.0, ay = up ? -1.0 : 0.0;
            final at = origin + Offset(r * ax, r * ay);
            return Stack(
              children: [
                CustomPaint(
                  painter: _ConePainter(
                    origin: origin,
                    prog: prog,
                    armed: armed,
                    color: color,
                    up: up,
                    mic: mic,
                  ),
                  size: size,
                ),
                Align(
                  alignment: Alignment(
                    (2 * at.dx / size.width - 1).clamp(-1.0, 1.0),
                    (2 * at.dy / size.height - 1).clamp(-1.0, 1.0),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: armed
                          ? Colors.white
                          : scheme.onSurfaceVariant.withValues(alpha: 0.9),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The cone's apex: the live finger point while it is down (the
  /// ripple origin already tracks it), falling back to the panel's
  /// bottom-centre — where a thumb naturally sits — before the first
  /// move event of the hold.
  Offset _coneOrigin(Size size) =>
      _pointerLocal == Offset.zero && _ripples.isEmpty
      ? Offset(size.width / 2, size.height * 0.62)
      : _pointerLocal;
}

/// The +272 gesture cone: a ±30° fan of BEAMS from the apex along the
/// gesture axis (up for INTERRUPT, right for DISCARD). Faint always
/// while held; fill, ray count glow and edge stroke all scale with the
/// lean; arm state arrives from PttHold itself so the picture can only
/// ever show what releasing right now would do. The word rides the
/// axis inside the fan.
class _ConePainter extends CustomPainter {
  _ConePainter({
    required this.origin,
    required this.prog,
    required this.armed,
    required this.color,
    required this.up,
    required this.mic,
  });

  final Offset origin;
  final double prog; // 0..1 lean toward this cone's direction
  final bool armed;
  final Color color;
  final bool up; // axis: -90° when up, 0° (right) otherwise
  final double mic; // beam pulse from the capture meter

  static const _halfSpread = 0.523; // ±30°
  static double radiusFor(double prog, bool armed) =>
      70 + 170 * prog + (armed ? 34 : 0);

  double get _axis => up ? -1.5708 : 0.0;

  @override
  void paint(Canvas canvas, Size size) {
    final r = radiusFor(prog, armed);
    final a0 = _axis - _halfSpread;
    final fan = Path()
      ..moveTo(origin.dx, origin.dy)
      ..lineTo(origin.dx + _cx(a0) * r, origin.dy + _cy(a0) * r)
      ..arcTo(
        Rect.fromCircle(center: origin, radius: r),
        a0,
        _halfSpread * 2,
        false,
      )
      ..close();
    // The fill: translucent always, brighter under the lean, and a
    // stronger base when armed so the decision reads before the word
    // is even parsed.
    canvas.drawPath(
      fan,
      Paint()
        ..shader = RadialGradient(
          // The apex IS the gradient centre (the shader rect is the
          // fan's circle): bright at the thumb, fading to the rim.
          center: Alignment.center,
          radius: 1.0,
          colors: [
            color.withValues(alpha: 0.34 + 0.30 * prog + (armed ? 0.25 : 0)),
            color.withValues(alpha: 0.04 + 0.10 * prog),
          ],
          tileMode: TileMode.clamp,
        ).createShader(Rect.fromCircle(center: origin, radius: r)),
    );
    // The BEAMS: five rays fanning the sector; the meter pulses their
    // weight so the cones breathe with the voice, not just the lean.
    final beam = Paint()
      ..strokeWidth = 1.2 + 2.6 * prog + 1.4 * mic + (armed ? 1.6 : 0)
      ..color = color.withValues(alpha: armed ? 0.85 : 0.22 + 0.45 * prog);
    for (var k = -2; k <= 2; k++) {
      final a = _axis + k * (_halfSpread / 2.4);
      canvas.drawLine(
        origin,
        Offset(origin.dx + _cx(a) * r, origin.dy + _cy(a) * r),
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
          ..strokeWidth = 2.4
          ..color = color.withValues(alpha: 0.9),
      );
    }
  }

  static double _cx(double a) => cos(a);
  static double _cy(double a) => sin(a);

  @override
  bool shouldRepaint(covariant _ConePainter old) =>
      old.prog != prog ||
      old.armed != armed ||
      old.origin != origin ||
      old.mic != mic;
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.ripples,
    required this.now,
    required this.base,
  });

  final List<_Ripple> ripples;
  final int now;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in ripples) {
      final age = (now - r.bornMs) / _Ripple.lifeMs;
      if (age < 0 || age > 1) continue;
      final out = Curves.easeOutCubic.transform(age);
      // Louder ⇒ the wave starts wider and travels further; every wave
      // starts AT the finger and only fades on its way out.
      final radius = 12.0 + (60.0 + 200.0 * r.strength) * out;
      final alpha = (1 - age) * (1 - age) * (0.12 + 0.45 * r.strength);
      canvas.drawCircle(
        r.at,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 + 4.5 * (1 - age) * r.strength
          ..color = base.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter old) => true;
}
