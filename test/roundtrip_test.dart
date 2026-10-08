// Round-trip smoke test: wav fixture -> Whisper ASR -> text -> Piper TTS.
//
// Runs on the Linux host (no mic, no speaker) against the raw extracted
// model directories in models/ (not the zipped app assets). Run with:
//
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     flutter test test/roundtrip_test.dart
//
// The synthesized reply is written to build/roundtrip_reply.wav so you can
// listen to exactly what the app would have spoken.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';

void main() {
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final ttsDir =
      Directory('models/vits-piper-en_US-lessac-medium').absolute.path;
  final paths = ModelPaths(
    whisperEncoder: '$asrDir/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$asrDir/tiny.en-decoder.int8.onnx',
    whisperTokens: '$asrDir/tiny.en-tokens.txt',
    vitsModel: '$ttsDir/en_US-lessac-medium.onnx',
    vitsTokens: '$ttsDir/tokens.txt',
    espeakDataDir: '$ttsDir/espeak-ng-data',
  );

  final haveModels =
      File(paths.whisperDecoder).existsSync() && File(paths.vitsModel).existsSync();

  test('voice round trip: wav -> text -> wav', () async {
    if (!haveModels) {
      // ignore: avoid_print
      print('SKIPPED: extracted models not found under models/');
      return;
    }

    // 1. Transcribe a real speech fixture (same wavs ship with the model).
    final wav = File('$asrDir/test_wavs/0.wav').readAsBytesSync();
    final (samples, sampleRate) = decodeWav(wav);

    final worker = await SpeechWorker.start(paths);
    try {
      final swAsr = Stopwatch()..start();
      final text = await worker.transcribe(samples, sampleRate);
      swAsr.stop();
      // ignore: avoid_print
      print('ASR: "$text" (${samples.length / sampleRate}s of audio, '
          '${swAsr.elapsedMilliseconds} ms)');
      expect(text.trim(), isNotEmpty);

      // 2. Speak the transcription back.
      final swTts = Stopwatch()..start();
      final (audio, ttsSampleRate) = await worker.synthesize(text.trim());
      swTts.stop();
      final audioSeconds = audio.length / ttsSampleRate;
      // ignore: avoid_print
      print('TTS: ${audioSeconds}s of audio generated in '
          '${swTts.elapsedMilliseconds} ms '
          '(${(swTts.elapsedMilliseconds / audioSeconds).round()} ms/audio-sec)');
      expect(audio.length, greaterThan(ttsSampleRate)); // > 1 second

      // 3. Persist the reply so it can be listened to.
      final out = File('build/roundtrip_reply.wav')..createSync(recursive: true);
      out.writeAsBytesSync(encodeWav(audio, ttsSampleRate));
      // ignore: avoid_print
      print('Reply audio written to ${out.absolute.path}');
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
