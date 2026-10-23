#!/usr/bin/env node
// Step-driven stream-json stub: the fake Cloude CLI for the test lab.
// It speaks ONLY real wire shapes (fragments of the golden tapes in
// tapes/ — never a nicer imagination; that is exactly the +325 lesson:
// the Dart fake behaved better than the real bridge, and the turn-id
// bug walked through the door).
//
// Nothing happens on its own. Every stdin line is RECORDED (prompts,
// interrupts, model picks) and answered only when the test commands the
// control port:
//
//   POST /emit   {"frame": {...}}   → one JSONL line on stdout, now
//   POST /emit   {"raw": "..."}     → verbatim line
//   POST /crash  {"code":1}         → process exits, mid-turn if open
//   GET  /heard  → the stdin transcript (what the bridge has asked)
//
// Env: STUB_LOG (transcript file), STUB_CTL_PORT (control port). The
// flags the bridge passes (-p, --input-format, --resume, …) are accepted
// and ignored, same doctrine as bridge_stub_claude.
import http from 'node:http';
import { appendFileSync, readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// One child per conversation: bind ANY free port and file it under the
// conversation's name (BRIDGE_CONV is the record's uuid — the testlab
// reads <name>.port to find the child it wants to poke).
const CTL_DIR = process.env.STUB_CTL_DIR;
// one transcript per conversation, next to the port file (STUB_LOG is
// shared across every child the bridge spawns — not good enough here)
const log = CTL_DIR
  ? join(CTL_DIR, (process.env.BRIDGE_CONV || 'boot') + '.log')
  : process.env.STUB_LOG;
const note = (s) => appendFileSync(log, s + '\n');
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const SESSION = 'stub-' + Math.random().toString(36).slice(2, 10);

process.stdin.setEncoding('utf8');
let lineBuf = '';
process.stdin.on('data', (b) => {
  lineBuf += b;
  let i;
  while ((i = lineBuf.indexOf('\n')) >= 0) {
    const line = lineBuf.slice(0, i).trim();
    lineBuf = lineBuf.slice(i + 1);
    if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.type === 'control_request') {
      const sub = m.request?.subtype;
      note(`ctl ${sub} ${JSON.stringify(m.request?.model ?? m.request ?? '')}`);
      // A set_model the CLI 'refuses' when the transcript asked it to:
      // the bridge deserves the real control_response error shape.
      if (sub === 'set_model' && refuseModel === m.request?.model) {
        refuseModel = null;
        note(`refused ${m.request?.model}`);
        out({ type: 'control_response',
          response: { subtype: 'error', request_id: m.request_id } });
      }
      continue;
    }
    if (m.type === 'user') {
      const c = m.message?.content;
      note(`prompt ${typeof c === 'string' ? c : (c?.[0]?.text ?? '')}`);
      continue;
    }
  }
});
let refuseModel = null;

const ctl = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => body += c);
  req.on('end', () => {
    if (req.method === 'GET' && req.url === '/heard') {
      res.writeHead(200); res.end(log ? readFileSync(log, 'utf8') : '');
      return;
    }
    if (req.url === '/refuse_model') { // arm the next set_model refusal
      refuseModel = JSON.parse(body).model;
      res.writeHead(200); res.end('armed\n'); return;
    }
    if (req.url === '/crash') {
      const { code = 1 } = body ? JSON.parse(body) : {};
      res.writeHead(200); res.end('bye\n');
      process.exit(code);
    }
    if (req.url === '/emit') {
      const j = JSON.parse(body);
      const list = Array.isArray(j) ? j : [j];
      // Tape frames carry the RECORDED session_id; every child speaks
      // with its own conversation's backend id, or the bridge would
      // rekey two records onto one key (a fidelity bug in the fake —
      // precisely what the tapes doctrine forbids).
      const mySid = SESSION;
      for (const e of list) {
        if (typeof e.raw === 'string') process.stdout.write(e.raw + '\n');
        else {
          const m = e.frame;
          if (m && typeof m === 'object') m.session_id = mySid;
          out(m);
        }
      }
      res.writeHead(200); res.end('ok\n'); return;
    }
    res.writeHead(404).end('no\n');
  });
});
ctl.listen(0, '127.0.0.1', () => {
  if (CTL_DIR) {
    mkdirSync(CTL_DIR, { recursive: true });
    writeFileSync(join(CTL_DIR, (process.env.BRIDGE_CONV || 'boot') + '.port'),
      String(ctl.address().port));
  }
});

// stdin EOF = the bridge is gone (a SIGKILL would otherwise orphan this
// child onto its control port forever): a real CLI dies the same way.
process.stdin.on('end', () => process.exit(0));
process.stdin.on('close', () => process.exit(0));
process.on('exit', () => note('exited'));
