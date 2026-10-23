// ── Cloude adapter: the Claude Code harness (Agent-SDK stream-json) -----
// The child speaks the SDK's headless wire: `claude -p --input-format
// stream-json --output-format stream-json --include-partial-messages` —
// JSONL in on stdin (user messages + control_request), JSONL events out.
// THIS file is the only place on the claude side that knows those frame
// shapes; everything it hands the bridge is a normalized HarnessEvent.
//
// The translation is deliberately 1:1 with what handleEvent used to read
// straight off the wire (the frames were already the app's protocol —
// see interface.mjs for the history); it just no longer IS the protocol,
// it feeds it:
//
//   stream_event/message_start          → CallStart   (kind 'message_start')
//   stream_event/content_block_start    → BlockStart  (kind 'content_block_start')
//   stream_event/content_block_delta    → BlockDelta  (kind 'content_block_delta')
//   stream_event/message_delta          → Usage       (kind 'message_delta')
//   stream_event/content_block_stop     → BlockStop   (kind 'content_block_stop')
//   stream_event/message_stop           → MessageStop (kind 'message_stop')
//   assistant / user                    → Snapshot    (role, blocks as-is)
//   system/task_notification            → Snapshot    (role 'task' — the
//                                        harness naming a finished
//                                        background task; the bridge's
//                                        debt ledger pays it)
//   system/init                         → ModelRan    (+ SessionId if named)
//   system/status compacting            → SystemNotice('compacting')
//   system/compact_boundary             → SystemNotice('compact_boundary')
//   system/api_retry[_after_too_long]   → Retry       (gaveUp on the latter)
//   result                              → ModelRan? + SessionId? + TurnEnd
//   control_response                    → ModelAck
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { HarnessEvent, harnessEvent, HarnessSession } from './interface.mjs';

export function translateClaudeFrame(m) {
  const out = [];
  const sid = (typeof m.session_id === 'string' && m.session_id) || null;
  if (m.type === 'control_response') {
    const r = m.response ?? {};
    out.push(harnessEvent(HarnessEvent.ModelAck, 'control_response',
      { requestId: r.request_id, ok: r.subtype === 'success' }));
    return out;
  }
  // +216/+282: the harness names the model it RUNS — init is the earliest
  // word (it precedes a fresh seat's first message_start), the result's
  // modelUsage the authoritative afterword. Either settles the operator's
  // 'default' into a name the phone can print.
  if (m.type === 'system' && m.subtype === 'init') {
    if (sid) out.push(harnessEvent(HarnessEvent.SessionId, 'init', { sid }));
    if (typeof m.model === 'string' && m.model)
      out.push(harnessEvent(HarnessEvent.ModelRan, 'init', { model: m.model }));
    return out;
  }
  if (m.type === 'stream_event') {
    const e = m.event ?? {};
    if (e.type === 'message_start') {
      const u = e.message?.usage ?? {};
      out.push(harnessEvent(HarnessEvent.CallStart, 'message_start',
        { inputTokens: u.input_tokens ?? 0,
          cacheRead: u.cache_read_input_tokens ?? 0,
          cacheCreation: u.cache_creation_input_tokens ?? 0 }));
    } else if (e.type === 'content_block_start') {
      const b = e.content_block ?? {};
      out.push(harnessEvent(HarnessEvent.BlockStart, 'content_block_start',
        { kind2: b.type ?? '', name: b.name }));
    } else if (e.type === 'content_block_delta') {
      const d = e.delta ?? {};
      // The three delta payloads the bridge reads, mapped to one shape.
      // Priority is the old code's read order (thinking fed the rolling
      // window; text grew the sentence buffer; input_json only counted).
      const kind2 = typeof d.thinking === 'string' && d.thinking ? 'thinking'
        : typeof d.text === 'string' && d.text ? 'text'
        : typeof d.partial_json === 'string' ? 'input_json' : 'text';
      const text = d.thinking ?? d.text ?? d.partial_json ?? '';
      out.push(harnessEvent(HarnessEvent.BlockDelta, 'content_block_delta',
        { kind2, text }));
    } else if (e.type === 'message_delta') {
      out.push(harnessEvent(HarnessEvent.Usage, 'message_delta',
        { outputTokens: e.usage?.output_tokens ?? 0 }));
    } else if (e.type === 'content_block_stop') {
      out.push(harnessEvent(HarnessEvent.BlockStop, 'content_block_stop', {}));
    } else if (e.type === 'message_stop') {
      out.push(harnessEvent(HarnessEvent.MessageStop, 'message_stop', {}));
    }
    return out;
  }
  if (m.type === 'assistant' || m.type === 'user') {
    if (sid) out.push(harnessEvent(HarnessEvent.SessionId, m.type, { sid }));
    out.push(snapshotOf(m.type, m));
    return out;
  }
  if (m.type === 'system' && m.subtype === 'task_notification') {
    // +182: the PRODUCTION shape of "your background task finished" — a
    // system event naming the task; only THIS subtype is scanned (the
    // birth events would murder each shell at its own birth). The
    // production carrier puts the text at TOP level (no message.content)
    // — the frame itself is the haystack, exactly as the old
    // `m.message?.content ?? m` read it.
    if (sid) out.push(harnessEvent(HarnessEvent.SessionId, 'task_notification', { sid }));
    out.push(snapshotOf('task', m));
    return out;
  }
  if (m.type === 'system' && m.subtype === 'status' &&
      m.status === 'compacting') {
    out.push(harnessEvent(HarnessEvent.SystemNotice, 'status',
      { notice: 'compacting' }));
    return out;
  }
  if (m.type === 'system' && m.subtype === 'compact_boundary') {
    out.push(harnessEvent(HarnessEvent.SystemNotice, 'compact_boundary',
      { notice: 'compact_boundary' }));
    return out;
  }
  if (m.type === 'system' &&
      (m.subtype === 'api_retry' || m.subtype === 'api_retry_after_too_long')) {
    // +221: the CLI SAYS when an API call fails and it backs off.
    out.push(harnessEvent(HarnessEvent.Retry, m.subtype, {
      status: m.error_status,
      error: typeof m.error === 'string' ? m.error
        : (m.error && m.error.message) || '',
      attempt: m.attempt, maxRetries: m.max_retries,
      delayMs: m.retry_delay_ms,
      gaveUp: m.subtype === 'api_retry_after_too_long',
    }));
    return out;
  }
  if (m.type === 'result') {
    if (sid) out.push(harnessEvent(HarnessEvent.SessionId, 'result', { sid }));
    const ran = Object.keys(m.modelUsage ?? {}).slice(-1)[0];
    if (ran) out.push(harnessEvent(HarnessEvent.ModelRan, 'result', { model: ran }));
    out.push(harnessEvent(HarnessEvent.TurnEnd, 'result', {
      isError: m.is_error,
      why: m.errors ?? m.result ?? m.api_error_status ?? '(no detail)',
      usage: m.usage ?? {},
      modelUsage: m.modelUsage,
      costUsd: m.total_cost_usd,
    }));
    return out;
  }
  return out; // a shape this adapter does not speak — journal-and-continue
              // already happened in the raw EVT line the adapter logged
}

function snapshotOf(role, m) {
  const content = m.message?.content;
  const blocks = Array.isArray(content) ? content : [];
  const timestamp = m.timestamp;
  return harnessEvent(HarnessEvent.Snapshot, 'snapshot', {
    role, blocks,
    // The haystack the background-task ledger scans a notification with:
    // plain text speaks, everything else is the whole frame as JSON (the
    // old `m.message?.content ?? m` shape exactly — the production
    // system/task_notification has no message wrapper to lose).
    hay: typeof content === 'string' ? content : JSON.stringify(content ?? m),
    ...(timestamp ? { timestamp } : {}),
  });
}

export class ClaudeSession extends HarnessSession {
  // The bridge owns the SPAWN LINE (the --settings dump tap, the betas
  // pin, the resume/model flags are lifecycle knowledge, not wire
  // knowledge); this owns the PIPE: parse out, verbs in, exit re-emitted.
  constructor({ bin, args, cwd, env, dumpNote }) {
    super();
    this.dumpNote = dumpNote ?? (() => {});
    this.child = spawn(bin, args, { cwd, env });
    this._lines = '';
    this.child.stdout.on('data', (b) => {
      this._lines += b;
      let i;
      while ((i = this._lines.indexOf('\n')) >= 0) {
        const line = this._lines.slice(0, i).trim();
        this._lines = this._lines.slice(i + 1);
        if (!line.startsWith('{')) continue;
        // The raw EVT line stays here, not in the bridge: it measures
        // the WIRE (frame sizes are why the dump tap exists), and the
        // bridge no longer sees wire shapes.
        let m; try { m = JSON.parse(line); } catch { continue; }
        logWire(m, line);
        for (const ev of translateClaudeFrame(m)) this.emit('event', ev);
      }
    });
    this.child.stderr.on('data', (b) =>
      process.stderr.write(`[claude] ${b}`));
    // A replaced child's late exit must not speak: /new SIGTERMs the old
    // one and the FIRST TALK respawns before the old exit lands, and the
    // handler used to read the fresh turn's turnOpen as its own death —
    // phantoming an 'error' and ending the new turn's view (the done
    // fell to the backlog unheard, field-proven by +216's wire test).
    // The bridge's guard (`focus.child !== this`) covers it; we just
    // forward the verdict exactly once.
    this.child.on('exit', (code, sig) => this.emit('exit', code, sig));
    this.child.stdin.on('error', () => {}); // a dead pipe is not a crash
  }
  // Slash commands must arrive as PLAIN STRING content: the CLI only runs
  // them as commands then — a block array like [{text:"/compact"}] goes to
  // the model as literal text (it just rambles about the word), verified on
  // 2.1.296. Everything else keeps the structured shape.
  prompt(text) {
    const msg = text.startsWith('/')
      ? { type: 'user', message: { role: 'user', content: text } }
      : { type: 'user',
          message: { role: 'user',
            content: [{ type: 'text', text }] } };
    this.child.stdin.write(JSON.stringify(msg) + '\n');
    this.dumpNote('stdin', text);
  }
  // In-band turn interrupt via the CLI's control protocol (verified live
  // on 2.1.296): a control_request on stdin cancels the OPEN turn — its
  // `result` still arrives (is_error: true — that's the interrupt
  // speaking, not a fault; see [result-error]) and the process keeps
  // running. This replaces SIGINT, which in headless -p mode kills the
  // WHOLE process: the next utterance then respawns with --resume and
  // re-hydrates the transcript from disk (slower to first token, and the
  // rebuilt request is yet one more prefix the cache has never seen).
  // Honest caveat from the 2026-10-16 probe: cross-turn cache hits were
  // never on offer from this CLI either way — it re-renders the request
  // on every user message — so the in-band interrupt buys process
  // survival and fast queue flush, not a warm prefix (see the header
  // latency note).
  interrupt() {
    try {
      this.child.stdin.write(JSON.stringify({
        type: 'control_request', request_id: randomUUID(),
        request: { subtype: 'interrupt' },
      }) + '\n');
    } catch {}
  }
  // Returns true when the pick rode a LIVE child (an ack may come back —
  // the bridge keeps the rollback ledger); false means the child is down
  // and the choice rides the respawn flag (the --model line the bridge
  // builds for the next spawn).
  setModel(id, requestId) {
    try {
      this.child.stdin.write(JSON.stringify({
        type: 'control_request', request_id: requestId,
        request: { subtype: 'set_model', model: id },
      }) + '\n');
      return true;
    } catch { return false; }
  }
  kill(sig) { this.child.kill(sig ?? 'SIGTERM'); }
}

function logWire(m, line) {
  if (m.type === 'stream_event') return; // deltas are a firehose: keep the log legible
  console.error(`EVT ${m.type}/${m.subtype ?? '-'} len=${line.length}` +
    // +250: status frames are rare, tiny, and the ONLY early sign of
    // the CLI auto-compacting — journal the body, not just the size.
    (m.type === 'system' && m.subtype === 'status'
      ? ' body=' + JSON.stringify(m).slice(0, 400) : ''));
}
