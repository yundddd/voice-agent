// Sentence chunking for streamed synthesis (barge-in gaps + short first
// audio). Mirrors the Rust split_for_tts constants.
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/speech_worker.dart';

void main() {
  test('short replies stay one chunk', () {
    expect(
      splitForTts('Hello Tim. NeuTTS nano speaking, generated on device.'),
      ['Hello Tim. NeuTTS nano speaking, generated on device.'],
    );
    expect(splitForTts('No punctuation reply here'), [
      'No punctuation reply here',
    ]);
    expect(splitForTts(''), ['']);
  });

  test('long multi-sentence replies pack up to 40 words per chunk', () {
    final sentences = List.generate(
      6,
      (i) =>
          'Sentence number $i carries exactly twelve words to make the '
          'packing arithmetic testable, sorry ten.',
    );
    final chunks = splitForTts(sentences.join(' '));
    expect(chunks.length, greaterThan(1));
    for (final c in chunks) {
      expect(c.split(RegExp(r'\s+')).length, lessThanOrEqualTo(40));
    }
    // Nothing lost: every sentence appears in exactly one chunk, in order.
    final joined = chunks.join(' ');
    for (final s in sentences) {
      expect(joined.contains(s), isTrue, reason: 'lost: $s');
    }
  });

  test('terminator runs never split the sentence they end', () {
    // The '...' + closing quote is ONE boundary: the ellipsis must never
    // orphan the sentence's tail ('..."' + 'he said.' as separate chunks
    // would read as two utterances). 38-word first sentence pushes the
    // quoted 1-word sentence across the packer boundary so the test sees
    // exactly where the run stuck, then content must be lossless.
    final text =
        'Words up front like ${List.filled(33, 'filler').join(' ')} here. '
        '"Wait..." he said. Then silence.';
    final chunks = splitForTts(text);
    expect(chunks.length, 2);
    expect(chunks.first.endsWith('"Wait..."'), isTrue, reason: chunks.first);
    expect(chunks[1], 'he said. Then silence.');
    expect(chunks.join(' '), text); // nothing lost or reordered
  });

  test('clause marks split long replies; numbers never do', () {
    // One comma-spliced 60-word sentence with decimals and a thousands
    // group inside: commas are now cut points, but "1,000" and "3.14"
    // must survive whole, and the packer must still keep chunks ≤ 40.
    final nums = 'Costs hit 1,000 coins, with a ratio near 3.14 today, ';
    final clause =
        'and every clause after that comma keeps the sentence running '
        'with plainly ordinary spoken filler words for a while longer, ';
    final text =
        '$nums$clause$clause'
        'and then it ends.';
    final chunks = splitForTts(text);
    expect(chunks.length, greaterThan(1), reason: text);
    for (final c in chunks) {
      expect(c.split(RegExp(r'\s+')).length, lessThanOrEqualTo(40));
      expect(c, isNot(matches(RegExp(r'\d,\s'))), reason: 'split 1,000: $c');
      expect(c, isNot(matches(RegExp(r'\d\.\s'))), reason: 'split 3.14: $c');
    }
    expect(chunks.join(' '), text);
  });

  test('one giant sentence is hard-split at word boundaries', () {
    final blob = List.filled(120, 'word').join(' ');
    final chunks = splitForTts(blob);
    expect(chunks.length, 3);
    for (final c in chunks) {
      expect(c.split(' ').length, lessThanOrEqualTo(40));
    }
  });
}
