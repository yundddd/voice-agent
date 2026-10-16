#!/usr/bin/env bash
# Build + pack the Kyutai Pocket TTS voice-engine assets, then upload to our
# GitHub release so the app downloads the pack anonymously (same CDN story as
# the NeuTTS pack, but nothing here is gated: we ship the *public* k2-fsa
# ONNX export of kyutai/pocket-tts (the HF repo itself is gated:auto — one
# terms click — but the export on the sherpa-onnx releases is not) plus
# reference wavs from the ungated kyutai/tts-voices repo).
#
# The engine itself is sherpa-onnx (already in the APK via the pub plugin,
# PocketTTS support since v1.12.24) — this pack carries only model data, so
# no NDK/Rust step; re-running needs only curl + zip + gh.
#
#   tool/build_pocket_pack.sh            # download, stage, zip
#   tool/build_pocket_pack.sh upload     # ...and gh-release-uploads the zip
set -euo pipefail

REPO=${REPO:-yundddd/voice-agent}
STAGE=${STAGE:-/tmp/opencode/pocket-pack/pocket-tts}
K2FSA_TTS=https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models
# FP32 export (v2 pack). The int8 pack (v1) measured the SAME ~10 kHz Mimi
# codec ceiling in our band forensics, so quantization bought no bandwidth —
# but subjective A/B (and the user's ears at ~1 kHz less AR-path hiss) came
# down for the full-precision graphs, at +70 MB download / 1.6x desktop RTF
# (0.16 vs 0.10; the voice-screen round-trip bench is how to feel it out).
PACK=sherpa-onnx-pocket-tts-2026-01-26
TTS_VOICES=https://huggingface.co/kyutai/tts-voices/resolve/main   # ungated

# Preset voices -> upstream paths (kyutai.org/pocket-tts voice list). Names
# must stay in sync with TtsVoice.pocketRefs in lib/tts_voices.dart.
declare -A REFS=(
  [jane]=vctk/p339_023_enhanced.wav                 # f, conversation
  [anna]=vctk/p228_023_enhanced.wav                 # f, conversation
  [jean]=ears/p010/freeform_speech_01_enhanced.wav  # m, conversation
  [michael]=vctk/p360_023_enhanced.wav              # m, conversation
  [alba]=alba-mackenna/casual.wav                   # m, reading
  [bill_boerst]=voice-zero/bill_boerst.wav          # m, reading
)
# Slider order (sid index == position in this list):
ORDER=(jane anna jean michael alba bill_boerst)

cd "$(dirname "$0")/.."

mkdir -p "$(dirname "$STAGE")"

# 1. Model files: the exported ONNX set + the CC-BY-4.0 licence text.
if [ ! -f "$STAGE/lm_main.onnx" ]; then
  rm -rf "$STAGE"  # fresh: mv must land the extracted dir AT $STAGE, not in it
  (cd "$(dirname "$STAGE")" && curl -sfL -O "$K2FSA_TTS/$PACK.tar.bz2" &&
    tar xjf "$PACK.tar.bz2" && rm "$PACK.tar.bz2" &&
    mv "$PACK" "$(basename "$STAGE")")
fi
mkdir -p "$STAGE/voices"
rm -rf "$STAGE/test_wavs"   # k2-fsa's samples: our curated voices/ replace them
rm -f "$STAGE/README.md"    # k2-fsa's two-paragraph note; NOTICE replaces it
for f in lm_flow.onnx lm_main.onnx encoder.onnx decoder.onnx \
  text_conditioner.onnx vocab.json token_scores.json LICENSE; do
  [ -s "$STAGE/$f" ] || { echo "missing $STAGE/$f" >&2; exit 1; }
done

# 2. Reference voices (mono PCM16, 10-13 s; sherpa resamples to 24 kHz and
#    caps the prompt at 10 s itself, so upstream rates are fine).
for v in "${ORDER[@]}"; do
  [ -s "$STAGE/voices/$v.wav" ] ||
    curl -sfL -o "$STAGE/voices/$v.wav" "$TTS_VOICES/${REFS[$v]}"
done

# 3. Attribution note for the mirrored files (license: CC-BY-4.0, shipped
#    verbatim as LICENSE; this records provenance for the onnx export step).
cat > "$STAGE/NOTICE" <<EOF
pocket-tts pack (v2, fp32 graphs)
  model:  kyutai/pocket-tts (CC-BY-4.0, https://huggingface.co/kyutai/pocket-tts)
          exported to ONNX (fp32) by KevinAHM/pocket-tts-onnx-export and
          repackaged on the k2-fsa/sherpa-onnx 'tts-models' releases as
          $PACK
  voices: reference wavs from https://huggingface.co/kyutai/tts-voices
          (jane -> vctk/p339, anna -> vctk/p228, jean -> ears/p010,
          michael -> vctk/p360, alba -> alba-mackenna/casual,
          bill_boerst -> voice-zero/bill_boerst)
EOF

# 4. Sentinel: bump the name when the pack layout changes — the app's
#    presence check keys on this file (see lib/tts_voices.dart). v1 was the
#    int8 graph set; v2 switches lm/flow/decoder to the fp32 export (the
#    unpacker clears the old directory on marker-bump re-downloads).
touch "$STAGE/pack-v2.ok"

# 5. Zip with one top-level dir (stripped on unpack, see model_unpack.dart):
#    the app's streaming zip path keeps phone RAM flat during unpack.
(cd "$(dirname "$STAGE")" && rm -f pocket-tts-v2.zip && zip -qry9 \
  pocket-tts-v2.zip "$(basename "$STAGE")")
echo "pack: $(du -h "$(dirname "$STAGE")/pocket-tts-v2.zip" | cut -f1)"

# 6. Publish alongside the ASR/TTS packs.
if [ "${1:-}" = upload ]; then
  gh release upload models-v1 "$(dirname "$STAGE")/pocket-tts-v2.zip" \
    --clobber -R "$REPO"
  echo "uploaded to $REPO releases (tag models-v1)"
fi
