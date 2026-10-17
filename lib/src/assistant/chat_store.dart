/// The conversation log the chat screen renders: user / assistant
/// bubbles, the polite-queue pin, the auto-scroll version, and disk
/// persistence — behind a [persist] callback so the assistant decides
/// where the file lives (and a test decides to just collect the JSON).
///
/// Each heard/spoken-for turn is a user bubble, each harness turn an
/// assistant bubble holding one block per spoken `say` section. This is
/// the on-screen history the reply card used to be — it no longer
/// disappears when the next turn starts; it accumulates like chat.
library;

import 'dart:async';

import '../chat/chat_log.dart';

class ChatStore {
  ChatStore({
    required this.persist,
    required this.repaint,
    this.cap = 80, // entries kept on screen and on disk
  });

  /// Hand the whole (capped) log, encoded, to storage. Must never throw:
  /// chat history must never break a conversation.
  final Future<void> Function(String json) persist;
  final void Function() repaint;
  final int cap;

  final List<ChatEntry> _entries = <ChatEntry>[];
  int _version = 0; // bumped on every mutation: drives auto-scroll
  ChatEntry? _queued; // the user entry currently wearing the pin

  /// The conversation log, oldest first (user / assistant bubbles).
  List<ChatEntry> get entries => _entries;

  /// Changes on every chat mutation — the UI keys its auto-scroll on it.
  int get version => _version;

  /// The user entry currently wearing the pin (polite-queue mode), if
  /// any. Cleared the first time that turn's stream shows life — the
  /// harness picked it up, so the message drops from the pinned card
  /// into the conversation flow where its answer will follow.
  ChatEntry? get queuedBubble => _queued?.queued == true ? _queued : null;

  /// The pinned message's text for the renderer (kept a plain string so
  /// the view widget needs no import of the log model).
  String? get queuedText => queuedBubble?.blocks.join(' ');

  /// The bubble the in-flight working line rides — see [liveTurnFor].
  ChatEntry? liveTurn({required bool turnRunning}) =>
      liveTurnFor(_entries, turnRunning: turnRunning);

  /// Is this exact reply block already in the (disk-persisted) log?
  /// The reattach replay consults this so paragraphs the user heard
  /// before the app died are never read aloud a second time; scans the
  /// WHOLE log (capped at [cap] entries), whitespace-normalised, exact
  /// match. The first cut stopped after three assistant bubbles — a
  /// restart-time backlog burst spans a dozen turns (2000 ring events),
  /// and field journal 22:31: every paragraph inside the three-bubble
  /// window deduped cleanly while older-but-still-under-two-minutes
  /// ones sailed past and got re-voiced: "replaying previous messages"
  /// heard exactly as described. The cap is small and this runs per
  /// replayed frame; a full scan is noise.
  bool containsBlock(String text) => chatContainsBlock(_entries, text);

  void addUser(String text, {bool queued = false}) {
    // One pin at a time: a newer queued press outranks the old one,
    // whose turn is by definition dead (superseded on the wire).
    if (queued) unpinQueued();
    final entry = ChatEntry.user(text, queued: queued);
    _entries.add(entry);
    if (queued) _queued = entry;
    touch();
  }

  /// +108: stamp a superseded turn so the bubble admits it was cut.
  /// Idempotent: the original stream and a later reattach replay of the
  /// same death must not stamp twice (and must not re-persist).
  void markInterrupted(ChatEntry turn) {
    if (turn.interrupted) return;
    turn.interrupted = true;
    touch();
  }

  /// +110: a standalone system bubble — the interruption verdict gets
  /// its own card in the channel instead of riding inside whichever
  /// assistant turn happens to be open, so the story of a cut thinking
  /// run or backgrounded tool call outlives both turns.
  void addSystemNote(String text) {
    _entries.add(ChatEntry.assistant()..blocks.add(text));
    touch();
  }

  /// Open the assistant bubble for a turn: sections are appended as
  /// each say's audio queues (text follows the voice, never leads it).
  /// An interrupted turn keeps the sections actually spoken — that IS
  /// what the conversation was. A turn that never spoke is removed at
  /// the end (see [removeEmptyTurn]).
  ChatEntry beginTurn() {
    final turn = ChatEntry.assistant();
    _entries.add(turn);
    touch();
    return turn;
  }

  /// Append one spoken block to a turn's bubble.
  void addBlock(ChatEntry turn, String text) {
    turn.blocks.add(text);
    touch();
  }

  void unpinQueued() {
    final q = _queued;
    _queued = null;
    if (q != null && q.queued) {
      q.queued = false;
      touch();
    }
  }

  /// A bridge turn whose assistant bubble stayed empty (error, or "ran
  /// with nothing to say"): take the blank bubble back out of the log.
  void removeEmptyTurn(ChatEntry turn) {
    if (_entries.remove(turn)) {
      _version++;
      unawaited(persist(encodeChatLog(_entries)));
    }
  }

  /// /new: blank the channel (the ack stays brief; the wipe speaks for
  /// itself on screen).
  void clearAll() {
    _entries.clear();
    touch();
  }

  /// Seed from disk at boot. Tolerant: [decodeChatLog] returns a fresh
  /// log for anything broken, and a missing file is just the first run.
  void load(String raw) {
    _entries
      ..clear()
      ..addAll(decodeChatLog(raw));
    _version++;
  }

  /// Cap, re-version, persist, repaint — the single mutation tail every
  /// change funnels through.
  void touch() {
    while (_entries.length > cap) {
      _entries.removeAt(0);
    }
    _version++;
    unawaited(persist(encodeChatLog(_entries)));
    repaint();
  }
}
