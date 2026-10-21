/// espeak-ng OUT OF PROCESS: the students' rule-engine front-end as a
/// standalone executable, the GPL boundary drawn at exec() instead of
/// at a linker.
///
/// Why (the +238 field report): the Dart lexicon ladder (+224) replaced
/// a rule engine with a dictionary, and dictionaries have no rule for
/// an all-caps initialism — APK came out "a-pick", TTS "tss", UI "eye".
/// espeak reads letter runs as letter names by reflex, because that is
/// what the +167..+223 era student voice was TRAINED on. The plugin
/// died over GPLv3 linking; run as a child process it is mere
/// interaction — the app stays closed, and the GPL duties shrink to
/// shipping the corresponding source of the bundled binary itself
/// (see third_party/espeak_exec/README.md).
///
/// The executable rides in jniLibs under a lib*.so name (Android's
/// W^X rule since API 29: only nativeLibraryDir files may be exec'd)
/// and speaks through the SAME Misaki fold the piper plugin used,
/// recovered from git history — the students' trained alphabet has no
/// room for improvisation. Where the binary cannot run (Linux desktop
/// tests, an x86 debug image without the binary), the lexicon ladder
/// stays as the fallback: a degraded voice beats a loud silence there,
/// and TitlTts says which path it took.
library;

import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

/// jniLibs name of the cross-built executable (the .so prefix is the
/// price of the exec-able directory, not a claim about its kind).
const espeakLibName = 'libvoiceagent_espeak.so';

/// Runtime dir the pruned English data unpacks to inside the models
/// dir (same root the packs unpack into; versioned by content bump).
const espeakDataDirName = 'espeak-ng-data';

/// Asset files carrying the pruned espeak-ng-data (936 KB: phondata,
/// the US/GMW language tables, en_dict, intonations). Listed explicitly
/// because rootBundle has no directory enumeration without the asset
/// manifest, and a silent missing file here means a broken voice.
const espeakAssetFiles = <String>[
  'phondata',
  'phonindex',
  'phontab',
  'intonations',
  'en_dict',
  'lang/gmw/en',
  'lang/gmw/en-029',
  'lang/gmw/en-GB-scotland',
  'lang/gmw/en-GB-x-gbclan',
  'lang/gmw/en-GB-x-gbcwmd',
  'lang/gmw/en-GB-x-rp',
  'lang/gmw/en-US',
  'lang/gmw/en-US-nyc',
];
const espeakAssetPrefix = 'assets/espeak-data';

/// The 'voiceagent/runtime' channel's one verb (MainActivity.kt).
const espeakRuntimeChannel = MethodChannel('voiceagent/runtime');

/// The app's nativeLibraryDir on Android; '' anywhere else, and on
/// Android before the platform answers (tests).
Future<String> nativeLibDir() async {
  try {
    final dir = await espeakRuntimeChannel.invokeMethod<String>('nativeLibDir');
    return dir ?? '';
  } catch (_) {
    return ''; // no plugin world (unit tests, desktop smoke)
  }
}

// ── The Misaki fold, verbatim from the pre-+224 pipeline ─────────────────
// The piper_phonemize path applied these before the graph ever saw a
// phoneme; the trained alphabet depends on them (diphthongs are SINGLE
// tokens to this graph — raw "aʊ" is what made the student say "sown").

const Map<String, String> espeakAliases = {
  'D': 'ð',
  'T': 'θ',
  '1': 'ɨ',
  '2': 'ʉ',
  'ä': 'ə',
  'ɾ': 'T',
  'ʔ': 't',
  'ˑ': '',
};

const List<List<String>> _foldsBeforeSyllabic = [
  ['ʔˌn̩', 'ʔn'],
  ['ʔn̩', 'ʔn'],
  ['aʊ', 'W'],
  ['aɪ', 'I'],
  ['dʒ', 'ʤ'],
  ['eɪ', 'A'],
  ['e', 'A'],
  ['tʃ', 'ʧ'],
  ['ɔɪ', 'Y'],
  ['əl', 'ᵊl'],
  ['ʲo', 'jo'],
  ['ʲə', 'jə'],
  ['ʲ', ''],
  ['ɚ', 'əɹ'],
  ['r', 'ɹ'],
  ['x', 'k'],
  ['ç', 'k'],
  ['ɐ', 'ə'],
  ['ɬ', 'l'],
  ['̃', ''],
];

const List<List<String>> _foldsUs = [
  ['oʊ', 'O'],
  ['ɜːɹ', 'ɜɹ'],
  ['ɜː', 'ɜɹ'],
  ['ɪə', 'iə'],
  ['ː', ''],
  ['o', 'ɔ'],
];

const _syllabicMark = '̩';

/// Misaki's US-branch fold (EspeakFallback in the piper pipeline,
/// syllabic rewrite between the two table passes). Pure.
String foldEspeakEn(String phonemized) {
  var s = phonemized;
  for (final f in _foldsBeforeSyllabic) {
    s = s.replaceAll(f[0], f[1]);
  }
  s = s.replaceAllMapped(RegExp('(\\S)$_syllabicMark'), (m) => 'ᵊ${m[1]}');
  for (final f in _foldsUs) {
    s = s.replaceAll(f[0], f[1]);
  }
  return s.replaceAll(_syllabicMark, '');
}

/// One use of the executable: run it over [text], fold its IPA into the
/// trained alphabet, drop anything outside [vocab], and hand back the
/// phoneme string TitlEngine.synth eats (trailing stop ensured — the
/// sentence intonation the teacher's own pipeline feeds the graph).
class EspeakExec {
  EspeakExec({required this.binPath, required this.dataDir});

  final String binPath;
  final String dataDir;

  /// Binary and data both present. The data marker is phondata (the
  /// fold tables cannot speak without it).
  bool get usable =>
      File(binPath).existsSync() && File('$dataDir/phondata').existsSync();

  /// Raw espeak IPA for [text]. Throws TitlException naming stderr —
  /// a student whose voice front-end died must name it, not whisper.
  String ipa(String text) {
    // The text rides argv, not a temp file: espeak's bare argument IS
    // the text (-f is the file input, and a file path passed bare is
    // spoken as the first thing you hear — the shipped build's first
    // field report: every reply prefaced by '/tmp/dart-…/input.txt').
    // -w still drops the synthesis to /dev/null so --ipa owns stdout.
    final r = Process.runSync(
      binPath,
      ['-v', 'en-us', '--ipa', '-w', '/dev/null', text],
      environment: {'ESPEAK_DATA_PATH': dataDir},
    );
    if (r.exitCode != 0) {
      throw EspeakException('espeak exec failed (${r.exitCode}): ${r.stderr}');
    }
    return (r.stdout as String).replaceAll('\n', ' ').trim();
  }

  /// IPA string → synth-ready phonemes (fold, alias, vocab-filter,
  /// stop). Pure; pinned against the cross-build's real stdout.
  static String phonemesFromIpa(String ipa, Set<String> vocab) {
    final b = StringBuffer();
    for (final rune in foldEspeakEn(ipa).runes) {
      final c = String.fromCharCode(rune);
      final folded = espeakAliases[c] ?? c;
      if (vocab.contains(folded)) b.write(folded);
    }
    var s = b.toString().trim();
    if (s.isNotEmpty && !s.endsWith('.')) s = '$s.'; // sentence intonation
    return s;
  }
}

class EspeakException implements Exception {
  final String message;
  EspeakException(this.message);
  @override
  String toString() => 'EspeakException: $message';
}
