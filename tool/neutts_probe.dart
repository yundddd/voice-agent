// NeuTTS voice probe (host): re-transcribes synthesized wavs with Whisper,
// re-synthesizes a fixed line (determinism check) and prints RTF.
//
//   source ~/.env
//   NEUTTS_DIR=/tmp/opencode/neutts-pack/neutts-nano \
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     dart run tool/neutts_probe.dart [gguf-path]
import 'dart:io';

import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';

Future<void> main(List<String> args) async {
  final dir =
      Platform.environment['NEUTTS_DIR'] ?? '/tmp/opencode/neutts-assets';
  final lib =
      Platform.environment['NEUTTS_BRIDGE'] ??
      '/tmp/opencode/neutts-rs/target/release/libneutts_bridge.so';
  final gguf = args.isNotEmpty ? args.first : '$dir/neutts-nano-Q4_0.gguf';
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final ttsDir = Directory(
    'models/vits-piper-en_US-lessac-medium',
  ).absolute.path;
  final paths = ModelPaths(
    whisperEncoder: '$asrDir/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$asrDir/tiny.en-decoder.int8.onnx',
    whisperTokens: '$asrDir/tiny.en-tokens.txt',
    vitsModel: '$ttsDir/en_US-lessac-medium.onnx',
    vitsTokens: '$ttsDir/tokens.txt',
    espeakDataDir: '$ttsDir/espeak-ng-data',
    vadModel: Directory('models/silero_vad.onnx').absolute.path,
  );
  final worker = await SpeechWorker.start(paths);
  TtsSpec spec(int sid, int seed) => TtsSpec.neutts(
    neuttsGguf: gguf,
    neuttsDecoder: '$dir/neucodec_decoder.safetensors',
    neuttsVoices: '$dir/voices',
    neuttsRefs: const ['greta', 'jo', 'juliette', 'mateo'],
    espeakDataDir: '/tmp/opencode/espeak-neutts-test',
    neuttsLib: lib,
    neuttsSeed: seed,
    sid: sid,
  );

  Future<void> report(String tag, String text) async {
    final sw = Stopwatch()..start();
    final (audio, rate) = await worker.synthesize(text);
    sw.stop();
    final secs = audio.length / rate;
    final heard = (await worker.transcribe(audio, rate)).toLowerCase();
    final hits = text
        .split(' ')
        .where((w) => w.length > 3)
        .where((w) => heard.contains(w.toLowerCase()))
        .length;
    // ignore: avoid_print
    print(
      '[$tag] ${secs.toStringAsFixed(1)}s audio, ${sw.elapsedMilliseconds} ms '
      '(RTF ${(sw.elapsedMilliseconds / 1000 / secs).toStringAsFixed(2)}); '
      '$hits/${text.split(' ').where((w) => w.length > 3).length} words -> "$heard"',
    );
  }

  Future<void> asrFile(String path) async {
    final (s, r) = decodeWav(File(path).readAsBytesSync());
    final heard = (await worker.transcribe(s, r)).toLowerCase();
    // ignore: avoid_print
    print('[file ${path.split('/').last}] "$heard"');
  }

  const line =
      'Hello Tim. NeuTTS nano speaking, generated entirely on this device.';
  for (final (seed, sid) in [
    (7, 0), (7, 1), (7, 2), (7, 3),
    (42, 0), (42, 1), (42, 2), (42, 3),
  ]) {
    await worker.useTts(spec(sid, seed));
    await report('seed$seed sid$sid', line);
  }
  for (final f in [
    'build/roundtrip_neutts.wav',
    'build/roundtrip_neutts_jo.wav',
  ]) {
    if (File(f).existsSync()) await asrFile(f);
  }
  worker.dispose();
}
