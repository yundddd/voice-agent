import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A model pack that is fetched once from a CDN-style URL and unpacked into
/// the app support directory. (The zips currently live on this project's
/// GitHub release; later they will come from the assistant's gateway.)
class ModelPack {
  final String label;
  final String url;
  final String dirName; // subdirectory it unpacks to
  final String markerFile; // file used to decide "already unpacked"
  const ModelPack({
    required this.label,
    required this.url,
    required this.dirName,
    required this.markerFile,
  });
}

const modelPacks = [
  ModelPack(
    label: 'speech recognition (Whisper tiny.en)',
    url:
        'https://github.com/yundddd/voice-agent/releases/download/models-v1/asr-whisper-tiny.en.zip',
    dirName: 'asr-whisper-tiny.en',
    markerFile: 'tiny.en-decoder.int8.onnx',
  ),
  ModelPack(
    label: 'voice synthesis (Piper lessac-medium)',
    url:
        'https://github.com/yundddd/voice-agent/releases/download/models-v1/tts-lessac-medium.zip',
    dirName: 'tts-lessac-medium',
    markerFile: 'espeak-ng-data/phondata',
  ),
];

/// Download progress callback: label, bytes done, total bytes (0 if unknown).
typedef ModelProgress = void Function(String, int, int);

const _vadAsset = 'assets/models/silero_vad.onnx';

/// Returns the directory that contains the unpacked model subdirectories.
Future<String> unpackModels({ModelProgress? onProgress}) async {
  final support = await getApplicationSupportDirectory();
  final modelsDir = Directory(p.join(support.path, 'models'));
  await modelsDir.create(recursive: true);

  // The Silero VAD model ships inside the APK (tiny) and is copied out.
  final vadFile = File(p.join(modelsDir.path, 'silero_vad.onnx'));
  final vadData = await rootBundle.load(_vadAsset);
  if (!await vadFile.exists() ||
      vadFile.lengthSync() != vadData.lengthInBytes) {
    await vadFile.create(recursive: true);
    await vadFile.writeAsBytes(
      vadData.buffer.asUint8List(vadData.offsetInBytes, vadData.lengthInBytes),
    );
  }

  for (final pack in modelPacks) {
    final dir = Directory(p.join(modelsDir.path, pack.dirName));
    if (await File(p.join(dir.path, pack.markerFile)).exists()) continue;
    await _fetchAndUnpack(pack, dir, onProgress);
  }
  return modelsDir.path;
}

Future<void> _fetchAndUnpack(
  ModelPack pack,
  Directory dir,
  ModelProgress? onProgress,
) async {
  final tmp = File('${dir.path}.zip.part');
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(pack.url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode} for ${pack.url}');
    }
    final total = res.contentLength;
    var done = 0;
    final sink = tmp.openWrite();
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(pack.label, done, total);
      }
    } finally {
      await sink.close();
    }

    onProgress?.call('Unpacking ${pack.label}', 0, 0);
    // The zips are < 130 MB, so reading them fully into memory is fine.
    final archive = ZipDecoder().decodeBytes(await tmp.readAsBytes());
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final out = File(p.join(dir.path, entry.name));
      await out.create(recursive: true);
      await out.writeAsBytes(entry.content as List<int>);
    }
    if (!await File(p.join(dir.path, pack.markerFile)).exists()) {
      throw StateError('model pack ${pack.label} unpacked without ${pack.markerFile}');
    }
  } finally {
    try {
      await tmp.delete();
    } catch (_) {}
    client.close(force: true);
  }
}
