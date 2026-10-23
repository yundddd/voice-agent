import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/titl_engine.dart';
import 'package:voice_agent/src/speech/worker_backends.dart';

void main() {
  final vocab = <String, int>{
    for (final e
        in (jsonDecode(File('test/fixtures/titl_vocab.json').readAsStringSync())
                as Map<String, Object?>)
            .entries)
      e.key: (e.value as num).toInt(),
  };

  group('teacher-in-the-loop text plumbing', () {
    // The espeak fold tables retired with the plugin (the lexicon
    // pronouncer feeds pre-trained entries — see lexicon_test.dart);
    // what stays pinned here is the vocab assembly both paths share.
    test('unknown chars drop and a stop is appended', () {
      // 0x2044 (fraction slash) is not in the vocab: dropped, never
      // guessed — a wrong id would speak a wrong phoneme, a dropped
      // char only shortens one.
      final words = [
        'aʊ'.codeUnits, // both legal singletons here
        [0x2044],
      ];
      final ph = TitlEngine.phonemesFromWords(words, vocab.keys.toSet());
      expect(ph, 'aʊ.');
    });

    test('+343: rare breath marks fold onto the trained comma', () {
      // The field ear: 'the student sometimes just continues the next
      // word' over a ';' or '—' — in the vocab, too rare in the distill.
      expect(TitlEngine.breathe('wˈɔɹd; nˈɛkst'), 'wˈɔɹd, nˈɛkst');
      expect(TitlEngine.breathe('a—b–c…d'), 'a,b,c,d');
      // Stops, bangs, quests and commas ride untouched.
      expect(TitlEngine.breathe('a. b! c? d, e'), 'a. b! c? d, e');
      // The ladder: a piece ending on ';' joins the fold THEN the stop
      // rule — it lands on the ',.' tail a comma-cut piece already
      // ships today, not a breath-less tail.
      final ph = TitlEngine.phonemesFromWords(
        [
          'wˈɔɹd;'.codeUnits,
          'nˈɛkst'.codeUnits,
        ],
        vocab.keys.toSet(),
      );
      expect(ph, 'wˈɔɹd, nˈɛkst.');
    });

    test('ids are padded at both ends and stay under the graph window', () {
      final runs = TitlEngine.idsFromPhonemes('a b c.', vocab);
      expect(runs, hasLength(1));
      expect(runs.single.first, 0);
      expect(runs.single.last, 0);
      expect(runs.single, containsAll([vocab['a'], vocab[' ']]));
    });

    test('unknown characters never become ids', () {
      final runs = TitlEngine.idsFromPhonemes('\u{2044}a\u{2044}b', vocab);
      expect(runs.single, [0, vocab['a'], vocab['b'], 0]);
    });

    test('warm swallows a broken pack; first speech stays the messenger', () {
      // No lexicon, no model files, no native runtime in the host test:
      // every step fails and every failure is contained — buildTts's
      // await must not sink the worker over a pack it can re-fetch.
      TitlTts(
        models: const ['nope.onnx'],
        vocabs: const ['nope.json'],
        lexiconPaths: '',
      ).warm(0);
    });

    test('overflow splits at word boundaries inside T<=512', () {
      final long = List.filled(700, 'a').join(); // no spaces anywhere
      final runs = TitlEngine.idsFromPhonemes(long, vocab);
      expect(runs.length, greaterThan(1));
      for (final r in runs) {
        expect(r.length, lessThanOrEqualTo(512));
        expect(r.first, 0);
        expect(r.last, 0);
      }
      final spaced = List.filled(300, 'sa ').join(); // spaces to cut on
      final spacedRuns = TitlEngine.idsFromPhonemes(spaced, vocab);
      expect(spacedRuns.length, 2);
      expect(spacedRuns.first.length, lessThanOrEqualTo(512));
    });
  });
}
