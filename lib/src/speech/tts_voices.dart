import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/model_packs.dart';
import 'espeak_exec.dart';
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

  /// Packs every style of this voice shares (for the students: the
  /// Kokoro lexicon files their espeak-free front-end reads). Shared
  /// packs download with the first style and never gate 'installed' —
  /// without them the English path silently falls back to espeak.
  final List<ModelPack> sharedPacks;

  const TtsVoice({
    required this.id,
    required this.label,
    required this.note,
    required this.sizeLabel,
    required this.packs,
    this.perSidPacks = false,
    this.sharedPacks = const [],
  });

  String get dirName => packs.first.dirName;

  static String _f(String modelsDir, String dirName, String file) =>
      p.join(modelsDir, dirName, file);

  /// Speaker-style names for this voice's engine, or null when the
  /// engine's roster comes from the device (Kokoro reports its own
  /// speaker count; the styles are its names).
  List<KokoroSpeaker>? get staticRoster => switch (id) {
    'titl' => titlRoster,
    'pocket' => pocketRoster,
    _ => null,
  };

  /// Pocket TTS preset references (`voices/<name>.wav` in the pack, in
  /// slider order — the same order as the pack script's ORDER list and
  /// pocketRoster above; sid indexes this list). Sids 0–5 are frozen (a
  /// v2/v3 install's picked voice must keep pointing at the same person);
  /// the v4 lineup appends ten more with the references padded to end on
  /// silence. Genders were measured from median F0, not read off the
  /// names — marius is female, george male.
  static const pocketRefs = [
    'jane',
    'anna',
    'jean',
    'michael',
    'alba',
    'bill_boerst',
    'azelma',
    'eve',
    'fantine',
    'mary',
    'vera',
    'marius',
    'charles',
    'george',
    'javert',
    'paul',
  ];

  /// Absolute-path job spec for the speech worker. Three engines live
  /// here: Kokoro (the teacher; the Piper/VITS, ZipVoice and NeuTTS
  /// engines were retired when Kokoro won the A/B on sound), the
  /// teacher-in-the-loop students — 8M single-voice distillations run
  /// on the same onnxruntime sherpa ships — and Pocket (Kyutai's
  /// zero-shot cloner, back by popular demand: sixteen presets ride the
  /// same slider and the engine was already inside sherpa). For the
  /// students, [sid] indexes the parallel pack lists; for Kokoro it is
  /// the style id inside the one loaded graph; for Pocket it picks a
  /// reference wav.
  Future<TtsSpec> specIn(String modelsDir, {int sid = 0}) async {
    if (id == 'pocket') {
      // Only the references THIS platform's pack actually carries (iOS
      // serves the six-voice v2 pack, Android/desktop the sixteen-voice
      // v4 one) — the slider reports what can speak. A pack that hasn't
      // downloaded yet (or a test's bare /models) keeps the full list,
      // so the roster never collapses before the files land.
      final paths = [
        for (final ref in pocketRefs)
          _f(modelsDir, dirName, 'voices/$ref.wav'),
      ];
      final there = paths.where((f) => File(f).existsSync()).toList();
      return TtsSpec.pocket(
        pocketLmFlow: _f(modelsDir, dirName, 'lm_flow.onnx'),
        pocketLmMain: _f(modelsDir, dirName, 'lm_main.onnx'),
        pocketEncoder: _f(modelsDir, dirName, 'encoder.onnx'),
        pocketDecoder: _f(modelsDir, dirName, 'decoder.onnx'),
        pocketTextConditioner: _f(modelsDir, dirName, 'text_conditioner.onnx'),
        pocketVocabJson: _f(modelsDir, dirName, 'vocab.json'),
        pocketTokenScoresJson: _f(modelsDir, dirName, 'token_scores.json'),
        pocketRefs: there.isEmpty ? paths : there,
        sid: sid,
      );
    }
    if (id == 'titl') {
      // +238: the students' PRIMARY front-end is espeak-ng as a child
      // process — GPL at arm's length, letter names for APK and TTS
      // back where the dictionary ladder had none. The nativeLibraryDir
      // (the only exec-able dir on modern Android) comes from the
      // platform; where it answers '' (desktop, tests) the lexicon
      // ladder from +224 stays the fallback voice.
      final libDir = await nativeLibDir();
      return titlSpec(
        modelsDir,
        sid,
        espeakBin: libDir.isEmpty ? '' : p.join(libDir, espeakLibName),
        espeakDataDir: p.join(modelsDir, espeakDataDirName),
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

  /// The student spec for one picked style: parallel model/vocab lists
  /// in pack order (sid indexes them), and THE PICKED SID riding the
  /// spec: the worker's synth default reads it from there, and dropping
  /// it was how every style after the first silently spoke af_heart
  /// again. Pure (no I/O) so tests can pin the wiring.
  ///
  /// The lexicon candidates list prefers the student's own shared pack,
  /// then the teacher pack's copies (dirName literal matches the
  /// 'kokoro' voice below) — first readable file wins per word, so
  /// whichever packs a device happens to have are enough, and the
  /// shared pack only downloads when neither file is there yet.
  TtsSpec titlSpec(
    String modelsDir,
    int sid, {
    String espeakBin = '',
    String espeakDataDir = '',
  }) => TtsSpec.titl(
    titlModels: [
      for (final pack in packs) _f(modelsDir, pack.dirName, 'model.onnx'),
    ].join(','),
    titlVocabs: [
      for (final pack in packs) _f(modelsDir, pack.dirName, 'vocab.json'),
    ].join(','),
    lexiconPaths: [
      // US before GB (the students only ever read en-us), shared
      // pack before teacher pack.
      for (final file in const ['lexicon-us-en.txt', 'lexicon-gb-en.txt'])
        for (final dir in [_lexDirName, _kokoroDirName])
          _f(modelsDir, dir, file),
    ].join(','),
    espeakBin: espeakBin,
    espeakDataDir: espeakDataDir,
    sid: sid,
  );

  static const _lexDirName = 'tts-lexicon-en';
  static const _kokoroDirName = 'kokoro-multi-lang-v1_0';

  Future<bool> installedIn(String modelsDir) async {
    // Shared packs are part of 'installed': the students without their
    // lexicon cannot speak (no espeak fallback anymore), and the
    // startup check that skips ensureIn for installed voices must
    // therefore see them as needing the (small) download.
    for (final shared in sharedPacks) {
      if (!await packInstalled(modelsDir, shared)) return false;
    }
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
    for (final shared in sharedPacks) {
      await ensurePack(modelsDir, shared, onProgress: onProgress);
    }
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
    for (final pack in [...packs, ...sharedPacks]) {
      await deletePack(modelsDir, pack);
    }
  }
}

/// Our model packs (Apache-2.0 provenance: the k2-fsa tts-models
/// release, the TiTL students from MithrilMan's Hugging Face weights,
/// Kokoro's own lexicon text). Re-hosted as zips deliberately: the
/// k2-fsa Kokoro original ships .tar.bz2, whose pure-Dart decode costs
/// ~21 s and ~900 MB on a desktop CPU (and OOM-kills mid-range phones)
/// to save 13% bytes that quantized weights never pay back anyway.
/// The zip stores binaries rather than deflating them: extraction is
/// then file-copy speed (0.6 s for the whole 371 MB pack here), and
/// peak RAM is one member instead of two full archives.
const _ourPacks =
    'https://github.com/yundddd/voice-agent/releases/download/models-v1';

/// Voices on offer, in display order. The students (TITL) are the
/// default and download on first run: 9 MB per style versus Kokoro's
/// 334 MB, at a quality the A/B on the same int8 graph called close.
final ttsVoices = <TtsVoice>[
  TtsVoice(
    id: 'titl',
    label: 'Students (8M)',
    note:
        'Faster and lighter than Kokoro, sounds close — one English '
        'voice, no 54-style browsing.',
    sizeLabel: '9 MB per style',
    perSidPacks: true,
    sharedPacks: [
      ModelPack(
        label: 'voice: student lexicon',
        url:
            'https://github.com/yundddd/voice-agent/releases/download/models-v1/tts-lexicon-en.zip',
        dirName: TtsVoice._lexDirName,
        markerFile: 'lexicon-us-en.txt',
      ),
    ],
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
        'The best-sounding voice in the app, with 54 speakers to pick '
        'from — slower and a big download.',
    sizeLabel: '334 MB',
    packs: [
      ModelPack(
        label: 'voice: Kokoro v1.0',
        url: '$_ourPacks/kokoro-multi-lang-v1_0.zip',
        dirName: 'kokoro-multi-lang-v1_0',
        markerFile: 'model.onnx',
      ),
    ],
  ),
  // The pairing rule ENFORCED IN CODE: the BOS-npy pack (v3+) requires
  // the patched libsherpa-onnx-c-api.so — vendored for Android via
  // tool/sherpa-bos and first on LD_LIBRARY_PATH for desktop — but iOS
  // has no patched xcframework yet, so iOS keeps the v2 pack: no npy,
  // the Dart growl ritual stays on, nothing regresses. The references
  // filter (specIn) follows the same split: v2 ships six, v4 ships
  // sixteen.
  TtsVoice(
    id: 'pocket',
    label: 'Pocket TTS',
    note:
        'Kyutai 100M zero-shot model — sixteen preset voices (8 female / 8 '
        'male) once loaded; any one of them also clones from a '
        'recording later. The english_2026-04 graphs from '
        'KevinAHM’s ONNX export plus the learned BOS-before-voice '
        'embedding our patched sherpa-onnx feeds before the voice (see '
        'tool/sherpa-bos/) — the cold-start growl is gone and the text '
        'opens with the model’s own breath, not a workaround. Runs on '
        'the shared sherpa-onnx engine.',
    sizeLabel: Platform.isIOS ? '~205 MB' : '~105 MB',
    packs: [
      Platform.isIOS
          ? const ModelPack(
              label: 'voice: Pocket TTS (engine + voices)',
              url: '$_ourPacks/pocket-tts-v2.zip',
              dirName: 'pocket-tts',
              markerFile: 'pack-v2.ok',
            )
          : const ModelPack(
              label: 'voice: Pocket TTS (engine + voices)',
              url: '$_ourPacks/pocket-tts-v4.zip',
              dirName: 'pocket-tts',
              markerFile: 'pack-v4.ok',
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

  TtsPrefs({this.voiceId = 'titl', this.sid = 0});

  Map<String, Object> toJson() => {'voice': voiceId, 'sid': sid};

  static TtsPrefs fromJson(Map<String, Object?> j) {
    final voiceId = switch (j['voice'] as String?) {
      null => 'titl',
      'titl-heart' => 'titl',
      final v => v,
    };
    var sid = j['sid'] as int? ?? 0;
    // The Italian student styles (sids 1–2) retired with the plugin:
    // an old pick of theirs lands on the one student that is left
    // rather than on an empty roster slot. Only per-sid voices clamp —
    // Kokoro keeps 54 styles inside its single pack.
    final voice = voiceById(voiceId);
    if (voice != null && voice.perSidPacks && sid >= voice.packs.length) {
      sid = 0;
    }
    return TtsPrefs(voiceId: voiceId, sid: sid);
  }
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
