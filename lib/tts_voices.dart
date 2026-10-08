import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model_packs.dart';
import 'speech_worker.dart' show TtsSpec;

/// One selectable TTS voice: a display entry + the packs it needs + how to
/// build a [TtsSpec] from its unpacked files. All packs download lazily when
/// the voice is first selected, and can be deleted again (except the voice
/// currently in use — the assistant refuses those).
class TtsVoice {
  final String id;
  final String label;
  final String note;
  final String sizeLabel;
  final List<ModelPack> packs;

  /// Piper/VITS: model + tokens file names inside the first pack's dir.
  final String? vitsModel, vitsTokens;

  /// True = ZipVoice zero-shot cloning engine (needs a recorded reference).
  final bool isClone;

  /// True = NeuTTS (Neuphonic) engine: GGUF backbone + pure-Rust codec via
  /// our own FFI bridge, preset reference voices picked with [specIn]'s sid.
  final bool isNeutts;
  const TtsVoice({
    required this.id,
    required this.label,
    required this.note,
    required this.sizeLabel,
    required this.packs,
    this.vitsModel,
    this.vitsTokens = 'tokens.txt',
    this.isClone = false,
    this.isNeutts = false,
  });

  String get dirName => packs.first.dirName;

  static String _f(String modelsDir, String dirName, String file) =>
      p.join(modelsDir, dirName, file);

  /// Absolute-path job spec for the speech worker.
  ///
  /// [neuttsLib] overrides the FFI bridge library file (host tests; empty =
  /// dlopen the APK-packaged one).
  TtsSpec specIn(
    String modelsDir, {
    int sid = 0,
    String referenceWav = '',
    String referenceText = '',
    String neuttsLib = '',
  }) {
    if (isClone) {
      return TtsSpec.zipvoice(
        zipTokens: _f(modelsDir, dirName, 'tokens.txt'),
        zipEncoder: _f(modelsDir, dirName, 'encoder.int8.onnx'),
        zipDecoder: _f(modelsDir, dirName, 'decoder.int8.onnx'),
        zipDataDir: _f(modelsDir, dirName, 'espeak-ng-data'),
        zipLexicon: _f(modelsDir, dirName, 'lexicon.txt'),
        vocoder: _f(modelsDir, dirName, 'vocos_24khz.onnx'),
        referenceWav: referenceWav,
        referenceText: referenceText,
      );
    }
    if (isNeutts) {
      // The Rust bridge .so rides *inside the pack* (not the APK): it only
      // downloads when the voice is picked. espeakDataDir doubles as the
      // phonemizer's unpack destination; modelsDir is app-writable.
      return TtsSpec.neutts(
        neuttsGguf: _f(modelsDir, dirName, 'neutts-nano-Q4_0.gguf'),
        neuttsDecoder: _f(modelsDir, dirName, 'neucodec_decoder.safetensors'),
        neuttsVoices: _f(modelsDir, dirName, 'voices'),
        neuttsRefs: const ['dave', 'jo'],
        espeakDataDir: p.join(modelsDir, 'espeak-neutts'),
        neuttsLib: neuttsLib.isNotEmpty
            ? neuttsLib
            : _f(modelsDir, dirName, 'libneutts_bridge.so'),
        sid: sid,
      );
    }
    return TtsSpec.vits(
      vitsModel: _f(modelsDir, dirName, vitsModel!),
      vitsTokens: _f(modelsDir, dirName, vitsTokens!),
      espeakDataDir: _f(modelsDir, dirName, 'espeak-ng-data'),
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

const _modelsRelease =
    'https://github.com/yundddd/voice-agent/releases/download/models-v1';

/// Voices on offer, in display order. Lessac is the default and downloads on
/// first run; the rest are lazy (only fetched if the user picks them).
/// The int8 Piper voices are the small, fast variants (~20 MB each).
const ttsVoices = <TtsVoice>[
  TtsVoice(
    id: 'lessac',
    label: 'Lessac',
    note: 'American woman — the built-in default',
    sizeLabel: '65 MB',
    packs: [defaultTtsPack],
    vitsModel: 'en_US-lessac-medium.onnx',
  ),
  TtsVoice(
    id: 'ryan',
    label: 'Ryan',
    note: 'American man — expressive',
    sizeLabel: '20 MB',
    packs: [
      ModelPack(
        label: 'voice: Ryan',
        url: '$_k2fsaTts/vits-piper-en_US-ryan-medium-int8.tar.bz2',
        dirName: 'tts-ryan-medium-int8',
        markerFile: 'en_US-ryan-medium.onnx',
      ),
    ],
    vitsModel: 'en_US-ryan-medium.onnx',
  ),
  TtsVoice(
    id: 'amy',
    label: 'Amy',
    note: 'American woman — clear and quick',
    sizeLabel: '20 MB',
    packs: [
      ModelPack(
        label: 'voice: Amy',
        url: '$_k2fsaTts/vits-piper-en_US-amy-medium-int8.tar.bz2',
        dirName: 'tts-amy-medium-int8',
        markerFile: 'en_US-amy-medium.onnx',
      ),
    ],
    vitsModel: 'en_US-amy-medium.onnx',
  ),
  TtsVoice(
    id: 'alba',
    label: 'Alba',
    note: 'Scottish woman',
    sizeLabel: '20 MB',
    packs: [
      ModelPack(
        label: 'voice: Alba',
        url: '$_k2fsaTts/vits-piper-en_GB-alba-medium-int8.tar.bz2',
        dirName: 'tts-alba-medium-int8',
        markerFile: 'en_GB-alba-medium.onnx',
      ),
    ],
    vitsModel: 'en_GB-alba-medium.onnx',
  ),
  TtsVoice(
    id: 'libritts',
    label: 'LibriTTS-R',
    note: 'American man — pick any of 60 reader styles once loaded',
    sizeLabel: '22 MB',
    packs: [
      ModelPack(
        label: 'voice: LibriTTS-R',
        url: '$_k2fsaTts/vits-piper-en_US-libritts_r-medium-int8.tar.bz2',
        dirName: 'tts-libritts-r-medium-int8',
        markerFile: 'en_US-libritts_r-medium.onnx',
      ),
    ],
    vitsModel: 'en_US-libritts_r-medium.onnx',
  ),
  TtsVoice(
    id: 'clone',
    label: 'My voice',
    note: 'Cloned from a 10-second recording of you (ZipVoice)',
    sizeLabel: '155 MB',
    packs: [
      ModelPack(
        label: 'voice cloning engine',
        url:
            '$_k2fsaTts/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2',
        dirName: 'tts-zipvoice',
        markerFile: 'encoder.int8.onnx',
      ),
      ModelPack(
        label: 'cloning vocoder',
        url:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx',
        dirName: 'tts-zipvoice',
        markerFile: 'vocos_24khz.onnx',
        fileName: 'vocos_24khz.onnx', // raw file, not an archive
      ),
    ],
    isClone: true,
  ),
  TtsVoice(
    id: 'neutts',
    label: 'NeuTTS Nano',
    note:
        'Neuphonic neural codec voice — Dave/Jo styles once loaded; the '
        'Rust engine ships inside the download. Android (arm64) only.',
    sizeLabel: '~500 MB',
    packs: [
      ModelPack(
        label: 'voice: NeuTTS Nano (engine + voices)',
        url: '$_modelsRelease/neutts-nano-v1.zip',
        dirName: 'neutts-nano',
        markerFile: 'neutts-nano-Q4_0.gguf',
      ),
    ],
    isNeutts: true,
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

  /// Recorded clone sample: wav path + what the user said in it (filled in
  /// by Whisper right after recording — ZipVoice needs the transcript).
  String sampleWav, sampleText;

  TtsPrefs({
    this.voiceId = 'lessac',
    this.sid = 0,
    this.sampleWav = '',
    this.sampleText = '',
  });

  Map<String, Object> toJson() => {
    'voice': voiceId,
    'sid': sid,
    'sampleWav': sampleWav,
    'sampleText': sampleText,
  };

  static TtsPrefs fromJson(Map<String, Object?> j) => TtsPrefs(
    voiceId: j['voice'] as String? ?? 'lessac',
    sid: j['sid'] as int? ?? 0,
    sampleWav: j['sampleWav'] as String? ?? '',
    sampleText: j['sampleText'] as String? ?? '',
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
