import 'dart:io';
import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';
// ignore: avoid_print
void main(List<String> args) async {
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final piper = Directory('models/vits-piper-en_US-lessac-medium').absolute.path;
  final paths = ModelPaths(
    whisperEncoder: '$asrDir/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$asrDir/tiny.en-decoder.int8.onnx',
    whisperTokens: '$asrDir/tiny.en-tokens.txt',
    vitsModel: '$piper/en_US-lessac-medium.onnx',
    vitsTokens: '$piper/tokens.txt',
    espeakDataDir: '$piper/espeak-ng-data',
    vadModel: Directory('models/silero_vad.onnx').absolute.path,
  );
  final worker = await SpeechWorker.start(paths);
  for (final f in args) {
    final (s, r) = decodeWav(File(f).readAsBytesSync());
    final tail = s.sublist((s.length - 6 * r).clamp(0, s.length));
    // ignore: avoid_print
    print('$f tail6s: "${await worker.transcribe(tail, r)}"');
  }
  worker.dispose();
}
