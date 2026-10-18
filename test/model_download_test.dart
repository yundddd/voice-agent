// Host-side tests for the backgrounding-robust downloader: a local
// origin that dies mid-body (the shape of a screen-off socket kill —
// simulated with a hard socket destroy, because Dart's own HttpServer
// validates contentLength on a polite close), stalls silently (the
// shape of a black-holed route — no FIN ever arrives), ignores ranges,
// or 404s. Against each, ensurePack must either CONTINUE from the
// partial file (Range resume, zero re-paid bytes) or fail loudly and
// once (a pack the origin simply doesn't have). The retry sleeps are
// injected, so every scenario runs in milliseconds.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/models/model_unpack.dart';

Uint8List fakeZip(int bodySize) {
  final data = Uint8List.fromList(
    List.generate(bodySize, (i) => (i * 31 + (i ~/ 7)) & 0xFF),
  );
  final a = Archive();
  a.addFile(ArchiveFile('model.bin', data.length, data));
  a.addFile(ArchiveFile('marker.onnx', 8, List.filled(8, 9)));
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

final pack = ModelPack(
  label: 'test pack',
  url: 'http://127.0.0.1:1/pack.zip', // rewritten per test
  dirName: 'test-pack',
  markerFile: 'marker.onnx',
);

/// Kills a response mid-body, honestly: headers (with the announced
/// contentLength) are flushed, the raw socket carries the bytes that
/// "made it", and destroy() severs mid-stream — no contentLength
/// validation, no FIN courtesy (Dart's own HttpServer refuses a short
/// body on a polite close, which is exactly the lie this test needs).
/// [afterMs] > 0 holds the half-open connection in silence first: the
/// black-holed route that never errors and never closes.
Future<void> sever(HttpResponse res, List<int> bytes, {int afterMs = 0}) async {
  final sock = await res.detachSocket();
  sock.add(bytes);
  await sock.flush();
  if (afterMs > 0) {
    await Future<void>.delayed(Duration(milliseconds: afterMs));
  }
  sock.destroy();
}

/// The byte offset a Range header asks to resume from (0 = no header).
int rangeStart(HttpRequest rq) {
  final r = rq.headers.value(HttpHeaders.rangeHeader);
  if (r == null) return 0;
  return int.parse(RegExp(r'bytes=(\d+)').firstMatch(r)!.group(1)!);
}

void main() {
  late Directory root;
  late HttpServer origin;
  late ModelPack urlPack;
  late List<Duration> waits;
  late List<int> seenRanges;
  late List<int> progressDone;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('dl');
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    urlPack = ModelPack(
      label: pack.label,
      url: 'http://127.0.0.1:${origin.port}/pack.zip',
      dirName: pack.dirName,
      markerFile: pack.markerFile,
    );
    waits = [];
    seenRanges = [];
    progressDone = [];
  });

  tearDown(() async {
    await origin.close(force: true);
    root.deleteSync(recursive: true);
  });

  Future<void> fetch(
    void Function(HttpRequest rq, int hit) handler, {
    int attempts = 3,
    Duration idle = const Duration(milliseconds: 300),
    ModelPack? p,
  }) {
    var hit = 0;
    origin.listen((rq) => handler(rq, ++hit));
    return ensurePack(
      root.path,
      p ?? urlPack,
      // Only download events count: the 'Unpacking' ping carries 0 and
      // belongs to the tail of the sequence, not its monotonicity.
      onProgress: (_, done, _) {
        if (done > 0) progressDone.add(done);
      },
      retryDelays: List.filled(attempts, Duration.zero),
      idleTimeout: idle,
      pause: (d) async => waits.add(d),
    );
  }

  void serveAll(HttpResponse res, List<int> bytes) {
    res.contentLength = bytes.length;
    res.add(bytes);
    res.close();
  }

  /// Serve a 206 slice from [start] (or a plain 200 when resuming from 0).
  void serveFrom(HttpRequest rq, List<int> all) {
    final start = rangeStart(rq);
    seenRanges.add(start);
    final res = rq.response;
    final rest = all.sublist(start);
    if (start > 0) res.statusCode = HttpStatus.partialContent;
    res.contentLength = rest.length;
    res.add(rest);
    res.close();
  }

  test('a mid-body death RESUMES: the next request ranges from the '
      'byte the wire stopped at, and the pack lands complete', () async {
    final all = fakeZip(40000);
    final half = all.length ~/ 2;
    await fetch((rq, hit) async {
      final res = rq.response;
      if (hit == 1) {
        // The +N screen-off shape: announce the full length, ship
        // half, kill the socket.
        seenRanges.add(0);
        res.contentLength = all.length;
        await sever(res, all.sublist(0, half));
        return;
      }
      serveFrom(rq, all);
    });

    expect(seenRanges.first, 0);
    expect(seenRanges[1], greaterThan(0), reason: 'attempt 2 resumed');
    expect(seenRanges[1], lessThanOrEqualTo(half));
    expect(waits, hasLength(1), reason: 'one backoff sleep between attempts');
    expect(
      File('${root.path}/test-pack/model.bin').lengthSync(),
      greaterThan(10000),
    );
    expect(await packInstalled(root.path, urlPack), isTrue);
    expect(
      File('${root.path}/test-pack.part').existsSync(),
      isFalse,
      reason: 'success retires the partial file',
    );
    // Progress never walked backwards through the resume (the counter
    // counts from the partial size, not from zero again).
    for (var i = 1; i < progressDone.length; i++) {
      expect(progressDone[i], greaterThanOrEqualTo(progressDone[i - 1]));
    }
  });

  test('a stalled route (no FIN, no bytes) trips the watchdog and '
      'resumes where the silence began', () async {
    final all = fakeZip(40000);
    final quarter = all.length ~/ 4;
    await fetch((rq, hit) async {
      final res = rq.response;
      if (hit == 1) {
        // Announce everything, ship a quarter, then NOTHING and no
        // close: the black-holed route. Only the watchdog can end
        // this attempt, so the sever delay outruns it.
        seenRanges.add(0);
        res.contentLength = all.length;
        // stays silent ~5 s after the first quarter (watchdog: 250 ms)
        await sever(res, all.sublist(0, quarter), afterMs: 5000);
        return;
      }
      serveFrom(rq, all);
    }, idle: const Duration(milliseconds: 250));
    expect(
      seenRanges[1],
      greaterThan(0),
      reason: 'the stall resumed — it did not restart from zero',
    );
    expect(await packInstalled(root.path, urlPack), isTrue);
    expect(progressDone.last, all.length);
  });

  test(
    'an origin that IGNORES the Range header re-fetches whole '
    '(a 200 resets the file — appending would duplicate every byte)',
    () async {
      final all = fakeZip(40000);
      final half = all.length ~/ 2;
      await fetch((rq, hit) async {
        final res = rq.response;
        if (hit == 1) {
          seenRanges.add(0);
          res.contentLength = all.length;
          await sever(res, all.sublist(0, half));
          return;
        }
        // The no-byte-serves origin: it ignores the Range and answers a
        // fresh 200 of the WHOLE body.
        seenRanges.add(rangeStart(rq));
        serveAll(res, all);
      });
      expect(seenRanges[1], greaterThan(0), reason: 'a Range WAS offered');
      expect(
        File('${root.path}/test-pack/model.bin').lengthSync(),
        greaterThan(10000),
        reason: 'the zip unpacked from clean full bytes, not a doubled file',
      );
      expect(await packInstalled(root.path, urlPack), isTrue);
    },
  );

  test('416 (the asset shrank under the resume) discards the partial '
      'and refetches fresh', () async {
    final all = fakeZip(40000);
    File(
      '${root.path}/test-pack.part',
    ).writeAsBytesSync(Uint8List(all.length + 99), mode: FileMode.append);
    await fetch((rq, hit) async {
      if (hit == 1) {
        seenRanges.add(rangeStart(rq));
        rq.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        rq.response.close();
        return;
      }
      seenRanges.add(rangeStart(rq));
      serveAll(rq.response, all);
    });
    expect(
      seenRanges.first,
      greaterThan(0),
      reason: 'it offered the stale Range',
    );
    expect(seenRanges[1], 0, reason: 'the stale partial was dropped');
    expect(await packInstalled(root.path, urlPack), isTrue);
  });

  test('a 404 is permanent: one attempt, no ladder, loud failure', () async {
    var threw = false;
    try {
      await fetch((rq, hit) async {
        seenRanges.add(0);
        rq.response.statusCode = HttpStatus.notFound;
        rq.response.close();
      }, attempts: 5);
    } on HttpException {
      threw = true;
    }
    expect(threw, isTrue);
    expect(seenRanges, hasLength(1), reason: 'no ladder spent on a 404');
    expect(waits, isEmpty);
  });

  test('a 503 is transient: the partial survives it, the resume '
      'finishes the pack', () async {
    final all = fakeZip(40000);
    await fetch((rq, hit) async {
      final res = rq.response;
      if (hit == 1) {
        seenRanges.add(0);
        res.contentLength = all.length;
        await sever(res, all.sublist(0, 100));
        return;
      }
      if (hit == 2) {
        res.statusCode = HttpStatus.serviceUnavailable;
        res.close();
        return;
      }
      serveFrom(rq, all);
    }, attempts: 5);
    expect(
      seenRanges[1],
      greaterThan(0),
      reason: 'the 503 neither lost the bytes nor spent more than one sleep',
    );
    expect(waits, hasLength(2));
    expect(await packInstalled(root.path, urlPack), isTrue);
  });

  test('an exhausted ladder surfaces the LAST failure, partial intact '
      'for the next app launch', () async {
    final all = fakeZip(40000);
    var threw = false;
    try {
      await fetch((rq, hit) async {
        final res = rq.response;
        res.contentLength = all.length; // always dies mid-first-chunk
        await sever(res, all.sublist(0, 100));
      }, attempts: 2);
    } on Object catch (e) {
      // The honest wire-death type: a severed connection surfaces as
      // HttpException('Connection closed while receiving data') (or a
      // SocketException / the watchdog's stall failure).
      threw = e is Exception;
    }
    expect(threw, isTrue);
    final part = File('${root.path}/test-pack.part');
    expect(
      part.existsSync(),
      isTrue,
      reason:
          'backgrounding ate the connection: the next foreground '
          'continues from these bytes, it does not re-pay them',
    );
    expect(part.lengthSync(), allOf(greaterThan(0), lessThan(200)));
    expect(waits, hasLength(2));
  });
}
