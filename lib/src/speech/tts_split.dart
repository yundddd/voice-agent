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
library;

/// Hard ceiling on one synthesized chunk (~510 phonemes; see the law
/// above).
const int maxWords = 100;

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
  return chunks;
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

/// Emit the chunks of t[start:end]: the sentence whole when it fits one
/// breath, else recursively halved at the breath-mark nearest its middle.
void _balance(String t, int start, int end, List<String> out) {
  final words = _wordRanges(t, start, end);
  if (words.length <= maxWords) {
    final s = t.substring(start, end).trim();
    if (s.isNotEmpty) out.add(s);
    return;
  }
  // Cut candidates = after word k, k in [0, len-2] (both sides non-empty).
  // Clause marks preferred, nearest the middle; the middle WORD is the
  // fallback for truly punctuation-less runs (it can't fake anything).
  final target = (words.length - 1) / 2;
  var best = -1, bestDist = double.infinity;
  for (var k = 0; k < words.length - 1; k++) {
    if (!_endsAtBreath(t, words[k])) continue;
    final d = (k - target).abs();
    if (d < bestDist) {
      bestDist = d;
      best = k;
    }
  }
  if (best < 0) best = ((words.length - 1) / 2).floor();
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
