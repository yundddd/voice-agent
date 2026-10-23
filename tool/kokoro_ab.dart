// Kokoro pack A/B (host): renders one fricative-rich English paragraph
// through every k2-fsa Kokoro pack we care to compare, scans voices for
// usable English, re-transcribes each rendering with whisper-tiny.en (the
// intelligibility oracle) and prints per-pack tables + RTF. Companion to
// bwcheck.py (spectral cutoff forensics) — the wavs land under
// /tmp/opencode/kokoro-ab/out/ for the report and Telegram audition.
//
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     dart run tool/kokoro_ab.dart
//
// Packs (extract first; see docs/kokoro-ab.md for URLs):
//   /tmp/opencode/kokoro-ab/kokoro-multi-lang-v1_1       (zh-first, fp32)  [opt]
//   /home/tim/voice-agent/models/kokoro-dl/kokoro-int8-multi-lang-v1_1 (zh-first, int8)
//   /tmp/opencode/kokoro-ab/kokoro-int8-multi-lang-v1_0  (en-first, int8)
//   /tmp/opencode/kokoro-ab/kokoro-multi-lang-v1_0       (en-first, fp32)
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;
import 'package:voice_agent/src/audio/audio_io.dart';
import 'package:voice_agent/src/models/model_paths.dart';
import 'package:voice_agent/src/speech/speech_worker.dart';

// Fricatives (/s/ /ʃ/ /f/ /θ/), digits, quote and multi-sentence rhythm:
// everything a narrowband path or a mis-phonemized lexicon trips over.
const text =
    "The quick brown fox jumped over the lazy dog's back, fifteen times in a "
    'row, while the kids laughed at 4:30. She whispered: "Really? All of '
    'that?" Then the rain fell softly on the tin roof again.';

const ab = '/tmp/opencode/kokoro-ab';

Future<void> main() async {
  Directory('$ab/out').createSync(recursive: true);
  await so.initBindingsAsync();
  final m = '/home/tim/voice-agent/models';
  final worker = await SpeechWorker.start(
    ModelPaths(
      whisperEncoder:
          '$m/sherpa-onnx-whisper-tiny.en/tiny.en-encoder.int8.onnx',
      whisperDecoder:
          '$m/sherpa-onnx-whisper-tiny.en/tiny.en-decoder.int8.onnx',
      tokens: '$m/sherpa-onnx-whisper-tiny.en/tiny.en-tokens.txt',
      vadModel: '$m/silero_vad.onnx',
    ),
  );

  const packs = <String, String>{
    'v1_1-int8':
        '/home/tim/voice-agent/models/kokoro-dl/kokoro-int8-multi-lang-v1_1',
    'v1_1-fp32': '$ab/kokoro-multi-lang-v1_1',
    'v1_0-int8': '$ab/kokoro-int8-multi-lang-v1_0',
    'v1_0-fp32': '$ab/kokoro-multi-lang-v1_0',
  };
  final want = text
      .toLowerCase()
      .split(RegExp(r'\W+'))
      .where((w) => w.length > 3)
      .toSet();

  for (final p in packs.entries) {
    final d = p.value;
    final model = File('$d/model.int8.onnx').existsSync()
        ? '$d/model.int8.onnx'
        : '$d/model.onnx';
    if (!File(model).existsSync() || !File('$d/voices.bin').existsSync()) {
      stdout.writeln('${p.key}: MISSING ($d) — skipped');
      continue;
    }
    final tts = so.OfflineTts(
      so.OfflineTtsConfig(
        model: so.OfflineTtsModelConfig(
          kokoro: so.OfflineTtsKokoroModelConfig(
            model: model,
            voices: '$d/voices.bin',
            tokens: '$d/tokens.txt',
            dataDir: '$d/espeak-ng-data',
            lexicon: '$d/lexicon-us-en.txt,$d/lexicon-zh.txt',
          ),
          numThreads: 4,
          provider: 'cpu',
        ),
        maxNumSenetences: 1,
      ),
    );
    stdout.writeln('\n${p.key}: numSpeakers=${tts.numSpeakers}');
    // Voices cluster by language prefix (af/b/am... English near the front
    // of both packs); sparse-scan and keep whatever produces English.
    for (final sid in [0, 1, 2, 3, 4, 6, 8, 11, 17, 30, 50, 70, 90]) {
      if (sid >= tts.numSpeakers) break;
      final sw = Stopwatch()..start();
      final audio = tts.generate(text: text, sid: sid);
      sw.stop();
      if (audio.samples.isEmpty) {
        stdout.writeln('  sid $sid: (empty)');
        continue;
      }
      final secs = audio.samples.length / audio.sampleRate;
      final rtf = sw.elapsedMilliseconds / 1000 / secs;
      File(
        '$ab/out/${p.key}_sid$sid.wav',
      ).writeAsBytesSync(encodeWav(audio.samples, audio.sampleRate));
      final heard = await worker.transcribe(audio.samples, audio.sampleRate);
      final got = heard
          .toLowerCase()
          .split(RegExp(r'\W+'))
          .where((w) => w.length > 3)
          .toSet();
      final cov = want.intersection(got).length;
      stdout.writeln(
        '  sid $sid: ${secs.toStringAsFixed(1)}s rtf ${rtf.toStringAsFixed(2)} '
        'cov $cov/${want.length} | "$heard"',
      );
    }
    tts.free();
  }
  worker.dispose();
  exit(0);
}
