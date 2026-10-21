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
//   STUB_TOOL_BG       1 = the Bash tool_use carries run_in_background
//                      (the +133 story): the tool closes at once with a
//                      'running in background with ID' start receipt,
//                      and the answer is just STUB_SAYS ('started').
//   STUB_BG_DONE_MS    the UNPROMPTED report turn this long after the
//                      launch: Read of the task output, its content,
//                      STUB_BG_SAYS, and a closing result — exactly the
//                      shapes the real CLI (2.1.286, probe-verified)
//                      emits when its own background shell finishes.
//   STUB_BG_SAYS       the report turn's answer lines
//   STUB_BG_NOTIFY_MS  the +159 shape: this long after the launch, a
//                      plain-text USER message — the real CLI's task
//                      notification naming the id and the output file
//                      — lands with no turn necessarily open. This is
//                      how a finished background shell reports when
//                      the model never Reads the file: the bridge must
//                      pay the debt off THIS message, not wait for a
//                      proactive report turn.
//   STUB_BG_NOTIFY_SYSTEM  +182: emit that notification as the
//                      PRODUCTION shape instead — a system event
//                      (type 'system', subtype 'task_notification').
//   STUB_BG_NOTIFY_REPORT  +182: follow the notification with an
//                      unprompted report turn (STUB_BG_SAYS + result,
//                      no Read, no path quoted) — the tape shape in
//                      which a drain-at-report that pays everything
//                      murders a sibling shell still sleeping.
//   STUB_TOOL2_BG      +182: a SECOND backgrounded Bash in the same
//                      turn (own id tbg<gen>b, own launch receipt) —
//                      the owed sibling the report must not pay for.
//   STUB_BG_NOTIFY2_MS +182: the second task's notification, landing
//                      between turns (names only its own task).
//   STUB_BG_BEAT_MS    pause inside the report turn (default 300) — the
//                      window during which /health shows it open; raise
//                      it to watch a phone wake mid-report
//   STUB_TOOL2_MS      +163: a SECOND tool round (tool_use + tool_result)
//                      this long into the turn — the fold boundary a
//                      politely queued prompt waits for. Pairs with
//                      STUB_TOOL/STUB_TOOL_BG to model a multi-step turn.
import { appendFileSync } from 'node:fs';

// STUB_CWD_LOG: also record the WORKING DIRECTORY of every spawn — one
// line per process start. This is how the /dir test proves the agent
// was respawned INSIDE the picked folder, not merely told about it.
if (process.env.STUB_CWD_LOG) {
  appendFileSync(process.env.STUB_CWD_LOG, process.cwd() + '\n');
}

// STUB_ARGS_LOG: also record the SPAWN ARGS of every process start —
// +216: how the /model pick rides a respawn (--model in argv) is a
// fact about the spawn line, not about any frame.
if (process.env.STUB_ARGS_LOG) {
  appendFileSync(process.env.STUB_ARGS_LOG,
    process.argv.slice(2).join(' ') + '\n');
}

const log = process.env.STUB_LOG;
const delay = Number(process.env.STUB_RESULT_MS ?? 1500);
const thinkMs = Number(process.env.STUB_THINK_MS ?? 0);
const toolCmd = process.env.STUB_TOOL ?? '';
const toolStartMs = Number(process.env.STUB_TOOL_START_MS ?? 200);
const toolDoneMs = Number(process.env.STUB_TOOL_DONE_MS ?? 0);
const toolDoneText = process.env.STUB_TOOL_DONE_TEXT ??
  'Bash finished — its output is in the log.';
const toolBg = process.env.STUB_TOOL_BG === '1';
const tool2Ms = Number(process.env.STUB_TOOL2_MS ?? 0);
const bgDoneMs = Number(process.env.STUB_BG_DONE_MS ?? 0);
const bgNotifyMs = Number(process.env.STUB_BG_NOTIFY_MS ?? 0);
const bgNotifySystem = process.env.STUB_BG_NOTIFY_SYSTEM === '1';
const bgNotifyReport = process.env.STUB_BG_NOTIFY_REPORT === '1';
const tool2BgCmd = process.env.STUB_TOOL2_BG ?? '';
const bgNotify2Ms = Number(process.env.STUB_BG_NOTIFY2_MS ?? 0);
const bgBeat = Number(process.env.STUB_BG_BEAT_MS ?? 300);
const bgSays = (process.env.STUB_BG_SAYS ??
  'The background command finished. It printed:\n\nBGOUT-hello\n\n(exit code 0)')
  .split('\n').map((x) => x.trim()).filter(Boolean);
// +252: a stub resumed under an id ANSWERS under that id — the exact
// law the real CLI enforces (session_id is stable and resume-able, see
// the header). Unresumed, the stub is 'stub-session' as ever, so every
// older walk sees the identical wire.
const _argv = process.argv.slice(2);
const _r = _argv.indexOf('--resume');
const SESSION = _r >= 0 ? _argv[_r + 1] : 'stub-session';

const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');

let turnSeq = 0; // timers of a superseded/cut turn must not speak again
let openToolId = null; // survives the cut when STUB_TOOL_DONE_MS is set
let steerTapeAt = 0; // +273: the silent-fold tape plays once, off the host message
let compactedOnce = false; // +250: after the tape's compaction, turns
// answer normally — the too-long echo is the FIRST turns' state, not a
// personality

const says = () => (process.env.STUB_SAYS ?? '').split('\n')
    .map((x) => x.trim()).filter(Boolean);

function finishTurn(gen) {
  if (gen !== turnSeq) return;
  for (const s of says()) {
    out({
      type: 'assistant', session_id: SESSION,
      message: { role: 'assistant', content: [{ type: 'text', text: s }] },
    });
  }
  out({
    type: 'result', subtype: 'success', session_id: SESSION,
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
    // +216: the model picker's claude dialect — a set_model control
    // frame gets the success/error control_response the bridge's
    // rollback rides. STUB_MODEL_FAIL=1 models the refusal (unknown
    // name at the CLI's own gate), STUB_MODEL_SPY logs the SPAWN
    // ARGS' --model carry too (that half is proven by argv, below).
    if (m.type === 'control_request' &&
        m.request?.subtype === 'set_model') {
      appendFileSync(log, 'set-model ' + (m.request.model ?? '') + '\n');
      out({
        type: 'control_response',
        response: {
          subtype: process.env.STUB_MODEL_FAIL === '1' ? 'error' : 'success',
          request_id: m.request_id,
          ...(process.env.STUB_MODEL_FAIL === '1'
            ? { message: 'model not available here' } : {}),
        },
      });
      return;
    }
    if (m.type === 'control_request' &&
        m.request?.subtype === 'interrupt') {
      // The real CLI aborts the open turn: its result arrives with
      // is_error. A surviving tool (STUB_TOOL_DONE_MS) keeps running
      // anyway and reports later — the +99 "tool goes to background"
      // contract the phone's banner rides on.
      const gen = ++turnSeq;
      if (openToolId && toolDoneMs) {
        const id = openToolId;
        const cancelled = process.env.STUB_TOOL_CANCELLED === '1';
        setTimeout(() => {
          out({
            type: 'user', session_id: SESSION,
            message: { role: 'user',
              content: [{ type: 'tool_result', tool_use_id: id,
                          ...(cancelled
                            ? {
                                is_error: true,
                                content:
                                  'Command aborted (exit code 143)',
                              }
                            : { content: toolDoneText }) }] },
          });
          out({
            type: 'assistant', session_id: SESSION,
            message: { role: 'assistant',
              content: [{ type: 'text', text: toolDoneText }] },
          });
        }, toolDoneMs);
      }
      openToolId = null;
      out({
        type: 'result', subtype: 'error_during_execution',
        session_id: SESSION, is_error: true, total_cost_usd: 0,
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
    // +221: STUB_RETRY=1 re-enacts a rate-limited API call: the CLI's
    // own system/api_retry frame before the answer, so the bridge's
    // relay ('retry' tool progress) is testable end to end.
    if (process.env.STUB_RETRY === '1') {
      setTimeout(() => out({
        type: 'system', subtype: 'api_retry',
        attempt: 2, max_retries: 5, retry_delay_ms: 1200,
        error_status: 429, error: 'rate limited',
      }), Math.max(10, delay >> 2));
    }
    // +250: STUB_TOO_LONG=1 re-enacts the oversized conversation: the
    // CLI echoes the API's refusal as an assistant text block and
    // closes the turn is_error with the same words. The bridge must
    // rewrite the wording, remember the verdict and refuse the NEXT
    // prompt without ever coming back here.
    if (process.env.STUB_TOO_LONG === '1' && !compactedOnce &&
        !(text.startsWith('/') && process.env.STUB_COMPACT === '1')) {
      setTimeout(() => {
        if (gen !== turnSeq) return;
        out({
          type: 'assistant', session_id: SESSION,
          message: { role: 'assistant',
            content: [{ type: 'text', text: 'Prompt is too long' }] },
        });
        out({
          type: 'result', subtype: 'error_during_execution',
          session_id: SESSION, is_error: true, total_cost_usd: 0,
          result: 'Prompt is too long',
        });
      }, delay);
      return;
    }
    // +250: STUB_COMPACT=1 plays the auto-compaction tape — the early
    // system/status frame, the boundary proof, then the ordinary
    // answer and a clean result (the recovered conversation).
    if (process.env.STUB_COMPACT === '1') {
      compactedOnce = true; // the refusal is over: this turn shrinks
      setTimeout(() => {
        if (gen !== turnSeq) return;
        out({ type: 'system', subtype: 'status', status: 'compacting',
              session_id: SESSION });
      }, Math.max(10, delay >> 2));
      setTimeout(() => {
        if (gen !== turnSeq) return;
        out({ type: 'system', subtype: 'compact_boundary',
              session_id: SESSION });
        finishTurn(gen);
      }, delay);
      return;
    }
    // +273: STUB_STEER_SILENT re-enacts the field tape: a host turn
    // whose ONE tool round is the fold boundary — the tool_result
    // takes the fold, the host closes with a result that never
    // acknowledges it, and only the following (second) run — the
    // steered prompt's own — speaks. The bridge must hold the folded
    // done across result #1 and let the pump close on result #2.
    if (process.env.STUB_STEER_SILENT === '1' && toolCmd) {
      // ONE tape for the whole exchange, timed off the HOST message:
      // the folded prompt's arrival must not restart it — the real
      // CLI runs the steer AFTER the host's result, never mid-way.
      if (!steerTapeAt) {
        steerTapeAt = Date.now();
        const at = (ms, f) => setTimeout(f, Math.max(10, steerTapeAt + ms - Date.now()));
        at(toolStartMs, () => {
          openToolId = 'tool-' + gen;
          out({ type: 'assistant', session_id: SESSION,
                message: { role: 'assistant', content: [{
                  type: 'tool_use', id: openToolId, name: 'Bash',
                  input: { command: toolCmd } }] } });
        });
        at(toolStartMs + 120, () => {
          out({ type: 'user', session_id: SESSION,
                message: { role: 'user', content: [{
                  type: 'tool_result', tool_use_id: openToolId,
                  content: 'tool out' }] } });
        });
        at(delay, () => { // result #1: the host's silent farewell
          out({ type: 'result', subtype: 'success', session_id: SESSION,
                is_error: false, total_cost_usd: 0,
                usage: { input_tokens: 100, output_tokens: 42 } });
        });
        at(delay + 300, () => { // the steer run speaks — and closes
          for (const t of says()) {
            out({ type: 'assistant', session_id: SESSION,
                  message: { role: 'assistant',
                    content: [{ type: 'text', text: t }] } });
          }
          out({ type: 'result', subtype: 'success', session_id: SESSION,
                is_error: false, total_cost_usd: 0,
                usage: { input_tokens: 110, output_tokens: 20 } });
        });
      }
      return;
    }
    if (toolCmd) {
      setTimeout(() => {
        if (gen !== turnSeq) return;
        openToolId = 'tool-' + gen;
        out({
          type: 'assistant', session_id: SESSION,
          message: { role: 'assistant', content: [
            {
              type: 'tool_use', id: openToolId, name: 'Bash',
              input: toolBg
                ? { command: toolCmd, run_in_background: true }
                : { command: toolCmd },
            },
            // +182: the owed sibling — a second backgrounded shell in
            // the same turn, so a report for one has something of the
            // other's to wrongly pay.
            ...(toolBg && tool2BgCmd ? [{
              type: 'tool_use', id: `tool2b-${gen}`, name: 'Bash',
              input: { command: tool2BgCmd, run_in_background: true },
            }] : []),
          ] },
        });
        if (toolBg) {
          // The start receipt the real CLI answers a backgrounded
          // launch with — a tool_result, naming the task id and the
          // output file. The tool CLOSES here; the work does not.
          setTimeout(() => {
            if (gen !== turnSeq) return;
            const receipts = [{
              type: 'tool_result', tool_use_id: openToolId,
              content: `Command running in background with ID: tbg${gen}. ` +
                `Output is being written to: ` +
                `/tmp/stub-tasks/tbg${gen}.output. You will be notified ` +
                `when it completes.`,
            }];
            if (tool2BgCmd) {
              receipts.push({
                type: 'tool_result', tool_use_id: `tool2b-${gen}`,
                content: `Command running in background with ID: tbg${gen}b. ` +
                  `Output is being written to: ` +
                  `/tmp/stub-tasks/tbg${gen}b.output. You will be notified ` +
                  `when it completes.`,
              });
            }
            out({
              type: 'user', session_id: SESSION,
              message: { role: 'user', content: receipts },
            });
          }, 80);
          // The +159 shape: the task notification the real CLI emits
          // when the shell ends — often long after the launching turn
          // closed, with no listener on the wire. The bridge must pay
          // the tracked debt off THIS message alone. +182: the
          // production carrier is a SYSTEM event (task_notification);
          // the user-text form stays available (the +159 walk pins the
          // bridge against BOTH shapes), and a following report turn
          // (bgNotifyReport) replays the tape where the drain-at-report
          // killed a sleeping sibling.
          const notify = (tid, ms, withReport) => {
            if (!ms) return;
            setTimeout(() => {
              if (gen !== turnSeq) return;
              const text = `Bash command (id: ${tid}) completed ` +
                `(exit code 0). Output written to ` +
                `/tmp/stub-tasks/${tid}.output.`;
              out(bgNotifySystem
                ? {
                    type: 'system', subtype: 'task_notification',
                    session_id: SESSION, content: text,
                  }
                : {
                    type: 'user', session_id: SESSION,
                    message: { role: 'user',
                      content: `<task-notification>${text}` +
                        `</task-notification>` },
                  });
              if (withReport) {
                setTimeout(() => {
                  if (gen !== turnSeq) return;
                  for (const t of bgSays) {
                    out({
                      type: 'assistant', session_id: SESSION,
                      message: { role: 'assistant',
                        content: [{ type: 'text', text: t }] },
                    });
                  }
                  out({
                    type: 'result', subtype: 'success',
                    session_id: SESSION, is_error: false,
                    total_cost_usd: 0,
                    usage: { input_tokens: 100, output_tokens: 42 },
                  });
                }, bgBeat);
              }
            }, toolStartMs + ms);
          };
          notify(`tbg${gen}`, bgNotifyMs, bgNotifyReport);
          notify(`tbg${gen}b`, bgNotify2Ms, false);
          if (bgDoneMs) {
            // The UNPROMPTED report turn (probe-verified shapes): Read
            // of the output, its content, the model's answer, result.
            setTimeout(() => {
              if (gen !== turnSeq) return;
              out({
                type: 'assistant', session_id: SESSION,
                message: { role: 'assistant', content: [{
                  type: 'tool_use', id: `read-${gen}`, name: 'Read',
                  input: { file_path: `/tmp/stub-tasks/tbg${gen}.output` },
                }] },
              });
              out({
                type: 'user', session_id: SESSION,
                message: { role: 'user', content: [{
                  type: 'tool_result', tool_use_id: `read-${gen}`,
                  content: '1\tBGOUT-hello\n2\t\n3\t[exited with code 0]',
                }] },
              });
              // The report takes a beat like any real answer (and a
              // test an honest window to observe turnOpen through).
              setTimeout(() => {
                if (gen !== turnSeq) return;
                for (const t of bgSays) {
                  out({
                    type: 'assistant', session_id: SESSION,
                    message: { role: 'assistant',
                      content: [{ type: 'text', text: t }] },
                  });
                }
                setTimeout(() => {
                  if (gen !== turnSeq) return;
                  out({
                    type: 'result', subtype: 'success',
                    session_id: SESSION, is_error: false,
                    total_cost_usd: 0,
                    usage: { input_tokens: 100, output_tokens: 42 },
                  });
                }, bgBeat);
              }, bgBeat);
            }, toolStartMs + bgDoneMs);
          }
        }
      }, toolStartMs);
      if (tool2Ms) {
        // +163: the second boundary of a multi-step turn — another
        // foreground tool opens and closes mid-turn. A politely parked
        // prompt folds HERE, not at the turn's end.
        setTimeout(() => {
          if (gen !== turnSeq) return;
          out({
            type: 'assistant', session_id: SESSION,
            message: { role: 'assistant', content: [{
              type: 'tool_use', id: `tool2-${gen}`, name: 'Bash',
              input: { command: 'echo second', description: 'step two' },
            }] },
          });
          setTimeout(() => {
            if (gen !== turnSeq) return;
            out({
              type: 'user', session_id: SESSION,
              message: { role: 'user', content: [{
                type: 'tool_result', tool_use_id: `tool2-${gen}`,
                content: 'second',
              }] },
            });
          }, 80);
        }, toolStartMs + tool2Ms);
      }
      setTimeout(() => finishTurn(gen), delay);
      return;
    }
    setTimeout(() => finishTurn(gen), delay + thinkMs);
  }
});
// The real CLI re-emits init per message; the bridge only reads session_id
// off whatever carries one, so one greeting is plenty.
out({ type: 'system', subtype: 'init', session_id: SESSION });
