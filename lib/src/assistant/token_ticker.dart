/// The live token ticker (spinner line: 'thinking · 1.2k out · 21k in').
///
/// The bridge relays its tally every ~0.8 s of active generation (plus
/// an exact-settling frame whenever a message closes). Between relays
/// this side keeps the number GROWING locally: [_rate] is a
/// tokens-per-second average learned from the app's OWN consecutive
/// relays (EMA, clamped to a believable band), so the eye sees a
/// counting ticker, not a 2-second-lagging step function. The local
/// growth is a display estimate only — the next relay always replaces
/// it with the bridge's authoritative number (which can even snap the
/// readout down when an estimate was over the exact count, exactly as
/// the CLI's own counter does when usage deltas land).
///
/// All of the counter state used to squat on the assistant as nine
/// underscore fields; here it is a class with a clock, and every rule
/// the field reports taught us has a unit test.
library;

import '../bridge/bridge_event.dart';
import '../bridge/text_rules.dart';
import '../common/clock.dart';
import '../common/sinks.dart';

class TokenTicker {
  TokenTicker({required this.clock, required this.repaint});

  final Clock clock;
  final Repaint repaint;

  int _out = 0; // last bridge-sent output figure (est or exact)
  int _in = 0; // context tokens from the same frame (RAW — the full
  // conversation each call carries; the meter shows the turn's delta)
  int _inAnchor = 0; // +93: the turn's first input figure — the delta
  // baseline (see turnInAnchor). The fresh turn's opening zero clears
  // it exactly like the opening zero clears _out's history.
  String _kind = ''; // 'thinking' | 'answering' | 'calling X' | ''
  String _thought = ''; // rolling tail of the LIVE thinking text — the
  // `thought` field the tally frames carry while kind is 'thinking';
  // cleared the moment kind moves off, so an answered turn never shows
  // the deliberations that got it there.
  String _draft = ''; // the un-spoken tail of the LIVE answer — the
  // `draft` field the tally frames carry while kind is 'answering'; the
  // in-flight bubble paints it as the reply writes itself, and the say
  // frame that lands on block close replaces it with the confirmed text.
  DateTime? _at; // when the last tally frame landed
  double _rate = 0; // learned tok/s (0 = nothing learned yet)
  bool _live = false; // ticking ONLY between a `tokens` frame and a
  // competing tool/say event (a running Bash freezes the counter —
  // nothing is generating) or a turn start (a frozen counter riding
  // into the next turn would be a lie).

  bool get isOn => _live && _at != null && (_out > 0 || _in > 0);

  /// The raw input figure the last frame carried (context frames compare
  /// against it before re-anchoring).
  int get rawInputTokens => _in;

  /// The live thought tail the spinner paints under its working line —
  /// non-empty only while the tally says 'thinking' and the bridge
  /// actually streamed thinking (the plain word remains honest when
  /// the model thinks silently: kind 'thinking', thought '').
  String get thought => _live && _kind == 'thinking' ? _thought : '';

  /// The live answer tail the in-flight bubble paints under its working
  /// line while the model writes its reply — non-empty only while the
  /// tally says 'answering' and the bridge streamed text. An older
  /// bridge (no `draft` field) or a silent answerer keeps the working
  /// line alone, exactly as before.
  String get draft =>
      _live && (_kind == 'answering' || _kind == 'settled') ? _draft : '';

  /// The bridge declared the answer's text final (message_stop, no open
  /// tools): the wheel must stop — the only thing left is the phone
  /// rendering audio (0.1.0+83/84).
  bool get settled => _kind == 'settled';

  /// The spinner's first line: WHAT the harness is doing, translated
  /// from the tally's kind — words only, never numbers (those belong
  /// to the meter line alone, per +76/+85: the same digits on two lines
  /// at two update cadences is how 'thinking' got buried).
  /// Falls back to the plain status until the first tally of the turn
  /// teaches us anything — so 'Asking the bridge…' covers the wire
  /// flight and the pre-first-token prefill, honestly.
  String activityLabel(String statusFallback) =>
      activityLabelFor(_kind, statusFallback);

  /// The growing label. Only meaningful while [isOn]; the spinner asks
  /// for it on every one of its 120 ms ticks, which is what makes the
  /// number move between relays.
  String get label {
    final age = clock().difference(_at!).inMilliseconds / 1000.0;
    // A stalled stream (frames stopped coming but nothing said 'tool
    // running' either) must not inflate the estimate forever: growth
    // freezes past a few relay periods of silence.
    final est = _out + (_rate * (age > 5 ? 5 : age)).round();
    final kind = _kind.isEmpty ? '' : '$_kind · ';
    return '$kind${fmtTokenCount(est)} out · ${fmtTokenCount(tokensIn)} in';
  }

  /// The output count for the spinner's meter line: the bridge's last
  /// exact figure, extrapolated between relays when the ticker is live
  /// (same math and freeze rule as [label]).
  int get tokensOut {
    if (!isOn || _at == null) return _out;
    final age = clock().difference(_at!).inMilliseconds / 1000.0;
    return _out + (_rate * (age > 5 ? 5 : age)).round();
  }

  /// The spinner meter's `in` figure: THIS turn's input growth (raw
  /// context minus the turn's anchor, +93). The full-conversation
  /// number the calls carries stays where it belongs — the context bar.
  int get tokensIn => _in > _inAnchor ? _in - _inAnchor : 0;

  /// Records a raw input figure (tally or context frame) and keeps the
  /// turn anchor honest: the first real number anchors, a smaller one
  /// re-anchors, and a zero — which every fresh turn's opening frames
  /// carry — clears the anchor so no stale delta rides across turns.
  void noteInputTokens(int observed) {
    _inAnchor = turnInAnchor(observed, _inAnchor);
    _in = observed > 0 ? observed : 0;
  }

  void onFrame(BridgeEvent ev) {
    final now = clock();
    final out = ev.outTokens;
    if (out > 0) {
      final dt = _at == null
          ? null
          : now.difference(_at!).inMilliseconds / 1000.0;
      // Only a real step UP while already ticking can teach the rate:
      // the first frame of a turn and down-settling corrections carry
      // no elapsed-generation information (the gap includes tool runs).
      if (_live && dt != null && dt > 0.15 && out > _out) {
        final inst = (out - _out) / dt;
        // ~3 relays to settle toward a step change; believable-speed
        // clamp (fast streaming rarely passes ~300 tok/s, and the
        // floor keeps a flat relay from freezing the ticker).
        _rate = _rate <= 0 ? inst : _rate * 0.6 + inst * 0.4;
        _rate = _rate.clamp(5.0, 800.0);
      }
    }
    // The bridge's number is AUTHORITATIVE — including the 0 of the
    // first `thinking` frame of a new turn: that zero is what buries the
    // PREVIOUS turn's tally so a fresh turn's line can never show stale
    // digits (the bridge resets its own counter at beginTurn too).
    _out = out;
    noteInputTokens(ev.inputTokens);
    _kind = ev.toolKind;
    _thought = ev.toolKind == 'thinking' ? ev.thought : '';
    // +83: 'settled' means the TEXT is final (bridge message_stop) but
    // the draft tail may still hold sentences whose audio hasn't played
    // — keep painting it, exactly as while answering.
    _draft =
        ev.toolKind == 'answering' ||
            ev.toolKind == 'settled' ||
            ev.draft.isNotEmpty
        ? ev.draft
        : _draft;
    _at = now;
    _live = true;
    // +76: the tally no longer overwrites the status with its stepped
    // 'thinking · 80 out · 300k in' label. Status keeps naming the WORK;
    // counts live on the meter line alone. (Frames still update the
    // counters and wake the widget.)
    repaint();
  }

  /// A new turn starts (or a /talk supersedes): counters belong to a
  /// turn, and this one's tally starts at its first frame (the bridge
  /// resets too).
  void resetForTurn() {
    _live = false;
    _kind = '';
    _thought = '';
  }

  /// The answer closed and is being spoken: nothing is generating to
  /// grow a counter over.
  void markSpoken() => _live = false;

  /// A real step (Bash npm test…) froze the counter: the estimate
  /// stopped being about live generation.
  void markToolStep() => _live = false;

  /// /new wiped the conversation: no counters, no learned rate — the
  /// bar goes blank, not into a monotonic decline from last week's
  /// number (the bridge cleared its snapshot; the first message_start
  /// of the new conversation puts an honest number back).
  void resetAll() {
    _out = _in = _inAnchor = 0;
    _kind = '';
    _thought = '';
    _live = false;
    _rate = 0;
  }
}
