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
REPO_ROOT=$PWD

mkdir -p "$STAGE/voices"

# Static C++ runtime: without this the cdylib NEEDs libc++_shared.so, which
# Android's linker cannot resolve from an app-private directory.
export RUSTFLAGS="${RUSTFLAGS:-} -C link-args=-static-libstdc++ -C link-args=-Wl,-rpath,\\\$ORIGIN"

# 1. Android arm64 bridge .so (llama.cpp + NeuCodec decoder + espeak-ng).
#    NDK r25 is deliberate: r28's bindgen target triple lacks an API level.
(
  cd "$BRIDGE"
  ANDROID_NDK_HOME=$NDK_DIR ANDROID_NDK=$NDK_DIR \
    CARGO_TARGET_DIR=/tmp/opencode/neutts-android-target \
    PATH=$HOME/.cargo/bin:$PATH \
    cargo ndk -t arm64-v8a --platform 21 build --release
)
rm -f "$STAGE/libneutts_bridge.so" /tmp/opencode/neutts-pack/neutts-nano/libneutts_bridge.so 2>/dev/null; cp /tmp/opencode/neutts-android-target/aarch64-linux-android/release/libneutts_bridge.so \
  "$STAGE/libneutts_bridge.so"
# rustc's cdylib link references the NDK's shared libc++; ship it beside the
# bridge ($ORIGIN RUNPATH above) so Android resolves it from the app-private
# dir instead of the (W^X-forbidden) runtime-extractable jniLibs path.
rm -f "$STAGE/libc++_shared.so" 2>/dev/null; cp "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" \
  "$STAGE/libc++_shared.so"
echo "packed $(du -h "$STAGE/libneutts_bridge.so" | cut -f1) bridge .so"

# 2. NeuCodec decoder weights: pytorch_model.bin (gated; HF_TOKEN needed) is
#    converted to the runtime safetensors by the neutts-rs example.
#    The converted weights are a Derivative Work under NeuTTS Open License
#    v1.0 s.4(a): ship the license text alongside them.
CONVERTED=0
if [ ! -f "$STAGE/neucodec_decoder.safetensors" ]; then
  CONVERTED=1
  (cd "$NEUTTS_RS" && env CARGO_TARGET_DIR=/tmp/opencode/neutts-rs/target \
    ~/.cargo/bin/cargo run --release --example convert_weights -- \
    --out "$STAGE/neucodec_decoder.safetensors")
  [ -f /tmp/opencode/neutts-LICENCE.txt ] &&
    cp /tmp/opencode/neutts-LICENCE.txt "$STAGE/LICENCE-neucodec-decoder.txt"
fi

# 2b. Half the download: the loader upcasts BF16, so requantise in place —
#     but only weights converted by THIS run: a staged pack's safetensors
#     are already shrunk, and the venv lives on a scratch disk that gets
#     cleaned (re-running the shrinker on shrunk weights needs it for no
#     bytes saved).
if [ "$CONVERTED" = 1 ]; then
  "${VENV:-/tmp/opencode/venv-bf16}/bin/python" \
    tool/shrink_neucodec_bf16.py "$STAGE/neucodec_decoder.safetensors"
fi

# 3. Backbone GGUF (gated) + preset voice references (MIT repo, ungated).
for f in neutts-nano-Q4_0.gguf LICENCE; do
  # (re-runs: the licence file gets renamed below, so check the target too)
  if [ "$f" = LICENCE ] && [ -f "$STAGE/LICENCE-neutts-nano.txt" ]; then
    continue
  fi
  [ -f "$STAGE/$f" ] || curl -sfL -H "Authorization: Bearer ${HF_TOKEN}" \
    -o "$STAGE/$f" \
    "https://huggingface.co/neuphonic/neutts-nano-q4-gguf/resolve/main/$f"
done
[ -f "$STAGE/LICENCE" ] && mv "$STAGE/LICENCE" "$STAGE/LICENCE-neutts-nano.txt" || true
for v in greta jo juliette mateo; do
  for e in npy txt; do
    [ -f "$STAGE/voices/$v.$e" ] || curl -sfL -o "$STAGE/voices/$v.$e" \
      "https://raw.githubusercontent.com/eugenehp/neutts-rs/main/samples/$v.$e"
  done
done

# 4. Sentinel: bump the name when the pack layout/bridge ABI changes — the
#    app's presence check keys on this file (pack-v1 packs lacked it; v3
#    carries the duration-aware-EOS + sentence-chunking engine rebuild).
touch "$STAGE/pack-v3.ok"
chmod 555 "$STAGE/libneutts_bridge.so" "$STAGE/libc++_shared.so" 2>/dev/null || true

# 5. Zip with one top-level dir (stripped on unpack, see model_unpack.dart).
(cd "$(dirname "$STAGE")" && rm -f neutts-nano-v1.zip && zip -qry9 \
  neutts-nano-v1.zip neutts-nano)
echo "pack: $(du -h "$(dirname "$STAGE")/neutts-nano-v1.zip" | cut -f1)"

# 5. Publish alongside the ASR/TTS packs.
if [ "${1:-}" = upload ]; then
  gh release upload models-v1 "$(dirname "$STAGE")/neutts-nano-v1.zip" \
    --clobber -R "$REPO"
  echo "uploaded to $REPO releases (tag models-v1)"
fi
