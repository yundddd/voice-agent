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

  test('a comma-spliced sentence rides the +341 window, not the old cap', () {
    // The +232 headline said 60 words ship whole; the +341 tape said a
    // 20.8-second say gets cut by the ENGINE where WE wouldn't have.
    // So the window applies: this 430-char sentence halves at its only
    // comma, and each half — still over the window — halves again at
    // the middle word. No seam lands at the prose's first breath.
    final sentence =
        '${List.filled(30, 'clause').join(' ')} mark, '
        '${List.filled(29, 'more').join(' ')} filler words here.';
    expect(_words(sentence), 63);
    final chunks = splitForTts(sentence);
    expect(chunks.length, 4); // lead 15 clause, 15+mark, then the tail halved
    for (final c in chunks) {
      expect(c.length, lessThanOrEqualTo(maxChunkChars));
    }
    expect(chunks.join(' '), sentence); // lossless, in order
  });

  test('an overlong sentence halves at the comma nearest its middle', () {
    // 120 words with its only comma dead center: the seam lands at the
    // middle, not at the prose's first breath (the old greedy front-shave).
    // +341: each middle half is still over the window, so it halves
    // again at the middle word — the comma cut is still the FIRST cut.
    final text =
        '${List.filled(59, 'alpha').join(' ')} beta, '
        '${List.filled(60, 'omega').join(' ')}.';
    final chunks = splitForTts(text);
    expect(chunks.length, 8); // comma first, then each half halves twice
    expect(chunks[3].endsWith('beta,'), isTrue, reason: chunks[3]);
    expect(chunks.join(' '), text); // lossless, in order
  });

  test('the middle-most of several clause marks wins', () {
    // Commas at words 10 and 55 of 101: 55 is nearer the middle —
    // 'evenly' is the rule, 'first comma' was the old one. +341: the
    // window then halves each side; the comma nearest the middle is
    // still the first cut the law takes.
    final text =
        '${List.filled(9, 'one').join(' ')} two, '
        '${List.filled(44, 'mid').join(' ')} three, '
        '${List.filled(46, 'tail').join(' ')}.';
    final chunks = splitForTts(text);
    expect(chunks[2].endsWith('three,'), isTrue, reason: chunks[2]);
    expect(chunks.join(' '), text);
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

  test('a balanced cut folds its sub-breath tail instead of speaking it '
      'alone (+351: the runt tail the last reply exposed)', () {
    const text =
        "I checked all three, Kokoro and the students already split "
        'naturally at sentence and clause breaths, while Pocket\'s hidden '
        '200-character internal pass can still re-cut a merged chunk and '
        'weld short sentences without spaces. I sent you the audit, '
        'ttssplitaudit md.';
    final chunks = splitForTts(text);
    expect(chunks, hasLength(2));
    expect(
      chunks.last,
      endsWith('I sent you the audit, ttssplitaudit md.'),
      reason: chunks.last,
    );
    for (final c in chunks) {
      expect(c.length, greaterThanOrEqualTo(minBreathChars), reason: c);
    }
    expect(chunks.join(' '), text); // lossless, in order
  });

  test('terminator runs never split the sentence they end', () {
    // The '...' + closing quote is ONE boundary: the ellipsis and its
    // quote never orphan from each other. +233 still welds the sub-breath
    // tail onto its head, but the +341 window then halves the long head
    // (no clause mark keeps both sides on the floor except 'here.', and
    // even that cut's halves go back to the word fallback) — while the
    // welded '"Wait..." he said. Then silence.' rides whole.
    final text =
        'Words up front like ${List.filled(33, 'filler').join(' ')} here. '
        '"Wait..." he said. Then silence.';
    final chunks = splitForTts(text);
    // No clause mark inside keeps both sides on the floor, so the cut
    // is the middle word — and the ellipsis+quote+attribution run
    // rides on in one piece, attached to the prose it merges from.
    expect(chunks.last, endsWith('"Wait..." he said. Then silence.'));
    expect(chunks.last, contains('here. "Wait..."'));
    for (final c in chunks) {
      expect(c, isNot(matches(RegExp(r'\.\.\.\s*$'))), reason: c);
    }
    expect(chunks.join(' '), text);
  });

  test('one giant unpunctuated blob splits at middle words, recursively', () {
    // 250 bare words: no breath to take, so the sentence halves and
    // halves again — now under TWO triggers: [maxWords] for the graph
    // and, since +341, [maxChunkChars] for the breath window. The
    // halving stops when every piece fits a 15-second breath.
    final blob = List.filled(250, 'word').join(' ');
    final chunks = splitForTts(blob);
    expect(chunks.length, 8); // 1249 chars halve to ~156 — one floor each
    for (final c in chunks) {
      expect(c.length, lessThanOrEqualTo(maxChunkChars));
      expect(c.length, greaterThanOrEqualTo(minBreathChars), reason: c);
    }
    expect(chunks.join(' '), blob);
  });

  test('the +341 lead cut ends the first chunk at its earliest breath', () {
    // The latency law: whatever the sentence's fate, audio starts on
    // the first clause. A 30-word opener with a comma at word 6 ships
    // the comma-sized first chunk, and the tail rides on.
    final text =
        'Read this first clause out loud to me right now, and hear how '
        'quickly the voice gets going on a sentence that is comfortably '
        'longer than one clean breath.';
    final chunks = splitForTts(text);
    expect(chunks.first, 'Read this first clause out loud to me right now,');
    expect(chunks.first.length, greaterThanOrEqualTo(minBreathChars));
    expect(chunks.join(' '), text);
  });

  test('the lead cut never leaves a side under the breath floor', () {
    // 'Yes sir.' welded forward: the first mark's prefix is a greeting,
    // not a breath (+233's lesson restated for the new law) — no cut.
    const text =
        'Yes sir. The rest of this reply is comfortably long prose '
        'that keeps going past every runt it might have made.';
    expect(splitForTts(text).first, contains('Yes sir.'));
  });

  test('maxWords is the student graph budget (~510 phonemes)', () {
    expect(maxWords, 100);
    expect(maxChunkChars, 160); // ~15 s at the slowest measured engine
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
    // +341: 'Yes.' merges for the floor, the grown lead then rides alone,
    // and the remaining runt folds into its neighbour — no runts, one
    // extra seam, both laws intact.
    expect(pieces, hasLength(2));
    expect(pieces.first, startsWith('Yes.'));
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

  test('+341: the pocket merge never welds the lead breath back shut', () {
    // The lead chunk was cut short ON PURPOSE so Pocket's first audio
    // lands early; re-merging piece two onto it would undo the latency
    // win for the sake of one fewer ritual. A lead under the runt floor
    // still merges ('Yes.' alone garbles) — floor outranks latency.
    final merged = mergePocketChunks([
      'Here is the first clause, and it was cut deliberately short by '
      'the lead law.',
      'The second sentence is perfectly long enough to ride the merge '
      'into its neighbours.',
      'And a third joins it under the merge cap, as any well-behaved '
      'piece does.',
    ]);
    expect(merged.first, startsWith('Here is the first clause,'));
    expect(merged.length, greaterThan(1));
    expect(merged.join(' '), contains('And a third joins it')); // nothing lost
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

  test('pocketInternalSplit: ordinary prose, first sentence a runt', () {
    // Even an ordinary two-sentence reply welds when the FIRST sentence
    // is under 30 codepoints — 'Hello Tim.' buffers, the space is eaten,
    // and the model reads one run-together sentence. Over 30 for the
    // first sentence and this ships with its spaces intact.
    expect(
      pocketInternalSplit('Hello Tim. NeuTTS nano speaking, generated on device.'),
      ['Hello Tim.NeuTTS nano speaking, generated on device.'],
    );
    final big =
        'The quick brown fox jumps over the lazy dog. Another sentence here.';
    expect(pocketInternalSplit(big), [
      'The quick brown fox jumps over the lazy dog.',
      'Another sentence here.',
    ]);
  });

  test('pocketInternalSplit: the runt floor welds short sentences', () {
    // min_char_in_sentence 30: 'Yes.' (4) buffers until the buffer passes
    // 30 codepoints — the C++ twin of mergePocketChunks' runt floor. Note
    // the C++ quirk the mirror keeps: NeedSpaceBetween sees the LEFT side
    // always ending on a boundary char, so the weld eats the sentence
    // space — the model reads run-together text at every C++ merge.
    expect(
      pocketInternalSplit('Yes. The answer is forty-two characters long!'),
      ['Yes.The answer is forty-two characters long!'],
    );
  });

  test('pocketInternalSplit: the ritual prefix absorbs into sentence one', () {
    // '.... Hello Tim. How are...' — SplitByPunctuation flushes at every
    // dot (no word-char anchor), so the '....' prefix is four raw runts;
    // MergeShortSentences welds the chain, spaces eaten (see above). The
    // whole non-BOS fed text reads as one run-together C++ sentence —
    // exactly what the fed note must show when a pause sounds wrong.
    expect(
      pocketInternalSplit('.... Hello Tim. How are you today my friend.'),
      ['....Hello Tim.How are you today my friend.'],
    );
  });

  test('pocketInternalSplit: no word-char anchor, but the merge repairs it', () {
    // '3.5' fakes a boundary at C++'s anchorless flush (the difference
    // from OUR splitter) — and the runt merge puts it right back.
    expect(
      pocketInternalSplit('It costs 3.5 dollars total, ok.'),
      ['It costs 3.5 dollars total, ok.'],
    );
  });

  test('pocketInternalSplit: a merged piece over 200 re-splits at a comma '
      'near the window end, not the middle', () {
    // The +342 weak-seam shape, alive in C++: SplitLongSentence scans
    // BACK from the 200-codepoint mark, so the comma at codepoint 199
    // (nearest the end) takes the cut — 199 a's + ',' on the left.
    final s = '${'a' * 199}, bbbbb';
    expect(pocketInternalSplit(s), ['${'a' * 199},', 'bbbbb']);
  });

  test('pocketInternalSplit: markless text cuts at the window line', () {
    // No space, no boundary anywhere: the 250-char runt rides the window
    // whole, the tail ships alone (unsplittable-inside-the-floor's C++
    // cousin).
    final s = 'a' * 250;
    expect(pocketInternalSplit(s), ['a' * 200, 'a' * 50]);
  });
}
