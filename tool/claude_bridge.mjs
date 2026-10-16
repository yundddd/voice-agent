// Voice-turn bridge: turns one long-lived `claude -p --input-format
// stream-json` process into an HTTP+SSE endpoint the voice agent can talk
// to over the LAN/Tailscale. Verified against claude 2.1.296 streaming
// stdin multi-turn (context persists between POSTs; each turn ends with a
// `result` event; `session_id` is stable and resume-able).
//
//   node tool/claude_bridge.mjs --dir ~/some-project --token SECRET
//
// Endpoints (all except /health require ?token=):
//   POST /talk   body: plain text utterance -> SSE stream of voice events
//                (event: say / tool / progress / done / error). A body
//                starting with / is written to stdin as PLAIN-STRING
//                content, so the CLI executes it as a real slash command
//                (block-array content would just feed it to the model —
//                verified on 2.1.296); /compact emits a system
//                compact_boundary, relayed here as `tool compact`.
//   POST /stop   interrupt the current turn (barge-in), context survives
//   POST /new    start a fresh session (kills + respawns claude)
//   GET  /health liveness + claude up?
//
// Voice events are derived from the raw stream-json: assistant text
// arrives as it closes (no token deltas — the TTS wants whole sentences),
// tool_use becomes `tool` progress lines, `result` becomes `done`.
import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 ? argv[i + 1] : dflt;
};
const dir = arg('dir', process.cwd());
const token = arg('token', process.env.BRIDGE_TOKEN);
const claudeBin = arg('claude', join(homedir(), '.local/bin/claude'));
const port = Number(arg('port', 8732));
// Voice-companion behaviour: spoken answers only. Keeps the TTS honest.
const sysPrompt =
  arg('system', 'You are a hands-free voice assistant driving a dev machine. ' +
      'Answer in one to three short spoken sentences. Never use markdown, ' +
      'code blocks, bullet lists, or emoji: say file paths and numbers in ' +
      'plain words. Do exactly what is asked, then stop.')
  + ' While working, narrate each tool step in one very short sentence.';
// Voice can't answer a permission prompt, and raw stream-json input has no
// host to answer it either - so under anything stricter, prompt-worthy
// tools (WebFetch et al.) get silently DENIED and the answer comes back
// "I can't". bypassPermissions approves everything; explicit deny rules
// (like this user's WebSearch) still win under bypass, verified on
// 2.1.296. Tighten later with --permission-mode acceptEdits (edits+bash
// free, network tools denied) or dontAsk (locked-down) if the voice ever
// stops being the only trigger.
const permMode = arg('permission-mode', 'bypassPermissions');

// -- claude child process: one per /new, kept alive across /talk ----------
let child = null;       // claude process
let childDead = true;   // needs respawn?
let sessionId = null;   // for --resume after a bridge restart
const sidFile = join(dir, '.claude_bridge_session');
let curRes = null;      // { res, lastMsgIds, buf } for the in-flight turn
const sse = (res, ev, data) =>
  res.write(`event: ${ev}\ndata: ${JSON.stringify(data)}\n\n`);

function spawnClaude(resume) {
  const args = ['-p', '--input-format', 'stream-json',
    '--output-format', 'stream-json', '--verbose',
    '--permission-mode', permMode,
    '--append-system-prompt', sysPrompt];
  if (resume) args.push('--resume', resume);
  child = spawn(claudeBin, args, { cwd: dir, env: process.env });
  childDead = false;
  let lineBuf = '';
  child.stdout.on('data', (b) => {
    lineBuf += b;
    let i;
    while ((i = lineBuf.indexOf('\n')) >= 0) {
      const line = lineBuf.slice(0, i).trim();
      lineBuf = lineBuf.slice(i + 1);
      if (line.startsWith('{')) handleEvent(line);
    }
  });
  child.stderr.on('data', (b) => process.stderr.write(`[claude] ${b}`));
  child.on('exit', () => {
    childDead = true;
    if (curRes) { sse(curRes, 'error', { error: 'claude exited' }); endTurn(); }
  });
}

function handleEvent(line) {
  const m = JSON.parse(line);
  console.error(`EVT ${m.type}/${m.subtype ?? '-'} len=${line.length}`);
  if (m.session_id) sessionId = m.session_id;
  // Transcript replay: after --resume (or a child respawn) claude re-emits
  // earlier turns' messages with their ORIGINAL timestamps. Without this
  // filter every resume re-speaks the whole conversation history — heard as
  // "the same response, over and over". Fresh events carry now-stamps, so
  // anything older than this turn's start is history, not an answer.
  if (m.type === 'assistant' && m.timestamp && curRes && curRes.turnStart &&
      Date.parse(m.timestamp) < curRes.turnStart) {
    console.error('  (replay, skipped)');
    return;
  }
  const res = curRes;
  if (!res) return; // no listener on this turn (client hung up): keep process alive
  switch (m.type) {
    case 'assistant': {
      // Snapshot handling. The proxy re-emits the growing message but NOT
      // necessarily as an appending prefix: under thinking mode we observed
      // event 1 = [thinking] and event 2 = [text] under the SAME message id,
      // content *replaced* (both length 1). An index watermark therefore
      // skipped the text block (seen=1, nothing past it) and long answers
      // came back with `done` but no `say` — the phone's "the harness ran,
      // but had nothing to say". So: scan every block of every snapshot and
      // let the per-turn exact-text set be the single source of truth —
      // it catches prefix-regrow repeats, re-UUID replays, and same-tuple
      // re-emissions alike. Tools dedupe on their unique c.id (tool_use
      // ids are stable across snapshots). History replays from --resume
      // never reach here at all: the timestamp guard above eats them.
      const content = m.message?.content ?? [];
      for (const c of content) {
        if (c.type === 'text' && c.text.trim()) {
          const t = c.text.trim();
          // Within one turn, relay each exact text once. Identical
          // consecutive progress lines lose their second copy — right
          // trade for audio.
          if (spokenTexts.has(t)) continue;
          spokenTexts.add(t);
          console.error(`  -> say "${t.slice(0, 40)}"`);
          sse(res, 'say', { text: t });
        }
        if (c.type === 'tool_use' && c.id && !spokenTools.has(c.id)) {
          spokenTools.add(c.id);
          sse(res, 'tool', { name: c.name, detail: summarize(c) });
        }
      }
      break;
    }
    case 'system':
      // The compaction proof the /compact chip listens for: emitted when
      // the CLI finishes condensing the transcript (silent otherwise —
      // no assistant message, empty result text), so relay it as live
      // tool-style progress instead of dead air.
      if (m.subtype === 'compact_boundary') {
        console.error('  -> tool compact');
        sse(res, 'tool', {
          name: 'compact',
          detail: 'condensed conversation summary',
        });
      }
      break;
    case 'result':
      sse(res, 'done', { costUsd: m.total_cost_usd, isError: m.is_error });
      endTurn();
      break;
  }
}
function endTurn() {
  if (keepAlive) { clearInterval(keepAlive); keepAlive = null; }
  if (curRes) { curRes.end(); curRes = null; }
  spokenTools.clear(); // every message lives inside one turn
  spokenTexts.clear();
  if (sessionId) { try { writeFileSync(sidFile, sessionId); } catch {} }
}
function summarize(tool) {
  const i = tool.input ?? {};
  return String(i.command ?? i.file_path ?? i.pattern ?? i.url ?? '').slice(0, 80);
}
function talk(text, res) {
  if (curRes) { sse(res, 'error', { error: 'busy: one turn at a time' }); res.end(); return; }
  if (childDead) spawnClaude(sessionId); // resume our voice conversation if any
  curRes = res;
  curRes.turnStart = Date.now() - 5000; // slack for clock skew / early stamps
  // SSE comment every 15 s: a 3-minute gradle build emits nothing, and
  // idle-detection on the link (NAT, tailscale, Dart clients) should not
  // get creative with a stream that is merely thinking.
  keepAlive = setInterval(() => { try { res.write(': ping\n\n'); } catch {} }, 15000);
  // Slash commands must arrive as PLAIN STRING content: the CLI only runs
  // them as commands then — a block array like [{text:"/compact"}} goes to
  // the model as literal text (it just rambles about the word), verified on
  // 2.1.296. Everything else keeps the structured shape.
  const msg = text.startsWith('/')
      ? { type: 'user', message: { role: 'user', content: text } }
      : { type: 'user',
          message: { role: 'user',
            content: [{ type: 'text', text }] } };
  child.stdin.write(JSON.stringify(msg) + '\n');
}
let keepAlive = null;
// tool_use ids already relayed this turn (tool_use ids are unique per
// call and stable across snapshots of the same message). Cleared at
// endTurn: a turn is the natural lifecycle here and it keeps the set from
// growing forever.
const spokenTools = new Set();
// Exact say texts already relayed this turn (catches replays that arrive
// under fresh message ids, e.g. a resumed transcript). Same lifecycle.
const spokenTexts = new Set();

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname !== '/health' && url.searchParams.get('token') !== token) {
    res.writeHead(401).end('nope\n'); return;
  }
  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, claudeUp: !childDead, sessionId }));
    return;
  }
  if (req.method !== 'POST') { res.writeHead(405).end(); return; }
  let body = '';
  req.on('data', (c) => body += c);
  req.on('end', () => {
    if (url.pathname === '/talk') {
      res.writeHead(200, { 'content-type': 'text/event-stream',
        'cache-control': 'no-cache', connection: 'keep-alive' });
      talk(body.trim(), res);
      // NOTE: must listen on the RESPONSE, not the request: a POST's req
      // 'close' fires the instant its body is read, which would end the
      // stream before claude ever answers. res 'close' = client hung up or
      // response finished.
      res.on('close', () => { if (curRes === res) endTurn(); });
    } else if (url.pathname === '/stop') {
      // Barge-in: SIGINT ends the CURRENT turn (claude answers next turns
      // with context intact). Only safe while a turn is in flight: SIGINT
      // while idle kills the process (it respawns + --resumes on the next
      // /talk, so even that is recoverable, but why pay the restart).
      if (curRes && !childDead) child?.kill('SIGINT');
      res.writeHead(200).end('ok\n');
    } else if (url.pathname === '/new') {
      try { rmSync(sidFile); } catch {}
      sessionId = null;
      child?.kill('SIGTERM'); child = null; childDead = true;
      res.writeHead(200).end('ok\n');
    } else res.writeHead(404).end();
  });
});
// no claude yet until first spawn
if (!existsSync(claudeBin)) { console.error(`no claude at ${claudeBin}`); process.exit(1); }
if (!token) { console.error('set --token or BRIDGE_TOKEN'); process.exit(1); }
try { sessionId = readFileSync(sidFile, 'utf8').trim(); } catch {}
spawnClaude(sessionId || undefined);
server.listen(port, '0.0.0.0', () => console.log(`voice bridge on :${port} dir=${dir} sid=${sessionId ?? 'new'}`));
