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
  bool _pollCapable = false;
  int _ringCursor = -1; // -1 = unseeded; else: last ring seq consumed
  bool _turnViaPoll = false;
  bool _prevTurnViaPoll = false; // transport of the LAST turn (cursor hygiene)

  int get skewMs => _skewMs;
  bool get pollCapable => _pollCapable;
  int get ringCursor => _ringCursor;

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
  /// +157: on the shared ring EVERY poll pump waits for its OWN
  /// started marker before honouring any farewell. The bridge files one
  /// marker per turn — idle or flushed — as the turn's first frame, and
  /// the ring can lag (a previous view's cursor stopped before an old
  /// `done`: field journal 23:52, 'Hello?' whose pump died on a farewell
  /// from the turn BEFORE its own, stranding the answer behind a drain
  /// that could not re-establish the ledger boundary without the
  /// marker). So while unseen: done and error frames are swallowed
  /// (journalled), and only a marker NAMING THIS PROMPT opens the gate —
  /// stale markers pass through for the loop to file as stale. The
  /// deadline still guards a silent ring.
  Stream<BridgeEvent> turn(
    HarnessGateway gw,
    String text,
    bool interrupt, {
    bool cutTool = false,
    void Function()? onActivity,
  }) {
    _prevTurnViaPoll = _turnViaPoll; // what the LAST turn consumed with
    this.onActivity = onActivity; // the poll loop re-leases the wire itself
    if (!_pollCapable) {
      _turnViaPoll = false;
      return gw.talk(
        text,
        interrupt: interrupt,
        cutTool: cutTool,
        onActivity: onActivity,
      );
    }
    _turnViaPoll = true;
    return _pollTurn(gw, text, interrupt, cutTool);
  }

  Stream<BridgeEvent> _pollTurn(
    HarnessGateway gw,
    String text,
    bool interrupt,
    bool cutTool,
  ) async* {
    // Cursor hygiene, the duplicate-bubble killer: if the LAST turn rode
    // the PUSH stream, the ring still holds a copy of every frame that
    // stream already delivered — and this pull turn would replay the
    // whole recent conversation as fresh, duplicated bubbles (the field
    // report: 'queue or interrupt shows bubbles I already saw'). Catch
    // the cursor up to the ring head BEFORE the POST. A polled previous
    // turn consumed the ring itself — leave the cursor alone, skipping
    // could eat this turn's own frames.
    final h = await gw.healthInfo();
    noteHealth(h);
    if (!_prevTurnViaPoll) {
      final head = h?['poll'] is Map ? (h!['poll'] as Map)['ring'] : null;
      if (head is num && head.toInt() > _ringCursor) _ringCursor = head.toInt();
    }
    if (_ringCursor < 0) _ringCursor = 0;
    // +157: every poll pump is born awaiting its own marker (+131's
    // parked-only law generalised — see the doc on [turn]).
    var awaitPickup = true;
    await gw.talkPoll(text, interrupt: interrupt, cutTool: cutTool);
    var deadline = clock().add(pollDeadline);
    var misses = 0;
    while (true) {
      await _tick();
      final page = await gw.poll(_ringCursor);
      if (page == null) {
        if (++misses >= 8) {
          yield BridgeEvent.parse('error', '{"error":"poll unreachable"}');
          return;
        }
        continue;
      }
      misses = 0;
      onActivity?.call();
      final head = page['seq'];
      if (head is num && head < _ringCursor) {
        // Ring reborn under our cursor (bridge restart with a young
        // sequence space): rewind to the oldest possible event so this
        // turn's already-relayed frames are not skipped, and re-probe —
        // /health may have renegotiated the transport for the next turn
        // (the endpoint serves whoever asks, so riding out THIS turn on
        // polls is safe even if poll is no longer advertised).
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
          final ownMarker =
              ev.kind == 'tool' &&
              ev.toolName == 'started' &&
              (ev.detail.isEmpty ||
                  ev.detail ==
                      (text.length > 60 ? text.substring(0, 60) : text));
          if (ownMarker) {
            // The hand-over marker — ours, by its own name. From the
            // next frame on, the ring carries OUR turn.
            awaitPickup = false;
          } else if (awaitPickup && (ev.isDone || ev.kind == 'error')) {
            // Not ours yet — this farewell belongs to the turn the
            // prompt parked behind (bridge ring order: done, queued,
            // started). Handing it over would break the event pump
            // before the pickup, fossilise the pin, and strand the
            // flushed answer with no listener. Eat it and keep polling;
            // if the flush never comes, the deadline below still says
            // so, and a superseding press cancels this whole stream.
            log(
              'poll: ${ev.isDone ? 'done' : 'error'} of ANOTHER turn '
              'swallowed pre-pickup (seq $seq) — pump survives for its '
              'own marker',
            );
            continue;
          }
          yield ev;
          if (ev.isDone || ev.kind == 'error') return;
        }
      }
      if (_ringCursor > consumedBefore) {
        // Progress on the wire (including the swallowed farewells): the
        // deadline guards against a SILENT ring, not against a turn
        // that spans a long prior tool — and a parked prompt's window
        // legitimately covers the whole of it.
        deadline = clock().add(pollDeadline);
      }
      if (clock().isAfter(deadline)) {
        yield BridgeEvent.parse(
          'error',
          '{"error":"poll deadline — the turn never said done"}',
        );
        return;
      }
    }
  }

  void Function()? onActivity;

  Future<void> _tick() {
    final c = Completer<void>();
    scheduler.after(pollInterval, () => c.complete());
    return c.future;
  }
}
