/// wire v2: the phone's memory of what it has TAKEN.
///
/// A message id enters this ledger at the moment its paragraph enters
/// the speak path (or, TTS-off, the chat log) — the same instant the
/// +116 stamp used to be the whole heard-ledger. From there the mid is
/// acked to the bridge (`POST /heard`), which trims its unheard backlog
/// — so a redelivered paragraph can be recognised EXACTLY, and the
/// app never guesses from text, order or age again (the +131/+155/+156/
/// +157 statutes of inference, retired by this one small set).
///
/// The commit is irrevocable by design: a barge-in that cuts audio
/// before or mid-paragraph DROPS the rest — never re-listening beats
/// never-not-listening (+116's trade, completed). A failed ack POST is
/// invisible to correctness: [retry] re-sends the pending list on the
/// next bridge interaction, and the worst case is one replay this
/// ledger swallows on arrival.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class HeardLedger {
  HeardLedger({
    required Future<bool> Function(List<int> mids) send,
    this.persist,
    this.cap = 1000,
    Iterable<int> heard = const [],
    Iterable<int> unacked = const [],
  }) : _send = send {
    _heard.addAll(heard);
    _unacked.addAll(unacked);
  }

  /// The transport seam (usually `gateway.heard`). True = acked.
  final Future<bool> Function(List<int> mids) _send;

  /// Optional disk hook — the full snapshot, encoded, after every
  /// commit. Must never throw (a chat memory must never break a
  /// conversation).
  final Future<void> Function(String json)? persist;

  /// Bounded memory: an LRU set. Eviction can only resurface a
  /// paragraph as one extra spoken line; the bridge has long since
  /// ack-trimmed it from the (much smaller) backlog anyway.
  final int cap;

  final Set<int> _heard = <int>{};
  final List<int> _unacked = <int>[];
  bool _sending = false;

  bool isHeard(int mid) => _heard.contains(mid);
  int get length => _heard.length;
  int get pending => _unacked.length;

  /// The paragraph was TAKEN: remembered forever, acked as soon as the
  /// wire allows.
  void commit(int mid) {
    if (mid == 0 || _heard.contains(mid)) return;
    _heard.add(mid);
    _unacked.add(mid);
    while (_heard.length > cap) {
      // Oldest first, but never evict an un-acked mid: its ack is the
      // bridge's only cue to stop replaying it.
      final victim = _heard.firstWhere(
        (m) => !_unacked.contains(m),
        orElse: () => 0,
      );
      if (victim == 0) break;
      _heard.remove(victim);
    }
    unawaited(_persistNow());
    unawaited(_drain());
  }

  /// Re-send whatever the wire swallowed. Cheap: idempotent both ends.
  /// Wired into the assistant's /health probes and turn teardowns.
  Future<void> retry() => _drain();

  Future<void> _drain() async {
    if (_sending || _unacked.isEmpty) return;
    _sending = true;
    try {
      while (_unacked.isNotEmpty) {
        final batch = _unacked.take(200).toList();
        if (!await _send(batch)) return; // unreachable: keep, retry later
        _unacked.removeWhere(batch.contains);
        await _persistNow();
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> _persistNow() async {
    final f = persist;
    if (f == null) return;
    try {
      await f(jsonEncode(toJson()));
    } on Object {
      /* memory is a luxury; the session continues */
    }
  }

  Map<String, Object> toJson() => {
    'heard': _heard.toList(),
    'unacked': _unacked,
  };

  static HeardLedger fromJson(
    Map<String, Object?> j, {
    required Future<bool> Function(List<int> mids) send,
    Future<void> Function(String json)? persist,
    int cap = 1000,
  }) {
    List<int> ints(Object? v) => v is List
        ? v.whereType<num>().map((e) => e.toInt()).toList()
        : const [];
    return HeardLedger(
      send: send,
      persist: persist,
      cap: cap,
      heard: ints(j['heard']),
      unacked: ints(j['unacked']),
    );
  }
}

File _ledgerFile(String modelsDir) =>
    File(p.join(modelsDir, 'heard_ledger.json'));

Future<HeardLedger> loadHeardLedger(
  String modelsDir, {
  required Future<bool> Function(List<int> mids) send,
}) async {
  try {
    return HeardLedger.fromJson(
      jsonDecode(await _ledgerFile(modelsDir).readAsString())
          as Map<String, Object?>,
      send: send,
      persist: (json) => _ledgerFile(modelsDir).writeAsString(json),
    );
  } catch (_) {
    return HeardLedger(
      send: send,
      persist: (json) => _ledgerFile(modelsDir).writeAsString(json),
    );
  }
}
