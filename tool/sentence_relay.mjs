// The bridge's sentence cutter, extracted from claude_bridge.mjs so
// its hard-won rules carry unit tests (three field-report regressions
// lived in this one function: batched multi-sentence frames, the
// anywhere-space 300-char cut that ignored nearby commas, and the
// missing forced flush that silently swallowed every reply's final
// sentence). Pure: it mutates blk.spoken and calls emit(text) per
// sentence; no I/O, no ring, no socket — node --test can guard it.
export const MIN_SENT_CHARS = 40; // never carve micro-segments ("OK.")
export const MAX_SENT_CHARS = 300; // bound first-audio latency unpunctuated

// blk: {buf: string, spoken: number}. Advances blk.spoken past every
// emitted sentence. opts.force: block closed — flush the remainder
// whole (the final sentence's period sits at end-of-text where the
// boundary regex can never see it). opts.emit: (text) => void.
export function relaySentences(blk, {force = false, emit = () => {}} = {}) {
  for (;;) {
    const from = blk.spoken;
    const win = blk.buf.slice(from, from + MAX_SENT_CHARS * 3);
    // The micro-segment floor protects mid-stream carving only; on
    // block close there is no 'next sentence' to merge into, and the
    // leftovers — however short — are the end of the answer.
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
    if (cut < 0 && blk.buf.length - from >= MAX_SENT_CHARS) {
      // Long ramble, no sentence end yet: prefer the LAST clause mark
      // (comma, semicolon, colon, dash) inside the cap — a place the
      // prose itself would breathe. A word gap remains only for truly
      // unpunctuated runs, and the micro-segment floor applies too.
      const clause = /[^\s][,;:—–]["')\]]*[ \n]/g;
      let cw = -1;
      for (let m; (m = clause.exec(win.slice(0, MAX_SENT_CHARS))) !== null;) {
        if (m.index + m[0].length >= MIN_SENT_CHARS) cw = m.index + m[0].length;
      }
      if (cw > 0) cut = cw;
      else {
        const w = blk.buf.lastIndexOf(' ', from + MAX_SENT_CHARS);
        if (w > from) cut = w + 1 - from; // long ramble: cut at a word gap
      }
    }
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
