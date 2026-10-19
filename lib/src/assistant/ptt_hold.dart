/// Push-to-talk hold choreography as a pure state machine.
///
/// Raw pointer edges from a Listener around the button: unlike a gesture
/// recognizer these never contest (or lose to) the button's own tap, and
/// the pointer stays bound to this path from down to up, so releasing a
/// few centimetres off the button still closes the mic.
///
/// Release GESTURE routes the new prompt when a harness turn is in
/// flight (v0.1.0+25): the press itself detaches that turn (the bridge
/// backgrounds it — the tool call keeps working, output is dropped) and
/// the mic opens over it. Slide the finger UP past a thumb's width and
/// release to INTERRUPT: a mere thinking turn is cut short in-band (
/// bridge `interrupt=1`, the process survives) so your prompt starts in a
/// heartbeat; an open tool still can't be cut and your prompt queues
/// behind it. Release in place or slide RIGHT to QUEUE politely
/// (`interrupt=0`) — since +163 that queue is a STEER: over a running
/// tool the prompt is folded into that very turn at the tool's result
/// (the bridge's foldPending), heard at the harness's next pause;
/// behind mere thinking, or when no boundary is left in the turn, it
/// keeps the old promise: the turn finishes its work first, then your
/// prompt goes next. A quick tap (< tap threshold) is the old hard stop:
/// detach + /stop. With no harness turn in flight every release is the
/// plain send-to-local-reply path, exactly as before.
///
/// This class answers "what is the hold" — pointer count, slide armed,
/// live lean, release classification. The assistant decides what each
/// edge DOES to the mic and the turn.
library;

import 'dart:ui' show Offset;

import '../common/clock.dart';
import 'state.dart';

/// What a release means. [stray] = a release with no recorded press
/// (dropped event, double release): loud in the journal, because this
/// is one way a message vanishes without a trace. [redraw] = the armed
/// slide or the lean were on screen and must be wiped now (a released
/// hold shows no armed direction and no lean immediately, not once the
/// transcribe path next notifies).
typedef PttRelease = ({
  bool up,
  bool right,
  bool stray,
  int heldMs,
  bool redraw,
  // How far the finger travelled between press and release, whatever
  // slide (if any) it spelled: a too-short release only earns the
  // mid-turn hard stop when it never moved — a drift that fell short
  // of a slide threshold was a mind half-changed, not a tap (+132).
  double driftPx,
});

class PttHold {
  PttHold({
    required this.clock,
    this.slideUpPx = 48,
    this.slideRightPx = 48,
    this.leanMaxPx = 72,
    this.tapStopMs = 400,
    this.tapSlopPx = 24,
  });

  final Clock clock;

  /// Slide-up-vs-rest distances, logical px: a deliberate thumb drag off
  /// the button, small enough to never trigger from a rolling press.
  final double slideUpPx;
  final double slideRightPx;

  /// Past this many px of drag, more travel adds no more visible lean —
  /// a far flick and a just-past-the-threshold drag look identical, and
  /// the button never dodges out from under the thumb.
  final double leanMaxPx;

  /// Press-and-release faster than this while a turn runs is a TAP: the
  /// hard stop (detach + /stop), the old tap-Stop behaviour, not a hold.
  final int tapStopMs;

  /// Below this drag distance a quick release was a TAP and nothing
  /// else: between slop and the slide thresholds the finger meant
  /// something, and the too-short hard stop must not read a stalling
  /// swipe as "stop the harness" (+132 — the gentle right that
  /// cancelled the tool call).
  final double tapSlopPx;

  // Debug counters (shown under the button in debug mode): press/release
  // edges observed — proves on-device whether holds reach the Listener.
  int edgeCount = 0;

  int _pointers = 0; // one hold; extra fingers are ignored
  Offset? _downPos; // press point: the release delta decides the gesture
  DateTime _downAt = DateTime.fromMillisecondsSinceEpoch(0);
  PttSlide _slide = PttSlide.none;
  Offset _drag = Offset.zero;

  /// This hold opened on top of an in-flight harness turn (the
  /// assistant sets it at the DOWN edge when the turn was detached).
  bool bridgeHold = false;

  int get pointers => _pointers;
  PttSlide get slide => _slide;
  Offset get drag => _drag;

  /// A push-to-talk hold whose mic opened on top of a running harness
  /// turn — the UI says "release to queue / slide up to interrupt" while
  /// this is set and the button is being held.
  bool get holdOverTurn => bridgeHold && _pointers > 0;

  /// Milliseconds the current (or just ended) press has been held. Only
  /// meaningful mid-turn: on the stray-release branch [release] reports
  /// -1 instead, because _downAt still wears the epoch there and
  /// printing its difference produced the nonsense
  /// 'held=1792195121943ms' that made a dropped press look like a
  /// two-week hold.
  int get heldMs => clock().difference(_downAt).inMilliseconds;

  /// The release classification as a pure function of the drag, shared
  /// by release and the live hold visualisation — the armed state on
  /// screen can never disagree with what releasing now will do, because
  /// both read this one predicate. (The two are exclusive by
  /// construction: a delta cannot be both vertical-dominant and
  /// horizontal-dominant.)
  PttSlide slideOf(Offset d) {
    if (d.dy < -slideUpPx && d.dy.abs() > d.dx.abs()) return PttSlide.up;
    if (d.dx > slideRightPx && d.dx.abs() > d.dy.abs()) return PttSlide.right;
    return PttSlide.none;
  }

  /// Registers a press edge. Returns true when this is the first pointer
  /// of the hold — i.e. the moment the mic should open. Android can
  /// renumber pointers mid-sequence (index reassignment when a second
  /// finger lifts) and may drop the matching release; the assistant
  /// caps the hold with its own timer rather than record forever.
  bool down(Offset? at) {
    _downPos = at;
    _downAt = clock();
    _slide = PttSlide.none; // a fresh hold starts slid nowhere
    _drag = Offset.zero;
    _pointers++;
    return _pointers == 1;
  }

  /// [pttMove] rides every pointer drift while a hold is down, so the
  /// hold guide can lean the button toward the finger and light the
  /// slide it is armed on. Quantises the lean to 4-px steps and reports
  /// whether anything moved: a 120-Hz finger stream must not rebuild
  /// the screen at 120 Hz.
  bool move(Offset at) {
    final start = _downPos;
    if (start == null || _pointers == 0) return false;
    final d = at - start;
    final slide = slideOf(d);
    final q = Offset(
      (d.dx.clamp(-leanMaxPx, leanMaxPx) / 4).roundToDouble() * 4,
      (d.dy.clamp(-leanMaxPx, leanMaxPx) / 4).roundToDouble() * 4,
    );
    if (q == _drag && slide == _slide) return false;
    _drag = q;
    _slide = slide;
    return true;
  }

  /// The release edge: consumes the press point (a stale-drag reading
  /// stays harmless even on the stray branch) and clears the visuals —
  /// a released hold shows no armed direction and no lean immediately,
  /// not once the transcribe path next notifies.
  PttRelease release(Offset? at) {
    final start = _downPos;
    _downPos = null;
    var up = false, right = false;
    if (at != null && start != null) {
      final slide = slideOf(at - start);
      up = slide == PttSlide.up;
      right = slide == PttSlide.right;
    }
    final stray = _pointers == 0;
    if (!stray) {
      _pointers--;
    }
    final held = stray ? -1 : clock().difference(_downAt).inMilliseconds;
    final redraw = !visualsClear;
    final drift = (at != null && start != null) ? (at - start).distance : 0.0;
    _slide = PttSlide.none;
    _drag = Offset.zero;
    return (
      up: up,
      right: right,
      stray: stray,
      heldMs: held,
      redraw: redraw,
      driftPx: drift,
    );
  }

  /// Back gesture / system interruption: behave exactly like a release
  /// with no slide (never discard the recording, never a hard stop by
  /// accident), so the mic can never be left open.
  void cancel() {
    _pointers = 0;
    _downPos = null;
    _slide = PttSlide.none;
    _drag = Offset.zero;
  }

  /// The live-visual state zeroed (release/cancel already did it; this
  /// reports whether a repaint is warranted).
  bool get visualsClear => _slide == PttSlide.none && _drag == Offset.zero;
}
