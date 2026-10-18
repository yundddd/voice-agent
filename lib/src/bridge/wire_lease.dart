/// The quiet-wire watchdog: the lease every bridge connection takes out
/// on the phone's belief that it still has an EAR on the turn.
///
/// The bridge pings an SSE comment (`: ping`) every 15 s while a turn is
/// open, so a listening socket that goes quiet for one interval plus
/// slack is LYING: Android froze the process, the Wi-Fi handoff or a
/// sleeping tailnet black-holed the route, and events relayed down it
/// are simply gone. This class owns the "bytes were seen at T" clock and
/// the single re-armable check timer; when the window expires it asks
/// its guards (hidden? audio still draining?) and otherwise reports the
/// wire dead — the owner's reattach ladder takes a fresh view before the
/// harness relays more of the turn into the void.
library;

import 'dart:async';

import '../common/clock.dart';
import '../common/sinks.dart';

class WireLease {
  WireLease({
    required this.scheduler,
    required this.clock,
    required this.onQuiet,
    required this.attached,
    required this.paused,
    required this.audioDraining,
    this.quietWindow = const Duration(
      seconds: 24,
    ), // ping 15 s + retransmit slack
  });

  final Scheduler scheduler;
  final Clock clock;

  /// The window expired for real: the view is a zombie.
  final void Function(Duration quiet) onQuiet;

  /// A turn is in flight on this lease (the assistant's busy flag).
  final bool Function() attached;

  /// App hidden: resumeConversation re-leases by itself, so a check
  /// while paused must no-op (and hide pauses the timers anyway).
  final bool Function() paused;

  /// Queued audio from before the silence is still draining: let the
  /// user hear it out before the hop cuts the seam (the reattach
  /// replays everything the bridge queued unheard anyway).
  final bool Function() audioDraining;

  /// ping 15 s + retransmit slack: longer than any legitimate silence
  /// the bridge can produce while a turn is open.
  final Duration quietWindow;

  DateTime _aliveAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _check;

  /// How long the wire has been silent.
  Duration get quietFor => clock().difference(_aliveAt);

  /// Record that the socket delivered bytes (event frame or keep-alive
  /// ping): the connection lives, and its watchdog gets a fresh quiet
  /// lease from this moment.
  void markAlive() {
    _aliveAt = clock();
    if (attached() && !paused()) _arm(quietWindow);
  }

  /// A fresh bridge stream (or a resumed app) starts its lease now — its
  /// first bytes may still be crossing the wire, and the kernel's receive
  /// buffer only drains on resume, so grant the full window up front.
  void armWatch() {
    _aliveAt = clock();
    _arm(quietWindow);
  }

  void _arm(Duration after) {
    _check?.cancel();
    _check = scheduler.after(after, _fired);
  }

  void cancel() {
    _check?.cancel();
    _check = null;
  }

  void _fired() {
    _check = null;
    if (paused()) return; // resumeConversation re-leases via markAlive
    if (!attached()) return; // this stream's turn already moved on
    final quiet = quietFor;
    if (quiet < quietWindow) {
      _arm(quietWindow - quiet); // dribbling bytes: check again next slice
      return;
    }
    if (audioDraining()) {
      _arm(quietWindow);
      return;
    }
    onQuiet(quiet);
  }
}

/// The reattach retry ladder. The chain exists because waking phones
/// wake their NETWORK late: one failed probe must never drop a live turn.
/// ~63 s of network-wake grace per orphaned turn.
const kReattachDelays = [
  Duration(seconds: 2),
  Duration(seconds: 6),
  Duration(seconds: 15),
  Duration(seconds: 40),
];

/// The next probe's delay for ladder rung [step], or null when the
/// ladder is spent (the caller retires the orphan).
Duration? reattachDelay(int step) =>
    step < kReattachDelays.length ? kReattachDelays[step] : null;
