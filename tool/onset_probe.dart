// Headless onset-clipping probe (pure Dart, no mic, no Flutter).
//
// Feeds build/onset_probe.wav (0.5 s silence, then speech, then silence)
// through the same VAD + endpointing path the app uses, then transcribes the
// endpointed segment. If the transcription starts with the fixture's first
// word ("After"), the utterance attack survived detection.
//
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     dart run tool/onset_probe.dart [wavpath]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';

Future<void> main(List<String> args) async {
  final wavPath = args.isEmpty ? 'build/onset_probe.wav' : args.first;
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final ttsDir = Directory('models/vits-piper-en_US-lessac-medium').absolute.path;
  final paths = ModelPaths(
    whisperEncoder: '$asrDir/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$asrDir/tiny.en-decoder.int8.onnx',
    whisperTokens: '$asrDir/tiny.en-tokens.txt',
    vitsModel: '$ttsDir/en_US-lessac-medium.onnx',
    vitsTokens: '$ttsDir/tokens.txt',
    espeakDataDir: '$ttsDir/espeak-ng-data',
    vadModel: Directory('models/silero_vad.onnx').absolute.path,
  );

  final (samples, sampleRate) = decodeWav(File(wavPath).readAsBytesSync());
  stdout.writeln('probe: ${wavPath} (${samples.length / sampleRate}s)');

  final segment = Completer<Float32List>();
  final worker = await SpeechWorker.start(paths, onEvent: (e) {
    if (e.segment != null && !segment.isCompleted) segment.complete(e.segment!);
  });

  for (var i = 0; i + 512 <= samples.length; i += 512) {
    worker.sendAudio(Float32List.sublistView(samples, i, i + 512));
  }
  final silence = Float32List(512);
  for (var i = 0; i < (2 * sampleRate / 512).ceil(); i++) {
    worker.sendAudio(silence); // force endpoint
  }

  final seg = await segment.future.timeout(const Duration(seconds: 10));
  final text = await worker.transcribe(seg, sampleRate);
  worker.dispose();

  final expected = 'After early nightfall';
  final got = text.trim();
  stdout.writeln('segment: ${seg.length / sampleRate}s '
      '(speech portion is ${samples.length / sampleRate - 1.0}s incl. 0.5s lead silence)');
  stdout.writeln('transcript: "$got"');
  if (got.toLowerCase().startsWith(expected.toLowerCase())) {
    stdout.writeln('PASS: utterance attack preserved');
  } else {
    stdout.writeln('FAIL: beginning clipped (expected it to start with '
        '"$expected")');
    exitCode = 1;
  }
}
