// One-off audit: what does espeak-ng actually emit for English text, and
// which of those characters silently drop against the TITL pack's
// vocab.json after the alias folding in titl_engine.dart?
import 'dart:convert';
import 'dart:io';

import 'package:piper_phonemize/piper_phonemize.dart' as piper;
import 'package:voice_agent/src/speech/titl_engine.dart';

Future<void> main() async {
  const root = '/home/tim/voice-agent/third_party/piper_phonemize';
  await piper.initBindingsAsync('$root/linux/x64');
  piper.PiperPhonemize.initialize('$root/espeak-ng-data');

  final vocab = <String, int>{
    for (final e
        in (jsonDecode(
                  File('/tmp/opencode/titl/pack/vocab.json').readAsStringSync(),
                )
                as Map<String, Object?>)
            .entries)
      e.key: (e.value as num).toInt(),
  };

  const lines = [
    ('en-us', 'Hi! This is how your assistant will sound with this voice.'),
    ('en-us', 'Getting bigger again — good morning, gorgeous.'),
    ('en-us', 'The thing that gets big is bigger: getting going gets going.'),
    (
      'en-us',
      'Hello from the small student. I am eight million parameters of '
          'Kokoro, distilled down to nine megabytes, and I still sound '
          'like the teacher.',
    ),
    // The Italian students: espeak 'it' against the same Kokoro vocab.
    ('it', 'Buongiorno! Ecco come suona il vostro assistente con questa voce.'),
    (
      'it',
      'Oggi è una splendida giornata: temperatura dodici gradi, cielo '
          'sereno, vento da nord-est. Ricordati la riunione di domani.',
    ),
    (
      'it',
      'Posso preparare il riepilogo oppure riprogrammare, come preferisci.',
    ),
  ];
  final dropped = <String, int>{};
  for (final (voice, line) in lines) {
    final words = piper.PiperPhonemize.phonemize(line, voice: voice);
    final raw = words.map((w) => String.fromCharCodes(w)).join(' ');
    final folded = TitlEngine.phonemesFromWords(words, vocab.keys.toSet());
    stdout.writeln('[$voice] text: $line');
    stdout.writeln('[$voice] espeak: $raw');
    stdout.writeln('[$voice] fed   : $folded');
    for (final c in raw.runes.map(String.fromCharCode)) {
      final f = espeakAliases[c] ?? c;
      if (!vocab.containsKey(f)) dropped[c] = (dropped[c] ?? 0) + 1;
    }
    stdout.writeln('');
  }
  stdout.writeln('DROPPED CHARS (char: count, codepoint):');
  for (final e in dropped.entries) {
    stdout.writeln(
      '  ${e.key.replaceAll('\n', ' ')}  x${e.value}  '
      'U+${e.key.runes.first.toRadixString(16).toUpperCase()}',
    );
  }
}
