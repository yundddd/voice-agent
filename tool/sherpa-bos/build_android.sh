#!/usr/bin/env bash
# Cross-build the patched sherpa-onnx v1.13.8 C API for every ABI the APK
# ships and vendor the result into android/app/src/main/jniLibs — the
# espeak precedent (third_party/espeak_exec): a GPL/FFI artifact built by
# a tool script into the IGNORED jniLibs dir, not a committed blob. Run
# it once before `flutter build apk`; app-level jniLibs shadow the
# sherpa_onnx_android_* plugin copies with the same SONAME, so the patch
# reaches every packaged binary while all other plugin .so's (ORT, cxx
# api) stay upstream.
#
# Pairing rule (docs/pocket-head-upstream-issue.md, README): pack v3's
# bos_before_voice.npy flips the Dart growl ritual off, so EVERY shipped
# ABI must run patched or the growl returns on that device. All three
# ABIs below, always.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
SRC=${SRC:-$here/sherpa-onnx-src}

# Pin the tag to the pub plugin's version — the patch and the bundled
# libraries may never disagree on the sherpa version.
VER=$(awk '/^  sherpa_onnx:/{f=1} f && /version: /{gsub(/"/, "", $2); print $2; exit}' \
        "$repo/pubspec.lock")
[ -n "$VER" ] || { echo "sherpa_onnx version not found in pubspec.lock" >&2; exit 1; }
TAG="v$VER"

# Same NDK Gradle will use: flutter 3.47 pins 28.2.13676358
# (packages/flutter_tools/gradle/.../FlutterExtension.kt). Override with
# NDK=/path/to/ndk when the SDK was provisioned differently.
SDK=${ANDROID_HOME:-$HOME/android-sdk}
NDK=${NDK:-$SDK/ndk/28.2.13676358}
NDK_DIR=$NDK
[ -d "$NDK_DIR" ] || { echo "NDK not found at $NDK_DIR (set NDK=)" >&2; exit 1; }

# 1. Source at the exact tag (shallow; submodules carry fst/knf/kaldifst).
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" --recurse-submodules \
      --shallow-submodules https://github.com/k2-fsa/sherpa-onnx.git "$SRC"
fi
git -C "$SRC" checkout -q "$TAG"
# Idempotent: reverse-check first — a clean reverse apply means the patch
# is already on, so re-running never double-applies.
if git -C "$SRC" apply --reverse --check "$here/pocket-bos-$TAG.patch" 2>/dev/null; then
  echo "patch already applied to $SRC"
else
  git -C "$SRC" apply "$here/pocket-bos-$TAG.patch"
fi

FLAGS=( -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
        -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_TTS=ON
        -DSHERPA_ONNX_ENABLE_PYTHON=OFF -DSHERPA_ONNX_ENABLE_TESTS=OFF
        -DSHERPA_ONNX_ENABLE_EXAMPLES=OFF -DSHERPA_ONNX_ENABLE_CHECK=OFF
        -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF -DSHERPA_ONNX_ENABLE_JNI=OFF
        -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF
        -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        # match the plugin's packaging conventions: static libc++ (no
        # libc++_shared.so in the APK today) and the plain ORT soname
        # (1.28.2, the version this tag pins = the plugin's own).
        -DANDROID_STL=c++_static )

readelf=$SDK/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf

for ABI in arm64-v8a x86_64 armeabi-v7a; do
  echo "== $ABI ($TAG, patched)"
  cmake -S "$SRC" -B "$SRC/build-$ABI" -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=$NDK_DIR/build/cmake/android.toolchain.cmake \
      -DANDROID_ABI=$ABI -DANDROID_PLATFORM=android-24 -DANDROID_ARM_NEON=ON \
      "${FLAGS[@]}" > /dev/null
  cmake --build "$SRC/build-$ABI" --target sherpa-onnx-c-api -j 10
  out="$repo/android/app/src/main/jniLibs/$ABI/libsherpa-onnx-c-api.so"
  mkdir -p "$(dirname "$out")"
  cp "$SRC/build-$ABI/lib/libsherpa-onnx-c-api.so" "$out"
  # Match the plugin's shipped form: the pub package carries stripped
  # libs (~4.5 MB, not 84 MB of DWARF). Gradle would strip at packaging
  # anyway; stripping here keeps the vendor artifact comparable and the
  # APK task honest.
  "$SDK/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
    --strip-unneeded "$out"
  # The patch markers: the npy convention string must be in the binary,
  # and the NEEDED list must stay libonnxruntime.so-only (no STL drift).
  grep -q bos_before_voice.npy "$out" || { echo "patch missing in $out" >&2; exit 1; }
  "$readelf" -d "$out" | grep -q "Shared library: \[libonnxruntime.so\]" ||
    { echo "unexpected link deps in $out" >&2; exit 1; }
  echo "   vendored $out"
done
echo "done — flutter build apk --release --split-per-abi now rides the patch"
