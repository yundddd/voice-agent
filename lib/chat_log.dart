import 'dart:convert';

/// One chat bubble. User entries carry the ASR transcript (or the chip's
/// short label, or typed text); assistant entries carry the harness's
/// reply in spoken SECTIONS — one block per `say` event, so the bubble
/// mirrors what came out of the speaker. An assistant entry created at
/// turn start but never filled (error/nothing-to-say turns) stays empty
/// and the UI hides it.
class ChatEntry {
  ChatEntry({required this.fromUser, List<String>? blocks})
    : blocks = blocks ?? <String>[];

  ChatEntry.user(String text) : fromUser = true, blocks = [text];

  ChatEntry.assistant() : fromUser = false, blocks = <String>[];

  final bool fromUser;
  final List<String> blocks;

  bool get isEmpty => blocks.isEmpty;

  Map<String, Object> toJson() => {'user': fromUser, 'blocks': blocks};

  static ChatEntry fromJson(Map<String, Object?> j) => ChatEntry(
    fromUser: j['user'] == true,
    blocks: [for (final b in (j['blocks'] as List? ?? const <Object>[])) '$b'],
  );
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
