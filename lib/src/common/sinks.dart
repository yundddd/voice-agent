/// Tiny shared seams the assistant uses to talk to the rest of the app:
/// plain typedefs and one-shot-scheduler interfaces so every collaborator
/// takes callbacks instead of reaching into the orchestrator, and tests
/// can run watchdogs, fades and backoff ladders on a fake clock instead
/// of sleeping on real seconds.
library;

import 'dart:async';

/// Receives one line of human-readable diagnostics: ring buffer on the
/// debug screen, journal on disk, and (relayed) the desktop's journalctl.
typedef DebugSink = void Function(String line);

/// Repaint hook: the assistant calls this whenever observable state moved.
typedef Repaint = void Function();

/// A scheduler seam around one-shot [Timer]s.
abstract interface class Scheduler {
  Timer after(Duration delay, void Function() callback);
}

/// The production scheduler.
class WallScheduler implements Scheduler {
  const WallScheduler();
  @override
  Timer after(Duration delay, void Function() callback) =>
      Timer(delay, callback);
}

class _Pending {
  _Pending(this.at, this.callback);
  final DateTime at;
  final void Function() callback;
}

/// Test scheduler: records pending timers and fires everything due, in
/// order, when [advance] says time moved. Returned handles cancel through
/// the scheduler, exactly like real timers.
class FakeScheduler implements Scheduler {
  FakeScheduler([DateTime? start]) : now = start ?? DateTime(2026, 1, 1);

  DateTime now;
  final List<_Pending> _pending = [];

  int get pendingCount => _pending.length;

  @override
  Timer after(Duration delay, void Function() callback) {
    final p = _Pending(now.add(delay), callback);
    _pending.add(p);
    return _FakeTimer(this, p);
  }

  /// Moves time forward and fires everything due, in order.
  void advance(Duration d) {
    now = now.add(d);
    final due = _pending.where((p) => !p.at.isAfter(now)).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    _pending.removeWhere(due.contains);
    for (final p in due) {
      p.callback();
    }
  }

  void _cancel(_Pending p) => _pending.remove(p);
}

class _FakeTimer implements Timer {
  _FakeTimer(this._owner, this._p);
  final FakeScheduler _owner;
  final _Pending _p;

  @override
  void cancel() => _owner._cancel(_p);
  @override
  bool get isActive => _owner._pending.contains(_p);
  @override
  int get tick => 0;
}
