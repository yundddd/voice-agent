/// The app-side event journal — the phone half of the story behind
/// "background → foreground and nothing happened".
///
/// Every lifecycle moment worth troubleshooting (hide/resume callbacks and
/// what flags they saw, stream opens and HOW each one died, reattach probe
/// verdicts, watchdog hops, barge-in detaches, and every `_logDebug` line
/// from the turn loops) is appended to a sequence-numbered ring, mirrored
/// to `app_events.jsonl` so an Android process kill cannot erase the
/// evidence, and served over a tiny HTTP endpoint:
///
///     GET http://<phone>:8733/applog?token=<bridge token>&since=<seq>
///
/// The bridge (`tool/claude_bridge.mjs`) learns this socket's address from
/// the `logport=` parameter every app request rides (the peer IP is simply
/// the connection's source address — the same route the turn uses), then
/// polls the journal every few seconds and relays new lines to its own
/// stderr — so one `journalctl -u claude-voice-bridge` shows BOTH machines'
/// views of a misbehaving turn, the phone's with its own clock in the
/// payload. Poll failure is itself telemetry: while the phone app is
/// frozen or killed by the OS the bridge logs exactly that, and the burst
/// of journal timestamps when it returns brackets the freeze window.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The port the app's journal server binds unless occupied (it then walks
/// upward); the app announces the real port to the bridge on every request.
const kAppLogDefaultPort = 8733;

class _Ev {
  const _Ev(this.seq, this.ms, this.msg);
  final int seq;
  final int ms;
  final String msg;
  Map<String, Object> json() => {'seq': seq, 't': ms, 'msg': msg};
}

class AppEventJournal {
  AppEventJournal({required this.dir, this.ringCapacity = 240});

  /// In-memory (and on-disk) newest-N cap. 240 entries ≈ a heavy turn's
  /// worth of events plus the lifecycle bookends around it — enough to
  /// reconstruct the story, small enough that the served JSON is a few KB.
  final String dir;
  int ringCapacity;

  final List<_Ev> _ring = [];
  int _seq = 0;
  int _writesSinceRewrite = 0;
  HttpServer? _srv;
  String Function() _tokenProvider = () => '';
  Map<String, Object> Function() _flagsProvider = () => const {};
  static const _file = 'app_events.jsonl';

  int get seq => _seq;
  int get servedPort => _srv?.port ?? kAppLogDefaultPort;
  File get _path => File(p.join(dir, _file));

  /// Re-seed the ring from the on-disk mirror (the app died last time —
  /// bring the evidence forward) and restore the sequence counter so a
  /// bridge watermark learned before the death still filters correctly.
  Future<void> load() async {
    try {
      final lines = await _path.readAsLines();
      for (final l in lines) {
        if (l.length < 12) continue;
        try {
          final j = jsonDecode(l) as Map<String, Object?>;
          final s = j['seq'];
          final t = j['t'];
          _ring.add(_Ev(
            s is num ? s.toInt() : 0,
            t is num ? t.toInt() : 0,
            '${j['msg'] ?? ''}',
          ));
          if (s is num && s.toInt() > _seq) _seq = s.toInt();
        } on FormatException {
          continue; // a half-written last line from the kill moment
        }
      }
      while (_ring.length > ringCapacity) {
        _ring.removeAt(0);
      }
    } catch (_) {
      // First run (or unreadable): a fresh journal is fine; load() never
      // fails the app the way a missing chat log doesn't.
    }
  }

  /// Append one event. Fire-and-forget safe: disk trouble must never break
  /// a conversation (same rule as the chat log).
  Future<void> log(String msg) async {
    final ev = _Ev(++_seq, DateTime.now().millisecondsSinceEpoch, msg);
    _ring.add(ev);
    while (_ring.length > ringCapacity) {
      _ring.removeAt(0);
    }
    try {
      if (_writesSinceRewrite >= 64) {
        // Mirror the whole ring, then truncate the append log — bounded
        // file size, and a crash between rewrites loses at most the last
        // 64 events from the DISK copy (the ring still serves them live).
        _writesSinceRewrite = 0;
        await _path.writeAsString(
          '${_ring.map((e) => jsonEncode(e.json())).join('\n')}\n',
        );
      } else {
        _writesSinceRewrite++;
        await _path.writeAsString(
          '${jsonEncode(ev.json())}\n',
          mode: FileMode.append,
        );
      }
    } catch (_) {}
  }

  /// Entries with seq > [since], oldest first.
  List<Map<String, Object>> eventsAfter(int since) => [
        for (final e in _ring)
          if (e.seq > since) {'seq': e.seq, 't': e.ms, 'msg': e.msg},
      ];

  Map<String, Object> envelope(int since, Map<String, Object> flags) => {
        'ok': true,
        'seq': _seq,
        'floor': _ring.isEmpty ? _seq : _ring.first.seq,
        'events': eventsAfter(since),
        'flags': flags,
      };

  /// Start the HTTP endpoint. Tries IPv6 dual-stack first (tailscale routes
  /// either family), falls back to IPv4, then loopback (tests). Walks the
  /// port upward when occupied. Returns the port actually bound; a failed
  /// bind is logged-but-survivable (the journal still works in-app).
  Future<int> serve({
    required int preferredPort,
    required String Function() tokenProvider,
    required Map<String, Object> Function() flagsProvider,
  }) async {
    _tokenProvider = tokenProvider;
    _flagsProvider = flagsProvider;
    for (final host in [InternetAddress.anyIPv6, InternetAddress.anyIPv4]) {
      for (var port = preferredPort; port < preferredPort + 8; port++) {
        try {
          final srv = await HttpServer.bind(host, port, v6Only: false);
          _srv = srv;
          unawaited(_serveLoop(srv));
          return srv.port; // may differ from `port` (0 = ephemeral bind)
        } on SocketException {
          continue; // permission or busy port: next address/port
        } on Object {
          continue;
        }
      }
    }
    return kAppLogDefaultPort; // not served; caller may retry later
  }

  Future<void> _serveLoop(HttpServer srv) async {
    await for (final req in srv) {
      try {
        _handle(req);
      } on Object {
        // A half-disconnected curl must not take the server down.
      }
    }
  }

  void _handle(HttpRequest req) {
    final tok = req.uri.queryParameters['token'] ?? '';
    final want = _tokenProvider();
    if (want.isNotEmpty && tok != want) {
      req.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.contentType = ContentType.json
        ..write('{"ok":false,"error":"bad token"}');
      unawaited(req.response.close());
      return;
    }
    if (req.method != 'GET' ||
        (req.uri.path != '/applog' && req.uri.path != '/')) {
      req.response.statusCode = HttpStatus.notFound;
      unawaited(req.response.close());
      return;
    }
    final since = int.tryParse(req.uri.queryParameters['since'] ?? '0') ?? 0;
    final body = req.uri.path == '/'
        ? 'voice-agent app journal — GET /applog?token=…&since=<seq>'
        : jsonEncode(envelope(since, _flagsProvider()));
    req.response
      ..headers.contentType = req.uri.path == '/'
          ? ContentType.text
          : ContentType.json
      ..write(body);
    unawaited(req.response.close());
  }

  Future<void> stop() async {
    await _srv?.close(force: true);
    _srv = null;
  }
}
