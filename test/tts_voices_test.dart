import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/tts_voices.dart';

void main() {
  group('student voice (espeak-free, English-only)', () {
    final titl = voiceById('titl')!;

    test('one style pack + the shared lexicon', () {
      expect(titl.perSidPacks, isTrue);
      expect(titl.packs.map((p) => p.dirName), ['tts-titl-af_heart']);
      expect(titl.staticRoster?.map((s) => s.name), ['af_heart']);
      // The roster sid must index the packs list (specIn builds both
      // in pack order; TitlTts indexes them the same way).
      expect(titl.staticRoster!.map((s) => s.sid), [0]);
    });

    test('installed once the style pack AND the lexicon are on disk', () async {
      final dir = Directory.systemTemp.createTempSync('models');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await titl.installedIn(dir.path), isFalse);
      Directory('${dir.path}/tts-titl-af_heart').createSync();
      File('${dir.path}/tts-titl-af_heart/model.onnx').writeAsBytesSync([0]);
      // The style graph alone is NOT installed anymore: without the
      // shared lexicon the voice cannot phonemize, and 'installed'
      // gates the startup download.
      expect(await titl.installedIn(dir.path), isFalse);
      Directory('${dir.path}/tts-lexicon-en').createSync();
      File(
        '${dir.path}/tts-lexicon-en/lexicon-us-en.txt',
      ).writeAsBytesSync([0]);
      expect(await titl.installedIn(dir.path), isTrue);
      // Kokoro (single pack) still demands its one pack: the flag off.
      final kokoro = voiceById('kokoro')!;
      expect(kokoro.perSidPacks, isFalse);
      expect(await kokoro.installedIn(dir.path), isFalse);
    });

    test('the old single-student voice id migrates', () {
      final p = TtsPrefs.fromJson({'voice': 'titl-heart', 'sid': 0});
      expect(p.voiceId, 'titl');
      expect(
        TtsPrefs.fromJson({}).voiceId,
        'titl',
        reason: 'the students are the shipped default: 9 MB, not 334',
      );
      expect(
        TtsPrefs.fromJson({'voice': 'kokoro', 'sid': 3}).sid,
        3,
        reason: 'Kokoro keeps 54 styles inside its one pack — no clamp',
      );
    });

    test('retired Italian student sids land back on af_heart', () {
      // if_sara/im_nicola were sids 1–2; their packs are gone from the
      // voice, and TitlTts can no longer fall back through espeak.
      expect(TtsPrefs.fromJson({'voice': 'titl', 'sid': 1}).sid, 0);
      expect(TtsPrefs.fromJson({'voice': 'titl', 'sid': 2}).sid, 0);
    });

    test('the picked sid rides the spec (switching speaks the switch)', () {
      // The regression: titlSpec dropped the sid, so the worker's
      // synth default stayed on pack 0 and every style after the
      // first silently spoke af_heart.
      final spec = titl.titlSpec('/models', 0);
      expect(spec.engine, 'titl');
      expect(spec.sid, 0);
      final paths = spec.titlModels.split(',');
      expect(paths, hasLength(1));
      expect(paths[0], endsWith('tts-titl-af_heart/model.onnx'));
      expect(
        spec.titlVocabs.split(',').single,
        endsWith('tts-titl-af_heart/vocab.json'),
      );
    });

    test('lexicon candidates: US before GB, shared pack first', () {
      // The espeak-free front-end reads whichever copies exist; order
      // pins that a student-only install's pack wins over the teacher
      // pack's, and that US entries beat GB (the students only ever
      // read en-us).
      final spec = titl.titlSpec('/models', 0);
      expect(spec.lexiconPaths.split(','), [
        '/models/tts-lexicon-en/lexicon-us-en.txt',
        '/models/kokoro-multi-lang-v1_0/lexicon-us-en.txt',
        '/models/tts-lexicon-en/lexicon-gb-en.txt',
        '/models/kokoro-multi-lang-v1_0/lexicon-gb-en.txt',
      ]);
      expect(titl.sharedPacks.map((p) => p.dirName), ['tts-lexicon-en']);
      // A missing lexicon is loud (TitlException names the pack), so
      // 'installed' must not pretend a half-download is a working voice.
    });
  });

  group('pocket voice (six preset references, one pack)', () {
    final pocket = voiceById('pocket')!;

    test('one pack, six named styles, sentinel-marked', () {
      expect(pocket.perSidPacks, isFalse);
      expect(pocket.packs.map((p) => p.dirName), ['pocket-tts']);
      // The sentinel (not model.onnx) is the installed-marker: bumping
      // its name in the pack is how the app forces a re-download.
      expect(pocket.packs.single.markerFile, 'pack-v2.ok');
      // Roster order == pocketRefs order == the pack script's ORDER —
      // a drift here would silently relabel every preset.
      expect(
        pocket.staticRoster!.map((s) => s.sid),
        List.generate(TtsVoice.pocketRefs.length, (i) => i),
      );
      expect(pocket.staticRoster!.map((s) => s.name), [
        'Jane',
        'Anna',
        'Jean',
        'Michael',
        'Alba',
        'Bill Boerst',
      ]);
    });

    test('installed once the sentinel is on disk', () async {
      final dir = Directory.systemTemp.createTempSync('models');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await pocket.installedIn(dir.path), isFalse);
      Directory('${dir.path}/pocket-tts').createSync();
      File('${dir.path}/pocket-tts/pack-v2.ok').writeAsBytesSync([0]);
      expect(await pocket.installedIn(dir.path), isTrue);
    });

    test(
      'the picked sid rides the spec and indexes the reference wavs',
      () async {
        final spec = await pocket.specIn('/models', sid: 5);
        expect(spec.engine, 'pocket');
        expect(spec.sid, 5); // TitlTts-style regression guard: dropping the
        // sid from the spec spoke preset 0 no matter what was picked.
        expect(spec.pocketRefs, hasLength(6));
        expect(spec.pocketRefs[5], '/models/pocket-tts/voices/bill_boerst.wav');
        expect(spec.pocketLmMain, '/models/pocket-tts/lm_main.onnx');
        expect(spec.pocketNumSteps, 2); // kyutai distilled 1-step decoder
      },
    );

    test('pocket sids are not clamped like per-sid packs', () {
      // Six styles live inside the one pack (like Kokoro's 54): an old
      // pick of sid 3 must survive to speak preset 3, not snap to 0.
      expect(TtsPrefs.fromJson({'voice': 'pocket', 'sid': 3}).sid, 3);
    });
  });
}
