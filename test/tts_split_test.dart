// Sentence chunking for streamed synthesis (VITS 44-second cap workaround +
// barge-in gaps). Mirrors the Rust split_for_tts constants.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/speech_worker.dart';

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
