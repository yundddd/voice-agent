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
        _tapped(res.transform(utf8.decoder), onActivity).transform(
          const LineSplitter(),
        ),
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
    void Function()? onActivity,
  }) => _sse(
    (client) async {
      final req = await client.postUrl(
        _u('/talk', {'interrupt': interrupt ? '1' : '0'}),
      );
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      req.add(utf8.encode(text));
      return req;
    },
    onActivity,
  );

  @override
  Stream<BridgeEvent> attach({void Function()? onActivity}) =>
      _sse((client) => client.getUrl(_u('/attach')), onActivity);

  @override
  Future<void> talkPoll(String text, {bool interrupt = true}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(
        _u('/talk', {'interrupt': interrupt ? '1' : '0', 'poll': '1'}),
      );
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      req.add(utf8.encode(text));
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode != 200) {
        throw BridgeException('bridge said HTTP ${res.statusCode}');
      }
    } on BridgeException {
      rethrow;
    } on Object catch (e) {
      throw BridgeException('bridge unreachable: $e');
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
