// The out-of-process espeak front-end (espeak_exec.dart): the Misaki
// fold is ported verbatim from the +167..+223 pipeline, and the golden
// below was produced by the SAME espeak-ng source at the SAME pruned
// data dir as the shipped binaries (host build, --ipa, file arg).
// If the fold or the vocabulary drifts, the students drift with it —
// this file is the drift alarm.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/espeak_exec.dart';

void main() {
  group('asset wiring', () {
    // +239: the first phone build died on 'Unable to load asset
    // assets/espeak-data/lang/gmw/en' — Flutter directory entries pack
    // ONLY the files directly inside them, so a subtree needs its own
    // pubspec line. This walk replays those exact semantics over the
    // real pubspec.yaml: whatever espeak_exec.dart asks rootBundle for
    // must be inside what the bundler would have packed.
    test('every espeak asset file is covered by a pubspec entry', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final declared = RegExp(r'^\s+- (assets\S+/)$', multiLine: true)
          .allMatches(pubspec)
          .map((m) => m.group(1)!)
          .toSet();
      // What a directory entry ACTUALLY bundles: plain files one deep.
      final bundled = <String>{
        for (final dir in declared)
          if (Directory(dir).existsSync())
            for (final e in Directory(dir).listSync())
              if (e is File) '$dir${e.uri.pathSegments.last}',
      };
      for (final rel in espeakAssetFiles) {
        final asset = '$espeakAssetPrefix/$rel';
        expect(File(asset).existsSync(), isTrue, reason: '$asset missing');
        expect(bundled, contains(asset), reason: '$asset declared nowhere');
      }
    });
  });

  group('foldEspeakEn', () {
    test('diphthongs collapse to the trained singletons', () {
      expect(foldEspeakEn('aʊ'), 'W'); // sound's OW, the "sown" bug
      expect(foldEspeakEn('aɪ'), 'I');
      expect(foldEspeakEn('eɪ'), 'A');
      expect(foldEspeakEn('ɔɪ'), 'Y');
      expect(foldEspeakEn('oʊ'), 'O');
      expect(foldEspeakEn('dʒ'), 'ʤ');
      expect(foldEspeakEn('tʃ'), 'ʧ');
    });

    test('US branch: length marks gone, NURSE gains its r', () {
      expect(foldEspeakEn('ɜː'), 'ɜɹ');
      expect(foldEspeakEn('ɡəˈɬ'), 'ɡəˈl'); // ɬ routes to l
      // A lone 'e' is the GOAT fold; 'æ' itself is untouched:
      expect(foldEspeakEn('bˈetən'), 'bˈAtən');
    });

    test('syllabic diacritics become the ᵊ convention', () {
      expect(foldEspeakEn('bˈɑt̩n'), 'bˈɑᵊtn');
      expect(foldEspeakEn('fˈɪʃəɫ'), contains('ɫ')); // lateral stays
    });
  });

  group('EspeakExec.phonemesFromIpa', () {
    // Produced by: espeak-ng -v en-us --ipa on
    // "APK TTS UI read the log file, 2 megabytes" with the shipped
    // pruned data. The regression is in the CONTENT: letter names for
    // every initialism (the +238 report: APK said "a-pick" through the
    // dictionary ladder), spelled words for the number.
    const goldenIpa =
        'ˌeɪpˌiːkˈeɪ tˌiːtˌiːˈɛs jˌuːˈaɪ ɹˈiːd ðə lˈɔɡ fˈaɪl '
        'tˈuː mˈɛɡəbˌaɪts';
    const goldenFolded =
        'ˌApˌikˈA tˌitˌiˈɛs jˌuˈI ɹˈid ðə lˈɔɡ fˈIl '
        'tˈu mˈɛɡəbˌIts.';

    // A vocab that lets the whole golden through (the real vocab.json
    // is a superset — these are all Kokoro alphabet rows).
    final vocab = {for (final c in goldenFolded.split('')) c, ' ', '.'};

    test('golden IPA folds to the trained alphabet verbatim', () {
      expect(EspeakExec.phonemesFromIpa(goldenIpa, vocab), goldenFolded);
    });

    test('the alias pass lands on the trained ids, after the fold', () {
      // ä is NOT a fold entry: it is an alias, applied by
      // phonemesFromIpa — one pass, no rescue route back to T→θ.
      expect(
        EspeakExec.phonemesFromIpa('bˈätən', {
          'b',
          'ˈ',
          'ə',
          't',
          'n',
          '.',
          ' ',
        }),
        'bˈətən.',
      );
    });

    test('a trailing stop is ensured for sentence intonation', () {
      expect(
        EspeakExec.phonemesFromIpa('hˈɛloʊ', {'h', 'ˈ', 'ɛ', 'l', 'O', '.'}),
        'hˈɛlO.',
      );
      expect(
        EspeakExec.phonemesFromIpa('dˈɒn.', {'d', 'ˈ', 'ɒ', 'n', '.'}),
        'dˈɒn.',
      );
    });

    test('foreign chars drop against the vocab — never guessed', () {
      // 'ɛ' and 'ø' are absent from the tiny vocab: only the overlap
      // survives, and nothing is mapped to a nearby trained sound.
      expect(EspeakExec.phonemesFromIpa('œ ø ɛ', {'ɛ', ' ', '.', 'ˈ'}), 'ɛ.');
    });
  });
}
