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

  // Current worker geometry, applied manually so both variants share it.
  Float32List fix(Float32List s) => pocketLeadIn(s);

  Future<void> gen(String vp, String text, String tag) async {
    final (ref, refRate) = decodeWav(File(vp).readAsBytesSync());
    final a = tts.generateWithConfig(
      text: text,
      config: sherpa.OfflineTtsGenerationConfig(
        referenceAudio: ref,
        referenceSampleRate: refRate,
        numSteps: 2,
        extra: {'max_frames': (text.length + 30).clamp(60, 500)},
      ),
    );
    final s = fix(Float32List.fromList(a.samples));
    final heard = (await worker.transcribe(s, 24000)).toLowerCase();
    final name = vp.split('/').last.replaceAll('.wav', '');
    File('/tmp/opencode/short_${name}_$tag.wav').writeAsBytesSync(encodeWav(s, 24000));
    // ignore: avoid_print
    print('$name ${tag.padRight(7)} "$text" -> "$heard"');
  }

  for (final vp in voices) {
    await gen(vp, 'Sure!', 'bare');          // worst case: one short word
    await gen(vp, ' ' * 8 + 'Sure!', 'pad'); // official short-input pad
  }
  tts.free();
  worker.dispose();
  exit(0);
}
