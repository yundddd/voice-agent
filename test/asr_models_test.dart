import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/asr_models.dart';

void main() {
  group('whisper variant roster', () {
    test('tiny.en is the default, base.en the larger pick', () {
      expect(asrModels.map((m) => m.id), ['tiny.en', 'base.en']);
      expect(asrModelById('tiny.en')!.pack.dirName, 'asr-whisper-tiny.en');
      expect(asrModelById('base.en')!.pack.dirName, 'asr-whisper-base.en');
      // The packs are the int8 graphs, repacked under our own release —
      // the whole point of the picker is the download trade-off, so the
      // base pack must be addressable next to the tiny one it beats.
      expect(
        asrModelById('base.en')!.pack.url,
        'https://github.com/yundddd/voice-agent/releases/'
        'download/models-v1/asr-whisper-base.en.zip',
      );
      expect(asrModelById('base.en')!.pack.markerFile,
          'base.en-decoder.int8.onnx');
    });

    test('pathsIn wires the int8 graph and the shared Silero VAD', () {
      final paths = asrModelById('base.en')!.pathsIn('/models');
      expect(
        paths.whisperEncoder,
        '/models/asr-whisper-base.en/base.en-encoder.int8.onnx',
      );
      expect(
        paths.whisperDecoder,
        '/models/asr-whisper-base.en/base.en-decoder.int8.onnx',
      );
      expect(
        paths.whisperTokens,
        '/models/asr-whisper-base.en/base.en-tokens.txt',
      );
      expect(paths.vadModel, '/models/silero_vad.onnx');
      // The tiny variant keeps the exact layout the app shipped with
      // before the picker: an existing install never re-downloads.
      expect(asrModelById('tiny.en')!.pathsIn('/models').whisperDecoder,
          '/models/asr-whisper-tiny.en/tiny.en-decoder.int8.onnx');
    });

    test('installed is decided by the marker file', () async {
      final dir = Directory.systemTemp.createTempSync('models');
      addTearDown(() => dir.deleteSync(recursive: true));
      final base = asrModelById('base.en')!;
      expect(await base.installedIn(dir.path), isFalse);
      Directory('${dir.path}/asr-whisper-base.en').createSync();
      File('${dir.path}/asr-whisper-base.en/base.en-decoder.int8.onnx')
          .writeAsBytesSync([0]);
      expect(await base.installedIn(dir.path), isTrue);
    });

    test('prefs default to tiny and survive a round trip', () {
      expect(AsrPrefs.fromJson({}).modelId, 'tiny.en');
      // The lone pre-picker choice migrates.
      expect(AsrPrefs.fromJson({'model': 'tiny'}).modelId, 'tiny.en');
      final p = AsrPrefs.fromJson({'model': 'base.en'});
      expect(p.modelId, 'base.en');
      expect(p.toJson(), {'model': 'base.en'});
    });

    test('prefs persist and reload from the models dir', () async {
      final dir = Directory.systemTemp.createTempSync('models');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await loadAsrPrefs(dir.path), isNotNull); // missing file: defaults
      await saveAsrPrefs(dir.path, AsrPrefs(modelId: 'base.en'));
      expect((await loadAsrPrefs(dir.path)).modelId, 'base.en');
    });
  });
}
