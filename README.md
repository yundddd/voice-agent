# Voice Agent

On-device voice assistant prototype in Flutter: you speak, the app transcribes
your speech **on-device**, and speaks the transcription back — the full
speech-to-text → text → speech-to-text round trip runs with no network.

That "future gateway" now exists for the desktop Claude Code harness (see
"Claude Code bridge" below): one tap or one spoken command, the harness on
your machine does the thinking, and the answer comes back spoken in your
chosen voice. Both speech models still stay on the phone.

## Research: which on-device models?

Constraint: two models (ASR + TTS) must run on Android **and** iOS phones,
offline, with reasonable latency and footprint.

The stack chosen here is **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
+ its [Flutter plugin](https://pub.dev/packages/sherpa_onnx)** — one Dart FFI
API for both models, onnxruntime bundled per platform (apk/aar splits and an
xcframework for iOS), actively maintained (v1.13.x), MIT licensed. Main
alternatives considered:

| Area | Candidates | Verdict |
|---|---|---|
| Runtime | **sherpa-onnx**; whisper.cpp (+FfiWhisper/whisper_plus); ML Kit (Android STT / iOS Speech — partly server-backed); Vosk (aging, weak TTS story); Picovoice/Cobalt (commercial licensing) | sherpa-onnx covers ASR **and** TTS **and** VAD from one plugin, ONNX-wide model zoo, no licensing issues |
| ASR (English) | **Whisper tiny.en** (~100 MB int8 shipped here) and **Moonshine tiny/base.en** (28/106 MB tarballs, MIT, selectable in the picker); NeMo Parakeet TDT 0.6B v2/v3 int8 (~110 MB, best accuracy/latency trade-off, up to 25 EU languages for v3); zipformer transducers (true streaming, small variants); SenseVoice (zh/en/ja/ko/yue) | Whisper tiny.en stays the default: robust and simple. **Moonshine v2** is now offered next to it — same whole-clip decode, a third of the download, and 5× faster on the bench (19 ms vs 92 ms for a 3.8 s clip, x64 CPU). Moonshine's *streaming* graphs are NOT on the menu: sherpa-onnx declined them as too expensive to run (k2-fsa/sherpa-onnx#3558), so real-time behaviour still comes from the shared Silero gate, and a true partial-transcript path means a **streaming zipformer transducer**. Parakeet v2/v3 if accuracy matters more than size |
| ASR (multilingual) | **Qwen3-ASR 0.6B int8** (`qwen3-0.6b`, 804 MB, our own repacked zip — k2-fsa's tar.bz2 inflates whole in RAM and a gigabyte archive is where phones die); SenseVoice, FireRed ASR 2 CTC, zipformer bilingual still ahead | The family switch is one `switch` in `worker_backends.dart` over `ModelPaths.modelType`, plus the pack row; no other code knows which graph it loaded. Two Qwen3 specifics worth knowing: sherpa's default `maxNewTokens` of 128 truncates a long hold mid-sentence (the app raises it to 2048), and this family **opts out of long-clip chunking** — `ModelPaths.chunksLongClips` is false for it, because cutting its context cost 22.9% → 41.7% WER on an 88 s bench clip, whereas Whisper/Moonshine must still be cut to survive their own input windows. In normal use the chunker rarely fires for anyone: the endpointer already ends a hold at 20 s, under the 26 s decode-whole threshold |
| TTS | **Piper VITS** (`en_US-lessac-medium`, this prototype; `amy-low` also downloaded — swap by replacing the asset zip); Matcha-icefall (smaller/faster, phoneme lexicon, no espeak dir); Kokoro-82M (top quality at ≈334 MB fp32 — shipped as the 'Kokoro v1.0' voice; int8 quantization measured worse in both fidelity and CPU speed); MeloTTS (multilingual); **Pocket TTS** (Kyutai 100M zero-shot clone — shipped as a downloadable voice, sherpa-onnx support since v1.12.24); silero/supertonic (commercial license traps) | Piper medium is the quality/size sweet spot (61 MB model + 19 MB espeak-ng-data) and runs ~20–70× faster than real time on desktop CPU; expect real-time or better even on mid-range phones. Pocket TTS adds reference-voice cloning inside sherpa itself; Kokoro is the remaining upgrade path |
| VAD | **Silero VAD** (0.6 MB, bundled in the APK) | Wired in for conversation-mode endpointing (1 s pause = stop) and barge-in detection. Tuned to `threshold 0.35 / minSpeechDuration 0.15`: Silero only raises after speech sustains past the threshold, and sherpa rewinds segment starts by `minSpeechDuration + 2 windows` (`voice-activity-detector.cc`), so a lower threshold raises earlier and the rewind fully covers the attack — no clipped beginnings (`tool/onset_probe.dart` checks exactly this). `minSilenceDuration` remains the endpointing knob |

Measured on this dev machine (Intel, 4 threads, debug FFI — phones will be slower but still far under real-time):

```
ASR: 6.6 s of speech → text in 150 ms   (RTF ≈ 0.02)
TTS: text → 5.1 s audio in 111 ms       (RTF ≈ 0.02)
```

APK footprint: the two model packs (~60 MB ASR + ~64 MB TTS zips) are **not**
in the APK — the app downloads them from the project's GitHub release on first
run and unpacks them once into app-support storage
(`lib/src/models/model_packs.dart`).
That download path is already the CDN seam: pointing `modelPacks` at the
gateway later is a two-line change. Only the 0.6 MB VAD model is bundled.
## App structure

```
lib/
  main.dart             Entry point: bindings, theme, home screen
  src/assistant/        The conversation state machine and its parts:
    assistant.dart        The orchestrator — wiring, intents, lifecycle folding
    turn_session.dart     The bridge-turn truth: busy slot, badge, snapshots,
                          generation/seq ownership, the interrupt policy table
    bridge_turn.dart      THE harness event loop (/talk, control, /attach
                          replay are origins of it): ledger, receipts, teardown
    hide_resume.dart      Background→foreground: double-hide guard, cut-
                          paragraph skip, unheard-say resume promise
    reattach_chain.dart   The retry ladder for a view that died mid-turn
    activity.dart         The status line as DATA (prose rendered at the edge)
    view.dart             AssistantView: the screen as one immutable snapshot —
                          the UI layer renders THIS, never the live machine
    chat_store.dart       The conversation log, its pins, persistence
    token_ticker.dart     Rate-learned live counter (spinner line)
    narration_gate.dart   Step-narration quiet/heartbeat rules
    hop_tracker.dart      The latency strip's flow pulses
    ptt_hold.dart         Push-to-talk pointer/slide geometry
    mic_pipeline.dart     Capture, watchdog, reopens (behind MicSource)
    reply_pipeline.dart   Streamed chunk playback (behind AudioOutput)
  src/bridge/           Harness gateway, SSE protocol, push/poll transport,
                        the quiet-wire lease, wording rules
  src/speech/           The worker isolate owning both models (FFI calls
                        never touch the UI isolate)
  src/audio/            Mic front end (high-pass, noise floor, speech gate,
                        denoise) + PCM16↔float32 and WAV encode/decode
  src/models/           Model file locations (injected → testable);
                        downloaded zips → app support dir (first run only)
  src/journal/          Phone-side event journal (desktop triage)
  src/ui/               Screens and widgets — pure render of AssistantView
                        (talk_surface.dart: the whole bottom panel is the
                        PTT button — press-anywhere, touch-seeded ripples
                        scaled by mic amplitude, wide UP=interrupt and
                        RIGHT=discard bands; prompt_bar.dart: typed sends
                        with the queue/interrupt buttons)
test/turn_flow_test.dart  The whole orchestrator on scripted fakes: every
                        field-report regression (interrupt, queue, detach,
                        reattach, ledger) pinned at VM speed, no simulator
test/bridge_turn_test.dart  The turn loop itself, driven with no orchestrator
test/reattach_chain_test.dart  The retry ladder on a fake clock
test/hide_resume_test.dart     The pause/resume transitions
test/assistant_view_test.dart  Behavior observed as VIEW DIFFERENCES
test/ui_widgets_test.dart      Widgets rendered from hand-built views
tool/                         claude_bridge.mjs + bridge_stub_claude.mjs +
                              bridge_queue_test.mjs (the wire suite, node --test)
```

### Signal pre-processing (why it doesn't hear itself, and survives noise)

Every mic window goes through a small DSP chain in the worker isolate
(`audio_dsp.dart` + the state machine in `speech_worker.dart`) **before**
Silero ever sees it:

1. **High-pass (120 Hz, RBJ biquad)** — kills handling rumble, desk
   vibration and AGC DC before they can waste VAD/Whisper bandwidth.
2. **Noise floor tracker** — min-statistics over frame RMS: instant drop,
   ~0.6 dB/s rise, so the estimate always sits at the true room floor
   (speech has syllable gaps; continuous noise of any kind is absorbed).
   The floor is *pinned* while an utterance or our own reply is active, so
   neither the user's loud frames nor TTS echo can lift the baseline that
   the next utterance is measured against.
3. **SNR speech gate** (`SpeechGate`) — Silero alone can't tell a door slam
   or our own speaker bleed from the user's voice (they all score as
   "speech"), and it's the raw VAD threshold that used to be the
   false-interrupt dial. The threshold stays low (0.35 — raises early so
   sherpa's onset rewind preserves word attacks, see below) and the gate is
   the *trust* dial: a new utterance starts only when Silero **and**
   `frame ≥ floor + 8 dB` (and ≥ −55 dBFS absolute) agree for 160 ms.
   Concretely:
   - *No self-interruption:* while the app speaks, `setPlaying(true)` raises
     the bar to +14 dB over the floor, and for the reply's first 500 ms the
     bar is +30 dB — Android's AEC is effectively deaf during its lock-in,
     so no barge-in can trigger on that leak. A muted/ended reply keeps the
     warm-up window armed for its echo re-lock transient too.
   - *Noise, not cut-offs:* endpointing is still pure silence timing
     (minSilenceDuration = 1 s) — a burst that fails the gate simply never
     starts an utterance, so noise can't cut the user off mid-sentence.
   - *Segment duty cycle:* a delivered segment must have had ≥35 %
     gate-loud frames during it; clatter and echo residue score as speech
     to Silero but sit near the floor, so their duty collapses and the
     segment is discarded (the worker reports `segment dropped: duty …`).
   Gate telemetry (`level/floor/pass/streak`, and drop reasons) surfaces as
   `[worker] …` lines in logcat every ~3 s for field debugging.
4. **Push to talk** gets the same high-pass plus an offline frame gate
   (`denoiseClip`) applied *after* the user finished — quiet fill between
   words gets −30 dB, onsets are never clipped. The debug replay button now
   plays back exactly what Whisper actually received.

### Interaction modes

- **Conversation (default).** The mic runs continuously; Silero VAD (0.6 MB,
  bundled in the APK) watches for speech. An utterance is endpointed after
  ~1 s of silence (`minSilenceDuration` in `speech_worker.dart` — tune there)
  and answered. Starting to talk while the assistant speaks **mutes the TTS
  immediately** (barge-in) — since +318 that mute is a *quick fade*: the
  syllable on air rides a ~75 ms volume ramp down before the player stops
  (tab-swipe cuts ride it too), so cuts end gracefully while every cut law
  stands: the epoch ticks before the first await, the player is stopped at
  the bottom, the next speaker owns it at once, and the lane climbs back
  to full volume before the next chunk is handed over (a ramp never
  leaves a silent speaker behind — the +118 signature).
  The recorder uses the voice-communication source
  with platform AEC/AGC so the mic hears the user over the speaker; a
  word-overlap guard drops segments that are just the assistant hearing its
  own reply. Short breaths get a "say a bit more" nudge instead of a turn.
  A watchdog reopens the mic automatically if Android ends the capture
  session (our own media playback can trigger that), so the session
  self-heals within seconds.
  Backgrounding the app **pauses the conversation** (mic released); a local
  echo turn is abandoned, but a **bridge turn keeps running while hidden** —
  the harness is still answering, every say streams into the chat log (no
  synth, no audio), and returning to the foreground **speaks the newest
  reply** then reopens the mic as the user left it. If says are still
  arriving at that moment the stream simply becomes audible from there on.
- **Push to talk.** Tap to start, tap to stop and send — the original
  behavior. Switchable at the top of the screen; both modes share the same
  worker, ASR and TTS path. On turn end (release / endpoint) the assistant
  plays a 100 ms silent tick through the player: Android's output route
  needs a moment to connect after the mic ran, and without the tick that
  warm-up eats the reply's first word (seen as Pocket TTS "truncation at
  the very beginning" in PTT only — the Settings preview, no active mic,
  stayed clean).
- **One declared audio lane (+317).** Over a Bluetooth speaker the FIRST
  reply used to change its own voice mid-sentence — telephone-thin for
  its first part, full for its second. The synthesized bytes rule the TTS
  out (every chunk is the same mono 24 kHz PCM; engine warm-up is
  documented latency-only); the mic explains it: the voice-communication
  capture puts Android in call mode, which on Bluetooth means the mono
  SCO codec, while the reply played as an UNDECLARED media stream — so
  audioserver flipped the still-playing first utterance to A2DP
  mid-sentence. The output now declares its lane once, before its first
  source ever reaches the player: `usage=VOICE_COMMUNICATION,
  content=SPEECH` — the mic's own lane. (The field's honest note: the
  declaration alone did NOT end the switch for the first reply of a
  launch — Android holds the call route open for seconds after the mic
  dies, and the first reply starts inside that window; +319 below closes
  the window by leaving call mode at mic close. Second chunk of the same
  reply proved the declared stream sounds full-quality the moment call
  mode is gone.) The declaration rides the launch
  silent warm-up (the one play guaranteed to run before any mic
  session), which is where its own route-attach cost lands — the output
  twin of the mic's byte-counted warm-up drop, and traceable the same
  way: the journal gets an `audio lane: playback declared …` line. If a
  device's call lane sticks (the +118 signature — full-duration plays
  under a silent speaker), the declaration fails open to the plugin
  default and gets re-asked next play.
- **Leave call mode at mic close (+319).** The +317 tape still caught
  the FIRST reply after a launch starting thin and going full mid-
  sentence (and waiting ten seconds before the first press did not
  hide it: everything on the headset's call line is slow exactly once
  per session, and the first reply is the first audio it ever carried).
  So the app no longer waits for Android to expire the line on its own:
  at every full mic close — the `onClosed` hook that fires only once
  the recorder's own stop has returned, never by the pre-start stop in
  `open()` — the output writes its global audio context with
  `audioMode=normal` (the plugin's one door to `AudioManager.mode`, no
  bespoke Kotlin needed) and lays ~0.4 s of silence through the same
  player so the line's release happens against nothing instead of
  against the first word. The hold no-ops while a reply is on air or
  still queued (the mode-switch case lets the narrator survive the mic
  closing; a hole punched mid-sentence would be worse than the old
  quiet switch), a refused release is swallowed (the line expires on
  its own, the pre-+319 world), and the journal carries an `audio hold:
  left call mode` line — traceable, per the drop law.

### Voices & voice cloning

The voice icon (top right) opens the voice screen (`lib/src/ui/voice_screen.dart`):

- **Standard voices.** Five Piper VITS voices — Lessac (default), Ryan,
  Amy, Alba, and LibriTTS-R (a slider picks any of its 60 reader styles),
  taken from the k2-fsa sherpa-onnx releases. Downloads are **lazy**:
  nothing lands on disk until the user selects that voice, and any
  downloaded voice can be **deleted** again (trash icon; the voice in use
  is protected — re-selecting simply re-downloads). The worker isolate
  hot-swaps its TTS engine to match (`TtsSpec` + `useTts` job in
  `speech_worker.dart`); the chosen voice and speaker id persist in
  `models/tts_prefs.json`. A headphones button previews any loaded voice.
- **Kokoro v1.0** (82M, fp32). The best-sounding reader in the app: a
  StyleTTS2-lineage one-pass renderer (no neural codec in the path, no
  autoregressive cold start — the first syllable is as clean as the last,
  which the pocket port cannot claim). 54 built-in speaker styles once
  loaded, named and grouped in a searchable roster sheet (tap to switch,
  ▶ to audition a style without switching — the sid rides the synth job,
  no engine rebuild; the roster table lives in `kokoro_voices.dart`),
  American + British English; RTF ~0.10 on desktop
  CPU at 4 threads. Fetched straight from the k2-fsa tts-models release
  (334 MB download, fp32 deliberately: our A/B measured the int8 pack
  audible-muted *and* 4× slower — `tool/kokoro_ab.dart`). Chinese-capable
  in-model but not wired: the Dart binding drops `dictDir`.
- **Clone my voice** (ZipVoice). Record one clear sentence (2–20 s, live
  timer; the mic is handed to the recorder and any running conversation
  resumes when done). On-device Whisper writes the transcript — ZipVoice
  speaks the reference *transcript*, so the UI lets you fix a mis-heard
  word before applying. The cloning engine (ZipVoice distill int8 + the
  Vocos vocoder, ~155 MB total) downloads on first use only. "Use my
  voice" switches all replies to the clone; the preview button speaks a
  test line. Cloned replies are noticeably slower to generate than the
  stock voices (RTF ≈0.2 measured on desktop, so expect replies to take
  a second or two more on the phone). Backgrounding during recording
  cancels the sample; the recording and delete buttons free the disk.
- **NeuTTS Nano** (Neuphonic). A speech-token neural codec voice, running
  through a *second native stack*: `neutts/bridge/` is a small Rust crate
  (C FFI, built by `tool/build_neutts_pack.sh`) over the MIT `neutts`
  crate — a llama.cpp GGUF backbone (Q4), a pure-Rust NeuCodec decoder,
  and a bundled-espeak phonemizer, so inference is self-contained next to
  sherpa-onnx, on the same worker isolate. The bridge `.so`, the GGUF, the
  converted decoder weights and the preset voices all ride **inside the
  voice pack** (zero APK weight, ~520 MB downloaded); four preset reference
  styles (Greta/Jo/Mateo/Juliette — the MIT-licensed reference samples of
  the Rust port) are selected with the same speaker slider used by
  LibriTTS-R. The sampler seed is pinned (upstream re-rolls it per call),
  which keeps each voice's character stable between replies. Android
  (arm64) only: iOS needs a `.xcframework` build of the same crate, and
  user-voice cloning is pending the pure-Rust NeuCodec *encoder* (the
  Rust port still defers reference encoding to Python). Upstream model
  repos are gated on Hugging Face (one-time terms click + login), so the
  pack is mirrored to our GitHub release by the script above — the app
  itself only ever downloads anonymously. The reply audio is 24 kHz;
  expect ~45 tok/s (RTF ≈1) on a mid-range phone (measured RTF 0.9-1.3
  on desktop x86; the Q8_0 backbone measured no better, so Q4 ships).
- **Pocket TTS** (Kyutai). A 100M-parameter zero-shot cloning model that
  runs *inside the existing sherpa-onnx engine* (PocketTTS support since
  v1.12.24) — no second native stack this time: the voice pack is plain
  model data, so the whole APK weight of the feature is one catalogue row.
  `tool/build_pocket_pack.sh` mirrors the public k2-fsa ONNX export of
  `kyutai/pocket-tts` (the HF repo itself is gated behind a terms click —
  one-time, login + acknowledge on the model page; the export is not) and
  six reference wavs from the ungated `kyutai/tts-voices` repo (Jane,
  Anna, Jean, Michael, Alba, Bill Boerst — CC-BY-4.0), zipped with a
  `pack-v2.ok` sentinel and uploaded to our GitHub release; the app
  again only ever downloads anonymously. v1 shipped the int8-quantized
  export at ~105 MB; v2 switched the LM/flow/decoder to the fp32 graphs:
  band forensics showed both variants hit the same ~10 kHz Mimi-codec
  ceiling (quantization bought no bandwidth), but the fp32 renders won
  the listening test and the head-drop rate improved — the cost is the
  download (~205 MB zip vs ~105 MB) and ~1.6x desktop CPU; the round-trip bench
  below measures the honest per-device numbers. Sentinel bumps are how
  the app re-downloads in place; the unpacker wipes the old directory
  first so orphaned graphs can't squat (`model_unpack.dart`).
  Like the NeuTTS presets, the six
  voices ride the speaker slider (`useTts` returns the reference count);
  the native layer resamples each reference to 24 kHz and caps it at 10 s,
  so presets of any upstream rate are fine. Output is 24 kHz, generated
  with 2 flow steps (the decoder ships one-step distilled). Cloning your
  own voice through this engine only needs the wav — no transcript — so
  wiring the record UI to a pocket spec is a small follow-up.
One port caveat to know before judging a recording: the k2-fsa ONNX
  export cold-starts differently from the PyTorch reference (sherpa's NaN
  initial latent maps to zeros, and the voice prompt is fed without the
  learned BOS embedding that `insert_bos_before_voice` prescribes — see
  kyutai's `flow_lm.py::VoicePrompt`). Worse, the single pooled voice
  embedding loses the prompt's trailing-pause state, so the port starts
  speaking ~0.4 s earlier than the reference — inside its own
  growl-corrupted first frames. The reference emits a clean ~0.5 s
  silence pre-roll before the first word; the export emits a low growl
  that swallows the attack, and the first words read as truncated
  (identically in PTT, conversation mode, and debug replay — proving the
  damage is in the *content*, not the playback path). Worked around in
  `SpeechWorker` (pocket arm, validated by whisper-tiny re-transcription
  of all six presets): every Generate call's text gets a `'.... '` prefix
  so the model *itself* opens with a generated pause (kyutai's own FAQ,
  issue #6) — plus `silenceScale: 1.0`, because the Dart default 0.2
  would squash that pause; `mergePocketChunks` (runt pieces misbehave — a
  one-word answer decodes to '[sound]', and a missed EOS babble-decoded
  40 s on michael — and every extra Generate call re-pays this whole
  ritual, so pieces now merge up to ~340 chars: a typical long answer is
  ONE call whose internal sentence pauses come from the model's own
  punctuation instead of our splice points. The per-piece
  `max_frames` cap scales with the merged size (a runaway EOS
  self-limits there, and no call truncates mid-word);
  `pocketLeadIn` (drop the first 250 ms — the growl now
  dies inside the pause; 30 ms fade so the splice adds no click; 300 ms
  inserted silence so the phone's post-capture output ramp — ~150 ms,
  plus mic-teardown mute — lands in silence too, with the
  model-generated pause behind it carrying the protection). The assistant
  additionally holds the output route open with inaudible silence from
  turn end until the first chunk (insurance for the same ramp; helps
  every engine). First phrase then lands intact in re-transcription on
  every measured draw (10/10 heads; RTF unchanged at ~0.11). If kyutai or
  k2-fsa fix the export, these workarounds retire one function at a time;
  the official renders under `ref6_*.wav` make the A/B audition trivial.

### Session tabs (first launch, swipes, and the seat)

The bridge seats ONE conversation at a time; the app keeps a LEDGER of
seats — tabs — and moves the seat between them. On FIRST launch (fresh
install, configured bridge) the app asks, before any session exists,
three questions in a big-button sheet: which harness answers (Claude
Code / Opencode), which model (the harness's real menu — `GET
/models?harness=&dir=` reads the menu of a seat the bridge is not on,
"Default" when you would not choose — a two-provider
catalog FOLDS under provider shelves so it never floods the screen),
and which working folder: a `GET /dirs` BROWSER, not a list of
confirm buttons — rows ENTER folders, the absolute path you stand on
is spelled out, and one SELECT button up top files it (Up walks back;
"Current" is not pre-picked, the question deserves an answer). The
whole sheet SCROLLS under a capped height. One `POST /seat`
then creates the session and the tab it lives in.
Navigation is horizontal: a **left-swipe** on the channel jumps to the
NEWER tab, a **right-swipe** to the OLDER one, and when the first tab
is all you have — the state first-launch leaves you in — the
right-swipe IS the creation sheet. The pills live IN THE APP BAR —
they replaced the title and the fingerprint line: a horizontally
scrollable strip shares the row with the corner buttons (which never
scroll), the fixed `+` on its end is always in place, and every pill
wears an ✕ that FORGETS the tab (its thread leaves with it; the
active tab's relief onto its neighbour obeys the rest law; deleting
the last tab fires no verb at all). The conversation's fingerprint
rides the pill's tooltip. The gesture is not a cut: the thread rides
the finger while the drag is down (and lifts like a grabbed card,
while the NEXT session's own hue glows in from the edge being pulled
open — past the first tab that edge wears the + slot and says so),
and the commit SLIDES the old thread out against the swipe while the
new one slides in across it — each tab wears a barely-there gradient
tint of its own (a golden-angle hue behind the bubbles), so the
crossfade itself says "a different session is arriving". Refused
switches spring the thread back with not a swap. Each tab is `(harness,
folder, model, sessions…)` in `bridge_prefs.json`; switching calls
`POST /seat {"sessionId":…}` which resumes that exact conversation
(and rewrites the project's pointer, so a bridge restart wakes on the
tab that was seated last). The switch RESTS while a turn is open —
like the harness row — and the refusal says so. The `/new` chip now
REPLACES THE CURRENT TAB: same harness, model and folder (unless the
Bridge rows steered them meanwhile — those rows update the tab too),
a blank conversation, and only that tab's bubbles leave the log;
every other tab keeps its thread. Upgrades are not asked: the first
`/health` silently seeds the live seat as tab 1.
Bridges without `/seat` (no `seat: true` in `/health`) keep the
pre-tab single-thread behavior; the pills go inert there.

### Round-trip latency bench (voice screen)

The bottom card on the voice screen is a measurement rig for the model
pair you actually run: hold the circle, talk, release — the utterance is
transcribed by Whisper and spoken straight back by the *selected* TTS
voice through the same streamed playback path a real reply takes
(warm-up silence, temp-wav hand-off, per-chunk `play()` included), but
with the bridge skipped, so no LLM thinking time pollutes the numbers.
Every figure is clocked from the button release: `release→text` (ASR
cost on your device), `release→first audio` (the round-trip figure worth
optimising — the moment the player got the echo's first chunk),
`synth total (RTF)` for the whole sentence. Runs stay in a session-only
history so you can switch voices (Piper, Kokoro, Pocket int8/fp32…) and
compare rows side by side; the 20 s hold cap and the mic hand-off
identical to the clone recorder keep the bench from colliding with a
live conversation. The latencies that matter — route warm-up,
post-capture output ramp, streamed-chunk playback — are the same ones
the real turn pays, deliberately: the panel should match what your ears
hear in production, not a lab best case.
  

## Design: the harness turn lifecycle

One utterance becomes one harness turn, and the phone is allowed to stop
listening at any moment **without stopping the work**. Four states, named
the same in the bridge's `/health` and in the app's widgets:

- **HEARD** (`bridgeBusy`): the turn's `/talk` response stream is open and
  carries every frame live. The spin box — wheel, activity line, token
  meter (`_HarnessSpinner`) — rides the live-turn bubble.
- **BACKGROUND** (`harnessBackgrounded`): any press cancels the phone's
  view; the bridge keeps the turn, relays every frame to its ring, and the
  appbar badge stays lit as the only proof the work exists. +72 made the
  *display* survive the detach; +91 made it survive the *queued press*
  too (the work bubble is the last ASSISTANT entry, `liveTurnFor`, not
  the literal last entry — the pin rides the card below, out of the flow).
- **QUEUED** (`pending`): one pin at a time, latest wins. The pin dissolves
  only on the bridge's explicit `started` frame, emitted at the real
  pickup (+81) — on the shared ring any older turn's frames would fake the
  pickup. A queued POST closes its own response at enqueue time by design
  (pull transport), and that close must NOT drop the prompt (+90) —
  flushPending's poll branch is its pickup, with the `started` marker
  relayed ahead of the turn's own frames.
- **SETTLED**: the `settled` tally frame means the text is final and only
  audio rendering remains; the wheel freezes and dims immediately (+84),
  rather than spinning until the socket closes. "Motion OR color, never
  neither" is the freeze honesty rule; pure playback hides the box, while
  a still-open turn keeps it live *through its own voice* (the answer can
  still be generating while the first sentence plays).

**Two transports, one truth.** Cellular paths coalesce server-pushed bytes
into silence (measured 8–14 s wire ages) while the phone's own outbound
requests land in milliseconds — so every relayed frame rides BOTH the live
SSE stream and a monotonic event ring (`GET /poll?since=cursor`, epoch-seeded
so cursors survive bridge restarts; `GET /attach` + backlog replay for
reattachment). The phone's cursor is its own reattach state; quiet-wire
watchdog (24 s) + padded heartbeat frames + 150 ms pings during an open turn
keep links and NAT tables honest.

**Both machines keep journals, mirrored into one stream.** The app writes a
seq-numbered lifecycle journal to disk and PUSHES it to the bridge (Android
tailscale accepts no dials, carrier NAT has no route); the bridge relays
each new entry to its stderr, so `journalctl -u claude-voice-bridge`
interleaves the phone's and the desktop's views of the same misbehaving
turn — every design claim above is field-verifiable from one command.
Per-turn `[census]` lines report what the upstream actually delivered
(live deltas / usage-only / none), and say frames are journalled by their
first forty chars, which is how "spoken twice" and "never spoken" get
told apart in the log.

**Regression discipline.** Every behavior rule in this section carries the
version tag of the field report that earned it. Fixes land as: reproduce
from the journals, extract the decision into a pure function
(`settleOwed`, `activityLabelFor`, `liveTurnFor`), unit-guard it
(`tool/sentence_relay.test.mjs`, `test/guards_test.dart` — one test per
field report), bump the `+N` in pubspec.yaml, and name the number in the
commit subject. The phone gets the new `+N` via Telegram (`--split-per-abi`
keeps the arm64 APK under the bot's 50 MB cap); the bridge updates with a
service restart.

## Queueing & interrupting: expected behaviour, and how it is driven in the simulator

What the two composer buttons owe the user, stated as contracts (each was
a field report; the wire flags are `?interrupt=`, `?cuttool=1`, `?poll=1`):

- **Queue over a thinking turn** (`interrupt=0`): the message pins at the
  bottom of the channel ("Queued — waiting for the current work") and the
  turn is left to settle. The pin dissolves **only** at the bridge's
  `started` pickup marker — never at a foreign turn's `done`, and never at
  the `queued` notice, which is the *opposite* promise (+81, +131). The
  parked pump must survive that farewell `done`: on the shared ring cursor
  it arrives ahead of the marker, and a pump that ends there fossilises
  the pin forever (the bash-sleep report — the journal line
  `poll: done of the PRIOR turn swallowed pre-pickup` is the fix proving
  itself). A superseded press retires its own pin: the bridge's pending
  slot is latest-wins, and a replaced prompt never gets a `started` to
  dissolve it.
- **Queue over a running tool** (`cuttool=1`, the Queue button): polite
  towards thinking is not polite towards builds — the moment the agent is
  chewing on a tool call, a queue press **backgrounds it** and the agent
  answers now. The bridge relays the disposition twice (enqueue notice and
  a re-announce at flush — any single copy is losable to a dying turn's
  pump), tags the pickup marker `kind='background'`, files the cut call
  in a `detached` map, and when the late `tool_result` lands it speaks a
  `finished` frame naming the step — that receipt, not the pickup, is
  what retires the banner; the phone files a `“Bash sleep 10 finished.”`
  bubble at the same moment (behaviours 2/4, +131). `/health` exposes
  `detached` so the count's own 0→1→0 trail is externally checkable, and
  a /health sweep finding nothing open and nothing detached retires the
  banner even if the tool's receipt never arrives (a harness that killed
  the tool with the turn owes nothing).
- **Interrupt** (default `interrupt=1`, and every voice barge-in): the
  turn is cut in-band with a `control_request interrupt` — thinking and
  in-flight tools alike. The cut turn's `done` is *suppressed* (+106: the
  phone cut it itself; a stray done landing on the fresh bubble births a
  dead turn), its bubble keeps the ✋ `interrupted` stamp and whatever was
  heard, and the new prompt's flush carries the same `kind='background'`
  promise as a queued cut.
- **The agent can background a shell itself** (+133): a Bash tool_use
  carrying `run_in_background` closes its tool with a *start receipt*,
  and the bridge tracks the debt — `/health.detached` counts it, so the
  banner's safety net keeps the bottom line naming the step. When the
  CLI later finishes the shell it speaks UNPROMPTED: a proactive report
  turn the bridge opens as a background turn (a fresh `/talk` queues
  politely behind it; `/stop` can cut it). The moment the report reads
  the task's output file, the relayed `tool finished` receipt names the
  step, the model's answer rides as ordinary `say` frames, and the turn
  closes with `done` like anything else. A phone that is idle when this
  happens hears it via the banner's heartbeat: while the line is lit,
  `/health` is consulted (4 s first, then 10 s) and a live report wakes
  the existing reattach chain — the same age rules decide whether the
  replay is spoken or filed silently; an even later phone finds the
  receipts on the ring at its next turn (the pre-marker window files
  them into the conversation, not into the fresh bubble).
- **Push-to-talk defers its verdict to the release** (+132): pressing
  over a live turn takes the EAR (the mic must open now) but stamps
  NOTHING — at press time the gesture has decided nothing. The release
  settles it: slide-up cuts (and files the trace it deferred), a
  motionless quick tap is the mid-turn hard stop (stamped too), a plain
  release queues politely (tool to background, no trace), and a
  slide-right dismiss leaves no trace at all — the tool call the user
  only walked away from keeps running. A release that merely DRIFTED
  (past touch slop, short of a slide threshold) is a half-changed mind,
  never the old tap-Stop: cancelling is not stopping.
- **A press behind already-detached work shows in the flow** (+126): the
  pin protects an answer the *ear* is holding; behind unheard work the
  badge and the bottom line already carry the wait, so the message rides
  the conversation immediately and dissolves nothing. The banner's
  warrants are exactly three — badge, pin, cut-tool promise — and every
  dismissal path clears one of them, so the line vanishing *is* the proof.
- **No duplicate bubbles.** Poll cursor hygiene at hand-offs (the cursor
  advances with what the pump *consumed*, not what the wire held; a
  push→pull flip catches the cursor up to the ring head), the flush
  re-announce lands on the system note's adjacency guard, and the
  heard-ledger (written at first audio chunk, retracted if the wire died
  before air) dedups every replay (+109…+116).

**Driving it in the emulator (what works, what bites):**

```bash
emulator -avd Pixel_8_API_35 -no-window -no-audio -no-boot-anim &   # headless
adb install -r build/app/outputs/flutter-apk/app-debug.apk
# seed bridge prefs where the app actually reads them — INSIDE the models dir:
adb push prefs.json /data/local/tmp/bridge_prefs.json
adb shell run-as com.voiceagent.voice_agent \
    sh -c 'mkdir -p files/models && cp /data/local/tmp/bridge_prefs.json files/models/'
```

- The stub harness (`--claude tool/bridge_stub_claude.mjs`) makes every
  scenario clock-deterministic: `STUB_RESULT_MS` pins the turn length,
  `STUB_TOOL`/`STUB_TOOL_START_MS` open a Bash step mid-turn,
  `STUB_TOOL_DONE_MS` makes that tool SURVIVE a cut and report `finished`
  N seconds later. `STUB_TOOL_BG=1` adds the +133 story: the launch
  answers with a start receipt, and `STUB_BG_DONE_MS` later an UNPROMPTED
  report turn (Read of the task output, `STUB_BG_SAYS`, closing `result`)
  walks in — `STUB_BG_BEAT_MS` stretches the window the phone must wake
  inside. The real bridge + real claude participate the same way
  with `sleep 10` as the tool; the stub exists so the *timing*, not the
  model, is what the test controls.
- Ground truth is the files, not the pixels: `prompts.log` (`STUB_LOG`)
  answers "did the harness get it"; the bridge-relayed journal answers
  "what did the phone believe and when" (`curl '/applogs?token=…&since=N'`
  or the bridge stderr `[app` lines) — but pushes arrive batched (~30 s),
  so reading the journal immediately after a press shows yesterday.
  `/health`'s `queued` is likewise a millisecond-wide window on a cut
  flush (the prompt parks and flushes in the same round trip) — a false
  there on a Queue press is EXPECTED, check the marker in the journal.
- `uiautomator dump` cannot settle while any spinner ticks (the elapsed
  counter repaints every second), which is exactly when you want a dump.
  Work around it: screenshots (`adb exec-out screencap -p`) always work;
  calibrate tap coordinates ONCE while idle and cache them; the composer
  row is at its dumped bounds in every state with at least one bubble on
  screen (empty-chat and IME-open screens float the layout ~250 px higher
  — re-dump after the first send, not before).
- Screenshots are 1080-px wide and display scaled: read tap coordinates
  from the uiautomator XML, never from the picture.
- Keep the stock companions pacified or they steal focus at the worst
  moment: `pm disable-user --user 0 com.google.android.apps.photos
  com.google.android.gm`, and note that snapshot restores can undo it.
  `show_ime_with_hard_keyboard=0` matters: with the IME shown, the
  driver's `keyevent 4` (IME close) becomes an app-exit, and taps land on
  a layout the calibration never saw.
- Force-stop between scenarios and delete `files/models/chat_log.json`
  for a clean channel; an unfinished control-chip turn (`/compact`)
  restores as a spinning zombie and poisons both dumps and banner
  assertions. And a fresh boot may re-send a pending chip command by
  itself — one unexplained `/compact` in `prompts.log` on a wiped start is
  this, not a bug in the queue.

The regression net stays three-deep on purpose: node drives the real
bridge over HTTP (`tool/bridge_queue_test.mjs` — every wire contract
above, incl. the marker surviving beginTurn's backlog wipe), Dart drives
the state machine against scripted ring pages
(`test/turn_flow_test.dart` — pin, armor, banner, receipts;
`test/turn_session_test.dart` — the coordinator's transition matrix),
and the emulator above is only for what no fake can prove: that the
compositor, the IME and the notification shade leave the promises above
visible where they belong.

## Claude Code bridge

The app can put the desktop's Claude Code harness between its ASR and TTS:
speak (or tap a chip), the text goes over the LAN/tailnet to a tiny bridge
process next to the harness, and the harness's answer is streamed back and
spoken with the app's selected voice. Start the bridge on the machine that
runs claude (Node, zero dependencies):

```bash
node tool/claude_bridge.mjs --dir ~/voice-agent --token SOMETHING_SECRET
# optional: --claude ~/.local/bin/claude --port 8732
```

In the app: terminal icon → set `http://<machine>:8732` (tailscale IPs
work too) + the token → Save & check. Two session-control chips then
appear above the mic button — `/new` (bridge reset endpoint: forgets the
persisted session so the harness starts blank) and `/compact` (sent as
plain-string content, which the CLI executes natively — it condenses the
transcript into a summary; the bridge relays the resulting
`compact_boundary` as live progress and the app speaks a confirmation
when the turn stays silent) — plus "Stop" while a turn is in flight
(barge-in interrupts the harness turn in-band via the CLI's control
protocol — the conversation AND the process survive, so no `--resume`
re-prefill; verified). The old canned-command chips (*Repo status, Run tests, Build
APK, Catch me up*) are gone: a harness you can converse with takes dictation
better than scripts. The Bridge screen also has a free-text box so
*anything* you type goes to the harness and comes back spoken — a line
starting with `/` executes as a real Claude Code command (`/context`,
`/usage`, ...) — and a restart button for a fresh conversation. **The voice toggle:** the "Speak to Claude Code"
switch (on from the factory, persisted in `bridge_prefs.json`) routes
whatever you say in push-to-talk or conversation mode to the harness
instead of repeating it back — say "what still has uncommitted changes?"
and Claude Code runs the git commands and answers in your assistant
voice. **Eyes-only mode** (0.1.0+131): the "Speak replies (TTS)"
switch on the Bridge screen — and the mute chip at the end of the
composer row (`TTS off — tap to speak replies`) — turns synthesis off
entirely: harness answers land as chat text, nothing is spoken, and the
send gate stops demanding the audio worker, so a phone with the speech
models still downloading (or a seatbelt-demo with no earbuds) takes
dictation and shows transcripts. In this mode the chat composer — the
`Type to the harness…` field with its two send icons (Queue = polite,
cuttool; Interrupt = cut) — is a full keyboard path into the harness:
text in, text out, no microphone anywhere in the loop. While a harness
turn runs, push-to-talk steers by RELEASE
GESTURE (0.1.0+25, refined by +132): the in-flight bubble carries a Claude Code-style
progress line — the braille spinner wheel (⠋⠙⠹⠸⠼…), the live status
(tool activity included), an elapsed-seconds counter (`HarnessSpinner`,
`lib/src/ui/harness_spinner.dart`) — and while the model generates, that
status shows a
live token tally ("thinking · 1.2k out · 48k in", exact at every
message boundary, ~4 chars/token in between; `--include-partial-messages`
stream_event deltas in `claude_bridge.mjs`). A context bar above the
button shows conversation consumption vs the model's window (`context`
SSE events + the `/health` snapshot, `ContextBar` in
`lib/src/ui/context_bar.dart`) —
the same numbers Claude Code's /context prints. And since context that
misses the prefix cache re-prefills at a measured ~7-8k tok/s — every
byte over the cache boundary is ~1 ms of dead air even for "hello" —
that number IS your latency; context size doubles the seconds, triples
the cost. It no longer re-prefills wholesale, though: the per-turn miss
turned out to be the CLI's experimental betas re-rendering a history
envelope ~1.5k tokens into an otherwise byte-stable request (captured
bodies + replays: pinned envelope 15k re-prefill → 64-token top-up,
1.13 s → 0.20 s), so the bridge spawns the CLI with
`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` and a warm chat now pays
only the new tail. What the bar still prices honestly: the first turn
of a session (full prefill), turns after a second tenant flushed the
cache's few mamba prefix branches, and every turn as history grows —
so the bridge does not force `/compact` on you: watch the bar, and use
the /new and /compact chips when *you* decide
the conversation has grown heavy enough. A fresh hold *anytime* during that turn detaches
it (the tool call goes to background and finishes its work unheard,
output dropped) and opens the mic right there. Release in place and
your words are QUEUED politely: the turn in flight finishes first,
then yours goes next; slide UP cuts in-band so your prompt starts in a
heartbeat (0.1.0+132: a running tool is cut into background with the
turn and owes its `finished` receipt like any other); slide RIGHT
throws the recording away unsent — the detached work is left completely
alone; and a motionless quick tap remains the hard stop: detach +
`/stop`, the old "Stop the harness". (A release that merely drifted —
past touch slop but short of a slide — is a mind half-changed, not a
tap, and stops nothing.)
The terminal-icon badge stays lit while a detached turn keeps working
unheard. In conversation mode the mic button likewise keeps working
mid-turn. `say` events are
synthesised sentence-stream through the same chunked player voice replies
use, and everything the harness answers runs past `cleanForSpeech` first
(a bullet list would otherwise be *spoken*; markdown/emoji are stripped).
Backgrounding a turn does not cancel it: every answer streams into the
chat log unseen and the newest one is spoken when you switch back.
**Barge-in backgrounds too** (0.1.0+20): speaking over a running harness
turn DETACHES the phone from it — the bridge turns it into a *background*
turn (the harness finishes its work in peace; its frames ride the ring,
nothing is dropped, and the late `finished` receipts say so)
— and your new words go out seconds later as a fresh turn, QUEUED behind
an open tool call or ahead of a cut-short thinking turn (the bridge cuts
pure-thinking turns at queue time with an in-band interrupt — the process
never dies, so the warm prefix cache keeps working — when the takeover wants to be heard —
`interrupt=1`, the default for spoken barge-in and PTT slide-up; PTT's
plain release passes `interrupt=0` and the queue waits politely, while
slide-right sends nothing at all (+132); in either
flavour a new prompt goes next even while a tool-free answer was
mid-air). Tapping Stop is the hard
flavour: same detach plus a `/stop` so the harness quits working too.
Smoke-tested end-to-end against a stubbed `claude` child
(`tool/bridge_queue_test.mjs`): queue-press-mid-tool backgrounds the tool
and answers immediately (the receipt lands when the tool does);
detach-mid-thinking interrupts and
answers inside ~1.5 s.
**Both sides of a turn are now on the record** (0.1.0+29): the app keeps a
seq-numbered *event journal* of its lifecycle story — raw hide/resume
callbacks with the flag snapshot each saw, every stream open and exactly
how it died, reattach probe verdicts, watchdog zombie hops, detaches —
mirrored to disk (`app_events.jsonl`: an Android kill can't erase the
evidence of its own death) and served over HTTP on the tailnet. The
bridge learns where to dial from the app's own requests and polls the
journal every 5 s, relaying new lines into its stderr: one `journalctl
-u claude-voice-bridge` interleaves the phone's and the desktop's views
of the same misbehaving turn; a frozen or killed phone shows up as
"not answering" and its recovery timestamps bracket the freeze window.
`curl 'http://<bridge>:8732/applogs?token=…&since=0'` pulls the whole
phone journal live; the Bridge screen shows the poller's peer and
reachability via `/health`.
**"Is it thinking?" now has an always-honest answer** (0.1.0+30): every
turn opens with a `thinking` tally frame, so the spinner line leaves
"Asking the bridge…" within one round trip — and if the upstream streams
no partials, quiet heartbeat frames keep saying so in words while a
per-turn `[census]` line in the bridge's journal reports what the wire
actually delivered (live deltas / usage-only settles / no live events).
Which one you get is your proxy's choice; now you can read it instead
of wondering. The journal itself now PUSHES (0.1.0+32) — the Android
tailscale client accepts no dialed-in connections and carrier NAT has
no route at all, so the phone POSTs its journal outbound (batched,
acked, deduped by seq) and the bridge mirrors the latest envelope:
`/applogs` answers from the mirror with `source:'push'`, and
`appLog.mode` in `/health` reads push / pull / silent.
**The harness row (UI for +211's endpoint):** the Bridge screen shows
which harness the bridge currently speaks (from `/health`) and carries a
switch to the other one — each harness keeps its own conversation, so
flipping is a step sideways, and flipping back resumes. The switch
rests while a turn is open (a flip is an honest `/new` for whoever holds
the seat) and lies dead on pre-switch bridges.
**The cutter breathes with the prose (+222):** a sentence whose only
period sits at the very end used to hold ALL its advice for the
block-close flush — the tape's last bubble was literally 'garbage
collection.', one and a half seconds after its head. Now a clause
boundary (comma, semicolon, colon, dash — the places the prose marks
for itself) cuts on its own once the chunk is a breath's length
(20 chars), so 'If you want space back,' ships immediately and the
rest follows. Sentence ENDS keep the old 40 floor (an 'OK.' frame is
chop noise); commas under the breath floor never carve; the
word-char anchor still refuses to let 'main.dart:801' or '1,000' fake
a breath. Each relay is a synthesis of its own, so the floor is what
stands between grammatical politeness and a robotic stutter.
**Transient failure is progress, not silence (+221):** when the
harness's API call fails and it backs off — a claude `api_retry`
system frame or an opencode failed step — the phone gets a `retry`
tool step naming the status and the attempt ('429: rate limited ·
attempt 2/5 in 1200ms'); a blipped opencode event bus says `wire ·
reconnecting` (the replay + dedup belt makes the 'drop' lose nothing).
Under Narrate these are spoken; otherwise they rewrite the spinner
line, which beats a frozen counter through a rate-limit storm. The
QUIET heartbeat (no deltas from upstream) and the failed-turn card
(+220) close the spectrum: silent-but-alive, retrying, and refused
each say their own piece.
**The model picker (+216, +218):** the Bridge screen's Model row shows
the current model (from `/health`) and opens a menu (`GET /models`) —
claude's list is the operator's `--model(s)` config (the CLI has no
list control; verified against 2.1.296), opencode's is the service's
own catalog for the working directory. A pick is one POST (`/model`)
answered in whichever dialect: a `set_model` control frame to the CLI
(carried into respawns via `--model`, rolled back on a refused ack),
or the session-model API to the service (parked into session creation
if no session exists yet). Opencode's current goes PROVEN when a step
names its model. Bridges pre-+216 say so and the switch lies dead.
The sheet is HIERARCHICAL when the catalog earns it (`+218`): two or
more providers means you browse PROVIDERS first, models under the one
you tap — a checked shelf is the one holding the current model, a
back arrow retreats; a single-provider or claude menu stays flat (no
gratuitous hop). And the app REMEMBERS: every accepted pick is filed
in prefs per harness (`lastModels`), so after a bridge restart —
before claude re-spawns its `--model` or an opencode step names
itself — the row wears `'acme/beta (last used)'`, the sheet captions
`last used:` and marks the remembered model (and its provider shelf)
with a history glyph. One tap puts it back.
**The split transcript (+213):** every bubble now carries the harness
era it was born under, and the chat channel renders ONE THREAD — the
current harness's bubbles plus the un-era'd prologue (the offline demo,
history from before the split, or a bridge too old to name its era:
those show everywhere). The filter is render-side only: the log on disk
stays one append-only truth, so the heard-ledger, the reattach dedup
and the receipt-by-id law keep scanning everything — a task finished
under claude stays finished when opencode replays it. The flip itself
files no bubble (+215): the thread changing under your eyes is the
whole announcement; the signpost note explained what the screen
already showed and repeated itself every flip.
**The channel follows the conversation (+223):** every bubble also
carries its SESSION id now (the harness conversation it was born
under; the birth-turn carries a sentinel and adopts the name the
moment the harness speaks it, and the pre-law history migrated to the
session already in use — once, prefs-guarded). The window shows the
CURRENT session's thread plus the true prologue: move the working
folder and the chat clears to that project's own memory — and moving
back RESTORES the thread exactly, because nothing was ever deleted,
only filtered (render-side, like the era split). This required the
bridge's `/dir` to stop being an honest /new: switching folders now
LOADS the destination's remembered session (each project keeps its
own pointer file, per harness) and the next utterance RESUMES it —
`--resume` on the CLI side, the session id on the service's. Tap a
folder, pick up the conversation where you left it, weeks later.
**The migration (+214):** a pre-split log is all un-era'd, which the
split first reads as one giant prologue — the install-day complaint of
"still seeing the other harness's bubbles." The bridge now keeps an
ERA TIMELINE (`~/.claude_bridge_harness_history`, one line per boot
that found a different harness and per `/harness` flip, served in
`/health` as `harnessHistory`), and the phone's first era-naming
glance stamps every legacy bubble ONCE by its own birth timestamp
against that timeline — older than the record, or a bridge with none,
wears the era observed then. A prefs flag spends the migration so a
bubble legitimately born un-era'd later (true offline turns) is never
re-stamped by a returning guess.
**The bridge now has a second harness (+211):** `--harness opencode` (or
a runtime `POST /harness {"to":"opencode"}`, persisted so the trial
survives restarts) points the same voice events, sentence relay, queue
and receipts at the OpenCode v2 service instead of a `claude -p` child —
the adapter translates the session bus into stream-json and joins (or
wakes) the machine's shared `opencode serve`, so the phone never learns
which harness spoke. Each harness remembers its own conversation (a
per-harness resume pointer: flipping back resumes where that one
stopped), and an explicit `--claude <path>` always means claude. See
`docs/claude-code-bridge.md` for the schema-verified API surface and
`tool/bridge_oc_test.mjs` for the stub-service regression rig.
Protocol, verification notes, and the systemd unit: `docs/claude-code-bridge.md`.

## Run

```bash
flutter pub get
flutter run -d android        # phone attached; mic permission prompted
# iOS: run from macOS (flutter run -d <iphone-or-simulator>)
```

On first launch the app downloads the ASR pack plus the selected voice
pack (Lessac by default, ~124 MB total, see `modelPacks` + `ttsVoices` in
`lib/src/models/model_packs.dart` / `lib/src/speech/tts_voices.dart`) from GitHub releases and
unpacks them once into the app-support dir; only the 0.6 MB Silero VAD
ships inside the APK. Extra voices download on demand. The raw model
tarballs (or their extracted directories) sit in `models/` for the
headless tests — when that directory is absent those tests print
`SKIPPED` and pass; the zips live in
`assets/models/`.

### Building & shipping the Android APK (what to know so it just works)

```bash
# from ~/voice-agent
sed -i '' 's/^version: .*/version: 0.1.0+N/' pubspec.yaml   # macOS sed wants the
                                                        # empty-arg; on Linux drop
                                                        # the ''. Bump the +N:
                                                        # Android refuses to
                                                        # update-install over a lower
                                                        # versionCode
# --dart-define stamps the app's OWN journal line ('app start: build
# 0.1.0+N …'), so a field tape can say which binary it rode. Omit it
# and the tape reads 'build UNSTAMPED' — an honest tell, not a guess.
flutter build apk --release --split-per-abi \
  --dart-define=APP_VERSION=0.1.0+N
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk  (the phone build, ~46 MB)
```

Hard-won details:

* **The JDK the Gradle daemon runs on** — Gradle always considers the
  *running* JVM as a toolchain candidate, so plugin `compileDebugJavaWithJavac`
  tasks (e.g. audioplayers) die with *"does not provide the required
  capabilities: [JAVA_COMPILER]"* unless the daemon is pinned to a full JDK.
  `android/gradle.properties` (committed) pins the daemon + toolchain paths of
  the original LINUX dev box (`/usr/lib/jvm/java-21-openjdk-amd64`) — on this
  macOS box the user-level `~/.gradle/gradle.properties` overrides
  `org.gradle.java.home` to a full JDK (currently jdk-25.jdk; a bare JRE is
  not enough). If a build suddenly "fails at task-configuration in 10 s",
  look here first, not in the Dart changes.
* **Split versionCodes are +2000.** `--split-per-abi` encodes the ABI in
  `versionCode / 1000`: an `0.1.0+N` arm64 split ships versionCode `2000+N`
  (read it with `apkanalyzer manifest print …apk | grep versionCode`). The
  fat APK is plain `N`. Verify before Telegram hand-off: a build shortly
  after a version bump can be satisfied from cache and re-emit the PREVIOUS
  manifest (observed at +132: pubspec said 132, the split said 2131); a
  `flutter clean` (or `--no-... cache` equivalent rebuild) resets it.
* **Signing**: the release build reuses the debug keystore
  (`android/app/build.gradle.kts`) — fine for sideloading to your own phone,
  not for Play.
* **`--split-per-abi`** keeps the arm64 APK under the Telegram bot's 50 MB
  upload cap (the fat APK doesn't; neither does the x86_64 split).
  Install with `adb install -r app-arm64-v8a-release.apk`.
* **Model/voice packs are NOT in the APK**: the app downloads them from the
  `models-v1` release of `yundddd/voice-agent` at runtime, so a new engine
  needs its pack published *before* the APK is useful —
  `tool/build_pocket_pack.sh upload` / `tool/build_neutts_pack.sh upload`
  (needs `gh` auth for the release; NeuTTS additionally needs `HF_TOKEN`
  in `~/.env` + the NDK r25 Rust toolchain, see the script headers).
  If you change a pack's layout, bump its `pack-vN.ok` sentinel name in
  both the script and `lib/src/speech/tts_voices.dart` so installed apps re-download.
* **Probes must stay flutter-import-free**: the `tool/*_probe.dart` scripts
  run under plain `dart run`, which cannot compile `package:flutter`
  (`dart:ui` lives in the engine). Import `speech_worker.dart`/`audio_io.dart`
  directly and inline constants (e.g. the pocket voice list) rather than
  importing `tts_voices.dart`.
* **Before shipping**: `dart format --set-exit-if-changed lib tool test`,
  `dart analyze`, and the headless tests below (with `LD_LIBRARY_PATH` set,
  and `POCKET_DIR`/`NEUTTS_DIR` pointing at staged packs) must pass; the
  Pocket leg re-hears each preset through Whisper, so borderline scores are
  the judge (Whisper tiny), not the engine — the test uses the most stable
  presets for its second check.

### Headless round-trip test (no mic, no speaker)

The `LD_LIBRARY_PATH` below is the Linux plugin layout; on macOS the
dylibs live under `sherpa_onnx_macos-1.13.8/macos` in the same pub-cache
(and Flutter test hosts usually find them without help).

```bash
LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  flutter test test/roundtrip_test.dart
# writes build/roundtrip_reply.wav — listen to hear the TTS reply

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  flutter test test/gate_test.dart   # DSP unit tests (no models needed)

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  flutter test test/model_unpack_test.dart  # lazy voice-pack downloads (tar.bz2/raw)

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  dart run tool/onset_probe.dart      # asserts the first word survives endpointing

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  dart run tool/clone_probe.dart      # ZipVoice clone + Whisper intelligibility check

LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
  dart run tool/pocket_probe.dart     # Pocket TTS presets + Whisper intelligibility check
```

(`tool/build_pocket_pack.sh` stages the Pocket voice pack from the public
k2-fsa ONNX export + ungated kyutai/tts-voices wavs and, with the `upload`
argument, publishes it to the same GitHub release; re-run it before
`pocket_probe.dart` if `/tmp/opencode/pocket-pack` is gone.)

(The clone leg of `roundtrip_test.dart` runs when the extracted ZipVoice
pack + `vocos_24khz.onnx` sit under `/tmp/opencode` — see the k2-fsa
`tts-models` / `vocoder-models` releases; otherwise it skips.)

### Linux desktop (full app with mic)

Needs `clang cmake ninja-build pkg-config libgtk-3-dev`. GStreamer plugins
for audioplayers, PipeWire/Pulse for `record`.

## Next steps

- Streaming partial ASR (Moonshine/streaming zipformer) for lower first-response latency.
- Wake-word before the full recognizer (e.g. sherpa keyword spotter).
- Per-ABI splits (done) → consider an Android App Bundle for Play.
- iOS: microphone entitlement done (Info.plist); verify pod on macOS.

(The gateway between ASR and TTS and the sentence-streaming player — both
listed here once — shipped with the Claude Code bridge.)
