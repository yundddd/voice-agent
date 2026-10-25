// Regression guards for the sentence cutter — run: node --test tool/
// Every test here names a field report it exists to keep fixed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { relaySentences, settleOwed, fmtTok, MIN_SENT_CHARS, MAX_SENT_CHARS } from './sentence_relay.mjs';

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

test('+342: a ramble past the old cap WAITS — no comma, no word gap, no '
    + 'mid-sentence frame (the tape at "…before the fix, where…": the '
    + 'last-comma-in-cap seam is retired; the phone owns sentence '
    + 'interiors)', () => {
  const head = 'word '.repeat(30).trim(); // 149 chars, no punctuation
  const commaAt = `${head} and the first comma lands here, then the clause ` +
    'runs on and a second comma comes later, well inside the cap but past ' +
    'the halfway mark of the window the cutter sees';
  assert.equal(run(commaAt).out.length, 0, 'nothing without a real boundary');
  const { out } = run(commaAt, { force: true });
  assert.equal(out.length, 1);
  assert.equal(out[0], commaAt, 'the block close ships it whole, uncut');
});

test('+232: a short reply stays fused — commas are the app\'s problem now', () => {
  const t = 'If you want space back, the practical moves are pruning the ' +
    'ComfyUI folder and running a containerd garbage collection.';
  const { out } = run(t, { force: true });
  assert.equal(out.length, 1, 'one frame for one sentence');
  assert.equal(out[0], t);
});

test('+232: a long comma-spliced sentence still rides the wire as ONE frame '
    + '(the field report: "very short chunks" — the clause cut retired so '
    + 'the phone can split evenly where the prose is widest)', () => {
  const t = 'If you want space back, the practical moves are pruning the ' +
    'ComfyUI folder and running a containerd garbage collection, plus ' +
    'unloading models you no longer route to and closing the tabs that ' +
    'leak a gigabyte each until the whole machine finally feels light.';
  assert.ok(t.length > 160);
  const { out } = run(t, { force: true });
  assert.equal(out.length, 1, 'no comma carves a sentence under the cap');
  assert.equal(out[0], t, 'the whole sentence ships; splitForTts owns its seams');
});

test('commas under the sentence floor never carve', () => {
  const { out } = run('Yes, we could do that but the early comma must not ' +
    'cut.', { force: true });
  assert.equal(out.length, 1,
    'a 5-char first clause stays fused — the micro-segment lesson holds');
});

test('path labels and versions do not fake a boundary', () => {
  const { out } = run('Open main.dart:801 first, then read the log line ' +
    'that follows it and note the retry counter before the run finally ' +
    'reports its verdict and writes the summary you will read tomorrow.',
    { force: true });
  assert.equal(out.length, 1,
    'the sentence ships whole — and the colon inside main.dart:801, ' +
    'having no trailing space, never pretended to be one');
});

test('+342: truly unpunctuated ramble holds the whole wire, not a word gap', () => {
  const ramble = 'x'.repeat(299) + ' y'.repeat(60);
  assert.equal(run(ramble).out.length, 0, 'it waits for a period');
  const { out } = run(ramble, { force: true });
  assert.equal(out.length, 1);
  assert.equal(out[0], ramble, 'and rides the close whole to the phone');
});

test('forced flush ships the final sentence whose period has no trailing space', () => {
  const first = 'This first sentence clears the micro floor with room to spare.';
  const last = 'And the final one ends at end of text.';
  const { out, blk } = run(`${first} ${last}`, { force: true });
  assert.deepEqual(out, [first, last]);
  assert.equal(blk.spoken, blk.buf.length);
  assert.equal(out.length, 2, 'loop terminates after the flush');
});

test('a whole-block short reply still speaks at block close', () => {
  const { out } = run('Yes.', { force: true });
  assert.deepEqual(out, ['Yes.'], 'the floor forbids fragments, not lone replies');
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

test('the floor is 40; the 300 is a scan window, not a blade (+342)', () => {
  assert.equal(MIN_SENT_CHARS, 40);
  assert.equal(MAX_SENT_CHARS, 300);
});
