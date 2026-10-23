// Wire fragments: the frame SEQUENCES the step-driven stub emits, shaped
// from real stream-json captures (same for the opencode bus). Until the
// golden tapes land (tool/testlab/tapes/, recorded by record_tapes.mjs),
// these shapes were transcribed from verified captures — every field the
// bridge reads exists here as it exists on the wire, and NOTHING nicer.
// The +325 lesson rules this file: a fake that behaves better than the
// real harness is a bug factory, not a test.
//
// A "turn" is a plan: an array of FRAGMENTS. stubEmit pops the next
// fragment (1..3 frames, as the real CLI batches them); stubFinish pops
// the remainder plus the result. Out-of-plan frames (retry, compacting,
// a late notification) are addressable by name for the generator.
const sidOf = (conv) => 'be-' + (conv || 'x').replace(/[^a-z0-9-]/gi, '').slice(0, 12);

// Golden tapes when present: the stub's FIRST dialect. Fragments are cut
// from real captured lines (tool/testlab/tapes/, recorded by
// record_tapes.mjs); the hand-built shapes below are the fallback for a
// checkout without tapes. A tape frame is emitted VERBATIM — the fake
// gets to improve on the wire in no way.
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
const TAPE_DIR = join(import.meta.dirname, 'tapes');
const tapeCache = new Map();
export function loadTape(name) {
  if (tapeCache.has(name)) return tapeCache.get(name);
  const f = join(TAPE_DIR, `claude-${name}.jsonl`);
  let frames = null;
  if (existsSync(f)) {
    frames = readFileSync(f, 'utf8').trim().split('\n')
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean);
  }
  tapeCache.set(name, frames);
  return frames;
}
// cut a captured turn into emit-sized fragments (the CLI's own batching,
// approximated by grouping consecutive stream_events around each block)
function fragmentTape(frames) {
  // a result frame ENDS its fragment; the snapshot cluster closes a
  // block; everything else rides the tape's own order
  const out = [];
  let batch = [];
  for (const m of frames) {
    if (m.type === 'result') { out.push(batch.length ? [batch.shift()] : null); batch = []; out.push([{ frame: m }]); continue; }
    batch.push({ frame: m });
    if (m.type === 'assistant' || m.type === 'user' ||
        (m.type === 'stream_event' && ['message_stop', 'content_block_stop'].includes(m.event?.type)) ||
        batch.length >= 3) { out.push(batch); batch = []; }
  }
  if (batch.length) out.push(batch);
  return out.filter(Boolean);
}

const msgStart = (conv, inTok) => ({ frame: { type: 'stream_event',
  session_id: sidOf(conv),
  event: { type: 'message_start', message: { id: 'msg_' + Math.random().toString(36).slice(2, 8),
    usage: { input_tokens: inTok, cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0 } } } } });
const cbStart = (conv, block) => ({ frame: { type: 'stream_event',
  session_id: sidOf(conv),
  event: { type: 'content_block_start', index: 0, content_block: block } } });
const cbText = (conv, text) => ({ frame: { type: 'stream_event',
  session_id: sidOf(conv),
  event: { type: 'content_block_delta', index: 0,
    delta: { type: 'text_delta', text } } } });
const cbThink = (conv, t) => ({ frame: { type: 'stream_event',
  session_id: sidOf(conv),
  event: { type: 'content_block_delta', index: 0,
    delta: { type: 'thinking_delta', thinking: t } } } });
const cbJson = (conv, j) => ({ frame: { type: 'stream_event',
  session_id: sidOf(conv),
  event: { type: 'content_block_delta', index: 0,
    delta: { type: 'input_json_delta', partial_json: j } } } });
const cbStop = (conv) => ({ frame: { type: 'stream_event',
  session_id: sidOf(conv),
  event: { type: 'content_block_stop', index: 0 } } });
const msgDelta = (conv, outTok) => ({ frame: { type: 'stream_event',
  session_id: sidOf(conv),
  event: { type: 'message_delta',
    delta: { stop_reason: 'end_turn' }, usage: { output_tokens: outTok } } } });
const msgStop = (conv) => ({ frame: { type: 'stream_event',
  session_id: sidOf(conv),
  event: { type: 'message_stop' } } });
const snap = (conv, blocks) => ({ frame: { type: 'assistant',
  session_id: sidOf(conv), timestamp: new Date().toISOString(),
  message: { role: 'assistant', content: blocks } } });
const snapUser = (conv, blocks) => ({ frame: { type: 'user',
  session_id: sidOf(conv), timestamp: new Date().toISOString(),
  message: { role: 'user', content: blocks } } });

function splitWords(s) {
  const w = s.split(' ');
  const halves = [w.slice(0, Math.ceil(w.length / 2)).join(' '),
    w.slice(Math.ceil(w.length / 2)).join(' ')].filter(Boolean);
  return halves.length ? halves : [s];
}

export const FRAMES = {
  // A plain spoken answer, batched like the CLI batches: start(+first
  // block), deltas, snapshot, usage, stop.
  textAnswer(conv, text) {
    const inTok = 1200 + Math.floor(Math.random() * 800);
    return [
      [msgStart(conv, inTok), cbStart(conv, { type: 'text' })],
      splitWords(text).map(t => cbText(conv, t + ' ')).flat(),
      [cbStop(conv), snap(conv, [{ type: 'text', text }])],
      [msgDelta(conv, 18 + text.length / 4 | 0), msgStop(conv)],
    ];
  },
  // A thinking preamble then an answer (the shape that hid the +?
  // block-index shift: thinking first, text under the SAME message id).
  thinkAnswer(conv, thought, text) {
    const inTok = 2000 + Math.floor(Math.random() * 800);
    return [
      [msgStart(conv, inTok), cbStart(conv, { type: 'thinking' })],
      splitWords(thought).map(t => cbThink(conv, t + ' ')).flat(),
      [cbStop(conv), cbStart(conv, { type: 'text' })],
      splitWords(text).map(t => cbText(conv, t + ' ')).flat(),
      [cbStop(conv), snap(conv, [{ type: 'thinking', thinking: thought },
        { type: 'text', text }])],
      [msgDelta(conv, 40), msgStop(conv)],
    ];
  },
  // A tool round-trip: use, call, result — the fold boundary +163 and
  // the banner receipts ride this shape.
  toolTurn(conv, cmd, resultText) {
    const id = 'toolu_' + Math.random().toString(36).slice(2, 10);
    return [
      [msgStart(conv, 1500)],
      [cbStart(conv, { type: 'tool_use', id, name: 'Bash' }),
        cbJson(conv, JSON.stringify({ command: cmd })), cbStop(conv),
        snap(conv, [{ type: 'tool_use', id, name: 'Bash',
          input: { command: cmd } }])],
      [snapUser(conv, [{ type: 'tool_result', tool_use_id: id,
        content: resultText }])],
    ];
  },
  // The answer that closes a tool turn (a SECOND message inside the
  // turn — the real CLI's tool-loop shape).
  toolAnswer(conv, text) {
    return [
      [msgStart(conv, 2400), cbStart(conv, { type: 'text' })],
      splitWords(text).map(t => cbText(conv, t + ' ')).flat(),
      [cbStop(conv), snap(conv, [{ type: 'text', text }])],
      [msgDelta(conv, 12), msgStop(conv)],
    ];
  },
  // Off-plan frames the generator can slip in.
  retry(conv) {
    return [{ frame: { type: 'system', subtype: 'api_retry',
      session_id: sidOf(conv), error_status: 429, attempt: 2,
      max_retries: 5, retry_delay_ms: 800, error: 'rate limit' } }];
  },
  compacting(conv) {
    return [{ frame: { type: 'system', subtype: 'status',
      session_id: sidOf(conv), status: 'compacting' } }];
  },
  compactBoundary(conv) {
    return [{ frame: { type: 'system', subtype: 'compact_boundary',
      session_id: sidOf(conv) } }];
  },
  // A background task's production notification (TOP-level content —
  // the +182 carrier).
  taskNotification(conv, taskId, label) {
    return [{ frame: { type: 'system', subtype: 'task_notification',
      session_id: sidOf(conv),
      content: `Bash command (id: ${taskId}) completed (exit code 0). ` +
        `Output written to /tmp/stub-tasks/${taskId}.output.` } }];
  },
  // The turn's last words.
  resultClean(conv) {
    return [{ frame: { type: 'result', subtype: 'success', is_error: false,
      duration_ms: 1400, num_turns: 1, session_id: sidOf(conv),
      usage: { input_tokens: 2400, cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0, output_tokens: 64 },
      total_cost_usd: 0.01,
      modelUsage: { 'claude-sonnet-5-5': { contextWindow: 200000 } } } }];
  },
  resultErr(conv, why = 'upstream 500') {
    return [{ frame: { type: 'result', subtype: 'error_during_execution',
      is_error: true, session_id: sidOf(conv), duration_ms: 300,
      num_turns: 0, errors: [why], modelUsage: {} } }];
  },
  // OpenCode bus equivalents for the opencode stub's /push.
  oc: {
    plain(conv, text) {
      return [
        { type: 'session.step.started', data: { sessionID: conv,
          model: { providerID: 'lab', id: 'small' } } },
        { type: 'session.usage.updated', data: { sessionID: conv,
          tokens: { input: 3000, output: 24 }, cost: 0.002 } },
        { type: 'session.text.started', data: { sessionID: conv } },
        ...splitWords(text).map(t => ({ type: 'session.text.delta',
          data: { sessionID: conv, delta: t + ' ' } })),
        { type: 'session.text.ended', data: { sessionID: conv, text } },
        { type: 'session.step.ended', data: { sessionID: conv } },
        { type: 'session.execution.succeeded', data: { sessionID: conv } },
      ];
    },
    interrupted(conv) {
      return [
        { type: 'session.execution.interrupted',
          data: { sessionID: conv, reason: 'interrupted' } },
      ];
    },
    stepFailed(conv) {
      return [{ type: 'session.step.failed', data: { sessionID: conv,
        error: { type: 'rate_limit', message: 'slow down' } } }];
    },
  },
  emitSet(rand, plan) { return nextFragments(plan, rand); },
  finishSet(st, conv) { return finishPlan(st, conv); },
};

// plan helpers used by the generator:
export function newPlan(conv, rand) {
  // rotate the captured scenarios: plain answers, a tool round-trip,
  // and an interrupted turn — every frame the stub speaks is VERBATIM
  // from a golden tape whenever one exists
  const pick = ['plain', 'tool', 'interrupt', 'resume'][Math.floor(rand() * 4)];
  const tape = loadTape(pick) ?? loadTape('plain');
  if (tape) return { conv, fromTape: true, queue: fragmentTape(tape) };
  const kind = rand();
  const n = Math.floor(rand() * 90 + 10);
  if (kind < 0.55) return FRAMES.textAnswer(conv, `The number is ${n}.`);
  if (kind < 0.8) return [
    ...FRAMES.thinkAnswer(conv, `Working on it`, `The number is ${n}.`)];
  return [
    ...FRAMES.toolTurn(conv, `echo ${n}`, String(n)),
    ...FRAMES.toolAnswer(conv, `It is ${n}.`),
  ];
}
export function nextFragments(plan, rand, max = 3) {
  const take = [];
  while (take.length < max && plan.queue.length) {
    const f = plan.queue.shift();
    take.push(...(Array.isArray(f) ? f : [f]));
    if (take.length && rand() < 0.35) break; // sometimes ship one frame at a time
  }
  return take.length ? take : null;
}
export function finishPlan(st, plan) {
  const rest = plan.queue.splice(0).flat();
  const hasResult = rest.some(f => f.frame?.type === 'result');
  return hasResult ? rest
    : rest.concat(st.errNext ? FRAMES.resultErr(plan.conv)
      : FRAMES.resultClean(plan.conv));
}
