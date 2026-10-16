import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:piper_phonemize/piper_phonemize.dart' as piper;

import 'model_packs.dart';
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

  const TtsVoice({
    required this.id,
    required this.label,
    required this.note,
    required this.sizeLabel,
    required this.packs,
  });

  String get dirName => packs.first.dirName;

  static String _f(String modelsDir, String dirName, String file) =>
      p.join(modelsDir, dirName, file);

  /// Absolute-path job spec for the speech worker. Two engines live
  /// here: Kokoro (the teacher; the Piper/VITS, Pocket, ZipVoice and
  /// NeuTTS engines were retired when Kokoro won the A/B on sound) and
  /// the teacher-in-the-loop student — an 8M single-voice distillation
  /// run on the same onnxruntime sherpa ships. [sid] is Kokoro-only.
  Future<TtsSpec> specIn(String modelsDir, {int sid = 0}) async {
    if (id == 'titl-heart') {
      // espeak-ng data rides the piper_phonemize plugin (extracted once
      // into app support); the graph + Kokoro vocab come from the pack.
      final dataDir = await piper.extractEspeakNgData();
      return TtsSpec.titl(
        titlModel: _f(modelsDir, dirName, 'model.onnx'),
        titlVocab: _f(modelsDir, dirName, 'vocab.json'),
        espeakDataDir: dataDir,
      );
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

  Future<bool> installedIn(String modelsDir) async {
    for (final pack in packs) {
      if (!await packInstalled(modelsDir, pack)) return false;
    }
    return true;
  }

  Future<void> ensureIn(String modelsDir, {ModelProgress? onProgress}) async {
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
    id: 'titl-heart',
    label: 'Heart (8M student)',
    note:
        'Teacher-in-the-loop: af_heart distilled out of Kokoro-82M into '
        'an 8M-parameter student — 9 MB, twenty-some times real-time on '
        'one CPU thread, UTMOS within 0.05 of the teacher (a faint '
        'metallic ring is the known tell). espeak-ng phonemes instead of '
        'Misaki; intelligible-first, A/B against the teacher.',
    sizeLabel: '9 MB',
    packs: [
      ModelPack(
        label: 'voice: TITL af_heart',
        url:
            'https://github.com/yundddd/voice-agent/releases/download/models-v1/tts-titl-af_heart.zip',
        dirName: 'tts-titl-af_heart',
        markerFile: 'model.onnx',
      ),
    ],
  ),
  TtsVoice(
    id: 'kokoro',
    label: 'Kokoro v1.0',
    note:
        '85M studio-grade reader — 54 voice styles once loaded. The best-'
        'sounding voice in the app (fp32; the int8 pack measured muddier '
        'and slower). Fetches from the k2-fsa release directly.',
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
    voiceId: j['voice'] as String? ?? 'kokoro',
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
