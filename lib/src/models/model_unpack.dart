import 'dart:async';
import 'dart:io';
import 'dart:isolate';
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
    // Marker bumped under the same dirName (e.g. the pocket pack's
    // int8 -> fp32 relayout) or a half-finished earlier attempt: the
    // previous contents are exactly what we are replacing, so start from
    // an empty directory. Otherwise obsolete files squat next to the new
    // ones and the user pays both layouts on disk — and after a marker
    // bump the entry's trash icon points at the NEW dir contents anyway,
    // so the leftovers are unreachable from the UI.
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    if (pack.fileName != null) {
      // Raw single file (no archive): move the download into place —
      // same filesystem, so no second copy through RAM or the UI thread.
      await dir.create(recursive: true);
      await tmp.rename(p.join(dir.path, pack.fileName!));
    } else {
      // Zip AND tar.bz2 both decode on a worker isolate, streaming from
      // the downloaded file. On the UI isolate a inflate pass is seconds
      // of frozen screen per large member (field report: first-launch
      // "Unpacking…" sat dead-faced through it), and the tar.bz2 branch
      // peaked at full-archive-in-RAM on top. The isolate fixes both:
      // peak is one member, and the label updates per file.
      await _unpackOnIsolate(tmp.path, pack, dir.path, onProgress: onProgress);
    }
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
///
/// Archives decode on a worker isolate ([_unpackOnIsolate]); a raw
/// [ModelPack.fileName] pack is one file write and stays here.
///
Future<void> unpackPackBytes(
  Uint8List bytes,
  ModelPack pack,
  Directory dir, {
  ModelProgress? onProgress,
}) async {
  if (pack.fileName != null) {
    // Raw single file (e.g. the vocoder): just write it into place.
    final out = File(p.join(dir.path, pack.fileName!));
    await out.create(recursive: true);
    await out.writeAsBytes(bytes);
    return;
  }
  final tmp = File('${dir.path}.tmp.bin');
  await tmp.create(recursive: true);
  await tmp.writeAsBytes(bytes);
  try {
    await _unpackOnIsolate(tmp.path, pack, dir.path, onProgress: onProgress);
  } finally {
    try {
      await tmp.delete();
    } catch (_) {}
  }
}

/// Like [unpackPackBytes] but streams the archive from [zipPath] instead of
/// a byte buffer: the 500 MB+ engine packs decode member-by-member on the
/// worker isolate, so peak RAM is one member (the ~420 MB decoder), not the
/// whole archive, and the UI isolate never touches inflate.
Future<void> unpackPackFromPath(
  String zipPath,
  ModelPack pack,
  Directory dir, {
  ModelProgress? onProgress,
}) => _unpackOnIsolate(zipPath, pack, dir.path, onProgress: onProgress);

Future<void> _unpackOnIsolate(
  String archivePath,
  ModelPack pack,
  String dirPath, {
  ModelProgress? onProgress,
}) async {
  final done = Completer<void>();
  final rp = ReceivePort();
  // If the worker dies without sending 'err' (an OOM kill mid-inflate is
  // the realistic one), the exit notice must still free the caller —
  // otherwise the status line hangs on "Unpacking…" forever.
  final exit = ReceivePort();
  exit.listen((m) {
    // Cross-port delivery order is undefined: a clean 'ok' can trail the
    // exit notice, so give the verdict message its moment before blaming
    // the death.
    Timer(const Duration(milliseconds: 100), () {
      if (!done.isCompleted) {
        done.completeError(
          StateError('unpack ${pack.label}: worker died ($m)'),
        );
      }
    });
  });
  rp.listen((msg) {
    if (msg is! List || msg.isEmpty) return;
    switch (msg.first) {
      case 'p':
        onProgress?.call(msg[1] as String, msg[2] as int, msg[3] as int);
      case 'ok':
        done.complete();
      case 'err':
        // The worker's own error object, un-wrapped: callers (and the
        // unpack tests) match on ArchiveException/FormatException/
        // StateError types, exactly as when decode ran inline.
        done.completeError(
          msg[1] as Object,
          msg[2] is StackTrace ? msg[2] as StackTrace : StackTrace.current,
        );
    }
  });
  await Isolate.spawn(
    _unpackWorker,
    [archivePath, pack, dirPath, rp.sendPort],
    // The worker turns its own failures into an 'err' message; a hard
    // crash (OOM kill) still must not leave the future hanging.
    errorsAreFatal: false,
  );
  try {
    await done.future;
  } finally {
    rp.close();
    exit.close();
  }
}

void _unpackWorker(List<Object?> args) {
  final archivePath = args[0] as String;
  final pack = args[1] as ModelPack;
  final dirPath = args[2] as String;
  final port = args[3] as SendPort;
  InputFileStream? input;
  try {
    final Archive archive;
    if (pack.url.endsWith('.tar.bz2')) {
      // bzip2 wants the whole stream; the isolate keeps the peak off the
      // UI either way, and the tar decodes lazily member-by-member.
      archive = TarDecoder().decodeBytes(
        BZip2Decoder().decodeBytes(File(archivePath).readAsBytesSync()),
      );
    } else {
      input = InputFileStream(archivePath);
      archive = ZipDecoder().decodeBuffer(input);
    }
    final root = commonTopDir(archive);
    Uint8List? marker;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      var name = entry.name;
      if (root != null && name.startsWith(root)) {
        name = name.substring(root.length);
      }
      if (name.isEmpty) continue;
      if (name == pack.markerFile) {
        marker = (entry.content as List<int>) as Uint8List;
        continue; // Written LAST: its existence alone means "fully unpacked".
      }
      final out = File(p.join(dirPath, name));
      out.createSync(recursive: true);
      out.writeAsBytesSync(entry.content as List<int>);
      port.send(['p', 'Unpacking ${pack.label} — $name', 0, 0]);
    }
    if (marker == null) {
      throw StateError(
        'model pack ${pack.label} unpacked without ${pack.markerFile}',
      );
    }
    final markerFile = File(p.join(dirPath, pack.markerFile));
    markerFile.createSync(recursive: true);
    markerFile.writeAsBytesSync(marker);
    port.send(['ok']);
  } catch (e, s) {
    port.send(['err', e, s]);
  } finally {
    input?.closeSync();
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
