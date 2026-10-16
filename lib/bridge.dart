/// Voice-agent → Claude Code bridge client (see docs/claude-code-bridge.md
/// and tool/claude_bridge.mjs). The bridge holds one long-lived
/// `claude -p --input-format stream-json` process and exposes it as SSE:
/// we POST an utterance, it streams back speakable events. Plain dart:io
/// HttpClient — no new dependency, and the SSE grammar here is the tiny
/// subset the bridge emits (one JSON line per `data:`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One parsed SSE frame from /talk.
class BridgeEvent {
  const BridgeEvent._(
    this.kind, {
    this.text = '',
    this.toolName = '',
    this.detail = '',
    this.isError = false,
  });

  /// 'say' | 'tool' | 'done' | 'error'.
  final String kind;
  final String text;
  final String toolName;
  final String detail;
  final bool isError;

  /// A complete assistant message — feed straight into the TTS path.
  bool get isSay => kind == 'say';
  bool get isDone => kind == 'done';

  static BridgeEvent parse(String event, String dataJson) {
    final decoded = tryJson(dataJson);
    if (decoded is! Map) {
      // Non-JSON data line: plain text is only meaningful as a say frame
      // (a hand-rolled bridge variant); anything else is an error line.
      return event == 'say'
          ? BridgeEvent._('say', text: dataJson)
          : BridgeEvent._('error', text: dataJson, isError: true);
    }
    final data = decoded.cast<String, Object>();
    switch (event) {
      case 'say':
        return BridgeEvent._('say', text: '${data['text'] ?? ''}');
      case 'tool':
        return BridgeEvent._(
          'tool',
          toolName: '${data['name'] ?? ''}',
          detail: '${data['detail'] ?? ''}',
        );
      case 'done':
        return BridgeEvent._('done', isError: data['isError'] == true);
      default:
        return BridgeEvent._(
          'error',
          text: '${data['error'] ?? data['message'] ?? dataJson}',
          isError: true,
        );
    }
  }

  static Object? tryJson(String s) {
    try {
      return jsonDecode(s);
    } on FormatException {
      return null;
    }
  }
}

/// Splits SSE protocol lines into parsed events — a pure state machine,
/// unit-testable without any socket. Ignores comments, handles multi-line
/// data (joined with newlines, per spec), and tolerates the stream ending
/// without a final blank line (last frame still yielded).
Stream<BridgeEvent> bridgeEventsFromLines(Stream<String> rawLines) async* {
  String? event;
  final data = StringBuffer();
  var haveData = false;
  await for (final line in rawLines.map(
    (l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l,
  )) {
    if (line.isEmpty) {
      if (haveData && event != null) {
        yield BridgeEvent.parse(event, data.toString());
      }
      event = null;
      data.clear();
      haveData = false;
      continue;
    }
    if (line.startsWith(':')) continue; // SSE comment / keep-alive
    if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (haveData) data.write('\n');
      data.write(line.substring(5).trimLeft());
      haveData = true;
    }
  }
  // Stream ended mid-frame (no trailing blank line): still deliver it.
  if (haveData && event != null) {
    yield BridgeEvent.parse(event, data.toString());
  }
}

class BridgeClient {
  BridgeClient(this.baseUrl, this.token);

  final String baseUrl; // e.g. http://192.168.1.20:8732
  final String token;

  Uri _u(String path) => Uri.parse(
    baseUrl.endsWith('/')
        ? '${baseUrl.substring(0, baseUrl.length - 1)}$path'
        : '$baseUrl$path',
  ).replace(queryParameters: {'token': token});

  /// Sends an utterance; the stream yields say/tool events as the harness
  /// works and a final done (or error) event, then closes. The HTTP
  /// request *is* the turn: cancelling the subscription closes the
  /// connection and the bridge's response-close hook cleans up.
  Stream<BridgeEvent> talk(String text) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(_u('/talk'));
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      req.add(utf8.encode(text));
      final res = await req.close();
      if (res.statusCode != 200) {
        final body = (await res.transform(utf8.decoder).join()).trim();
        throw BridgeException(
          'bridge said HTTP ${res.statusCode}'
          '${body.isEmpty ? '' : ': $body'}',
        );
      }
      yield* bridgeEventsFromLines(
        res.transform(utf8.decoder).transform(const LineSplitter()),
      );
    } on BridgeException {
      rethrow;
    } on Object catch (e) {
      throw BridgeException('bridge unreachable: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// Barge-in: asks the bridge to end the in-flight turn (context
  /// survives — the next talk continues the same conversation).
  Future<void> stop() => _post('/stop');

  /// Forget the conversation (fresh session on the next utterance).
  Future<void> reset() => _post('/new');

  /// GET /health → null when reachable and claude is up, else the reason.
  Future<String?> health() async {
    try {
      final req = await HttpClient()
          .getUrl(_u('/health'))
          .then((r) => r.close())
          .timeout(const Duration(seconds: 6));
      final body = await req.transform(utf8.decoder).join();
      if (req.statusCode != 200) return 'HTTP ${req.statusCode}';
      final j = BridgeEvent.tryJson(body);
      if (j is! Map) return 'unexpected reply: $body';
      return j['claudeUp'] == true ? null : 'claude is not up: $body';
    } on Object catch (e) {
      return '$e';
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

class BridgeException implements Exception {
  BridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Belt-and-braces markdown stripper before TTS: the bridge's voice
/// system prompt already asks for plain spoken sentences, but a harness
/// that ignores it (or a repo report full of bullet lists) would
/// otherwise get its formatting *spoken* ("asterisk asterisk...").
String cleanForSpeech(String t) {
  var s = t.replaceAll(RegExp(r'``[\s\S]*?``'), ' (code omitted) ');
  // Links -> their text (replaceAll doesn't expand $1; mapped does).
  s = s.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]*\)'),
    (m) => m.group(1) ?? m.group(0)!,
  );
  s = s.replaceAll(RegExp(r'[*_`~#>|]'), '');
  s = s
      .split('\n')
      .map(
        (l) => l
            .replaceFirst(RegExp(r'^\s*[-•*+]\s*'), 'and ')
            .replaceFirst(': ', ', ')
            .replaceFirst(RegExp(r'[\s:;]+$'), '') // colon before a join dot
            .trim(),
      )
      .where((l) => l.isNotEmpty)
      .join('. ')
      .replaceAll(RegExp(r'\.\s*\.'), '.')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Piper reads a comma-final clause oddly; give the text a stopper.
  if (s.isNotEmpty && !RegExp(r'[.!?]$').hasMatch(s)) s += '.';
  return s;
}

/// Persisted bridge settings (mirrors the tts_prefs.json pattern).
/// The field defaults ship pointing at the dev machine's always-on demo
/// bridge (tailscale IP, port 8732, --token testtok): a fresh install
/// gets working command chips with zero typing — the Tailscale app on
/// the phone is the only prerequisite (or swap the url for the LAN ip).
/// Saved-but-explicitly-empty strings still mean "the user cleared it".
class BridgePrefs {
  static const defaultUrl = 'http://100.99.240.112:8732';
  static const defaultToken = 'testtok';

  /// When true (the factory setting) and the bridge is configured, spoken
  /// utterances go to the harness and its answer is spoken back; when
  /// false the app keeps parrot-repeating your speech like the original
  /// offline demo. Toggle: the switch on the Bridge screen.
  BridgePrefs({
    this.url = defaultUrl,
    this.token = defaultToken,
    this.voice = true,
  });
  String url, token;
  bool voice;
  bool get configured => url.trim().isNotEmpty && token.isNotEmpty;

  Map<String, Object> toJson() => {'url': url, 'token': token, 'voice': voice};
  static BridgePrefs fromJson(Map<String, Object?> j) => BridgePrefs(
    url: (j['url'] as String? ?? BridgePrefs.defaultUrl).trim(),
    token: j['token'] as String? ?? BridgePrefs.defaultToken,
    voice: j['voice'] as bool? ?? true,
  );
}

File _prefsFile(String modelsDir) =>
    File(p.join(modelsDir, 'bridge_prefs.json'));

Future<BridgePrefs> loadBridgePrefs(String modelsDir) async {
  try {
    return BridgePrefs.fromJson(
      jsonDecode(await _prefsFile(modelsDir).readAsString())
          as Map<String, Object?>,
    );
  } catch (_) {
    return BridgePrefs();
  }
}

Future<void> saveBridgePrefs(String modelsDir, BridgePrefs prefs) async {
  try {
    await _prefsFile(modelsDir).writeAsString(jsonEncode(prefs.toJson()));
  } catch (_) {}
}
