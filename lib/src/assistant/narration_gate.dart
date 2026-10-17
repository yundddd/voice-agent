/// The progress-narration policy for harness turns, kept away from the
/// event loop so the rules read (and test) as one unit.
///
/// 'Working towards the goal' means AUDIO while working, not only at the
/// end: the bridge pushes a `tool` event at every step's start, and with
/// the Narrate switch on those events are spoken. The reply's own audio
/// always outranks chatter: narration waits for 8 s of real quiet
/// (nothing synthesising or playing, no narration line in the last 8 s —
/// the gate that keeps a burst of ten Edit calls from machine-gunning
/// the speaker), and a step that goes dark for minutes (one gradle
/// build, zero events) repeats its last known line as a ~45 s heartbeat
/// from a pulse timer instead of dead air. While hidden, narration holds
/// off (no synth at all): the answer still buffers for replay and the
/// log has every step as text.
library;

import '../common/clock.dart';

class NarrationGate {
  NarrationGate({
    required this.clock,
    this.quietWindow = const Duration(seconds: 8),
    this.heartbeatGap = const Duration(seconds: 45),
  });

  final Clock clock;

  /// Real-audio / real-narration silence required before any narration
  /// line may be spoken.
  final Duration quietWindow;

  /// Minimum spacing between REPEATS of the same heartbeat line.
  final Duration heartbeatGap;

  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastNarrated = '';
  DateTime _lastNarratedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Reply audio just became active (synth issued): hush.
  void audioActivity() => _lastSpokenAt = clock();

  /// A line was just narrated.
  void narrated(String line) {
    _lastNarrated = line;
    _lastNarratedAt = clock();
  }

  /// The shared quiet test: pref on, app visible, nothing audible, and
  /// both clocks beyond their window.
  bool quiet({
    required bool enabled,
    required bool backgrounded,
    required bool speaking,
    required bool playing,
  }) {
    if (!enabled || backgrounded || speaking || playing) return false;
    final now = clock();
    return now.difference(_lastSpokenAt) >= quietWindow &&
        now.difference(_lastNarratedAt) >= quietWindow;
  }

  /// A fresh step line may be spoken when it is quiet and the line is
  /// news (the same line repeating is the heartbeat's job, not this
  /// one's).
  bool wantStep(
    String line, {
    required bool enabled,
    required bool backgrounded,
    required bool speaking,
    required bool playing,
  }) =>
      line.isNotEmpty &&
      quiet(
        enabled: enabled,
        backgrounded: backgrounded,
        speaking: speaking,
        playing: playing,
      ) &&
      line != _lastNarrated;

  /// A long-silent step repeats its last known line as a steady
  /// 'still on it' cadence rather than a stutter — but only after the
  /// same line has been quiet for the heartbeat gap.
  bool wantHeartbeat(
    String line, {
    required bool enabled,
    required bool backgrounded,
    required bool speaking,
    required bool playing,
  }) {
    if (!quiet(
      enabled: enabled,
      backgrounded: backgrounded,
      speaking: speaking,
      playing: playing,
    )) {
      return false;
    }
    return !(line == _lastNarrated &&
        clock().difference(_lastNarratedAt) < heartbeatGap);
  }
}
