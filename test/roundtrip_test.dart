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
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
    vadModel: Directory('models/silero_vad.onnx').absolute.path,
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

  test('VAD endpointing: streamed speech + 1s silence -> segment', () async {
    if (!haveModels) {
      // ignore: avoid_print
      print('SKIPPED: extracted models not found under models/');
      return;
    }

    final wav = File('$asrDir/test_wavs/1.wav').readAsBytesSync();
    final (samples, sampleRate) = decodeWav(wav);
    expect(sampleRate, 16000);

    final segment = Completer<Float32List>();
    final started = Completer<void>();
    final worker = await SpeechWorker.start(
      paths,
      endpointSilence: 1.0,
      onEvent: (e) {
        if (e.speechStarted && !started.isCompleted) started.complete();
        if (e.segment != null && !segment.isCompleted) {
          segment.complete(e.segment!);
        }
      },
    );
    try {
      // Stream the utterance in 512-sample windows, like the mic feed does,
      // then 1.5 s of silence to trip the endpoint.
      for (var i = 0; i + 512 <= samples.length; i += 512) {
        worker.sendAudio(Float32List.sublistView(samples, i, i + 512));
      }
      final silence = Float32List(512);
      final silenceWindows = (1.6 * sampleRate / 512).ceil(); // > 1 s endpoint
      for (var i = 0; i < silenceWindows; i++) {
        worker.sendAudio(silence);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      await started.future.timeout(const Duration(seconds: 5));
      final seg =
          await segment.future.timeout(const Duration(seconds: 10));
      // ignore: avoid_print
      print('VAD segment: ${(seg.length / 16000).toStringAsFixed(2)}s of '
          '${(samples.length / 16000).toStringAsFixed(2)}s streamed');
      expect(seg.length, greaterThan(16000)); // > 1 s of trimmed speech
      // Segments may carry a little trailing pre-endpoint silence.
      expect(seg.length, lessThan(samples.length + (1.5 * sampleRate).round()));

      final text = await worker.transcribe(seg, 16000);
      // ignore: avoid_print
      print('Endpointed utterance transcribed: "$text"');
      expect(text.trim(), isNotEmpty);
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
