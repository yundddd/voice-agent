import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:piper_phonemize/piper_phonemize.dart' as piper;
import 'package:voice_agent/src/speech/titl_engine.dart';

void main() {
  final vocab = <String, int>{
    for (final e
        in (jsonDecode(
              File('test/fixtures/titl_vocab.json').readAsStringSync(),
            )
                as Map<String, Object?>)
            .entries)
      e.key: (e.value as num).toInt(),
  };

  group('teacher-in-the-loop text plumbing', () {
    test('aliases fold, unknowns drop, a stop is appended', () {
      // espeak 'think' older IPA uses 'T'; 'ɾ' folds to 'ɹ'; the bogus
      // codepoint 0x2044 (fraction slash) is not in the vocab.
      final words = [
        'Tɪŋk'.codeUnits,
        'ɾaT'.codeUnits,
        [0x2044],
      ];
      final ph = TitlEngine.phonemesFromWords(words, vocab.keys.toSet());
      expect(ph, 'θɪŋk ɹaθ.');
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

  group('live espeak-ng phonemizer (host native)', () {
    test('Hello world maps to a non-trivial id run', () async {
      // flutter test can't resolve package URIs; read the generated
      // package config instead and point at the pub cache copy.
      final cfg = (jsonDecode(
        File('.dart_tool/package_config.json').readAsStringSync(),
      ) as Map<String, Object?>)['packages'] as List;
      final entry = cfg
          .cast<Map<String, Object?>>()
          .firstWhere((m) => m['name'] == 'piper_phonemize');
      final pkgRoot = Uri.parse(entry['rootUri'] as String).toFilePath();
      final dataDir = '$pkgRoot/espeak-ng-data';
      if (!Directory(dataDir).existsSync()) return; // packaged differently
      await piper.initBindingsAsync('$pkgRoot/linux/x64');
      piper.PiperPhonemize.initialize(dataDir);
      final words = piper.PiperPhonemize.phonemize(
        'Hello world, this works.',
        voice: 'en-us',
      );
      expect(words, isNotEmpty);
      final ph = TitlEngine.phonemesFromWords(words, vocab.keys.toSet());
      expect(ph.length, greaterThan(8));
      final runs = TitlEngine.idsFromPhonemes(ph, vocab);
      expect(runs.single.length, greaterThan(10));
      // 'hello' survives as o + stress-ish IPA: sanity that we are not
      // looking at an empty drop-everything pass.
      expect(runs.single.any((id) => id == vocab['o'] || id == vocab['ə']), isTrue);
    });
  });
}
