import 'dart:math' as math;
import 'dart:typed_data';

const double _ln10 = 2.302585092994046;

/// Per-frame, speech-aware noise-floor estimate.
///
/// Tracks the minimum of recent frame levels (instant drop, slow rise — the
/// classic "min statistics" trick from spectrum-subtraction noise
/// suppressors). Speech has natural amplitude dips between syllables, so the
/// tracker always falls back to the true floor — and while our own TTS
/// replies play, the residual echo bleeds into the mic and the tracked floor
/// rises to cover it. That is exactly the reference the speech gate needs:
/// to start a new utterance the user must now be louder than our own voice.
class NoiseFloorTracker {
  NoiseFloorTracker({double initialDb = -40, this.risePerFrameDb = 0.02})
    : _db = initialDb;

  /// dB climb per 32 ms frame (~0.6 dB/s): how fast the estimate may relax
  /// upward when no quiet frames appear.
  final double risePerFrameDb;
  double _db;

  double get noiseFloorDb => _db;

  /// Present one frame's RMS level (dBFS). Call once per window, always —
  /// including during speech; the min-tracking makes that safe.
  void offer(double frameRmsDb) {
    final relaxed = _db + risePerFrameDb;
    _db = math.max(math.min(relaxed, frameRmsDb), -70.0);
  }
}

/// RBJ 2nd-order Butterworth high-pass at 120 Hz @ 16 kHz.
///
/// Removes handling noise, desk vibration, HVAC rumble and the DC residual of
/// cheap AGC before any analysis or ASR — Silero and Whisper both score
/// better without low-end junk (the TTS band, ~85-300 Hz, is kept intact).
class HighPassFilter {
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  // RBJ cookbook HPF @120 Hz Q=0.707 @16 kHz, a-normalized:
  // y = b0·x + b1·x⁻¹ + b2·x⁻² − a1·y⁻¹ − a2·y⁻²
  static const _b0 = 0.967227, _b1 = -1.934455, _b2 = 0.967227;
  static const _a1 = -1.933380, _a2 = 0.935529;

  Float32List process(Float32List input) {
    final out = Float32List(input.length);
    for (var i = 0; i < input.length; i++) {
      final x = input[i];
      final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
      _x2 = _x1;
      _x1 = x;
      _y2 = _y1;
      _y1 = y;
      out[i] = y;
    }
    return out;
  }

  void reset() => _x1 = _x2 = _y1 = _y2 = 0;
}

/// The speech gate: a per-frame level/SNR test consumed by the worker's
/// utterance state machine. It exists to fix the two ways a bare Silero
/// threshold fails in practice:
///  * the app interrupting itself — while our TTS reply plays, mic energy
///    IS our own voice (even AEC leaves residue, and AEC is silent-broken for
///    the first ~half second of every playback). `playbackStarted()` raises
///    the bar for a reply's first 500 ms (AEC lock-in) and then keeps it high
///    for the whole playback: only clear over-speech can interrupt;
///  * noisy environments — keyboard clicks, clatter, and door slams score as
///    speech to Silero but sit near the energy floor, so they never clear
///    floor+margin. Real close-talk speech is +10..+30 dB over the floor and
///    starts instantly; the endpoint (minSilenceDuration) still rules when
///    speech *ends*, so a noise burst can never cut the user off.
///
/// The floor *pin* while an utterance or reply is active prevents the
/// positive feedback where the loud frames of speech push the floor up and
/// then disqualify the speech that raised it.
class SpeechGate {
  SpeechGate(
    this._floor, {
    this.startMarginDb = 8.0,
    this.playbackMarginDb = 20.0,
    this.warmupMarginDb = 30.0,
    this.warmupFrames = 16, // 500 ms of AEC lock-in at 32 ms frames
    this.absoluteFloorDb = -55.0,
  });

  final NoiseFloorTracker _floor;
  final double startMarginDb;

  /// Bar while our reply plays. 14 dB self-fired on real phones: speaker→mic
  /// feedback at high media volume sways ±6-8 dB around +15-18 dB above the
  /// (pinned) floor, and every wobble through the bar risked chopping the
  /// reply's tail. 20 dB + the worker's longer in-reply confirm streak
  /// (see confirmStreakPlaying) keeps genuine barge-ins (close voice: +25 dB
  /// and holding) while shrugging off echoes.
  final double playbackMarginDb;
  final double warmupMarginDb;
  final int warmupFrames;
  final double absoluteFloorDb;

  double _levelDb = -100;
  int _frames = 0;
  int? _playbackAtFrame; // when the current (or most recent) reply began
  bool _playing = false;

  double get levelDb => _levelDb;
  double get noiseFloorDb => _floor.noiseFloorDb;
  bool get playbackActive => _playing;

  /// Call once per 512-sample window, before [passes].
  void offer(Float32List window, {required bool freezeFloor}) {
    _frames++;
    var sum = 0.0;
    for (final v in window) {
      sum += v * v;
    }
    _levelDb = sum <= 0
        ? -100.0
        : math.max(10 * math.log(sum / window.length) / _ln10, -100.0);
    // While an utterance or reply is active the floor is pinned: neither the
    // user's loud frames nor our own echo may lift the baseline that the
    // *next* utterance is measured against.
    if (!freezeFloor) _floor.offer(_levelDb);
  }

  /// Whether the current window is loud enough to count as (new) speech.
  bool passes() {
    final double margin;
    final at = _playbackAtFrame;
    if (at == null) {
      margin = startMarginDb;
    } else if (_frames - at < warmupFrames) {
      // Covers AEC lock-in — and stays armed for a reply that was muted or
      // ended early, whose echo re-lock transient still has to be survived.
      margin = warmupMarginDb; // near-deaf by design
    } else if (_playing) {
      margin = playbackMarginDb;
    } else {
      margin = startMarginDb;
    }
    return _levelDb >= noiseFloorDb + margin && _levelDb >= absoluteFloorDb;
  }

  /// Whether an *ongoing* utterance still counts as active this frame.
  /// 4 dB lower than the start bar (hysteresis): one dip or one noisy second
  /// can't cut the user off. Always false while (or just after) our reply
  /// plays — the mic is holding *our* voice then, and it must not keep the
  /// user's utterance "alive" past the reply.
  bool held() {
    if (_playing ||
        _playbackAtFrame != null &&
            _frames - _playbackAtFrame! < warmupFrames) {
      return false;
    }
    return _levelDb >= noiseFloorDb + startMarginDb - 4;
  }

  /// Our own TTS just became audible: raises the bar.
  void playbackStarted() {
    _playing = true;
    _playbackAtFrame = _frames;
  }

  /// Our reply stopped. The playback bar drops, but the warm-up timestamp
  /// stays until the AEC lock-in window has fully passed.
  void playbackEnded() => _playing = false;

  void reset() {
    _playing = false;
    _playbackAtFrame = null;
  }
}

/// Frame-level noise gate for offline (push-to-talk) cleanup: windows under
/// a floor+margins get attenuated (not chopped), so Whisper gets natural —
/// if quieter — fill instead of chop, and the first words of the utterance
/// are never at risk (this runs after the user already finished speaking).
({Float32List samples, double keptFraction}) denoiseClip(
  Float32List pcm, {
  required NoiseFloorTracker floor,
  double marginDb = 7.0,
  double attenuationDb = -30.0,
}) {
  const window = 512;
  final hp = HighPassFilter();
  final out = Float32List(pcm.length);
  final gain = math.pow(10, attenuationDb / 20).toDouble();
  var kept = 0, total = 0;
  for (var off = 0; off + window <= pcm.length; off += window) {
    final chunk = hp.process(Float32List.sublistView(pcm, off, off + window));
    var sum = 0.0;
    for (final v in chunk) {
      sum += v * v;
    }
    final db = sum <= 0 ? -100.0 : 10 * math.log(sum / window) / _ln10;
    final loud = db >= math.max(floor.noiseFloorDb + marginDb, -42.0);
    if (loud) kept += window;
    total += window;
    final g = loud ? 1.0 : gain;
    for (var i = 0; i < window; i++) {
      out[off + i] = chunk[i] * g;
    }
    // Let the floor adapt *downward* during quiet stretches (min tracking),
    // never upward from speech frames — the clip has no pauses to trust.
    floor.offer(db);
  }
  return (samples: out, keptFraction: total == 0 ? 0 : kept / total);
}
