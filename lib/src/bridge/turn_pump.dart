/// The queue + wake plumbing shared by BOTH harness event loops (the
/// /talk loop and the /attach reattach loop) — the reason they used to be
/// a 60-line copy-paste pair with subtly divergent bug fixes.
///
/// Manual subscription, not await-for: a barge-in must be able to detach
/// the phone from a turn at any moment WITHOUT waiting for the next SSE
/// event to finally break the loop (await-for only reacts when an event
/// lands, and a long tool call is exactly where none land). [detach]
/// cancels the subscription — the connection closes, the bridge BACKGROUNDS
/// the turn (see claude_bridge.mjs: the harness keeps working, its output
/// goes nowhere, and the next prompt either queues behind the open tool or
/// cuts a mere thinking turn short in-band).
///
/// Wake on EVERY event: `q.add` alone leaves a frame parked until the
/// loop's next accidental resume — which streaming disguised (each
/// processed say drains into the next) but a quiet tool run exposed: the
/// poll delivered frames within milliseconds, and the loop sat on them
/// until the 15 s heartbeat stumbled past. The wire was fixed one event
/// handler from home.
library;

import 'dart:async';

import 'bridge_event.dart';
import 'gateway.dart';

/// How a pump's turn ended, for the owner's teardown triage.
class PumpOutcome {
  const PumpOutcome({
    required this.stale,
    required this.sawDone,
    required this.sawErrorFrame,
    required this.streamError,
    required this.detached,
  });

  /// The loop exited because its turn was superseded (isStale said so):
  /// every teardown step must then bow out to the successor turn.
  final bool stale;

  /// The turn's own `done` frame closed the loop: a clean end.
  final bool sawDone;

  /// The bridge's `error` frame closed the loop: also a clean end.
  final bool sawErrorFrame;

  /// The socket died (error or EOF) — null unless it died badly.
  final Object? streamError;

  /// Ended because [detach] was called (an intentional steer).
  final bool detached;

  /// The stream closed without done/error — either a detach or a zombie
  /// hop. The reattach decision belongs to the caller, which knows
  /// whether the busy flag still names this turn as its own.
  bool get closedWithoutDone => !sawDone && !sawErrorFrame;
}

class BridgeTurnPump {
  BridgeTurnPump({
    required this.onEvent,
    required this.isStale,
    required this.beforeEvent,
    this.keepOpenOnDone,
  });

  /// Handles one event. The pump breaks the loop after a `done` or
  /// `error` frame, whatever this returns.
  final Future<void> Function(BridgeEvent) onEvent;

  /// True once a newer turn owns the slot: the loop must exit.
  final bool Function() isStale;

  /// Runs before each event's dispatch (hop lighting, queue-pin release)
  /// — a hook so the two loops' different pre-dispatch policies stay
  /// theirs without duplicating the queue.
  final void Function(BridgeEvent) beforeEvent;

  /// Consulted at a `done` frame: when it answers true, the `done` is
  /// a past turn's farewell — already-swallowed history (+133: the
  /// backlog replay of a proactive report carries the launch turn's
  /// done ahead of the report's receipts, and the poll pump's armour
  /// eats it too) — and breaking on it would strand everything that
  /// rides behind it. The reattach loop passes the bridge's own
  /// turnOpen verdict; the talk loop never does (its done is its own).
  final Future<bool> Function()? keepOpenOnDone;

  final _q = <BridgeEvent>[];
  Completer<void>? _wake;
  StreamSubscription<BridgeEvent>? _sub;
  bool _closed = false;
  bool _detached = false;
  Object? _streamError;
  bool _sawDone = false;
  bool _sawErrorFrame = false;

  void _wakeNow() {
    final w = _wake;
    _wake = null;
    w?.complete();
  }

  /// Opens the view and runs until the turn closes, the stream dies, the
  /// loop goes stale, or [detach] cuts it.
  Future<PumpOutcome> run(Stream<BridgeEvent> source) async {
    _sub = source.listen(
      (BridgeEvent ev) {
        _q.add(ev);
        _wakeNow();
      },
      onError: (Object e, StackTrace _) {
        _streamError = e is BridgeException ? e : BridgeException('$e');
        _closed = true;
        _wakeNow();
      },
      onDone: () {
        _closed = true;
        _wakeNow();
      },
    );
    while (true) {
      if (isStale()) break;
      if (_q.isEmpty) {
        if (_closed) break; // stream ended (done event or close)
        await (_wake ??= Completer<void>()).future;
        continue;
      }
      final ev = _q.removeAt(0);
      beforeEvent(ev);
      await onEvent(ev);
      if (ev.isDone) {
        if (keepOpenOnDone != null && await keepOpenOnDone!()) {
          continue; // a history lesson, not a period
        }
        _sawDone = true;
        break;
      }
      if (ev.kind == 'error') {
        _sawErrorFrame = true;
        break;
      }
    }
    await _sub?.cancel();
    _sub = null;
    return PumpOutcome(
      stale: isStale(),
      sawDone: _sawDone,
      sawErrorFrame: _sawErrorFrame,
      streamError: _streamError,
      detached: _detached,
    );
  }

  /// Abandon the VIEW of this turn now (barge-in / takeover / stop):
  /// cancels the connection and unparks the loop even mid-tool-run.
  /// Safe to call twice; safe to call from [onEvent].
  void detach() {
    _detached = true;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    _closed = true;
    _wakeNow();
  }

  /// The wake hook the assistant hands to [_abandonBridgeTurn]'s shared
  /// slot: same semantics as [detach] minus the subscription cancel
  /// (the abandon path cancels through the field it holds).
  void Function() get wakeHook => _wakeNow;
}
