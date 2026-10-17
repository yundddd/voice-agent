import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:piper_phonemize/piper_phonemize.dart' as piper;

import '../models/model_packs.dart';
import 'kokoro_voices.dart';
import 'speech_worker.dart' show TtsSpec;

/// One selectable TTS voice: a display entry + the packs it needs + how to
/// build a [TtsSpec] from its unpacked files. Packs download lazily when
/// the voice is first selected, and can be deleted again (except the voice
/// currently in use — the assistant refuses those).
class TtsVoice {
  final String id;
  final String label;
  final String note;
  final String sizeLabel;
  final List<ModelPack> packs;

  /// Multi-pack voices whose sid selects the pack (the student roster:
  /// one 9 MB graph per voice). Such a voice counts as installed when
  /// ANY of its packs is on disk, and only downloads the picked pack.
  final bool perSidPacks;

  const TtsVoice({
    required this.id,
    required this.label,
    required this.note,
    required this.sizeLabel,
    required this.packs,
    this.perSidPacks = false,
  });

  String get dirName => packs.first.dirName;

  static String _f(String modelsDir, String dirName, String file) =>
      p.join(modelsDir, dirName, file);

  /// Speaker-style names for this voice's engine, or null when the
  /// engine's roster comes from the device (Kokoro reports its own
  /// speaker count; the styles are its names).
  List<KokoroSpeaker>? get staticRoster => id == 'titl' ? titlRoster : null;

  /// Absolute-path job spec for the speech worker. Two engines live
  /// here: Kokoro (the teacher; the Piper/VITS, Pocket, ZipVoice and
  /// NeuTTS engines were retired when Kokoro won the A/B on sound) and
  /// the teacher-in-the-loop students — 8M single-voice distillations
  /// run on the same onnxruntime sherpa ships. For the students, [sid]
  /// indexes the parallel pack lists; for Kokoro it is the style id
  /// inside the one loaded graph.
  Future<TtsSpec> specIn(String modelsDir, {int sid = 0}) async {
    if (id == 'titl') {
      // espeak-ng data rides the piper_phonemize plugin (extracted once
      // into app support); graph + Kokoro vocab come from each pack.
      return titlSpec(modelsDir, await piper.extractEspeakNgData(), sid);
    }
    // English-only wiring (see TtsSpec.kokoro: the Dart binding drops
    // dictDir, so the zh jieba path can't load — us-en + gb-en lexicons
    // + espeak fallback cover everything we speak).
    return TtsSpec.kokoro(
      kokoroModel: _f(modelsDir, dirName, 'model.onnx'),
      kokoroVoices: _f(modelsDir, dirName, 'voices.bin'),
      kokoroTokens: _f(modelsDir, dirName, 'tokens.txt'),
      kokoroDataDir: _f(modelsDir, dirName, 'espeak-ng-data'),
      kokoroLexicon: [
        _f(modelsDir, dirName, 'lexicon-us-en.txt'),
        _f(modelsDir, dirName, 'lexicon-gb-en.txt'),
      ].join(','),
      sid: sid,
    );
  }

  /// The student spec for one picked style: parallel model/vocab lists
  /// in pack order (sid indexes them), one espeak voice per student
  /// (af_heart reads English, the Italian pair read Italian — their
  /// training language), and THE PICKED SID riding the spec: the
  /// worker's synth default reads it from there, and dropping it was
  /// how every style after the first silently spoke af_heart again.
  /// Pure (no plugin extraction) so tests can pin the wiring.
  TtsSpec titlSpec(String modelsDir, String espeakDataDir, int sid) =>
      TtsSpec.titl(
        titlModels: [
          for (final pack in packs) _f(modelsDir, pack.dirName, 'model.onnx'),
        ].join(','),
        titlVocabs: [
          for (final pack in packs) _f(modelsDir, pack.dirName, 'vocab.json'),
        ].join(','),
        espeakVoices: 'en-us,it,it',
        espeakDataDir: espeakDataDir,
        sid: sid,
      );

  Future<bool> installedIn(String modelsDir) async {
    for (final pack in packs) {
      final there = await packInstalled(modelsDir, pack);
      if (there && perSidPacks) return true;
      if (!there && !perSidPacks) return false;
    }
    return !perSidPacks;
  }

  Future<void> ensureIn(
    String modelsDir, {
    ModelProgress? onProgress,
    int? sid,
  }) async {
    if (perSidPacks && sid != null && sid < packs.length) {
      await ensurePack(modelsDir, packs[sid], onProgress: onProgress);
      return;
    }
    for (final pack in packs) {
      await ensurePack(modelsDir, pack, onProgress: onProgress);
    }
  }

  /// Delete the unpacked model files (frees disk; re-downloadable anytime).
  Future<void> deleteIn(String modelsDir) async {
    for (final pack in packs) {
      await deletePack(modelsDir, pack);
    }
  }
}

const _k2fsaTts =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

/// Voices on offer, in display order. Kokoro is the default and downloads on
/// first run.
const ttsVoices = <TtsVoice>[
  TtsVoice(
    id: 'titl',
    label: 'Students (8M)',
    note:
        'Faster and lighter than Kokoro, sounds close — but only '
        '3 speakers, not 54.',
    sizeLabel: '9 MB per style',
    perSidPacks: true,
    packs: [
      ModelPack(
        label: 'voice: TITL af_heart',
        url:
            'https://github.com/yundddd/voice-agent/releases/download/models-v1/tts-titl-af_heart.zip',
        dirName: 'tts-titl-af_heart',
        markerFile: 'model.onnx',
      ),
      ModelPack(
        label: 'voice: TITL if_sara',
        url:
            'https://github.com/yundddd/voice-agent/releases/download/models-v1/tts-titl-if_sara.zip',
        dirName: 'tts-titl-if_sara',
        markerFile: 'model.onnx',
      ),
      ModelPack(
        label: 'voice: TITL im_nicola',
        url:
            'https://github.com/yundddd/voice-agent/releases/download/models-v1/tts-titl-im_nicola.zip',
        dirName: 'tts-titl-im_nicola',
        markerFile: 'model.onnx',
      ),
    ],
  ),
  TtsVoice(
    id: 'kokoro',
    label: 'Kokoro v1.0',
    note:
        'The best-sounding voice in the app, with 54 speakers to pick '
        'from — slower and a big download.',
    sizeLabel: '334 MB',
    packs: [
      ModelPack(
        label: 'voice: Kokoro v1.0',
        url: '$_k2fsaTts/kokoro-multi-lang-v1_0.tar.bz2',
        dirName: 'kokoro-multi-lang-v1_0',
        markerFile: 'model.onnx',
      ),
    ],
  ),
];

TtsVoice? voiceById(String id) {
  for (final v in ttsVoices) {
    if (v.id == id) return v;
  }
  return null;
}

// ── Persisted choice ───────────────────────────────────────────────────────

class TtsPrefs {
  String voiceId;
  int sid;

  TtsPrefs({this.voiceId = 'kokoro', this.sid = 0});

  Map<String, Object> toJson() => {'voice': voiceId, 'sid': sid};

  static TtsPrefs fromJson(Map<String, Object?> j) => TtsPrefs(
    // 'titl-heart' was the lone af_heart voice before the roster grew.
    voiceId: switch (j['voice'] as String?) {
      null => 'kokoro',
      'titl-heart' => 'titl',
      final v => v,
    },
    sid: j['sid'] as int? ?? 0,
  );
}

File _prefsFile(String modelsDir) => File(p.join(modelsDir, 'tts_prefs.json'));

Future<TtsPrefs> loadTtsPrefs(String modelsDir) async {
  try {
    final j = jsonDecode(await _prefsFile(modelsDir).readAsString());
    return TtsPrefs.fromJson(j as Map<String, Object?>);
  } catch (_) {
    return TtsPrefs(); // first run or unreadable: defaults
  }
}

Future<void> saveTtsPrefs(String modelsDir, TtsPrefs prefs) async {
  try {
    await _prefsFile(modelsDir).writeAsString(jsonEncode(prefs.toJson()));
  } catch (_) {} // best effort — never block voice switching on persistence
}
