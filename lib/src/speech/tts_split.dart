/// Sentence/word chunking for streamed TTS — pure, tested in
/// test/tts_split_test.dart. Lives apart from the isolate plumbing so the
/// rules can grow (and be reused by the bridge's own relay) without
/// touching worker messages.
library;

/// Split [text] into speakable chunks of at most 40 words, breaking at
/// sentence ends (. ! ?) and at clause boundaries (, ; :) — a mark only
/// cuts when followed by whitespace, end-of-text, or a closing
/// quote/bracket, so "3.14", "1,000" and "U.S.A." stay intact. A unit
/// still beyond twice the cap is hard-split at word boundaries, and text
/// without any punctuation stays one chunk. Descended from split_for_tts
/// in the vendored neutts crate (same constants), since broadened for
/// streamed prose that is mostly one long comma-spliced sentence.

List<String> splitForTts(String text) {
  const maxWords = 40;
  // 1. Clauses, terminators kept attached; break after [.!?,;:] followed
  //    by whitespace (incl. \r), end-of-text, or a closing quote/bracket.
  //    Runs like "..." or "!\"" stay with their sentence.
  final sentences = <String>[];
  final b = List<int>.from(
    text.codeUnits,
  ); // utf-16 code units; ASCII punctuation matches by code
  var start = 0, i = 0;
  while (i < b.length) {
    final c = b[i];
    final term = c == 0x2E || c == 0x21 || c == 0x3F; // . ! ?
    final clause = c == 0x2C || c == 0x3B || c == 0x3A; // , ; :
    final boundary =
        (term || clause) &&
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
      sentences.add(text.substring(start, end).trim());
      start = end;
      while (start < b.length && _isWs(b[start])) {
        start += 1;
      }
      i = start;
      continue;
    }
    i += 1;
  }
  if (start < text.length) sentences.add(text.substring(start).trim());
  sentences.removeWhere((s) => s.isEmpty);

  final wordCount = text.trim().isEmpty ? 0 : text.trim().split(_ws).length;
  if (sentences.length <= 1 && wordCount <= maxWords * 2) {
    return [text.trim()];
  }

  // 2. Hard-split oversized sentences at word boundaries.
  final units = <String>[];
  for (final s in sentences) {
    final words = s.split(_ws).where((w) => w.isNotEmpty).toList();
    if (words.length <= maxWords) {
      units.add(s);
    } else {
      for (var w = 0; w < words.length; w += maxWords) {
        units.add(words.skip(w).take(maxWords).join(' '));
      }
    }
  }

  // 3. Greedy-pack sentences up to maxWords per chunk.
  final chunks = <String>[];
  final cur = <String>[];
  var curWords = 0;
  for (final u in units) {
    final n = u.split(_ws).where((w) => w.isNotEmpty).length;
    if (curWords + n > maxWords && cur.isNotEmpty) {
      chunks.add(cur.join(' '));
      cur.clear();
      curWords = 0;
    }
    curWords += n;
    cur.add(u);
  }
  if (cur.isNotEmpty) chunks.add(cur.join(' '));
  return chunks;
}

final RegExp _ws = RegExp(r'\s+');
bool _isWs(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D;

