// Host smoke test for the teacher-in-the-loop engine: phonemize with
// the pure-Dart LexiconPronouncer over Kokoro's own lexicon files (the
// students' espeak-free front-end), run the student graph on sherpa's
// x64 libonnxruntime, and write a WAV we can listen to (or analyze)
// before ever booting the phone-side path.
//
//   dart run tool/titl_smoke.dart [--lex <lexicon-us-en.txt[,gb]>] <words…>
//
// Model + vocab load from /tmp/titl/ (unzip a tts-titl-af_heart.zip
// there); the lexicon defaults to the same dir.
import 'dart:io';
import 'dart:typed_data';

import 'package:voice_agent/src/speech/lexicon_pronouncer.dart';
import 'package:voice_agent/src/speech/titl_engine.dart';

Future<void> main(List<String> argv) async {
  String arg(String name, String dflt) {
    final i = argv.indexOf(name);
    return i >= 0 ? argv[i + 1] : dflt;
  }

  final text = argv.where((a) => !a.startsWith('--')).join(' ').isEmpty
      ? 'Hello from the small student. I am eight million parameters of '
            'Kokoro, distilled down to nine megabytes, and I still sound '
            'like the teacher.'
      : argv.where((a) => !a.startsWith('--')).join(' ');
  final pron = LexiconPronouncer.loadAll(
    arg('--lex', '/tmp/titl/lexicon-us-en.txt').split(','),
  );
  if (pron == null) {
    stderr.writeln('no lexicon file readable — pass --lex <path>');
    exit(1);
  }
  final engine = TitlEngine.load(
    modelPath: '/tmp/titl/model.onnx',
    vocabPath: '/tmp/titl/vocab.json',
  );
  final phonemes = TitlEngine.phonemesFromWords(
    pron.phonemize(text),
    engine.vocab.keys.toSet(),
  );
  stdout.writeln('phonemes: $phonemes');
  final t0 = DateTime.now();
  final audio = engine.synth(phonemes);
  final ms = DateTime.now().difference(t0).inMilliseconds;
  stdout.writeln(
    'samples: ${audio.length} (${audio.length / TitlEngine.sampleRate} s) '
    'in ${ms}ms',
  );
  var peak = 0.0;
  var sum = 0.0;
  for (final s in audio) {
    final a = s.abs();
    if (a > peak) peak = a;
    sum += a;
  }
  stdout.writeln('peak ${peak.toStringAsFixed(3)} avg ${sum / audio.length}');
  // 24 kHz mono PCM16 WAV
  final pcm = Int16List(audio.length);
  for (var i = 0; i < audio.length; i++) {
    pcm[i] = (audio[i] * 32767).clamp(-32768, 32767).toInt();
  }
  final bytes = pcm.buffer.asUint8List();
  final pcmBytes = Uint8List.fromList(bytes);
  // Chunk size rides in ck(); the body is the 16-byte fmt data.
  final fmt = Uint8List.fromList([
    1, 0, // PCM
    1, 0, // mono
    0x3c, 0x5d, 0, 0, // 24000
    0x78, 0xbb, 0, 0, // byte rate 48000
    2, 0, // block align
    16, 0, // bits
  ]);
  final wav = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add(_u32(36 + pcmBytes.length))
    ..add('WAVE'.codeUnits);
  void ck(String tag, List<int> d) {
    wav.add(tag.codeUnits);
    wav.add(_u32(d.length));
    wav.add(d);
  }

  ck('fmt ', fmt);
  ck('data', pcmBytes);
  File('/tmp/titl/smoke.wav').writeAsBytesSync(wav.toBytes());
  stdout.writeln('wrote /tmp/titl/smoke.wav');
}

List<int> _u32(int n) => [
  n & 0xff,
  (n >> 8) & 0xff,
  (n >> 16) & 0xff,
  (n >> 24) & 0xff,
];
