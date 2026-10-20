import 'dart:convert';

/// One chat bubble. User entries carry the ASR transcript (or the chip's
/// short label, or typed text); assistant entries carry the harness's
/// reply in spoken SECTIONS — one block per `say` event, so the bubble
/// mirrors what came out of the speaker. An assistant entry created at
/// turn start but never filled (error/nothing-to-say turns) stays empty
/// and the UI hides it.
class ChatEntry {
  ChatEntry({
    required this.fromUser,
    List<String>? blocks,
    this.queued = false,
    this.interrupted = false,
    this.cancelled = false,
    this.receipt = false,
    this.createdMs = 0,
  }) : blocks = blocks ?? <String>[];

  ChatEntry.user(
    String text, {
    this.queued = false,
    this.interrupted = false,
    this.cancelled = false,
    this.receipt = false,
    this.createdMs = 0,
  }) : fromUser = true,
       blocks = [text];

  ChatEntry.assistant({
    this.createdMs = 0,
    this.cancelled = false,
    this.receipt = false,
  }) : fromUser = false,
       blocks = <String>[],
       queued = false,
       interrupted = false;

  /// A file the bridge delivered (POST /send relayed as a `file`
  /// frame): a RECEIPT of bytes on the desktop, not prose — the
  /// renderer gives it the file-card style and a tap fetches them from
  /// GET /file. Like the cancelled flag, it is history: it survives a
  /// reload, and so does the moment the bytes landed on this device.
  ChatEntry.file(
    this.fileName,
    this.filePath,
    this.fileSize, {
    this.createdMs = 0,
  }) : fromUser = false,
       blocks = <String>[],
       queued = false,
       interrupted = false,
       cancelled = false,
       receipt = false;

  final bool fromUser;
  final List<String> blocks;

  // ── Lifecycle stamps (epoch ms, local wall clock; 0 = never / legacy) ──
  // The bubble's own account of the story the journal triangulates:
  // when the phone generated it, when a queued press was finally taken,
  // when the answer first reached the ear, when a cut landed. Under a
  // lossy link these are the numbers triage reads off disk after the
  // fact — which hop swallowed the seconds.

  /// When the bubble entered the log (user: utterance heard/typed;
  /// assistant: turn opened).
  final int createdMs;

  /// User: the harness accepted this queued prompt (pin dissolved).
  int pickedUpMs = 0;

  /// Assistant: the first block appeared — text followed its audio, so
  /// this is the delivered-to-the-screen (usually delivered-to-the-ear)
  /// moment.
  int deliveredMs = 0;

  /// The turn was cut this instant.
  int interruptedMs = 0;

  /// A politly-queued prompt (interrupt-off press over a live turn):
  /// the renderer parks it in the pinned-at-bottom card instead of the
  /// flow until the harness takes the turn (first streamed frame), at
  /// which point it joins the conversation where it was spoken.
  bool queued;

  /// +108: the turn was CUT by a newer press (or an interrupt) before
  /// its done arrived: it keeps the sections it actually spoke and says
  /// so — a silently truncated reply used to read as a deliberately
  /// short one (field report: interrupted thinking showed nothing).
  /// Survives a reload: unlike the queue pin, the fact that a turn was
  /// cut is history, not live machinery.
  bool interrupted;

  /// +168: a background process this phone cut reports
  /// 'X cancelled.' — a RECEIPT, not a reply. It wears the same bubble
  /// as spoken prose today and reads as though the agent said it; the
  /// flag asks the renderer for a distinct style (outline, warning,
  /// italic). Like `interrupted`, it is history, not machinery: it
  /// survives a reload.
  bool cancelled;

  /// +184: the receipt law widened to EVERY tool-finish note. +168
  /// dressed only the CANCELLED receipt distinct; the field tape shows
  /// the happy 'X finished.' note arriving in ordinary chat-bubble
  /// clothes, and two of them in a row read like spoken prose the agent
  /// never said. A receipt now means receipt: outline card, italic
  /// line, small status glyph. [cancelled] picks the ink — warning for
  /// the cut, calm outline ink for the completed. History, not
  /// machinery: survives a reload like every flag here.
  bool receipt;

  // ── The file bubble (set only when isFile) ─────────────────────────────
  bool get isFile => filePath.isNotEmpty;
  String fileName = '';
  String filePath = '';
  int fileSize = 0;

  /// When the bytes landed on THIS device (epoch ms; 0 = never fetched).
  int savedMs = 0;
  String savedPath = '';

  /// Live download state — memory-only, never persists across a restart.
  bool downloading = false;
  int downloadBytes = 0;
  int totalBytes = 0;

  /// Why the last OPEN failed (no viewer, no channel) — memory-only,
  /// like the download counters: the bubble must never wear yesterday's
  /// error as if it were fresh news.
  String? openError;

  bool get isEmpty => blocks.isEmpty;

  Map<String, Object> toJson() => {
    'user': fromUser,
    'blocks': blocks,
    if (createdMs != 0) 't': createdMs,
    if (pickedUpMs != 0) 'pickedUp': pickedUpMs,
    if (deliveredMs != 0) 'heard': deliveredMs,
    if (interruptedMs != 0) 'cut': interruptedMs,
    if (queued) 'queued': true,
    if (interrupted) 'interrupted': true,
    if (cancelled) 'cancelled': true,
    if (receipt) 'receipt': true,
    if (isFile)
      'file': {'name': fileName, 'path': filePath, 'size': fileSize},
    if (savedMs != 0) 'saved': savedMs,
    if (savedPath.isNotEmpty) 'savedTo': savedPath,
  };

  static ChatEntry fromJson(Map<String, Object?> j) {
    int? ms(Object? v) => v is num && v.toInt() != 0 ? v.toInt() : null;
    final f = j['file'] is Map
        ? (j['file'] as Map).cast<String, Object?>()
        : null;
    return ChatEntry(
        // Pins deliberately do NOT survive a reload: the pin belongs to a
        // turn this process was watching; after a restart nobody is holding
        // it, and a stale pin would hang at the bottom forever. The message
        // itself stays in the log.
        fromUser: j['user'] == true,
        blocks: [
          for (final b in (j['blocks'] as List? ?? const <Object>[])) '$b',
        ],
        interrupted: j['interrupted'] == true,
        cancelled: j['cancelled'] == true,
        receipt: j['receipt'] == true,
        createdMs: ms(j['t']) ?? 0,
      )
      ..pickedUpMs = ms(j['pickedUp']) ?? 0
      ..deliveredMs = ms(j['heard']) ?? 0
      ..interruptedMs = ms(j['cut']) ?? 0
      // The file bubble and its delivery record: history, like the
      // receipt flags — a fetched APK stays 'saved' across a restart.
      ..fileName = f?['name'] as String? ?? ''
      ..filePath = f?['path'] as String? ?? ''
      ..fileSize = f?['size'] is num ? (f!['size'] as num).toInt() : 0
      ..savedMs = ms(j['saved']) ?? 0
      ..savedPath = j['savedTo'] as String? ?? '';
  }
}

/// Recency-scoped exact-block scan: like [chatContainsBlock] but walking
/// only the entries newer than [nowMs] minus [withinMs] (an unstamped
/// entry is legacy history and ends the walk). +185: this is the shape
/// the receipt dedup needed — the whole-log text scan silently swallowed
/// the SECOND run of an identical command forever ("Bash sleep 10 &&
/// echo done finished." filed once at 15:59 killed its twin at 16:02,
/// field: 'it doesn't show up at all'), making TEXT an identity across
/// time when the wire v2 lesson says it never is. Inside the window the
/// law is untouched: one delivery, or a live-plus-replay pair, files
/// one period; outside it, a repeat is a different completion and earns
/// its own.
bool chatRecentlyContains(
  List<ChatEntry> entries,
  String text, {
  required int nowMs,
  required int withinMs,
}) {
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final want = norm(text);
  final cutoff = nowMs - withinMs;
  for (final e in entries.reversed) {
    if (e.createdMs == 0 || e.createdMs < cutoff) break;
    if (e.fromUser) continue;
    if (e.blocks.any((b) => norm(b) == want)) return true;
  }
  return false;
}

/// Compact bubble clock: local `HH:MM:SS` for a lifecycle stamp, or the
/// empty string when the stamp is unknown (entries written before
/// timestamps existed render without a caption rather than a fake one).
String formatBubbleClock(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

/// Age of a delta in whole seconds, for one-line journal captions
/// ('waited 47s'): the degraded-network numbers as compact as the
/// clock strings on screen.
String formatWait(int deltaMs) {
  if (deltaMs < 0) deltaMs = 0;
  final s = deltaMs ~/ 1000;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m${_two(s % 60)}s';
  return '${s ~/ 3600}h${_two(s % 3600 ~/ 60)}m';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Human bytes for the file bubble's status line: B under a kilobyte,
/// KB under one megabyte, MB above (one decimal — a slip, not a spec).
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1048576) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '${(n / 1048576).toStringAsFixed(1)} MB';
}

/// Exact-block scan of the assistant side of a chat log, whitespace-
/// normalized. The reattach replay consults this so paragraphs the
/// user already heard are never re-voiced: it must scan the WHOLE log
/// (a restart-time backlog bursts across a dozen turns), it must
/// compare the CLEANED text the log stores (never the raw wire frame —
/// that mismatch re-voiced heard paragraphs at 0.1.0+61), and user
/// entries never count (the replay is answer text). Pure; unit-tested.
bool chatContainsBlock(List<ChatEntry> entries, String text) {
  String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final want = norm(text);
  for (final e in entries.reversed) {
    if (e.fromUser) continue;
    if (e.blocks.any((b) => norm(b) == want)) return true;
  }
  return false;
}

String encodeChatLog(List<ChatEntry> entries) =>
    jsonEncode([for (final e in entries) e.toJson()]);

/// Tolerant decode: any broken chat file (or a future format we do not
/// understand) starts the log fresh rather than blocking app init.
List<ChatEntry> decodeChatLog(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! List) return const [];
    return [
      for (final e in j)
        if (e is Map) ChatEntry.fromJson(e.cast<String, Object?>()),
    ];
  } on FormatException {
    return const [];
  }
}

/// (+151): liveTurnFor retired with the in-bubble spinner — the working
/// line rides the channel's bottom row (AssistantView.showWorkingRow), not a
/// bubble, so no drain shell or queued placeholder can ever steal it.
