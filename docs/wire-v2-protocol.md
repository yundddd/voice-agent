# Wire v2 — identity and acknowledgement (plan)

## Why

The mental model is two lines: **the bridge forwards the conversation; the app
is the user's window on it.** Today the wire makes that impossible, because it
carries *events* while the app must maintain a *state*: "what happened, in
which turn, and which of it has this phone already shown or said?" Every answer
is inferred, and every inference has produced its own field incident:

| question | current inference | incident it caused |
|---|---|---|
| is this message already heard? | text match vs chat log | reused paragraph swallowed (+155); same paragraph re-voiced by a drain (+156→dup today) |
| whose turn is this frame? | position vs a `started` marker | pin fossilised by a prior `done` (+131, +157's gate) |
| did the phone actually say it? | socket delivery | `missed=9` replays of freshly heard frames |
| is this farewell mine? | swallow-all-until-marker | pump died on a stranger's `done` (+157) |

We have patched inference with inference for days. v2 deletes the inferences:
**every frame gets an id and a turn, and hearing becomes an explicit
acknowledgement.** The bridge then replays only what was genuinely never heard,
and the app renders what arrives, once.

No backward compatibility (user dictum): one lockstep release of bridge + APK;
an old app on a new bridge gets a visible "update the bridge" error and nothing
subtler.

## Wire v2

### Framing (all transports)
Every relayed event's data gains two fields, stamped inside `relay()`:

- `_mid` — the message id. One counter, monotonic across the bridge process,
  assigned **before** ring/backlog branching, so the ring copy, the backlog
  copy and every view see the same id.
- `_turn` — the turn id. Turn ids are **reserved at enqueue/POST time**
  (a queue notice and its prompt's `started` marker carry the id their turn
  *will* have), so a frame's ownership is decidable at arrival, forever.
  `done`/`error` carry the id of the turn they close.

### Endpoints
- `POST /talk` — unchanged shape; gains an echo of the reserved turn id:
  - poll: the response body is `{"ok":true,"turn":N}` before the socket ends;
  - push: the stream's first SSE event is `turn` with `data: {turn:N}`.
- `POST /heard {mids:[...]}` (new) — the phone's **commit** acknowledgement.
  The bridge removes those mids from the unheard backlog. No response body
  needed beyond 200. Ack happens when the phone TAKES the paragraph, so a
  barge-in never leaves a debt: interrupted paragraphs are dropped by design,
  and the backlog replays only what the phone never saw at all.
- `GET /attach` — unchanged shape (backlog replay, then live), but the backlog
  now means what `missed` claims: **relayed and not yet acked**. Every frame
  carries `_mid`/`_turn` anyway.
- `GET /poll` — unchanged cursor semantics; `data` carries the fields.
- `GET /health` — gains `proto: 2` and `turn: <current or 0>`; `missed` is now
  *literally* the unheard count (it is today only incidentally).

### What "heard" means
A mid is acked when the phone **takes** the paragraph: the moment it enters the
speak path (or, TTS-off, enters the chat log). Barge-in does NOT retract the
ack — a paragraph interrupted before or mid-audio is **dropped**, never to be
re-delivered (user dictum: "for barge in just drop"). This extends the +116
trade already lived ("a paragraph cut off mid-audio counts as heard; its tail
is not repeated") to the pre-audio case, and it is what the +114 retraction
experiment kept converging to anyway: never re-listening beats
never-not-listening, and the backlog shrinks to a single honest meaning —
**never reached the phone at all**. Ack is batch-friendly: the phone piggybacks
mids per POST and re-sends its small pending-ack list after a network miss
(relays stay idempotent by `_mid`).

## Bridge changes (`claude_bridge.mjs`)

1. `msgSeq` + `turnSeq` counters; `relay()` stamps `_mid`, `_turn`.
2. Turn id reserved in `talk()`/`flushPending()` before queueing; echoed per
   transport; `beginTurn` receives it instead of inventing one.
3. Backlog entries become `{mid, ev, data}`; `DELETE`-on-`/heard`.
4. `started` marker: still relayed by `beginTurn` and still permanent in the
   backlog (its job now is queue UX — un-grey, receipts order — not dedup).
5. Delete the phone-facing inference the bridge also does: `spokenTexts`
   (exact-text relay dedup) stays — it dedups the CLI's own snapshot
   re-emissions, a different problem. Note that in its comment.
6. `/health` `proto: 2`; startup log prints the version banner.

## App changes (`lib/src/…`)

1. **`HeardLedger`** (new, `assistant/heard_ledger.dart`): persists acked mids
   (bounded, ~1000, LRU) in prefs; exposes `isHeard(mid)`, `commit(mid)`
   (= persist + enqueue ack at TAKE time — never retracted on barge-in).
   Pending acks retry on any bridge call.
2. **`BridgeEvent`**: parse `_mid`, `_turn`; `forTest` builders take them.
3. **`_onSay` collapses to:**
   ```
   if (ev.mid == 0) → protocol error (banner);
   if (heard.isHeard(ev.mid)) → log 'dup by id — skipped', return;
   if (age > ARCHIVE && !heard) → addBlock text-only, commit(mid), log 'silent backlog', return;   // one-line courtesy rule
   else → heard.commit(ev.mid), then speak
   ```
   One path for push/poll/attach/replay — the `via` branches, archaeology
   matrix, `inFlight` text set, boundary and `containsBlock` law all die.
4. **Pump (`transport._pollTurn`)**: knows `myTurn` from the POST echo; ends
   only on `done/error` with `_turn == myTurn`; foreign farewells pass
   through harmlessly (the loop ignores them by id). Marker-gate and the
   swallow law deleted. Deadline logic unchanged.
5. **Queue/pin UX**: `started` (own id) dissolves the pin as today;
   `_beforeEvent`'s parked check becomes `ev.turn < myTurn` (the waited
   turn's frames keep the grey; my frames take the floor) — a comparison,
   not a law.
6. **Chat log** (as shipped): the journal line carries the mid, bubbles do
   not. `ChatStore.containsBlock` survives ONE honest render-side use —
   the banner note's adjacency guard (one event, one bubble). The delivery
   ledger is `HeardLedger` alone; a fresh empty ledger meets a fresh
   empty backlog (the bridge restart at upgrade zeroes the backlog, so
   mixed-version history cannot exist).
7. `debugDetachUnheard`, view projections, spinner/banner/stop laws: untouched
   — this is the delivery layer only.

## Test plan

- **Wire suite (node):** every frame carries `_mid`/`_turn`; POST echo names
  the reserved turn (immediate *and* queued flush); `/heard` trims the backlog
  (`missed` drops on /health); `/attach` replays only un-acked mids; a
  re-relayed CLI snapshot gets one mid; `done._turn` matches the echo; queued
  notice's `_turn` equals the later marker's.
- **`turn_flow`:** rewrite the +139 (duplicate bubbles), +155/156 (reused
  paragraph), +157 (stranded answer) walks in id terms: redelivery of a
  committed mid never re-speaks, *even with identical text, even fresh*;
  a never-acked unheard paragraph is re-delivered once and spoken; an
  ancient never-heard paragraph logs silently; a barge-in before first sound
  acks and drops (no re-delivery ever); the pump ignores another turn's
  `done` by id, ends on its own.
- **Fakes:** `FakeHarness` stamps mids/turns and serves the echo; the stub
  CLI gains a "repeat a previously used paragraph" mode (the field's trick).
- Existing queue/pin/banner/stop suites must pass untouched — they pin the UX
  layer this change must not move.

## Shipped as (0.1.0+158)

- `proto: 2` + `turn` on /health; `_mid`/`_turn` on every frame; JSON
  receipt on polled POSTs, `turn` SSE event first on pushed; `/heard`
  trims; `/attach` replays without consuming. Wire suite 12 green.
- App: `HeardLedger` (lib/src/assistant/heard_ledger.dart) — lazy
  in-memory until the disk copy loads, acks batched, retried from every
  `_refreshSession` and every commit; `_onSay` is the set lookup + the
  one age line; the poll pump attributes farewells by `_turn` (+131's
  armour and +157's marker gate retire into one comparison); the
  started marker is queue UX only; barge-ins drop. Dart suite 310 green.
- The proto gate refuses sends (`Bridge too old — install the new
  claude_bridge.mjs`) once a /health has answered non-2.

## Rollout (lockstep, no fallback)

1. Bridge v2 (+ wire suite) → deploy systemd unit; `/health proto:2`.
2. App v2 (+ suites) → APK; on connect, `proto != 2` → error banner
   "Bridge too old — install the new claude_bridge.mjs" and no turn UI.
3. Delete-the-dead-code commit after both land, so the diff that *removes*
   the old law is reviewable separately from the one that adds the new path.

## Risks / resolved decisions

- **Ack lost in transit** → backlog keeps the mid; the phone re-acks from its
  ledger (a committed-but-unacked list); worst case is one duplicate that
  `isHeard` swallows on arrival. Idempotent both ends.
- **Two phones / future clients** → per-connection backlog today means
  first-listener-takes-all; v2's backlog is per-*bridge*, same semantics as
  now; per-client ack sets are a later, additive step.
- **Restart semantics** → bridge restart clears the backlog (as now); the
  phone's ledger is by mid, and a bridge restart resets counters, so ids
  restart from 1 with both stores wiped together — clean. (Counter seeded
  from boot time to avoid aliasing across rapid restarts.)
- **Age rule kept** — one condition, not a matrix: ancient-but-never-heard
  text is shown silently. If it ever misfires, it degrades to "one old
  paragraph unvoiced after a week offline", not a wrong bubble.
