# Changelog

All notable changes to **neutts-rs** are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).  
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- Pure-Rust NeuCodec encoder (removes Python dependency for reference encoding).
- iOS / Android build guides and pre-built XCFramework.

---

## [0.0.7] — 2026-03-10

### Changed

#### `llama-cpp-4` dependency: `0.2.0` → `0.2.5`
- Pinned `llama-cpp-4` to `"0.2.5"` in `Cargo.toml`; `llama-cpp-sys-4` is
  correspondingly bumped from `0.2.0` to `0.2.5`, bringing in the latest
  llama.cpp snapshot.
- The 0.2.x API is backward-compatible: all existing call sites in
  `src/backbone.rs` compile unchanged.

#### `src/backbone.rs` — sampler: add top-p (llama-cpp-4 0.2.5)
- `LlamaSampler::top_p(0.9, 1)` is now inserted between `top_k` and `temp`
  in both `generate` and `generate_streaming`.  The chain is now:
  `top_k(50) → top_p(0.9) → temp(1.0) → dist(seed)`.
- Seed derivation now goes through `LlamaSamplerParams::default()
  .with_seed(rand::random()).seed()` — this uses the new `LlamaSamplerParams`
  type introduced in 0.2.5 and gives the sampler a deterministic seed when
  `BackboneModel::seed` is `None`.
- `token_to_piece` helper refactored to call `token_to_str_with_size` (the
  higher-level string-returning API) instead of `token_to_bytes_with_size`
  followed by a lossy UTF-8 conversion.  The retry-on-small-buffer logic is
  preserved.

### Added

#### `vulkan` Cargo feature
- New `vulkan = ["llama-cpp-4?/vulkan"]` feature enables the Vulkan GPU
  backend for the GGUF backbone on Linux and Windows (requires a Vulkan
  runtime, e.g. `apt install libvulkan1`):
  ```
  cargo build --features "backbone,vulkan"
  ```
  Complements the existing `metal` (macOS) and `cuda` (NVIDIA) features.

---

## [0.0.6] — 2026-03-10

### Added — test suite (`tests/`)

Five new integration / end-to-end test files covering all pure-Rust modules
(no model weights or network access required):

| File | Tests | Coverage |
|------|-------|----------|
| `tests/integration_npy.rs` | 9 | NPY v1.0 round-trips, magic bytes, 64-byte header alignment, error paths (bad magic, truncated file, missing file) |
| `tests/integration_cache.rs` | 6 | `RefCodeCache` store → hit → evict → clear lifecycle; content-addressed keying; SHA-256 path derivation; `CacheOutcome` display |
| `tests/integration_preprocess.rs` | 24 | Full `TextPreprocessor` pipeline: integers, negatives, ordinals, percentages, currencies (with cents), SI units, contractions, scientific notation, time, scale suffixes, HTML removal, URL removal, whitespace normalisation, empty/whitespace-only input |
| `tests/integration_tokens.rs` | 16 | `ids_to_token_str` / `extract_ids` round-trips over the full 0–1023 vocabulary and the wider 0–65 535 FSQ range; `build_prompt` structural markers and ordering invariants |
| `tests/e2e_codec.rs` | 10 | Token pipeline, WAV bytes builder (44-byte header structure, peak normalisation, no-amplification invariant), NPY persistence, cache lifecycle, realistic TTS input preprocessing |

Total: **106 tests** (41 existing unit tests + 65 new integration/e2e).  
All pass: `cargo test --lib --tests --no-default-features --features fast`

### Added — Windows cross-compilation via Zig

Building for `x86_64-pc-windows-gnu` from a Linux or macOS host no longer
requires a MinGW-w64 toolchain.  Zig's built-in C compiler (`zig cc`) serves
as the cross-compiler.

- `.cargo/config.toml` — new `[target.x86_64-pc-windows-gnu]` section wires
  `x86_64-w64-mingw32-gcc` / `x86_64-w64-mingw32-ar` as linker and archiver.
  A matching `[target.x86_64-unknown-linux-musl]` section covers Linux x86_64
  cross-compilation from an ARM64 host.
- Thin shell wrappers (`x86_64-w64-mingw32-{gcc,g++,ar}`) translate MinGW-w64
  invocations from `cc-rs` into Zig-style calls (`zig cc -target
  x86_64-windows-gnu`).  The wrappers drop the `--target=x86_64-pc-windows-gnu`
  flag that `cc-rs` injects but Zig does not recognise (Zig uses
  `x86_64-windows-gnu`).
- Validated: `cargo build --target x86_64-pc-windows-gnu --no-default-features
  --features fast --release` produces a valid 40 MB PE/COFF static archive
  (`libneutts.a`) containing x86-64 COFF object files.

### Added — multi-platform espeak-ng build system (`build.rs`, `scripts/`)

#### Windows native (MSVC)
- `build.rs` detects `target_env = msvc` and looks for `espeak-ng.lib` /
  `espeak-ng-merged.lib` instead of `libespeak-ng.a`.
- Archive merging uses `lib.exe` (or `llvm-lib.exe`) instead of `libtool`/`ar`.
- No `stdc++` link flag emitted on MSVC — the MSVC CRT is auto-linked by
  `link.exe` when it finds C++ objects.
- New `scripts/build-espeak-windows.ps1` — PowerShell script that clones
  espeak-ng, builds with CMake + MSVC (or Ninja), merges the three produced
  `.lib` files into `espeak-ng-merged.lib`, and copies data + headers into
  `espeak-static/` ready for `cargo build`.

#### Windows path-length fix (`\\?\` bug)
- `build.rs` no longer calls `std::fs::canonicalize()` anywhere in the
  build-from-source path.  `canonicalize()` on Windows returns `\\?\`-prefixed
  extended-length paths; MSVC `cl.exe` rejects these with "Cannot open source
  file" even when the file exists.  All intermediate paths now derive from
  `OUT_DIR` (already absolute, no prefix) or `ESPEAK_BUILD_DIR`.
- New `ESPEAK_BUILD_DIR` env var — overrides the cmake build root, useful when
  `OUT_DIR` itself is deeply nested.

#### Cross-compilation (Linux/macOS → Windows-GNU)
- `build.rs` detects `target_os = windows` + `target_env = gnu` and injects
  the MinGW cross-compiler into cmake via `ESPEAK_CROSS_PREFIX` (default:
  `x86_64-w64-mingw32-`).
- New `scripts/cmake/mingw-toolchain.cmake` — CMake toolchain file for the
  MinGW-w64 cross-compiler.
- `scripts/build-espeak.sh` accepts `CROSS_TARGET=x86_64-w64-mingw32` to
  build `libespeak-ng-merged.a` targeting Windows-GNU from any Unix host.

#### CI matrix (`.github/workflows/ci.yml`)
- Four jobs covering the supported build matrix:
  - `macos`             — macOS arm64, native
  - `linux`             — Linux x86_64, native
  - `windows-msvc`      — Windows x86_64 MSVC (`windows-2022` runner)
  - `windows-gnu-cross` — Linux → Windows x86_64-pc-windows-gnu, compile-only

### Fixed

#### `src/download.rs` — dead-code warnings under `--no-default-features`
- `backbone_language()` and `convert_checkpoint()` are only reachable when the
  `backbone` feature is enabled.  Both are now gated with
  `#[cfg(feature = "backbone")]`, eliminating `#[warn(dead_code)]` warnings in
  every feature-stripped build (e.g. codec-only or CI test runs).

#### `examples/encode_reference.rs` — unused import
- Removed the unused `Path` from `use std::path::{Path, PathBuf}`, which
  emitted `#[warn(unused_imports)]` during `cargo check --examples`.

#### `src/preprocess.rs` — ordinal suffix: missing `y → ieth` rule
- `ordinal_suffix()` now handles words ending in `'y'` correctly:
  "twenty" → "twentieth", "thirty" → "thirtieth", "forty" → "fortieth", etc.
  Previously these produced "twentyth", "thirtyth", etc.
  The `'y'` is dropped and `"ieth"` appended, matching standard English.
  Verified by the new `prep_ordinal_4th_to_20th` integration test.

---

## [0.0.5] — 2026-03-09

### Changed

#### Backbone dependency: `llama-cpp-2` → `llama-cpp-4`
- Replaced `llama-cpp-2 v0.1` with `llama-cpp-4 v0.2` as the GGUF backbone
  binding crate (`Cargo.toml`, `src/backbone.rs`).
- `token_to_piece_bytes(token, N, true, None)` replaced by
  `token_to_bytes_with_size(token, N, Special::Tokenize, None)` — the
  function was renamed in llama-cpp-4 and the `bool` special-token flag
  became the typed `Special` enum.
- `Special` imported alongside `AddBos`, `LlamaModel`, and
  `LlamaModelParams` from `llama_cpp_4::model`.
- `metal` and `cuda` feature pass-throughs updated:
  `llama-cpp-2?/metal` → `llama-cpp-4?/metal`,
  `llama-cpp-2?/cuda` → `llama-cpp-4?/cuda`.
- All doc comments and the README architecture diagram updated to reference
  `llama-cpp-4`.

---

## [0.0.2] — 2026-03-05

### Added

#### Streaming backbone API (`src/backbone.rs`)
- `BackboneModel::generate_streaming<F: FnMut(&str) -> Result<()>>(prompt,
  max_new_tokens, on_piece)` — calls `on_piece` with each decoded text piece
  immediately as it is produced, rather than accumulating the full output.
  Enables audio to begin playing before the backbone finishes generating.
  Errors returned from the callback propagate out of `generate_streaming`
  unchanged, allowing clean abort from within the closure.
  The stop token (`<|SPEECH_GENERATION_END|>`) is never forwarded; any text
  preceding it within the same piece is correctly emitted first.

#### `stream_pcm` example (`examples/stream_pcm.rs`)
- New example demonstrating the preload-once, stream-forever pattern:
  1. Models (backbone + codec) are loaded once at startup; all subsequent
     synthesis calls pay no loading cost.
  2. Backbone runs in streaming mode via `generate_streaming`.
  3. Speech tokens accumulate in a pending buffer; once the buffer reaches
     `--chunk` tokens the codec decodes the chunk and writes raw signed
     16-bit little-endian PCM to stdout.
  4. Timing diagnostics (time-to-first-audio, RTF) are printed to stderr
     so they do not corrupt the byte stream.
- `--chunk N` flag (default: 25 tokens = 500 ms): controls the
  latency/quality trade-off at chunk boundaries.
- Pipe to `aplay` (Linux), `sox -d` (macOS), or `ffplay` for real-time
  playback; redirect to a `.pcm` file and convert with `sox`/`ffmpeg`.

#### RoPE computation feature flags (`Cargo.toml`, `src/codec.rs`, `build.rs`)
- `fast` feature (default): RoPE sin/cos computed via a degree-7/6 Horner-form
  polynomial with f32 range reduction.  No transcendental function calls; 6 FMAs
  per sin and per cos value.  Max absolute error ≈ 1 × 10⁻⁴ — imperceptible in
  speech synthesis.
- `precise` feature: RoPE sin/cos delegates to `f32::sin_cos()`, which is
  correctly rounded (ULP ≤ 1) on x86 SSE/AVX, ARM NEON, and Apple Silicon.
- `pub(crate) fn rope_sin_cos(x: f32) -> (f32, f32)` — single dispatch point
  in `codec.rs` shared by the CPU decoder (`apply_rope`) and the GPU decoder
  precompute pass (`load_weights`), ensuring both paths always use the same
  algorithm.
- Build-time conflict check in `build.rs`: setting both `fast` and `precise`
  simultaneously is a hard compile-time error with a clear message.

### Changed

#### `NeuCodecDecoder` — eager GPU backend initialisation (`src/codec.rs`)
- **Before**: the Burn wgpu/NdArray backend was initialised lazily on the
  first call to `decode()`, meaning the ~1.7 s GPU upload was silently
  counted inside synthesis time ("synth took X s").
- **After**: `NeuCodecDecoder::from_file()` initialises the backend
  immediately after loading weights.  GPU upload time now appears in "loaded
  in X s" and no longer inflates the synthesis RTF.
  Measured on M2 (Metal, neutts-nano-Q4_0): synthesis RTF improved from
  **1.79×** to **~1.1×** real-time.

#### Pre-computed RoPE tables (`src/codec_burn.rs`)
- `BurnWeights` gains `rope_cos: Tensor<B, 2>` and `rope_sin: Tensor<B, 2>`
  fields (shape `[2048, head_dim/2]`), computed once in `load_weights()` and
  stored as device tensors.
- `t_apply_rope` now accepts pre-sliced `&Tensor<B, 2>` cos/sin rather than
  recomputing and re-uploading them from CPU on every call.
- `t_transformer_block` forwards the pre-sliced tables to both the Q and K
  `t_apply_rope` calls.
- `burn_decode` slices the tables to the current sequence length once (a
  single O(1) view op) and passes the slices into the transformer fold.
- **Net result**: 24 CPU→GPU uploads eliminated per decode call
  (12 transformer blocks × Q and K projections), reducing GPU command-buffer
  pressure and host-to-device synchronisation stalls.
- The single-pass `theta.iter().map(rope_sin_cos).unzip()` replaces the two
  separate `.map(|v| v.cos()).collect()` / `.map(|v| v.sin()).collect()`
  passes, halving the number of iterations over the theta table.

#### `BurnWeights` struct (`src/codec_burn.rs`)
- Added fields: `rope_cos`, `rope_sin`, `head_dim`.
- The `head_dim` field (`hidden / n_heads`) is derived from `DecoderWeights`
  at load time and stored to avoid repeated division inside `burn_decode`.

#### `burn_decode` (`src/codec_burn.rs`)
- `t` (sequence length) is now computed once at the top of the function from
  `codes.len()` and reused throughout, avoiding the shadowed `let [t, n_out]`
  destructure at step 9.
- Local variable `half` at step 10 renamed to `n_bins` for clarity (it
  represents the number of STFT frequency bins, not `head_dim/2`).

### Removed

#### `LazyBurnDecoder::Pending` variant (`src/codec.rs`)
- The `Pending` variant was never constructed after the eager-init refactor.
  Removed to eliminate the dead-code warning.  `backend_name()` and
  `decode()` updated to match the now-exhaustive enum.

### Fixed

- `backend_name()` no longer returns the misleading string
  `"burn/wgpu (pending — lazy init)"` in any reachable code path.

---

## [0.0.1] — 2026-03-04

### Added

#### NeuCodec decoder — pure-Rust CPU inference (`src/codec.rs`)
- Full XCodec2-based decoder implemented from scratch in safe Rust:
  - **FSQ decode** — integer codes (0–65 535) decomposed into 8 base-4 digits,
    scaled to {−1, −⅓, ⅓, 1}, projected via a learned linear layer.
    Supports both `generator.quantizer.fsqs.0.project_out.*` (older exports) and
    the flat `generator.quantizer.project_out.*` key layout automatically.
  - **VocosBackbone** — Conv1d(k=7) → 2 × ResnetBlock → 12 × TransformerBlock
    (RMSNorm + multi-head attention + RoPE + SiLU MLP) → 2 × ResnetBlock →
    LayerNorm.
  - **ISTFTHead** — Linear(hidden → n_fft+2) → split magnitude/phase → ISTFT
    with same-padding and Hann window.
  - **ISTFT** — overlap-add synthesis with window-envelope normalisation;
    produces 24 kHz mono `Vec<f32>`.
- Runtime weight loading from `models/neucodec_decoder.safetensors`; no
  recompilation needed when weights change.
- Supports both `F32` and `BF16` tensor dtypes in the safetensors file.
- Architecture hyper-parameters (`hidden_dim`, `depth`, `n_heads`,
  `hop_length`) auto-detected from weight shapes at load time.
- `n_heads` optionally overridden via `__metadata__` key in the safetensors
  header.
- Decoder output constants exported: `SAMPLE_RATE` (24 000 Hz),
  `ENCODER_SAMPLE_RATE` (16 000 Hz), `SAMPLES_PER_TOKEN` (480),
  `ENCODER_SAMPLES_PER_TOKEN` (320).
- Naive linear resampler (`resample()`) for 16 kHz → 24 kHz (or any ratio).
- `NeuCodecEncoder` stub with clear error message directing users to the Python
  `neucodec` package until a pure-Rust encoder is available.
- Full unit-test suite covering FSQ decode, `linear`, `conv1d`, `group_norm`,
  `layer_norm`, `rms_norm`, RoPE, Hann window, ISTFT length, and resampler.

#### Model registry (`src/download.rs`)
- `ModelInfo` struct capturing `repo`, `name`, `language`, `params`, and
  `is_gguf` for every known backbone.
- `BACKBONE_MODELS` static registry covering all 15 official repos:
  English: Nano Q4/Q8/full, Air Q4/Q8/full; German, French, Spanish: Nano Q4/Q8/full.
- `find_model(repo)` — O(n) registry lookup by repo ID.
- `backbone_language(repo)` — derives espeak-ng language code from the registry.
- `load_from_hub_cb` with `gguf_file: Option<&str>` — auto-select or pin a
  specific quantisation variant.
- `list_gguf_files(repo)` — returns all `.gguf` filenames in a repo.
- `print_model_table()` — prints a formatted ASCII table of all known models.

#### `speak` example (`examples/speak.rs`)
- End-to-end: WAV in → WAV out.  Reference is encoded on first run and cached
  as `<stem>.npy`; subsequent runs skip encoding entirely.
- `--wav`, `--codes`, `--ref-text`, `--text`, `--out`, `--backbone`,
  `--gguf-file`, `--list-files`, `--list-models` flags.

#### Weight conversion script (`scripts/convert_weights.py`)
- Downloads `neuphonic/neucodec` and extracts decoder weights from
  `pytorch_model.bin` into `models/neucodec_decoder.safetensors` with
  `n_heads` recorded in `__metadata__`.

#### Reference-code cache (`src/cache.rs`)
- `RefCodeCache` — SHA-256 keyed disk cache for pre-encoded reference codes.

#### NPY I/O (`src/npy.rs`)
- `load_npy` / `load_npy_i32` / `write_npy_i32` / `load_npz`.

#### Bundled sample voices
- Jo, Dave, Juliette, Greta, Mateo — `.wav`, `.npy`, `.txt` for each.

#### C FFI (`src/ffi.rs`, `include/neutts.h`)
- `neutts_model_load`, `neutts_model_free`, `neutts_decode_tokens`,
  `neutts_write_wav`, `neutts_free_audio`.

#### Other
- `clone_voice`, `encode_reference`, `download_models`, `test_pipeline` examples.
- `src/preprocess.rs` — number, currency, and abbreviation normalisation.
- `src/phonemize.rs` — espeak-ng bindings; `is_espeak_available()` probe.
- `src/tokens.rs` — prompt builder and `<|speech_N|>` token extractor.
- `src/backbone.rs` — `BackboneModel` wrapping `llama-cpp-2`.

### Fixed

- **FSQ weight key** — tries `generator.quantizer.fsqs.0.project_out.*` first,
  falls back to `generator.quantizer.project_out.*`, resolving
  `TensorNotFound` on all current NeuCodec checkpoints.

### Changed

- `load_from_hub_cb` gains `gguf_file: Option<&str>` parameter.
- `backbone_language()` driven by `BACKBONE_MODELS` registry.
- README fully rewritten with quick-start, model table, and API examples.
