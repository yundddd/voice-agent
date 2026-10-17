/// The Kokoro v1.0 speaker roster: sid → name, exactly as the k2-fsa
/// kokoro-multi-lang-v1_0 pack orders `voices.bin` (the mapping the
/// sherpa-onnx docs publish, plus the Spanish `em_santa` the pack README
/// appends at id 53). The voice screen's style picker shows these names
/// instead of bare "Speaker N of 54"; a sid outside the table renders as
/// a numbered fallback so a future pack that grew voices still lists.
library;

/// sid → speaker name for kokoro-multi-lang-v1_0 (54 voices).
const List<String> kokoroSpeakerNames = [
  'af_alloy', // 0
  'af_aoede', // 1
  'af_bella', // 2
  'af_heart', // 3
  'af_jessica', // 4
  'af_kore', // 5
  'af_nicole', // 6
  'af_nova', // 7
  'af_river', // 8
  'af_sarah', // 9
  'af_sky', // 10
  'am_adam', // 11
  'am_echo', // 12
  'am_eric', // 13
  'am_fenrir', // 14
  'am_liam', // 15
  'am_michael', // 16
  'am_onyx', // 17
  'am_puck', // 18
  'am_santa', // 19
  'bf_alice', // 20
  'bf_emma', // 21
  'bf_isabella', // 22
  'bf_lily', // 23
  'bm_daniel', // 24
  'bm_fable', // 25
  'bm_george', // 26
  'bm_lewis', // 27
  'ef_dora', // 28
  'em_alex', // 29
  'ff_siwis', // 30
  'hf_alpha', // 31
  'hf_beta', // 32
  'hm_omega', // 33
  'hm_psi', // 34
  'if_sara', // 35
  'im_nicola', // 36
  'jf_alpha', // 37
  'jf_gongitsune', // 38
  'jf_nezumi', // 39
  'jf_tebukuro', // 40
  'jm_kumo', // 41
  'pf_dora', // 42
  'pm_alex', // 43
  'pm_santa', // 44
  'zf_xiaobei', // 45
  'zf_xiaoni', // 46
  'zf_xiaoxiao', // 47
  'zf_xiaoyi', // 48
  'zm_yunjian', // 49
  'zm_yunxi', // 50
  'zm_yunxia', // 51
  'zm_yunyang', // 52
  'em_santa', // 53 (Spanish — added by the pack, see its README)
];

/// One roster entry as the picker renders it.
class KokoroSpeaker {
  final int sid;
  final String name; // 'af_heart', or 'Speaker 27 of 54' past the table
  final String description; // 'American English · female'
  final bool english; // language of the style, not of our wiring note

  /// Demo line for the audition button — the voice's own language when
  /// it is not English (null = the assistant's standard preview line).
  final String? previewText;

  const KokoroSpeaker({
    required this.sid,
    required this.name,
    required this.description,
    required this.english,
    this.previewText,
  });

  /// Sort order: English styles first (they're what this app actually
  /// speaks — the pack is wired us-en/gb-en lexicons + espeak English),
  /// then female before male, then by name so the list is stable.
  int get order => english ? sid : sid + 1000;
}

/// The student voice's roster (`TtsVoice` id 'titl'): sid = pack index
/// into its three graph packs, mirroring the upstream release
/// (MithrilMan/teacher-in-the-loop). Single-voice models, so each style
/// is its own graph rather than a speaker embedding.
const List<KokoroSpeaker> titlRoster = [
  KokoroSpeaker(
    sid: 0,
    name: 'af_heart',
    description: 'American English · female',
    english: true,
  ),
  KokoroSpeaker(
    sid: 1,
    name: 'if_sara',
    description: 'Italian · female',
    english: false,
    previewText:
        'Buongiorno! Ecco come suona il vostro assistente con questa voce.',
  ),
  KokoroSpeaker(
    sid: 2,
    name: 'im_nicola',
    description: 'Italian · male',
    english: false,
    previewText:
        'Buongiorno! Ecco come suona il vostro assistente con questa voce.',
  ),
];

/// Prefix → (language, gender) as the Kokoro naming scheme defines it.
const Map<String, (String, String, bool)> _prefixes = {
  'af': ('American English', 'female', true),
  'am': ('American English', 'male', true),
  'bf': ('British English', 'female', true),
  'bm': ('British English', 'male', true),
  'ef': ('French', 'female', false),
  'em': ('French', 'male', false),
  'ff': ('French', 'female', false),
  'hf': ('Hindi', 'female', false),
  'hm': ('Hindi', 'male', false),
  'if': ('Italian', 'female', false),
  'im': ('Italian', 'male', false),
  'jf': ('Japanese', 'female', false),
  'jm': ('Japanese', 'male', false),
  'pf': ('Portuguese', 'female', false),
  'pm': ('Portuguese', 'male', false),
  'zf': ('Chinese', 'female', false),
  'zm': ('Chinese', 'male', false),
};

/// The roster for a freshly loaded engine, `numSpeakers` long: named
/// where the table knows the sid, numbered where a pack grew past it.
List<KokoroSpeaker> kokoroRoster(int numSpeakers) => [
  for (var sid = 0; sid < numSpeakers; sid++) _speakerAt(sid),
];

KokoroSpeaker _speakerAt(int sid) {
  final name = sid < kokoroSpeakerNames.length ? kokoroSpeakerNames[sid] : null;
  if (name == null) {
    return KokoroSpeaker(
      sid: sid,
      name: 'Speaker ${sid + 1}',
      description: 'unknown style (not in the shipped roster)',
      english: false,
    );
  }
  // The pack's README calls em_santa Spanish; the prefix table says
  // French, so special-case the one known disagreement.
  final p = _prefixes[name.substring(0, 2)]!;
  final (lang, gender, english) = name == 'em_santa'
      ? ('Spanish', 'male', false)
      : (p.$1, p.$2, p.$3);
  return KokoroSpeaker(
    sid: sid,
    name: name,
    description: '$lang · $gender',
    english: english,
  );
}

/// The display name for a sid (picker card headline, bench labels).
String kokoroSpeakerName(int sid, {required int numSpeakers}) {
  if (sid < 0 || sid >= numSpeakers) return 'current voice';
  return _speakerAt(sid).name;
}
