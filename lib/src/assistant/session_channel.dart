/// +251 step 3 (shipped +298): THE SESSION CHANNEL — one conversation's
/// complete private life (docs/session-channels-design.md). The
/// +246..+251 line of fixes kept re-homing pieces of ONE global
/// conversation state every time the user moved between tabs (the
/// working row's marker, the context bar's owner, the rest refusals);
/// the model behind them is that each session is a completely separate
/// thing and the wire merely routes frames to the right one. This class
/// is that thing's home: the turn, its ticker, its reattach ladder, its
/// thread's id and sizes, its parked drain verdict, its focus
/// watermark, its parked-prompt wait. VoiceAssistant now holds
/// {sessionId: SessionChannel} and the getter `_chan` answers for the
/// seated one: every law the +249..+297 series legislated with owner
/// gates (the borrowed box, the badge's home, the stranger's settled
/// verdict, the false grey pin) holds STRUCTURALLY — a channel can
/// only ever speak for its own conversation. The marker laws
/// (turnHomeSid above all) delete with the concept that needed them.
///
/// What deliberately stays on the assistant, single: the reply/audio
/// pipeline and its epoch (ONE speaker — the review's AudioController),
/// the chat store (session-stamped entries, per-session retention),
/// the transport and its ring cursor (ONE multiplexed wire), and the
/// background-work heartbeat (it asks one /health and settles the
/// channel that report names).
library;

import 'reattach_chain.dart';
import 'token_ticker.dart';
import 'turn_session.dart';

final class SessionChannel {
  SessionChannel({
    required this.turn,
    required this.ticker,
    required this.chain,
  });

  /// The wire turn machine, the token ticker and the retry ladder —
  /// constructed per channel by VoiceAssistant._openChannel (their
  /// envs reach the gateway, the reply player and the mic) and owned
  /// here as THIS conversation's.
  final TurnCoordinator turn;
  final TokenTicker ticker;
  final ReattachChain chain;

  bool get busy => turn.busy;
  bool get backgrounded => turn.backgrounded;
  DateTime? get since => turn.since;
  int get seq => turn.seq;
  int get generation => turn.generation;
  String get bgWork => turn.bgWork;

  /// The id this conversation is named by (null = the birth turn's
  /// 'name coming' state; ChatStore.pendingSession stamps its bubbles).
  String? sessionId;

  // Context consumption for THIS conversation's bar: fed by `context`
  // events mid-turn/at turn end and by every /health read. Window 0 =
  // no `result` has named one yet.
  int contextIn = 0;
  int contextWindow = 0;
  double get contextFrac =>
      contextWindow > 0 ? (contextIn / contextWindow).clamp(0.0, 1.0) : 0;

  /// A drain verdict the teardown parked behind on-air audio (+124);
  /// consumed by the channel's own natural-end, superseded by any
  /// newer verdict. One conversation never parks another's drain.
  ({int gen, int mySeq})? drainAfterSpeech;

  /// +168: the current /attach claim is a MAIL FETCH, not work — the
  /// box stays dark while the replay of history the ear already owns
  /// streams in.
  bool drainReading = false;

  /// +298: the PARKED prompt's wait (was VoiceAssistant._awaitPickup,
  /// a global). The grey pin's law (+146/+148): a parked prompt leaves
  /// the spinner's box to the running work and the started marker
  /// lifts the wait — and (+296, made structural here) only the
  /// conversation whose prompt waits may outvote a `settled` verdict
  /// with that wait. A park on tab A was never a warrant for tab B's
  /// box.
  bool awaitPickup = false;

  /// +253 THE FOCUS WATERMARK (Tim's law): the moment (bridge clock,
  /// milliseconds — same domain as a frame's _ts stamp) this
  /// conversation became the one on screen. A say stamped BEFORE it
  /// is backlog: filed, acked, visible, mute — you do not hear the
  /// messages you switch onto, only the ones written after you sit
  /// down. 0 = no watermark yet (fresh boot: the age and heard-ledger
  /// laws alone decide, as they always have).
  int focusAtMs = 0;

  void dispose() {
    chain.cancel();
  }
}
