#!/usr/bin/env node
// Step-driven opencode v2 SERVICE stub (the OpenCode adapter's fake).
// Same doctrine as stub_claude.mjs: speak only real wire shapes (the
// shapes a live 2.0.18 capture proved — see the golden tapes), record
// everything the bridge asks, and emit NOTHING until the test says so.
//
// Control port (STUB_CTL_PORT):
//   POST /push   {"type":"session.text.delta","data":{...}} → one SSE
//                bus envelope with a fresh monotonic id
//   POST /pushes {"events":[{type,data},…]}                  → many
//   POST /crash  {"code":1}
//   GET  /heard  the transcript (prompts, interrupts, replies)
import http from 'node:http';
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const log = process.env.STUB_OC_LOG;
const port = Number(process.env.STUB_OC_PORT || 4192);
const CTL_DIR = process.env.STUB_CTL_DIR;
const note = (s) => appendFileSync(log, s + '\n');

const stDir = join(homedir(), '.local/state/opencode');
mkdirSync(stDir, { recursive: true });
let SVC_PORT = 0;
const writeSvc = () => writeFileSync(join(stDir, 'service.json'),
  JSON.stringify({ url: `http://127.0.0.1:${SVC_PORT}`, pid: process.pid,
    version: '2.0.18-labstub', password: 'labpw' }));
const auth = 'Basic ' + Buffer.from('opencode:labpw').toString('base64');
const portsFile = CTL_DIR ? join(CTL_DIR, 'oc.ports') : null;

let evtSeq = 0;
let lastSid = null; // the service's own id for the conversation it made —
                    // every session bus event wears it, tagged HERE, the
                    // way the real service tags its truth (a test cannot
                    // know a minted id before the mint)
const subs = new Set();
const ring = []; // late subscribers get the tail replayed (the real
                 // service does; the adapter dedupes by id — pin that)
const send = (type, data) => {
  const d = data ?? {};
  if (type.startsWith('session.') && lastSid) d.sessionID = lastSid;
  const f = `data: ${JSON.stringify({ id: 'e' + (++evtSeq), type,
    data: d })}\n\n`;
  ring.push(f);
  for (const s of subs) s.res.write(f);
};

const svc = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => body += c);
  req.on('end', () => {
    const u = new URL(req.url, 'http://x');
    const h = { authorization: req.headers.authorization };
    if (h.authorization !== auth) { res.writeHead(401).end(); return; }
    if (u.pathname === '/api/info') { res.writeHead(200).end('{"ok":true}'); return; }
    if (u.pathname === '/api/model') {
      res.writeHead(200, {'content-type': 'application/json'}).end(
        JSON.stringify({data: [{providerID: 'lab', id: 'small',
          name: 'Lab Small'}]})); return;
    }
    if (u.pathname === '/api/session' && req.method === 'POST') {
      note(`session ${body}`);
      lastSid = 'sess-' + evtSeq + Math.random().toString(36).slice(2,6);
      res.writeHead(200, {'content-type': 'application/json'})
        .end(JSON.stringify({data: {id: lastSid}})); return;
    }
    if (u.pathname === '/api/event' && req.method === 'GET') {
      res.writeHead(200, {'content-type': 'text/event-stream',
        'cache-control': 'no-cache'});
      // The real service speaks the stream OPEN immediately (its first
      // bytes are headers/comment, not payload). Without this, an
      // empty-ring subscription flushed nothing, headers never landed,
      // and the bus was a silent hole — the fake behaving UNLIKE the
      // service it pins (the exact sin this doctrine forbids).
      res.write(': open\n\n');
      const sub = {res}; subs.add(sub);
      for (const f of ring) res.write(f); // replay the tail like the real bus
      res.on('close', () => subs.delete(sub));
      // UNSUBSCRIBE rides the RESPONSE's close (socket death), never the
      // request's: on a bodyless GET, req 'close' fires the instant the
      // (empty) request is done reading — and the subscription dies
      // seconds old. That is exactly how the lab's opencode turns were
      // born open and never closed: the bus wrote to a set that had
      // already dropped its only ear.
      return;
    }
    let m;
    if ((m = u.pathname.match(/^\/api\/session\/([^/]+)\/prompt$/))) {
      note(`prompt ${m[1]} ${body}`);
      res.writeHead(200).end('{}'); return;
    }
    if ((m = u.pathname.match(/^\/api\/session\/([^/]+)\/(interrupt|compact|model)$/))) {
      note(`${m[2]} ${m[1]}`);
      res.writeHead(200).end('{}'); return;
    }
    if ((m = u.pathname.match(/^\/api\/session\/[^/]+\/permission\/([^/]+)\/reply$/))) {
      note(`permission ${m[1]} ${body}`);
      res.writeHead(200).end('{}'); return;
    }
    if ((m = u.pathname.match(/^\/api\/experimental\/session\/([^/]+)\/instructions\/entries\/voice$/))) {
      note(`instructions ${m[1]} ${body}`);
      res.writeHead(200).end('{}'); return;
    }
    res.writeHead(404).end('nope');
  });
});
svc.listen(0, '127.0.0.1', () => {
  SVC_PORT = svc.address().port; writeSvc();
});

const ctl = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => body += c);
  req.on('end', () => {
    if (req.method === 'GET' && req.url === '/heard') {
      res.writeHead(200); res.end(readFileSync(log, 'utf8')); return;
    }
    if (req.url === '/crash') {
      const { code = 1 } = body ? JSON.parse(body) : {};
      res.writeHead(200); res.end('bye\n'); process.exit(code);
    }
    if (req.url === '/pushes') {
      const { events = [] } = JSON.parse(body);
      for (const e of events) send(e.type, e.data);
      res.writeHead(200); res.end('ok\n'); return;
    }
    if (req.url === '/push') {
      const { type, data } = JSON.parse(body);
      send(type, data);
      res.writeHead(200); res.end('ok\n'); return;
    }
    res.writeHead(404).end('no\n');
  });
});
ctl.listen(0, '127.0.0.1', () => {
  if (portsFile) writeFileSync(portsFile,
    JSON.stringify({ svc: SVC_PORT || svc.address().port, ctl: ctl.address().port }));
});
// write once more after svc's port is known even if ctl answered first
svc.on('listening', () => { if (portsFile) writeFileSync(portsFile,
  JSON.stringify({ svc: svc.address().port, ctl: ctl.address()?.port ?? 0 })); });
process.on('exit', () => note('exited'));
