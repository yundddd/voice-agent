/// +299: the BRIDGE AS THE PHONE SEES IT — a behavioural fake of
/// tool/claude_bridge.mjs for multi-session scenario walks (docs/
/// claude-code-bridge.md, docs/wire-v2-protocol.md).
///
/// The old FakeHarness records calls and hands back whatever frames a
/// test pushes at it, so every walk hand-authors its own frame sequence
/// — and the bridge's BEHAVIOUR (a prompt parks behind a live turn; a
/// message with tool_use goes final with openTools empty and relays
/// `settled`; a run_in_background shell reports later through a
/// `finished` frame and can speak a whole proactive report turn; every
/// frame wears `_sess`/`_mid`/`_turn`/`_ts`) lives in the test author's
/// head instead of the rig. That is how the same multi-session tape —
/// background sleep, swipe, receipt, report — kept finding a NEW leak
/// (the +297 meter, the +297 pin, the +298 marker, the +299 rename)
/// past 540 green unit walks: nobody could say "run the field test"
/// without a phone.
///
/// This file says it. Tests speak in CONVERSATION moves —
/// [prompt]/[toolStep]/[backgrounded]/[complete]/[reportTurn] — and
/// the fake relays what the real bridge relays, stamped the way it
/// stamps it, into ONE shared ring with per-frame mids, a per-phone
/// heard-ledger truth (`missed` = never-acked mids) and a focus that
/// moves on /seat. The wire is the poll transport (proto 2 + /health
/// `poll`) — the shape the field phones actually run.
///
/// What it deliberately does NOT model (honest edges): the streaming
/// /talk view (talk() serves the same ring, so stream-transport walks
/// stay in the older rigs), the ring cap, steer folding, the context-
/// full refusal, --resume/backends, and the heartbeat pings. Adding a
/// law here when a scenario needs it is the intended growth.
library;

import 'dart:async';

import 'package:voice_agent/src/bridge/bridge_event.dart';
import 'package:voice_agent/src/bridge/gateway.dart';

final class ScenarioConv {
  ScenarioConv(this.dir, this.uuid);

  final String dir;

  /// The app uuid — the only name the wire speaks (+295).
  final String uuid;

  bool turnOpen = false;
  int? turnId;

  /// The prompt parked behind the open turn (+ the id reserved for it
  /// at POST time — its frames will wear this _turn when it runs).
  String? parkedText;
  int? parkedTurn;
  bool parkedInterrupt = true;

  /// The conversation's running context tally (what the bar reads).
  int inTok = 19000;

  /// Foreground tools this conversation has running (message_stop
  /// with this EMPTY is what relays `settled`).
  final openTools = <String>[];

  /// The bridge's TURN EPOCH (claude_bridge's turn bookkeeping):
  /// set when an interrupt-flag prompt cut the previous turn — the
  /// press's own detach /stop, arriving a beat late, answers that
  /// cut and must NOT kill the prompt that just opened. The phone
  /// fires the funnel /stop and the /talk POST in the same breath;
  /// the arrival order is a race, the guard is the law.
  bool interruptedHere = false;
  int? lastTurnId;

  /// run_in_background shells owed their `finished` frame — the count
  /// /health reports as `detached` while the seat is this record.
  final bgTools = <String>[];

  /// Tools cut by /stop: the receipt still comes, `cancelled`.
  final cutTools = <String>[];

  /// True once any tool_use was relayed in the CURRENT message — the
  /// settled verdict is a message farewell, not a turn farewell.
  bool hadToolUse = false;
}

final class ScenarioBridge implements HarnessGateway {
  ScenarioBridge();

  // The clock lives in the RIG's phone-time (the walks' clock is
  // DateTime(2026,1,1,12)): _ts stamps, the watermark's focusAt and
  // the wireTag ages then compare honestly, exactly as a calibrated
  // phone and bridge do on the tape.
  static final int _t0 = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
  int _now = _t0;
  int _mid = _t0; // one message counter, like msgSeq
  int _seq = _t0; // ring sequence
  int _turn = 900000; // turn-id reserve
  int _n = 0;

  /// Everything relayed, in order — {seq, ev, data} (the /poll page
  /// shape; frames keep their stamped maps, tests inspect them).
  final ring = <Map<String, Object?>>[];

  /// mids the phone has ACKED through /heard — `missed` and the
  /// attach replay read exactly this set (received means acked).
  final acked = <int>{};

  /// The bridge's backlog MEMORY — 'says, markers, finished receipts'
  /// (+1050's set, and the turn's `done`, whose loss would strand a
  /// pump): the frames a drain must be able to re-deliver. A step
  /// line and a context tally are regenerable noise and never owed.
  final _owed = <int>{};
  final convs = <String, ScenarioConv>{};
  String? focusSid;

  /// When true, /poll answers null (the wire is down; the AGENT is
  /// not) — the +D blackout walk flips this.
  bool blackout = false;

  /// The same null answer for /health too — the whole bridge
  /// unreachable (a handoff, a restart), not merely a dead carrier.
  bool quiet = false;

  /// Every /heard batch, in order (tests assert who owes what).
  final heardBatches = <List<int>>[];

  /// The sid of the last /stop (+257's addressed cut).
  String? lastStopSid;
  int stops = 0;
  int resets = 0;
  bool lastInterrupt = true;
  bool lastCutTool = false;
  String model = 'default';

  final _tails = <StreamController<BridgeEvent>>[]; // attach/talk views

  // ── the scenario author's verbs (what the HARNESS does) ───────────────

  ScenarioConv newConv(String dir) {
    final c = ScenarioConv(dir, 'sc-$dir-${_n++}');
    convs[c.uuid] = c;
    return c;
  }

  ScenarioConv conv(String dirOrUuid) =>
      convs[dirOrUuid] ?? convs.values.firstWhere((c) => c.dir == dirOrUuid);

  /// The harness ran a foreground tool this turn (tool_use relayed).
  void toolStep(String dirOrUuid, String name, String detail) {
    final r = conv(dirOrUuid);
    r.hadToolUse = true;
    r.openTools.add('$name $detail');
    _relay(r, 'tool', {'name': name, 'detail': detail});
  }

  /// Its result landed — no frame (the phone's step line aged out
  /// honestly; the next say/done speaks for the round).
  void toolResult(String dirOrUuid, String label) {
    conv(dirOrUuid).openTools.remove(label);
  }

  /// Bash run_in_background: the `backgrounded` frame lights the
  /// bottom line; the ledger counts it in `detached`.
  void backgrounded(String dirOrUuid, String label) {
    final r = conv(dirOrUuid);
    r.hadToolUse = true;
    r.bgTools.add(label);
    _relay(r, 'tool', {'name': 'backgrounded', 'detail': label});
  }

  void say(String dirOrUuid, String text) =>
      _relay(conv(dirOrUuid), 'say', {'text': text});

  /// The bar's truth + the +253 identity stamp the phone learns from.
  void contextGrowth(String dirOrUuid, int inTok, {int window = 200000}) {
    final r = conv(dirOrUuid);
    _relay(r, 'context', {
      'in': inTok,
      'window': window,
      'session': r.uuid, // the ctxSession name, like the real relay
    });
  }

  /// The turn's result frame lands: message farewell (the `settled`
  /// relay ONLY when the message carried tool_use and no foreground
  /// tool is still open — bgTools do not block it, the +297 law), the
  /// `done` wearing the turn id — and the parked pickup, if any (the
  /// 'started' marker wearing the PARKED prompt's reserved id).
  void endTurn(String dirOrUuid, {bool pickup = true, bool settled = true}) {
    final r = conv(dirOrUuid);
    if (r.turnOpen) {
      if (settled) messageFarewell(r.dir);
      _relay(r, 'done', {'costUsd': 0.01, 'isError': false});
      r.turnOpen = false;
      r.hadToolUse = false;
      r.interruptedHere = false;
    }
    if (pickup) this.pickup(r.dir);
  }

  /// JUST the message farewell — `tool tokens kind:settled` — the
  /// frame a message with tool_use relays when its foreground tools
  /// are all done (bgTools do not block it). A no-delta fake has no
  /// natural message_stop mid-turn, so walks name it when the
  /// stream's shape calls for one (the +297 foreign-settled walks).
  void messageFarewell(String dirOrUuid) {
    final r = conv(dirOrUuid);
    if (r.hadToolUse && r.openTools.isEmpty) {
      _relay(r, 'tool', {'name': 'tokens', 'kind': 'settled'});
    }
  }

  /// The parked prompt's round begins: the +81 'started' marker the
  /// phone's pin waits for. Split out of endTurn so a walk can stand
  /// between the farewell and the pickup — the exact gap the +296
  /// tape died in (settled and done land, the box must not blink).
  void pickup(String dirOrUuid) {
    final r = conv(dirOrUuid);
    if (r.parkedText == null) return;
    final text = r.parkedText!;
    r.turnId = r.parkedTurn;
    r.turnOpen = true;
    r.parkedText = null;
    r.parkedTurn = null;
    _relay(r, 'tool', {'name': 'started', 'detail': _clip(text)});
  }

  /// A background shell finished. Its `finished` receipt relays —
  /// and the harness, reporting in unprompted, may speak a whole
  /// PROACTIVE turn over it (new turn id, the tape's [proactive]).
  void complete(
    String dirOrUuid,
    String label, {
    bool cancelled = false,
    List<String> report = const [],
  }) {
    final r = conv(dirOrUuid);
    (cancelled ? r.cutTools : r.bgTools).remove(label);
    r.openTools.remove(label);
    _relay(r, 'tool', {
      'name': 'finished',
      'detail': label,
      'id': 'task-${label.hashCode & 0xffffff}',
      if (cancelled) 'kind': 'cancelled',
    });
    if (report.isEmpty) return;
    turnOpen(r);
    for (final line in report) {
      say(r.dir, line);
    }
    endTurn(r.dir);
  }

  /// Opens a harness-initiated turn (a report stream).
  void turnOpen(ScenarioConv r) {
    r.turnOpen = true;
    r.turnId = ++_turn;
    contextGrowth(r.dir, r.inTok += 500);
  }

  // ── the phone's doors (HarnessGateway) ────────────────────────────────

  @override
  int Function()? journalPort;

  void _relay(ScenarioConv r, String ev, Map<String, Object?> data) {
    // The +295/+274 identity law at the one door: every frame is born
    // under its record, wearing uuid/mid/turn/ts.
    data['_ts'] ??= _now;
    data['_sess'] ??= r.uuid;
    data['_mid'] ??= ++_mid;
    data['_turn'] ??= r.turnId ?? 0;
    final mid = data['_mid'] as int;
    final name = data['name'];
    // The backlog memory, and its discharge, in the same breath:
    // any view LIVE at relay time gets the frame on its stream, and
    // the phone's law (bridge_turn 553) commits EVERY delivered
    // frame except a refused foreign say — so the debt only stands
    // when nobody was home to hear it. (The field's refused-say
    // shape is reproduced exactly when the focus is mid-turn: the
    // say reaches the foreign pump, is not taken, and stays owed.)
    // The backlog memory (says, markers, receipts, farewells). The
    // discharge is the phone's own: bridge_turn 553 commits EVERY
    // frame its pump consumes except a refused foreign say — so
    // `missed` measures exactly what that law leaves standing.
    if (ev == 'say' ||
        ev == 'done' ||
        (ev == 'tool' && (name == 'started' || name == 'finished'))) {
      _owed.add(mid);
    }
    ring.add({'seq': ++_seq, 'ev': ev, 'data': data});
    final event = BridgeEvent.parseMap(ev, data);
    for (final t in _tails.toList()) {
      if (!t.isClosed) t.add(event);
    }
  }

  int _begin(String text, bool interrupt, bool cutTool) {
    final r = convs[focusSid]!;
    lastInterrupt = interrupt;
    lastCutTool = cutTool;
    final id = ++_turn;
    if (r.turnOpen) {
      // The per-record queue (+257): a prompt to a conversation that
      // already holds the floor PARKS — one slot, the bridge's word on
      // the ring, pickup at the turn's farewell. Interrupt cuts only a
      // mere thinking turn; an open tool keeps the floor (the press
      // queuing behind its own answer).
      if (interrupt && r.openTools.isEmpty && r.bgTools.isEmpty) {
        _relay(r, 'done', {'isError': false, 'interrupted': true});
        r.turnOpen = false;
        r.interruptedHere = true; // the press's own late /stop bows out
      } else {
        r.parkedText = text;
        r.parkedTurn = id;
        r.parkedInterrupt = interrupt;
        _relay(r, 'tool', {
          'name': 'queued',
          'detail': 'one moment — finishing the current task first',
          '_turn': r.turnId,
        });
        return id;
      }
    }
    r.turnOpen = true;
    r.turnId = id;
    r.lastTurnId = id;
    _relay(r, 'tool', {'name': 'started', 'detail': _clip(text)});
    // The real relay carries a context tally with every turn (the
    // tape's 'bridge context N/M' lines) — and it is the frame the
    // +253 learning and the +290 wear read. A walk that never saw it
    // leaves the pump nameless and the paperwork parks in pending.
    contextGrowth(r.dir, r.inTok += 500);
    return id;
  }

  @override
  Stream<BridgeEvent> talk(
    String text, {
    bool interrupt = true,
    bool cutTool = false,
    void Function()? onActivity,
  }) {
    final from = ring.length;
    _begin(text, interrupt, cutTool);
    final ctl = StreamController<BridgeEvent>();
    _tails.add(ctl);
    for (final f in ring.sublist(from)) {
      ctl.add(BridgeEvent.parseMap('${f['ev']}', f['data'] as Map));
    }
    return ctl.stream;
  }

  @override
  Future<int> talkPoll(
    String text, {
    bool interrupt = true,
    bool cutTool = false,
  }) async => _begin(text, interrupt, cutTool);

  @override
  Future<bool> heard(List<int> mids) async {
    if (mids.isEmpty) return true;
    heardBatches.add(List.of(mids));
    acked.addAll(mids);
    _owed.removeAll(mids);
    return true;
  }

  @override
  Future<Map<String, Object>?> poll(int since) async {
    if (blackout || quiet) return null;
    return {
      'ok': true,
      'seq': _seq,
      'events': [
        for (final f in ring)
          if ((f['seq'] as int) > since) f,
      ],
    };
  }

  @override
  Stream<BridgeEvent> attach({void Function()? onActivity}) {
    // /attach STEALS the heard view: the backlog first (every frame
    // the phone never acked, in ring order), then live.
    final ctl = StreamController<BridgeEvent>();
    _tails.add(ctl);
    ctl.onCancel = () => _tails.remove(ctl);
    for (final f in ring) {
      final d = f['data'] as Map;
      final mid = d['_mid'] as int;
      if (_owed.contains(mid) &&
          !acked.contains(mid) &&
          d['_sess'] == focusSid) {
        ctl.add(BridgeEvent.parseMap('${f['ev']}', d));
      }
    }
    return ctl.stream;
  }

  @override
  Future<void> stop({String? sid}) async {
    final r = sid == null ? convs[focusSid]! : conv(sid);
    // The TURN EPOCH guard: an interrupt press detaches (funnel
    // /stop) AND POSTs (interrupt flag) in the same breath — if the
    // /talk lands first, the cut already happened via the flag, and
    // the late stop answers the previous turn, not the prompt that
    // replaced it. Same-era stops cut for real.
    if (r.interruptedHere) {
      r.interruptedHere = false;
      return;
    }
    if (r.turnOpen) {
      stops++;
      lastStopSid = sid ?? focusSid;
      _relay(r, 'done', {'isError': false, 'interrupted': true});
      r.turnOpen = false;
      r.cutTools.addAll(r.openTools);
      r.openTools.clear();
    }
  }

  @override
  Future<void> reset() async {
    // /new FORGETS but the identity holds (+295): the record keeps
    // its uuid; the floor and ledgers wipe.
    resets++;
    final r = convs[focusSid];
    if (r == null) return;
    r.turnOpen = false;
    r.parkedText = null;
    r.parkedTurn = null;
    r.openTools.clear();
    r.bgTools.clear();
    r.hadToolUse = false;
  }

  @override
  Future<String?> health() async => null;

  @override
  Future<Map<String, Object>?> healthInfo() async {
    if (quiet) return null;
    final f = focusSid == null ? null : convs[focusSid];
    // The tape's two-phase honesty (16:51:35 / 16:51:41): /health
    // counts the BACKLOG OF THE RECORD IT NAMES — a conversation's
    // owed words never refuse a move AWAY from the tab that owes
    // them; they stop a move ONTO it only once the seat's own glance
    // speaks for them (the landing probe finds them and drains).
    var missed = 0;
    for (final fr in ring) {
      final d = fr['data'] as Map;
      if (d['_sess'] == f?.uuid &&
          _owed.contains(d['_mid']) &&
          !acked.contains(d['_mid'])) {
        missed++;
      }
    }
    return <String, Object?>{
      'ok': true,
      'proto': 2,
      'now': _now, // the calibration the transport's guard expects
      'seat': true, // the +230 capability flag the tabs' law reads
      // +303: the uuid-at-birth declaration (real bridge, /health) —
      // the phone's law reads it and may not learn names from the
      // global sessionId line any more.
      'uuidAtBirth': true,
      'harness': 'claude',
      'poll': {'ring': _seq}, // the handshake that arms the transport
      'sessionId': f?.uuid,
      'turnOpen': f?.turnOpen ?? false,
      'queued': f?.parkedText != null,
      'detached': f?.bgTools.length ?? 0, // the SEAT's owed shells
      'missed': missed,
      'model': model,
      'dir': f?.dir,
      'sessions': [
        // +253's ledger rows, in app names — the machine's honest
        // report of who holds the floor (this rig: the seat).
        if (f != null)
          {
            'sid': f.uuid,
            'backendSid': 'backend-${f.uuid}',
            'turnOpen': f.turnOpen,
            'contextIn': 1000,
            'contextWindow': 200000,
          },
      ],
    }.cast<String, Object>(); // nulls ride, like the real JSON
  }

  @override
  Future<bool> pushJournal(Map<String, Object> envelope) async => true;

  @override
  Future<Map<String, Object>?> dirs({String? path}) async => {
    'dirs': [for (final c in convs.values) c.dir],
  };

  @override
  Future<String?> setDir(String path) async => null;

  @override
  Future<Map<String, Object>?> models({String? harness, String? dir}) async => {
    'current': 'default',
    'models': ['default'],
  };

  @override
  Future<String?> setModel(String id) async {
    model = id;
    return null;
  }

  @override
  Future<Map<String, Object>?> seat({
    String? harness,
    String? dir,
    String? model,
    String? sessionId,
    bool fresh = false,
  }) async {
    // +295's resolution, scene-sized: a spoken uuid re-seats (the
    // phone's own tab id), a dir adopts the conversation that lives
    // there, and only a truly fresh sheet mints a new record.
    ScenarioConv? c;
    if (sessionId != null) c = convs[sessionId];
    if (c == null && dir != null) c = _byDir(dir);
    if (c == null && dir != null) {
      c = ScenarioConv(dir, sessionId ?? 'sc-$dir-${_n++}');
      convs[c.uuid] = c;
    }
    if (c == null && fresh) {
      c = ScenarioConv(dir ?? '/anon', sessionId ?? 'sc-new-${_n++}');
      convs[c.uuid] = c;
    }
    if (c == null) return {'ok': false, 'error': 'no such session tab'};
    focusSid = c.uuid;
    return {
      'ok': true,
      'sessionId': c.uuid,
      'harness': harness ?? 'claude',
      'dir': c.dir,
      'model': model ?? this.model,
    };
  }

  @override
  Future<String?> setHarness(String to) async => null;

  @override
  Future<bool> downloadFile(
    String url,
    String dest, {
    void Function(int received, int total)? onProgress,
  }) async => true;

  ScenarioConv? _byDir(String dir) {
    for (final c in convs.values) {
      if (c.dir == dir) return c;
    }
    return null;
  }

  /// mids the FOCUSED conversation still owes the phone — what
  /// /health counts as `missed` and what an attach re-delivers.
  List<int> get owedMids => [
    for (final f in ring)
      if (_owed.contains((f['data'] as Map)['_mid']) &&
          !acked.contains((f['data'] as Map)['_mid']) &&
          (f['data'] as Map)['_sess'] == focusSid)
        (f['data'] as Map)['_mid'] as int,
  ];

  /// Let the virtual clock move (the _ts stamp follows).
  void tick(int ms) => _now += ms;

  static String _clip(String s) => s.length <= 60 ? s : s.substring(0, 60);
}
