import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// A model pack that is fetched once from a CDN-style URL and unpacked into
/// the app support directory. (The zips currently live on this project's
/// GitHub release or on the k2-fsa sherpa-onnx releases; later they will
/// come from the assistant's gateway.)
///
/// Packs download **lazily** — `unpackModels` in model_packs.dart only
/// fetches what every run needs; voice packs (lib/tts_voices.dart) are
/// fetched via [ensurePack] the first time the user picks them and can be
/// deleted again with [deletePack].
class ModelPack {
  final String label;
  final String url;
  final String dirName; // subdirectory it unpacks to
  final String markerFile; // file used to decide "already unpacked"

  /// Set for packs that are a single raw file (no archive): the file is
  /// downloaded as-is to `dirName/fileName`; [markerFile] is that same name.
  final String? fileName;
  const ModelPack({
    required this.label,
    required this.url,
    required this.dirName,
    required this.markerFile,
    this.fileName,
  });

  String markerPath(String modelsDir) =>
      p.join(modelsDir, dirName, fileName ?? markerFile);
}

/// Download progress callback: label, bytes done, total bytes (0 if unknown).
typedef ModelProgress = void Function(String, int, int);

/// Download + unpack [pack] unless its marker file already exists.
Future<void> ensurePack(
  String modelsDir,
  ModelPack pack, {
  ModelProgress? onProgress,
}) async {
  if (await packInstalled(modelsDir, pack)) return;
  await _fetchAndUnpack(modelsDir, pack, onProgress);
}

Future<bool> packInstalled(String modelsDir, ModelPack pack) =>
    File(pack.markerPath(modelsDir)).exists();

/// Remove an unpacked pack (frees disk; it will simply re-download on demand).
Future<void> deletePack(String modelsDir, ModelPack pack) async {
  try {
    await Directory(p.join(modelsDir, pack.dirName)).delete(recursive: true);
  } catch (_) {}
  try {
    await File('$modelsDir/${pack.dirName}.part').delete();
  } catch (_) {}
}

Future<void> _fetchAndUnpack(
  String modelsDir,
  ModelPack pack,
  ModelProgress? onProgress,
) async {
  final dir = Directory(p.join(modelsDir, pack.dirName));
  final tmp = File('${dir.path}.part');
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
    await unpackPackBytes(await tmp.readAsBytes(), pack, dir);
  } finally {
    try {
      await tmp.delete();
    } catch (_) {}
    client.close(force: true);
  }
}

/// Unpack an already-downloaded pack (archive or single file) into [dir].
/// k2-fsa tarballs (and any zip) whose entries all sit under one top-level
/// directory get that directory stripped, so contents land directly in
/// [dir] — this is what the marker-file paths assume.
Future<void> unpackPackBytes(
  Uint8List bytes,
  ModelPack pack,
  Directory dir,
) async {
  if (pack.fileName != null) {
    // Raw single file (e.g. the vocoder): just write it into place.
    final out = File(p.join(dir.path, pack.fileName!));
    await out.create(recursive: true);
    await out.writeAsBytes(bytes);
  } else {
    // Packs are ≤ ~110 MB, so reading them fully into memory is fine.
    final archive = pack.url.endsWith('.tar.bz2')
        ? TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes))
        : ZipDecoder().decodeBytes(bytes);
    final root = commonTopDir(archive);
    for (final entry in archive) {
      if (!entry.isFile) continue;
      var name = entry.name;
      if (root != null && name.startsWith(root)) {
        name = name.substring(root.length);
      }
      if (name.isEmpty) continue;
      final out = File(p.join(dir.path, name));
      await out.create(recursive: true);
      await out.writeAsBytes(entry.content as List<int>);
    }
  }
  if (!await File(
    p.join(dir.path, pack.fileName ?? pack.markerFile),
  ).exists()) {
    throw StateError(
      'model pack ${pack.label} unpacked without ${pack.markerFile}',
    );
  }
}

/// If every entry sits under one common top-level directory, return "name/".
String? commonTopDir(Archive archive) {
  String? root;
  var files = 0;
  for (final entry in archive) {
    if (!entry.isFile) continue;
    files++;
    final cut = entry.name.indexOf('/');
    if (cut <= 0) return null;
    final dir = entry.name.substring(0, cut + 1);
    if (root == null) {
      root = dir;
    } else if (root != dir) {
      return null;
    }
  }
  return files > 0 ? root : null;
}
