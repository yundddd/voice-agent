# PocketTTS (ONNX): garbled/cut-off speech onset — cold start lacks the BOS-before-voice step the PyTorch reference uses

**Environment:** sherpa-onnx v1.13.8 (also checked `master`: `offline-tts-pocket-impl.h` is
identical), model: `sherpa-onnx-pocket-tts-int8-2026-01-26.tar.bz2` (KevinAHM export),
CPU provider, linux x86_64 + Android arm64.

## Symptom
Every `Generate` call starts speaking at full amplitude from sample 0 with a low
growl/click where the official PyTorch model emits its natural ~0.5 s silence
pre-roll; the attack of the first word rides inside the growl, so recordings sound
"cut off at the very beginning". Whisper reports the mangled onset (e.g.
"Hello Tim" -> "the low-tem" / "lutham") while the rest of the sentence is
perfectly clean. Additionally, a short standalone sentence (< ~5 words) reliably
fails: the first syllable is garbled and if EOS never fires the loop decodes to
`max_frames` = **40 s** of babble (observed).

## Evidence
Same text + same reference wavs (kyutai/tts-voices jane/alba/anna/jean/michael/
bill_boerst):

* official `pocket_tts.TTSModel.generate_audio` **and** `generate_audio_stream`:
  12/12 files start with true silence (RMS ~0.001 FS) and clean "Hello Tim".
* sherpa-onnx: 0/12 draws clean; first-loud at 0.2–1 ms, leading 20 ms windows
  already at 5–30 % FS (growl), first word mangled or eaten.
* Trimming the first ~250 ms of the sherpa output restores intelligibility of the
  remainder -> damage is confined to the cold-start frames, mid-sentence audio is
  identical quality.
* knobs don't fix it: temperature 0.3/0.7, num_steps 2/5, silence_scale
  1.0/0.2, chunk_size 15/500, seed sweep 0..21 all show the same per-draw lottery.

## Suspected root cause
In `OfflineTtsPocketImpl::GenerateSingleSentence` the voice conditioning is

```cpp
RunLmMain(View(&empty_seq_tensor), std::move(voice_embedding), lm_main_state);  // voice
RunLmMain(std::move(empty_seq_tensor), std::move(text_embedding), lm_main_state); // text
```

while the reference (`flow_lm.py`) builds the prompt as
`[bos_emb] + voice_prompt + text` — kyutai's configs set
`insert_bos_before_voice: true`, and `flow_lm.py` replaces NaN latents with the
**learned BOS embedding**, not zeros. The Go port
[CWBudde/go-pocket-tts](https://github.com/CWBudde/go-pocket-tts)
(`internal/onnx/generate.go::prependVoice`) does feed `BOSBeforeVoice()` before
the voice embedding and includes a `ChunkFadeIn` on the first chunk, suggesting
other port maintainers hit the same artifact. The single voice-conditioning step
without the preceding BOS frame also explains why short inputs fail harder: the
reference's `_MIN_FRAMES_BEFORE_EOS = 6` guard ("before speech starts, the EOS
logit of some voices can cross the threshold, and a short text then ends before
the word is spoken") has no counterpart in the C++ port — the EOS check applies
from step 0, and `eos_step == 0` never breaks (`if (eos_step > 0 && ...)`),
silently switching to the 500-frame default.

## Suggested fixes
1. Prepend the learned BOS-before-voice embedding (or one extra conditioning
   step) when priming `lm_main_state` with the voice embedding, mirroring
   `FlowLM.VoicePrompt`.
2. Port the `_MIN_FRAMES_BEFORE_EOS` guard (ignore EOS for the first ~6 frames,
   and treat `eos_step == 0` as "at frame 0", currently unreachable).
3. Optionally clamp/scale the first decoder chunk (fade-in), as the Go port does.

## Update (2026-10-23): the upstream export now ships the fix's data
[KevinAHM/pocket-tts-onnx](https://huggingface.co/KevinAHM/pocket-tts-onnx)
re-exported to per-language bundles that each carry **`bos_before_voice.npy`**
— the learned BOS embedding fix #1 names, exported — and its bundled
`pocket_tts_onnx.py` runtime feeds it before the voice embedding (line ~269),
honours `model_recommended_frames_after_eos`, and loads kyutai's
`.safetensors` prompt states directly (the without-voice-cloning path).
Measured on this machine with the same text + alba reference as the
clone-leg above, english_2026-04 int8 bundle:
**first-20 ms RMS 0.0018** (true pre-roll; sherpa draws measured 0.05-0.3
at the same window) and whisper-tiny re-hears
"Hello Tim, Pocket TTS Speaking, generated entirely on this device." — head
intact. sherpa-onnx `master` (checked today) still consumes neither the npy
nor the safetensors states (`offline-tts-pocket{,-model}.h` mention no
bos/npy), so the artifact exists end-to-end: what is missing is the sherpa
runtime change. This closes the diagnosis half of this issue; the app keeps
the '....' + `pocketLeadIn` ritual until sherpa ships the BOS step (or the
pack moves to a runtime that has it).

Happy to re-run any experiment against a branch — I have the full A/B harness
(official pytorch renders vs sherpa renders, whisper-tiny re-transcription,
onset RMS profiles) for all six presets.

## Addendum (2026-10-15): port opens ~0.4 s too early, not just noisy
Further A/B (official pytorch `generate_audio` vs `generate_audio_stream`
vs sherpa, same 6 prompts, same text): the OFFICIAL renders — offline AND
streaming — all keep a true-silence pre-roll (first-loud at 57-917 ms,
voice-dependent); sherpa renders start at full amplitude at 0.2-1 ms on
every voice/draw/knob (temperature 0.3/0.7, num_steps 2/5,
silence_scale 1/0.2, chunk_size 15/500, seeds 0-21). So the cold-start
failure has a timing component, not only an artifact component:
`GetVoiceEmbedding` collapses the reference to one pooled frame, so
lm_main never sees the prompt ending in its trailing pause (the official
continuation state does — that pause IS the pre-roll), and the model
answers ~2-5 frames early, putting the first word's attack inside the
corrupted frames. That also explains why short openers ("Sure!") are
devastated while long first phrases only lose their first syllable.
App-side workaround that fully fixed the audible symptom (measured
whisper-tiny head-hits 10/10 across all six presets): text prefix
'.... ' (model-generated pause per kyutai FAQ, kyutai-labs/pocket-tts#6)
+ silence_scale 1.0 (the default 0.2 squashes it) + drop the first
250 ms + 30 ms fade + 300 ms inserted silence. A proper runtime-side fix
would keep the full per-frame prompt state for the voice conditioning
(prepend BOS + feed prompt codes as a sequence) instead of one pooled
embedding step; happy to test a branch.
