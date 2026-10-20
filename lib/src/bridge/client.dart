/// The Claude Code implementation of [HarnessGateway]: a plain dart:io
/// HttpClient over the bridge in tool/claude_bridge.mjs (see
/// docs/claude-code-bridge.md). The bridge holds one long-lived
/// `claude -p --input-format stream-json` process and exposes it as SSE
/// (plus an event ring for the pull transport); the SSE grammar decoded
/// here is the tiny subset the bridge emits — one JSON line per `data:`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge_event.dart';
import 'gateway.dart';

class BridgeClient extends HarnessGateway {
  BridgeClient(this.baseUrl, this.token);

  final String baseUrl; // e.g. http://192.168.1.20:8732
  final String token;

  Uri _u(String path, [Map<String, String>? extra]) {
    final jp = journalPort == null ? null : journalPort!();
    return Uri.parse(
      baseUrl.endsWith('/')
          ? '${baseUrl.substring(0, baseUrl.length - 1)}$path'
          : '$baseUrl$path',
    ).replace(
      queryParameters: {
        'token': token,
        if (jp != null && jp > 0) 'logport': '$jp',
        ...?extra,
      },
    );
  }

  /// Every streamed call shares this shape: POST/GET, fail loudly on a
  /// non-200, decode SSE, and tap every byte for the wire watchdog.
  Stream<BridgeEvent> _sse(
    Future<HttpClientRequest> Function(HttpClient) open,
    void Function()? onActivity,
  ) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await open(client);
      final res = await req.close();
      if (res.statusCode != 200) {
        final body = (await res.transform(utf8.decoder).join()).trim();
        throw BridgeException(
          'bridge said HTTP ${res.statusCode}'
          '${body.isEmpty ? '' : ': $body'}',
        );
      }
      yield* bridgeEventsFromLines(
        _tapped(
          res.transform(utf8.decoder),
          onActivity,
        ).transform(const LineSplitter()),
      );
    } on BridgeException {
      rethrow;
    } on Object catch (e) {
      throw BridgeException('bridge unreachable: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// Byte-level activity tap (see HarnessGateway.talk's [onActivity]
  /// docs): forward every chunk, touching the callback as each crosses.
  static Stream<String> _tapped(
    Stream<String> raw,
    void Function()? onTouch,
  ) async* {
    await for (final s in raw) {
      if (onTouch != null) onTouch();
      yield s;
    }
  }

  @override
  Stream<BridgeEvent> talk(
    String text, {
    bool interrupt = true,
    bool cutTool = false,
    void Function()? onActivity,
  }) => _sse((client) async {
    final req = await client.postUrl(
      _u('/talk', {
        'interrupt': interrupt ? '1' : '0',
        if (cutTool && !interrupt) 'cuttool': '1',
      }),
    );
    req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
    req.add(utf8.encode(text));
    return req;
  }, onActivity);

  @override
  Stream<BridgeEvent> attach({void Function()? onActivity}) =>
      _sse((client) => client.getUrl(_u('/attach')), onActivity);

  @override
  Future<int> talkPoll(
    String text, {
    bool interrupt = true,
    bool cutTool = false,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(
        _u('/talk', {
          'interrupt': interrupt ? '1' : '0',
          if (cutTool && !interrupt) 'cuttool': '1',
          'poll': '1',
        }),
      );
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      req.add(utf8.encode(text));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw BridgeException('bridge said HTTP ${res.statusCode}');
      }
      // v2: the polled POST answers {ok:true,turn:N} — the receipt
      // that names this prompt's turn before a single frame rings.
      final j = BridgeEvent.tryJson(body);
      final t = j is Map ? j['turn'] : null;
      return t is num ? t.toInt() : 0;
    } on BridgeException {
      rethrow;
    } on Object catch (e) {
      throw BridgeException('bridge unreachable: $e');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<bool> heard(List<int> mids) async {
    if (mids.isEmpty) return true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(_u('/heard'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'mids': mids})));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode == 200;
    } on Object {
      return false; // unreachable: the ledger keeps the pending list
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Map<String, Object>?> poll(int since) async {
    try {
      final req = await HttpClient()
          .getUrl(_u('/poll', {'since': '$since'}))
          .then((r) => r.close())
          .timeout(const Duration(seconds: 6));
      final text = await req.transform(utf8.decoder).join();
      if (req.statusCode != 200) return null;
      final j = BridgeEvent.tryJson(text);
      if (j is! Map) return null;
      return j.cast<String, Object>();
    } on Object {
      return null;
    }
  }

  @override
  Future<void> stop() => _post('/stop');

  @override
  Future<void> reset() => _post('/new');

  @override
  Future<String?> health() async {
    final h = await _healthRaw();
    if (h.body == null) return h.why ?? 'unreachable';
    return h.body!['claudeUp'] == true ? null : 'claude is not up: ${h.body}';
  }

  @override
  Future<Map<String, Object>?> healthInfo() async => (await _healthRaw()).body;

  /// POSTs the app event journal envelope (src/journal/) — the PUSH
  /// transport for phones that cannot be dialed back (the Android
  /// tailscale client refuses inbound connections by default, and behind
  /// carrier NAT there is no route to dial at all). Outbound is always
  /// alive; it already carries every turn. The bridge confirms with a
  /// plain `ok`, and the journal's watermark advances only on that ack —
  /// delivery is at-least-once, seq-deduped bridge-side, convergent by
  /// construction. `logport=` rides the request too, so a phone that
  /// later enables inbound (tailscale toggle) gets its pull leg revived
  /// automatically.
  @override
  Future<bool> pushJournal(Map<String, Object> envelope) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(_u('/applog'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(envelope)));
      final res = await req.close();
      final body = (await res.transform(utf8.decoder).join()).trim();
      return res.statusCode == 200 && body == 'ok';
    } on Object {
      return false; // unreachable/refused: the journal keeps the backlog
    } finally {
      client.close(force: true);
    }
  }

  /// The bridge's folder listing (GET /dirs?in=rel) for the working-
  /// folder picker; null = unreachable, refused or pre-picker bridge.
  @override
  Future<Map<String, Object>?> dirs({String? path}) async {
    try {
      final res = await HttpClient()
          .getUrl(
            _u('/dirs', {if (path != null && path.isNotEmpty) 'in': path}),
          )
          .then((r) => r.close())
          .timeout(const Duration(seconds: 6));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final j = BridgeEvent.tryJson(text);
      return j is Map ? j.cast<String, Object>() : null;
    } on Object {
      return null;
    }
  }

  /// Move the working folder (POST /dir): an honest /new at the
  /// destination. Any non-2xx (or a body-less 400) comes back as the
  /// one-line reason the Bridge screen can show.
  @override
  Future<String?> setDir(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(_u('/dir'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'path': path})));
      final res = await req.close();
      final body = (await res.transform(utf8.decoder).join()).trim();
      if (res.statusCode == 200) return null;
      return body.isEmpty ? 'HTTP ${res.statusCode}' : body;
    } on Object catch (e) {
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  /// Switch the harness the bridge speaks (POST /harness {"to":…}).
  /// Any non-2xx comes back as the one-line reason the Bridge screen
  /// can show; success simply re-filters what /health says next.
  @override
  Future<String?> setHarness(String to) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(_u('/harness'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'to': to})));
      final res = await req.close();
      final body = (await res.transform(utf8.decoder).join()).trim();
      if (res.statusCode == 200) return null;
      return body.isEmpty ? 'HTTP ${res.statusCode}' : body;
    } on Object catch (e) {
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  /// The model picker's menu (GET /models): both harnesses answer the
  /// same shape; null = unreachable or a bridge without the endpoint.
  @override
  Future<Map<String, Object>?> models() async {
    try {
      final res = await HttpClient()
          .getUrl(_u('/models'))
          .then((r) => r.close())
          .timeout(const Duration(seconds: 6));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final j = BridgeEvent.tryJson(text);
      return j is Map ? j.cast<String, Object>() : null;
    } on Object {
      return null;
    }
  }

  /// Apply a model pick (POST /model). Any non-2xx comes back as the
  /// bridge's one-line reason (an off-menu id is refused at the
  /// bridge's own gate, before the harness ever sees it).
  @override
  Future<String?> setModel(String id) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(_u('/model'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'id': id})));
      final res = await req.close();
      final body = (await res.transform(utf8.decoder).join()).trim();
      if (res.statusCode == 200) return null;
      return body.isEmpty ? 'HTTP ${res.statusCode}' : body;
    } on Object catch (e) {
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  /// GET /file?path=… into [destPath], streaming to a .part and renaming
  /// on completion. A `$destPath.part` from an interrupted transfer
  /// resumes (Range: bytes=N-); a 416 (the file changed under us) starts
  /// whole. False = failed, and the partial stays for the next attempt.
  @override
  Future<bool> downloadFile(
    String path,
    String destPath, {
    void Function(int done, int total)? onProgress,
  }) async {
    final tmp = File('$destPath.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      int have = await tmp.exists() ? await tmp.length() : 0;
      Future<HttpClientResponse> open(int from) async {
        final req = await client.getUrl(_u('/file', {'path': path}));
        if (from > 0) req.headers.set('range', 'bytes=$from-');
        return req.close();
      }

      var res = await open(have);
      if (res.statusCode == 416) {
        have = 0;
        await tmp.delete();
        res = await open(0);
      }
      if (res.statusCode != 200 && res.statusCode != 206) {
        await res.drain<void>();
        return false;
      }
      final total = have + (res.contentLength > 0 ? res.contentLength : 0);
      final sink = tmp.openWrite(
        mode: have > 0 ? FileMode.append : FileMode.write,
      );
      int done = have;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          done += chunk.length;
          onProgress?.call(done, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      await tmp.rename(destPath);
      return true;
    } on Object {
      return false; // partial stays; the next tap resumes from the byte
    } finally {
      client.close(force: true);
    }
  }

  Future<({Map<String, Object>? body, String? why})> _healthRaw() async {
    try {
      final res = await HttpClient()
          .getUrl(_u('/health'))
          .then((r) => r.close())
          .timeout(const Duration(seconds: 6));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        return (body: null, why: 'HTTP ${res.statusCode}');
      }
      final j = BridgeEvent.tryJson(text);
      if (j is! Map) return (body: null, why: 'unexpected reply: $text');
      return (body: j.cast<String, Object>(), why: null);
    } on Object catch (e) {
      return (body: null, why: '$e');
    }
  }

  Future<void> _post(String path) async {
    try {
      final req = await HttpClient().postUrl(_u(path)).then((r) => r.close());
      await req.drain<void>();
    } on Object {
      /* best effort */
    }
  }
}
