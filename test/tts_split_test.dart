// Sentence chunking for streamed synthesis (barge-in gaps + short first
// audio). +232: the even-breath law — whole sentences ride, overlong
// ones halve at the clause mark nearest the middle (see tts_split.dart).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/speech/speech_worker.dart';

int _words(String c) =>
    c.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

void main() {
  test('short replies stay one chunk', () {
    // +233: 'Hello Tim.' is under the micro-breath floor and MERGES into
    // the next sentence — +232 shipped it as its own chunk and the field
    // heard the greeting clipped off its own answer.
    expect(
      splitForTts('Hello Tim. NeuTTS nano speaking, generated on device.'),
      ['Hello Tim. NeuTTS nano speaking, generated on device.'],
    );
    expect(splitForTts('No punctuation reply here'), [
      'No punctuation reply here',
    ]);
    expect(splitForTts(''), ['']);
  });

  test('a comma-spliced sentence under the cap ships WHOLE, commas intact', () {
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
      'packing (the old 40-word packer welded sentences across breaths)', () {
    final sentences = List.generate(
      6,
      (i) =>
          'Sentence number $i carries exactly twelve words to make the '
          'packing arithmetic testable, sorry ten.',
    );
    final chunks = splitForTts(sentences.join(' '));
    expect(chunks, sentences);
  });

  test('the field case: a salutation rides its sentence, not a seam of '
      'its own (+233: "I only heard hello")', () {
    const text =
        "Hello! The +233 APK should be on your phone's shelf whenever you "
        'want to try the new chunking.';
    expect(splitForTts(text), [text]);
  });

  test('a short sentence in the MIDDLE absorbs forward, then flows', () {
    // 'On it.' (6 chars) is no breath: it rides the sentence that follows.
    const text =
        'On it. The merge lands in the splitter and every greeting after '
        'this one rides its own answer in a single breath.';
    expect(splitForTts(text), [text]);
  });

  test('a trailing fragment merges BACKWARD when there is no next', () {
    // Long head + short tail: the tail has nowhere forward to go.
    const text =
        'Every chunk before this one clears the micro-breath floor with '
        'plenty of prose to spare, and keeps going. Yes it does.';
    expect(splitForTts(text), [text]);
  });

  test('terminator runs never split the sentence they end', () {
    // The '...' + closing quote is ONE boundary: the ellipsis and its
    // quote never orphan from each other. The boundary still ends that
    // quoted fragment's sentence; +233 then walks the short tail back —
    // '"Wait..."' < 'he said.' < 'Then silence.' are all sub-breath, so
    // the whole text is ONE chunk: the aside reattaches to the prose it
    // was always part of, lossless.
    final text =
        'Words up front like ${List.filled(33, 'filler').join(' ')} here. '
        '"Wait..." he said. Then silence.';
    final chunks = splitForTts(text);
    expect(chunks, [text]);
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

  test('pocket merge keeps every chunk past the runt-piece floor', () {
    // A 2-word opener like the probe line must never reach Pocket alone:
    // it garbles the first syllable and risks the max_frames runaway.
    final merged = mergePocketChunks(
      splitForTts(
        'Hello Tim. Pocket TTS speaking, generated entirely on this device.',
      ),
    );
    expect(merged, [
      'Hello Tim. Pocket TTS speaking, generated entirely on this device.',
    ]);
    // Short middling pieces get folded into their neighbours, in order,
    // with nothing lost — and now so do normal-sized sentences, up to the
    // merge cap, because every extra Generate call re-pays the cold-start
    // ritual (see mergePocketChunks): a whole short answer should be ONE
    // call and speak with the model's own pauses.
    final pieces = mergePocketChunks([
      'Yes.',
      'The tower is 330 metres tall, and it was completed in 1889.',
      'Quite famous.',
      'Victor Hugo admired it greatly.',
    ]);
    expect(pieces, hasLength(1)); // all one spoken paragraph now
    for (final p in pieces) {
      expect(p.length, greaterThanOrEqualTo(30));
    }
    expect(pieces.join(' '), contains('Quite famous.'));
    // Long answers chunk up instead of running past the frame guard:
    // every merged piece stays inside the cap, and NOTHING is lost —
    // the merged text is the original text, piece for piece.
    final text = List.filled(
      3,
      'The quick brown fox jumps over the lazy dog, and then it '
      'rests a while. Nearby birds sing softly under the wide '
      'and patient sky. Only later, in a dream, the fox '
      'remembers the day.',
    ).join(' ');
    final para = mergePocketChunks(splitForTts(text));
    expect(para.length, greaterThan(1)); // must actually chunk the big one
    for (final p in para) {
      expect(p.length, lessThanOrEqualTo(400 + 60)); // cap + one tail merge
      expect(p.length, greaterThanOrEqualTo(30)); // no runt escapes
    }
    expect(para.join(' '), text); // zero loss, zero reorder, no glue skew
    // An unmergeable lone runt stays as-is (nothing to merge into).
    expect(mergePocketChunks(['Yes.']), ['Yes.']);
  });

  test('pocket lead-in drops the warm-up growl and fades the cut', () {
    // 1.0 full-scale square through the drop region, then the 'speech' that
    // must survive, minus 250 ms, plus a 300 ms silence lead and 30 ms
    // fade (the generated '....' pause behind it carries the rest — see the
    // pocket synthesize arm).
    final s = Float32List(24000 * 2); // 1 s at 24 kHz
    for (var i = 1000; i < s.length; i++) {
      s[i] = 0.5; // 'Hello' content starts 42 ms in
    }
    final out = pocketLeadIn(s);
    expect(out.length, s.length - 6000 + 7200);
    // First 300 ms is the inserted silence (covers the post-capture output
    // ramp; the model-generated pause behind it covers the rest):
    expect(out.getRange(0, 7200).every((v) => v == 0), isTrue);
    // The fade opens soft (no click at the splice):
    expect(out[7200], lessThan(0.01));
    // ...and the surviving content is intact after fade + lead:
    expect(
      out.sublist(7200 + 720 + 1, out.length).every((v) => v == 0.5),
      isTrue,
    );
    // Runt outputs are passed through untouched rather than emptied:
    final tiny = Float32List.fromList([0.1, 0.2, 0.3]);
    expect(pocketLeadIn(tiny), tiny);
  });
}
