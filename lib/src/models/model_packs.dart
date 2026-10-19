import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  return modelsDir;
}
