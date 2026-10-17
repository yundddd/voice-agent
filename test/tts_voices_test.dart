import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/tts_voices.dart';

void main() {
  group('student voice roster (per-sid packs)', () {
    final titl = voiceById('titl')!;

    test('three style packs, one graph each', () {
      expect(titl.perSidPacks, isTrue);
      expect(titl.packs.map((p) => p.dirName), [
        'tts-titl-af_heart',
        'tts-titl-if_sara',
        'tts-titl-im_nicola',
      ]);
      expect(titl.staticRoster?.map((s) => s.name), [
        'af_heart',
        'if_sara',
        'im_nicola',
      ]);
      // The roster sid must index the packs list (specIn builds both
      // in pack order; TitlTts indexes them the same way).
      expect(titl.staticRoster!.map((s) => s.sid), [0, 1, 2]);
    });

    test('installed with only one style pack on disk', () async {
      final dir = Directory.systemTemp.createTempSync('models');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(await titl.installedIn(dir.path), isFalse);
      Directory('${dir.path}/tts-titl-if_sara').createSync();
      File('${dir.path}/tts-titl-if_sara/model.onnx').writeAsBytesSync([0]);
      expect(await titl.installedIn(dir.path), isTrue);
      // Kokoro (single pack) still demands its one pack: the flag off.
      final kokoro = voiceById('kokoro')!;
      expect(kokoro.perSidPacks, isFalse);
      expect(await kokoro.installedIn(dir.path), isFalse);
    });

    test('the old single-student voice id migrates', () {
      final p = TtsPrefs.fromJson({'voice': 'titl-heart', 'sid': 0});
      expect(p.voiceId, 'titl');
      expect(TtsPrefs.fromJson({}).voiceId, 'kokoro');
      expect(TtsPrefs.fromJson({'voice': 'kokoro', 'sid': 3}).sid, 3);
    });

    test('the picked sid rides the spec (switching speaks the switch)', () {
      // The regression: titlSpec dropped the sid, so the worker's
      // synth default stayed on pack 0 and every style after the
      // first silently spoke af_heart.
      final spec = titl.titlSpec('/models', '/data', 2);
      expect(spec.engine, 'titl');
      expect(spec.sid, 2);
      final paths = spec.titlModels.split(',');
      expect(paths, hasLength(3));
      expect(paths[2], endsWith('tts-titl-im_nicola/model.onnx'));
      expect(
        spec.titlVocabs.split(',').elementAt(2),
        endsWith('tts-titl-im_nicola/vocab.json'),
      );
      expect(spec.espeakVoices.split(','), ['en-us', 'it', 'it']);
    });
  });
}
