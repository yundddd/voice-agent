import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_unpack.dart';

export 'model_unpack.dart';

/// Packs every run needs, downloaded on first launch.
const modelPacks = [
  ModelPack(
    label: 'speech recognition (Whisper tiny.en)',
    url:
        'https://github.com/yundddd/voice-agent/releases/download/models-v1/asr-whisper-tiny.en.zip',
    dirName: 'asr-whisper-tiny.en',
    markerFile: 'tiny.en-decoder.int8.onnx',
  ),
];

/// The default TTS voice pack (also referenced by the 'lessac' voice entry).
const defaultTtsPack = ModelPack(
  label: 'voice synthesis (Piper lessac-medium)',
  url:
      'https://github.com/yundddd/voice-agent/releases/download/models-v1/tts-lessac-medium.zip',
  dirName: 'tts-lessac-medium',
  markerFile: 'espeak-ng-data/phondata',
);

const _vadAsset = 'assets/models/silero_vad.onnx';

/// Directory holding the unpacked model subdirectories (created on demand).
Future<String> modelsRootDir() async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(p.join(support.path, 'models'));
  await dir.create(recursive: true);
  return dir.path;
}

/// Downloads the always-required packs (ASR) and copies the bundled Silero
/// VAD model out of the APK. Returns the models directory path.
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

  for (final pack in modelPacks) {
    await ensurePack(modelsDir, pack, onProgress: onProgress);
  }
  return modelsDir;
}
