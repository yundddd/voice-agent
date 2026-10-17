// One-off: render the same lines as tool/titl_smoke.dart with the teacher
// (Kokoro v1.0 fp32 pack, sid 3 = af_heart) for A/B audition of the TITL
// student. Writes /tmp/opencode/samples/teacher_*.wav.
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'package:voice_agent/src/audio/audio_io.dart';

const dir = '/tmp/opencode/kokoro-ab/kokoro-multi-lang-v1_0';

const lines = {
  'preview': 'Hi! This is how your assistant will sound with this voice.',
  'fricatives':
      "The quick brown fox jumped over the lazy dog's back, "
      'fifteen times in a row, while the kids laughed at 4:30. She '
      'whispered: "Really? All of that?" Then the rain fell softly on '
      'the tin roof again.',
  'meeting':
      'Your meeting with Dana is at 9:30 tomorrow. Should I '
      'prepare the summary, or reschedule?',
};

Future<void> main() async {
  await so.initBindingsAsync();
  final tts = so.OfflineTts(
    so.OfflineTtsConfig(
      model: so.OfflineTtsModelConfig(
        // (kokoro rides OfflineTtsModelConfig.kokoro — see kokoro_ab.dart)
        kokoro: so.OfflineTtsKokoroModelConfig(
          model: '$dir/model.onnx',
          voices: '$dir/voices.bin',
          tokens: '$dir/tokens.txt',
          dataDir: '$dir/espeak-ng-data',
          lexicon: '$dir/lexicon-us-en.txt,$dir/lexicon-gb-en.txt',
        ),
        numThreads: 4,
        provider: 'cpu',
      ),
      maxNumSenetences: 1,
    ),
  );
  for (final l in lines.entries) {
    final a = tts.generate(text: l.value, sid: 3); // af_heart
    File(
      '/tmp/opencode/samples/teacher_${l.key}.wav',
    ).writeAsBytesSync(encodeWav(a.samples, a.sampleRate));
    stdout.writeln(
      '${l.key}: ${(a.samples.length / a.sampleRate).toStringAsFixed(1)}s',
    );
  }
  tts.free();
  exit(0);
}
