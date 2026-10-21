# espeak-ng, out of process

The student TTS front-end (+238): upstream espeak-ng built as a
standalone Android executable. GPL v3 applies to THIS binary and its
data; the app talks to it through exec() + argv + stdout only — mere
interaction, no linking — so no copyleft duty touches our code.

Provenance
- Source: https://github.com/espeak-ng/espeak-ng (clone, depth 1 at
  build time; pin the tag you build with before re-shipping).
- The pruned data (en_dict + lang/gmw only, 936 KB) replaces the old
  piper_phonemize vendoring of +67..+223 — same content rules, this
  time produced by the upstream build rather than a package prune.

Rebuild (Linux host, Android NDK r25+, cmake >= 3.22):
    cmake -S espeak-ng -B build-arm64 -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 \
      -DCMAKE_BUILD_TYPE=Release -DUSE_ASYNC=OFF
    cmake --build build-arm64 --target espeak-ng -j
    # host build of the same tree compiles the data (arch-neutral):
    cmake -S espeak-ng -B build-host -G Ninja && cmake --build build-host
    # prune build-host/espeak-ng-data to phondata, phonindex, phontab,
    # intonations, en_dict, lang/gmw/*  → assets/espeak-data/
    $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip -s \
      build-arm64/src/espeak-ng
    cp build-arm64/src/espeak-ng \
      android/app/src/main/jniLibs/arm64-v8a/libvoiceagent_espeak.so

The lib*.so name is required, not stylistic: Android >= 10 only execs
from nativeLibraryDir (W^X), and gradle jniLibs.useLegacyPackaging
extracts it there at install (android/app/build.gradle.kts).

Obligations (GPLv3 for the bundled binary): ship the corresponding
source INCLUDING these build modifications with every release that
carries the binary, keep COPYING.gpl3 in the APK-facing tree, and do
not restrict recipients of this component.
