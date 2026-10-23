/// Sentence/word chunking for streamed TTS — pure, tested in
/// test/tts_split_test.dart. Lives apart from the isolate plumbing so the
/// rules can grow (and be reused by the bridge's own relay) without
/// touching worker messages.
///
/// +232 — the even-breath law. The bridge now relays whole sentences
/// (tool/sentence_relay.mjs retired its clause cuts after the field
/// report "very short chunks"), and THIS file owns every seam inside a
/// sentence. The old rule packed greedily to 40 words: a sentence that
/// didn't fit was shaved from the front, one clause at a time, so the
/// voice always broke at the prose's FIRST comma — the worst place for
/// the seam, front-loading the chop and leaving the tail a ragged run.
/// The new rule asks only whether a sentence is too long for one
/// breath ([maxWords]) and, when it is, cuts at the clause mark closest
/// to its MIDDLE, recursively: two roughly even halves, each still one
/// breath if it can be. The seam lands where the sentence is widest,
/// and short sentences — the overwhelming majority of spoken replies —
/// ship whole, commas and all, under one intonation contour.
/// [maxWords] is 100, not an aesthetic number: it is the student
/// graph's real ceiling (TitlEngine caps a run at 510 phonemes, ~100
/// words of English) and this splitter's only job is to keep graph
/// input inside it politely. The engine's own split remains the last
/// backstop — a chunk that still overruns is cut at the last space in
/// budget, never dropped.
///
/// +341 — the window and the lead cut. Two field truths re-tuned the
/// law: a cap-fitting sentence still outlives one breath (the tape: a
/// 20.8-second say whose internal pause the LISTENER heard, made by the
/// engine's own clause pass because OUR splitter waved a 48-word
/// sentence whole), and the only real win in going smaller is the
/// FIRST chunk — at RTF ~0.1 the pipeline computes ten seconds of audio
/// per second of playback, so after the first breath every chunk is
/// already invisible; uniform tiny chunks would buy nothing but seams.
/// So: (1) the window — a chunk may not exceed [maxChunkChars],
/// a duration budget expressed in characters because every engine's
/// measured speaking rate is characters-to-seconds (Pocket ~10 c/s
/// slowest, Kokoro ~13-15); [maxWords] stays as the student graph's
/// phoneme backstop, and a window cut with no clause mark willing both
/// sides on the floor ships whole rather than chop; (2) the lead cut —
/// the FIRST chunk of a reply ends at its earliest breath mark (clause
/// OR a sentence terminator a +233 merge welded in) where both sides
/// keep [minBreathChars], so audio starts on the first clause while
/// every later chunk rides the window like any other. Pocket's merge
/// re-welds the tail pieces for its per-call ritual, but the lead
/// chunk stays alone by law: it is the one whose size IS the latency.
library;

/// Hard ceiling on one synthesized chunk (~510 phonemes; see the law
/// above).
const int maxWords = 100;

/// +341: the breath window — ~15 seconds of audio at the SLOWEST
/// measured engine rate (Pocket, ~10 chars/s; Kokoro lands ~11 s).
/// A duration budget, stated in characters: the engines disagree on
/// phonemes, frames and words, but all three have been timed in
/// characters per second by the round-trip bench.
const int maxChunkChars = 160;

/// +233 — the floor under a breath. The per-sentence law shipped a
/// bug the old packer had hidden: 'Hello! The +232 APK should be…'
/// relayed as ONE bridge frame was cut into 'Hello!' + its sentence,
/// and the field heard the greeting's own falling intonation, a seam,
/// and the answer starting over — 'your first chunk audio is completely
/// cut off before this next chunk audio starts playing'. A two-word
/// salutation is not a breath; the same micro-segment lesson the bridge
/// learned as MIN_SENT_CHARS, restated where sentences are now cut.
/// So a sentence SHORTER than this merges with its neighbour (forward,
/// or backward for a trailing fragment) instead of standing alone —
/// exactly what the greedy packer accidentally did for every short
/// 'Sure.' and 'OK.' the old law ever shipped.
const int minBreathChars = 40;

/// Split [text] into speakable chunks: one per sentence, and a sentence
/// over [maxWords] words recursively halved at the clause mark
/// (, ; : — –) nearest its middle — a mark only counts at a word's end
/// (optionally inside closing quotes/brackets), so "3.14", "1,000" and
/// "main.dart:801" never fake a breath. Text with no punctuation still
/// splits (at the middle WORD) rather than overrun the graph; the
/// sentence-terminator runs (. ! ?) keep every mark they end attached.
/// Lossless: chunks rejoined with a single space reproduce the trimmed
/// input's words in order.
List<String> splitForTts(String text) {
  final t = text.trim();
  if (t.isEmpty) return const [''];
  final chunks = <String>[];
  for (final (start, end) in _merged(t, _sentences(t))) {
    _balance(t, start, end, chunks);
  }
  // +341: the lead cut — the first chunk ends at its earliest breath.
  if (chunks.isNotEmpty) {
    final lead = chunks.removeAt(0);
    final cut = _leadSplit(lead);
    if (cut != null) {
      chunks.insert(0, cut[1]);
      chunks.insert(0, cut[0]);
    } else {
      chunks.insert(0, lead);
    }
  }
  return chunks;
}

/// The +341 lead cut: split [s] right after its earliest word that ends
/// on a breath — a clause mark ([_endsAtBreath]) OR a sentence
/// terminator (+233's merges weld whole sentences together, and a
/// period is the widest breath there is) — but only where BOTH sides
/// keep [minBreathChars]: a 6-word opener is the clipped-greeting bug
/// wearing a latency story. Null when no mark qualifies: the chunk
/// rides alone and whole.
List<String>? _leadSplit(String s) {
  final ranges = _wordRanges(s, 0, s.length);
  for (var k = 0; k < ranges.length - 1; k++) {
    final (wStart, wEnd) = ranges[k];
    if (!_endsAtBreath(s, (wStart, wEnd)) && !_endsTerminator(s, (wStart, wEnd))) {
      continue;
    }
    if (wEnd < minBreathChars) continue; // prefix too short to be a breath
    var right = wEnd;
    while (right < s.length && _isWs(s.codeUnitAt(right))) {
      right += 1;
    }
    if (s.length - right < minBreathChars) continue; // tail runt
    return [s.substring(0, wEnd), s.substring(right)];
  }
  return null;
}

/// Does this word end on a sentence-terminator run (. ! ?), optionally
/// inside closing quotes/brackets — the same attachment law _sentences
/// applies to real boundaries?
bool _endsTerminator(String t, (int, int) word) {
  var e = word.$2;
  final lo = word.$1;
  while (e > lo) {
    final c = t.codeUnitAt(e - 1);
    if (c == 0x22 || c == 0x27 || c == 0x29 || c == 0x5D || c == 0x7D ||
        c == 0x2E || c == 0x21 || c == 0x3F) {
      e -= 1; // trailing closer or terminator: keep walking back
      continue;
    }
    break;
  }
  if (e == word.$2 || e <= lo) return false;
  final c = t.codeUnitAt(e - 1);
  return c == 0x2E || c == 0x21 || c == 0x3F;
}

/// Merge sub-breath sentences into their neighbours: forward while a
/// run is shorter than [minBreathChars], and backward for a trailing
/// fragment ('he said.' at the very end has no next to join). Ranges
/// stay contiguous spans of [t], so the merged sentence's own
/// whitespace rides along and the chunks stay lossless.
List<(int, int)> _merged(String t, List<(int, int)> ranges) {
  final out = <(int, int)>[];
  for (final r in ranges) {
    if (out.isNotEmpty && _short(t, out.last)) {
      out[out.length - 1] = (out.last.$1, r.$2);
    } else {
      out.add(r);
    }
  }
  if (out.length > 1 && _short(t, out.last)) {
    final last = out.removeLast();
    out[out.length - 1] = (out.last.$1, last.$2);
  }
  return out;
}

bool _short(String t, (int, int) r) =>
    t.substring(r.$1, r.$2).trim().length < minBreathChars;

/// Sentence ranges (start, end) of [t] split at [.!?] runs (with any
/// trailing quotes/brackets) followed by whitespace or end-of-text.
/// Clause marks do NOT end a sentence — +232 gave them to [_balance].
List<(int, int)> _sentences(String t) {
  final out = <(int, int)>[];
  final b = t.codeUnits;
  var start = 0, i = 0;
  while (i < b.length) {
    final c = b[i];
    final term = c == 0x2E || c == 0x21 || c == 0x3F; // . ! ?
    final boundary =
        term &&
        (i + 1 == b.length ||
            _isWs(b[i + 1]) ||
            (i + 2 < b.length &&
                (b[i + 1] == 0x22 || b[i + 1] == 0x27 || b[i + 1] == 0x29)));
    if (boundary) {
      var end = i + 1;
      while (end < b.length &&
          (b[end] == 0x2E ||
              b[end] == 0x21 ||
              b[end] == 0x3F ||
              b[end] == 0x2C ||
              b[end] == 0x3B ||
              b[end] == 0x29 ||
              b[end] == 0x22 ||
              b[end] == 0x27)) {
        end += 1;
      }
      out.add((start, end));
      start = end;
      while (start < b.length && _isWs(b[start])) {
        start += 1;
      }
      i = start;
      continue;
    }
    i += 1;
  }
  if (start < t.length) out.add((start, t.length));
  return out..removeWhere((r) => t.substring(r.$1, r.$2).trim().isEmpty);
}

/// Emit the chunks of t[start:end]: whole when the sentence fits one
/// breath ([maxWords] for the graph's phoneme budget, [maxChunkChars]
/// for the +341 window), else recursively cut at the breath-mark
/// nearest its MIDDLE position. Candidates that keep [minBreathChars]
/// on both sides win outright; among the rest, the mark nearest the
/// middle still beats the middle word, and the middle word still beats
/// overrun. Truly unsplittable text ships whole — the engine's own
/// split is the backstop for a 2-kiloword monster.
void _balance(String t, int start, int end, List<String> out) {
  final words = _wordRanges(t, start, end);
  if (words.length <= maxWords && end - start <= maxChunkChars) {
    final s = t.substring(start, end).trim();
    if (s.isNotEmpty) out.add(s);
    return;
  }
  // Cut candidates = after word k, k in [0, len-2] (both sides non-empty).
  // +341: the middle is measured in CHARACTERS now — the window is a
  // duration budget and words are not equal.
  final midPos = start + (end - start) ~/ 2;
  int? pick({required bool floored}) {
    var best = -1;
    var bestDist = double.infinity;
    for (var k = 0; k < words.length - 1; k++) {
      if (!_endsAtBreath(t, words[k])) continue;
      final cut = words[k].$2;
      if (floored &&
          (cut - start < minBreathChars || end - cut < minBreathChars)) {
        continue;
      }
      final d = (cut - midPos).abs().toDouble();
      if (d < bestDist) {
        bestDist = d;
        best = k;
      }
    }
    return best < 0 ? null : best;
  }

  var best = pick(floored: true) ?? pick(floored: false);
  if (best == null) {
    // Word fallback: the mark-less middle, floor-respecting when any
    // word cut can keep it.
    for (var d = 0; d < words.length; d++) {
      for (final k in [
        ((words.length - 1) ~/ 2) - d,
        ((words.length - 1) ~/ 2) + d,
      ]) {
        if (k < 0 || k >= words.length - 1) continue;
        final cut = words[k].$2;
        if (cut - start < minBreathChars || end - cut < minBreathChars) {
          continue;
        }
        best = k;
        break;
      }
      if (best != null) break;
    }
  }
  if (best == null) {
    final s = t.substring(start, end).trim();
    if (s.isNotEmpty) out.add(s); // unsplittable inside the floor
    return;
  }
  final mid = words[best].$2;
  var right = mid;
  while (right < end && _isWs(t.codeUnitAt(right))) {
    right += 1;
  }
  _balance(t, start, mid, out);
  _balance(t, right, end, out);
}

/// Word ranges (start, end) of the whitespace-separated words in
/// [t] within [start:end].
List<(int, int)> _wordRanges(String t, int start, int end) {
  final words = <(int, int)>[];
  var i = start;
  while (i < end) {
    while (i < end && _isWs(t.codeUnitAt(i))) {
      i += 1;
    }
    final w = i;
    while (i < end && !_isWs(t.codeUnitAt(i))) {
      i += 1;
    }
    if (i > w) words.add((w, i));
  }
  return words;
}

/// Does this word end on a breath — a clause mark (, ; : — –) at the
/// word's end, optionally inside closing quotes/brackets? Mid-word
/// marks ('1,000', 'main.dart:801', "well,") never qualify: the mark
/// must be the last real character, which is exactly the old
/// "followed by whitespace" lookahead restated at word granularity.
bool _endsAtBreath(String t, (int, int) word) {
  var e = word.$2;
  while (e > word.$1) {
    final c = t.codeUnitAt(e - 1);
    if (c == 0x22 || c == 0x27 || c == 0x29 || c == 0x5D || c == 0x7D) {
      e -= 1; // trailing closer: skip it and ask what hides before it
      continue;
    }
    return c == 0x2C || c == 0x3B || c == 0x3A || c == 0x2014 || c == 0x2013;
  }
  return false;
}

bool _isWs(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D;

/// Pocket-specific chunk merge over [splitForTts] output. Two reasons it
/// exists, and the second one is why the rules changed:
/// 1. a Generate call with very few text tokens misbehaves in this model
///    (kyutai's own guards: pad short prompts, ignore EOS for 6 frames,
///    split_into_best_sentences). In the ONNX port a 2-word piece reliably
///    garbles the first syllable, and a voice that never emits EOS decodes
///    up to max_frames — 40 s of babble measured. Merging neighbours to
///    >= 30 chars matches sherpa's internal min_char_in_sentence so C++'s
///    own sentence pass never sees a runt either.
/// 2. EVERY separate Generate call re-pays the cold-start ritual (the
///    '....' pause, the growl region trimmed by pocketLeadIn, the inserted
///    lead silence, plus one more player prepare seam). Long answers split
///    sentence-by-sentence into short pieces therefore "broke up"
///    audibly — measured seams of 0.3-0.7 s of silence per sentence. So
///    pieces now merge up to 400 chars regardless of runt status: a
///    whole typical assistant answer becomes ONE call, and the model's
///    own punctuation-driven pauses (kept whole by silenceScale 1.0)
///    provide natural paragraph flow instead of our splice points.
List<String> mergePocketChunks(List<String> pieces) {
  const minChars = 30; // runt floor: below this a piece garbles
  // Speech runs ~0.94-1.2 frames/char (all six preset voices measured, and
  // a full 373-char answer rendered at 321 frames); one frame = 80 ms and
  // the per-call frame guard in PocketTts.generate grants ~1.35 frames/char
  // + 30 of slack against the model's 500-frame (40 s) ceiling. At 400
  // chars the guard clamps to that ceiling, which measured ~18 s of margin
  // on the slowest realistic delivery — a clamp hit trims trailing
  // silence, never words, and only in a pathological EOS miss.
  const maxChars = 400;
  final out = <String>[];
  for (final p in pieces) {
    if (out.isEmpty) {
      out.add(p);
      continue;
    }
    // +341: the LEAD piece rides alone once it's a real breath — the
    // splitter cut it short on purpose so audio starts early, and a
    // merge that welds piece two onto it would undo the whole law. A
    // lead under the runt floor is different: the floor outranks the
    // latency ('Yes.' alone garbles the first syllable), so it merges
    // like anything else.
    final leadAlone = out.length == 1 && out.first.length >= minChars;
    if (!leadAlone &&
        (out.last.length < minChars ||
            p.length < minChars ||
            out.last.length + p.length + 1 <= maxChars)) {
      out.last = '${out.last} $p';
    } else {
      out.add(p);
    }
  }
  if (out.length > 1 && out.last.length < minChars) {
    // Folding the tail runt in can overshoot the ideal cap a little (a
    // few chars of extra allowance is covered by the guard's +30 slack;
    // a clamp hit only trims trailing silence, never mid-word content at
    // this size).
    out[out.length - 2] = '${out[out.length - 2]} ${out.removeLast()}';
  }
  return out;
}
