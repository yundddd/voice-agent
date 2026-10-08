// Host-side probe for ZipVoice zero-shot voice cloning (pure Dart).
//
// Clones a speaker from a reference wav (+ its transcript) and synthesizes
// arbitrary text, then verifies intelligibility by re-transcribing the clone
// with the Whisper model. Reports real-time factor (RTF) so phone latency
// can be estimated.
//
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     dart run tool/clone_probe.dart <ref.wav> "<ref transcript>" "<text to speak>"
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:voice_agent/audio_io.dart';

const modelDir = '/tmp/opencode/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia';
const vocoder = '/tmp/opencode/vocos_24khz.onnx';

Future<void> main(List<String> args) async {
  final refPath = args.isEmpty
      ? 'models/sherpa-onnx-whisper-tiny.en/test_wavs/0.wav'
      : args[0];
  final refText = args.length > 1
      ? args[1]
      : 'After early nightfall, the yellow lamps would light up here and '
            'there the squalid quarter of the brothels.';
  final text = args.length > 2
      ? args[2]
      : 'Hello Tim. This is what your cloned voice will sound like when '
            'the assistant replies to you from now on.';

  await sherpa_onnx.initBindingsAsync();

  final (refSamples, refRate) = decodeWav(File(refPath).readAsBytesSync());
  stderr.writeln(
    'reference: $refPath (${refSamples.length / refRate}s '
    '@ $refRate Hz)',
  );

  final tts = sherpa_onnx.OfflineTts(
    sherpa_onnx.OfflineTtsConfig(
      model: sherpa_onnx.OfflineTtsModelConfig(
        zipvoice: sherpa_onnx.OfflineTtsZipVoiceModelConfig(
          tokens: '$modelDir/tokens.txt',
          encoder: '$modelDir/encoder.int8.onnx',
          decoder: '$modelDir/decoder.int8.onnx',
          vocoder: vocoder,
          dataDir: '$modelDir/espeak-ng-data',
          lexicon: '$modelDir/lexicon.txt',
        ),
        numThreads: 4,
        debug: true,
        provider: 'cpu',
      ),
      maxNumSenetences: 4,
    ),
  );

  final sw = Stopwatch()..start();
  final audio = tts.generateWithConfig(
    text: text,
    config: sherpa_onnx.OfflineTtsGenerationConfig(
      referenceAudio: Float32List.fromList(refSamples),
      referenceSampleRate: refRate,
      referenceText: refText,
    ),
  );
  sw.stop();
  final seconds = audio.samples.length / audio.sampleRate;
  stdout.writeln(
    'clone_probe: generated ${seconds.toStringAsFixed(1)}s of '
    'audio at ${audio.sampleRate} Hz in ${sw.elapsedMilliseconds} ms '
    '(RTF ${(sw.elapsedMilliseconds / 1000 / seconds).toStringAsFixed(2)})',
  );

  final out = File('build/clone_probe.wav')..createSync(recursive: true);
  out.writeAsBytesSync(encodeWav(audio.samples, audio.sampleRate));
  stdout.writeln('clone_probe: wrote ${out.path}');
  tts.free();

  // Intelligibility check: transcribe the clone with Whisper.
  final asr = sherpa_onnx.OfflineRecognizer(
    sherpa_onnx.OfflineRecognizerConfig(
      model: sherpa_onnx.OfflineModelConfig(
        whisper: sherpa_onnx.OfflineWhisperModelConfig(
          encoder:
              'models/sherpa-onnx-whisper-tiny.en/tiny.en-encoder.int8.onnx',
          decoder:
              'models/sherpa-onnx-whisper-tiny.en/tiny.en-decoder.int8.onnx',
          language: 'en',
          task: 'transcribe',
        ),
        tokens: 'models/sherpa-onnx-whisper-tiny.en/tiny.en-tokens.txt',
        modelType: 'whisper',
        numThreads: 4,
        debug: false,
        provider: 'cpu',
      ),
    ),
  );
  final (check, checkRate) = decodeWav(out.readAsBytesSync());
  final stream = asr.createStream();
  stream.acceptWaveform(samples: check, sampleRate: checkRate);
  asr.decode(stream);
  final heard = asr.getResult(stream).text;
  stream.free();
  asr.free();
  stdout.writeln('clone_probe: whisper heard "$heard"');
  final ok = text
      .split(' ')
      .where((w) => w.length > 3)
      .where((w) => heard.toLowerCase().contains(w.toLowerCase()))
      .length;
  stdout.writeln(
    'clone_probe: ${ok > 4 ? 'PASS' : 'FAIL'} '
    '($ok long words recognized)',
  );
}
