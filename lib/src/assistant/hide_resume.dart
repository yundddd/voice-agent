/// The background → foreground dance as a state unit.
///
/// Five fields used to live loose on the orchestrator — hidden,
/// was-live, the paragraph the hide cut mid-play, the reply buffered
/// unheard while hidden, the spinner line snapshotted under the pause
/// notice — and every bug pinned in their comments (the double `pause`
/// on the way up quoting the pause notice as the working line; the
/// amnesia replay of a half-heard paragraph; only says that landed
/// UNHEARD earning the resume promise) was an interaction between two
/// of them. Same treatment [TurnCoordinator] gave the bridge-turn
/// truth: one writer, named transitions, the invariants stated once on
/// the method that enforces them.
///
/// This class holds no machines: [hide] takes the verdicts the caller
/// computed (is a bridge turn live? was the conversation streaming?)
/// and [resume] hands back a [ResumePlan] of WHAT to do; the assistant
/// does it (respawn the pump, speak the pending block, relisten) in
/// whatever order its machinery requires.
library;

import 'activity.dart';
import 'state.dart';

/// What a resume owes the user, decided at hide time.
final class ResumePlan {
  const ResumePlan({
    required this.unheardReply,
    required this.workingLine,
    required this.relisten,
  });

  /// The newest reply that landed WHILE HIDDEN (text-only by design —
  /// no audio was expected with the app away) and must get its voice
  /// now. Never a half-heard paragraph: those are marked to be skipped
  /// whole, and replaying them reads as amnesia.
  final String? unheardReply;

  /// The spinner's working line snapshotted under the "when you're
  /// back" notice, so a background/foreground blink is invisible to a
  /// running turn.
  final Activity? workingLine;

  /// The conversation was live when the app went away: reopen capture
  /// exactly as it was left.
  final bool relisten;
}

final class HideResume {
  bool _hidden = false;
  bool _wasLive = false;
  String? _drop; // the paragraph audible when the hide cut it: skip whole
  String? _pending; // newest say that landed while hidden, unheard
  String? _lastReply; // newest block speak() has fed to the log
  Activity? _pausedLine; // spinner line snapshotted at hide time

  /// The app is in the background (or frozen behind a pause).
  bool get hidden => _hidden;

  /// The newest reply block handed to the speaker (or to the hidden
  /// buffer) — the candidate the hide marks for silence if it cuts it.
  void noteReplyText(String text) => _lastReply = text;

  /// A block became AUDIBLE: it is heard, so no later path may drop or
  /// re-voice it; this outranks any pending drop mark.
  void blockAired() => _drop = null;

  /// True while [text] is the paragraph a hide cut mid-play: its
  /// remaining chunks die on the floor and no resume path re-voices it.
  bool shouldDrop(String text) => _drop == text;

  /// A fresh turn buries any hide-marked paragraph: new story, no
  /// debt to the old one.
  void buryDropMark() => _drop = null;

  /// A say landed while hidden: logged text-only everywhere, and the
  /// MOST RECENT one earns the "speak it when you're back" promise
  /// (the chat log already shows all of them — one voice, the answer).
  void noteUnheardSay(String text) => _pending = text;

  /// The app went away. [bridgeLive] = a harness turn is in flight (its
  /// stream STAYS attached — the hide must not silence the harness or
  /// bump its generation); [conversationLive] = the mic path was
  /// mid-conversation. `applied` is false when the app already believed
  /// itself hidden — Android fires hidden AND paused on the way down
  /// and hidden AGAIN on the way up, and a second pass would snapshot
  /// the "when you're back" notice itself as the working line (the
  /// spinner quoting the pause notice while we ARE back: the turn looks
  /// like it stopped doing anything). `droppedMidPlay` reports that an
  /// audible paragraph was marked for silence (skip, don't replay).
  ({bool applied, bool droppedMidPlay}) hide({
    required bool bridgeLive,
    required bool conversationLive,
    required AssistantPhase phase,
    required Activity status,
  }) {
    if (_hidden) return (applied: false, droppedMidPlay: false);
    // A paragraph AUDIBLE when the hide cut it is marked for complete
    // silence, not seeded into the resume buffer.
    final midPlay =
        bridgeLive && phase == AssistantPhase.speaking && _lastReply != null;
    if (midPlay) _drop = _lastReply;
    if (bridgeLive) _pausedLine = status;
    _wasLive = conversationLive;
    _hidden = true;
    return (applied: true, droppedMidPlay: midPlay);
  }

  /// The app is back: hand the caller everything hide decided, and
  /// clear the hidden state. The drop mark SURVIVES — chunks still
  /// synthesising for the cut paragraph must keep dying on the floor.
  ResumePlan resume() {
    _hidden = false;
    final plan = ResumePlan(
      unheardReply: _pending,
      workingLine: _pausedLine,
      relisten: _wasLive,
    );
    _pending = null;
    _pausedLine = null;
    _wasLive = false;
    return plan;
  }

  /// A mode switch abandons the relisten intent (the new mode rewires
  /// the input side from scratch).
  void resetRelisten() => _wasLive = false;
}
