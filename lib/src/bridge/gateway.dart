/// The harness seam: what the assistant needs from "the thing that
/// answers", said as a protocol rather than as Claude Code specifics.
///
/// Today the only implementation is [BridgeClient] (the Claude Code SSE
/// bridge in tool/claude_bridge.mjs); tomorrow it can be a different
/// coding agent's server, a hosted endpoint, or a local in-process
/// runner — the assistant only ever talks to this interface, and tests
/// hand it a [FakeHarness].
library;

import 'bridge_event.dart';

abstract class HarnessGateway {
  /// The port this app serves its event journal on (src/journal/).
  /// Ridden on EVERY request as `?logport=` so the harness always knows
  /// where to poll the phone's side of the story from. Null until the
  /// app wires it in: the parameter is simply absent then.
  int Function()? journalPort;

  /// Starts a turn with [text]; the stream yields a `turn` meta event
  /// naming the reserved turn id FIRST, then say/tool/context events
  /// as the harness works and a final done (or error) event, and
  /// closes. Cancelling the subscription abandons the phone's VIEW
  /// of the turn (the harness keeps working, backgrounded).
  ///
  /// [interrupt] decides what a QUEUED prompt does to a turn already in
  /// flight: true interrupts a mere thinking turn in-band; false lets
  /// the work finish first (the polite queue). [cutTool] is the
  /// middle flavour (queue-with-backgrounding): polite for thinking
  /// turns, but a RUNNING TOOL is put into background so the agent is
  /// freed for this prompt at once. The bridge owns the decision — it
  /// alone knows whether a tool is open at the moment the prompt lands.
  ///
  /// [onActivity] fires for every raw chunk the connection delivers —
  /// event frames AND keep-alive pings — the liveness signal behind the
  /// quiet-wire watchdog ([WireLease]).
  Stream<BridgeEvent> talk(
    String text, {
    bool interrupt = true,
    bool cutTool = false,
    void Function()? onActivity,
  });

  /// Pull transport: start a turn whose events are read from the ring
  /// with [poll] instead of a pushed stream. The bridge answers the
  /// POST with a JSON receipt — returns the turn id it RESERVED for
  /// this prompt (0 only if the receipt was unreadable: proto drift).
  Future<int> talkPoll(
    String text, {
    bool interrupt = true,
    bool cutTool = false,
  });

  /// wire v2: commit the phone's hearing — the bridge trims these
  /// message ids from the unheard backlog. Idempotent by contract;
  /// true = acknowledged (a false only postpones: the phone re-sends
  /// its pending list, the worst case is one replay the heard-ledger
  /// swallows on arrival).
  Future<bool> heard(List<int> mids);

  /// One ring page: events with seq > [since]; null = unreachable.
  Future<Map<String, Object>?> poll(int since);

  /// A fresh heard view of whatever turn the harness is running (or
  /// just ran): replays the unheard backlog, then streams live.
  Stream<BridgeEvent> attach({void Function()? onActivity});

  /// Cut the harness's in-flight WORK short (in-band interrupt; the
  /// conversation itself survives). +257: [sid] names the
  /// CONVERSATION whose turn to cut — the Stop chip rides a view that
  /// may belong to a backgrounded thread, and since the router era
  /// every conversation has its own floor to cut. Null cuts the
  /// seated one.
  Future<void> stop({String? sid});

  /// Forget the conversation (fresh session on the next utterance).
  Future<void> reset();

  /// Health as a one-line reason: null when alive and healthy.
  Future<String?> health();

  /// The raw health payload (sessionId, claudeUp, turnOpen, missed,
  /// poll…): what reattach decisions, the context bar and the session
  /// row all read. Null when unreachable.
  Future<Map<String, Object>?> healthInfo();

  /// Deliver a journal envelope out-of-band (push transport for phones
  /// that cannot be dialled back); true = acknowledged.
  Future<bool> pushJournal(Map<String, Object> envelope);

  /// The harness's working-folder listing for the picker: one directory
  /// level under the bridge's allowlisted root ([path] null = the root).
  /// Payload: `{dir, in, parent, dirs: [{name, path}]}` — null when
  /// unreachable or the harness has no folder browser. Defaults to
  /// unsupported so a harness without folders keeps compiling.
  Future<Map<String, Object>?> dirs({String? path}) async => null;

  /// Move the harness's working folder (a fresh session starts there).
  /// Returns the failure reason, null on success/unsupported.
  Future<String?> setDir(String path) async => null;

  /// +216: the model picker's menu, one shape for both harnesses:
  /// {harness, current, models: [{id, label}]}. Null when unreachable
  /// or a bridge too old for /models (the row then reads dead).
  /// +230: [harness]/[dir] ask the menu of a seat the bridge is NOT
  /// on (the session-creation sheet previews before it moves); absent
  /// answers for the live seat.
  Future<Map<String, Object>?> models({String? harness, String? dir}) async =>
      null;

  /// Apply a menu entry (POST /model): claude over the CLI's
  /// set_model control frame, opencode over the session-model API —
  /// the bridge translates; the phone never learns which dialect ran.
  /// Returns the failure reason, null on success/unsupported.
  Future<String?> setModel(String id) async => null;

  /// +230: move the bridge's single seat to this tab's
  /// (harness, folder, conversation) in ONE atomic request
  /// (POST /seat). [sessionId] null-with-[fresh] starts the tab's
  /// first conversation; a named id resumes it and rewrites the
  /// project's pointer, so a bridge restart wakes on this tab.
  /// Answers the bridge's settled seat
  /// {ok, harness, dir, sessionId, model}; null = unreachable or a
  /// bridge without the endpoint (the flags ride /health's `seat`).
  Future<Map<String, Object>?> seat({
    String? harness,
    String? dir,
    String? model,
    String? sessionId,
    bool fresh = false,
  }) async => null;

  /// Switch WHICH harness the bridge speaks (POST /harness {"to":…}).
  /// The switch is an honest /new at the seam, but each harness keeps
  /// its OWN resume pointer — flipping back resumes that conversation
  /// where it stopped. The current value rides /health as `harness`
  /// (absent on pre-switch bridges: the row then reads 'Claude Code'
  /// and the switch is dead). Returns the failure reason, null on
  /// success/unsupported.
  Future<String?> setHarness(String to) async => null;

  /// Fetch the bytes behind a relayed `file` frame into [destPath],
  /// resuming a `$destPath.part` an earlier wire death left short.
  /// True = the whole file is at [destPath]. Defaults to unsupported.
  Future<bool> downloadFile(
    String path,
    String destPath, {
    void Function(int done, int total)? onProgress,
  }) async => false;
}

class BridgeException implements Exception {
  BridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}
