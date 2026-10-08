#!/usr/bin/env bash
# Build + pack the NeuTTS voice engine assets, then upload to our GitHub
# release so the app can download the pack anonymously (Hugging Face itself
# gates the upstream repos behind a terms click — see README).
#
# Prereqs (one-time): rustup target add aarch64-linux-android &&
# cargo install cargo-ndk, Android NDK 25 (bindgen on NDK 28 chokes on
# libc++'s pthread_cond_clockwait guards), cmake on PATH, gh CLI, and
# HF_TOKEN in ~/.env for the gated neucodec checkpoint download.
#
#   tool/build_neutts_pack.sh            # builds, converts, zips
#   tool/build_neutts_pack.sh upload     # ...and gh-release-uploads the zip
set -euo pipefail

REPO=${REPO:-yundddd/voice-agent}
STAGE=${STAGE:-/tmp/opencode/neutts-pack/neutts-nano}
BRIDGE=neutts/bridge
NDK_DIR=${NDK_DIR:-$HOME/android-sdk/ndk/25.1.8937393}
NEUTTS_RS=${NEUTTS_RS:-/tmp/opencode/neutts-rs}   # github.com/eugenehp/neutts-rs

cd "$(dirname "$0")/.."

mkdir -p "$STAGE/voices"

# 1. Android arm64 bridge .so (llama.cpp + NeuCodec decoder + espeak-ng).
#    NDK r25 is deliberate: r28's bindgen target triple lacks an API level.
(
  cd "$BRIDGE"
  ANDROID_NDK_HOME=$NDK_DIR ANDROID_NDK=$NDK_DIR \
    PATH=$HOME/.cargo/bin:$PATH \
    cargo ndk -t arm64-v8a --platform 21 -o "$OLDPWD/$STAGE" build --release
)
mv "$STAGE/arm64-v8a/libneutts_bridge.so" "$STAGE/libneutts_bridge.so"
rmdir "$STAGE/arm64-v8a"
echo "packed $(du -h "$STAGE/libneutts_bridge.so" | cut -f1) bridge .so"

# 2. NeuCodec decoder weights: pytorch_model.bin (gated; HF_TOKEN needed) is
#    converted to the runtime safetensors by the neutts-rs example.
if [ ! -f "$STAGE/neucodec_decoder.safetensors" ]; then
  (cd "$NEUTTS_RS" && ~/.cargo/bin/cargo run --release --example \
    convert_weights -- --out "$OLDPWD/$STAGE/neucodec_decoder.safetensors")
fi

# 3. Backbone GGUF (gated) + preset voice references (MIT repo, ungated).
for f in neutts-nano-Q4_0.gguf LICENCE; do
  [ -f "$STAGE/$f" ] || curl -sfL -H "Authorization: Bearer ${HF_TOKEN}" \
    -o "$STAGE/$f" \
    "https://huggingface.co/neuphonic/neutts-nano-q4-gguf/resolve/main/$f"
done
[ -f "$STAGE/LICENCE" ] && mv "$STAGE/LICENCE" "$STAGE/LICENCE-neutts-nano.txt"
for v in dave jo; do
  for e in npy txt; do
    [ -f "$STAGE/voices/$v.$e" ] || curl -sfL -o "$STAGE/voices/$v.$e" \
      "https://raw.githubusercontent.com/eugenehp/neutts-rs/main/samples/$v.$e"
  done
done

# 4. Zip with one top-level dir (stripped on unpack, see model_unpack.dart).
(cd "$(dirname "$STAGE")" && rm -f neutts-nano-v1.zip && zip -qry9 \
  neutts-nano-v1.zip neutts-nano)
echo "pack: $(du -h "$(dirname "$STAGE")/neutts-nano-v1.zip" | cut -f1)"

# 5. Publish alongside the ASR/TTS packs.
if [ "${1:-}" = upload ]; then
  gh release upload models-v1 "$(dirname "$STAGE")/neutts-nano-v1.zip" \
    --clobber -R "$REPO"
  echo "uploaded to $REPO releases (tag models-v1)"
fi
