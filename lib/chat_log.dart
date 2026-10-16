import 'dart:convert';

/// One chat bubble. User entries carry the ASR transcript (or the chip's
/// short label, or typed text); assistant entries carry the harness's
/// reply in spoken SECTIONS — one block per `say` event, so the bubble
/// mirrors what came out of the speaker. An assistant entry created at
/// turn start but never filled (error/nothing-to-say turns) stays empty
/// and the UI hides it.
class ChatEntry {
  ChatEntry({required this.fromUser, List<String>? blocks, this.queued = false})
    : blocks = blocks ?? <String>[];

  ChatEntry.user(String text, {this.queued = false})
    : fromUser = true,
      blocks = [text];

  ChatEntry.assistant()
    : fromUser = false,
      blocks = <String>[],
      queued = false;

  final bool fromUser;
  final List<String> blocks;

  /// A politly-queued prompt (interrupt-off press over a live turn):
  /// the renderer parks it in the pinned-at-bottom card instead of the
  /// flow until the harness takes the turn (first streamed frame), at
  /// which point it joins the conversation where it was spoken.
  bool queued;

  bool get isEmpty => blocks.isEmpty;

  Map<String, Object> toJson() => {
    'user': fromUser,
    'blocks': blocks,
    if (queued) 'queued': true,
  };

  static ChatEntry fromJson(Map<String, Object?> j) => ChatEntry(
    // Pins deliberately do NOT survive a reload: the pin belongs to a
    // turn this process was watching; after a restart nobody is holding
    // it, and a stale pin would hang at the bottom forever. The message
    // itself stays in the log.
    fromUser: j['user'] == true,
    blocks: [for (final b in (j['blocks'] as List? ?? const <Object>[])) '$b'],
  );
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

/// The bubble the in-flight working line rides — while a bridge turn is
/// heard OR backgrounded, the LAST assistant entry. Not literally the
/// last entry: a queued press over live work appends a user pin on top
/// of it, and that pin rides the pinned card below, out of the flow,
/// until the harness takes the turn. Requiring chat.last to be the
/// assistant bubble made the spinner box vanish the moment the finger
/// pressed — hiding the very work the detached turn keeps doing (the
/// field report that gets fixed here; pure and public so it is unit-
/// guarded, same pattern as activityLabelFor).
ChatEntry? liveTurnFor(List<ChatEntry> chat, {required bool turnRunning}) {
  if (!turnRunning) return null;
  for (final e in chat.reversed) {
    if (!e.fromUser) return e;
  }
  return null;
}
