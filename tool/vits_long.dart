// quick host probe: long-reply VAD-truncation check for Piper voices
import 'dart:io';
import 'package:voice_agent/audio_io.dart';
import 'package:voice_agent/model_paths.dart';
import 'package:voice_agent/speech_worker.dart';

const long120 =
    'Here is the full plan for Saturday, and it has several parts. '
    'The library stays open until nine tonight, but the returns bin '
    'closes at six, so plan around that. The bus line twelve runs every '
    'fifteen minutes during the day and only every forty minutes after '
    'eight, which means the last useful ride leaves the square at twenty '
    'past nine. If it rains, the walk takes you past the covered arcade '
    'on market street and saves you from the downpour on oak. Bring the '
    'small folding umbrella from the hall closet, the one with the wooden '
    'handle, and wear the boots by the door, because the path along the '
    'creek is always mud. The market stalls set up at seven and the good '
    'bread at the corner ovens sells out before eight, so arrive early, '
    'and stop at the flower cart near the fountain if you want tulips '
    'without paying Saturday prices. The post office window closes at '
    'four on Saturdays, so mail the package before lunch.';
const text =
    'Here is what I found. The library stays open until nine tonight, '
    'but the returns bin closes at six, so plan around that. The bus '
    'line twelve runs every fifteen minutes during the day and only '
    'every forty minutes after eight, which means the last useful '
    'ride leaves the square at twenty past nine. If it rains, the '
    'walk takes you past the covered arcade on market street and '
    'saves you from the downpour on oak.';
Future<void> main() async {
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final piper = Directory(
    'models/vits-piper-en_US-lessac-medium',
  ).absolute.path;
  final lib = Directory('models/tts-libritts-r-medium-int8').absolute.path;
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
  for (final (tag, model, tokens) in [
    ('lessac', '$piper/en_US-lessac-medium.onnx', '$piper/tokens.txt'),
    ('libritts', '$lib/en_US-libritts_r-medium.onnx', '$lib/tokens.txt'),
  ]) {
    await worker.useTts(
      TtsSpec.vits(
        vitsModel: model,
        vitsTokens: tokens,
        espeakDataDir: '$piper/espeak-ng-data',
        sid: 0,
      ),
    );
    final (audio, rate) = await worker.synthesize(long120);
    final heard = (await worker.transcribe(audio, rate)).toLowerCase();
    File('build/vits_120_$tag.wav').writeAsBytesSync(encodeWav(audio, rate));
    // ignore: avoid_print
    print(
      '[$tag] ${audio.length / rate}s; tail: ${heard.split(' ').length > 8 ? heard.split(' ').sublist(heard.split(' ').length - 8).join(' ') : heard}',
    );
  }
  worker.dispose();
}
