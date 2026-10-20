// A stand-in for the opencode v2 SERVICE (not the CLI): the minimal
// HTTP surface tool/claude_bridge.mjs drives in --harness opencode, with
// the SAME request schemas the live 2.0.18 service enforced when this
// adapter was discovered:
//
//   * PUT instructions entries requires {value}; {content} is a 400
//     (the original adapter body-shape bug: silently fell into the
//     preamble fallback, so the voice prompt never rode the session).
//   * POST permission reply requires {decision: once|always|reject};
//     {response} is a 400 (the other bug: the reply died unobserved
//     and a prompt-worthy turn hung forever).
//
// Everything it HEARS is appended to $STUB_OC_LOG — prompts, the
// instructions entry, permission verdicts, interrupts, compacts — so
// 'delivered' stays a fact on disk, the doctrine of bridge_stub_claude.
// Bus events ride GET /api/event (SSE, envelope {id, type, data}) with
// the names a live capture of a real turn proved: session.step.started,
// session.text.{started,delta,ended}, session.usage.updated,
// session.step.ended, session.execution.succeeded.
//
// Env: STUB_OC_LOG (required), port via argv --port, state file written
// to $HOME/.local/state/opencode/service.json so the bridge (same HOME)
// finds it. STUB_OC_SAYS: answer lines (default one). STUB_OC_MS: gap
// between bus frames. STUB_OC_PERMISSION=1: a permission request sits
// mid-turn, closed only by a schema-legal reply. STUB_OC_STALL=1: the
// answer never closes (for the /stop cut test).
import http from 'node:http';
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const log = process.env.STUB_OC_LOG;
const port = Number(process.argv.slice(2).join(' ').match(/--port[= ](\d+)/)?.[1] ??
  process.env.STUB_OC_PORT ?? 4091);
const says = (process.env.STUB_OC_SAYS ?? 'The stub sees you.').split('\n')
  .map((x) => x.trim()).filter(Boolean);
const stepMs = Number(process.env.STUB_OC_MS ?? 20);
const wantPermission = process.env.STUB_OC_PERMISSION === '1';
const stall = process.env.STUB_OC_STALL === '1';
const note = (s) => appendFileSync(log, s + '\n');

// The state file the real service maintains — the bridge re-reads it per
// call, so writing it once at boot is enough (no password rotation here).
const stDir = join(homedir(), '.local/state/opencode');
mkdirSync(stDir, { recursive: true });
writeFileSync(join(stDir, 'service.json'),
  JSON.stringify({ url: `http://127.0.0.1:${port}`, pid: process.pid,
    version: '2.0.18-stub', password: 'stubpw' }));

// ── the bus ──────────────────────────────────────────────────────────
let evtSeq = 0;
const subs = new Set();
// A subscriber that missed early frames (the connect race at boot) gets
// the ring replayed; the bridge dedupes by event id exactly like it
// does with the real service's resubscribe tail.
const ring = [];
const send = (type, data, ms) => setTimeout(() => {
  const f = `data: ${JSON.stringify(
    { id: 'evt-' + ++evtSeq, type, data: { sessionID: SID, ...data } })}\n\n`;
  ring.push(f);
  if (ring.length > 200) ring.shift();
  for (const res of subs) res.write(f);
}, ms);
const push = (type, data, ms) => send(type, data, ms);

let SID = 'soc-1';
let turnSeq = 0; // a cut turn's late frames must not speak

// ── the surface ──────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const p = u.pathname;
  if (!req.headers.authorization?.startsWith('Basic ')) {
    res.writeHead(401).end('auth\n'); return;
  }
  let body = '';
  req.on('data', (c) => body += c);
  await new Promise((r) => req.on('end', r));
  const j = (() => { try { return JSON.parse(body); } catch { return {}; } })();
  note(`${req.method} ${p} ${body}`);

  if (req.method === 'GET' && p === '/api/info') { res.writeHead(204).end(); return; }
  if (req.method === 'GET' && p === '/api/event') {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write(`data: ${JSON.stringify(
      { id: 'evt-' + ++evtSeq, type: 'server.connected', data: {} })}\n\n`);
    for (const f of ring) res.write(f);
    subs.add(res);
    req.on('close', () => subs.delete(res));
    return;
  }
  if (req.method === 'POST' && p === '/api/session') {
    res.writeHead(200, { 'content-type': 'application/json' })
      .end(JSON.stringify({ data: { id: SID, title: j.title } }));
    return;
  }
  // The v2 instructions API takes {value}; 'content' is a 400 — the
  // live service enforced it with additionalProperties:false.
  if (req.method === 'PUT' && /^\/api\/experimental\/session\/[^/]+\/instructions\/entries\/[^/]+$/.test(p)) {
    if (typeof j.value !== 'string' || Object.keys(j).some(k => k !== 'value')) {
      res.writeHead(400).end('{"message":"expected {value}"}\n'); return;
    }
    note(`instructions ${p.split('/').pop()} ${j.value}`);
    res.writeHead(204).end(); return;
  }
  // Same enforcement for the permission verdict — {decision}, not
  // {response}; a 400 here is a voice turn screaming unheard.
  const perm = p.match(/^\/api\/session\/([^/]+)\/permission\/([^/]+)\/reply$/);
  if (req.method === 'POST' && perm) {
    if (!['once', 'always', 'reject'].includes(j.decision)) {
      res.writeHead(400).end('{"message":"expected {decision}"}\n'); return;
    }
    note(`permission-reply ${j.decision}`);
    // The service closes its own pending prompt; the stub answers as
    // if it had, and the turn resumes speaking.
    res.writeHead(204).end(); return;
  }
  if (req.method === 'POST' && /^\/api\/session\/[^/]+\/interrupt$/.test(p)) {
    push('session.execution.interrupted', {}, stepMs);
    res.writeHead(204).end(); return;
  }
  if (req.method === 'POST' && /^\/api\/session\/[^/]+\/compact$/.test(p)) {
    res.writeHead(204).end(); return;
  }
  const prompt = p.match(/^\/api\/session\/([^/]+)\/prompt$/);
  if (req.method === 'POST' && prompt) {
    if (typeof j.text !== 'string' || !j.text) {
      res.writeHead(400).end('{"message":"expected {text}"}\n'); return;
    }
    note(`prompt ${j.text}`);
    const gen = ++turnSeq;
    let t = 0;
    const at = () => (t += stepMs);
    push('session.step.started', {}, at());
    if (wantPermission) push('session.permission.request', { requestID: 'perm-1' }, at());
    for (const s of says) {
      push('session.text.started', { ordinal: 0 }, at());
      push('session.text.delta', { delta: s }, at());
      push('session.text.ended', { text: s }, at());
    }
    push('session.usage.updated',
      { cost: 0, tokens: { input: 1234, output: 42, cache: { read: 0, write: 0 } } }, at());
    push('session.step.ended', {}, at());
    if (!stall) push('session.execution.succeeded', {}, at());
    res.writeHead(204).end(); return;
  }
  res.writeHead(404).end('stub: no route ' + req.method + ' ' + p + '\n');
});
server.listen(port, '127.0.0.1', () => console.error(`stub oc on ${port}`));
