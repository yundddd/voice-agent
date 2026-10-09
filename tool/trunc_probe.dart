// NeuTTS tail-truncation probe (host).
//
// Synthesizes realistic multi-sentence assistant replies with each preset
// voice, saves the wavs, transcribes them, and prints a tail-energy profile
// plus whether the LAST content words survived. Distinguishes:
//   - early EOS   -> audio ends on a clean stop, tail decays, last words gone
//   - token cap   -> audio ends at ~2048 tokens (~40 s) mid-word, no decay
//   - no bug      -> last keyword heard, natural trailing silence
//
//   NEUTTS_DIR=/tmp/opencode/neutts-nano \
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     dart run tool/trunc_probe.dart [gguf-path]
import 'dart:io';
import 'dart:math' as math;

import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';

// A medium two-sentence reply and a long three-sentence one. Both end on a
// distinctive, unlikely-to-be-garbled keyword so tail survival is checkable.
const texts = {
  'medium':
      'Sure! The weather tomorrow will be mostly sunny with a high of '
      'twenty-two degrees. I would leave around nine in the morning to '
      'avoid the bridge traffic in the afternoon.',
  'long':
      'Here is what I found. The library stays open until nine tonight, '
      'but the returns bin closes at six, so plan around that. The bus '
      'line twelve runs every fifteen minutes during the day and only '
      'every forty minutes after eight, which means the last useful '
      'ride leaves the square at twenty past nine. If it rains, the '
      'walk takes you past the covered arcade on market street and '
      'saves you from the downpour on oak.',
};
const finalKeywords = {'medium': 'afternoon', 'long': 'oak'};
const presets = {'greta': 0, 'jo': 1, 'mateo': 2, 'juliette': 3};

Future<void> main(List<String> args) async {
  final dir = Platform.environment['NEUTTS_DIR'] ?? '/tmp/opencode/neutts-nano';
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
  Directory('build').createSync(recursive: true);

  for (final len in texts.keys) {
    final text = texts[len]!;
    for (final e in presets.entries) {
      final spec = TtsSpec.neutts(
        neuttsGguf: gguf,
        neuttsDecoder: '$dir/neucodec_decoder.safetensors',
        neuttsVoices: '$dir/voices',
        neuttsRefs: const ['greta', 'jo', 'mateo', 'juliette'],
        espeakDataDir: '/tmp/opencode/espeak-neutts-test',
        neuttsLib: lib,
        neuttsSeed: 7,
        sid: e.value,
      );
      await worker.useTts(spec);
      final sw = Stopwatch()..start();
      final (audio, rate) = await worker.synthesize(text);
      sw.stop();
      final secs = audio.length / rate;
      final heard = (await worker.transcribe(audio, rate)).toLowerCase();
      final words = text
          .split(' ')
          .map(
            (w) => w.replaceAll(RegExp(r'[^a-z0-9]', caseSensitive: false), ''),
          )
          .where((w) => w.length > 3)
          .toList();
      final hits = words.where((w) => heard.contains(w.toLowerCase())).length;
      // Tail energy: 20 ms RMS slots over the last second, dB.
      final slots = <int>[];
      for (
        var i = math.max(0, audio.length - rate);
        i < audio.length;
        i += rate ~/ 50
      ) {
        var sum = 0.0;
        var n = 0;
        for (var j = i; j < math.min(i + rate ~/ 50, audio.length); j++) {
          sum += audio[j] * audio[j];
          n++;
        }
        slots.add(
          (10 * math.log(math.max(n == 0 ? 1e-9 : sum / n, 1e-9)) / math.ln10)
              .round(),
        );
      }
      final heardWords = heard.split(RegExp(r'\s+'));
      final file = 'build/trunc_${e.key}_$len.wav';
      File(file).writeAsBytesSync(encodeWav(audio, rate));
      // ignore: avoid_print
      print(
        '[${e.key}/$len] ${secs.toStringAsFixed(1)}s audio (${sw.elapsedMilliseconds} ms) '
        'words $hits/${words.length} keyword "${finalKeywords[len]}"='
        '${heard.contains(finalKeywords[len]!) ? 'HEARD' : 'MISSING'} '
        'heard-tail: ${heardWords.length > 8 ? heardWords.sublist(heardWords.length - 8).join(' ') : heard}',
      );
      // ignore: avoid_print
      print('  tail dB ${slots.sublist(math.max(0, slots.length - 40))}');
    }
  }
  worker.dispose();
}
