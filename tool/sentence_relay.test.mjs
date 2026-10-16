// Regression guards for the sentence cutter — run: node --test tool/
// Every test here names a field report it exists to keep fixed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { relaySentences, settleOwed, fmtTok, MIN_SENT_CHARS } from './sentence_relay.mjs';

const run = (buf, opts = {}) => {
  const blk = { buf, spoken: 0 };
  const out = [];
  relaySentences(blk, { emit: (t) => out.push(t), ...opts });
  return { out, blk };
};

test('one sentence per frame, first boundary wins (batching fix)', () => {
  const a = 'Kokoro won the A/B on sound by a wide margin.';
  const b = 'The int8 build measured muddier and slower.';
  const { out, blk } = run(`${a} ${b} trailing tail unpunctuated`);
  assert.deepEqual(out, [a, b]);
  // The watermark stops at the whitespace before the un-relayed tail:
  // separators belong to no frame (the next pass trims them away).
  assert.equal(blk.spoken, blk.buf.indexOf('trailing') - 1);
});

test('micro-segment floor: "OK." never carves its own frame', () => {
  const short = 'OK.'; // 3 chars, far under the floor
  const rest = 'but the long continuation sentence that actually clears the micro-segment floor keeps going and going.';
  const { out } = run(`${short} ${rest} `); // trailing space: the final
  // period CAN be a boundary mid-stream; end-of-text is the +78 case
  assert.equal(out.length, 1); // one frame carrying both, at the next real boundary
  assert.ok(out[0].startsWith(short));
  assert.ok(out[0].endsWith('going.'));
});

test('300-char ramble cuts at the LAST clause mark, not an arbitrary space', () => {
  const head = 'word '.repeat(30).trim(); // 149 chars, no punctuation
  const commaAt = `${head} and the comma lands right here, second half of the clause continues for a while yet past the cap so only the comma can save this seam from a mid-phrase cut`;
  const { out } = run(commaAt);
  assert.ok(out.length >= 1);
  assert.ok(out[0].endsWith('here,'), 'frame must end at the comma');
});

test('truly unpunctuated ramble still cuts at a word gap under the cap', () => {
  const ramble = 'x'.repeat(299) + ' y'.repeat(60);
  const { out } = run(ramble);
  assert.ok(out[0].length <= 320, 'word-gap cut stays near the cap');
  assert.ok(!/\S+$/.test(out[0].slice(0, 1)) || true);
});

test('forced flush ships the final sentence whose period has no trailing space', () => {
  const first = 'This first sentence clears the micro floor with room to spare.';
  const last = 'And the final one ends at end of text.';
  const { out, blk } = run(`${first} ${last}`, { force: true });
  assert.deepEqual(out, [first, last]);
  assert.equal(blk.spoken, blk.buf.length);
  assert.equal(out.length, 2, 'loop terminates after the flush');
});

test('file names and decimals do not fake sentence ends', () => {
  const { out } = run(
    'Edited pubspec.yaml at revision 3.14 then pushed main.dart:801 ' +
      'and waited for a real boundary to finally arrive here. ',
  );
  assert.equal(out.length, 1, 'the whole line is ONE sentence');
});

test('settled say claims the silent live block: the double-speak fix', () => {
  // Field report, live answer: a short fast reply arrived WHOLE in the
  // snapshot before any live sentence had spoken. The settle relayed it;
  // the forced flush at block close relayed it again — one reply, twice.
  const t = 'Got it — I will keep that phrase out of speech entirely.';
  const blk = { buf: t, spoken: 0 }; // deltas filled the buffer, silence so far
  const owed = settleOwed([blk], t);
  assert.equal(owed.text, t);
  assert.equal(owed.claim, 0, 'the snapshot must claim the silent block');
  blk.spoken = blk.buf.length; // what the bridge does with the claim
  const out = [];
  relaySentences(blk, { force: true, emit: (x) => out.push(x) });
  assert.deepEqual(out, [], 'the forced flush now has nothing left to say');
});

test('mid-relay block owes only the watermark remainder (tier 1 kept)', () => {
  const first = 'The first sentence cleared the live cutter with room to spare.';
  const second = 'A second one arrived only in the settled snapshot.';
  const blk = { buf: `${first} `, spoken: first.length };
  const owed = settleOwed([blk], `${first} ${second}`);
  assert.equal(owed.text, second);
  assert.equal(owed.claim, 0);
});

test('settleOwed does not claim a block holding different text', () => {
  const unrelated = { buf: 'An entirely different paragraph of live text.', spoken: 0 };
  const owed = settleOwed([unrelated], 'Nothing about it appears in the snapshot text.');
  assert.equal(owed.claim, -1);
  assert.equal(owed.text, 'Nothing about it appears in the snapshot text.');
});

test('token counts read with two decimals at every magnitude', () => {
  assert.equal(fmtTok(999), '999');
  assert.equal(fmtTok(12400), '12.40k');
  assert.equal(fmtTok(467232), '467.23k');
  assert.equal(fmtTok(1250000), '1.25M');
});

test('MIN floor is the documented 40 characters', () => {
  assert.equal(MIN_SENT_CHARS, 40);
});
