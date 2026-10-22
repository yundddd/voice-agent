# Session channels: the seat becomes a speaker focus

Status: design (+251 era). Supersedes the seat-marker line of fixes
(+246 backgrounding, +247 refusal journal, +248 cross-harness switches,
+249 row/context ownership, +251 return-trip recapture). Those laws are
each correct and each is a patch over ONE missing concept: the phone and
the bridge both keep a single global conversation state, then re-home
pieces of it whenever the user moves. The model this doc proposes:

> Each session is a completely separate thing. The bridge routes each
> session's frames to that session. Each session behaves exactly
> normally — except that a session the user is NOT looking at receives
> its messages without speaking them.

## The objects

### Bridge: a turn registry, not a turn

Today: one child, one `turnOpen`, one ring, one `missed`, one backlog,
and `ctxOwner` bolted on to say whose number the bar shows. Replace with
a map keyed by session id:

    sessions: { [sid]: { child, frames ring, missed, ctx, phase, queued } }

- Every frame the bridge relays carries its `sid` (already true
  session-stamped from +246; the registry makes it structural instead
  of a label on a global stream).
- `/talk` gains the session it addresses: `{sid, text, interrupt…}`.
  Interrupt/queue semantics scope to THAT session's turn — which they
  already are in fact (+248: "the running child is bound to nothing but
  its own spawn"); the globality was only ever the API's shape.
- `/heard` acks are per mid and stay as-is (delivery law, wire v2).
- `/attach?sid=` replays that session's ring only. `missed` becomes
  per-session; the +168 mail-fetch reads the map.
- `/health` answers with the map plus `focus` (below). The
  `turnOpen/queued/missed` trio and the `ctxOwner` gate (+249) are just
  the map's fields; the owner-gate patch retires.
- `/seat` shrinks to `POST /focus {sid}`: it decides which session's
  frames the SPEAKER serves, and nothing else. No reset, no
  backgrounding law, no rest refusals (+246/+247/+248 all become
  theorems: nothing resets because nothing is shared to reset).
- Harness/dirs/models stay per-session entries in the map (the tab
  already carries harness/dir/model — it becomes the map's row).

### Phone: a SessionChannel per tab

One object per tab holding what VoiceAssistant holds globally today:

    class SessionChannel {
      ChatThread thread;          // store rows filtered by era+sid (exists)
      TurnState turn;             // busy, backgrounded, ticker, drain
      ContextBar ctx;             // its own sizes — no ownership gate needed
      WorkingRow working;         // spinner/thought/draft, owned outright
      StreamSub sub;              // its /talk or /attach view, alive or idle
      int missed;                 // its own mail
    }

`VoiceAssistant` becomes the coordinator: the tab ledger (already
there), the focus pointer, and the audio pipeline. The view projects
the FOCUSED channel; the tab strip reads the others.

- `turnHomeSid`, `ctxOwner`, the manual context zero, and
  `showWorkingRow`'s `turnHomeHere` clause all delete: the working row
  is a field of the channel that owns it, so "which tab shows the
  thinking box" is structural, not legislated.
- Any session's turn streams any time: its channel's subscription is
  live while its turn is open, regardless of focus. Frames → thread →
  store → ack (`/heard`) exactly as normal.
- **TTS gate:** the reply pipeline (sentence relay → synth → player)
  subscribes only to the FOCUSED channel. A backgrounded session's
  `say` frames are filed as text bubbles and acked (the thread is
  complete when you open it — the +168 honesty: opening a tab is
  reading mail, not missing a call). No audible replay on foreground;
  the unread count and the gear badge (+230) are the sign that work
  happened out of earshot.
- Barge-in, the drain (+124/+164), the heard ledger and the +250
  context-full verdict all become PER CHANNEL: a barge interrupts the
  focused channel's turn; a parked drain belongs to the channel that
  owed it. The cross-session law the phone kept learning (+250: the
  verdict "rides as text" to every transport) is just each channel
  minding its own state.

### Era notes from the steps as they land

Step 1 (+252, phone): landed as written — SessionChannel with one
instance, all 466 walks the extraction proof.

Step 3, phone portion (+254): Tim's watermark LAW landed where the
pump decides mouths — BridgeTurn._onSay asks two questions before it
dare speak: is this view's conversation the seated one (identity: the
+246 backgrounding kept the stream alive; from now on its paragraphs
file into the thread, mute — the gear badge signs them, the thread
delivers them), and was the frame stamped before the focus landed
(watermark: SessionChannel.focusAtMs, recorded by the phone's clock in
the bridge's clock domain — the same _ts every frame carries, which
the bridge has always preserved across replays for exactly this kind
of question)? A say that fails either is filed AND acked (received
means acked — the +253 walks pin the commit riding the mute path) and
journalled by name: 'pre-focus backlog' / 'unfocused conversation:
logged silently, not spoken'. Unstamped frames (old bridges) fall
through to the age and heard-ledger laws unchanged. The focus moves
that set the watermark: switchSession and createSession (boot's
reconcile does not — the screen never moved; it put the seat back
under the tab already in view).

Step 2 (+253, bridge): landed as a WRAP — `sessions` map in
claude_bridge.mjs, rows minted at turn birth (or at the harness
speaking a birth turn's name mid-flight), resting with their context
size at death; `/health` answers `sessions` + `turnSid` beside the old
globals. Two boundary discoveries, both of which the map documents:
the record swap can only happen at TURN boundaries, not seat moves —
a backgrounded turn's stream owns the parse globals until its result
lands (that is exactly why the +249 ctxOwner gate exists, and it
retires only when parsing itself goes per-record); and one turn is
live at a time today (the queue is a single slot), so this era the
map is a LEDGER that reports who held the machine, not yet a router
that serves two. Per-session rings and a per-row queue slot — the
actual concurrent-inactive-receive — are the map's next increment.

## Migration order (tests green at every step)

1. ✅ (+252) Phone first: extract `SessionChannel` from
   `VoiceAssistant`'s globals with exactly ONE channel instance and
   the focus trivially on it. All 250 eras of walks keep passing —
   the extraction is the proof the state was one channel's anyway.
2. ✅ (+253) Bridge: wrap the single turn into the map + `focus`;
   `/health` answers both old globals and the map for one era; the
   phone reads the map.
Step 2.5 (+257, bridge): the LEDGER BECAME THE ROUTER. The
`Conv` record is real per-conversation state — child, turn, queue
slot, parse tally, context sizes, tool receipts, unheard backlog —
and the module globals are its FOCUSED bundle: every handler reads
the names it always read, and `withConv` is the only door between
bundles. Children bind their stdout and exit to the record that
spawned them, keep-pingers carry their record, /seat is a save-and-
load swap, /heard trims every backlog (mids are globally unique),
/stop takes `?sid=`, and the phone's Stop chip now addresses the
conversation whose context frames it watched. The law this buys is
the one Tim's tape could not get from any marker: a prompt to a
conversation with no turn of its own STARTS, while another
conversation's answer streams in the background — the queue is no
one else's floor (walk: 'two conversations work at once, each with
its own row'). Known era limits, honest: the opencode backend is
still a single session object (one oc conversation at a time — the
bus filter speaks for it); the ring and the /health `missed` scalar
stay transport-global (a phone with N ears reads rows for per-
conversation mail); and the phone still keeps ONE SessionChannel —
the away conversation's thread is fed by its still-alive view, mute
by the +253 identity gate, and the marker family retires when the
phone's map lands.

3. ✅ (+254, closed +298) Phone: the TTS gate (identity + watermark)
   at `_onSay` — walks (a), (b-silent), (c) and the return-arc are
   green. The debts this step owed until +298: N channel instances
   with per-channel live subscriptions (the single `_chan` wore every
   tab's state; the watermark rode it correctly because every focus
   MOVE re-stamps it, but the away conversation's turn bookkeeping —
   ticker, drain, row — was ONE bed two conversations took turns
   in). CLOSED at +298: `VoiceAssistant` now holds
   `{sessionId: SessionChannel}` — the review's
   SessionStore[sessionId], turn slice — keyed by the bridge's
   app uuid (+295), with the unnamed slot
   (`ChatStore.pendingSession`) adopted into the first name the
   wire speaks (the exact law the chat bubbles follow). The seat
   looks through `_chan`; pumps bind their channel at build, so
   the generation/seq/busy/badge tokens, the meter, the badge,
   the owed-shell ledger, the parked drain and the pick-up wait
   all speak for THEIR conversation by construction. Frames
   stamped for another conversation ROUTE to its ledger
   (`BridgeTurnEnv.routeForeignTool`) — away work keeps its own
   meter moving; the bar you come home to shows where the work
   was. Still honestly deferred: per-session rings for the
   never-acked backlog (one multiplexed wire, one cursor — the
   +249..+274 stamp laws serve it), and (d) a barge scoped to
   the focused turn only (one speaker; the epoch law A already
   silences what must not sound).
4. ✅ (+298) The marker laws are deleted: `turnHomeSid` (its whole
   capture/sign/retire family — a channel IS its own marker), the
   +297 owner gates (`_liveWorkIsHere` — parking behind a
   stranger's busy flag is now UNREPRESENTABLE), the +287
   owner-pair probe (the ladder belongs to its channel and
   settles it alone), and the +279.1 nameless-row fallback.
   `turnHomeHere` stays in the view API, honestly tautological —
   every projection is its own home — while the gear badge's
   cross-session sign (+230) moved to the new `awayWork` arm
   (any channel busy/badged/owing). The +246…+257 walks retargeted
   to the structural signals; /health's clean bill settles only
   the channel it names, and a nameless report keeps the old
   global proof for the old wires.

### The focus switch is a watermark (Tim's +251 clarification)

Swiping onto a session that OWES unheard frames does not speak them:
the pending backlog is drained silently (filed, acked, visible). TTS
adopts only the NEW messages of that session — frames that arrive
after the focus landed. A turn still generating at the moment of the
swipe splits on the same line: its sentences already streamed while
backgrounded file silently, its next sentence speaks, because the
relay cuts at sentence boundaries anyway. The rule generalizes the
+168 mail-fetch honesty to tabs: reading mail never speaks, whatever
is written AFTER you sit down at the desk does.

## Why the ack-on-receive (not replay-on-foreground)

A phone that only speaks what you're watching behaves like every
notification you already trust: the message landed, the thread knows,
the badge tells you. Replaying a backgrounded session's answer at full
volume the moment you glance at it is the exact behavior +168's
mail-fetch law exists to forbid — history the ear already owns must
not speak. Tim's rule, verbatim: an inactive session "shouldn't process
the TTS, but we should still receive messages from the bridge" —
received means acked; an ack that could be re-sent is not received.

## +302: the new button, or why staleness must ask the issuer

The field tape for a phone-side law: three presses of the /new chip
in thirty seconds, each answered by the bridge (`[seat] … starts
fresh on the next word`) and each cut short on the phone —
`reply tail dropped: 1 unplayed chunk(s) — pump superseded between
chunks`. The button looked dead because its confirmation was
invisible-orphaned and its voice was self-truncated.

Two leaks, both grandchildren of +295's frozen name and +298's
swappable seat:

1. **The /new wipe predated the identity law.** It purged the live
   channel along with the history — correct when /new RENAMED the
   record, wrong now that /new only starts it fresh. The seat went
   unnamed, the ack stamped the pending sentinel (invisible under a
   named tab, and userOnly adoption can't rescue an assistant
   bubble), and the swap itself armed leak two. The law now: the
   HISTORY dies, the IDENTITY stands. The seat's channel retires its
   warrants in place (debts settled, badge and work retired — an
   erased thread's owed shells have no ear), the tab's OTHER ids
   lose their channels, the bubbles (the chip's own two included —
   the +230 blankness law) go, and `sessionIds` keeps exactly the
   uuid the bridge still calls this record.
2. **Every staleness closure read `gen == _generation`** — the
   generation of WHICHEVER channel the seat looks through now.
   Sound in one-channel worlds; since +298 a seat swap (a tab
   switch, or /new's own wipe) flips the verdict of every live
   replay. Sixteen sites now bind the ISSUING ledger at the claim —
   `_stale(led, gen)`, `_startPump(gen, led:)`,
   `_speakResumedPending(text, gen, led:)` — because a generation is
   a number only its ledger can interpret. The scenario rig walks
   it: /new blanks the screen, speaks its ack WHOLE, keeps the tab's
   uuid, and the next exchange lands on the same tab clean.
