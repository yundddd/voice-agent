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
///  * THE GESTURE (+273): the cones the +272 volley opened here were
///    lifted to a full-screen overlay the next day (see
///    cone_overlay.dart) — a thumbnail-sized fan under the thumb is a
///    detail, not a sign. The panel keeps the ripple field and the
///    press wave; the screen above it wears the decision.
///
/// Ripples and the field keep painting from their own ticker, but the
/// state they paint is the projected view (ptt.holdActive/slide/
/// micLevel) — the widget owns animation, never truth.
library;

import 'package:flutter/material.dart';

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
        // (the waves are the conversation now, not the icon — and the
        // gesture cones that answer the lean live on the SCREEN
        // above, +273).
        Center(
          child: Icon(
            widget.icon,
            size: 44,
            color: ptt.holdActive
                ? widget.color.withValues(alpha: 0.25)
                : widget.color,
          ),
        ),
      ],
    );
  }
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
