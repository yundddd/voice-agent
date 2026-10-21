import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../speech/espeak_exec.dart';
import 'model_unpack.dart';

export 'model_unpack.dart';

const _vadAsset = 'assets/models/silero_vad.onnx';

/// Directory holding the unpacked model subdirectories (created on demand).
Future<String> modelsRootDir() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, 'models'));
  await dir.create(recursive: true);
  return dir.path;
}

/// Copies the bundled Silero VAD model out of the APK. The ASR pack is a
/// lazy [AsrModel] choice (see lib/speech/asr_models.dart) — the assistant
/// ensures the selected variant, like every voice pack. Returns the models
/// directory path.
Future<String> unpackModels({ModelProgress? onProgress}) async {
  final modelsDir = await modelsRootDir();

  // The Silero VAD model ships inside the APK (tiny) and is copied out.
  final vadFile = File(p.join(modelsDir, 'silero_vad.onnx'));
  final vadData = await rootBundle.load(_vadAsset);
  if (!await vadFile.exists() ||
      vadFile.lengthSync() != vadData.lengthInBytes) {
    await vadFile.create(recursive: true);
    await vadFile.writeAsBytes(
      vadData.buffer.asUint8List(vadData.offsetInBytes, vadData.lengthInBytes),
    );
  }

  // +238: the out-of-process espeak's pruned English data (936 KB of
  // phondata/lang/intonations, assets listed in espeak_exec.dart).
  // Copied out like silero — versioned by content: a re-shipped asset
  // tree changes sizes and re-copies on the next launch.
  for (final rel in espeakAssetFiles) {
    final dest = File(p.join(modelsDir, espeakDataDirName, rel));
    final data = await rootBundle.load('$espeakAssetPrefix/$rel');
    if (!await dest.exists() || dest.lengthSync() != data.lengthInBytes) {
      await dest.create(recursive: true);
      await dest.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
  }

  return modelsDir;
}
