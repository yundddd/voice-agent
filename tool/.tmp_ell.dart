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
  Float32List extendTail(Float32List ref, int rate) {
    const take = 8.0;
    final out = Float32List(((take + 1.8) * rate).round());
    final n = ref.length < (take * rate).round() ? ref.length : (take * rate).round();
    out.setRange(0, n, ref);
    return out;
  }

  Future<void> gen(String name, String text, Float32List ref, int rate,
      double ss, String tag) async {
    final a = tts.generateWithConfig(
      text: text,
      config: sherpa.OfflineTtsGenerationConfig(
        referenceAudio: ref,
        referenceSampleRate: rate,
        numSteps: 2,
        silenceScale: ss,
        extra: {'max_frames': (text.length + 60).clamp(90, 500)},
      ),
    );
    final s = pocketLeadIn(Float32List.fromList(a.samples));
    final heard = (await worker.transcribe(s, 24000)).toLowerCase();
    final hits = ['hello', 'tim'].where(heard.contains).length;
    File('/tmp/opencode/el_${name}_${tag}_$hits.wav').writeAsBytesSync(encodeWav(s, 24000));
    // ignore: avoid_print
    print('$name ${tag.padRight(4)} hits=$hits  "$heard"');
  }

  for (final name in ['jane', 'alba', 'anna', 'bill_boerst']) {
    final (ref, rate) = decodeWav(File('$d/voices/$name.wav').readAsBytesSync());
    await gen(name, line, ref, rate, 1.0, 'ss1');            // control: ss off, no ellipsis
    await gen(name, '... $line', ref, rate, 0.2, 'e1');      // ellipsis, ss default
    await gen(name, '... $line', ref, rate, 1.0, 'e2');      // ellipsis, ss off
    await gen(name, '.... $line', ref, rate, 1.0, 'e3');     // longer pause, ss off
    await gen(name, '... $line', extendTail(ref, rate), rate, 1.0, 'f'); // + tail ext
  }
  tts.free();
  worker.dispose();
  exit(0);
}
