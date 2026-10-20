import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/bridge/client.dart';

/// BridgeClient.downloadFile against a stub /file that honours Range —
/// the exact contract the bridge implements (tool/claude_bridge.mjs,
/// pinned server-side by the wire test): fresh 200, resumed 206, and a
/// 416 that says the partial is past the end so the fetch restarts
/// whole. The .part file is the resume ledger; a dead wire keeps it.
void main() {
  late HttpServer server;
  late BridgeClient client;
  late Directory dir;
  final body = List<int>.generate(1000, (i) => 65 + i % 26); // A..Z cycle
  final rangeLog = <String?>[];

  setUp(() async {
    rangeLog.clear();
    dir = Directory.systemTemp.createTempSync('dl');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = BridgeClient('http://127.0.0.1:${server.port}', 'tok');
    server.listen((req) {
      if (req.uri.path != '/file') {
        req.response.statusCode = 404;
        req.response.close();
        return;
      }
      final range = req.headers.value('range');
      rangeLog.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      }
      if (start >= body.length) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set('content-range', 'bytes */${body.length}');
        req.response.close();
        return;
      }
      final slice = body.sublist(start);
      req.response.statusCode = start > 0 ? 206 : 200;
      req.response.headers.contentType = ContentType(
        'application',
        'vnd.android.package-archive',
      );
      req.response.headers.set('accept-ranges', 'bytes');
      req.response.contentLength = slice.length;
      req.response.add(slice);
      req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  test('fresh download lands the whole file and reports progress', () async {
    final dest = '${dir.path}/payload.bin';
    final progress = <int>[];
    expect(
      await client.downloadFile(
        'payload.bin',
        dest,
        onProgress: (d, t) => progress.add(d),
      ),
      isTrue,
    );
    expect(File(dest).readAsBytesSync(), body);
    expect(progress.last, body.length);
    expect(rangeLog.single, isNull); // nothing on disk: no Range asked
    expect(
      await File('$dest.part').exists(),
      isFalse,
      reason: 'the .part is renamed, not copied — no litter',
    );
  });

  test('a .part from the dead wire resumes with a Range and appends', () async {
    final dest = '${dir.path}/payload.bin';
    File('$dest.part').writeAsBytesSync(body.sublist(0, 400));
    expect(await client.downloadFile('payload.bin', dest), isTrue);
    expect(
      File(dest).readAsBytesSync(),
      body,
      reason: 'head from disk + tail off the wire = the whole file',
    );
    expect(rangeLog.single, 'bytes=400-');
  });

  test('a partial past the end takes the 416 and restarts whole', () async {
    final dest = '${dir.path}/payload.bin';
    // The wire test proves the bridge answers 416 here; this server
    // answers 416 for start >= length — simulate a too-long partial by
    // first planting one and letting the client re-ask from its end.
    File('$dest.part').writeAsBytesSync(List.filled(1500, 0));
    expect(await client.downloadFile('payload.bin', dest), isTrue);
    expect(
      File(dest).readAsBytesSync(),
      body,
      reason: '416 -> throw the partial -> fresh 200 -> the real bytes',
    );
    expect(rangeLog, [
      'bytes=1500-',
      null,
    ], reason: "first ask resumed; the 416's second was whole");
  });

  test(
    'a vanished bridge fails but keeps the partial for the next tap',
    () async {
      await server.close(force: true);
      final dest = '${dir.path}/payload.bin';
      File('$dest.part').writeAsBytesSync(body.sublist(0, 10));
      expect(await client.downloadFile('payload.bin', dest), isFalse);
      expect(
        await File('$dest.part').exists(),
        isTrue,
        reason: '10 good bytes must not be thrown away',
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      await server.close();
    },
  );
}
