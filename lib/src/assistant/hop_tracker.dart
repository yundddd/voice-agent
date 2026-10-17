/// The latency strip's flow diagram moments.
///
/// Each hop records WHEN its stage last fired — asr: a transcript landed;
/// sent: the words reached the harness (TALK/ATTACH open); reply: a
/// bridge event arrived; tts: a spoken block's first audio chunk. The
/// strip lights the arrow green while the moment is younger than [_lit]
/// and lets it fade back once data stops flowing, so the arrows trace
/// the round trip rather than staying lit once it has happened.
///
/// Each hop lights its arrow for [_lit] after data last crossed it, then
/// fades back on its own — a pulse that follows the flow, not a latch.
/// One shared timer drives the fade-back: any hop firing restamps the
/// clock and (re)arms it, and when the last pulse's window closes with
/// nothing newer behind it, the timer repaints once and dies.
library;

import 'dart:async';

import '../common/clock.dart';
import '../common/sinks.dart';

class HopTracker {
  HopTracker({
    required this.clock,
    required this.scheduler,
    required this.repaint,
    this.lit = const Duration(milliseconds: 500),
  });

  final Clock clock;
  final Scheduler scheduler;
  final Repaint repaint;
  final Duration lit;

  DateTime? _asrAt, _sentAt, _replyAt, _ttsAt;
  Timer? _fade;

  void _hop(void Function(DateTime) store) {
    store(clock());
    repaint();
    _fade?.cancel();
    _fade = scheduler.after(lit, () {
      _fade = null;
      repaint(); // re-evaluate the arrows once the pulse expires
    });
  }

  void asr() => _hop((t) => _asrAt = t);
  void sent() => _hop((t) => _sentAt = t);
  void reply() => _hop((t) => _replyAt = t);
  void tts() => _hop((t) => _ttsAt = t);

  bool _live(DateTime? at) => at != null && clock().difference(at) < lit;

  bool get hopAsr => _live(_asrAt);
  bool get hopSent => _live(_sentAt);
  bool get hopReply => _live(_replyAt);
  bool get hopTts => _live(_ttsAt);

  void dispose() => _fade?.cancel();
}
