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
    this.createdMs = 0,
  }) : blocks = blocks ?? <String>[];

  ChatEntry.user(
    String text, {
    this.queued = false,
    this.interrupted = false,
    this.cancelled = false,
    this.createdMs = 0,
  }) : fromUser = true,
       blocks = [text];

  ChatEntry.assistant({this.createdMs = 0, this.cancelled = false})
    : fromUser = false,
      blocks = <String>[],
      queued = false,
      interrupted = false;

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
  };

  static ChatEntry fromJson(Map<String, Object?> j) {
    int? ms(Object? v) => v is num && v.toInt() != 0 ? v.toInt() : null;
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
        createdMs: ms(j['t']) ?? 0,
      )
      ..pickedUpMs = ms(j['pickedUp']) ?? 0
      ..deliveredMs = ms(j['heard']) ?? 0
      ..interruptedMs = ms(j['cut']) ?? 0;
  }
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
