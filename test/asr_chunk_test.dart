// VAD chunking for long PTT clips (asr_chunk.dart) — pure, driven by
// the worker's count-based FakeVad: FakeVad 'detects' while the accepted
// window count sits inside startsAt..endsAt and publishes the accepted
// speech on the fall, so segment boundaries are exact arithmetic here.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/asr_chunk.dart';
import 'package:voice_agent/src/speech/worker_backends.dart';

Float32List _clip(int windows, {double v = 0.5}) =>
    Float32List.fromList(List.filled(windows * 512, v));

void main() {
  group('chunkForWhisper', () {
    test('speech still open at clip end is surfaced by the endpoint pad', () {
      // The real case: the button came up mid-word. The fall only
      // happens because the chunker pushes a second of silence after
      // the samples run out.
      final vad = FakeVad(startsAt: 4, endsAt: 20);
      final segs = chunkForWhisper(vad, _clip(8), 16000);
      expect(segs, hasLength(1));
      // Windows 4..20 counted as speech (the fake is count-blind to
      // content): exactly 17 windows of the fed samples, values intact.
      expect(segs[0], hasLength(17 * 512));
      // The clip's five windows first (values intact), then the pad
      // windows as zeros — a real silero pads with true silence too.
      expect(segs[0].take(5 * 512).every((s) => s == 0.5), isTrue);
      expect(segs[0].skip(5 * 512).every((s) => s == 0), isTrue);
    });

    test('speech that falls mid-clip drains before the rest is fed', () {
      final vad = FakeVad(startsAt: 2, endsAt: 5);
      final segs = chunkForWhisper(vad, _clip(30), 16000);
      expect(segs, hasLength(1));
      expect(segs[0], hasLength(4 * 512));
    });

    test('a clip with no speech chunks to nothing (caller decides)', () {
      final vad = FakeVad(startsAt: 1000, endsAt: 2000);
      expect(chunkForWhisper(vad, _clip(40), 16000), isEmpty);
    });

    test('a sub-window remainder rides the padded tail window', () {
      // 3 full windows + 100 samples: the remainder must still reach
      // the VAD (zero-padded) — losing it would shave the last word's
      // offglide off every long clip.
      final vad = FakeVad(startsAt: 1, endsAt: 6);
      final clip = Float32List.fromList([
        ...List.filled(3 * 512, 0.5),
        ...List.generate(100, (i) => i * 1.0),
      ]);
      final segs = chunkForWhisper(vad, clip, 16000);
      expect(segs, hasLength(1));
      expect(segs[0].length, greaterThan(3 * 512));
    });

    test('the VAD is reset first — a reused chunker keeps no state', () {
      final vad = FakeVad(startsAt: 1, endsAt: 3);
      chunkForWhisper(vad, _clip(40), 16000);
      // Second call, same fake: windows recounted from zero, so the
      // exact same segment shape must come back (a leaked count would
      // have blown past the detection window and returned nothing).
      final again = chunkForWhisper(vad, _clip(40), 16000);
      expect(again, hasLength(1));
    });
  });
}
