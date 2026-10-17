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
  });
  String url, token;
  bool voice;

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
  };
  static BridgePrefs fromJson(Map<String, Object?> j) => BridgePrefs(
    url: (j['url'] as String? ?? BridgePrefs.defaultUrl).trim(),
    token: j['token'] as String? ?? BridgePrefs.defaultToken,
    voice: j['voice'] as bool? ?? true,
    narrate: j['narrate'] as bool? ?? false,
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
