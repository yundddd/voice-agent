// Round-trip smoke test: wav fixture -> Whisper ASR -> text -> Kokoro TTS.
//
// Runs on the Linux host (no mic, no speaker) against the raw extracted
// model directories in models/ (not the zipped app assets). Run with:
//
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     flutter test test/roundtrip_test.dart
//
// The synthesized reply is written to build/roundtrip_reply.wav so you can
// listen to exactly what the app would have spoken. Kokoro is the app's
// only TTS engine; the test skips its leg until the pack is staged (the
// app downloads it on selection; KOKORO_DIR overrides the path).
//
// Where libonnxruntime cannot load (no LD_LIBRARY_PATH), every test here
// SKIPS instead of failing: the default run stays green, and the
// deterministic pipeline coverage lives in worker_fake_test.dart — the
// same worker isolate and job protocol on FakeBackends, no ONNX.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:voice_agent/src/audio/audio_io.dart';
import 'package:voice_agent/src/models/model_paths.dart';
import 'package:voice_agent/src/speech/speech_worker.dart';
import 'package:voice_agent/src/speech/tts_voices.dart';

void main() {
  final asrDir = Directory('models/sherpa-onnx-whisper-tiny.en').absolute.path;
  final paths = ModelPaths(
    whisperEncoder: '$asrDir/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$asrDir/tiny.en-decoder.int8.onnx',
    tokens: '$asrDir/tiny.en-tokens.txt',
    vadModel: Directory('models/silero_vad.onnx').absolute.path,
  );

  final haveModels = File(paths.whisperDecoder).existsSync();

  bool? runtimeOk;
  Future<bool> nativeUsable() async {
    // dlopen fails identically from any isolate, so probing here predicts
    // the worker's fate; initBindingsAsync caches across the suite.
    if (runtimeOk == true) return true;
    try {
      await sherpa_onnx.initBindingsAsync();
      runtimeOk = true;
    } catch (_) {
      runtimeOk = false;
    }
    return runtimeOk == true;
  }

  Future<bool> ready(String what) async {
    if (!haveModels) {
      // ignore: avoid_print
      print('SKIPPED $what: extracted models not found under models/');
      return false;
    }
    if (!await nativeUsable()) {
      // ignore: avoid_print
      print(
        'SKIPPED $what: libonnxruntime not loadable '
        '(set LD_LIBRARY_PATH to the sherpa_onnx_linux lib dir)',
      );
      return false;
    }
    return true;
  }

  test('ASR: wav fixture -> Whisper -> text', () async {
    if (!await ready('ASR roundtrip')) return;

    // Transcribe a real speech fixture (same wavs ship with the model).
    final wav = File('$asrDir/test_wavs/0.wav').readAsBytesSync();
    final (samples, sampleRate) = decodeWav(wav);

    final worker = await SpeechWorker.start(paths);
    try {
      final swAsr = Stopwatch()..start();
      final text = await worker.transcribe(samples, sampleRate);
      swAsr.stop();
      // ignore: avoid_print
      print(
        'ASR: "$text" (${samples.length / sampleRate}s of audio, '
        '${swAsr.elapsedMilliseconds} ms)',
      );
      expect(text.trim(), isNotEmpty);
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('VAD endpointing: streamed speech + 1s silence -> segment', () async {
    if (!await ready('VAD endpointing')) return;

    final wav = File('$asrDir/test_wavs/1.wav').readAsBytesSync();
    final (samples, sampleRate) = decodeWav(wav);
    expect(sampleRate, 16000);

    final segment = Completer<Float32List>();
    final started = Completer<void>();
    final worker = await SpeechWorker.start(
      paths,
      endpointSilence: 1.0,
      onEvent: (e) {
        // ignore: avoid_print
        if (e.note != null) print('[note] ${e.note}');
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
      final seg = await segment.future.timeout(const Duration(seconds: 10));
      // ignore: avoid_print
      print(
        'VAD segment: ${(seg.length / 16000).toStringAsFixed(2)}s of '
        '${(samples.length / 16000).toStringAsFixed(2)}s streamed',
      );
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

  test('Kokoro v1_0 fp32 speaks preset styles', () async {
    final dir =
        Platform.environment['KOKORO_DIR'] ??
        '/tmp/opencode/kokoro-ab/kokoro-multi-lang-v1_0';
    TtsSpec spec(int sid) => TtsSpec.kokoro(
      kokoroModel: '$dir/model.onnx',
      kokoroVoices: '$dir/voices.bin',
      kokoroTokens: '$dir/tokens.txt',
      kokoroDataDir: '$dir/espeak-ng-data',
      kokoroLexicon: '$dir/lexicon-us-en.txt,$dir/lexicon-gb-en.txt',
      sid: sid,
    );
    if (!await ready('Kokoro TTS') ||
        !File('$dir/model.onnx').existsSync() ||
        !File('$dir/voices.bin').existsSync()) {
      // ignore: avoid_print
      print('SKIPPED Kokoro assets: not staged under $dir');
      return;
    }

    final worker = await SpeechWorker.start(paths);
    try {
      final speakers = await worker.useTts(spec(0));
      expect(speakers, greaterThan(10)); // 54-style roster drives the slider

      const line =
          'The quick brown fox jumped over the lazy dog, and the kids '
          'laughed out loud at the old joke.';
      for (final sid in [1, 8]) {
        await worker.useTts(spec(sid));
        final sw = Stopwatch()..start();
        final (audio, sampleRate) = await worker.synthesize(line);
        sw.stop();
        final seconds = audio.length / sampleRate;
        // ignore: avoid_print
        print(
          'kokoro TTS sid $sid: ${seconds.toStringAsFixed(1)}s generated in '
          '${sw.elapsedMilliseconds} ms (RTF '
          '${(sw.elapsedMilliseconds / 1000 / seconds).toStringAsFixed(2)})',
        );
        expect(audio.length, greaterThan(sampleRate));
        expect(sampleRate, 24000);
        final out = File('build/roundtrip_reply_sid$sid.wav')
          ..createSync(recursive: true);
        out.writeAsBytesSync(encodeWav(audio, sampleRate));
        // ignore: avoid_print
        print('Reply audio written to ${out.absolute.path}');
        final heard = (await worker.transcribe(
          audio,
          sampleRate,
        )).toLowerCase();
        final hits = line
            .split(' ')
            .where((w) => w.length > 3)
            .where((w) => heard.contains(w.toLowerCase()))
            .length;
        // ignore: avoid_print
        print('kokoro ASR (sid $sid): "$heard" ($hits long words matched)');
        // Kokoro has no cold-start damage (one forward pass, no codec):
        // the FIRST long word ('quick') must be present — that is the
        // whole point of this engine.
        expect(hits, greaterThan(2));
        expect(heard, contains('quick'));
      }
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  // Pocket TTS leg: hot-swaps to the sherpa-onnx PocketTTS engine (Kyutai
  // ONNX export) and verifies the preset references clone through Whisper.
  // Skipped until the pack is staged: run tool/build_pocket_pack.sh (assets
  // land under POCKET_DIR, default /tmp/opencode/pocket-pack/pocket-tts).
  test('TTS voice swap: Kokoro -> Pocket TTS speaks preset voices', () async {
    final dir =
        Platform.environment['POCKET_DIR'] ??
        '/tmp/opencode/pocket-pack/pocket-tts';
    final refs = TtsVoice.pocketRefs;
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
    if (!await ready('Pocket TTS') ||
        !File('$dir/lm_main.onnx').existsSync() ||
        !File('$dir/voices/${refs.first}.wav').existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: Pocket TTS assets not staged under $dir');
      return;
    }

    final worker = await SpeechWorker.start(paths);
    try {
      final speakers = await worker.useTts(spec(0));
      expect(speakers, refs.length); // references drive the style slider

      const line =
          'Hello Tim. Pocket TTS speaking, generated entirely on this device.';
      final sw = Stopwatch()..start();
      final (audio, sampleRate) = await worker.synthesize(line);
      sw.stop();
      final seconds = audio.length / sampleRate;
      // ignore: avoid_print
      print(
        'pocket TTS: ${seconds.toStringAsFixed(1)}s generated in '
        '${sw.elapsedMilliseconds} ms '
        '(RTF ${(sw.elapsedMilliseconds / 1000 / seconds).toStringAsFixed(2)})',
      );
      expect(audio.length, greaterThan(sampleRate));
      expect(sampleRate, 24000); // Pocket's output rate

      File('build/roundtrip_pocket.wav')
        ..createSync(recursive: true)
        ..writeAsBytesSync(encodeWav(audio, sampleRate));

      final heard = (await worker.transcribe(audio, sampleRate)).toLowerCase();
      final hits = line
          .split(' ')
          .where((w) => w.length > 3)
          .where((w) => heard.contains(w.toLowerCase()))
          .length;
      // ignore: avoid_print
      print('pocket ASR: "$heard" ($hits long words matched)');
      // Body words must land (>= 3): the ONNX port's cold-start head can eat
      // the first syllable even after the lead-in repair (see pocketLeadIn),
      // and tiny.en drops the trailing words of a long take, so assert on the
      // middle of the sentence — that is what the engine guarantees.
      expect(hits, greaterThan(2));
      if (File('$dir/bos_before_voice.npy').existsSync()) {
        // v3 pack (BOS embedding staged next to the encoder): the patched
        // sherpa build feeds the learned BOS frame, the port cold-starts
        // like the PyTorch reference, and the ritual is off — the FIRST
        // word surviving intact is now the engine's guarantee.
        expect(heard, contains('hello'));
      }

      // Second preset sounds different but is equally intelligible.
      await worker.useTts(spec(5)); // bill_boerst: the most stable draw
      final (audio2, _) = await worker.synthesize(line);
      File('build/roundtrip_pocket_bill.wav')
        ..createSync(recursive: true)
        ..writeAsBytesSync(encodeWav(audio2, sampleRate));
      final heard2 = (await worker.transcribe(
        audio2,
        sampleRate,
      )).toLowerCase();
      final hits2 = line
          .split(' ')
          .where((w) => w.length > 3)
          .where((w) => heard2.contains(w.toLowerCase()))
          .length;
      // ignore: avoid_print
      print('pocket ASR (bill_boerst): "$heard2" ($hits2 long words matched)');
      expect(hits2, greaterThan(2));
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
