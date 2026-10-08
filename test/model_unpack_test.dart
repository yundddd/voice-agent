// Host-side tests for the lazy model-pack downloader/unpacker (the formats
// the phone hits for real: k2-fsa tar.bz2 voice packs, tar.bz2 clone pack,
// raw single-file vocoder). Run with:
//
//   LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//     flutter test test/model_unpack_test.dart
//
// Tarballs under /tmp/opencode are used when present (download them once
// from the k2-fsa releases to exercise the big-pack paths, or they skip):
//   tts-models/vits-piper-en_US-amy-medium-int8.tar.bz2  -> amy.tar.bz2
//   tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2 -> zv.tar.bz2
//   vocoder-models/vocos_24khz.onnx
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/model_unpack.dart';

const _tmp = '/tmp/opencode';

void main() {
  final amyPack = ModelPack(
    label: 'voice: Amy',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-amy-medium-int8.tar.bz2',
    dirName: 'tts-amy-medium-int8',
    markerFile: 'en_US-amy-medium.onnx',
  );
  final zipvoicePack = ModelPack(
    label: 'voice cloning engine',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2',
    dirName: 'tts-zipvoice',
    markerFile: 'encoder.int8.onnx',
  );
  final vocosPack = ModelPack(
    label: 'cloning vocoder',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx',
    dirName: 'tts-zipvoice',
    markerFile: 'vocos_24khz.onnx',
    fileName: 'vocos_24khz.onnx',
  );

  test('tar.bz2 voice pack unpacks with the top directory stripped', () async {
    final file = File('$_tmp/amy.tar.bz2');
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: no ${file.path} (download the k2-fsa voice tarball)');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('pack-amy');
    try {
      await unpackPackBytes(await file.readAsBytes(), amyPack, dir);
      // Model + tokens + nested espeak data, all WITHOUT the tarball's
      // `vits-piper-en_US-amy-medium-int8/` wrapper:
      expect(
        File('${dir.path}/en_US-amy-medium.onnx').lengthSync(),
        greaterThan(10000000),
      );
      expect(File('${dir.path}/tokens.txt').existsSync(), isTrue);
      expect(File('${dir.path}/espeak-ng-data/phondata').existsSync(), isTrue);
      expect(
        Directory('${dir.path}/vits-piper-en_US-amy-medium-int8').existsSync(),
        isFalse,
      );
      expect(await packInstalled(dir.parent.path, amyPack), isFalse); // root
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('zipvoice clone pack unpacks + vocos single-file pack', () async {
    final file = File('$_tmp/zv.tar.bz2'); // the ZipVoice tarball
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('SKIPPED: no ${file.path} (download the ZipVoice tarball)');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('pack-zv');
    try {
      await unpackPackBytes(await file.readAsBytes(), zipvoicePack, dir);
      for (final f in [
        'encoder.int8.onnx',
        'decoder.int8.onnx',
        'tokens.txt',
        'lexicon.txt',
        'espeak-ng-data/phondata',
      ]) {
        expect(File('${dir.path}/$f').existsSync(), isTrue, reason: f);
      }
      // Vocoder downloads as a raw file next to the engine:
      await unpackPackBytes(
        File('$_tmp/vocos_24khz.onnx').readAsBytesSync(),
        vocosPack,
        dir,
      );
      expect(
        File('${dir.path}/vocos_24khz.onnx').lengthSync(),
        greaterThan(10000000),
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('deletePack frees the space and re-download is expected', () async {
    final root = Directory.systemTemp.createTempSync('pack-del');
    try {
      final dir = Directory('${root.path}/${vocosPack.dirName}')..createSync();
      File('${dir.path}/vocos_24khz.onnx').writeAsBytesSync([1, 2, 3]);
      expect(await packInstalled(root.path, vocosPack), isTrue);
      await deletePack(root.path, vocosPack);
      expect(await packInstalled(root.path, vocosPack), isFalse);
      expect(dir.existsSync(), isFalse);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('unpacking something without the marker file throws', () async {
    // Garbage bytes (no bz2 signature): the decode must fail loudly — and
    // a valid archive missing its marker throws StateError inside
    // unpackPackBytes, so both flavors surface as Exceptions to the caller.
    expect(
      () => unpackPackBytes(
        Uint8List(1024),
        amyPack,
        Directory.systemTemp.createTempSync('pack-bad'),
      ),
      throwsA(isA<Exception>()),
    );
  });
}
