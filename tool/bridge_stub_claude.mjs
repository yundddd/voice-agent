#!/usr/bin/env node
// A stand-in for the claude CLI, for the bridge's queue regression test —
// and for driving the phone app through the queue/interrupt scenarios by
// hand with a stopwatch instead of a model. Speaks just enough
// stream-json to be real: every user message written to its stdin is
// appended (text only, one per line) to process.env.STUB_LOG, and the
// turn closes with a `result` after STUB_RESULT_MS (default 1500). The
// whole point is DETERMINISM the real harness cannot offer: no network,
// no model, turn length nailed to a clock the test controls. Flags the
// bridge passes (-p, --input-format, --resume, …) are accepted and
// ignored.
//
// Scripting env (all per-turn, re-armed on every user message):
//   STUB_SAYS          newline-separated answer lines (one snapshot each)
//   STUB_TOOL          command text: the turn opens with a Bash tool_use
//                      snapshot at STUB_TOOL_START_MS instead of answering
//   STUB_TOOL_START_MS tool_use relay delay (default 200)
//   STUB_TOOL_DONE_MS  SURVIVING background tool (the +99 story): when the
//                      turn is CUT while STUB_TOOL is open, the tool's
//                      tool_result + a completion say arrive this long
//                      after the cut — into whatever turn holds the view
//   STUB_THINK_MS      extra wait before the first snapshot (simulated
//                      thinking; the bridge's own 0.8s tallies cover the
//                      spinner meanwhile)
import { appendFileSync } from 'node:fs';

const log = process.env.STUB_LOG;
const delay = Number(process.env.STUB_RESULT_MS ?? 1500);
const thinkMs = Number(process.env.STUB_THINK_MS ?? 0);
const toolCmd = process.env.STUB_TOOL ?? '';
const toolStartMs = Number(process.env.STUB_TOOL_START_MS ?? 200);
const toolDoneMs = Number(process.env.STUB_TOOL_DONE_MS ?? 0);
const toolDoneText = process.env.STUB_TOOL_DONE_TEXT ??
  'Bash finished — its output is in the log.';
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');

let turnSeq = 0; // timers of a superseded/cut turn must not speak again
let openToolId = null; // survives the cut when STUB_TOOL_DONE_MS is set

const says = () => (process.env.STUB_SAYS ?? '').split('\n')
    .map((x) => x.trim()).filter(Boolean);

function finishTurn(gen) {
  if (gen !== turnSeq) return;
  for (const s of says()) {
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
}

process.stdin.setEncoding('utf8');
let lineBuf = '';
process.stdin.on('data', (b) => {
  lineBuf += b;
  let i;
  while ((i = lineBuf.indexOf('\n')) >= 0) {
    const line = lineBuf.slice(0, i).trim();
    lineBuf = lineBuf.slice(i + 1);
    if (!line.startsWith('{')) continue;
    const m = JSON.parse(line);
    if (m.type === 'control_request' &&
        m.request?.subtype === 'interrupt') {
      // The real CLI aborts the open turn: its result arrives with
      // is_error. A surviving tool (STUB_TOOL_DONE_MS) keeps running
      // anyway and reports later — the +99 "tool goes to background"
      // contract the phone's banner rides on.
      const gen = ++turnSeq;
      if (openToolId && toolDoneMs) {
        const id = openToolId;
        setTimeout(() => {
          out({
            type: 'user', session_id: 'stub-session',
            message: { role: 'user',
              content: [{ type: 'tool_result', tool_use_id: id,
                          content: 'done in background' }] },
          });
          out({
            type: 'assistant', session_id: 'stub-session',
            message: { role: 'assistant',
              content: [{ type: 'text', text: toolDoneText }] },
          });
        }, toolDoneMs);
      }
      openToolId = null;
      out({
        type: 'result', subtype: 'error_during_execution',
        session_id: 'stub-session', is_error: true, total_cost_usd: 0,
        errors: ['interrupted by user'],
      });
      return;
    }
    if (m.type !== 'user') continue;
    const c = m.message?.content;
    const text = typeof c === 'string' ? c : (c?.[0]?.text ?? '');
    appendFileSync(log, text + '\n');
    const gen = ++turnSeq;
    openToolId = null;
    if (toolCmd) {
      setTimeout(() => {
        if (gen !== turnSeq) return;
        openToolId = 'tool-' + gen;
        out({
          type: 'assistant', session_id: 'stub-session',
          message: { role: 'assistant', content: [{
            type: 'tool_use', id: openToolId, name: 'Bash',
            input: { command: toolCmd },
          }] },
        });
      }, toolStartMs);
      setTimeout(() => finishTurn(gen), delay);
      return;
    }
    setTimeout(() => finishTurn(gen), delay + thinkMs);
  }
});
// The real CLI re-emits init per message; the bridge only reads session_id
// off whatever carries one, so one greeting is plenty.
out({ type: 'system', subtype: 'init', session_id: 'stub-session' });
