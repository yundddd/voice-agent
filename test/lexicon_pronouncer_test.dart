import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/lexicon_pronouncer.dart';
import 'package:voice_agent/src/speech/titl_engine.dart';

/// Fixture lines are REAL entries from the shipped
/// kokoro-multi-lang-v1_0/lexicon-us-en.txt (and a few from
/// lexicon-gb-en.txt); 'lexicon_mini_us.txt' deliberately lacks common
/// plurals/past forms so the rule rungs of the ladder get exercised
/// against dictionary ground truth instead of made-up IPA.
void main() {
  final vocab = <String, int>{
    for (final e
        in (jsonDecode(File('test/fixtures/titl_vocab.json').readAsStringSync())
                as Map<String, Object?>)
            .entries)
      e.key: (e.value as num).toInt(),
  };
  final us = LexiconPronouncer.loadAll(['test/fixtures/lexicon_mini_us.txt'])!;
  final gb = LexiconPronouncer.loadAll(['test/fixtures/lexicon-gb-mini.txt'])!;

  // What the student graph receives: pronouncer morphemes through the
  // engine's vocab filter and stop rule — one line.
  String spoken(LexiconPronouncer p, String text) =>
      TitlEngine.phonemesFromWords(p.phonemize(text), vocab.keys.toSet());

  group('lexicon pronouncer', () {
    test('exact entries speak the trained alphabet, no fold needed', () {
      // 'sound s ˈ W n d' is THE regression this whole path exists for:
      // the ow must be the single trained 'W' token (the old espeak
      // route needed the Misaki fold to get here; the file is already
      // there). Same for the flap: the lexicon's raw ɾ/ʔ became the
      // capital-T convention at parse time — 'water' must land on the
      // same 'T' the graph was trained with.
      expect(spoken(us, 'sound'), 'sˈWnd.');
      expect(spoken(us, 'water'), 'wˈɔTəɹ.');
      expect(spoken(us, "don't"), 'dˈOnt.');
      expect(spoken(us, "it's"), 'ɪts.');
      expect(spoken(us, "twenty-one"), 'twˌɛntiwˈʌn.');
    });

    test('numbers speak as words, decimals digit by digit', () {
      expect(spoken(us, '13'), 'θˌɜɹtˈin.');
      expect(spoken(us, '3.14'), 'θɹˈi pˈYnt wˈʌn fˈɔɹ.');
      expect(spoken(us, '1,000'), 'wˈʌn θˈWzᵊnd.');
      expect(spoken(us, '300.9'), 'θɹˈi hˈʌndɹəd pˈYnt nˈIn.');
      expect(spoken(us, '1000000'), 'wˈʌn mˈɪljᵊn.');
      // $ and % voice as words the way espeak read them; digits and
      // letters never share a token ('2x' = 'two x', not one weird one).
      expect(spoken(us, r'$5'), 'dˈɑləɹ fˈIv.');
      expect(spoken(us, '5%'), 'fˈIv pəɹsˈɛnt.');
      expect(spoken(us, '2x'), 'tˈu ɛks.'); // single-letter 'x' = name
      expect(spoken(us, '8m'), 'ˈAt ɛm.');
    });

    test('regular inflection off a dictionary stem', () {
      // dog ends voiced (ɡ) → z; make ends k → s; dish ends ʃ → the
      // language inserts ɨ (the -es rule).
      expect(spoken(us, 'dogs'), 'dˈɔɡz.');
      expect(spoken(us, 'makes'), 'mˌAks.');
      expect(spoken(us, 'dishes'), 'dˈɪʃɨz.');
      // Real 'boxes'/'tests' entries must beat the rules with the file's
      // own form (ᵻ and all).
      expect(spoken(us, 'boxes'), 'bˈɑksᵻz.');
      expect(spoken(us, 'tests'), 'tˈɛsts.');
      // -ed: start ends t → ɪd syllable; walk ends k → plain t; bake
      // finds its entry under 'bake'+'d' spelling minus the d.
      expect(spoken(us, 'started'), 'stˈɑɹTᵻd.'); // exact entry wins
      expect(spoken(us, 'walked'), 'wˈɔkt.');
      expect(spoken(us, 'baked'), 'bˈAkt.'); // exact entry, rule agrees
      expect(spoken(us, 'speaking'), 'spˈikɪŋ.');
      expect(spoken(us, 'studies'), 'stˈʌdiz.'); // ies → y + z
      expect(spoken(us, 'fastly'), 'fˈæstli.');
      expect(spoken(us, 'builder'), 'bˈɪldɜɹ.');
      expect(spoken(us, 'parameters'), 'pəɹˈæməTəɹz.');
      expect(spoken(us, 'students'), 'stˈudᵊnts.');
      expect(spoken(us, 'renamed'), 'ɹinˈAmd.');
    });

    test('possessives and light clitics after a stem', () {
      expect(spoken(us, "dog's"), 'dˈɔɡz.');
      // A plural possessive is just the plural — the apostrophe adds no
      // sound ("the dogs' bowls" speaks "dogz").
      expect(spoken(us, "dogs'"), 'dˈɔɡz.');
      expect(spoken(us, "you'll"), 'jul.');
      expect(spoken(us, "we're"), 'wɪɹ.');
    });

    test('compounds segment into dictionary pieces', () {
      expect(spoken(us, 'speakerphone'), 'spˈikəɹ fˈOn.');
      // 'xyzzy' has no entry, no stem and no pieces: the letter rules
      // speak it approximately rather than dropping it silent.
      expect(us.phonemize('xyzzy'), isNotEmpty);
    });

    test('punctuation survives attached, as espeak left it', () {
      final m = us.phonemize('Hello, world!');
      expect(String.fromCharCodes(m.first), 'həlˈO,');
      // A trailing '!' is already a stop — the engine's '.' rule stands
      // down when the piece ends in any trained punctuation.
      expect(spoken(us, 'Hello, world!'), 'həlˈO, wˈɜɹld!');
    });

    test('US files load first and GB drops its length marks', () {
      // Same word in both fixtures: first-loaded priority for the US
      // entry (the students read en-us today), no GB ɔː at all.
      expect(spoken(us, 'water'), 'wˈɔTəɹ.');
      // GB alone still speaks: ː stripped at parse (US-trained graph),
      // and the GB-only word proves the fallback dictionary works.
      expect(spoken(gb, 'water'), 'wˈɔtə.');
      expect(spoken(gb, 'ask'), 'ˈɑsk.');
      final both = LexiconPronouncer.loadAll([
        'test/fixtures/lexicon_mini_us.txt',
        'test/fixtures/lexicon-gb-mini.txt',
      ])!;
      expect(spoken(both, 'water'), 'wˈɔTəɹ.');
    });

    test('loadAll is null when no file is readable, never throws', () {
      expect(LexiconPronouncer.loadAll(['nope.txt']), isNull);
    });

    test('a full sentence through the engine as one line', () {
      expect(
        spoken(us, 'Run 2 tests, the dog is still fine.'),
        'ɹˈʌn tˈu tˈɛsts, ði dˈɔɡ ɪz stˈɪl fˈIn.',
      );
    });
  });
}
