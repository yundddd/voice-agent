#!/usr/bin/env node
// Golden tapes (+328): record REAL harness output once, replay it forever.
// The stubs may only speak fragments of these files — the +325 lesson: a
// fake that behaves better than the real bridge hides protocol truth.
//
//   node tool/testlab/record_tapes.mjs [--only claude|opencode]
//
// Writes tapes/<harness>-<scenario>.{jsonl,busl} plus a MANIFEST naming
// the exact harness versions — re-run on CLI upgrade; a tape diff means
// the protocol moved and an adapter must be checked.
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HERE = import.meta.dirname;
const DIR = join(HERE, 'tapes');
mkdirSync(DIR, { recursive: true });
const argv = process.argv.slice(2);
const only = argv.includes('--only') ? argv[argv.indexOf('--only') + 1] : null;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const manifest = [];

const claudeBin = join(homedir(), '.local/bin/claude');
const COMMON = ['-p', '--input-format', 'stream-json',
  '--output-format', 'stream-json', '--verbose',
  '--include-partial-messages', '--permission-mode', 'bypassPermissions'];

// record one claude child: feed `script` (array of {atMs, line}),
// capture every stdout JSONL line until result (or capMs)
function tapeClaude(name, script, { resume, capMs = 90000 } = {}) {
  return new Promise((resolve, reject) => {
    const args = [...COMMON, ...(resume ? ['--resume', resume] : [])];
    const child = spawn(claudeBin, args, { cwd: HERE });
    const lines = [];
    let buf = '';
    child.stdout.on('data', (b) => {
      buf += b;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (line.startsWith('{')) {
          lines.push(line);
          let m; try { m = JSON.parse(line); } catch { continue; }
          if (m.type === 'result') finish();
        }
      }
    });
    child.stderr.resume();
    const timer = setTimeout(finish, capMs);
    function finish() {
      clearTimeout(timer);
      try { child.kill(); } catch {}
      writeFileSync(join(DIR, `claude-${name}.jsonl`), lines.join('\n') + '\n');
      manifest.push({ tape: `claude-${name}.jsonl`, frames: lines.length });
      resolve(lines);
    }
    const userMsg = (text) => JSON.stringify({ type: 'user',
      message: { role: 'user', content: [{ type: 'text', text }] } });
    let sent = 0;
    const pump = setInterval(() => {
      while (sent < script.length && (script[sent].atMs ?? 0) <=
             lines.length * 0 + (Date.now() - t0)) {
        child.stdin.write(script[sent].line(userMsg) + '\n');
        sent++;
      }
      if (sent >= script.length) clearInterval(pump);
    }, 100);
    const t0 = Date.now();
    child.on('exit', () => { clearInterval(pump); });
  });
}

async function claudeTapes() {
  // 1. plain answer
  await tapeClaude('plain', [
    { atMs: 200, line: () => JSON.stringify({ type: 'user', message:
      { role: 'user', content: [{ type: 'text',
        text: 'Answer with exactly the word: GOLDEN' }] } }) },
  ]);
  // 2. a tool call (Bash echo) — the tool_use/tool_result shapes
  const t2 = await tapeClaude('tool', [
    { atMs: 200, line: () => JSON.stringify({ type: 'user', message:
      { role: 'user', content: [{ type: 'text',
        text: 'Run the shell command `echo tape-check` and tell me what it printed.' }] } }) },
  ]);
  const sid = (() => { for (const l of t2) { const m = JSON.parse(l);
    if (m.session_id) return m.session_id; } })();
  // 3. interrupt mid-tool: long sleep, cut it after a beat
  await tapeClaude('interrupt', [
    { atMs: 200, line: () => JSON.stringify({ type: 'user', message:
      { role: 'user', content: [{ type: 'text',
        text: 'Run the shell command `sleep 25` in Bash, then say done.' }] } }) },
    { atMs: 6000, line: () => JSON.stringify({ type: 'control_request',
      request_id: 'tape-cut-1', request: { subtype: 'interrupt' } }) },
  ], { capMs: 30000 });
  // 4. resume: fresh process, --resume the tool session, one prompt —
  //    the transcript-replay frames the bridge's timestamp guard eats
  await tapeClaude('resume', [
    { atMs: 300, line: () => JSON.stringify({ type: 'user', message:
      { role: 'user', content: [{ type: 'text',
        text: 'What command did we just run? One short sentence.' }] } }) },
  ], { resume: sid });
  // 5. long context: a fat prompt so message_start names a big input
  const fat = 'Once upon a time there was a tape that recorded everything. '.repeat(2200);
  await tapeClaude('longcontext', [
    { atMs: 200, line: () => JSON.stringify({ type: 'user', message:
      { role: 'user', content: [{ type: 'text',
        text: fat + ' Summarize the one sentence above in one word.' }] } }) },
  ], { capMs: 180000 });
  return sid;
}

async function opencodeTapes() {
  const st = JSON.parse(readFileSync(
    join(homedir(), '.local/state/opencode/service.json'), 'utf8'));
  const auth = 'Basic ' + Buffer.from(`opencode:${st.password}`).toString('base64');
  const req = (p, body, method) => fetch(st.url + p, {
    method: method ?? (body ? 'POST' : 'GET'),
    headers: { authorization: auth,
      ...(body ? { 'content-type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20000) });
  const s = await (await req('/api/session', {
    title: 'tape recorder', location: { directory: HERE } })).json();
  const sid = s.data?.id ?? s.id;
  const scenarios = {
    plain: { text: 'Answer with exactly the word: GOLDEN' },
    tool: { text: 'Run the shell command `echo tape-check` and tell me what it printed.' },
    longcontext: { text: 'Once upon a time there was a tape that recorded everything. '.repeat(2200) +
      ' Summarize the one sentence above in one word.' },
  };
  for (const [name, p] of Object.entries(scenarios)) {
    await req(`/api/session/${sid}/prompt`, p);
    // ride the bus until the turn closes
    const ctrl = new AbortController();
    const res = await fetch(st.url + '/api/event', { headers: {
      authorization: auth, accept: 'text/event-stream' },
      signal: ctrl.signal });
    const rd = res.body.getReader(); const dec = new TextDecoder();
    let buf = '', captured = [], done = false;
    const t0 = Date.now();
    while (!done && Date.now() - t0 < 120000) {
      const chunk = await Promise.race([rd.read(),
        sleep(1000).then(() => ({ timeout: true }))]);
      if (chunk.timeout) continue;
      if (chunk.done) break;
      buf += dec.decode(chunk.value, { stream: true });
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const f = buf.slice(0, i); buf = buf.slice(i + 2);
        const dl = f.split('\n').find(l => l.startsWith('data:'));
        if (!dl) continue;
        const env = JSON.parse(dl.slice(5));
        if (env.data?.sessionID !== sid) continue;
        captured.push(env);
        if (/^session\.execution\.(succeeded|failed|interrupted)$/.test(env.type)
            || env.type === 'session.error') done = true;
      }
    }
    ctrl.abort();
    if (name === 'interrupt') captured.push(...await cutOnce(sid, st, auth));
    writeFileSync(join(DIR, `opencode-${name}.busl`),
      captured.map(c => JSON.stringify(c)).join('\n') + '\n');
    manifest.push({ tape: `opencode-${name}.busl`, frames: captured.length });
  }
  // interrupt: prompt sleep, cut mid-flight
  await req(`/api/session/${sid}/prompt`,
    { text: 'Run the shell command `sleep 25` with the Bash tool, then say done.' });
  const cap = [];
  const ctrl = new AbortController();
  const res = await fetch(st.url + '/api/event', { headers: {
    authorization: auth, accept: 'text/event-stream' }, signal: ctrl.signal });
  const rd = res.body.getReader(); const dec = new TextDecoder();
  let buf = '', sent = false, done = false; const t0 = Date.now();
  while (!done && Date.now() - t0 < 30000) {
    const chunk = await Promise.race([rd.read(), sleep(200).then(() => ({ t: 1 }))]);
    if (chunk.t) {
      if (!sent && cap.some(e => /tool\.(called|input\.started)/.test(e.type))) {
        await req(`/api/session/${sid}/interrupt`, undefined, 'POST');
        sent = true;
      }
      continue;
    }
    if (chunk.done) break;
    buf += dec.decode(chunk.value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const f = buf.slice(0, i); buf = buf.slice(i + 2);
      const dl = f.split('\n').find(l => l.startsWith('data:'));
      if (!dl) continue;
      const env = JSON.parse(dl.slice(5));
      if (env.data?.sessionID !== sid) continue;
      cap.push(env);
      if (/^session\.execution\./.test(env.type)) done = true;
    }
  }
  ctrl.abort();
  writeFileSync(join(DIR, 'opencode-interrupt.busl'),
    cap.map(c => JSON.stringify(c)).join('\n') + '\n');
  manifest.push({ tape: 'opencode-interrupt.busl', frames: cap.length });
}
async function cutOnce() { return []; } // interrupt recorded separately below

const versions = {};
try { versions.claude = readFileSync('/dev/null', 'utf8'); } catch {}
const { execFileSync } = await import('node:child_process');
versions.claude = execFileSync(claudeBin, ['--version']).toString().trim();

await (only !== 'opencode' ? claudeTapes() : Promise.resolve());
await (only !== 'claude' ? opencodeTapes() : Promise.resolve());
writeFileSync(join(DIR, 'MANIFEST.json'), JSON.stringify({
  recorded: new Date().toISOString(), versions, tapes: manifest,
}, null, 2) + '\n');
console.log('tapes recorded:', manifest.map(m => `${m.tape} (${m.frames})`).join(', '));
