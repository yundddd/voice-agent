# The patched sherpa-onnx (Pocket BOS-before-voice)

`pocket-bos-v1.13.8.patch` is a ~90-line, one-file patch against
**sherpa-onnx v1.13.8** — the exact version the `sherpa_onnx` pub plugin
(1.13.8) ships as prebuilt libraries. It answers
`docs/pocket-head-upstream-issue.md` fix #1+#2 inside sherpa's C++ Pocket
arm:

1. `LoadBosBeforeVoice()` reads `bos_before_voice.npy` (the learned
   `flow_lm.bos_before_voice` embedding, shape `(1,1,1024)` f4) from the
   **directory of the configured encoder graph** — no new config fields,
   so the Dart FFI struct layouts stay untouched. Absent file → byte-for-
   byte the old behavior (v2 packs keep working, ritual and all).
2. `GetVoiceEmbedding()` prepends that frame to the mimi encoder's output
   **before caching**, so the voice-conditioning step runs
   `[BOS] + voice_prompt` exactly as kyutai's `FlowLM.VoicePrompt` builds
   it — the fix for the growl-corrupted first frames.
3. The EOS loop gains kyutai's `_MIN_FRAMES_BEFORE_EOS = 6` guard
   (override via the `min_frames_before_eos` extra) and the
   `eos_step == 0` dead break (`eos_step > 0` → `>= 0`) — the
   short-input babble insurance.
4. Bonus fix: the voice-embedding cache HIT path built its tensor from
   the cached *shape* vector (rank-1 output) and then `std::memcpy`'d the
   *data* over a 3-element buffer — a rank mismatch plus a heap overrun
   on every second Generate with the same reference. Now alloc+shape,
   then fill. (The cache default capacity is 50, so every real app does
   hit this path.)

Measured on this machine (`/tmp` rig, alba reference, bench sentence):
first-20 ms RMS **0.0020** vs 0.0251 unpatched on the same graphs, and
whisper-tiny re-hears the full `Hello Tim, Pocket TTS Speaking…` head —
indistinguishable from KevinAHM's Python runtime (0.0018). The Dart
ritual (the `'.... '` prefix and the 250 ms trim) retires with this pack;
see `PocketTts.bosBeforeVoice` in `lib/src/speech/worker_backends.dart`.

## Pairing rule (why this is a pack *and* a library change)

The pack (`tool/build_pocket_pack.sh` v3) carries the npy; the Dart side
flips the ritual off **when the npy is on disk**. An unpatched runtime
with a v3 pack therefore re-opens the growl — the npy must pair with a
**patched library**. The APK vendors the built `.so` (below) and the
`pack-v3.ok` sentinel bump forces the re-download in the same update.

## Apply + build (Linux desktop — the bench path)

```bash
git clone --depth 1 --branch v1.13.8 --recurse-submodules \
    --shallow-submodules https://github.com/k2-fsa/sherpa-onnx.git
cd sherpa-onnx && git apply PATH/TO/pocket-bos-v1.13.8.patch
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_TTS=ON \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF -DSHERPA_ONNX_ENABLE_TESTS=OFF \
    -DSHERPA_ONNX_ENABLE_EXAMPLES=OFF -DSHERPA_ONNX_ENABLE_CHECK=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF -DSHERPA_ONNX_ENABLE_JNI=OFF \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
    -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build --target sherpa-onnx-c-api -j
```

Try it against the staged v3-style pack without touching the APK:

```bash
LD_LIBRARY_PATH=$PWD/build/lib:$PWD/build/_deps/onnxruntime-src/lib \
  flutter test test/roundtrip_test.dart   # from the app repo
```

The patched library must come FIRST on the path (the pub plugin ships
the same SONAME). The v1.13.8 pin downloads onnxruntime **1.28.2** — the
identical version the pub plugin bundles, so no ORT swap is needed.

## Vendor it (Android arm64)

Cross-build with the NDK (any r26+; `flutter doctor` shows the pinned
one) and drop the result into the app so it shadows the plugin's copy —
app `jniLibs` beat library `jniLibs` in the merge:

```bash
cmake -B build-and -G Ninja -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_ARM_NEON=ON \
    <the same -D flags as above>
cmake --build build-and --target sherpa-onnx-c-api -j
cp build-and/lib/libsherpa-onnx-c-api.so \
   android/app/src/main/jniLibs/arm64-v8a/
```

(Only that one `.so` is needed — the patch is header-only and the core
links statically, mirroring how the plugin ships it. Verify with the
round-trip bench on-device: the voice-screen latency card, or
`dart run tool/pocket_probe.dart` before packaging.)

## iOS

Same single-file patch against the v1.13.8 xcframework build (a macOS
runner; k2-fsa's own iOS build action is the template). Until it lands
there, the iOS side simply keeps the `pack-v2` line: the Dart fallback
is keyed on the npy's absence, so the growl ritual keeps iOS voices
sounding exactly as they do today.

## Upstream

Open as a PR against sherpa-onnx (the issue doc has been waiting for
the runtime half; the data half KevinAHM's bundle already ships). Keep
the patch as a diff file rather than a fork: one header, v1.13.8-pinned,
re-apply is one `git apply` on every version bump — and delete the whole
directory once k2-fsa merges an equivalent.
