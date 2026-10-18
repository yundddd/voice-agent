# Design review: making the interrupt/queue/detach core testable without a device

> **STATUS: IMPLEMENTED** (2026-10-18). Everything in §3–§5 landed:
> `bridge_turn.dart` (the one event loop, three origins),
> `hide_resume.dart`, `reattach_chain.dart`, `activity.dart`,
> `view.dart` + `AssistantView` projection. The conversation widgets
> (`ChatBubble`, `HarnessSpinner`, `BackgroundedWorkCard`,
> `QueuedBubbleCard`, `ContextBar`, `LatencyStrip` — and since +135 the
> full-area `TalkSurface`, which replaced the FAB hold guide)
> render the view, not the machine; `assistant_screen` builds one
> snapshot per frame. The full suite (now 280) runs on the
> VM in ~2 s: `turn_flow_test` (orchestrator regressions, unchanged —
> the behavior-preservation proof), `bridge_turn_test` (the loop
> without an orchestrator), `reattach_chain_test` (ladder on fake
> clock), `hide_resume_test` (transitions), `assistant_view_test`
> (behavior AS view differences), `ui_widgets_test` (widgets from
> hand-built views, no fakes at all). `voice_screen`/`bridge_screen`
> keep talking to the assistant directly — settings surfaces, not the
> behavior mirror; §3.4's phone-abstracting claim belongs to the
> conversation screens. Recorded wire fixtures (§5.6) remain optional.

Scope: `lib/src/assistant/`, `lib/src/bridge/`, `lib/src/ui/`, `test/`.
Question: can the app be refactored so the behavior that historically carries the
bugs (supersede, detach, polite queue, badge, reattach, hide/resume) is verified
in milliseconds on the VM, and the UI becomes a separate layer that mirrors a
data structure instead of the phone?

## 1. Where we already are

The seams are in surprisingly good shape, and the premise "the only way to
verify behavior is the simulator" is already half false:

* Every outer collaborator is injectable on the `VoiceAssistant` constructor:
  `MicSource`, `AudioOutput`, `HarnessGateway` (factory), `SpeechEngine`,
  `Clock`, `Scheduler`.
* `test/support/fakes.dart` + `test/turn_flow_test.dart` drive the **whole
  turn lifecycle headlessly** — 900+ lines of regression tests for the
  +72…+128 field reports (detach-keeps-spinner, queue pin push-vs-poll,
  ledger-stamp-at-air, zombie wire hop, parked drain verdict) running in
  milliseconds with `FakeScheduler`.
* `TurnCoordinator` (turn_session.dart) already collapsed the bridge-turn
  *truth* (busy, badge, bgWork snapshot, gen/seq) into named transitions, and
  `takeoverStop` is the interrupt policy expressed as an exhaustive data
  table. `BridgeTurnPump` unified the queue+wake plumbing of both event
  loops. `WireLease`, `ChatStore`, `NarrationGate`, `TokenTicker`,
  `HopTracker`, `PttHold` are each unit-guarded.

So the machinery *is* testable. The remaining friction is that the **unit of
behavior** — a turn's event loop — is not itself a unit: it lives as two
~350–470-line inline closures inside `VoiceAssistant` (3,248 lines), and the
**shape the UI consumes** is imperative prose strings, not a data structure.

## 2. The four clusters that still force device-level verification

### 2.1 The turn loop is a method, not an object

`runQuickCommand` (assistant.dart ~L643–1155) and `reattachBackgroundTurn`
(~L1996–2308) each build a `BridgeTurnPump` with a ~120-line `onEvent`
closure that is *nearly identical* (say → clean → ledger → speak; tool →
ticker/label/heartbeat; `started`/`finished` receipts; context merge), plus a
~110-line `finally` teardown (release pump, wireOrphan verdict, retract
un-aired commits, mark interrupted, close stream, drain backlog). This is
exactly the copy-paste-pair shape that `BridgeTurnPump`'s own doc comment
calls out as "the reason they used to be a 60-line copy-paste pair with
subtly divergent bug fixes" — the loop body regrew the pair one level up.
Every queue/detach/receipt rule change must be made (and verified) in both
closures; the tests can only reach them through the full `VoiceAssistant`
facade, which drags in mic/bench/voice state that a detach test doesn't care
about.

### 2.2 The hide/resume dance is still loose fields

`_backgrounded`, `_conversationWasLive`, `_dropAfterHide`, `_resumeReplyText`,
`_pausedWorking`, `_drainAfterSpeech` (+124) are mutated from
`pauseConversation`, `resumeConversation`, `speak()`, `_speakResumedPending`,
`_replayPendingReply`, `_handleNaturalEnd` — the same "N raw flags mutated
from M sites" disease that `TurnCoordinator` was created to cure, left in
place on the lifecycle side. The bugs pinned in comments there (double
`pause` on the way up, amnesia replay of a half-heard paragraph, replay
cutting mid-word audio) are all *interaction-between-fields* bugs — the
class of bug a named-transition state unit with its own truth table is
precisely good at preventing.

### 2.3 State-as-prose: `_status` is the UI model

Phase, busy, badge and queue are properly structured, but the working line,
idle hints, error text and detach verdicts are carried in `_status` /
`_error` as display strings assembled at the mutation site
(`'Bash ${ev.detail}…'`, `'One moment — …'`). Consequences:

* Behavior tests must assert on prose (`expect(a.status, 'Bash flutter
  test…')`), so rewording breaks tests that mean to pin *behavior*.
* The UI can't render "what is true now" — it renders whatever string was
  last assigned, so correctness of the screen is only observable on screen.
* The bottom-line/badge/pin rules ("the empty string IS the auto-dismiss")
  are enforced by convention across three files.

### 2.4 The widgets read the god object, not a projection

`ChatBubble`, `HarnessSpinner`, `BackgroundedWorkCard` take
`VoiceAssistant` and pull 10+ getters (`harnessElapsed`, `turnSettled`,
`tokenThought`, `tokenDraft`, `activityLabel`, `backgroundedWork`…), do
formatting (`formatBubbleClock`, `_fmtTok`, age math) and own timing
(120 ms wheel, 1 s age tick) *inside* the render path. There is no
checkpoint where "the data this screen should show" exists as a value, so a
UI change can only be validated by running the app. This is why the phone
feels load-bearing for verifying behavior: the *projection* only exists
during rendering.

## 3. Target shape

Three layers, no framework rewrite — the existing collaborator+callback
style is right and keeps every scar-tissue comment attached to its rule:

```
ui/            widgets + a thin ChangeNotifier adapter (VoiceAssistant stays
               the widget-facing object, but only ever exposes `view`)
        ▲  projects
core/          the turn machine: BridgeTurn, TurnCoordinator (exists),
               HideResume, ReattachChain — pure Dart, no dart:io, no Flutter,
               emits state + effects
        ▲  over ports
adapters/      BridgeClient, RecordMicSource, FilePlayerAudioOutput,
               SpeechWorker, file-backed chat persist, journal, wall clock
```

### 3.1 Extract `BridgeTurn` — the behavioral twin of `TurnCoordinator`

One object per bridge turn (heard `/talk`, `/attach` replay, or control
stream), owning what the two closures own today: the gen/seq claim, the pump,
the 15 s pulse, `committed`/`aired`/`_inFlight` ledger, `speak()` with the
air-stamp law, the tool-step/narration dispatch, and the teardown
(`wireOrphan` verdict, retracts, interrupt stamp, backlog drain). The
differences between the /talk and /attach variants become constructor
parameters (a `beforeEvent` policy, the replay archaeology rule, an optional
`replayFirst` block). `runQuickCommand` shrinks to: decide pin/detach
verdicts → build a `BridgeTurn` → open the stream. `reattachBackgroundTurn`
same, with the attach stream.

Testing payoff: a detach/queue/receipt test constructs a `BridgeTurn` with
`FakeHarness` + gate + fake sink and drives *only the turn* — no mic, no
bench, no voice state. Teardown rules get tested by presenting scripted
`PumpOutcome`s. The two loops can no longer diverge because there is one.

### 3.2 Extract `HideResume` and `ReattachChain` the same way

* `HideResume`: owns `_backgrounded`, `_conversationWasLive`,
  `_dropAfterHide`, `_resumeReplyText`, `_pausedWorking`; transitions
  `hide()`, `resume()`, `noteSpeak(text)`, `chunkBecameAudible()`; returns
  what the assistant must do (re-speak this text, restart pump, flush
  journal, snapshot status as an `Activity` value). The double-pause guard,
  skip-don't-replay rule and "only unheard says earn the resume promise"
  become table-driven transitions with direct tests.
* `ReattachChain`: owns `_reattachGen/Seq/Step/Retire/Timer` and the ladder
  (already data: `kReattachDelays`); `start/advance/retire` transitions,
  verdicts from `bridgeReattachNeeded`. Its guards (PTT pointer down,
  bench, hidden, ownership) become explicit inputs so the +52/+124 stomps
  are pinned per-transition instead of per-integration.
* Move `_drainAfterSpeech` (the +124 parked verdict) into `ReattachChain` —
  it is chain state by meaning.

### 3.3 Replace prose state with `Activity` values, project strings at the edge

Model the working line as data:

```dart
sealed class Activity {}
class IdleHint / Thinking{tokensIn,tokensOut,thought,draft,settled,since}
class ToolStep{name,detail,isBareCommand} / Spoken{block}
class QueuedVerdict{reason} / DetachedWork{step,sinceMs} / Failed{message}
```

`speak()` paths, the ticker and the gate already have the inputs. The status
*string* becomes a pure render function `statusText(Activity, phase, mode)`
called by the projection (keep `_status` as a cached render during
migration so every existing test keeps passing). Tests then assert
`ToolStep(name:'Bash', detail:'flutter test')` — wording stops being a
regression surface, and the eyes-only/heartbeat rules (`stepIsSilentFor`)
stay exactly where they are.

### 3.4 A projected, immutable `AssistantView`

`VoiceAssistant` gains one member that widgets are allowed to use:

```dart
AssistantView get view; // rebuilt (or memoized) on every notifyListeners
```

with the shape the screen actually renders today:

```dart
record AssistantView {
  AssistantPhase phase; InteractionMode mode;
  Activity activity; String statusText; String error;
  List<ChatEntry> chat; int chatVersion;
  ChatEntry? liveTurnBubble; QueuedPin? queued;      // text + createdMs
  BgWorkLine? backgrounded;                          // label + sinceMs + age
  TokenMeter ticker; ContextBar context;
  PttGuide ptt;                                      // holdActive, slide-armed flags
  bool bridgeBusy, harnessBackgrounded;
}
```

It is a pure function of (coordinators + stores + trackers) — which means:

* **Phone-abstracted UI tests:** run the core headlessly, capture the
  `AssistantView` sequence as a scenario plays, and assert on it (value or
  golden). "Does the spinner survive a press over a tool-only turn (+126)"
  becomes a snapshot assertion, not a screen observation.
* **Separately iterable UI:** widgets take `ChatEntry`/`TokenMeter`/
  `BgWorkLine` values, not `VoiceAssistant`. Widget tests construct views
  by hand — no fakes at all for pure render bugs; the formatting helpers
  move from widgets to the projection layer where they can be diffed
  against fixtures. `HarnessSpinner`'s wheel phase rule ("freeze only when
  purely talking", "+84 settled") is already derived state — put that
  derivation in the view (`spinnerSpinning: bool`) and the widget just
  paints.
* The debug ring / journal keep working: they subscribe to the same
  transitions core-side.

## 4. Test strategy after the split

| Layer | What is asserted | Needs device? |
|---|---|---|
| `takeoverStop` / detach policy | the table itself (already) | no |
| `BridgeTurn` | event in → effects out (`SpeakBlock`, `PostStop`, `RetractCommit`, `Journal`), teardown verdicts from scripted `PumpOutcome`s | no |
| `HideResume`, `ReattachChain` | transition sequences vs scripted `FakeScheduler` time | no |
| Projection | `AssistantView` values per scenario step (goldens of view-state lists) | no |
| Widgets | render from hand-built views; golden tests | no |
| Adapters (`BridgeClient`, poll transport vs `tool/claude_bridge.mjs`) | contract tests vs recorded wire transcripts — `tool/bridge_stub_claude.mjs` already gives the stub | no |
| Audio route / mic HAL / Tailscale / real SSE | smoke only | yes |

Behavior scenarios can even become **data**: the existing fakes are already
an event scripting DSL, so a `scenarios/` folder of small turn scripts
(press → frames → hide → detach…) shared between the core test (assert
effects) and a widget test (render the view sequence) makes one field report
equal one fixture, verified at both layers.

## 5. Incremental migration (each step shippable, guarded by the existing suite)

1. **Snapshot today's suite as the safety net** — `turn_flow_test.dart`
   already runs on the VM; run it before/after every step below, unchanged,
   until each step's own tests replace the relevant assertions.
2. **Add `AssistantView` + `project()`** inside `VoiceAssistant`, no other
   behavior change; migrate one widget (start with `BackgroundedWorkCard`)
   to render from the view. Immediate payoff: view goldens exist.
3. **Extract `BridgeTurn`** from the two closures; `runQuickCommand` and
   `reattachBackgroundTurn` become openers. Move the turn-flow tests that
   target turn behavior into `bridge_turn_test.dart` driving the class
   directly (keep a couple of facade-level ones as wiring proof).
4. **Extract `HideResume` and `ReattachChain`**, mirroring the
   `turn_session_test.dart` style: transitions and invariants first, the
   assistant reduced to firing them.
5. **`Activity` values behind `_status`** — render at the projection edge;
   rewrite prose assertions in tests to value assertions as they come
   naturally.
6. Optional: record real `/poll` and `/talk` transcripts (the journal +
   `wireTag` already carry everything needed) into replay fixtures, so the
   poll/push transport negotiation itself is also a VM test.

## 6. What not to change

* Do not adopt Bloc/Redux wholesale — the callback-seam pattern is carrying
  ~30 documented field-report rules and every framework indirection makes
  those comments harder to keep true.
* Keep `TurnCoordinator` and the `takeoverStop` table exactly where they
  are; this proposal generalizes their pattern (single writer, named
  transitions, policy-as-data) to the three clusters that lack it, rather
  than replacing them.
* `VoiceAssistant` stays the one widget-facing object (in `view` form);
  `main.dart` keeps a single instance. The split is internal.

## 7. One-paragraph answer

The core *is* already device-free testable — but the testable unit is today
"the whole orchestrator", and the two inline turn loops plus the loose
hide/resume and reattach fields are where behavior changes still cost the
most verification effort. Extract the turn loop into an object (`BridgeTurn`),
give the lifecycle and reattach clusters the same named-transition treatment
`TurnCoordinator` got, and — the part that abstracts the phone away for the
UI — add an immutable projected `AssistantView` so widgets render a data
structure instead of pulling a dozen getters off the live machine. Then
interrupt/queue/detach changes are verified by effect-stream and view-golden
tests in milliseconds, UI changes are verified against hand-built views, and
the simulator is reserved for the audio route, the mic and Tailscale — the
three things no fake can honestly stand in for.
