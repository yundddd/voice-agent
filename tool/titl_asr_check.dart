// One-off: transcribe /tmp/titl/smoke.wav with the app's Whisper tiny.en
// to check the TITL student's output is intelligible speech. Reads the
// PCM by hand: titl_smoke.dart's ad-hoc WAV header is non-canonical.
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

Future<void> main() async {
  await so.initBindingsAsync();
  final bytes = File('/tmp/titl/smoke.wav').readAsBytesSync();
  final pcm = Int16List.sublistView(
    bytes,
    44,
    44 + ((bytes.length - 44) ~/ 2) * 2,
  );
  final samples = Float32List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    samples[i] = pcm[i] / 32768.0;
  }
  final rec = so.OfflineRecognizer(
    so.OfflineRecognizerConfig(
      model: so.OfflineModelConfig(
        whisper: so.OfflineWhisperModelConfig(
          encoder: 'models/sherpa-onnx-whisper-tiny.en/tiny.en-encoder.onnx',
          decoder: 'models/sherpa-onnx-whisper-tiny.en/tiny.en-decoder.onnx',
          language: 'en',
          task: 'transcribe',
        ),
        tokens: 'models/sherpa-onnx-whisper-tiny.en/tiny.en-tokens.txt',
        modelType: 'whisper',
        numThreads: 4,
      ),
    ),
  );
  final stream = rec.createStream();
  stream.acceptWaveform(samples: samples, sampleRate: 24000);
  rec.decode(stream);
  stdout.writeln('ASR of student audio: "${rec.getResult(stream).text}"');
}
