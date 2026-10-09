// Speech front-end unit tests: noise floor, high-pass, and the speech gate.
// Synthetic signals only — no models, no isolate, runs anywhere.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/audio_dsp.dart';

/// Deterministic pseudo-noise window (LCG, no timing flakiness).
Float32List noiseWindow(int seed, double amplitude) {
  final w = Float32List(512);
  var s = seed;
  for (var i = 0; i < w.length; i++) {
    s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
    w[i] = (s / 0x7FFFFFFF - 1) * amplitude;
  }
  return w;
}

/// Window with a 100 Hz tone burst at `dbfs` (speech-like band energy).
Float32List toneWindow(double dbfs, {int skip = 0}) {
  final w = Float32List(512);
  final amp = math.pow(10, dbfs / 20) * math.sqrt2;
  for (var i = 0; i < w.length; i++) {
    final t = (i + skip) / 16000.0;
    w[i] = (amp * math.sin(2 * math.pi * 100 * t)).toDouble();
  }
  return w;
}

void main() {
  group('NoiseFloorTracker', () {
    test(
      'drops instantly to quiet frames, then relaxes one step per frame',
      () {
        final f = NoiseFloorTracker(initialDb: 0);
        f.offer(-55);
        expect(f.noiseFloorDb, closeTo(-55, 0.001));
        for (var i = 0; i < 1000; i++) {
          f.offer(-20); // loud: only the slow rise may move it
        }
        // Rises exactly at the capped rate, and never past the quietest frame
        // history allows (well below the -20 it was offered).
        expect(f.noiseFloorDb, closeTo(-55 + 1000 * 0.02, 0.5));
        expect(f.noiseFloorDb, lessThan(-30));
      },
    );

    test('rise is capped at one rise step per frame', () {
      final f = NoiseFloorTracker(initialDb: -60);
      for (var i = 0; i < 31; i++) {
        f.offer(-20);
      }
      expect(f.noiseFloorDb, lessThan(-59.0)); // ≈ -60 + 31*0.02
    });
  });

  group('HighPassFilter', () {
    test('is stable on DC (never blows up)', () {
      final hp = HighPassFilter();
      final out = hp.process(Float32List.fromList(List.filled(512, 0.9)));
      for (final v in out.take(512)) {
        expect(v.isFinite, isTrue);
        expect(v.abs(), lessThan(2.0));
      }
      // Settles to (b0+b1+b2)/(1+a1+a2) = 0 for HPF:
      expect(out.last.abs(), lessThan(0.01));
    });

    test('keeps speech-band tone, removes sub-rumble', () {
      final hp = HighPassFilter();
      double rms(Float32List w) {
        var s = 0.0;
        for (final v in w) {
          s += v * v;
        }
        return s / w.length;
      }

      // 30 Hz rumble at -12 dBFS vs 300 Hz tone at -12 dBFS:
      Float32List rumble = Float32List(2048);
      Float32List tone = Float32List(2048);
      for (var i = 0; i < 2048; i++) {
        rumble[i] = 0.25 * math.sin(2 * math.pi * 30 * i / 16000);
        tone[i] = 0.25 * math.sin(2 * math.pi * 300 * i / 16000);
      }
      final rOut = hp.process(rumble);
      final t = hp.process(tone);
      final hr = hp.process(toneWindow(-12, skip: 4096));
      // Measure over the second half (filter warm-up done):
      double tailRms(Float32List w) => rms(w.sublist(1024));
      expect(tailRms(t) / tailRms(rOut), greaterThan(10));
      expect(hr.length, 512); // API sanity: same-size output
    });
  });

  group('SpeechGate', () {
    NoiseFloorTracker quietFloor() {
      final f = NoiseFloorTracker();
      f.offer(-60); // room tone established up-front
      return f;
    }

    test('stays closed on steady ambient noise alone', () {
      final g = SpeechGate(quietFloor());
      var anyPass = false;
      for (var i = 0; i < 60; i++) {
        g.offer(noiseWindow(i, 0.001), freezeFloor: false); // -60 dBFS-ish
        anyPass |= g.passes();
      }
      expect(anyPass, isFalse);
    });

    test('opens quickly for clear close-talk speech', () {
      final g = SpeechGate(quietFloor());
      var openedAt = -1;
      for (var i = 0; i < 20 && openedAt < 0; i++) {
        g.offer(toneWindow(-25, skip: i * 512), freezeFloor: false);
        if (g.passes()) openedAt = i;
      }
      expect(openedAt, inInclusiveRange(0, 2)); // well under its 160 ms budget
    });

    test('a burst at +16 dB over the floor cannot interrupt a reply', () {
      final g = SpeechGate(quietFloor());
      g.playbackStarted();
      // AEC lock-in window: deaf to everything under +30 dB (i.e. under
      // -30 dBFS here). A +16 dB barge-in attempt must fail while locked,
      // and after it too: the playback bar now sits at +20 dB (-40 dBFS),
      // because real phones feed back +14-18 dB from the speaker at high
      // media volume and were self-tripping the interruption logic.
      for (var i = 0; i < 20; i++) {
        g.offer(toneWindow(-44, skip: i * 512), freezeFloor: true);
        expect(g.passes(), isFalse);
      }
      // A close-talk barge-in (floor -60 → voice at -32 dBFS, i.e. +28 dB)
      // still walks straight through the +20 dB bar.
      g.offer(toneWindow(-32, skip: 9999), freezeFloor: true);
      expect(g.passes(), isTrue);
      expect(g.held(), isFalse); // echo can never keep an utterance "alive"
    });

    test('after the reply, the warm-up deaf window still covers lock-in', () {
      final g = SpeechGate(quietFloor());
      g.playbackStarted();
      for (var i = 0; i < 4; i++) {
        g.offer(toneWindow(-25, skip: i * 512), freezeFloor: true);
      }
      g.playbackEnded(); // reply muted inside the first 500 ms
      // Echo re-lock transient just below the warm-up bar must stay deaf:
      g.offer(toneWindow(-31, skip: 777), freezeFloor: true);
      expect(g.passes(), isFalse); // warm-up bar = floor(-60) + 30 = -30 dBFS
      // …but once the window has passed, normal hearing returns:
      for (var i = 0; i < 16; i++) {
        g.offer(toneWindow(-60, skip: i * 512), freezeFloor: true);
      }
      g.offer(toneWindow(-25, skip: 4242), freezeFloor: true);
      expect(g.passes(), isTrue);
    });

    test('held() hysteresis: 4 dB below the start bar', () {
      final g = SpeechGate(quietFloor());
      // Floor -60 → start bar -52; -55 sits between: held but not passing.
      g.offer(toneWindow(-55), freezeFloor: true);
      expect(g.passes(), isFalse);
      expect(g.held(), isTrue);
    });
  });

  group('denoiseClip', () {
    test('attenuates quiet fill and keeps loud speech frames', () {
      // 1 s of quiet ambience, then 1 s of tone at -22 dBFS.
      final pcm = Float32List(32000);
      final rnd = math.Random(7);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = (rnd.nextDouble() * 2 - 1) * 0.0008; // ~ -62 dBFS
      }
      for (var i = 16000; i < pcm.length; i++) {
        pcm[i] = 0.09 * math.sin(2 * math.pi * 220 * i / 16000);
      }
      final r = denoiseClip(pcm, floor: NoiseFloorTracker(initialDb: -18));
      expect(r.keptFraction, closeTo(0.5, 0.02));
      // Quiet half attenuated ~-30 dB, loud half intact:
      double rms(int from, int to) {
        var s = 0.0;
        for (var i = from; i < to; i++) {
          s += r.samples[i] * r.samples[i];
        }
        return math.sqrt(s / (to - from));
      }

      final quietOut = rms(1024, 7000); // past HPF warm-up
      final loudOut = rms(17000, 31000);
      expect(loudOut, greaterThan(quietOut * 50));
    });
  });
}
