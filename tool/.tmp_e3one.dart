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
  final (ref, refRate) = decodeWav(File('$d/voices/jane.wav').readAsBytesSync());
  for (var rep = 0; rep < 3; rep++) {
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
    final s = pocketLeadIn(Float32List.fromList(a.samples));
    final heard = (await worker.transcribe(s, 24000)).toLowerCase();
    File('/tmp/opencode/e3one_$rep.wav').writeAsBytesSync(encodeWav(s, 24000));
    // ignore: avoid_print
    print('jane rep=$rep ${heard.contains("tim") || heard.contains("hello") ? "WIN" : "MISS"}  "$heard"');
  }
  tts.free();
  worker.dispose();
  exit(0);
}
