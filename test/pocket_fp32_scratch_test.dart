// Temporary harness (flutter test): Pocket int8-vs-fp32 A/B, same worker
// pipeline (ritual included) for both packs. Reports, per variant x voice x
// line: RTF, onset ms after the ritual's 300 ms inserted lead (= the
// model's own generated pause; long => clean start, ~0 => it starts speaking
// inside the growl window again), spectral rolloff (does fp32 lift the
// ~9.5-10.6 kHz ceiling the int8 renders carry?), whisper coverage of the
// whole sentence, and whether the FIRST long word survives — the original
// cut-off bug's victim. Graphs come from the variant dir; reference wavs
// always from our curated pack (the fp32 tarball has no voices/ dir).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';
import 'package:voice_agent/tts_voices.dart';

const lines = [
  'Good news: everything is clean. The test suite passed with thirty-nine '
      'tests green, and the release build finished quickly.',
  'He whispered something about the old tin roof, then laughed out loud at '
      'the joke nobody else heard yet.',
];

/// First ms where sustained voice energy appears (5 ms frames, 8 consecutive
/// above 0.2% full-scale).
int onsetMs(Float32List s, int rate) {
  var run = 0;
  for (var i = 0; i < s.length - 480; i += 240) {
    var peak = 0.0;
    for (var j = i; j < i + 240; j++) {
      final v = s[j].abs();
      if (v > peak) peak = v;
    }
    if (peak > 0.002) {
      if (++run >= 8) return (i - run * 240) * 1000 ~/ rate;
    } else {
      run = 0;
    }
  }
  return -1;
}

/// Goertzel power at [freq] Hz over up to [maxSamples] samples.
double goertzel(Float32List s, int rate, double freq) {
  final w = 2.0 * 3.141592653589793 * freq / rate;
  final coeff = 2.0 * math.cos(w);
  var s1 = 0.0, s2 = 0.0;
  var n = 0;
  for (var i = 0; i < s.length && n < 100000; i++) {
    final q0 = coeff * s1 - s2 + s[i];
    s2 = s1;
    s1 = q0;
    n++;
  }
  if (n == 0) return 0;
  return (s1 * s1 + s2 * s2 - coeff * s1 * s2).abs() / n;
}

/// 99%-energy rolloff over log probes (comparative, not cert-grade).
double rolloff99(Float32List s, int rate) {
  final probes = [500, 800, 1200, 1800, 2600, 3400, 4500, 6000, 7500, 9500,
      11500];
  final e = <double, double>{};
  var tot = 0.0;
  for (final f in probes) {
    e[f.toDouble()] = goertzel(s, rate, f.toDouble());
    tot += e[f.toDouble()]!;
  }
  if (tot <= 0) return 0;
  var cum = 0.0;
  for (final f in probes) {
    cum += e[f.toDouble()]!;
    if (cum >= 0.99 * tot) return f.toDouble();
  }
  return probes.last.toDouble();
}

void main() {
  test('Pocket int8 vs fp32 A/B', () async {
    const int8Dir = '/tmp/opencode/pocket-pack/pocket-tts';
    const fp32Dir = '/tmp/opencode/pocket-fp32/sherpa-onnx-pocket-tts-2026-01-26';
    final m = Directory('models').absolute.path;
    final paths = ModelPaths(
      whisperEncoder: '$m/sherpa-onnx-whisper-tiny.en/tiny.en-encoder.int8.onnx',
      whisperDecoder: '$m/sherpa-onnx-whisper-tiny.en/tiny.en-decoder.int8.onnx',
      whisperTokens: '$m/sherpa-onnx-whisper-tiny.en/tiny.en-tokens.txt',
      vitsModel: '$m/vits-piper-en_US-lessac-medium/en_US-lessac-medium.onnx',
      vitsTokens: '$m/vits-piper-en_US-lessac-medium/tokens.txt',
      espeakDataDir: '$m/vits-piper-en_US-lessac-medium/espeak-ng-data',
      vadModel: '$m/silero_vad.onnx',
    );
    final refs = TtsVoice.pocketRefs;
    TtsSpec spec(String dir, String sfx, int sid) => TtsSpec.pocket(
      pocketLmFlow: '$dir/lm_flow$sfx.onnx',
      pocketLmMain: '$dir/lm_main$sfx.onnx',
      pocketEncoder: '$dir/encoder.onnx',
      pocketDecoder: '$dir/decoder$sfx.onnx',
      pocketTextConditioner: '$dir/text_conditioner.onnx',
      pocketVocabJson: '$dir/vocab.json',
      pocketTokenScoresJson: '$dir/token_scores.json',
      // fp32 tarball ships no voices/: always clone from curated pack.
      referenceWav: '$int8Dir/voices/${refs[sid]}.wav',
      pocketRefs: refs,
      sid: sid,
    );

    if (!File('$fp32Dir/lm_main.onnx').existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: fp32 pack not at $fp32Dir');
      return;
    }

    final worker = await SpeechWorker.start(paths);
    try {
      for (final (name, dir, sfx) in [
        ('int8', int8Dir, '.int8'),
        ('fp32', fp32Dir, ''),
      ]) {
        var rtSum = 0.0, onsetSum = 0, rollMax = 0.0, heads = 0, takes = 0;
        for (final sid in [0, 3]) {
          final n = await worker.useTts(spec(dir, sfx, sid));
          expect(n, refs.length);
          for (final (li, line) in lines.indexed) {
            final sw = Stopwatch()..start();
            final (audio, rate) = await worker.synthesize(line);
            sw.stop();
            final secs = audio.length / rate;
            final rtf = sw.elapsedMilliseconds / 1000 / secs;
            final f = File('/tmp/opencode/ab2_${name}_${refs[sid]}_$li.wav')
              ..writeAsBytesSync(encodeWav(audio, rate));
            final onset = onsetMs(audio, rate);
            final roll = rolloff99(audio, rate);
            final h = (await worker.transcribe(audio, rate)).toLowerCase();
            final words = line
                .split(RegExp(r'\W+'))
                .where((w) => w.length > 3)
                .toList();
            final cov =
                words.where((w) => h.contains(w.toLowerCase())).length;
            final first = words.first;
            final headOk = h.contains(first.toLowerCase());
            rtSum += rtf;
            onsetSum += onset;
            if (roll > rollMax) rollMax = roll;
            if (headOk) heads++;
            takes++;
            // ignore: avoid_print
            print(
              '[$name ${refs[sid]} L$li ${f.path.split('/').last}] '
              '${secs.toStringAsFixed(1)}s rtf ${rtf.toStringAsFixed(2)} '
              'onset ${onset}ms roll99 ${roll.round()}Hz '
              'cov $cov/${words.length} head=$headOk\n        "$h"',
            );
          }
        }
        // ignore: avoid_print
        print(
          '== $name: mean rtf ${(rtSum / takes).toStringAsFixed(2)}, '
          'mean onset ${onsetSum ~/ takes}ms, max roll99 '
          '${rollMax.round()}Hz, heads intact $heads/$takes',
        );
      }
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
