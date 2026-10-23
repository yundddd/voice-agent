// Pocket TTS voice probe (host): swaps the worker through every preset
// reference, re-transcribes the replies with Whisper (intelligibility), and
// prints RTF. Assets: run tool/build_pocket_pack.sh first.
//
//   POCKET_DIR=/tmp/opencode/pocket-pack/pocket-tts \
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     dart run tool/pocket_probe.dart
import 'dart:io';

import 'package:voice_agent/src/audio/audio_io.dart';
import 'package:voice_agent/src/models/model_paths.dart';
import 'package:voice_agent/src/speech/speech_worker.dart';

Future<void> main(List<String> args) async {
  final dir =
      Platform.environment['POCKET_DIR'] ??
      '/tmp/opencode/pocket-pack/pocket-tts';
  // Kept in sync with TtsVoice.pocketRefs; inlined so the probe stays
  // free of package:flutter imports (plain `dart run` can't compile those).
  // The v2 pack ships the fp32 graph set (no .int8 files).
  const refs = ['jane', 'anna', 'jean', 'michael', 'alba', 'bill_boerst'];
  TtsSpec spec(int sid) => TtsSpec.pocket(
    pocketLmFlow: '$dir/lm_flow.onnx',
    pocketLmMain: '$dir/lm_main.onnx',
    pocketEncoder: '$dir/encoder.onnx',
    pocketDecoder: '$dir/decoder.onnx',
    pocketTextConditioner: '$dir/text_conditioner.onnx',
    pocketVocabJson: '$dir/vocab.json',
    pocketTokenScoresJson: '$dir/token_scores.json',
    pocketRefs: [for (final r in refs) '$dir/voices/$r.wav'],
    sid: sid,
  );
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final paths = ModelPaths(
    whisperEncoder: '$asrDir/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$asrDir/tiny.en-decoder.int8.onnx',
    tokens: '$asrDir/tiny.en-tokens.txt',
    vadModel: Directory('models/silero_vad.onnx').absolute.path,
  );
  final worker = await SpeechWorker.start(paths);

  const line =
      'Hello Tim. Pocket TTS speaking, generated entirely on this device.';
  for (var sid = 0; sid < refs.length; sid++) {
    final speakers = await worker.useTts(spec(sid));
    final sw = Stopwatch()..start();
    final (audio, rate) = await worker.synthesize(line);
    sw.stop();
    final secs = audio.length / rate;
    final heard = (await worker.transcribe(audio, rate)).toLowerCase();
    final words = line.split(' ').where((w) => w.length > 3).toList();
    final hits = words.where((w) => heard.contains(w.toLowerCase())).length;
    // ignore: avoid_print
    print(
      '[${refs[sid]}] sid=$sid speakers=$speakers rate=$rate; '
      '${secs.toStringAsFixed(1)}s audio, ${sw.elapsedMilliseconds} ms '
      '(RTF ${(sw.elapsedMilliseconds / 1000 / secs).toStringAsFixed(2)}); '
      '$hits/${words.length} words -> "$heard"',
    );
    File('build/roundtrip_pocket_${refs[sid]}.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync(encodeWav(audio, rate));
  }
  worker.dispose();
}
