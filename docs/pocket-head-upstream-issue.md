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

Happy to re-run any experiment against a branch — I have the full A/B harness
(official pytorch renders vs sherpa renders, whisper-tiny re-transcription,
onset RMS profiles) for all six presets.
