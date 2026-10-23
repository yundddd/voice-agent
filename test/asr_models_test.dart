import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voice_agent/src/speech/asr_models.dart';

void main() {
  group('whisper variant roster', () {
    test('tiny.en is the default and the roster is in display order', () {
      expect(asrModels.map((m) => m.id), [
        'tiny.en',
        'base.en',
        'moonshine-tiny.en',
        'moonshine-base.en',
        'qwen3-0.6b',
      ]);
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
      expect(
        asrModelById('base.en')!.pack.markerFile,
        'base.en-decoder.int8.onnx',
      );
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
      expect(paths.tokens, '/models/asr-whisper-base.en/base.en-tokens.txt');
      expect(paths.vadModel, '/models/silero_vad.onnx');
      // The family rides along as sherpa's own model_type, and the default
      // is the one every install already has on disk.
      expect(paths.modelType, 'whisper');
      // The tiny variant keeps the exact layout the app shipped with
      // before the picker: an existing install never re-downloads.
      expect(
        asrModelById('tiny.en')!.pathsIn('/models').whisperDecoder,
        '/models/asr-whisper-tiny.en/tiny.en-decoder.int8.onnx',
      );
    });

    test('installed is decided by the marker file', () async {
      final dir = Directory.systemTemp.createTempSync('models');
      addTearDown(() => dir.deleteSync(recursive: true));
      final base = asrModelById('base.en')!;
      expect(await base.installedIn(dir.path), isFalse);
      Directory('${dir.path}/asr-whisper-base.en').createSync();
      File(
        '${dir.path}/asr-whisper-base.en/base.en-decoder.int8.onnx',
      ).writeAsBytesSync([0]);
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

  group('moonshine variants', () {
    test('the graphs are k2-fsa\'s own dated packages, not a re-host', () {
      for (final (id, pkg) in [
        ('moonshine-tiny.en', 'sherpa-onnx-moonshine-tiny-en-quantized'),
        ('moonshine-base.en', 'sherpa-onnx-moonshine-base-en-quantized'),
      ]) {
        final m = asrModelById(id)!;
        expect(
          m.pack.url,
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
          'asr-models/$pkg-2026-02-27.tar.bz2',
        );
        expect(m.pack.dirName, 'asr-$id');
        expect(m.pack.markerFile, 'decoder_model_merged.ort');
      }
    });

    test('pathsIn wires the .ort pair, the pack tokens and the shared VAD', () {
      final paths = asrModelById('moonshine-tiny.en')!.pathsIn('/models');
      expect(paths.modelType, 'moonshine');
      expect(
        paths.moonshineEncoder,
        '/models/asr-moonshine-tiny.en/encoder_model.ort',
      );
      expect(
        paths.moonshineMergedDecoder,
        '/models/asr-moonshine-tiny.en/decoder_model_merged.ort',
      );
      // Moonshine's units file has no variant prefix — the pack directory is
      // the variant — so the worker's single `tokens` field carries it.
      expect(paths.tokens, '/models/asr-moonshine-tiny.en/tokens.txt');
      expect(paths.vadModel, '/models/silero_vad.onnx');
      // No Whisper path is set: a wrong-family config shows up as an empty
      // file name rather than a half-loaded model.
      expect(paths.whisperEncoder, '');
      expect(paths.whisperDecoder, '');
    });

    test(
      'installed is decided by the merged decoder, not the encoder',
      () async {
        final dir = Directory.systemTemp.createTempSync('models');
        addTearDown(() => dir.deleteSync(recursive: true));
        final ms = asrModelById('moonshine-base.en')!;
        expect(await ms.installedIn(dir.path), isFalse);
        Directory('${dir.path}/asr-moonshine-base.en').createSync();
        File(
          '${dir.path}/asr-moonshine-base.en/encoder_model.ort',
        ).writeAsBytesSync([0]);
        // A half-unpacked pack (the wire died after the encoder) still reads
        // as missing — the marker is the big file that lands last.
        expect(await ms.installedIn(dir.path), isFalse);
        File(
          '${dir.path}/asr-moonshine-base.en/decoder_model_merged.ort',
        ).writeAsBytesSync([0]);
        expect(await ms.installedIn(dir.path), isTrue);
      },
    );

    test('a Moonshine choice persists and never becomes the default', () {
      expect(
        AsrPrefs.fromJson({'model': 'moonshine-tiny.en'}).modelId,
        'moonshine-tiny.en',
      );
      // Existing installs keep Whisper tiny: the new variants are opt-in.
      expect(AsrPrefs.fromJson({}).modelId, 'tiny.en');
    });
  });

  group('qwen3 variant', () {
    test('pathsIn wires the frontend, both graphs and the tokenizer dir', () {
      final paths = asrModelById('qwen3-0.6b')!.pathsIn('/models');
      expect(paths.modelType, 'qwen3-asr');
      expect(
        paths.qwen3ConvFrontend,
        '/models/asr-qwen3-0.6b/conv_frontend.onnx',
      );
      expect(paths.qwen3Encoder, '/models/asr-qwen3-0.6b/encoder.int8.onnx');
      expect(paths.qwen3Decoder, '/models/asr-qwen3-0.6b/decoder.int8.onnx');
      // A directory: sherpa reads vocab/merges/config out of it, so this
      // family is the one that has NO units file.
      expect(paths.qwen3Tokenizer, '/models/asr-qwen3-0.6b/tokenizer');
      expect(paths.tokens, '');
      expect(paths.vadModel, '/models/silero_vad.onnx');
    });

    test('it is re-hosted on our release, marked by the biggest graph', () {
      final m = asrModelById('qwen3-0.6b')!;
      expect(
        m.pack.url,
        'https://github.com/yundddd/voice-agent/releases/'
        'download/models-v1/asr-qwen3-0.6b.zip',
      );
      expect(m.pack.markerFile, 'decoder.int8.onnx');
    });

    test('it decodes whole: only the windowed families get clip chunking', () {
      // Cutting the clip is what saves Whisper's 30 s window, and what costs
      // Qwen3 its long context — so the flag is per family, not global.
      expect(asrModelById('tiny.en')!.pathsIn('/m').chunksLongClips, isTrue);
      expect(
        asrModelById('moonshine-tiny.en')!.pathsIn('/m').chunksLongClips,
        isTrue,
      );
      expect(
        asrModelById('qwen3-0.6b')!.pathsIn('/m').chunksLongClips,
        isFalse,
      );
    });

    test('the staged pack holds exactly the files pathsIn names', () {
      final zip = File('build/asr-qwen3-0.6b.zip');
      // Like the model dirs themselves, the pack is staged by hand; an
      // unstaged zip skips the leg rather than failing a clean checkout.
      if (!zip.existsSync()) return;
      final names = ZipDecoder()
          .decodeBuffer(InputFileStream(zip.path))
          .where((e) => e.isFile)
          .map((e) => e.name)
          .toSet();
      final m = asrModelById('qwen3-0.6b')!;
      // The pack must be FLAT: the unpacker strips one shared top-level
      // directory when every member has one, so a zip that carries its own
      // dir name would unpack one level too deep for [AsrModel.pathsIn].
      expect(names.any((n) => n.startsWith('${m.pack.dirName}/')), isFalse);
      final want = m.pathsIn('root');
      final packDir = p.join('root', m.pack.dirName);
      for (final f in [
        want.qwen3ConvFrontend,
        want.qwen3Encoder,
        want.qwen3Decoder,
      ]) {
        expect(names, contains(p.relative(f, from: packDir)), reason: f);
      }
      for (final t in ['vocab.json', 'merges.txt', 'tokenizer_config.json']) {
        expect(names, contains('tokenizer/$t'));
      }
    });
  });
}
