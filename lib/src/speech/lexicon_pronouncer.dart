// The students' espeak-free text front-end: every word looks up its
// phonemes in Kokoro's OWN lexicon files (the same lexicon-us-en.txt /
// lexicon-gb-en.txt the teacher's sherpa path reads), so the APK can
// speak English without carrying the GPL piper_phonemize native.
//
// Why this can replace espeak at all: the lexicon is espeak-DERIVED but
// already converted to the trained Kokoro alphabet — diphthongs are the
// single trained tokens ('sound s ˈ W n d'), the length marks are gone,
// ð θ ʤ ʧ are the trained forms. Auditing both shipped files: 46
// distinct symbols per file, every one a vocabulary codepoint, and the
// ONLY raw spots left are the flap ('water w ˈ ɔ ɾ ə ɹ' — 17k entries
// carry ɾ, zero carry 'T') and 437 glottal stops. So exactly those two
// characters are mapped at parse time — the tail of what foldEspeakEn
// does to espeak's live output — and a lexicon entry then needs NO
// further fold: TitlTts calls phonemesFromWords with aliases/folds off
// for this path.
//
// The lexicon is a dictionary, not a rule engine, so unknown words walk
// a ladder — the ladder covers what espeak's letter rules used to:
//   1. whole word (apostrophes/hyphens are real parts of keys: 'don't',
//      'twenty-one' are entries; ~178k words per file);
//   2. digits spoken as words ('13' → thirteen, '3.14' → three point
//      one four, $5 → dollar five, 50% → fifty percent) — espeak said
//      them, and the spelled-out words then take rung 1;
//   3. clitics and possessives after a known stem ("dog's" → dog + z);
//   4. regular inflection: -s/-es/-ed/-ing/-ly/-er/-est off a lexicon
//      stem, the suffix sound picked from the stem's final phoneme
//      ('parameters' → parameter + z — the plural IS in the file for
//      most words ('megabytes' is there), the rules rescue the rest);
//   5. compound split, greedy longest known pieces ('speakerphone' →
//      speaker + phone);
//   6. a small letter-to-sound table — approximate, vocab-filtered
//      downstream, the same bet espeak makes for names;
//   7. nothing matched: the word is dropped, never guessed, exactly
//      the engine's standing rule for foreign characters.
library;

import 'dart:convert';
import 'dart:io';

/// The two raw spots the lexicon still carries, mapped to the trained
/// alphabet (see the header audit note). These are the last two rules
/// of the old espeak fold: the flap-as-'T' is a trained convention, not
/// a preference, and folding at parse time means the read path folds
/// nothing.
const Map<String, String> _trainedForm = {'ɾ': 'T', 'ʔ': 't'};

class LexiconPronouncer {
  /// word (lowercase ASCII key) → phonemes as one codepoint string,
  /// multi-word values joined on ' ' (a legal vocab token, so one
  /// entry can speak several words, e.g. the number '13').
  final Map<String, String> _ipa;

  LexiconPronouncer._(this._ipa);

  int get wordCount => _ipa.length;

  /// Parse lexicon files in priority order — the first entry for a
  /// word wins, so pass US before GB, and duplicates like the two
  /// candidate directories for the same file cost nothing. Lines are
  /// `word tok tok …` with every phoneme a single codepoint; tokens
  /// are stored concatenated, exactly the morpheme shape the engine
  /// consumes. GB files also lose the length mark ː (68k of them: the
  /// students trained on US output, which carries none). Missing files
  /// are skipped; null when nothing loaded at all — TitlTts turns that
  /// into a loud TitlException, so a student without its lexicon pack
  /// says so instead of speaking silence.
  static LexiconPronouncer? loadAll(Iterable<String> paths) {
    final ipa = <String, String>{};
    for (final path in paths) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final stripLength = path.contains('lexicon-gb');
      for (final line in f.readAsLinesSync(encoding: utf8)) {
        final sp = line.indexOf(' ');
        if (sp <= 0) continue;
        var entry = line.substring(sp + 1).replaceAll(' ', '');
        for (final e in _trainedForm.entries) {
          entry = entry.replaceAll(e.key, e.value);
        }
        if (stripLength) entry = entry.replaceAll('ː', '');
        if (entry.isEmpty) continue;
        ipa.putIfAbsent(line.substring(0, sp), () => entry);
      }
    }
    return ipa.isEmpty ? null : LexiconPronouncer._(ipa);
  }

  // ── Text front-end ───────────────────────────────────────────────────

  /// Text → morpheme code lists, the shape PiperPhonemize.phonemize
  /// returns: one entry per word, the codepoints of that word's
  /// phonemes. Sentence punctuation survives EXACTLY as far as it did
  /// inside espeak — attached to the preceding word ('world, ðɪs'
  /// carried the comma in the current path; the phoneme stream the
  /// graph trained on includes those ids as prosody markers).
  List<List<int>> phonemize(String text) {
    final out = <List<int>>[];
    for (final t in _tokens(text)) {
      if (t.punct) {
        if (out.isNotEmpty && _punct.contains(t.s)) {
          out.last.addAll(t.s.codeUnits);
        }
        continue;
      }
      final ipa = _lookup(t.s);
      if (ipa == null || ipa.isEmpty) continue;
      out.add(ipa.codeUnits.toList());
    }
    return out;
  }

  /// The punctuation espeak handed on as speaking ids; everything else
  /// (brackets, slashes, stray unicode) vanished inside it and vanishes
  /// here. '.' doubles as the stop the caller appends at piece end.
  static const _punct = {'.', ',', ';', ':', '!', '?', '—', '“', '”', '…'};

  /// Words and punctuation out of raw text: runs of letters (inner
  /// apostrophes and hyphens kept — 'don't', 'twenty-one' are real
  /// keys), digit runs with an optional decimal point, the two
  /// currency/measure symbols espeak voiced as words ($ → dollar,
  /// % → percent), and single punctuation characters as their own
  /// tokens.
  static List<_Tok> _tokens(String text) {
    final out = <_Tok>[];
    final s = text.toLowerCase().replaceAll('\u2019', "'");
    final b = StringBuffer();
    // 0 = letter token, 1 = digit token; overwritten by the first char
    // of every new token, so its stale value can only be read while b
    // is empty — where the read is guarded away.
    var tokClass = 1;
    void flush() {
      if (b.isNotEmpty) {
        out.add(_Tok(b.toString(), false));
        b.clear();
      }
    }

    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      final digit = _isDigit(c);
      final letter = _isLetter(c);
      final joiner =
          (c == "'" || c == '-') && b.isNotEmpty && _isLetter(s[i - 1]);
      final decimal =
          c == '.' &&
          i > 0 &&
          _isDigit(s[i - 1]) &&
          i + 1 < s.length &&
          _isDigit(s[i + 1]);
      // Digits and letters never share a token ('2x' is two words,
      // exactly as espeak read it) — tracked on the token's own class,
      // so the decimal point inside '3.14' cannot look like a change.
      final tokDigit = tokClass == 1;
      final classChange =
          (letter || digit) && b.isNotEmpty && tokDigit != digit;
      // A comma between digits is a thousands separator: vanish inside
      // the number and keep feeding the same token.
      if (c == ',' &&
          i > 0 &&
          _isDigit(s[i - 1]) &&
          i + 1 < s.length &&
          _isDigit(s[i + 1])) {
        continue;
      }
      if (classChange) flush();
      if (letter || digit || joiner || decimal) {
        b.write(c);
        if (digit) tokClass = 1;
        if (letter) tokClass = 0;
        continue;
      }
      flush();
      if (c == r'$' || c == '%') {
        out.add(_Tok(c, false));
        continue;
      }
      if (_punct.contains(c)) out.add(_Tok(c, true));
    }
    flush();
    return out;
  }

  static bool _isDigit(String c) {
    final r = c.codeUnitAt(0);
    return r >= 0x30 && r <= 0x39;
  }

  static bool _isLetter(String c) {
    final r = c.runes.first;
    if (r >= 0x41 && r <= 0x5a) return true;
    if (r >= 0x61 && r <= 0x7a) return true;
    // Letters outside ASCII count too: the key folds them to their
    // stripped form (café → cafe), so they can still hit an entry.
    return r > 0x7f && _foldAccents(c) != c;
  }

  /// Lookup ladder for one token from [words].
  String? _lookup(String token) {
    final key = foldKey(token);
    if (key.isEmpty) return null;
    if (key == r'$') return _ipa['dollar'];
    if (key == '%') return _ipa['percent'];
    final hit = _ipa[key];
    if (hit != null) return hit;
    if (RegExp(r'^[0-9]+(\.[0-9]+)?$').hasMatch(key)) return _number(key);
    // Initial-letter words ('2x', '8m'): the lexicon's letter entries
    // already speak single letters ('t' → 't ˈ i'); this table covers
    // the rest so 'x' is 'ɛks', never the 'ks' the letter rules would
    // start a word with.
    if (key.length == 1) return _letterNames[key];
    final clit = _clitic(key);
    if (clit != null) return clit;
    final suf = _suffixRule(key);
    if (suf != null) return suf;
    final seg = _segment(key);
    if (seg != null) return seg;
    return _letterSounds(key);
  }

  // ── Clitics and possessives ──────────────────────────────────────────

  /// "'s", "s'", and the light contractions the lexicon happens not to
  /// carry: the stem re-enters the full lookup (so rules can feed it
  /// too), 's rides the same voicing rule as the plural, and a bare
  /// trailing apostrophe adds nothing — "dogs'" IS just "dogs".
  String? _clitic(String key) {
    final apos = key.lastIndexOf("'");
    if (apos <= 0) return null;
    final tail = key.substring(apos + 1);
    final stem = _lookup(key.substring(0, apos));
    if (stem == null) return null;
    if (tail.isEmpty) return stem;
    if (tail == 's') return stem + _linkS(stem);
    const sounds = {
      'll': 'l',
      'd': 'd',
      'm': 'm',
      've': 'v',
      're': 'ɹ',
      'em': 'əm',
    };
    final cliticSound = sounds[tail];
    return cliticSound == null ? null : stem + cliticSound;
  }

  // ── Numbers ──────────────────────────────────────────────────────────

  static const _ones = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
  ];
  static const _tens = [
    '',
    '',
    'twenty',
    'thirty',
    'forty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  ];
  static const _scales = ['', 'thousand', 'million', 'billion', 'trillion'];

  /// Integers with scale words, decimals digit by digit after 'point';
  /// absurdly long runs go digit by digit too. Every spelled word re-
  /// enters the lexicon — a scale word missing there drops the phrase,
  /// it never silences the voice.
  String? _number(String digits) {
    final dot = digits.indexOf('.');
    var n = dot < 0 ? digits : digits.substring(0, dot);
    final frac = dot < 0 ? '' : digits.substring(dot + 1);
    final words = <String>[];
    if (n.length > 15) {
      words.addAll(n.split('').map(_digitWord));
    } else {
      var group = 0;
      while (n.isNotEmpty) {
        final chunk = n.length > 3 ? n.substring(n.length - 3) : n;
        n = n.length > 3 ? n.substring(0, n.length - 3) : '';
        final cw = _threeDigits(chunk);
        if (cw.isNotEmpty) {
          if (group > 0 && _scales[group].isNotEmpty) cw.add(_scales[group]);
          words.insertAll(0, cw);
        }
        group++;
      }
      if (words.isEmpty) words.add('zero');
    }
    if (frac.isNotEmpty) {
      words.addAll(['point', ...frac.split('').map(_digitWord)]);
    }
    final parts = <String>[];
    for (final w in words) {
      final ipa = _ipa[foldKey(w)];
      if (ipa == null) return null;
      parts.add(ipa);
    }
    return parts.join(' ');
  }

  static String _digitWord(String d) => _ones[int.parse(d)];

  static List<String> _threeDigits(String g) {
    final w = <String>[];
    var n = int.parse(g);
    if (n >= 100) {
      w.add(_ones[n ~/ 100]);
      w.add('hundred');
      n %= 100;
      if (n == 0) return w;
    }
    if (n >= 20) {
      w.add(_tens[n ~/ 10]);
      if (n % 10 != 0) w.add(_ones[n % 10]);
    } else if (n > 0) {
      w.add(_ones[n]);
    }
    return w;
  }

  // ── Regular inflection ───────────────────────────────────────────────

  /// stem entry + the trained sound of the stripped suffix, chosen by
  /// the stem's final phoneme just as the language does. Null when the
  /// stem is not in the lexicon, so 'bus' never becomes 'bu' + noise.
  String? _suffixRule(String w) {
    // -ies: studies → study + iz
    if (w.length > 4 && w.endsWith('ies')) {
      final stem = _ipa['${w.substring(0, w.length - 3)}y'];
      if (stem != null) return '$stem iz';
    }
    // -es after sibilants: boxes → box + ɨz, dishes → dish + ɨz
    if (w.length > 3 && w.endsWith('es')) {
      final stem = _ipa[w.substring(0, w.length - 2)];
      if (stem != null && _endsWithSibilant(stem)) return '$stemɨz';
    }
    // plain -s plurals / 3sg: dogs → dog + z, makes → make + s
    if (w.length > 3 && w.endsWith('s')) {
      final stem = _ipa[w.substring(0, w.length - 1)];
      if (stem != null) return stem + _linkS(stem);
    }
    // -ed: distilled → distill + d, started → start + ɪd, baked → bake + t
    if (w.length > 3 && w.endsWith('ed')) {
      for (final stem in [
        _ipa[w.substring(0, w.length - 2)],
        _ipa[w.substring(0, w.length - 1)],
      ]) {
        if (stem != null) return stem + _linkD(stem);
      }
    }
    // -ing: walking → walk + ɪŋ; making → make + ɪŋ (the e-less
    // spelling finds the entry under '${base}e')
    if (w.length > 4 && w.endsWith('ing')) {
      final base = w.substring(0, w.length - 3);
      for (final stem in [_ipa[base], _ipa['${base}e']]) {
        if (stem != null) return '$stemɪŋ';
      }
    }
    // -ly: quickly → quick + li
    if (w.length > 4 && w.endsWith('ly')) {
      final stem = _ipa[w.substring(0, w.length - 2)];
      if (stem != null) return '${stem}li';
    }
    // -er / -ers / -est: speak + ɜɹ, + ɜɹz, fast + ɪst
    if (w.length > 4) {
      if (w.endsWith('ers')) {
        final stem = _ipa[w.substring(0, w.length - 3)];
        if (stem != null) return '$stemɜɹz';
      } else if (w.endsWith('er')) {
        final stem = _ipa[w.substring(0, w.length - 2)];
        if (stem != null) return '$stemɜɹ';
      } else if (w.endsWith('est')) {
        final stem = _ipa[w.substring(0, w.length - 3)];
        if (stem != null) return '$stemɪst';
      }
    }
    return null;
  }

  /// Plural/3sg 's' after the stem: ɨz after a sibilant, s after an
  /// explicitly voiceless stop, z everywhere else (the voiced default;
  /// wrong-side misses are rare consonant-final stems).
  static String _linkS(String stem) {
    final t = _last(stem);
    if (const {'s', 'z', 'ʃ', 'ʒ', 'ʧ', 'ʤ', 'ɕ', 'ʑ'}.contains(t)) return 'ɨz';
    if (const {'p', 'k', 'f', 't', 'θ', 'ʦ', 'x'}.contains(t)) return 's';
    return 'z';
  }

  /// Past -ed: ɪd after t/d (the syllable the language inserts), t
  /// after voiceless, plain d as the voiced default.
  static String _linkD(String stem) {
    final t = _last(stem);
    if (t == 't' || t == 'd') return 'ɪd';
    if (const {'p', 'k', 'f', 'θ', 's', 'ʃ', 'ʧ'}.contains(t)) return 't';
    return 'd';
  }

  static bool _endsWithSibilant(String stem) =>
      const {'s', 'z', 'ʃ', 'ʒ', 'ʧ', 'ʤ'}.contains(_last(stem));

  /// The final CODE POINT (not .last, which is a grapheme cluster).
  static String _last(String s) => String.fromCharCode(s.runes.last);

  // ── Compound split ───────────────────────────────────────────────────

  /// Greedy longest-prefix over the lexicon: every piece at least two
  /// letters (a one-letter piece would speak the letter's NAME:
  /// 's' → 'ɛ s'), full coverage required, max five pieces.
  /// 'speakerphone' → speaker + phone; 'xyzzy' falls through to the
  /// letter rules.
  String? _segment(String w) {
    if (w.length < 6) return null;
    final parts = <String>[];
    var rest = w;
    while (rest.isNotEmpty) {
      var found = false;
      for (var cut = rest.length; cut >= 2 && !found; cut--) {
        final ipa = _ipa[rest.substring(0, cut)];
        if (ipa != null) {
          parts.add(ipa);
          rest = rest.substring(cut);
          found = true;
        }
      }
      if (!found || parts.length > 5) return null;
    }
    return parts.length > 1 ? parts.join(' ') : null;
  }

  // ── Letter-to-sound (last resort) ────────────────────────────────────

  /// Compact English grapheme rules emitting TRAINED-alphabet symbols.
  /// This is the rough edge by design: an approximate accent is a
  /// cheaper failure than a silently dropped word (names and coinages
  /// a harness answer always carries), and the vocab filter behind the
  /// engine guarantees whatever comes out is at least speakable.
  String? _letterSounds(String w) {
    // silent final -e, and the -le/'el' dark-l endings that need it back
    final s = w.endsWith('e') && w.length > 3
        ? w.substring(0, w.length - 1)
        : w;
    final b = StringBuffer();
    for (var i = 0; i < s.length;) {
      var matched = false;
      for (final n in [5, 4, 3, 2]) {
        if (i + n > s.length) continue;
        final r = _digraphs[s.substring(i, i + n)];
        if (r != null) {
          b.write(r);
          i += n;
          matched = true;
          break;
        }
      }
      if (matched) continue;
      final c = s[i];
      // doubled consonants speak once
      if (i + 1 < s.length && s[i + 1] == c && _letters.containsKey(c)) {
        i++;
        continue;
      }
      final sound = _letters[c] ?? _vowels[c];
      if (sound != null) b.write(sound);
      i++;
    }
    final out = b.toString();
    return out.isEmpty ? null : out;
  }

  static const _vowels = {
    'a': 'æ',
    'e': 'ɛ',
    'i': 'ɪ',
    'o': 'ɑ',
    'u': 'ʌ',
    'y': 'ə',
  };

  /// Letter names for one-letter tokens the lexicon does not carry as
  /// words — 'a', 'i', 'o' are words (articles, pronoun, interjection)
  /// and hit the dictionary before this table is ever consulted.
  static const _letterNames = {
    'b': 'bi',
    'c': 'si',
    'd': 'di',
    'e': 'i',
    'f': 'ɛf',
    'g': 'dʒi',
    'h': 'eɪʧ',
    'j': 'dʒeɪ',
    'k': 'keɪ',
    'l': 'ɛl',
    'm': 'ɛm',
    'n': 'ɛn',
    'p': 'pi',
    'q': 'kju',
    'r': 'ɑɹ',
    's': 'ɛs',
    't': 'ti',
    'u': 'ju',
    'v': 'vi',
    'w': 'dʌblju',
    'x': 'ɛks',
    'y': 'waɪ',
    'z': 'zi',
  };

  static const _digraphs = {
    // consonant clusters with their own letters
    'tch': 'ʧ',
    'igh': 'I',
    'tious': 'ʃəs',
    'tion': 'ʃən',
    'sion': 'ʒən',
    'cial': 'ʃəl',
    'tial': 'ʃəl',
    'sure': 'ʒɚ',
    'sh': 'ʃ',
    'ch': 'ʧ',
    'th': 'θ',
    'ph': 'f',
    'wh': 'w',
    'ck': 'k',
    'ng': 'ŋ',
    'nk': 'ŋk',
    'qu': 'kw',
    // vowel digraphs, trained singletons where the spelling maps to one
    'ai': 'I',
    'ay': 'I',
    'ei': 'A',
    'ey': 'i',
    'ea': 'i',
    'ee': 'i',
    'oo': 'u',
    'ou': 'W',
    'ow': 'W',
    'oi': 'Y',
    'oy': 'Y',
    'au': 'ɔ',
    'aw': 'ɔ',
    'al': 'ɔ',
    'oa': 'oʊ',
    'ew': 'u',
    'ir': 'ɜɹ',
    'er': 'ɜɹ',
    'ur': 'ɜɹ',
    'or': 'ɔɹ',
    'ar': 'ɑɹ',
    'ear': 'iɹ',
    'le': 'əl',
    'el': 'əl',
  };

  static const _letters = {
    'b': 'b',
    'c': 'k',
    'd': 'd',
    'f': 'f',
    'g': 'ɡ',
    'h': 'h',
    'j': 'dʒ',
    'k': 'k',
    'l': 'l',
    'm': 'm',
    'n': 'n',
    'p': 'p',
    'r': 'ɹ',
    's': 's',
    't': 't',
    'v': 'v',
    'w': 'w',
    'x': 'ks',
    'z': 'z',
    'y': 'j',
    'à': 'ɑ',
    'á': 'ɑ',
    'è': 'ɛ',
    'é': 'e',
    'ü': 'u',
    'ö': 'ɜ',
    'ñ': 'n',
  };

  // ── Keys ─────────────────────────────────────────────────────────────

  /// Lookup key: lowercase, accent-stripped (Café → cafe). Tokens from
  /// [words] arrive lowercased already; ASCII words skip the fold.
  static String foldKey(String w) {
    var ascii = true;
    for (final c in w.codeUnits) {
      if (c > 0x7f) {
        ascii = false;
        break;
      }
    }
    if (ascii) return w;
    final b = StringBuffer();
    for (final r in w.runes) {
      b.write(_foldAccents(String.fromCharCode(r)));
    }
    return b.toString().toLowerCase();
  }

  static const _accentTable = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
    'ñ': 'n',
    'ý': 'y',
    'ÿ': 'y',
  };
  static String _foldAccents(String c) => _accentTable[c] ?? c;
}

/// One scanner output: a word to look up, or a punctuation char to
/// attach to the preceding morpheme.
class _Tok {
  final String s;
  final bool punct;
  _Tok(this.s, this.punct);
}
