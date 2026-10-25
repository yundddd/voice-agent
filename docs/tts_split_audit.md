# TTS sentence-splitting audit — Kokoro, Titl students, Pocket

## Verdict

The shared `splitForTts` law is already the right general rule for all three engines:
sentence boundaries first, a 40-character breath floor, a 160-character / 100-word
breath window, a middle-clause cut for overlong sentences, and a lead cut for the
first chunk. Kokoro and Titl are natural under this law. Pocket is the outlier:
the Dart merge to 400 characters is not aligned with sherpa's hidden C++ sentence
pass, so Pocket can still make seams the Dart splitter did not choose.

## Kokoro v1.0

- Kokoro's frontend (`ConvertTextToTokenIdsKokoroOrKitten`) splits text into
  sentence token groups; its `max_token_len` is 400. A 160-character Dart chunk
  is safely below that.
- No hidden 200-character re-cut in the Kokoro arm.
- The worker adds a ~62 ms silent tail between chunks; Kokoro also has its own
  punctuation pauses. That is a reasonable sentence seam.
- Kokoro's default `silenceScale` is 0.2, which compresses the model's pauses.
  If pauses sound clipped, a tape A/B with `silenceScale: 1.0` is the only
  worthwhile tuning; the splitter itself does not need changing.

## Titl students (8M)

- The graph is capped at `TitlEngine.maxPhonemes = 510`; 160 characters produce
  far fewer than 510 phonemes, so the window is safe. `maxWords = 100` is only a
  backstop, not the binding limit in practice.
- The espeak front-end (`EspeakExec.ipaWithBreaths`) segments the chunk at every
  breath mark and welds the pause back, so a clause cut at the middle of a
  sentence arrives with its punctuation intact.
- No hidden engine split in the relevant range, and no space-eating.
- This arm is already natural; no change needed.

## Pocket TTS

The Dart side does two things: `splitForTts` cuts at sentence/clause breaths, and
`mergePocketChunks` re-welds pieces up to 400 characters to avoid paying the
cold-start ritual on every call. Then sherpa's C++ pass does three more things:

1. `SplitByPunctuation` flushes at every `. ! ?` with no word-character anchor.
2. `MergeShortSentences` welds sentences below 30 codepoints and **eats the
   space** at the join because `NeedSpaceBetween` sees the left side ending on
   a boundary character (`Hello Tim.Pocket TTS...`).
3. `SplitLongSentence` defaults to `max_char_in_sentence = 200` and scans back
   from the window end, so a merged 400-character piece can be re-cut at a comma
   or space near character 200, not at the middle.

That is the unnatural part. The Dart seam is chosen at the middle; the C++ pass
can choose a weak end-of-window seam inside the same Generate call.

Recommended alignment:

- Pass `max_char_in_sentence: 400` and `min_char_in_sentence: 30` in
  `PocketTts.generate`'s `extra` map, so the C++ window matches
  `mergePocketChunks`.
- Update the `pocketInternalSplit` mirror call and its default to 400 so the
  `pocket fed:` journal reflects what the engine actually does.
- The space-eating weld is a separate upstream `NeedSpaceBetween` bug; setting
  the window does not fix it. It needs an upstream patch or a deliberate Dart
  punctuation rewrite.

Measured on the splitter alone:

- `"Hello Tim. Pocket TTS speaking, generated entirely on this device."`
  splits to one Dart piece; the C++ mirror produces
  `"Hello Tim.Pocket TTS speaking, generated entirely on this device."`
- A 63-word sentence splits to `[111, 103, 79, 83]` characters and Pocket merges
  to `[111, 267]`; with the C++ 200 limit the 267-character piece re-cuts at its
  last comma, while 400 keeps it whole.

## Bottom line

Do not build three separate splitters. Keep the shared sentence/breath law.
Kokoro and Titl already match it. Pocket needs only one config alignment — its
C++ `max_char_in_sentence` — plus an upstream fix for the short-sentence space
weld. The first-chunk lead cut remains the right latency compromise for all three.
