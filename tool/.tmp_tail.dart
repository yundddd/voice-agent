import 'dart:io';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';

Future<void> main(List<String> args) async {
  sherpa.initBindings();
  final d = '/tmp/opencode/pocket-pack/pocket-tts';
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
  const line = 'Hello Tim. Pocket TTS speaking, generated entirely on this device.';

  Float32List extendTail(Float32List ref, int rate, double speech, double sil) {
    // First `speech` seconds of the prompt, then `sil` seconds of silence.
    final n = ((speech + sil) * rate).round();
    final out = Float32List(n);
    final take = ref.length < (speech * rate).round() ? ref.length : (speech * rate).round();
    out.setRange(0, take, ref);
    return out;
  }

  Future<void> gen(String name, String text, Float32List ref, int rate, String tag) async {
    final a = tts.generateWithConfig(
      text: text,
      config: sherpa.OfflineTtsGenerationConfig(
        referenceAudio: ref,
        referenceSampleRate: rate,
        numSteps: 2,
        extra: {'max_frames': (text.length + 30).clamp(60, 500)},
      ),
    );
    final s = pocketLeadIn(Float32List.fromList(a.samples));
    final heard = (await worker.transcribe(s, 24000)).toLowerCase();
    final hits = ['hello', 'tim'].where(heard.contains).length;
    File('/tmp/opencode/tl_${name}_$tag.wav').writeAsBytesSync(encodeWav(s, 24000));
    // ignore: avoid_print
    print('$name ${tag.padRight(9)} hits=$hits  "$heard"');
  }

  for (final name in ['jane', 'alba', 'anna', 'bill_boerst']) {
    final (ref, rate) = decodeWav(File('$d/voices/$name.wav').readAsBytesSync());
    await gen(name, line, ref, rate, 'A_plain');
    await gen(name, ' ' * 8 + line, ref, rate, 'B_pad');
    await gen(name, line, extendTail(ref, rate, 8.0, 1.8), rate, 'C_tail');
    await gen(name, ' ' * 8 + line, extendTail(ref, rate, 8.0, 1.8), rate, 'D_both');
  }
  tts.free();
  worker.dispose();
  exit(0);
}
