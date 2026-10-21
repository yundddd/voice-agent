// Sentence chunking for streamed synthesis (barge-in gaps + short first
// audio). +232: the even-breath law — whole sentences ride, overlong
// ones halve at the clause mark nearest the middle (see tts_split.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/speech_worker.dart';

int _words(String c) => c.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

void main() {
  test('short replies stay one chunk', () {
    // +232: 'Hello Tim.' is its own sentence and its own chunk — the old
    // packer welded it to the next one; one breath per sentence now.
    expect(
      splitForTts('Hello Tim. NeuTTS nano speaking, generated on device.'),
      ['Hello Tim.', 'NeuTTS nano speaking, generated on device.'],
    );
    expect(splitForTts('No punctuation reply here'), [
      'No punctuation reply here',
    ]);
    expect(splitForTts(''), ['']);
  });

  test('a comma-spliced sentence under the cap ships WHOLE, commas intact',
      () {
    // The +232 headline: this is the shape the old 40-word packer shaved
    // into clause shreds; 60 words is one breath to the new law.
    final sentence =
        '${List.filled(30, 'clause').join(' ')} mark, '
        '${List.filled(29, 'more').join(' ')} filler words here.';
    expect(_words(sentence), 63);
    expect(splitForTts(sentence), [sentence]);
  });

  test('an overlong sentence halves at the comma nearest its middle', () {
    // 120 words with its only comma dead center: the seam lands at the
    // middle, not at the prose's first breath (the old greedy front-shave).
    final text =
        '${List.filled(59, 'alpha').join(' ')} beta, '
        '${List.filled(60, 'omega').join(' ')}.';
    final chunks = splitForTts(text);
    expect(chunks.length, 2);
    expect(_words(chunks[0]), 60);
    expect(_words(chunks[1]), 60);
    expect(chunks.first.endsWith('beta,'), isTrue, reason: chunks.first);
    expect(chunks.join(' '), text); // lossless, in order
  });

  test('the middle-most of several clause marks wins', () {
    // Commas at words 10 and 55 of 101: 55 is nearer the middle (50) —
    // 'evenly' is the rule, 'first comma' was the old one.
    final text =
        '${List.filled(9, 'one').join(' ')} two, '
        '${List.filled(44, 'mid').join(' ')} three, '
        '${List.filled(46, 'tail').join(' ')}.';
    final chunks = splitForTts(text);
    expect(chunks.length, 2);
    expect(chunks.first.endsWith('three,'), isTrue, reason: chunks.first);
  });

  test('numbers never fake a breath', () {
    // The only real comma is 'coins,' at word 20; '1,000' and '3.14' sit
    // mid-sentence as decoys. The sentence must cut at the real mark and
    // no chunk may end inside a number.
    final text =
        'Costs hit 1,000 coins, with a ratio near 3.14 today and '
        '${List.filled(100, 'plain').join(' ')} spoken filler words.';
    final chunks = splitForTts(text);
    expect(chunks.length, greaterThan(1), reason: text);
    for (final c in chunks) {
      expect(c, isNot(matches(RegExp(r'\d,\s*$'))), reason: 'split 1,000: $c');
      expect(c, isNot(matches(RegExp(r'\d\.\s*$'))), reason: 'split 3.14: $c');
    }
    expect(chunks.first.endsWith('coins,'), isTrue, reason: chunks.first);
    expect(chunks.join(' '), text);
  });

  test('multi-sentence replies stay one chunk PER sentence — no greedy '
      'packing (the old 40-word packer welded sentences across breaths)',
      () {
    final sentences = List.generate(
      6,
      (i) =>
          'Sentence number $i carries exactly twelve words to make the '
          'packing arithmetic testable, sorry ten.',
    );
    final chunks = splitForTts(sentences.join(' '));
    expect(chunks, sentences);
  });

  test('terminator runs never split the sentence they end', () {
    // The '...' + closing quote is ONE boundary: the ellipsis and its
    // quote never orphan from each other. The boundary still ends that
    // quoted fragment's sentence (the period after 'said' ends the next);
    // +232 gives each its own chunk, none long enough to halve.
    final text =
        'Words up front like ${List.filled(33, 'filler').join(' ')} here. '
        '"Wait..." he said. Then silence.';
    final chunks = splitForTts(text);
    expect(chunks.length, 4);
    expect(chunks[1], '"Wait..."');
    expect(chunks[2], 'he said.');
    expect(chunks[3], 'Then silence.');
    expect(chunks.join(' '), text); // nothing lost or reordered
  });

  test('one giant unpunctuated blob splits at middle words, recursively', () {
    // 250 bare words: no breath to take, so the sentence halves (125/125),
    // each half still too long halves again — four even pieces, every one
    // inside the graph's budget. The old law made three 40-word shavings
    // and one ragged tail.
    final blob = List.filled(250, 'word').join(' ');
    final chunks = splitForTts(blob);
    expect(chunks.length, 4);
    for (final c in chunks) {
      expect(_words(c), lessThanOrEqualTo(maxWords));
      expect(_words(c), greaterThanOrEqualTo(60), reason: 'uneven: $c');
    }
    expect(chunks.join(' '), blob);
  });

  test('maxWords is the student graph budget (~510 phonemes)', () {
    expect(maxWords, 100);
  });
}
