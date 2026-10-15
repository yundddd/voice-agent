import 'dart:io';
import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';
Future<void> main(List<String> args) async {
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final ttsDir = Directory('models/vits-piper-en_US-lessac-medium').absolute.path;
  final worker = await SpeechWorker.start(ModelPaths(
    whisperEncoder: '$asrDir/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$asrDir/tiny.en-decoder.int8.onnx',
    whisperTokens: '$asrDir/tiny.en-tokens.txt',
    vitsModel: '$ttsDir/en_US-lessac-medium.onnx',
    vitsTokens: '$ttsDir/tokens.txt',
    espeakDataDir: '$ttsDir/espeak-ng-data',
    vadModel: Directory('models/silero_vad.onnx').absolute.path,
  ));
  for (final f in args) {
    final (s, r) = decodeWav(File(f).readAsBytesSync());
    // ignore: avoid_print
    print('${f.split('/').last}: "${await worker.transcribe(s, r)}"');
  }
  worker.dispose();
  exit(0);
}
