#!/usr/bin/env bash
# Build + pack the Kyutai Pocket TTS voice-engine assets, then upload to our
# GitHub release so the app downloads the pack anonymously (same CDN story as
# every other pack: nothing here is gated).
#
# v4 layout (the no-growl pack, sixteen voices):
#   - the FLOW LM graphs move from the k2-fsa 2026-01 export (checkpoint
#     english_2026-01, which has NO bos_before_voice embedding at all) to
#     KevinAHM's per-language bundle of checkpoint english_2026-04 —
#     https://huggingface.co/KevinAHM/pocket-tts-onnx — whose
#     bos_before_voice.npy the patched sherpa-onnx build (see
#     tool/sherpa-bos/) feeds before the voice embedding, exactly as
#     kyutai's FlowLM.VoicePrompt does. Measured (docs/pocket-head-upstream-
#     issue.md): first-20ms RMS 0.0020 vs 0.0251 unpatched, whisper re-hears
#     the full first sentence; the Dart '....' prefix + 250ms trim retire.
#   - LM/flow ship INT8 (the bundle's own default; measured clean and ~2x
#     the fp32 throughput — see benchmarks in the bundle README). The mimi
#     encoder/decoder and text conditioner ship fp32, following the v1->v2
#     A/B on our own ears (the int8 decoder path measured drier; the codec
#     side is where the listening test was decided). PRECISION=fp32 flips
#     the LM graphs too if you want to redo that A/B on the new checkpoint.
#   - vocab.json/token_scores.json still come from the k2-fsa rehost (they
#     are generated artifacts of the export; the tokenizer.model is byte-
#     identical across the repos, so they stay valid for the new graphs).
#
#   tool/build_pocket_pack.sh            # download, stage, zip
#   tool/build_pocket_pack.sh upload     # ...and gh-release-uploads the zip
set -euo pipefail

REPO=${REPO:-yundddd/voice-agent}
STAGE=${STAGE:-/tmp/opencode/pocket-pack/pocket-tts}
K2FSA_TTS=https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models
# Same k2-fsa export as v1/v2: still the source of the tokenizer JSONs,
# the LICENSE and the provenance anchor (its graphs are superseded below).
K2PACK=sherpa-onnx-pocket-tts-2026-01-26
KEVIN=https://huggingface.co/KevinAHM/pocket-tts-onnx/resolve/main
KEVIN_LANG=english_2026-04           # the bundle whose npy the patch wants
PRECISION=${PRECISION:-int8}         # int8 | fp32 for the LM graphs
TTS_VOICES=https://huggingface.co/kyutai/tts-voices/resolve/main   # ungated

# Preset voices -> upstream paths (kyutai.org/pocket-tts voice list). Names
# must stay in sync with TtsVoice.pocketRefs in lib/src/speech/tts_voices.dart
# and pocketRoster in kokoro_voices.dart. Sids 0-5 are FROZEN (ships user
# prefs); the v4 lineup appends ten more, 8 female / 8 male (genders
# measured from the references' median F0, not assumed from names —
# marius is female, george male).
declare -A REFS=(
  [jane]=vctk/p339_023_enhanced.wav                 # f, conversation
  [anna]=vctk/p228_023_enhanced.wav                 # f, conversation
  [jean]=ears/p010/freeform_speech_01_enhanced.wav  # m, conversation
  [michael]=vctk/p360_023_enhanced.wav              # m, conversation
  [alba]=alba-mackenna/casual.wav                   # m, reading
  [bill_boerst]=voice-zero/bill_boerst.wav          # m, reading
  [azelma]=vctk/p303_023_enhanced.wav               # f
  [eve]=vctk/p361_023_enhanced.wav                  # f
  [fantine]=vctk/p244_023_enhanced.wav              # f
  [mary]=vctk/p333_023_enhanced.wav                 # f
  [vera]=vctk/p229_023_enhanced.wav                 # f
  [marius]=voice-donations/Selfie.wav               # f
  [charles]=vctk/p254_023_enhanced.wav              # m
  [george]=vctk/p315_023_enhanced.wav               # m
  [javert]=voice-donations/Butter.wav               # m
  [paul]=vctk/p259_023_enhanced.wav                 # m
)
# Slider order (sid index == position in this list):
ORDER=(jane anna jean michael alba bill_boerst
       azelma eve fantine mary vera marius
       charles george javert paul)

cd "$(dirname "$0")/.."

mkdir -p "$(dirname "$STAGE")"

# 1. k2-fsa export: tokenizer JSONs, LICENSE, and the graph set we overwrite.
if [ ! -f "$STAGE/vocab.json" ]; then
  rm -rf "$STAGE"  # fresh: mv must land the extracted dir AT $STAGE, not in it
  (cd "$(dirname "$STAGE")" && curl -sfL -O "$K2FSA_TTS/$K2PACK.tar.bz2" &&
    tar xjf "$K2PACK.tar.bz2" && rm "$K2PACK.tar.bz2" &&
    mv "$K2PACK" "$(basename "$STAGE")")
fi
mkdir -p "$STAGE/voices"
rm -rf "$STAGE/test_wavs"   # k2-fsa's samples: our curated voices/ replace them
rm -f "$STAGE/README.md"    # k2-fsa's two-paragraph note; NOTICE replaces it

# 2. v3 graphs: KevinAHM's english_2026-04 bundle, renamed to the k2-fsa
#    file names sherpa-onnx (and our TtsSpec) read. Wipe any v2 graphs in
#    a re-staged directory first: fetch() below skips files that exist,
#    and a stale v2 lm_main.onnx must not shadow the new bundle.
rm -f "$STAGE/lm_main.onnx" "$STAGE/lm_flow.onnx" "$STAGE/decoder.onnx" \
      "$STAGE/encoder.onnx" "$STAGE/text_conditioner.onnx" \
      "$STAGE"/*.int8.onnx "$STAGE"/pack-v*.ok
fetch() { # fetch <url> <dest-name>
  [ -s "$STAGE/$2" ] && return
  curl -sfL -o "$STAGE/$2.part" "$1" && mv "$STAGE/$2.part" "$STAGE/$2"
}
fetch "$KEVIN/onnx/$KEVIN_LANG/flow_lm_main_$PRECISION.onnx"   lm_main.onnx
fetch "$KEVIN/onnx/$KEVIN_LANG/flow_lm_flow_$PRECISION.onnx"   lm_flow.onnx
fetch "$KEVIN/onnx/$KEVIN_LANG/mimi_decoder.onnx"              decoder.onnx
fetch "$KEVIN/onnx/$KEVIN_LANG/mimi_encoder.onnx"              encoder.onnx
fetch "$KEVIN/onnx/$KEVIN_LANG/text_conditioner.onnx"          text_conditioner.onnx
fetch "$KEVIN/onnx/$KEVIN_LANG/bos_before_voice.npy"           bos_before_voice.npy
rm -f "$STAGE"/*.int8.onnx   # the 2026-01 graphs: superseded by the bundle
for f in lm_flow.onnx lm_main.onnx encoder.onnx decoder.onnx \
  text_conditioner.onnx bos_before_voice.npy vocab.json token_scores.json LICENSE; do
  [ -s "$STAGE/$f" ] || { echo "missing $STAGE/$f" >&2; exit 1; }
done

# 3. Reference voices: downloaded, then ALWAYS repacked to end on silence
#    (first 9.5 s + 0.7 s pad). Conditioning stops at 10 s (sherpa's
#    max_reference_audio_len), so the pad is what makes the prompt's last
#    frame a pause — without it the model legitimately starts speaking at
#    sample 0 and the first word rides its own attack (measured on the
#    raw vctk cut: RMS@20ms 0.026 vs 0.001 padded; the BOS patch fixed
#    the cold start, the pad fixes the prompt). Mono PCM16 at the
#    upstream rate; sherpa resamples to 24 kHz itself.
for v in "${ORDER[@]}"; do
  rm -f "$STAGE/voices/$v.wav"     # always re-pad: one provenance for all refs
  curl -sfL -o "$STAGE/voices/$v.raw.wav" "$TTS_VOICES/${REFS[$v]}"
  ffmpeg -loglevel error -y -i "$STAGE/voices/$v.raw.wav" \
    -af "atrim=0:9.5,apad=pad_dur=0.7" -ac 1 -c:a pcm_s16le \
    "$STAGE/voices/$v.wav" && rm -f "$STAGE/voices/$v.raw.wav"
done

# 4. Attribution note for the mirrored files (license: CC-BY-4.0, shipped
#    verbatim as LICENSE; this records provenance for the onnx export step).
cat > "$STAGE/NOTICE" <<EOF
pocket-tts pack (v4, $PRECISION LM/flow graphs + learned BOS-before-voice + sixteen padded reference voices)
  model:  kyutai/pocket-tts (CC-BY-4.0, https://huggingface.co/kyutai/pocket-tts)
          bundle '$KEVIN_LANG' (checkpoint english_2026-04) exported to ONNX by
          KevinAHM/pocket-tts-onnx (https://huggingface.co/KevinAHM/pocket-tts-onnx)
          graphs renamed from flow_lm_main_$PRECISION/flow_lm_flow_$PRECISION/
          mimi_decoder/mimi_encoder/text_conditioner to the sherpa-onnx names
  npy:    bos_before_voice.npy = flow_lm.bos_before_voice of the same
          checkpoint; consumed by our patched sherpa-onnx v1.13.8 (see
          tool/sherpa-bos/) — with it, the voice prompt is conditioned as
          [BOS] + voice (kyutai FlowLM.VoicePrompt) and the cold-start
          growl documented in docs/pocket-head-upstream-issue.md is gone
  tokens: vocab.json/token_scores.json from the k2-fsa re-host
          ($K2PACK) of the original export; tokenizer.model is byte-
          identical between the checkpoints' repos, so they remain valid
  voices: reference wavs from https://huggingface.co/kyutai/tts-voices
          (jane -> vctk/p339, anna -> vctk/p228, jean -> ears/p010,
          michael -> vctk/p360, alba -> alba-mackenna/casual,
          bill_boerst -> voice-zero/bill_boerst, azelma -> vctk/p303,
          eve -> vctk/p361, fantine -> vctk/p244, mary -> vctk/p333,
          vera -> vctk/p229, marius -> voice-donations/Selfie,
          charles -> vctk/p254, george -> vctk/p315,
          javert -> voice-donations/Butter, paul -> vctk/p259);
          every one trimmed to 9.5 s + 0.7 s silence so the
          conditioning prompt ends on a pause (see the pack script)
EOF

# 5. Sentinel: bump the name when the pack layout changes — the app's
#    presence check keys on this file (see lib/src/models/model_unpack.dart).
#    v2 was the fp32 2026-01 graphs; v3 swaps in the english_2026-04 bundle
#    + bos_before_voice.npy (the unpacker clears the old directory on
#    marker-bump re-downloads). v4 = sixteen padded reference voices (the
#    graphs and the npy are unchanged from v3). THE PAIRING RULE: Dart flips the ritual off
#    when the npy exists, and the native side must actually feed it — a v3
#    pack on an UNPATCHED runtime re-opens the growl (worse: the prefix that
#    used to absorb it is gone). The patched .so therefore ships in the same
#    APK as this pack: tool/sherpa-bos/README.md is the build-and-vendor
#    note, and the round-trip bench's contains('hello') leg is the tripwire.
touch "$STAGE/pack-v4.ok"

# 6. Zip with one top-level dir (stripped on unpack, see model_unpack.dart):
#    the app's streaming zip path keeps phone RAM flat during unpack.
(cd "$(dirname "$STAGE")" && rm -f pocket-tts-v4.zip && zip -qry9 \
  pocket-tts-v4.zip "$(basename "$STAGE")")
echo "pack: $(du -h "$(dirname "$STAGE")/pocket-tts-v4.zip" | cut -f1)"

# 7. Publish alongside the ASR/TTS packs.
if [ "${1:-}" = upload ]; then
  gh release upload models-v1 "$(dirname "$STAGE")/pocket-tts-v4.zip" \
    --clobber -R "$REPO"
  echo "uploaded to $REPO releases (tag models-v1)"
fi
