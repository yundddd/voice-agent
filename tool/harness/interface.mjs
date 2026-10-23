// ── the harness session interface ------------------------------------------
// One seam between the bridge's turn machine and whatever harness actually
// thinks. Before this split the shared internal wire WAS the Claude Code
// stream-json shape: the opencode adapter translated its bus events INTO
// that shape (ocTranslate) so one handleEvent could serve both — true,
// but it made a Claude frame layout the app's de-facto event protocol,
// and every future harness inherited it by accident. Here the protocol is
// OURS: HarnessEvent is the normalized event set the bridge consumes,
// and each adapter (claude.mjs, opencode.mjs) is the only code that
// knows its harness's native shapes.
//
// The VERBS (what the bridge asks a session to do) are methods on
// HarnessSession; the EVENTS (what a session reports back) are the
// normalized objects below, emitted on 'event' and consumed by the
// bridge's handleEvent under the spawning record's bundle (the +257
// binding law — the adapter itself knows no records):
//
//   begin/resume  the adapter is constructed with {resume} — the sid to
//                 rehydrate, or none for a fresh conversation
//   prompt(text)  run an utterance as a turn ('/...' slash lines may be
//                 harness-commands; each adapter decides)
//   interrupt()   cut the OPEN turn in band; the turn still closes with a
//                 TurnEnd (isError — the cut speaking, not a fault)
//   setModel(id)  optimistic pick; Promise of the new current, reject on
//                 refusal; an async NO lands as ModelAck {ok: false}
//   kill()        retire the backend (SIGTERM / close the bus)
//
// Notifications: 'event' (a HarnessEvent below), 'exit' (code, sig) —
// the shared death bookkeeping (onChildExit) runs on the bridge side.
//
// Block payloads inside Snapshot keep the Claude content-block layout
// ({type: 'text'|'thinking'|'tool_use'|'tool_result', ...}) — not as a
// harness fact but as our own normalized block shape, because it is the
// layout both harnesses' content already reduces to and the snapshot
// matcher (the spoken-watermark scan) is written against it.
import { EventEmitter } from 'node:events';

export const HarnessEvent = Object.freeze({
  // Identity & the model truth.
  SessionId: 'session_id',      // { sid } — the conversation's real name;
                                // rekeys the record the moment it lands
  ModelRan: 'model_ran',        // { model } — the harness PROVED it runs this
  ModelAck: 'model_ack',        // { requestId, ok } — a pick's verdict
  // The stream (one API call / one harness step's worth).
  CallStart: 'call_start',      // { inputTokens, cacheRead, cacheWrite } —
                                // the call begins carrying its context
  BlockStart: 'block_start',    // { kind: 'text'|'thinking'|'tool_use', name }
  BlockDelta: 'block_delta',    // { kind: 'text'|'thinking'|'input_json', text }
  BlockStop: 'block_stop',      // {} — this block's text is final
  Usage: 'usage',               // { outputTokens } — this call's exact output
  MessageStop: 'message_stop',  // {} — the answer's TEXT is final; whether
                                // generation continues is openTools' business
  // Whole-message snapshots (the trustworthy text, vs the delta firehose).
  Snapshot: 'snapshot',         // { role: 'assistant'|'user'|'task',
                                //   blocks, hay, timestamp }
  SystemNotice: 'system_notice',// { notice: 'compacting'|'compact_boundary' }
  Retry: 'retry',               // { status, error, attempt, maxRetries,
                                //   delayMs, gaveUp } — the harness is
                                //   backing off, mid-turn, and says so
  // The turn's last word.
  TurnEnd: 'turn_end',          // { isError, why, usage, modelUsage,
                                //   costUsd }
});

// Every normalized event carries `kind`: the adapter's raw wire label
// ('message_start', 'session.step.started' mapped to its Claude-shaped
// twin, …). The per-turn census counts by it, so the [census] journal
// line stays comparable across harnesses — which is exactly the point
// the +221 retry note made: the phone learns ONE shape per meaning, and
// the diagnostics name the wire it came from.
export function harnessEvent(type, kind, fields = {}) {
  return { type, kind, ...fields };
}

export class HarnessSession extends EventEmitter {
  // Adapters implement the VERB surface; see the header. Subclasses emit
  // 'event' (normalized) synchronously or on their own clock, and 'exit'
  // exactly once when the backend is gone.
  prompt(_text) { throw new Error('not implemented'); }
  interrupt() {}
  setModel(_id) { throw new Error('not implemented'); }
  kill() {}
}
