import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/model_paths.dart';
import '../models/model_unpack.dart';

/// One selectable Whisper variant: a display entry + the pack it needs +
/// how to build [ModelPaths] from its unpacked files. Like the TTS voices,
/// packs download lazily when the variant is first selected and can be
/// deleted again (except the one in use — the assistant refuses those).
///
/// All variants are the sherpa-onnx int8 graphs (the same layout the
/// always-on tiny pack had before the picker existed): encoder + decoder +
/// tokens, VAD shared.
class AsrModel {
  final String id;
  final String label;
  final String note;
  final String sizeLabel;
  final ModelPack pack;

  /// Prefix of the onnx/tokens files inside [pack] ('tiny.en', 'base.en').
  final String filePrefix;

  const AsrModel({
    required this.id,
    required this.label,
    required this.note,
    required this.sizeLabel,
    required this.pack,
    required this.filePrefix,
  });

  String get dirName => pack.dirName;

  /// Absolute-path ASR wiring for the speech worker; VAD stays the shared
  /// Silero file `unpackModels` copies out of the APK.
  ModelPaths pathsIn(String modelsDir) => ModelPaths(
    whisperEncoder: p.join(modelsDir, dirName, '$filePrefix-encoder.int8.onnx'),
    whisperDecoder: p.join(modelsDir, dirName, '$filePrefix-decoder.int8.onnx'),
    whisperTokens: p.join(modelsDir, dirName, '$filePrefix-tokens.txt'),
    vadModel: p.join(modelsDir, 'silero_vad.onnx'),
  );

  Future<bool> installedIn(String modelsDir) => packInstalled(modelsDir, pack);

  Future<void> ensureIn(String modelsDir, {ModelProgress? onProgress}) =>
      ensurePack(modelsDir, pack, onProgress: onProgress);

  /// Delete the unpacked model files (frees disk; re-downloadable anytime).
  Future<void> deleteIn(String modelsDir) => deletePack(modelsDir, pack);
}

const _kOwnAsr =
    'https://github.com/yundddd/voice-agent/releases/download/models-v1';

/// Variants on offer, in display order. tiny.en is the default and the
/// first-run download: it cut a third of the round trip against base.en
/// on the bench, and base.en buys accuracy, not latency.
const asrModels = <AsrModel>[
  AsrModel(
    id: 'tiny.en',
    label: 'Whisper tiny.en',
    note:
        'The default: fastest to load and transcribe, good enough for '
        'short commands.',
    sizeLabel: '59 MB',
    filePrefix: 'tiny.en',
    pack: ModelPack(
      label: 'speech recognition (Whisper tiny.en)',
      url: '$_kOwnAsr/asr-whisper-tiny.en.zip',
      dirName: 'asr-whisper-tiny.en',
      markerFile: 'tiny.en-decoder.int8.onnx',
    ),
  ),
  AsrModel(
    id: 'base.en',
    label: 'Whisper base.en',
    note:
        'The larger variant: noticeably better on hard words and accents, '
        'at a slower load and a slightly slower transcript.',
    sizeLabel: '91 MB',
    filePrefix: 'base.en',
    pack: ModelPack(
      label: 'speech recognition (Whisper base.en)',
      url: '$_kOwnAsr/asr-whisper-base.en.zip',
      dirName: 'asr-whisper-base.en',
      markerFile: 'base.en-decoder.int8.onnx',
    ),
  ),
];

const _defaultAsrId = 'tiny.en';

AsrModel? asrModelById(String id) {
  for (final m in asrModels) {
    if (m.id == id) return m;
  }
  return null;
}

// ── Persisted choice ───────────────────────────────────────────────────────

class AsrPrefs {
  String modelId;

  AsrPrefs({this.modelId = _defaultAsrId});

  Map<String, Object> toJson() => {'model': modelId};

  static AsrPrefs fromJson(Map<String, Object?> j) => AsrPrefs(
    modelId: switch (j['model'] as String?) {
      null => _defaultAsrId,
      // The variant id replaced the old pack dir names ('tiny' was the
      // lone choice before the picker existed).
      'tiny' => _defaultAsrId,
      final m => m,
    },
  );
}

File _prefsFile(String modelsDir) => File(p.join(modelsDir, 'asr_prefs.json'));

Future<AsrPrefs> loadAsrPrefs(String modelsDir) async {
  try {
    final j = jsonDecode(await _prefsFile(modelsDir).readAsString());
    return AsrPrefs.fromJson(j as Map<String, Object?>);
  } catch (_) {
    return AsrPrefs(); // first run or unreadable: defaults
  }
}

Future<void> saveAsrPrefs(String modelsDir, AsrPrefs prefs) async {
  try {
    await _prefsFile(modelsDir).writeAsString(jsonEncode(prefs.toJson()));
  } catch (_) {} // best effort — never block model switching on persistence
}
