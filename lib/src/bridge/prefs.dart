/// Persisted bridge settings (mirrors the tts_prefs.json pattern).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// +230: one session tab — a seat the user asked for and the app
/// remembers: which harness answers, which model, which working
/// folder, and every conversation id that has lived under the tab
/// (a replace-by-/new retires the list's tail, so history leaves with
/// the session it belongs to and the NEW id lands on return). The id
/// list, not a single id, is what the channel filters on: a tab that
/// has not spoken yet owns no id (its bubbles wear the pending
/// sentinel until the harness names the birth turn), and a tab whose
/// conversation outlives a bridge restart keeps wearing the same one.
class SessionTab {
  SessionTab({
    required this.harness,
    required this.dir,
    this.model,
    List<String>? sessionIds,
    this.createdMs = 0,
    this.hue,
    this.ctxIn,
    this.ctxWindow,
  }) : sessionIds = sessionIds ?? [];

  String harness; // 'claude' | 'opencode'
  String dir; // the working folder the seat was created with
  String? model; // a pick made AT creation (null = harness default)
  List<String> sessionIds;
  int createdMs;

  /// +271 (Tim): each session gets its own colour, RANDOM at creation
  /// and then STUCK — identity that survives restarts and reorders,
  /// unlike the +230 index-derived hue that changed a session's face
  /// every time a neighbour was deleted. Null on pre-+271 tabs:
  /// [hueOrDefault] falls back to the old golden-angle of the tab's
  /// index (existing installs keep the exact colours they wore at
  /// upgrade — a session's colour may be random, but it is never
  /// revised).
  int? hue;

  /// The random-but-distant picker: sample 24 hues and keep the one
  /// FARTHEST (circularly) from every hue already worn — neighbours
  /// and complements stay distinguishable without trusting luck.
  static int pickHue(List<int> taken, {Random? rng}) {
    final r = rng ?? Random();
    if (taken.isEmpty) return r.nextInt(360);
    var best = 0, bestDist = -1;
    for (var k = 0; k < 24; k++) {
      final h = r.nextInt(360);
      final d = taken.map((t) => _hueGap(h, t)).reduce((a, b) => a < b ? a : b);
      if (d > bestDist) {
        bestDist = d;
        best = h;
      }
    }
    return best;
  }

  static int _hueGap(int a, int b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  /// The colour this tab wears: its own, or the legacy index-derived
  /// one when it predates +271.
  int hueOrDefault(int index) => hue ?? (index * 137) % 360;

  /// +280 (Tim): the conversation's LAST KNOWN context sizes — what
  /// the bar read the last time this tab had a number. Like the hue,
  /// this belongs to the conversation and is persisted: swiping home
  /// wakes the bar wearing what the conversation last said instead of
  /// a 'measuring' placeholder, and every later /health or context
  /// frame UPDATES the cached reading as truth arrives. null = never
  /// spoken (a fresh tab, or a /new that blanked the conversation —
  /// a blanked conversation has no yesterday to fall back on).
  int? ctxIn;
  int? ctxWindow;

  /// The conversation this tab is CURRENTLY (the newest id it ever
  /// wore); null while the birth turn has not been named yet.
  String? get currentId => sessionIds.isEmpty ? null : sessionIds.last;

  /// The basename of the working folder — what the pill wears.
  String get label {
    final clean = dir.replaceAll(RegExp(r'[/\\]+$'), '');
    final i = clean.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? clean : clean.substring(i + 1);
  }

  Map<String, Object> toJson() => {
    'harness': harness,
    'dir': dir,
    if (model != null && model!.isNotEmpty) 'model': model!,
    'sessionIds': sessionIds,
    'createdMs': createdMs,
    // (the local promotion the guard needs: 'hue != null ? h : ...'
    // would still carry the field's nullability into the map)
    if (hue != null) 'hue': (hue as int),
    if (ctxIn != null) 'ctxIn': (ctxIn as int),
    if (ctxWindow != null) 'ctxWindow': (ctxWindow as int),
  };
  static SessionTab fromJson(Map<String, Object?> j) => SessionTab(
    harness: j['harness'] == 'opencode' ? 'opencode' : 'claude',
    dir: j['dir'] as String? ?? '',
    model: j['model'] is String ? j['model'] as String : null,
    sessionIds: [
      for (final s in (j['sessionIds'] as List? ?? const []))
        if (s is String && s.isNotEmpty) s,
    ],
    createdMs: (j['createdMs'] as num?)?.toInt() ?? 0,
    hue: j['hue'] is num ? (j['hue'] as num).toInt() % 360 : null,
    ctxIn: j['ctxIn'] is num ? (j['ctxIn'] as num).toInt() : null,
    ctxWindow: j['ctxWindow'] is num ? (j['ctxWindow'] as num).toInt() : null,
  );
}

/// The field defaults ship pointing at the dev machine's always-on demo
/// bridge (tailscale IP, port 8732, --token testtok): a fresh install
/// gets working command chips with zero typing — the Tailscale app on
/// the phone is the only prerequisite (or swap the url for the LAN ip).
/// Saved-but-explicitly-empty strings still mean "the user cleared it".
class BridgePrefs {
  static const defaultUrl = 'http://100.99.240.112:8732';
  static const defaultToken = 'testtok';

  /// When true (the factory setting) and the bridge is configured, spoken
  /// utterances go to the harness and its answer is spoken back; when
  /// false the app keeps parrot-repeating your speech like the original
  /// offline demo. Toggle: the switch on the Bridge screen.
  BridgePrefs({
    this.url = defaultUrl,
    this.token = defaultToken,
    this.voice = true,
    this.narrate = false,
    this.tts = true,
    this.debug = false,
    this.mode = 'conversation',
    this.eraBackfilled = false,
    this.sessionBackfilled = false,
    Map<String, String>? lastModels,
    List<SessionTab>? tabs,
    this.activeTab = 0,
    this.installed = false,
  }) : lastModels = lastModels ?? {},
       tabs = tabs ?? [];
  String url, token;
  bool voice;

  /// +230: the session TABS — the seats the user created (see
  /// [SessionTab]). Empty on a fresh install, which is exactly when
  /// the app asks harness/model/folder before the first session is
  /// born; an upgraded app seeds one tab from the bridge's live seat
  /// instead of interrupting anyone.
  List<SessionTab> tabs;

  /// Index into [tabs] — the tab whose thread the channel paints and
  /// the seat /talk speaks into. Clamped on load, repaired on every
  /// tab mutation (a deleted tab must not strand the index past the
  /// end).
  int activeTab;

  /// True whenever the prefs FILE parsed — i.e. this is not the first
  /// launch. The onboarding question rides on it: a fresh install is
  /// asked, an upgrade is not (its prefs predate the tab law, which
  /// the seed-from-/health path handles without a dialog).
  final bool installed;

  /// +218: the model EACH harness last answered with, as the app
  /// remembers it ('claude' → 'opus', 'opencode' →
  /// 'local/gemma-3'). The bridge reports a CURRENT; the app keeps a
  /// MEMORY: after a bridge restart (or before opencode's first step
  /// names itself) the row and the picker still know what you were
  /// using, the sheet can badge it, and one tap puts it back. Keyed by
  /// harness because eras keep their own habits — last time's claude
  /// model is not this time's opencode suggestion.
  Map<String, String> lastModels;

  /// +223: the one-time session migration's mark — the first /health
  /// that names a session adopts the pre-law history (era-stamped but
  /// session-null: born under the split, before the thread law) for
  /// the session already in use, ONCE. Later session-null arrivals
  /// are true prologue and must stay shared.
  bool sessionBackfilled;

  /// +214: the one-time chat migration's mark. The first /health that
  /// names an era files the harness of every UN-ERA'D legacy bubble
  /// (by its own timestamp against the bridge's harnessHistory when it
  /// can, by the observed era otherwise) and sets this — so the split
  /// happens once, not every launch, and so a bubble legitimately
  /// created un-era later (no bridge, offline prologue) is never
  /// re-stamped by a returning guess.
  bool eraBackfilled;

  /// The remembered interaction-mode tab: 'conversation' or 'pushToTalk'
  /// (the InteractionMode enum names). The app reopens the way the user
  /// left it — which mode they talk to their assistant in is a habit,
  /// not a per-launch accident.
  String mode;

  /// Master switch for the voice. Off (a test/degraded-network mode):
  /// replies land as text in the chat bubbles only — no synthesis, no
  /// audio, and the worker never demands a TTS model pack. The harness
  /// turn itself is unaffected; this gates exactly the speaker.
  bool tts;

  /// 'Narrate progress' (off from the factory: tool-call chatter is
  /// messy — the silent status text and the answer alone carry a turn).
  /// On, the harness's work becomes audible AS IT HAPPENS — every `tool`
  /// event the bridge emits at a step's start gets a spoken line, and a
  /// long silent step (a three-minute build) repeats its line as a
  /// still-at-it heartbeat, so a turn never sounds like dead air followed
  /// by one block of speech at the end.
  /// The turn loop reads this live (no wire involvement).
  bool narrate;

  /// +230: 'Debug tools' — the bug icon on the main bar retired into a
  /// setting, so its choice survives restarts like every other habit.
  /// On, the main screen shows the replay buttons, the hold-edge
  /// counter and the event log under the talk surface.
  bool debug;
  bool get configured => url.trim().isNotEmpty && token.isNotEmpty;

  Map<String, Object> toJson() => {
    'url': url,
    'token': token,
    'voice': voice,
    'narrate': narrate,
    'tts': tts,
    'debug': debug,
    'mode': mode,
    'eraBackfilled': eraBackfilled,
    'sessionBackfilled': sessionBackfilled,
    'lastModels': {for (final e in lastModels.entries) e.key: e.value},
    'tabs': [for (final t in tabs) t.toJson()],
    'activeTab': activeTab,
  };
  static BridgePrefs fromJson(Map<String, Object?> j) => BridgePrefs(
    url: (j['url'] as String? ?? BridgePrefs.defaultUrl).trim(),
    token: (j['token'] as String? ?? BridgePrefs.defaultToken),
    voice: j['voice'] as bool? ?? true,
    narrate: j['narrate'] as bool? ?? false,
    tts: j['tts'] as bool? ?? true,
    debug: j['debug'] as bool? ?? false,
    // Only the two real tabs; anything else (an enum rename, a hand
    // edit) falls back to the factory default.
    mode: j['mode'] == 'pushToTalk' ? 'pushToTalk' : 'conversation',
    eraBackfilled: j['eraBackfilled'] == true,
    sessionBackfilled: j['sessionBackfilled'] == true,
    lastModels: {
      for (final e in (j['lastModels'] as Map? ?? const {}).entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    },
    tabs: [
      for (final t in (j['tabs'] as List? ?? const []))
        if (t is Map<String, Object?>) SessionTab.fromJson(t),
    ],
    activeTab: (j['activeTab'] as num?)?.toInt() ?? 0,
    installed: true, // the file parsed — this is not the first launch
  );
}

File _prefsFile(String modelsDir) =>
    File(p.join(modelsDir, 'bridge_prefs.json'));

Future<BridgePrefs> loadBridgePrefs(String modelsDir) async {
  try {
    return BridgePrefs.fromJson(
      jsonDecode(await _prefsFile(modelsDir).readAsString())
          as Map<String, Object?>,
    );
  } catch (_) {
    return BridgePrefs();
  }
}

Future<void> saveBridgePrefs(String modelsDir, BridgePrefs prefs) async {
  try {
    await _prefsFile(modelsDir).writeAsString(jsonEncode(prefs.toJson()));
  } catch (_) {}
}
