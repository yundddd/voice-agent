import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/model_paths.dart';
import '../models/model_unpack.dart';

/// Which sherpa-onnx runtime a pack's files are written for. [sherpaType] is
/// the string sherpa's `model_type` expects, so a variant never has to
/// repeat it.
enum AsrFamily {
  /// The int8 encoder + decoder pair, the layout the app shipped with.
  whisper('whisper'),

  /// Moonshine v2: an encoder + merged-decoder `.ort` pair, English-only
  /// packages under MIT.
  moonshine('moonshine'),

  /// Qwen3-ASR: an audio frontend + int8 encoder/decoder pair plus a BPE
  /// tokenizer directory. Multilingual, Apache-2.0, and by far the largest.
  qwen3('qwen3-asr');

  const AsrFamily(this.sherpaType);

  final String sherpaType;
}

/// One selectable ASR variant: a display entry + the pack it needs +
/// how to build [ModelPaths] from its unpacked files. Like the TTS voices,
/// packs download lazily when the variant is first selected and can be
/// deleted again (except the one in use — the assistant refuses those).
///
/// Every variant is a sherpa-onnx graph — the families differ only in which
/// files the pack holds and which config sherpa reads them from ([family]);
/// the Silero VAD file is shared by all of them.
class AsrModel {
  final String id;
  final String label;
  final String note;
  final String sizeLabel;
  final ModelPack pack;
  final AsrFamily family;

  /// Prefix of the onnx/tokens files inside [pack] ('tiny.en', 'base.en').
  /// Whisper-only: the Moonshine graphs are named by role, not by prefix.
  final String filePrefix;

  const AsrModel({
    required this.id,
    required this.label,
    required this.note,
    required this.sizeLabel,
    required this.pack,
    this.family = AsrFamily.whisper,
    this.filePrefix = '',
  });

  String get dirName => pack.dirName;

  /// Absolute-path ASR wiring for the speech worker; VAD stays the shared
  /// Silero file `unpackModels` copies out of the APK. The Whisper layout is
  /// the one the app shipped with before the picker existed (an existing
  /// install never re-downloads); the Moonshine layout is k2-fsa's own
  /// package, whose graphs sit unprefixed at the pack root, and the Qwen3
  /// pack keeps that same flat rule with one extra directory for its
  /// tokenizer.
  ModelPaths pathsIn(String modelsDir) {
    String f(String name) => p.join(modelsDir, dirName, name);
    final vad = p.join(modelsDir, 'silero_vad.onnx');
    return switch (family) {
      AsrFamily.whisper => ModelPaths(
        whisperEncoder: f('$filePrefix-encoder.int8.onnx'),
        whisperDecoder: f('$filePrefix-decoder.int8.onnx'),
        tokens: f('$filePrefix-tokens.txt'),
        vadModel: vad,
      ),
      AsrFamily.moonshine => ModelPaths(
        modelType: family.sherpaType,
        moonshineEncoder: f('encoder_model.ort'),
        moonshineMergedDecoder: f('decoder_model_merged.ort'),
        tokens: f('tokens.txt'),
        vadModel: vad,
      ),
      AsrFamily.qwen3 => ModelPaths(
        modelType: family.sherpaType,
        qwen3ConvFrontend: f('conv_frontend.onnx'),
        qwen3Encoder: f('encoder.int8.onnx'),
        qwen3Decoder: f('decoder.int8.onnx'),
        // A directory, not a file: sherpa builds the decoder prompt from the
        // BPE vocab and merges inside it, so this family has no tokens file.
        qwen3Tokenizer: f('tokenizer'),
        vadModel: vad,
      ),
    };
  }

  Future<bool> installedIn(String modelsDir) => packInstalled(modelsDir, pack);

  Future<void> ensureIn(String modelsDir, {ModelProgress? onProgress}) =>
      ensurePack(modelsDir, pack, onProgress: onProgress);

  /// Delete the unpacked model files (frees disk; re-downloadable anytime).
  Future<void> deleteIn(String modelsDir) => deletePack(modelsDir, pack);
}

const _kOwnAsr =
    'https://github.com/yundddd/voice-agent/releases/download/models-v1';

// The Moonshine graphs come straight from k2-fsa's own release rather than
// being re-hosted under our models-v1: the dated package name is what pins
// the bytes, and re-shipping somebody else's quantized graph under our own
// release only hides which vintage is on the phone. The Qwen3 pack does get
// re-hosted, for one reason — k2-fsa ships it as a tar.bz2, which this
// unpacker inflates whole in memory, and a gigabyte archive is exactly where
// a phone dies; as a zip the same bytes stream member-by-member from disk.
const _kSherpaAsr =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

/// Variants on offer, in display order. tiny.en is the default and the
/// first-run download: it cut a third of the round trip against base.en
/// on the bench, and base.en buys accuracy, not latency.
///
/// The Moonshine pair below is the accuracy-per-megabyte upgrade: the v2
/// English graphs beat Whisper tiny and base on Moonshine's own benchmarks
/// from a smaller download. Both stay VAD-paced — sherpa-onnx declined
/// Moonshine's *streaming* models as too expensive to run (k2-fsa/sherpa-onnx
/// #3558), so a real-time feel here comes from the shared Silero gate cutting
/// the clip, exactly as it does for Whisper.
///
/// Qwen3-ASR at the end of the list is the other direction: accuracy over
/// footprint. On its pack's own noisy English clips it measured 12.9 and 22.9
/// percent word error where Whisper tiny took 29 and 75 and Moonshine tiny
/// heard nothing at all — for 804 MB and 0.12 times real time on a desktop
/// CPU at four threads. Opt-in, and it has to earn its space.
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
  AsrModel(
    id: 'moonshine-tiny.en',
    label: 'Moonshine tiny.en',
    note:
        'Smaller than Whisper tiny and clearer on short commands. English '
        'only; pauses end the transcript a touch sooner.',
    sizeLabel: '28 MB',
    family: AsrFamily.moonshine,
    pack: ModelPack(
      label: 'speech recognition (Moonshine tiny.en)',
      url:
          '$_kSherpaAsr/sherpa-onnx-moonshine-tiny-en-quantized-'
          '2026-02-27.tar.bz2',
      dirName: 'asr-moonshine-tiny.en',
      markerFile: 'decoder_model_merged.ort',
    ),
  ),
  AsrModel(
    id: 'moonshine-base.en',
    label: 'Moonshine base.en',
    note:
        'The accuracy pick: beats Whisper base on hard words and accents at '
        'a third of the download, for a slower transcript.',
    sizeLabel: '106 MB',
    family: AsrFamily.moonshine,
    pack: ModelPack(
      label: 'speech recognition (Moonshine base.en)',
      url:
          '$_kSherpaAsr/sherpa-onnx-moonshine-base-en-quantized-'
          '2026-02-27.tar.bz2',
      dirName: 'asr-moonshine-base.en',
      markerFile: 'decoder_model_merged.ort',
    ),
  ),
  AsrModel(
    id: 'qwen3-0.6b',
    label: 'Qwen3-ASR 0.6B',
    note:
        'The accuracy pick: still writes through background noise the others '
        'give up on, in 30 languages. A huge download and the slowest '
        'transcript — install it on Wi-Fi, and expect it to earn its space.',
    sizeLabel: '804 MB',
    family: AsrFamily.qwen3,
    pack: ModelPack(
      label: 'speech recognition (Qwen3-ASR 0.6B)',
      url: '$_kOwnAsr/asr-qwen3-0.6b.zip',
      dirName: 'asr-qwen3-0.6b',
      // The 756 MB graph, written last by the unpacker: its presence alone
      // means every other file arrived too.
      markerFile: 'decoder.int8.onnx',
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
