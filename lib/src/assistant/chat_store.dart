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
    int Function()? nowMs,
    this.trace,
    this.harness,
  }) : _nowMs = nowMs ?? _wallNowMs;

  /// +213: who the phone believes is holding the pen THIS very moment
  /// ('claude' | 'opencode' | null = offline, not yet seen, or a
  /// harness with no switch). Every entry-creating mutator stamps the
  /// born bubble with it — the split view filters on the stamp, the
  /// log itself stays one append-only truth.
  final String? Function()? harness;

  /// Hand a snapshot of the whole (capped) log to storage. Must never
  /// throw: chat history must never break a conversation. +205: the
  /// list, not an encoded string — the old contract made the STORE
  /// jsonEncode all eighty entries at EVERY touch (the frame bill
  /// caught it: a 71 ms build spike riding mid-entrance), while the
  /// coalescing at +199 only saved the disk. Encoding is now the
  /// persister's side of the seam: once per burst, off the UI isolate.
  final Future<void> Function(List<ChatEntry> snapshot) persist;
  final void Function() repaint;
  final int cap;

  /// Wall clock in epoch ms — every lifecycle stamp runs through this so
  /// tests can wind the world.
  final int Function() _nowMs;
  static int _wallNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// One journal line per bubble-lifecycle event: generated on the
  /// phone, parked in the queue, taken by the harness, heard, cut. The
  /// screen shows the words; this is the history a degraded-network
  /// triage reads (the assistant wires it to its debug sink, which
  /// HH:MM:SS-stamps and journals it).
  final void Function(String line)? trace;

  final List<ChatEntry> _entries = <ChatEntry>[];
  int _version = 0; // bumped on every mutation: drives auto-scroll
  ChatEntry? _queued; // the user entry currently wearing the pin

  /// The era a bubble born THIS mutation wears (see [ChatStore.harness]).
  String? get _era => harness?.call();

  /// +214: the one-time migration of the PRE-SPLIT log. Every un-era'd
  /// legacy bubble gets its era from its own birth timestamp against
  /// the bridge's harnessHistory (the last flip at or before the
  /// birth); a bubble older than the whole timeline, or a bridge with
  /// no timeline to give, wears [fallbackEra] — the era the phone
  /// first saw the pen held in. Returns how many bubbles took a stamp.
  int migrateUnera(
    String fallbackEra, {
    List<({int since, String harness})> timeline = const [],
  }) {
    String eraFor(int bornMs) {
      if (timeline.isEmpty || bornMs == 0) return fallbackEra;
      var era = timeline.first.harness; // older than the first line:
      // the best witness left is the era that line itself records.
      for (final t in timeline) {
        if (t.since <= bornMs) era = t.harness;
      }
      return era;
    }

    var n = 0;
    for (final e in _entries) {
      if (e.harness == null) {
        e.harness = eraFor(e.createdMs);
        n++;
      }
    }
    if (n != 0) {
      trace?.call('msg migration: $n legacy bubbles era\u2019d '
          '(${timeline.length} timeline lines read)');
      touch();
    }
    return n;
  }

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
  /// [parkedBehind]: a prompt is queued and has not STARTED (pin
  /// riding) — the spinner belongs to the work still running, not to
  /// the parked prompt's fresh, empty bubble. +148: a Queue press must
  /// leave the tool-call box untouched; it migrates to the new bubble
  /// at the started marker, when the prompt is actually taken.
  /// +151 retired the which-bubble question with the spinner itself:
  /// the working line now rides NO bubble (see
  /// [AssistantView.showWorkingRow]), so drains, placeholders and pins
  /// have nothing left to steal.

  /// Is this exact text already a block in the log (whitespace-
  /// normalised, whole scan)? wire v2 retired this as the HEARD-LEDGER
  /// (delivery dedup is the HeardLedger's id set — text plays no part);
  /// one honest use remains: [_retireBgWork]'s banner note must not
  /// stamp 'Bash npm test finished.' twice when the receipt rides two
  /// transports. The scan is render-side and rare.
  bool containsBlock(String text) => chatContainsBlock(_entries, text);

  /// +185: the receipt dedup's window — a live file and its replays all
  /// land within seconds of each other; two RUNS of the same command
  /// are minutes apart. Ten minutes is generous for a flaky drain and
  /// still lets tonight's second build announce itself honestly.
  static const receiptDedupMs = 10 * 60 * 1000;

  /// Exact-block scan limited to the recent tail (see
  /// [chatRecentlyContains]): the belt behind the heard-ledger's by-id
  /// dedup, for the same delivery arriving over two transports.
  bool containsBlockRecent(String text, {int withinMs = receiptDedupMs}) =>
      chatRecentlyContains(_entries, text, nowMs: _nowMs(), withinMs: withinMs);

  /// +188: open a user bubble while the words are still in ASR — the
  /// push-to-talk release moment, answered to the speaker with a
  /// transcribing pulse inside the bubble. Machinery like the pin:
  /// an unfilled placeholder never survives a reload, and the
  /// renderer knows the state from the entry itself.
  ChatEntry addUserTranscribing() {
    final entry = ChatEntry.user('', createdMs: _nowMs())
      ..transcribing = true
      ..harness = _era;
    _entries.add(entry);
    trace?.call('msg phone: user (transcribing…)');
    touch();
    return entry;
  }

  /// The ASR verdict for a [+addUserTranscribing] placeholder: the
  /// pulse gives way to the words, in the same bubble, at the same
  /// place in the log. Takes the same queued semantics [addUser] had
  /// at this moment (the pin and the grey ride the fill, because the
  /// queue verdict is only decided with the text).
  void fillUser(ChatEntry entry, String text, {bool queued = false}) {
    entry.blocks[0] = text;
    entry.transcribing = false;
    entry.rev++; // +202: the pulse gave way to words — the bubble changed
    if (queued) {
      unpinQueued();
      entry.queued = true;
      _queued = entry;
    }
    trace?.call('msg phone: user "${_abbrev(text)}" queued=${queued ? 1 : 0}');
    touch();
  }

  void addUser(String text, {bool queued = false}) {
    // One pin at a time: a newer queued press outranks the old one,
    // whose turn is by definition dead (superseded on the wire).
    if (queued) unpinQueued();
    final entry = ChatEntry.user(text, queued: queued, createdMs: _nowMs())
      ..harness = _era;
    _entries.add(entry);
    if (queued) _queued = entry;
    trace?.call('msg phone: user "${_abbrev(text)}" queued=${queued ? 1 : 0}');
    touch();
  }

  /// +108: stamp a superseded turn so the bubble admits it was cut.
  /// Idempotent: the original stream and a later reattach replay of the
  /// same death must not stamp twice (and must not re-persist).
  void markInterrupted(ChatEntry turn) {
    if (turn.interrupted) return;
    turn.interrupted = true;
    turn.interruptedMs = _nowMs();
    turn.rev++; // +202: the cut stamp rides the bubble's face
    trace?.call(
      'msg cut: turn shortened'
      '${turn.createdMs == 0 ? '' : ' after ${formatWait(turn.interruptedMs - turn.createdMs)}'}'
      ' with ${turn.blocks.length} heard block(s)',
    );
    touch();
  }

  /// +114: withdraw one committed block — used at wire death for text
  /// whose audio never started, so the ledger means what it says:
  /// every block in it was heard (or is background-buffered on purpose).
  void removeBlock(ChatEntry turn, String text) {
    if (turn.blocks.remove(text)) {
      turn.rev++; // +202: a block withdrawn is a smaller bubble
      touch();
    }
  }

  /// +110: a standalone system bubble — the interruption verdict gets
  /// its own card in the channel instead of riding inside whichever
  /// assistant turn happens to be open, so the story of a cut thinking
  /// run or backgrounded tool call outlives both turns. Idempotent by
  /// ADJACENCY: the poll transport can deliver the same disposition
  /// notice twice (enqueue ring copy + flush re-announce), and one
  /// event is one bubble — but a legitimately repeated verdict much
  /// later still gets its own fresh card (a text ledger would swallow
  /// every second tool-cut with the same wording — the lesson v2 took
  /// to heart: TEXT is never an identity).
  /// Whether THIS task id already owns a filed receipt (whole log —
  /// an id never dies, so unlike the +185 text window this scan is
  /// forever, and forever-correct: the same task can only ever be
  /// finished once). +186.
  bool hasReceiptFor(String taskId) =>
      taskId.isNotEmpty && _entries.any((e) => e.receiptId == taskId);

  void addSystemNote(
    String text, {
    bool cancelled = false,
    bool receipt = false,
    String receiptId = '',
  }) {
    if (_entries.isNotEmpty) {
      final last = _entries.last;
      if (!last.fromUser &&
          last.blocks.length == 1 &&
          last.blocks.single == text &&
          // +186: identity joins the adjacency test — the same words
          // from a DIFFERENT task are new news (second run of an
          // identical command), while the same task on two transports
          // stays one event.
          last.receiptId == receiptId) {
        return;
      }
    }
    // +168: a cancelled receipt is a RECEIPT — flagged for the outline
    // style, so the acknowledgement of a cut never dresses in the
    // clothes of spoken prose. +184: EVERY tool-finish note gets the
    // same courtesy — the happy 'X finished.' line was still wearing
    // the reply card.
    _entries.add(
      ChatEntry.assistant(
        createdMs: _nowMs(),
        cancelled: cancelled,
        receipt: receipt,
        receiptId: receiptId,
      )
        ..blocks.add(text)
        ..harness = _era,
    );
    trace?.call('msg note: "${_abbrev(text)}"');
    touch();
  }

  /// A bridge-relayed file lands as its own bubble — like a system
  /// note, its own card, not a block inside whichever turn happens to
  /// be open (the bytes outlive the conversation). Idempotent by
  /// ADJACENCY like addSystemNote: the poll transport can hand the same
  /// frame twice, and one delivery is one bubble (the pump's heard-
  /// ledger already dedups by _mid; this is the belt).
  void addFile({
    required String name,
    required String path,
    required int size,
  }) {
    if (_entries.isNotEmpty &&
        _entries.last.isFile &&
        _entries.last.filePath == path) {
      return;
    }
    _entries.add(ChatEntry.file(name, path, size, createdMs: _nowMs())
      ..harness = _era);
    trace?.call('msg file: "$name" ($size bytes)');
    touch();
  }

  /// Open the assistant bubble for a turn: sections are appended as
  /// each say's audio queues (text follows the voice, never leads it).
  /// An interrupted turn keeps the sections actually spoken — that IS
  /// what the conversation was. A turn that never spoke is removed at
  /// the end (see [removeEmptyTurn]).
  ChatEntry beginTurn() {
    final turn = ChatEntry.assistant(createdMs: _nowMs())..harness = _era;
    _entries.add(turn);
    trace?.call('msg turn: assistant bubble open');
    touch();
    return turn;
  }

  /// Append one spoken block to a turn's bubble. The bubble's first
  /// block is its DELIVERY: stamp it and journal the round trip from
  /// the user bubble this turn answers — under delay or drops this is
  /// the number that says where the seconds went.
  void addBlock(ChatEntry turn, String text) {
    if (!turn.fromUser && turn.deliveredMs == 0) {
      turn.deliveredMs = _nowMs();
      trace?.call(_deliveredLine(turn, text));
    }
    turn.blocks.add(text);
    turn.rev++; // +202: THE streaming hot bump — one spoken section,
    // one bubble rebuilt, the other seventy-nine untouched
    touch();
  }

  void unpinQueued() {
    final q = _queued;
    _queued = null;
    if (q != null && q.queued) {
      q.queued = false;
      q.pickedUpMs = _nowMs();
      q.rev++; // +202: the pin lifted — the wait caption lands
      trace?.call(
        'msg queue taken: ${q.createdMs == 0 ? 'waited ?' : 'waited ${formatWait(q.pickedUpMs - q.createdMs)}'}',
      );
      touch();
    }
  }

  /// Drop the pin only if it is still THIS entry's (a newer press may
  /// own it now). A superseded queue-turn calls this: the bridge's one
  /// pending slot is latest-wins, so a prompt replaced by a newer press
  /// is never taken — without this its pin would fossilise at the
  /// bottom of the channel forever (the 'queue or interrupt leaves
  /// stale bubbles' field complaint). The message itself stays in the
  /// log, exactly like a taken pin's — it simply returns to the flow.
  void dropPin(ChatEntry? e) {
    if (e == null) return;
    if (identical(_queued, e)) _queued = null;
    if (e.queued) {
      e.queued = false;
      e.rev++; // +202: pin gone, grey gone — the bubble re-renders plain
      trace?.call('msg pin dropped: superseded before pickup');
      touch();
    }
  }

  /// A bridge turn whose assistant bubble stayed empty (error, or "ran
  /// with nothing to say"): take the blank bubble back out of the log.
  void removeEmptyTurn(ChatEntry turn) {
    if (_entries.remove(turn)) {
      _version++;
      unawaited(persist(List<ChatEntry>.from(_entries)));
    }
  }

  /// Put back an entry that was withdrawn while its verdict was still
  /// pending (+132: a push-to-talk press defers the interrupted trace to
  /// the release gesture — the entry object survived [removeEmptyTurn],
  /// and a decided cut re-files it whole, blocks, stamp and all).
  void reAppend(ChatEntry entry) {
    if (!_entries.contains(entry)) {
      _entries.add(entry);
      _version++;
      unawaited(persist(List<ChatEntry>.from(_entries)));
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
    unawaited(persist(List<ChatEntry>.from(_entries)));
    repaint();
  }

  /// The first-heard line for a turn's bubble, with the round trip back
  /// to the user prompt it answers (when that prompt's stamp is still
  /// in the log): sent→heard, the phone's own end-to-end delay.
  String _deliveredLine(ChatEntry turn, String text) {
    final head = 'msg heard: assistant "${_abbrev(text)}"';
    final i = _entries.indexOf(turn);
    for (var k = i - 1; k >= 0; k--) {
      final e = _entries[k];
      if (e.fromUser && e.createdMs != 0) {
        return '$head (sent→heard ${formatWait(turn.deliveredMs - e.createdMs)})';
      }
    }
    return turn.createdMs == 0
        ? head
        : '$head (+${formatWait(turn.deliveredMs - turn.createdMs)} '
              'since turn opened)';
  }

  static String _abbrev(String s) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 48 ? flat : '${flat.substring(0, 48)}…';
  }
}
