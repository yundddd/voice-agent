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
    this.inputTokens = 0,
    this.contextWindow = 0,
    this.outTokens = 0,
    this.toolKind = '',
  });

  /// 'say' | 'tool' | 'context' | 'done' | 'error'.
  final String kind;
  final String text;
  final String toolName;
  final String detail;
  final bool isError;

  /// For 'context' (and for 'tool {name:tokens}', where it is that
  /// frame's `in`): tokens of conversation context the next call will
  /// carry, and the model's window (0 = the bridge has not seen a
  /// `result` naming one yet). A context frame may also be a PREVIEW
  /// (extra `preview: true` key, ignored here): the bridge's estimate
  /// of the growing input while the model is still reading — turn
  /// start and every fresh tool_result — which the next exact frame
  /// overrules.
  final int inputTokens;
  final int contextWindow;

  /// For 'tool {name:tokens}' (the live spinner counter): output tokens
  /// this turn (estimate or exact — the bridge says which by when it
  /// sends), the call's context tokens in [inputTokens] (same field the
  /// `context` frame uses), and the activity word in [toolKind]
  /// ('thinking', 'answering', 'calling Bash', …). A pre-numbers bridge
  /// leaves these zero/empty and the app shows [detail] verbatim.
  final int outTokens;
  final String toolKind;

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
        final n = data['in'];
        final o = data['out'];
        return BridgeEvent._(
          'tool',
          toolName: '${data['name'] ?? ''}',
          detail: '${data['detail'] ?? ''}',
          inputTokens: n is num ? n.toInt() : 0,
          outTokens: o is num ? o.toInt() : 0,
          toolKind: '${data['kind'] ?? ''}',
        );
      case 'context':
        final n = data['in'], w = data['window'];
        return BridgeEvent._(
          'context',
          inputTokens: n is num ? n.toInt() : 0,
          contextWindow: w is num ? w.toInt() : 0,
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

  /// The port this app serves its event journal on (lib/app_events.dart).
  /// Ridden on EVERY request as `?logport=` so the bridge always knows
  /// where to poll the phone's side of the story from — the peer address
  /// is simply the connection source the turn already used. Null until
  /// the app wires it in (or for host tests): the parameter is simply
  /// absent then, and the bridge leaves polling off.
  int Function()? journalPort;

  Uri _u(String path, [Map<String, String>? extra]) {
    final jp = journalPort == null ? null : journalPort!();
    return Uri.parse(
      baseUrl.endsWith('/')
          ? '${baseUrl.substring(0, baseUrl.length - 1)}$path'
          : '$baseUrl$path',
    ).replace(queryParameters: {
      'token': token,
      if (jp != null && jp > 0) 'logport': '$jp',
      ...?extra,
    });
  }

  /// Sends an utterance; the stream yields say/tool events as the harness
  /// works and a final done (or error) event, then closes. The HTTP
  /// request *is* the turn: cancelling the subscription closes the
  /// connection and the bridge's response-close hook cleans up.
  ///
  /// [interrupt] decides what a QUEUED prompt does to the turn in flight
  /// (only relevant while one is already running backgrounded): true
  /// (the default — typed text, conversation barge-in, PTT slide-up)
  /// interrupts a mere thinking turn in-band so this prompt starts in a
  /// heartbeat (the CLI process itself survives — no kill, no `--resume`,
  /// no cold prefill next turn);
  /// false (the PTT slide-right polite queue) lets the turn finish its
  /// work first. An open tool is never interrupted — it runs to
  /// completion and this prompt goes next either way.
  ///
  /// [onActivity] fires for every raw chunk the socket delivers — every
  /// event frame AND every keep-alive comment the parser drops. The
  /// bridge pings `: ping` every 15 s while a turn is open, so this is
  /// the app's liveness signal on the connection itself: no bytes for
  /// over a ping interval means the socket has gone quiet on us (a
  /// black-holed route after a background stint), not that the harness
  /// is quiet.
  Stream<BridgeEvent> talk(
    String text, {
    bool interrupt = true,
    void Function()? onActivity,
  }) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(
        _u('/talk', {'interrupt': interrupt ? '1' : '0'}),
      );
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

  /// Byte-level activity tap shared by /talk and /attach (see talk's
  /// [onActivity] docs): forward every chunk, touching the callback as
  /// each crosses. Errors and cancellation ride straight through.
  static Stream<String> _tapped(
    Stream<String> raw,
    void Function()? onTouch,
  ) async* {
    await for (final s in raw) {
      if (onTouch != null) onTouch();
      yield s;
    }
  }

  /// Re-attaches to a turn the bridge is running with NO listener — the
  /// phone's stream died while the app was hidden (Android killed the
  /// process, or the OS dropped the socket): the bridge replays the
  /// events that happened unheard, then streams live until the turn's
  /// done. When the turn is still open the GET becomes its heard view
  /// even if the bridge still believes a (zombie) socket is attached —
  /// the attach STEALS the view, which is how the app repairs a silently
  /// black-holed connection. Cancelling the subscription backgrounds the
  /// turn again, exactly like a hung-up /talk. A turn that already ended
  /// replays its buffered tail (done included) and closes — the same
  /// events either way, so the caller needs no special-casing.
  Stream<BridgeEvent> attach({void Function()? onActivity}) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(_u('/attach'));
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

  /// Barge-in: asks the bridge to end the in-flight turn (context
  /// survives — the next talk continues the same conversation).
  Future<void> stop() => _post('/stop');

  /// Forget the conversation (fresh session on the next utterance).
  Future<void> reset() => _post('/new');

  /// GET /health → null when reachable and claude is up, else the reason.
  Future<String?> health() async {
    final h = await _healthRaw();
    if (h.body == null) return h.why ?? 'unreachable';
    return h.body!['claudeUp'] == true ? null : 'claude is not up: ${h.body}';
  }

  /// GET /health verbatim ({ok, claudeUp, sessionId, turnOpen, queued,
  /// backgrounded}) — what the Bridge screen shows as the session id;
  /// null when the bridge can't be reached at all.
  Future<Map<String, Object>?> healthInfo() async => (await _healthRaw()).body;

  /// POSTs the app event journal envelope (lib/app_events.dart) — the
  /// PUSH transport for phones that cannot be dialed back (the Android
  /// tailscale client refuses inbound connections by default, and behind
  /// carrier NAT there is no route to dial at all). Outbound is always
  /// alive; it already carries every turn. The bridge confirms with a
  /// plain `ok`, and the journal's watermark advances only on that ack —
  /// delivery is at-least-once, seq-deduped bridge-side, convergent by
  /// construction. `logport=` rides the request too, so a phone that
  /// later enables inbound (tailscale toggle) gets its pull leg revived
  /// automatically.
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

class BridgeException implements Exception {
  BridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the app should do about the bridge after ITS view died — the /talk
/// (or /attach) socket dropped while the app was hidden, the process was
/// killed, or the connection went quiet and black-holed. Fed the GET
/// /health snapshot (or null when the bridge cannot be reached right now):
///
/// * `true` — reattach with GET /attach: a turn is open (`turnOpen`) so
///   attach becomes its heard view again — it STEALS the view even when
///   the bridge still believes the old dead socket is attached (an
///   interrupt-then-repair for the blackhole case, where the server never
///   learns the ear is gone and would keep relaying into the void); or a
///   turn ended unheard and left `missed` events in the replay backlog.
/// * `false` — nothing open, nothing unheard: the turn finished while we
///   were gone and delivered its tail (or never existed) — go idle.
/// * `null` — bridge unreachable: cannot tell whether the turn is alive.
///   Waking phones wake their network late (Tailscale especially), so a
///   failed probe must never silently drop a running turn — retry the
///   probe with backoff instead.
bool? bridgeReattachNeeded(Map<String, Object>? health) {
  if (health == null) return null;
  if (health['turnOpen'] == true) return true;
  final missed = health['missed'];
  return missed is num && missed.toInt() > 0;
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

/// 12400 -> '12.4k', 467232 -> '467k', 1_250_000 -> '1.3M'. Shared by
/// the context bar (main.dart) and the live token ticker
/// (VoiceAssistant.tokenTickerLabel), mirroring the bridge's own
/// fmtTok so phone and wire never disagree about how a number reads.
String fmtTokenCount(int n) => n < 1000
    ? '$n'
    : n < 1000000
    ? '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k'
    : '${(n / 1000000).toStringAsFixed(1)}M';

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
    this.narrate = true,
  });
  String url, token;
  bool voice;

  /// 'Narrate progress' (the factory setting): the harness's work becomes
  /// audible AS IT HAPPENS — every `tool` event the bridge emits at a
  /// step's start gets a spoken line, and a long silent step (a
  /// three-minute build) repeats its line as a still-at-it heartbeat, so
  /// a turn never sounds like dead air followed by one block of speech
  /// at the end. Off restores the quiet regime: status text only, the
  /// answer arrives when it's ready. Read live by
  /// VoiceAssistant.runQuickCommand's event loop (no wire involvement).
  bool narrate;
  bool get configured => url.trim().isNotEmpty && token.isNotEmpty;

  Map<String, Object> toJson() => {
    'url': url,
    'token': token,
    'voice': voice,
    'narrate': narrate,
  };
  static BridgePrefs fromJson(Map<String, Object?> j) => BridgePrefs(
    url: (j['url'] as String? ?? BridgePrefs.defaultUrl).trim(),
    token: j['token'] as String? ?? BridgePrefs.defaultToken,
    voice: j['voice'] as bool? ?? true,
    narrate: j['narrate'] as bool? ?? true,
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
