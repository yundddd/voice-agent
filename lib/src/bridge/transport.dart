/// Which pipe a turn's events ride, and how honest their timestamps are.
///
/// Measured on the live wire: frames the bridge PUSHES (SSE) sit seconds
/// in the cellular path (wire ages of 8–14 s, surfacing only in the
/// turn-close burst — even padded, even pinged), while frames the phone
/// PULLS arrive every time in a round trip (the journal's own outbound
/// POSTs ack in milliseconds). So when /health advertises the event ring,
/// a turn's events are polled: POST /talk?poll=1 to start, then GET
/// /poll?since=$cursor — outbound requests throughout, and the cursor is
/// a reattach state that can never die.
///
/// Every /health read also calibrates the phone-vs-bridge clock skew, so
/// frame `_ts` stamps become honest wire ages even though the two clocks
/// will never agree.
library;

import 'dart:async';

import '../common/clock.dart';
import '../common/sinks.dart';
import 'bridge_event.dart';
import 'gateway.dart';

class BridgeTransport {
  BridgeTransport({
    required this.scheduler,
    required this.clock,
    required this.log,
    this.pollInterval = const Duration(milliseconds: 250),
    this.pollDeadline = const Duration(minutes: 5),
  });

  final Scheduler scheduler;
  final Clock clock;
  final DebugSink log;
  final Duration pollInterval;
  final Duration pollDeadline;

  int _skewMs = 0; // phone-minus-bridge clock, calibrated per /health
  int _proto = 0; // v2 handshake: /health's `proto` (0 = never seen)
  bool _pollCapable = false;
  int _ringCursor = -1; // -1 = unseeded; else: last ring seq consumed
  bool _turnViaPoll = false;
  bool _prevTurnViaPoll = false; // transport of the LAST turn (cursor hygiene)

  int get skewMs => _skewMs;
  bool get pollCapable => _pollCapable;
  int get ringCursor => _ringCursor;

  /// The wire v2 handshake: ids are law only on a proto-2 bridge. Until
  /// the first /health answer there is no verdict (0); anything else is
  /// a bridge the app must not silently mis-deliver against — the
  /// assistant shows one honest banner instead of guessing.
  int get proto => _proto;
  bool get protoV2 => _proto == 2;

  /// Whether the CURRENT turn's events came from GET /poll (set in
  /// [turn]). On the shared ring, frames of whatever turn was already
  /// running keep flowing after a polite queue — they must NOT fake the
  /// pickup and dissolve the pin early (+81). Push (SSE) views are
  /// per-turn, so there the first frame really is our own.
  bool get turnViaPoll => _turnViaPoll;

  /// Fold one /health snapshot in: clock calibration + transport
  /// negotiation, then a one-line account of what the snapshot says the
  /// app should DO (the exact fields the reattach decision turns on, so
  /// a desktop triage read shows WHY the app chose attach/idle/retry).
  String noteHealth(Map<String, Object>? h) {
    if (h != null && h['now'] is num) {
      final pr = h['proto'];
      if (pr is num) _proto = pr.toInt();
      final skew = clock().millisecondsSinceEpoch - (h['now'] as num).toInt();
      // Absurd skew = a stalled probe answer or a wild phone clock; keep
      // the last sane value rather than poison the latency column.
      if (skew.abs() < 10 * 60 * 1000) _skewMs = skew;
      // Every probe also negotiates the transport: a bridge with the
      // event ring gets the pull transport; one without keeps SSE.
      final p = h['poll'];
      if (p is Map) {
        _pollCapable = true;
        final head = p['ring'];
        if (_ringCursor < 0 && head is num) _ringCursor = head.toInt();
      } else {
        _pollCapable = false;
      }
    }
    return h == null
        ? 'UNREACHABLE'
        : 'turnOpen=${h['turnOpen'] == true} '
              'backgrounded=${h['backgrounded'] == true} '
              'missed=${h['missed'] ?? 0} queued=${h['queued'] == true} '
              'detached=${h['detached'] ?? 0}';
  }

  /// How long this frame sat between the bridge's write and our parse
  /// (skew-corrected); -1 when the frame (or a pre-stamp bridge) has no
  /// wire clock to compare against.
  int wireAgeMs(BridgeEvent ev) => ev.wireMs == 0
      ? -1
      : clock().millisecondsSinceEpoch - _skewMs - ev.wireMs;

  String wireTag(BridgeEvent ev) {
    final age = wireAgeMs(ev);
    return age < 0 ? '' : ' [wire+${age}ms]';
  }

  /// Opens this turn's event stream on whichever transport the last
  /// /health taught us the bridge speaks.
  ///
  /// [cutTool] rides the wire as `cuttool=1`: the queue-with-
  /// backgrounding flavour — polite towards thinking, cut-through for a
  /// running tool (see the bridge's talk()).
  ///
  /// wire v2: the POST /talk receipt NAMES this pump's turn, and every
  /// farewell says whose it is (`_turn`). A poll pump honours done and
  /// error only when they name its own turn; every other farewell is
  /// journalled and skipped — the +157 dance of swallowing-until-marker
  /// was inference about exactly this fact, and the shared ring's lag
  /// (field journal 23:52, 'Hello?') was its failure mode. The loop
  /// downstream learns the same id from the first yielded `turn` event.
  /// The deadline still guards a silent ring.
  Stream<BridgeEvent> turn(
    HarnessGateway gw,
    String text,
    bool interrupt, {
    bool cutTool = false,
    required String? sessionId,
    void Function()? onActivity,
  }) {
    _prevTurnViaPoll = _turnViaPoll; // what the LAST turn consumed with
    this.onActivity = onActivity; // the poll loop re-leases the wire itself
    if (!_pollCapable) {
      _turnViaPoll = false;
      return gw.talk(
        text,
        sessionId: sessionId,
        interrupt: interrupt,
        cutTool: cutTool,
        onActivity: onActivity,
      );
    }
    _turnViaPoll = true;
    return _pollTurn(gw, text, interrupt, cutTool, sessionId);
  }

  /// +311: ONE consumer for the ring. Each subscribed turn used to run
  /// its own poll loop — two live turns advanced the one cursor twice
  /// per tick, each saw half the frames, and the wire's request rate
  /// doubled for free. The transport now owns the single loop; turns
  /// subscribe, the fan-out addresses the funerals, and the loop
  /// retires when the last subscriber goes.
  final _subs = <_RingSub>[];
  bool _loopLive = false;
  HarnessGateway? _loopGw;

  Stream<BridgeEvent> _pollTurn(
    HarnessGateway gw,
    String text,
    bool interrupt,
    bool cutTool,
    String? sessionId,
  ) async* {
    // Cursor hygiene, the duplicate-bubble killer: if the LAST turn rode
    // the PUSH stream, the ring still holds a copy of every frame that
    // stream already delivered — and this pull turn would replay the
    // whole recent conversation as fresh, duplicated bubbles (the field
    // report: 'queue or interrupt shows bubbles I already saw'). Catch
    // the cursor up to the ring head BEFORE the POST — but only while
    // the consumer is COLD: a live loop is advancing the cursor
    // honestly, and skipping could eat this turn's own birth frames.
    final h = await gw.healthInfo();
    noteHealth(h);
    if (!_prevTurnViaPoll && !_loopLive) {
      final head = h?['poll'] is Map ? (h!['poll'] as Map)['ring'] : null;
      if (head is num && head.toInt() > _ringCursor) _ringCursor = head.toInt();
    }
    if (_ringCursor < 0) _ringCursor = 0;
    // Subscribe BEFORE the POST: the pickup notice can ring between
    // the receipt and the first poll, and a frame that arrives in
    // that window must not be consumed by the loop for someone else
    // alone. Until the receipt names the turn, done/error frames are
    // not ours by construction and the rest ride through (the old
    // loop started at the cursor; nothing is missed either way).
    // myTurn 0 = 'not yet in hand' (the same value an unreadable
    // receipt carries): farewells cannot match an unassigned turn, so
    // they pass the foreign test by construction and the rest rides.
    final sub = _RingSub(clock().add(pollDeadline), 0);
    sub.ctl.onCancel = () => _retire(sub);
    _subs.add(sub);
    _loopGw = gw;
    if (!_loopLive) unawaited(_ringLoop());
    // v2: the receipt names our turn BEFORE the first poll; the loop
    // learns it from the same event the other transports get first.
    final myTurn = await gw.talkPoll(
      text,
      sessionId: sessionId,
      interrupt: interrupt,
      cutTool: cutTool,
    );
    sub.myTurn = myTurn;
    yield BridgeEvent.parse('turn', '{"turn":$myTurn}');
    await for (final ev in sub.ctl.stream) {
      yield ev;
      if (ev.isDone || ev.kind == 'error') break;
    }
    _retire(sub);
  }

  /// The single ring consumer: one GET /poll per tick, cursor advanced
  // exactly once, every frame delivered to every watchful pump. The
  /// per-turn laws ride UNCHANGED — eight dead polls say non-terminal
  /// disconnect, a silent ring with a live wire says deadline error
  /// (unless the wire itself is down, whose fuse extends), a young
  /// ring rewinds the cursor, and a stranger's funeral may not break
  /// a parked pump before its pickup.
  Future<void> _ringLoop() async {
    _loopLive = true;
    final gw = _loopGw!;
    while (_subs.isNotEmpty) {
      await _tick();
      if (_subs.isEmpty) break;
      final page = await gw.poll(_ringCursor);
      if (page == null) {
        for (final sub in _subs.toList()) {
          sub.misses++;
          if (sub.misses == 8) {
            // Transport failure is NOT agent failure (see +D): the
            // WIRE is down; say so non-terminally and keep polling —
            // a recovered wire resumes at the exact missed frame.
            sub.emit(
              BridgeEvent.parse(
                'disconnect',
                '{"error":"bridge unreachable — retrying"}',
              ),
            );
          }
        }
        continue;
      }
      for (final sub in _subs) {
        sub.misses = 0;
      }
      onActivity?.call();
      final head = page['seq'];
      if (head is num && head < _ringCursor) {
        // Ring reborn under our cursor (bridge restart with a young
        // sequence space): rewind to the oldest possible event so
        // turns' already-relayed frames are not skipped, and re-probe
        // — /health may have renegotiated the transport.
        log(
          'poll: ring reset (head $head < cursor $_ringCursor) '
          '— rewinding to 0',
        );
        noteHealth(await gw.healthInfo());
        _ringCursor = 0;
        continue;
      }
      final evs = page['events'];
      final consumedBefore = _ringCursor;
      if (evs is List) {
        for (final f in evs) {
          if (f is! Map) continue;
          final seq = f['seq'];
          if (seq is! num || seq <= _ringCursor) continue;
          _ringCursor = seq.toInt();
          final ev = BridgeEvent.parseMap(
            '${f['ev']}',
            f['data'] is Map
                ? f['data'] as Map<Object?, Object?>
                : const <String, Object>{},
          );
          for (final sub in _subs.toList()) {
            final foreign =
                (ev.isDone || ev.kind == 'error') &&
                sub.myTurn != 0 &&
                ev.turn != 0 &&
                ev.turn != sub.myTurn;
            if (foreign) {
              // Someone else's funeral: honouring it would break the
              // pump before its pickup, fossilise the pin and strand
              // the flushed answer — skip it; if the flush never
              // comes the deadline below still says so.
              log(
                'poll: ${ev.isDone ? 'done' : 'error'} of turn ${ev.turn} '
                '(ours is ${sub.myTurn}) — not ours, pump survives',
              );
              continue;
            }
            sub.emit(ev);
            if (ev.isDone || ev.kind == 'error') _retire(sub);
          }
        }
      }
      for (final sub in _subs.toList()) {
        if (_ringCursor > consumedBefore) {
          // Progress on the wire (including the swallowed farewells):
          // the deadline guards a SILENT ring, not a turn spanning a
          // long prior tool — a parked prompt's window legitimately
          // covers the whole of it.
          sub.deadline = clock().add(pollDeadline);
        }
        if (clock().isAfter(sub.deadline)) {
          if (sub.misses >= 8) {
            // The wire, not the agent, owns this silence: extend the
            // fuse and keep dialling.
            sub.deadline = clock().add(pollDeadline);
            continue;
          }
          sub.emit(
            BridgeEvent.parse(
              'error',
              '{"error":"poll deadline — the turn never said done"}',
            ),
          );
          _retire(sub);
        }
      }
    }
    _loopLive = false;
  }

  void _retire(_RingSub sub) {
    _subs.remove(sub);
    if (!sub.ctl.isClosed) sub.ctl.close();
  }

  void Function()? onActivity;

  Future<void> _tick() {
    final c = Completer<void>();
    scheduler.after(pollInterval, () => c.complete());
    return c.future;
  }
}

/// +311: one pump's subscription to the shared ring consumer — its
/// reserved turn (null until the receipt arrives: pre-birth frames
/// ride through except others' farewells, which cannot be ours), its
/// own silence fuse, and its own dead-wire counter.
final class _RingSub {
  _RingSub(this.deadline, this.myTurn);
  int myTurn;
  DateTime deadline;
  int misses = 0;
  final ctl = StreamController<BridgeEvent>();
  void emit(BridgeEvent ev) {
    if (!ctl.isClosed) ctl.add(ev);
  }
}
