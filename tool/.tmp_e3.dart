import 'dart:io';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';

Future<void> main(List<String> args) async {
  sherpa.initBindings();
  final d = '/tmp/opencode/pocket-pack/pocket-tts';
  final voices = Directory('$d/voices').listSync().whereType<File>().map((f) => f.path).toList()..sort();
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      pocket: sherpa.OfflineTtsPocketModelConfig(
        lmFlow: '$d/lm_flow.int8.onnx',
        lmMain: '$d/lm_main.int8.onnx',
        encoder: '$d/encoder.onnx',
        decoder: '$d/decoder.int8.onnx',
        textConditioner: '$d/text_conditioner.onnx',
        vocabJson: '$d/vocab.json',
        tokenScoresJson: '$d/token_scores.json',
      ),
      numThreads: 4,
    ),
  ));
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final tDir = Directory('models/vits-piper-en_US-lessac-medium').absolute.path;
  final worker = await SpeechWorker.start(ModelPaths(
    whisperEncoder: '$asrDir/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$asrDir/tiny.en-decoder.int8.onnx',
    whisperTokens: '$asrDir/tiny.en-tokens.txt',
    vitsModel: '$tDir/en_US-lessac-medium.onnx',
    vitsTokens: '$tDir/tokens.txt',
    espeakDataDir: '$tDir/espeak-ng-data',
    vadModel: Directory('models/silero_vad.onnx').absolute.path,
  ));

  // Shipping geometry: ' .... ' prefix, ss 1.0, trim inside the pause, 400 ms.
  Float32List lead400(Float32List s) {
    const rate = 24000, drop = 6000, lead = 9600 ~/ 2; // 250ms drop, 400ms lead
    if (s.length <= drop) return s;
    final fade = 720;
    final out = Float32List(s.length - drop + lead);
    for (var i = 0; i < s.length - drop; i++) {
      var v = s[i + drop];
      if (i < fade) v *= i / fade;
      out[i + lead] = v;
    }
    return out;
  }

  var wins = 0, total = 0;
  for (var rep = 0; rep < 3; rep++) {
    for (final f in voices) {
      final name = f.split('/').last.replaceAll('.wav', '');
      final (ref, refRate) = decodeWav(File(f).readAsBytesSync());
      const text = ' .... Hello Tim. Pocket TTS speaking, generated entirely on this device.';
      final a = tts.generateWithConfig(
        text: text,
        config: sherpa.OfflineTtsGenerationConfig(
          referenceAudio: ref,
          referenceSampleRate: refRate,
          numSteps: 2,
          silenceScale: 1.0,
          extra: {'max_frames': (text.length + 60).clamp(90, 500)},
        ),
      );
      final s = lead400(Float32List.fromList(a.samples));
      final heard = (await worker.transcribe(s, 24000)).toLowerCase();
      final hit = heard.contains('tim') || heard.contains('hello');
      total++;
      if (hit) wins++;
      File('/tmp/opencode/e3_${name}_$rep.wav').writeAsBytesSync(encodeWav(s, 24000));
      // ignore: avoid_print
      print('rep=$rep $name ${hit ? "WIN" : "MISS"}  "$heard"');
    }
  }
  // ignore: avoid_print
  print('=== first-word present: $wins/$total');
  tts.free();
  worker.dispose();
  exit(0);
}
