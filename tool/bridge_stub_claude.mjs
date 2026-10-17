#!/usr/bin/env node
// A stand-in for the claude CLI, for the bridge's queue regression test.
// Speaks just enough stream-json to be real: every user message written to
// its stdin is appended (text only, one per line) to process.env.STUB_LOG,
// and the turn closes with a `result` after STUB_RESULT_MS (default 1500).
// The whole point is DETERMINISM the real harness cannot offer: no network,
// no model, turn length nailed to a clock the test controls. Flags the
// bridge passes (-p, --input-format, --resume, …) are accepted and ignored.
import { appendFileSync } from 'node:fs';

const log = process.env.STUB_LOG;
const delay = Number(process.env.STUB_RESULT_MS ?? 1500);
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (b) => {
  buf += b;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line.startsWith('{')) continue;
    const m = JSON.parse(line);
    if (m.type !== 'user') continue;
    const c = m.message?.content;
    const text = typeof c === 'string' ? c : (c?.[0]?.text ?? '');
    appendFileSync(log, text + '\n');
    setTimeout(() => {
      // STUB_SAYS (newline-separated): the turn answers with an
      // assistant snapshot per line — the shape real snapshots take
      // when the upstream sends no live partials, exercising the
      // bridge's say relays deterministically.
      for (const s of (process.env.STUB_SAYS ?? '').split('\n')
          .map((x) => x.trim()).filter(Boolean)) {
        out({
          type: 'assistant', session_id: 'stub-session',
          message: { role: 'assistant', content: [{ type: 'text', text: s }] },
        });
      }
      out({
        type: 'result', subtype: 'success', session_id: 'stub-session',
        is_error: false, total_cost_usd: 0,
        usage: { input_tokens: 100, output_tokens: 42 },
      });
    }, delay);
  }
});
// The real CLI re-emits init per message; the bridge only reads session_id
// off whatever carries one, so one greeting is plenty.
out({ type: 'system', subtype: 'init', session_id: 'stub-session' });
