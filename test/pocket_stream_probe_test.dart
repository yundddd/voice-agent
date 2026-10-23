// +341 probe (Tim, 'can't we just use the online API?'): sherpa-onnx has
// no separate streaming TTS class — the SAME OfflineTts carries
// generateWithConfig(onProgress:), whose contract promises partial sample
// chunks. Whether the Pocket C++ arm actually calls that callback DURING
// generation (Kyutai's reference runtime streams at ~200 ms to first
// chunk) or only hands the finished buffer over at the end is exactly
// what this probe measures: stamp every arrival against the call's own
// stopwatch. A spread across the call = intra-sentence streaming is
// real and the worker can ride it; one arrival at the end = the API is
// decorative and sentence pipelining stays our only stream.
//
// Runs only with the pack staged (same skip semantics as the round-trip
// Pocket leg): POCKET_DIR, default /tmp/opencode/pocket-pack/pocket-tts.
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:flutter_test/flutter_test.dart';

import 'package:voice_agent/src/audio/audio_io.dart' show decodeWav;

void main() {
  test('Pocket onProgress callback: real stream or decorative?', () async {
    final dir =
        Platform.environment['POCKET_DIR'] ??
        '/tmp/opencode/pocket-pack/pocket-tts';
    if (!File('$dir/lm_main.onnx').existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: Pocket pack not staged under $dir');
      return;
    }
    final refs =
        Platform.environment['POCKET_REFS']?.split(',') ??
        ['alba', 'jane', 'jean'].map((v) => '$dir/voices/$v.wav').toList();
    sherpa_onnx.initBindings();
    final tts = sherpa_onnx.OfflineTts(
      sherpa_onnx.OfflineTtsConfig(
        model: sherpa_onnx.OfflineTtsModelConfig(
          pocket: sherpa_onnx.OfflineTtsPocketModelConfig(
            lmFlow: '$dir/lm_flow.onnx',
            lmMain: '$dir/lm_main.onnx',
            encoder: '$dir/encoder.onnx',
            decoder: '$dir/decoder.onnx',
            textConditioner: '$dir/text_conditioner.onnx',
            vocabJson: '$dir/vocab.json',
            tokenScoresJson: '$dir/token_scores.json',
          ),
          numThreads: 4,
          debug: false,
          provider: 'cpu',
        ),
        maxNumSenetences: 4,
      ),
    );
    final (reference, referenceSampleRate) = decodeWav(
      File(refs.first).readAsBytesSync(),
    );
    // Long on purpose: the longer the utterance, the clearer the
    // one-at-the-end shape separates from a live drip.
    const text =
        'Hello Tim, this is the Pocket TTS probe streaming test. The '
        'question today is whether audio arrives while the model still '
        'speaks, or only after the very last frame is computed, and a '
        'long sentence makes the difference impossible to miss.';
    final sw = Stopwatch()..start();
    final arrivals = <(int, int)>[]; // (elapsedMs, chunk samples)
    final audio = tts.generateWithConfig(
      text: text,
      config: sherpa_onnx.OfflineTtsGenerationConfig(
        referenceAudio: reference,
        referenceSampleRate: referenceSampleRate,
        numSteps: 2,
        silenceScale: 1.0,
        extra: {'max_frames': (text.length * 135 ~/ 100 + 30).clamp(60, 500)},
      ),
      onProgress: (samples, progress) {
        arrivals.add((sw.elapsedMilliseconds, samples.length));
        return 1; // keep generating
      },
    );
    sw.stop();
    final totalMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print(
      'probe: ${arrivals.length} callback arrival(s) over ${totalMs}ms '
      'of generation, final buffer ${audio.samples.length} samples '
      '(${(audio.samples.length / audio.sampleRate).toStringAsFixed(1)}s '
      'of audio)',
    );
    for (final (ms, n) in arrivals.take(12)) {
      // ignore: avoid_print
      print('  +${ms}ms: $n samples');
    }
    // The verdict assertion stays soft (print) — this is a field
    // measurement, not a law; the law it informs gets its own pin.
    final spread = arrivals.length > 1
        ? arrivals.last.$1 - arrivals.first.$1
        : 0;
    // ignore: avoid_print
    print(
      spread > 500 && arrivals.length > 2
          ? 'VERDICT: STREAMING — callbacks spread ${spread}ms across the '
                'call (first at +${arrivals.first.$1}ms)'
          : 'VERDICT: NOT STREAMED — the callback is decorative for this '
                'arm (spread ${spread}ms, ${arrivals.length} arrivals)',
    );
    tts.free();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
