// +251 design step 1: THE SESSION CHANNEL — one conversation's complete
// private life (docs/session-channels-design.md). The +246..+251 line
// of fixes kept re-homing pieces of ONE global conversation state
// every time the user moved between tabs (the working row's marker,
// the context bar's owner, the rest refusals); the model behind them
// is that each session is a completely separate thing and the wire
// merely routes frames to the right one. This class is that thing's
// home: the turn, its ticker, its reattach ladder, its thread's id and
// sizes, its parked drain verdict. In this era VoiceAssistant holds
// exactly ONE channel and the speaker focus is trivially on it — the
// extraction itself is the proof the scattered globals were always one
// conversation's furniture. Step 3 swaps the single field for
// {sessionId: SessionChannel}, keeps the focused one's frames as the
// only TTS feed, and lets every non-focused channel receive, file and
// ack its messages silently; the marker laws (turnHomeSid above all)
// then delete with the concept that needed them.
import 'reattach_chain.dart';
import 'token_ticker.dart';
import 'turn_session.dart';

final class SessionChannel {
  SessionChannel({required this.turn, required this.ticker, required this.chain});

  /// The wire turn machine, the token ticker and the retry ladder —
  /// constructed by VoiceAssistant (their envs reach the gateway, the
  /// reply player and the mic) and owned here as this conversation's.
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

  /// +249: the conversation the LIVE work belongs to, when a mid-turn
  /// switch backgrounded it; null = the work, if any, is the seat's
  /// own. Step 3 deletes this field: with one channel per session the
  /// working row is furniture INSIDE the channel that owns it, so
  /// 'which tab shows the box' stops being legislated.
  String? turnHomeSid;

  /// A drain verdict the teardown parked behind on-air audio (+124);
  /// consumed by the channel's own natural-end, superseded by any
  /// newer verdict. One conversation never parks another's drain.
  ({int gen, int mySeq})? drainAfterSpeech;

  /// +168: the current /attach claim is a MAIL FETCH, not work — the
  /// box stays dark while the replay of history the ear already owns
  /// streams in.
  bool drainReading = false;
}
