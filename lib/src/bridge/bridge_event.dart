/// One parsed SSE frame from the harness bridge (/talk, /attach or the
/// /poll ring), plus the pure SSE state machine that decodes them.
///
/// Kept free of any socket or client reference: a test feeds it scripted
/// lines (or maps from a poll page) and asserts the frames out.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

class BridgeEvent {
  const BridgeEvent._(
    this.kind, {
    this.text = '',
    this.toolName = '',
    this.detail = '',
    this.isError = false,
    this.inputTokens = 0,
    this.contextWindow = 0,
    this.ctxSession,
    this.session,
    this.outTokens = 0,
    this.toolKind = '',
    this.thought = '',
    this.draft = '',
    this.wireMs = 0,
    this.mid = 0,
    this.turn = 0,
    this.fileName = '',
    this.filePath = '',
    this.fileSize = 0,
    this.taskId = '',
  });

  /// Test seam: build frames verbatim without inventing wire payloads.
  @visibleForTesting
  const BridgeEvent.forTest(
    this.kind, {
    this.text = '',
    this.toolName = '',
    this.detail = '',
    this.isError = false,
    this.inputTokens = 0,
    this.contextWindow = 0,
    this.ctxSession,
    this.session,
    this.outTokens = 0,
    this.toolKind = '',
    this.thought = '',
    this.draft = '',
    this.wireMs = 0,
    this.mid = 0,
    this.turn = 0,
    this.fileName = '',
    this.filePath = '',
    this.fileSize = 0,
    this.taskId = '',
  });

  /// 'say' | 'tool' | 'context' | 'done' | 'error' | 'file'.
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

  /// +249: for 'context' frames — the conversation these numbers
  /// describe. Null = a bridge too old to say; the phone merges those
  /// on trust, exactly as before.
  final String? ctxSession;

  /// +274: the conversation that OWNED any relayed frame at relay time
  /// (the wire's `_sess`). Null = a bridge too old to stamp, or a
  /// frame born before the session had a name — the phone falls back
  /// on the +253 context-frame inference for those.
  final String? session;
  final int contextWindow;

  /// For 'tool {name:tokens}' (the live spinner counter): output tokens
  /// this turn (estimate or exact — the bridge says which by when it
  /// sends), the call's context tokens in [inputTokens] (same field the
  /// `context` frame uses), and the activity word in [toolKind]
  /// ('thinking', 'answering', 'calling Bash', …). A pre-numbers bridge
  /// leaves these zero/empty and the app shows [detail] verbatim.
  final int outTokens;
  final String toolKind;

  /// For 'tool {name:tokens}' while [toolKind] is 'thinking': a rolling
  /// one-line tail (~160 chars) of the model's LIVE thinking text — the
  /// words behind the word "thinking". Empty when not thinking, or when
  /// the model simply answers.
  final String thought;

  /// For 'tool {name:tokens}' while [toolKind] is 'answering': a rolling
  /// one-line tail (~240 chars) of the answer text the bridge has not
  /// spoken yet — the reply painted while it is still being written.
  /// Empty on bridges too old to send it (unknown frame keys are
  /// ignored), so the chat bubble simply stays on the working line.
  final String draft;

  /// +186: for 'tool {name:finished}' — the BACKGROUND TASK's own
  /// identity (the CLI's task id, or the cut tool's tool_use id),
  /// carried so the phone dedups receipts by WHAT finished, never by
  /// the label text or the clock. Empty on the turn-lifecycle farewell
  /// (which names a turn, not a task) and on bridges too old to send
  /// it — the receipt then falls back to the +185 delivery window.
  final String taskId;

  /// For 'file' (POST /send relayed): the display name, the root-
  /// relative path to fetch from GET /file, and the size in bytes. A
  /// bridge too old to have /send never emits the frame, so these stay
  /// empty on every other kind.
  final String fileName;
  final String filePath;
  final int fileSize;

  /// wire v2 identity: the message id the bridge stamped at relay
  /// (`_mid` — the phone's heard-ledger key), and the id of the turn
  /// that owns this frame (`_turn` — reserved at POST time, echoed as
  /// the 'turn' meta event, worn by every frame the turn relays).
  /// Zero on either means a frame predates v2: it is treated as news
  /// (never ledger-skipped) and, for farewells, as this view's own.
  final int mid;
  final int turn;

  /// The bridge's wall-clock milliseconds at the moment this frame
  /// crossed the wire (`_ts` on every SSE frame; 0 from older bridges).
  /// The assistant subtracts its /health-calibrated clock skew and logs
  /// the age next to tool lines — the instrument that tells whether
  /// batching happens on the wire or in this app's socket stack.
  final int wireMs;

  /// A complete assistant message — feed straight into the TTS path.
  bool get isSay => kind == 'say';
  bool get isDone => kind == 'done';

  /// Ring/poll frame shape: the event name and an already-decoded data
  /// map — same dispatch as [parse], minus the re-encode round trip.
  static BridgeEvent parseMap(String event, Map<Object?, Object?> data) =>
      parse(event, jsonEncode(data));

  static int _int(Object? v) => v is num ? v.toInt() : 0;

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
    final sess = data['_sess'] is String && (data['_sess'] as String).isNotEmpty
        ? data['_sess'] as String
        : null;
    switch (event) {
      case 'say':
        return BridgeEvent._(
          'say',
          text: '${data['text'] ?? ''}',
          wireMs: _int(data['_ts']),
          session: sess,
          mid: _int(data['_mid']),
          turn: _int(data['_turn']),
        );
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
          thought: '${data['thought'] ?? ''}',
          draft: '${data['draft'] ?? ''}',
          wireMs: _int(data['_ts']),
          session: sess,
          mid: _int(data['_mid']),
          turn: _int(data['_turn']),
          taskId: '${data['id'] ?? ''}',
        );
      case 'context':
        final n = data['in'], w = data['window'];
        return BridgeEvent._(
          'context',
          inputTokens: n is num ? n.toInt() : 0,
          contextWindow: w is num ? w.toInt() : 0,
          ctxSession: data['session'] is String
              ? data['session'] as String
              : null,
          session: sess,
          mid: _int(data['_mid']),
          turn: _int(data['_turn']),
        );
      case 'file':
        return BridgeEvent._(
          'file',
          fileName: '${data['name'] ?? ''}',
          filePath: '${data['path'] ?? ''}',
          fileSize: _int(data['size']),
          wireMs: _int(data['_ts']),
          session: sess,
          mid: _int(data['_mid']),
          turn: _int(data['_turn']),
        );
      case 'turn':
        // The transport's meta frame: the id POST /talk reserved for
        // THIS prompt (not relayed, so it carries no _turn of its own
        // — it IS the turn). Every later frame the pump sees may
        // finally be attributed; see BridgeTransport and BridgeTurn.
        return BridgeEvent._('turn', turn: _int(data['turn']));
      case 'disconnect':
        // A transport truth, not a turn verdict: the wire is down and
        // the pump is retrying (see BridgeTransport._pollTurn). Never
        // terminal — the loop that consumes this stream must not close
        // the turn over it.
        return BridgeEvent._(
          'disconnect',
          text: '${data['error'] ?? 'bridge unreachable'}',
          wireMs: _int(data['_ts']),
          session: sess,
          mid: _int(data['_mid']),
          turn: _int(data['_turn']),
        );
      case 'done':
        return BridgeEvent._(
          'done',
          isError: data['isError'] == true,
          // +219: an error's REASON rides the done frame (the field
          // tape: the provider's 403 died in the bridge's stderr and
          // the phone closed the turn 'done clean'). The text lands in
          // `text` so the pump's error path and the journal share one
          // carrier.
          text: data['error'] is String ? data['error'] as String : '',
          session: sess,
          mid: _int(data['_mid']),
          turn: _int(data['_turn']),
        );
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
