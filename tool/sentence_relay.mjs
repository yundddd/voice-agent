// The bridge's sentence cutter, extracted from claude_bridge.mjs so
// its hard-won rules carry unit tests (three field-report regressions
// lived in this one function: batched multi-sentence frames, the
// anywhere-space 300-char cut that ignored nearby commas, and the
// missing forced flush that silently swallowed every reply's final
// sentence). Pure: it mutates blk.spoken and calls emit(text) per
// sentence; no I/O, no ring, no socket — node --test can guard it.
//
// +232 — the wire speaks in sentences, full stops. Tim's tape on the
// +228 relay: 'very short chunks'; the logs agreed, three or four
// comma-spliced shreds per answer, every one its own say frame, its
// own synthesis, its own seam and gap. The clause cut (the +222 breath
// rule, gated behind the +228 backlog valve) was a LATENCY measure
// paying with prosody, and the field says the price came due. So the
// cut moves downstream: the bridge relays a sentence when it has one
// (plus the ramble cap's escape for unpunctuated runs and the forced
// flush a block close always owed), and the PHONE splits a sentence
// that is too long for one breath — evenly, at the clause mark nearest
// its middle (lib/src/speech/tts_split.dart). Fewer frames, whole
// sentences on the wire, and the seam lands where the prose is widest,
// not where its first comma happens to sit.
//
// +342 — the cap's mid-sentence cut is RETIRED (Tim, after the tape at
// '…before the fix, where…': the bridge's last-comma-in-cap picked the
// weakest possible seam, a relative-clause break, and reached it BEFORE
// the phone's middle-law could pick the dash). The wire now cuts on
// sentence boundaries only: a run with no period rides to the block
// close, where the forced flush ships it whole and the PHONE owns every
// seam inside it. MAX_SENT_CHARS stays as the regex's scan window —
// bookkeeping, never a blade.
export const MIN_SENT_CHARS = 40; // never carve micro-segments ("OK.")
export const MAX_SENT_CHARS = 300; // scan window ×3, not a cut target (+342)

// blk: {buf: string, spoken: number}. Advances blk.spoken past every
// emitted sentence. opts.force: block closed — flush the remainder
// whole (the final sentence's period sits at end-of-text where the
// boundary regex can never see it). opts.emit: (text) => void.
export function relaySentences(blk, {force = false, emit = () => {}} = {}) {
  for (;;) {
    const from = blk.spoken;
    const win = blk.buf.slice(from, from + MAX_SENT_CHARS * 3);
    if (win.length < MIN_SENT_CHARS && !force) return;
    // A sentence end = a punctuation run (with trailing quotes/brackets)
    // preceded by a word char and followed by whitespace; the word-char
    // anchor keeps 'main.dart:801' and '3.5' from faking periods.
    // Take the FIRST legal boundary, not the last: each frame becomes
    // exactly one sentence, voiced as its own natural bite. The
    // surrounding loop still emits one sentence per pass, so a fat
    // delta closes several in order.
    let cut = -1;
    const re = /\S[.!?…]+["')\]]*(?=[ \n])/g;
    for (let m; (m = re.exec(win)) !== null;) {
      if (m.index + m[0].length >= MIN_SENT_CHARS) {
        cut = m.index + m[0].length;
        break;
      }
    }
    // +342: no cap branch. Past the scan window with no boundary in
    // sight, the sentence simply WAITS — for its period, or for the
    // block close below. The phone owns everything inside a sentence.
    // On block close, force whatever is left out whole: without this
    // the last sentence of every reply ending on bare punctuation was
    // spoken as nothing ('the last message dropped again').
    if (cut < 0 && force && blk.buf.length > from) cut = blk.buf.length - from;
    if (cut < 0) return;
    const t = blk.buf.slice(from, from + cut).trim();
    blk.spoken = from + cut;
    if (t) emit(t);
  } // loop: a fat delta can close several sentences at once
}

// What a settled assistant snapshot still OWES, given the live sentence
// blocks of the same message. The bridge's snapshot path calls this so a
// reply can never be spoken twice — the field report it guards: a short
// fast answer arrived whole in the snapshot BEFORE any live sentence had
// spoken, so the old matcher (silent on an unspoken prefix) claimed no
// block, the settle said the full text, and the forced flush at block
// close said it again one second later — heard as one reply, twice.
// Returns { text, claim }: text is the remainder to relay, claim is the
// index of the live block whose watermark the caller must advance (or
// -1: no live block is involved). Prefix-comparable means the same text
// seen at two moments of its growth — either side may lead.
export function settleOwed(blocks, t) {
  // Tier 1: a block already mid-relay — its spoken prefix extends into t.
  for (let i = 0; i < blocks.length; i++) {
    const said = blocks[i].buf.slice(0, blocks[i].spoken).trimStart();
    if (said && t.startsWith(said)) {
      return { text: t.slice(Math.min(said.length, t.length)).trim(), claim: i };
    }
  }
  // Tier 2 (the double-speak guard): a block that has spoken NOTHING yet
  // whose buffer and the snapshot are the same growing text. Claiming it
  // is what stops the forced live flush from re-saying the settle — the
  // case the field report died on. Silent-by-empty-buffer blocks are
  // skipped so the vacuous '' prefix can't claim the wrong block.
  for (let i = 0; i < blocks.length; i++) {
    const rest = blocks[i].buf.trim();
    if (!rest || blocks[i].spoken !== 0) continue;
    if (t.startsWith(rest) || rest.startsWith(t)) {
      return { text: t, claim: i };
    }
  }
  return { text: t, claim: -1 };
}

// Display token counts with two decimals at every magnitude (mirrors
// fmtTokenCount in lib/bridge.dart — phone and wire read identically).
export const fmtTok = (n) => n < 1000
  ? `${n}`
  : n < 1e6
  ? `${(n / 1000).toFixed(2)}k`
  : `${(n / 1e6).toFixed(2)}M`;
