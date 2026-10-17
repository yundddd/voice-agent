/// Injectable wall clock: every time-dependent piece of assistant logic
/// (token ticker extrapolation, hop pulses, the narration gate, the PTT
/// hold) reads "now" through a [Clock] instead of calling
/// [DateTime.now] inline, so unit tests can hand it a scripted fake and
/// assert on exact windows (the 8 s narration quiet rule, the 45 s
/// heartbeat, the 500 ms hop pulse) without sleeping.
typedef Clock = DateTime Function();

/// The production clock.
DateTime wallClock() => DateTime.now();

/// A clock over a fake "now" a test moves forward by hand.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime(2026, 1, 1);
  DateTime now;
  DateTime call() => now;

  void advance(Duration d) => now = now.add(d);
}
