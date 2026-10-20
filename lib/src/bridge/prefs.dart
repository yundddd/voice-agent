/// Persisted bridge settings (mirrors the tts_prefs.json pattern).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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
    this.mode = 'conversation',
    this.eraBackfilled = false,
    this.sessionBackfilled = false,
    Map<String, String>? lastModels,
  }) : lastModels = lastModels ?? {};
  String url, token;
  bool voice;

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
  bool get configured => url.trim().isNotEmpty && token.isNotEmpty;

  Map<String, Object> toJson() => {
    'url': url,
    'token': token,
    'voice': voice,
    'narrate': narrate,
    'tts': tts,
    'mode': mode,
    'eraBackfilled': eraBackfilled,
    'sessionBackfilled': sessionBackfilled,
    'lastModels': {for (final e in lastModels.entries) e.key: e.value},
  };
  static BridgePrefs fromJson(Map<String, Object?> j) => BridgePrefs(
    url: (j['url'] as String? ?? BridgePrefs.defaultUrl).trim(),
    token: j['token'] as String? ?? BridgePrefs.defaultToken,
    voice: j['voice'] as bool? ?? true,
    narrate: j['narrate'] as bool? ?? false,
    tts: j['tts'] as bool? ?? true,
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
