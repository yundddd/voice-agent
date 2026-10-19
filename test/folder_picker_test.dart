import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/bridge/client.dart';

/// The working-folder picker's client half, driven against a stub server
/// that speaks the bridge's /dirs and /dir contract (the server side of
/// the same contract is pinned by the wire test in
/// tool/bridge_queue_test.mjs — together they close the seam).
void main() {
  late HttpServer server;
  late BridgeClient client;
  final seen = <String>[]; // method+path+query, per request

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = BridgeClient('http://127.0.0.1:${server.port}', 'tok');
    server.listen((req) async {
      seen.add('${req.method} ${req.uri}');
      if (req.uri.path == '/dirs') {
        final inn = req.uri.queryParameters['in'];
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'ok': true,
              'dir': '/home/user/${inn ?? ''}',
              'in': inn,
              'parent': inn == null ? null : '',
              'dirs': [
                {'name': 'projects', 'path': 'projects'},
              ],
            }),
          );
      } else if (req.uri.path == '/dir') {
        final body = jsonDecode(await utf8.decodeStream(req))
            as Map<String, Object?>;
        if (body['path'] == '/home/user/good') {
          req.response.write('{"ok":true}');
        } else {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.write('not a folder inside the bridge\'s --dir-root');
        }
      }
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('dirs() rides the token and passes the browse path as in=', () async {
    final l = await client.dirs();
    expect(l, isNotNull);
    expect(l!['dir'], '/home/user/');
    expect(seen.single, contains('token=tok'));
    expect(seen.single, isNot(contains('in=')));
    await client.dirs(path: 'projects');
    expect(seen.last, contains('in=projects'));
  });

  test('setDir posts the path; 200 is success, 400 the honest reason',
      () async {
    expect(await client.setDir('/home/user/good'), isNull);
    final why = await client.setDir('/etc');
    expect(why, contains('not a folder'));
    expect(why, isNot(contains('HTTP'))); // the body beat the bare code
  });

  test('an unreachable bridge answers null dirs and a reason for setDir',
      () async {
    await server.close(force: true);
    expect(await client.dirs(), isNull);
    expect(await client.setDir('/home/user/good'), isNotNull);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    await server.close(); // keep tearDown's close a no-op
  });
}
