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

/// The retry ladder for a phone-sized network: backgrounding KILLS long
/// downloads (Doze cuts the socket on screen-off, Wi-Fi handoff and
/// tailnet re-key black-hole it mid-body, and Android may freeze or
/// kill the whole process), and a 334 MB pack must not restart from
/// zero every time the screen blinks. Every transfer failure keeps
/// `dirName.part` where it is and comes back at the byte the wire
/// stopped at (HTTP Range) — the ladder only decides how long to wait
/// before the next continue, not what to re-fetch. ~4 minutes of
/// attempts covers the deep-sleep cases; the app's own resume hook
/// (§VoiceAssistant) re-arms a fresh ladder after longer naps.
const kDownloadRetries = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(seconds: 60),
];

/// The stalled-body watchdog: a route that dies quietly (the carrier's
/// NAT forgets the flow, the tailnet drops it without a FIN) leaves a
/// listening socket that delivers NOTHING and never errors — the
/// download would hang at its last percentage forever. No body bytes
/// for this long and the attempt is declared dead: the partial file
/// stays on disk and the retry ladder continues it. Longer than any
/// legitimate silence a CDN produces mid-stream, shorter than a user's
/// patience.
const kDownloadIdle = Duration(seconds: 30);

/// Download + unpack [pack], resuming an interrupted transfer across
/// retries. Only a corrupted or vanished pack starts the bytes over;
/// every wire death continues from the partial file.
///
/// [retryDelays] and [pause] are the test seam: the ladder and its
/// sleeps are injectable so the resume choreography pins in
/// milliseconds on a local server.
Future<void> ensurePack(
  String modelsDir,
  ModelPack pack, {
  ModelProgress? onProgress,
  List<Duration> retryDelays = kDownloadRetries,
  Duration idleTimeout = kDownloadIdle,
  Future<void> Function(Duration) pause = Future.delayed,
}) async {
  if (await packInstalled(modelsDir, pack)) return;
  final delays = List.of(retryDelays);
  while (true) {
    try {
      await _fetchAndUnpack(modelsDir, pack, onProgress, idleTimeout);
      return;
    } on _PermanentPackFailure catch (e) {
      // 404 / marker-less garbage: another attempt reads the same
      // nothing. Loud is the only useful answer.
      throw HttpException(e.message);
    } catch (_) {
      if (delays.isEmpty) rethrow;
      await pause(delays.removeAt(0));
    }
  }
}

/// A failure no retry can fix (gone from the origin, or corrupt past
/// the point of re-reading the same bytes).
class _PermanentPackFailure implements Exception {
  const _PermanentPackFailure(this.message);
  final String message;
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
  Duration idleTimeout,
) async {
  final dir = Directory(p.join(modelsDir, pack.dirName));
  final tmp = File('${dir.path}.part');
  final client = HttpClient();
  // The partial file's fate by the time this function exits: TRUE
  // through every wire death (those bytes are valid, they are just
  // not the whole story yet); false only after success, after
  // corruption, or after a 4xx that says the origin has nothing to
  // resume into.
  var keepPartial = true;
  try {
    var have = await tmp.exists() ? await tmp.length() : 0;
    final req = await client.getUrl(Uri.parse(pack.url));
    if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
    // The header phase gets the same watchdog as the body: a connect
    // into a black hole must stall the ladder, not stop it.
    final res = await req.close().timeout(idleTimeout);
    if (res.statusCode == 416) {
      // The origin is smaller than what we have: the asset changed
      // under the resume (or the partial file is stale garbage).
      // Discard and refetch on the next attempt.
      keepPartial = false;
      throw const SocketException('range past end of pack — restarting fetch');
    }
    if (res.statusCode == 200 && have > 0) {
      // Range ignored (an origin without byte serves): the full body
      // arrives, so appending would duplicate every byte already on
      // disk. Start the file over — the next death resumes again.
      have = 0;
    }
    if (res.statusCode != 200 && res.statusCode != 206) {
      // Server-busy family: transient — come back (with the partial)
      // and ask again. Anything else (404, 403, 410) is the origin
      // saying this pack is not there: no ladder helps.
      final transient =
          res.statusCode >= 500 ||
          res.statusCode == 408 ||
          res.statusCode == 429;
      keepPartial = transient;
      if (!transient) {
        throw _PermanentPackFailure('HTTP ${res.statusCode} for ${pack.url}');
      }
      throw HttpException('HTTP ${res.statusCode} for ${pack.url}');
    }
    final total = res.contentLength > 0 ? have + res.contentLength : 0;
    var done = have;
    final sink = tmp.openWrite(
      mode: have > 0 ? FileMode.append : FileMode.write,
    );
    try {
      await _watchedCopy(res, sink, idleTimeout, (n) {
        done += n;
        onProgress?.call(pack.label, done, total);
      });
    } finally {
      await sink.close();
    }
    if (res.contentLength > 0 &&
        await tmp.length() != have + res.contentLength) {
      // EOF early without an error frame (a proxy truncating the
      // stream): the lie is only that we believed it was done. Keep
      // what arrived, resume the rest.
      throw const SocketException('body shorter than content-length');
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
      try {
        await _unpackOnIsolate(
          tmp.path,
          pack,
          dir.path,
          onProgress: onProgress,
        );
      } on _PermanentPackFailure {
        keepPartial = false; // corrupt bytes: re-reading them won't help
        rethrow;
      } on FormatException {
        keepPartial = false;
        rethrow;
      }
      // An OOM'd isolate (StateError: worker died) keeps the bytes:
      // they are complete and good, the next attempt just needs the
      // memory more than the download.
    }
    keepPartial = false; // unpacked: the archive has served its purpose
  } finally {
    if (!keepPartial) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    client.close(force: true);
  }
}

/// Pipes [body] into [sink], dying loudly when the stream goes quiet.
/// A cancelled subscription is how a mid-body route death LOOKS from
/// here when the network never sent FIN: nothing errors, nothing
/// arrives — so the watchdog cancels it and throws the failure the
/// retry ladder turns into a resume.
Future<void> _watchedCopy(
  Stream<List<int>> body,
  StreamSink<List<int>> sink,
  Duration idleTimeout,
  void Function(int chunkBytes) onBytes,
) {
  final done = Completer<void>();
  Timer? idle;
  StreamSubscription<List<int>>? sub;
  void arm() {
    idle?.cancel();
    idle = Timer(idleTimeout, () {
      unawaited(sub?.cancel());
      if (!done.isCompleted) {
        done.completeError(
          SocketException(
            'download stalled — no bytes for ${idleTimeout.inSeconds}s',
          ),
        );
      }
    });
  }

  sub = body.listen(
    (chunk) {
      arm();
      sink.add(chunk);
      onBytes(chunk.length);
    },
    onError: (Object e, StackTrace s) {
      if (!done.isCompleted) done.completeError(e, s);
    },
    onDone: () {
      idle?.cancel();
      if (!done.isCompleted) done.complete();
    },
  );
  arm();
  return done.future.whenComplete(() {
    idle?.cancel();
    unawaited(sub?.cancel());
  });
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
        // StateError types, exactly as when decode ran inline. One
        // translation: a valid archive MISSING its marker is a broken
        // asset, not a bad wire — the downloader must not spend the
        // whole retry ladder re-fetching the same incomplete zip.
        final e = msg[1] as Object;
        if (e is StateError && e.message.contains('unpacked without')) {
          done.completeError(
            _PermanentPackFailure('${pack.label}: ${e.message}'),
            msg[2] is StackTrace ? msg[2] as StackTrace : StackTrace.current,
          );
        } else {
          done.completeError(
            e,
            msg[2] is StackTrace ? msg[2] as StackTrace : StackTrace.current,
          );
        }
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
