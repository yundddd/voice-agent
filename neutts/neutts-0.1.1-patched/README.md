# neutts-rs

[![Version](https://img.shields.io/badge/version-0.1.0-blue)](CHANGELOG.md)

Rust port of [NeuTTS](https://github.com/neuphonic/neutts) — on-device voice-cloning TTS
built on a GGUF LLM backbone and the [NeuCodec](https://huggingface.co/neuphonic/neucodec)
neural audio codec.

**Pure Rust — no ONNX Runtime, no native ML dependencies.**  
The codec runs as a self-contained CPU/GPU inference engine
(`safetensors` + `ndarray` + `rustfft`, with optional `burn`/`wgpu` GPU path).

**Pure-Rust phonemisation** — the `espeak` feature uses the [`espeak-ng`](https://crates.io/crates/espeak-ng)
crate with bundled data for all 114 languages.  No system library installation required.

---

## Quick start

### 1. Convert codec weights (one-time, ~2 min)

```sh
pip install torch huggingface_hub safetensors
python scripts/convert_weights.py
```

Downloads `neuphonic/neucodec`, extracts the decoder weights, and saves them as
`models/neucodec_decoder.safetensors`.

### 2. Build

```sh
cargo build --features espeak
```

No system dependencies needed — `espeak-ng` is pure Rust with bundled data.

### 3. Clone a voice and synthesise

The simplest path — point at any WAV file and say what you want:

```sh
cargo run --example speak --features espeak -- \
  --wav      my_voice.wav \
  --ref-text "Exactly what I said in the recording." \
  --text     "Hello, this is my cloned voice."
```

On the first run the reference WAV is encoded via the Python `neucodec` package
and cached as `my_voice.npy` beside the WAV.  Every subsequent run loads the
cache and skips encoding entirely.

**One-time Python install for encoding:**

```sh
pip install neucodec huggingface_hub torchaudio
```

---

## Examples

| Example | What it does |
|---------|-------------|
| [`speak`](#speak) | **Recommended.** WAV in → WAV out. Encodes on first run, caches `.npy`. Supports `--list-models`, `--list-files`, `--gguf-file`. |
| [`stream_pcm`](#stream_pcm) | **Streaming.** Preloads models once, streams raw PCM to stdout as audio is synthesised in chunks. |
| `basic` | Synthesise from a pre-encoded `.npy` reference |
| `clone_voice` | Full voice cloning — `.npy` or raw WAV + SHA-256 cache |
| `encode_reference` | Stub — returns a helpful error; use Python for now |
| `download_models` | Download / stage weights |
| `test_pipeline` | Smoke-test every component without model files |

### speak

```sh
# Minimal — encodes reference on first run, cached after that
cargo run --example speak --features espeak -- \
  --wav      my_voice.wav \
  --ref-text "What I said in the recording." \
  --text     "Hello, this is my cloned voice."

# Use a bundled sample voice (pre-encoded, no Python needed)
cargo run --example speak --features espeak -- \
  --wav      samples/jo.wav \
  --ref-text samples/jo.txt \
  --text     "Hello from Jo."

# Skip directly to a pre-encoded .npy
cargo run --example speak --features espeak -- \
  --codes    samples/dave.npy \
  --ref-text samples/dave.txt \
  --text     "Hello from Dave."

# List all known backbone models
cargo run --example speak --features espeak -- --list-models

# List GGUF files available in a specific repo
cargo run --example speak --features espeak -- \
  --backbone neuphonic/neutts-nano-q4-gguf --list-files

# Pick a specific GGUF quantisation
cargo run --example speak --features espeak -- \
  --wav       my_voice.wav \
  --ref-text  "What I said." \
  --text      "Hello." \
  --backbone  neuphonic/neutts-nano-q4-gguf \
  --gguf-file neutts-nano-Q4_K_M.gguf

# Different language backbone
cargo run --example speak --features espeak -- \
  --backbone neuphonic/neutts-nano-german-q4-gguf \
  --wav      samples/greta.wav \
  --ref-text samples/greta.txt \
  --text     "Hallo aus Rust."

# CPU-only (no wgpu)
cargo run --example speak --no-default-features --features espeak -- \
  --wav my_voice.wav --ref-text "..." --text "Hello."
```

**speak flags:**

| Flag | Short | Purpose |
|------|-------|---------|
| `--wav PATH` | `-w` | WAV file of the voice to clone |
| `--codes PATH` | `-c` | Pre-encoded `.npy` (skips encoding) |
| `--ref-text TEXT\|PATH` | `-r` | Transcript of the reference WAV (file or literal string). Auto-detected from `<stem>.txt` if omitted. |
| `--text TEXT` | `-t` | Text to synthesise |
| `--out PATH` | `-o` | Output WAV (default: `output.wav`) |
| `--backbone REPO` | `-b` | HuggingFace backbone repo (see `--list-models`) |
| `--gguf-file FILE` | `-g` | Specific `.gguf` filename within the repo |
| `--list-files` | | Print all `.gguf` files in `--backbone` and exit |
| `--list-models` | | Print table of all known backbone repos and exit |

### stream_pcm

Preloads the backbone and codec **once at startup**, then drives the backbone in
streaming mode: speech tokens are forwarded to the codec in chunks as they are
generated, and raw signed 16-bit little-endian PCM is written to stdout as each
chunk is ready.  Timing diagnostics (time-to-first-audio, RTF) go to stderr so
they do not corrupt the byte stream.

```sh
# Linux — aplay
cargo run --example stream_pcm --features espeak -- \
  --codes samples/dave.npy --ref-text samples/dave.txt \
  --text "Hello, streaming audio." | \
  aplay -f S16_LE -r 24000 -c 1

# macOS — sox
cargo run --example stream_pcm --features espeak -- \
  --codes samples/dave.npy --ref-text samples/dave.txt \
  --text "Hello, streaming audio." | \
  sox -t raw -r 24000 -e signed -b 16 -c 1 - -d

# Cross-platform — ffplay
cargo run --example stream_pcm --features espeak -- \
  --codes samples/dave.npy --ref-text samples/dave.txt \
  --text "Hello, streaming audio." | \
  ffplay -f s16le -ar 24000 -ac 1 -nodisp -

# Save to file, then convert
cargo run --example stream_pcm --features espeak -- \
  --codes samples/dave.npy --ref-text samples/dave.txt \
  --text "Hello." > output.pcm
sox -t raw -r 24000 -e signed -b 16 -c 1 output.pcm output.wav
```

**stream_pcm flags:**

| Flag | Short | Default | Purpose |
|------|-------|---------|---------|
| `--codes PATH` | `-c` | *(required)* | Pre-encoded `.npy` reference codes |
| `--text TEXT` | `-t` | *(required)* | Text to synthesise |
| `--ref-text TEXT\|PATH` | `-r` | auto | Transcript of the reference recording |
| `--backbone REPO` | `-b` | nano-q4 | HuggingFace backbone repo |
| `--gguf-file FILE` | `-g` | auto | Specific `.gguf` filename |
| `--chunk N` | `-k` | `25` | Tokens per decode chunk (25 ≈ 500 ms) |

**Chunk size trade-off:**

| `--chunk` | Audio buffered | Latency (TTFA) | Quality at boundaries |
|-----------|---------------|----------------|-----------------------|
| 10 | ~200 ms | lowest | mild artefacts possible |
| 25 | ~500 ms | balanced | good *(default)* |
| 50 | ~1 s | higher | best |

Each chunk is decoded independently by the NeuCodec transformer, so very small
chunks lose cross-chunk attention context.  Values ≥ 25 are recommended.

---

## Available models

Run `--list-models` to see the full table at any time:

```sh
cargo run --example speak -- --list-models
```

| Repo | Name | Language | Params | GGUF |
|------|------|----------|--------|------|
| `neuphonic/neutts-nano-q4-gguf` | NeuTTS Nano Q4 | en-us | 0.2B | ✅ |
| `neuphonic/neutts-nano-q8-gguf` | NeuTTS Nano Q8 | en-us | 0.2B | ✅ |
| `neuphonic/neutts-nano` | NeuTTS Nano (full) | en-us | 0.2B | |
| `neuphonic/neutts-air-q4-gguf` | NeuTTS Air Q4 | en-us | 0.7B | ✅ |
| `neuphonic/neutts-air-q8-gguf` | NeuTTS Air Q8 | en-us | 0.7B | ✅ |
| `neuphonic/neutts-air` | NeuTTS Air (full) | en-us | 0.7B | |
| `neuphonic/neutts-nano-german-q4-gguf` | NeuTTS Nano German Q4 | de | 0.2B | ✅ |
| `neuphonic/neutts-nano-german-q8-gguf` | NeuTTS Nano German Q8 | de | 0.2B | ✅ |
| `neuphonic/neutts-nano-german` | NeuTTS Nano German (full) | de | 0.2B | |
| `neuphonic/neutts-nano-french-q4-gguf` | NeuTTS Nano French Q4 | fr-fr | 0.2B | ✅ |
| `neuphonic/neutts-nano-french-q8-gguf` | NeuTTS Nano French Q8 | fr-fr | 0.2B | ✅ |
| `neuphonic/neutts-nano-french` | NeuTTS Nano French (full) | fr-fr | 0.2B | |
| `neuphonic/neutts-nano-spanish-q4-gguf` | NeuTTS Nano Spanish Q4 | es | 0.2B | ✅ |
| `neuphonic/neutts-nano-spanish-q8-gguf` | NeuTTS Nano Spanish Q8 | es | 0.2B | ✅ |
| `neuphonic/neutts-nano-spanish` | NeuTTS Nano Spanish (full) | es | 0.2B | |

To discover which specific GGUF quantisation variants are in a repo:

```sh
cargo run --example speak -- \
  --backbone neuphonic/neutts-nano-q4-gguf --list-files
```

Then pick one with `--gguf-file`:

```sh
cargo run --example speak --features espeak -- \
  --backbone  neuphonic/neutts-nano-q4-gguf \
  --gguf-file neutts-nano-Q4_K_M.gguf \
  --wav my_voice.wav --ref-text "..." --text "Hello."
```

---

## Bundled Languages (114)

The `espeak` feature bundles phoneme data for all 114 espeak-ng languages:

`af`, `am`, `an`, `ar`, `as`, `az`, `ba`, `be`, `bg`, `bn`, `bpy`, `bs`, `ca`, `chr`, `cmn`, `cs`, `cv`, `cy`, `da`, `de`, `el`, `en`, `eo`, `es`, `et`, `eu`, `fa`, `fi`, `fr`, `ga`, `gd`, `gn`, `grc`, `gu`, `hak`, `haw`, `he`, `hi`, `hr`, `ht`, `hu`, `hy`, `ia`, `id`, `io`, `is`, `it`, `ja`, `jbo`, `ka`, `kk`, `kl`, `kn`, `ko`, `kok`, `ku`, `ky`, `la`, `lb`, `lfn`, `lt`, `lv`, `mi`, `mk`, `ml`, `mr`, `ms`, `mt`, `mto`, `my`, `nci`, `ne`, `nl`, `no`, `nog`, `om`, `or`, `pa`, `pap`, `piqd`, `pl`, `pt`, `py`, `qdb`, `qu`, `quc`, `qya`, `ro`, `ru`, `sd`, `shn`, `si`, `sjn`, `sk`, `sl`, `smj`, `sq`, `sr`, `sv`, `sw`, `ta`, `te`, `th`, `ti`, `tk`, `tn`, `tr`, `tt`, `ug`, `uk`, `ur`, `uz`, `vi`, `yue`

> **Note**: 4 languages (`bs`, `io`, `lfn`, `pap`) have missing phoneme tables in `espeak-ng` 0.1.0.
> 17 languages with non-Latin scripts may return empty IPA for some inputs (upstream limitation).

---

## Architecture

```
text ──► espeak-ng (pure Rust) ──► IPA ──┐
                                          ├──► prompt builder ──► GGUF backbone ──► speech tokens
ref_codes (.npy) ─────────────────────────┘                          (llama-cpp-4)        │
                                                                                           ▼
                                                                               NeuCodec decoder
                                                                          (Burn wgpu GPU  ──or──
                                                                           Burn NdArray CPU ──or──
                                                                           raw ndarray CPU)
                                                                                           │
                                                                                           ▼
                                                                               audio (Vec<f32>, 24 kHz)
```

### GGUF backbone

Small causal LM in GGUF format, run via `llama-cpp-4`.  Takes a phonemized text
prompt and pre-encoded reference speaker codes, generates `<|speech_N|>` tokens
one at a time.  The `generate_streaming` API forwards each token to a callback
immediately, enabling low-latency audio delivery.

### NeuCodec decoder (pure Rust)

XCodec2-based architecture loaded at runtime from `models/neucodec_decoder.safetensors`.
With the `wgpu` feature the full forward pass runs on the GPU (Metal / Vulkan / DX12);
the final ISTFT always runs on CPU.

```
codes [T]
   └─► FSQ decode  (integer → 8 scaled digits → project_out Linear 8→2048)
         │
    fc_post_a  (Linear 2048→1024)
         │
   VocosBackbone
    ├─ Conv1d(k=7)
    ├─ 2 × ResnetBlock  (GroupNorm → SiLU → Conv1d)
    ├─ 12 × TransformerBlock  (RMSNorm → MHA + RoPE → SiLU MLP)
    │        └─ RoPE tables pre-computed at load time (see `fast`/`precise` features)
    └─ 2 × ResnetBlock + LayerNorm
         │
   ISTFTHead
    ├─ Linear(1024 → n_fft+2)
    └─ ISTFT (same padding, Hann window, always CPU)
         │
   audio [T × hop_length]  (24 kHz)
```

| Property | Value |
|----------|-------|
| Output sample rate | 24 000 Hz |
| Tokens / second | 50 |
| Samples / token | 480 (hop_length) |
| FSQ codebook size | 4⁸ = 65 536 codes |
| Encoder input | 16 000 Hz mono WAV |

---

## Bundled reference voices

Five pre-encoded voices are included and work without any Python encoding step:

| Files | Voice | Language |
|-------|-------|----------|
| `samples/jo.*` | Jo | English |
| `samples/dave.*` | Dave | English |
| `samples/juliette.*` | Juliette | French |
| `samples/greta.*` | Greta | German |
| `samples/mateo.*` | Mateo | Spanish |

Each has a `.wav` (original audio), `.npy` (pre-encoded tokens), and `.txt` (transcript).

---

## Feature flags

| Feature | Default | Description |
|---------|---------|-------------|
| `backbone` | ✓ | GGUF backbone via `llama-cpp-4` (requires cmake + C++) |
| `espeak` | | Raw-text input via pure-Rust `espeak-ng` (114 bundled languages, no system deps) |
| `wgpu` | | GPU-accelerated codec via Burn wgpu (Metal/Vulkan/DX12); auto-falls back to Burn NdArray CPU, then raw ndarray |
| `metal` | | macOS Metal GPU for the backbone |
| `cuda` | | NVIDIA CUDA for the backbone |
| `vulkan` | | Vulkan GPU for the backbone (Linux/Windows, requires `libvulkan1`) |
| `fast` | ✓ | RoPE: degree-7/6 Horner polynomial (~1 × 10⁻⁴ error, no transcendental calls) |
| `precise` | | RoPE: stdlib `f32::sin_cos()`, correctly rounded; mutually exclusive with `fast` |

**`fast` vs `precise`:**  Both affect how sin/cos values are computed when
building the Rotary Positional Embedding tables in the NeuCodec transformer.
The polynomial path (`fast`) avoids transcendental function calls — 6 FMAs per
value — and is measurably faster at load time on platforms where hardware sin/cos
is slow.  The accuracy difference is imperceptible in speech synthesis.  Pass
`--features precise` to opt into full IEEE 754 accuracy:

```sh
cargo run --example speak --features "espeak,precise" -- ...
```

Setting both `fast` and `precise` simultaneously is a compile-time error.

**Without `backbone`** — codec-only mode; use `NeuCodecDecoder::decode()` directly.

**Without `espeak`** — pass pre-phonemized IPA via `tts.infer_from_ipa()`.

---

## Performance

Measured on a MacBook Pro M2 with the `wgpu` feature (Metal GPU) and
`neutts-nano-Q4_0.gguf` (0.2B parameters, 372 reference tokens, ~125 output tokens):

| Version | Synth time | RTF | Notes |
|---------|-----------|-----|-------|
| 0.0.1 | 4.45 s | 1.79× | GPU init (1.72 s) counted against synthesis |
| 0.0.2 | ~2.7 s | ~1.1× | GPU init moved to load time; RoPE uploads eliminated |

---

## Build requirements

| Platform | Backbone | Codec | Phonemizer (`espeak` feature) |
|----------|----------|-------|-------------------------------|
| All | cmake + C++ (auto) | pure Rust | **None** — pure Rust with bundled data |

The `espeak` feature requires zero system dependencies.  The `backbone` feature
requires cmake + a C++ compiler for llama.cpp.

### Cross-platform builds

Since phonemisation is now pure Rust, cross-compilation is straightforward:

```sh
# iOS
rustup target add aarch64-apple-ios
cargo build --target aarch64-apple-ios --features espeak

# Android
rustup target add aarch64-linux-android
cargo build --target aarch64-linux-android --features espeak

# Linux aarch64
rustup target add aarch64-unknown-linux-gnu
cargo build --target aarch64-unknown-linux-gnu --features espeak

# Windows (from any host)
rustup target add x86_64-pc-windows-gnu
cargo build --target x86_64-pc-windows-gnu --features espeak
```

No `ESPEAK_LIB_DIR`, no sysroot, no cross-compiled C library needed.

---

## Using the library

### Full pipeline

```rust
use neutts::{NeuTTS, download};
use std::path::Path;

// Download backbone from HuggingFace (cached after first run).
// Pass None to auto-select the first GGUF in the repo,
// or Some("filename.gguf") to pick a specific quantisation.
let tts = download::load_from_hub_cb(
    "neuphonic/neutts-nano-q4-gguf",
    None,       // or Some("neutts-nano-Q4_K_M.gguf")
    |_| {},
).unwrap();

// Load pre-encoded reference codes
let ref_codes = tts.load_ref_codes(Path::new("samples/jo.npy")).unwrap();

// Synthesise — returns Vec<f32> at 24 kHz mono
let audio = tts.infer(
    "Hello from Rust!",
    &ref_codes,
    "Transcript of the reference recording.",
).unwrap();

// Save to WAV
tts.write_wav(&audio, Path::new("output.wav")).unwrap();
```

### Streaming synthesis

The backbone exposes a token-by-token streaming API that lets you start
decoding audio before the model has finished generating:

```rust
use neutts::{tokens, download};
use std::io::Write as _;

let tts = download::load_from_hub_cb("neuphonic/neutts-nano-q4-gguf", None, |_| {}).unwrap();
let ref_codes = tts.load_ref_codes("samples/dave.npy".as_ref()).unwrap();
let ref_ipa   = neutts::phonemize::phonemize("Reference transcript.", "en-us").unwrap();
let input_ipa = neutts::phonemize::phonemize("Hello, streaming!", "en-us").unwrap();
let prompt    = tokens::build_prompt(&ref_ipa, &input_ipa, &ref_codes);

let mut pending   = Vec::<i32>::new();
let     codec     = &tts.codec;
let     stdout    = std::io::stdout();
let mut out       = std::io::BufWriter::new(stdout.lock());

tts.backbone.generate_streaming(&prompt, 2048, |piece| {
    pending.extend(tokens::extract_ids(piece));

    if pending.len() >= 25 {          // 25 tokens ≈ 500 ms of audio
        let audio = codec.decode(&pending)?;
        for s in &audio {
            let s16 = (s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
            out.write_all(&s16.to_le_bytes())?;
        }
        out.flush()?;
        pending.clear();
    }
    Ok(())
})?;
```

See [`examples/stream_pcm.rs`](examples/stream_pcm.rs) for the full
self-contained example with timing diagnostics and player instructions.

### Discover models programmatically

```rust
use neutts::download::{BACKBONE_MODELS, list_gguf_files, find_model};

// Iterate the registry
for m in BACKBONE_MODELS {
    println!("{} ({}) — GGUF: {}", m.repo, m.language, m.is_gguf);
}

// Find a specific repo
if let Some(info) = find_model("neuphonic/neutts-nano-q4-gguf") {
    println!("language: {}", info.language); // "en-us"
}

// List GGUF files available in a repo (network call)
let files = list_gguf_files("neuphonic/neutts-nano-q4-gguf").unwrap();
for f in &files { println!("{f}"); }
```

### IPA passthrough (without espeak)

```rust
let audio = tts.infer_from_ipa(
    "hɛloʊ fɹʌm ɹʌst",    // input IPA
    &ref_codes,
    "wɪ ɑːɹ tɛstɪŋ ðɪs",  // reference IPA
).unwrap();
```

### Decoder only

```rust
use neutts::NeuCodecDecoder;

let dec = NeuCodecDecoder::new().unwrap();
println!("backend: {}", dec.backend_name()); // e.g. "burn/wgpu (GPU)"
println!("{} samples/token", dec.hop_length());

let codes: Vec<i32> = vec![/* speech token IDs */];
let audio: Vec<f32> = dec.decode(&codes).unwrap();
```

### Reference-code cache

```rust
use neutts::RefCodeCache;
use std::path::Path;

let cache = RefCodeCache::new()?;
if let Some((codes, outcome)) = cache.try_load(Path::new("reference.wav"))? {
    println!("{outcome}"); // "Cache hit (SHA-256: …)"
}
```

---

## Mobile / C FFI

A practical mobile architecture runs the backbone server-side and only the
NeuCodec decoder on-device:

```c
NeuTtsHandle *codec = neutts_model_load("/path/to/neucodec_decoder.safetensors");

float *audio = neutts_decode_tokens(codec, codes, num_codes, &n_samples);
neutts_write_wav(audio, n_samples, "/path/to/output.wav");
neutts_free_audio(audio, n_samples);
neutts_model_free(codec);
```

See [`include/neutts.h`](include/neutts.h) for the full C header.

---

## Pipeline stages

1. **Text preprocessing** — numbers, currencies, abbreviations → spoken words
2. **Phonemisation** — pure-Rust espeak-ng converts text to IPA phonemes
3. **Prompt construction** — reference codes + IPA → GGUF prompt
4. **Backbone inference** — GGUF LLM generates `<|speech_N|>` tokens
5. **Token extraction** — regex extracts integer IDs from generated text
6. **Codec decode** — NeuCodec decoder converts IDs to 24 kHz audio

---

## Migration from C `libespeak-ng`

This crate previously used C FFI bindings to `libespeak-ng` with a 749-line
`build.rs` for native library detection and cross-compilation. It now uses the
pure-Rust [`espeak-ng`](https://crates.io/crates/espeak-ng) crate instead:

- **No system library required** — `brew install espeak-ng` / `apt install libespeak-ng-dev` no longer needed
- **No C compiler needed** for phonemisation — no `cmake`, no `gcc`, no build scripts
- **No unsafe code** in phonemisation — the entire FFI layer was removed
- **build.rs reduced from 749 lines to 48** — only RoPE checks and weight detection remain
- **Cross-compilation just works** — no `ESPEAK_LIB_DIR`, no `ESPEAK_SYSROOT`, no NDK toolchain setup
- **114 languages bundled** — all espeak-ng languages ship as embedded data

---

## Status

| Component | Status |
|-----------|--------|
| GGUF backbone inference | ✅ |
| NeuCodec decoder (pure Rust, safetensors) | ✅ |
| NeuCodec encoder (pure Rust) | ⏳ `speak` example falls back to Python `neucodec` |
| GPU-accelerated codec (`wgpu` feature) | ✅ Metal / Vulkan / DX12 via Burn |
| Streaming backbone API (`generate_streaming`) | ✅ |
| Streaming PCM output (`stream_pcm` example) | ✅ |
| Pure-Rust phonemisation (114 languages) | ✅ |
| English backbones (Nano / Air, Q4 / Q8) | ✅ |
| German / French / Spanish backbones | ✅ |
| Cross-platform builds | ✅ No native espeak deps |
| Test suite (unit + integration + e2e) | ✅ 114 tests |
| iOS / Android build | ✅ codec + phonemiser are pure Rust; backbone needs cross-compile |

---

## Citation

If you use this software in your research or project, please cite it as:

```bibtex
@software{hauptmann2026neuttsrs,
  author       = {Hauptmann, Eugene},
  title        = {{neutts}: Rust port of {NeuTTS} — on-device voice-cloning {TTS}
                  with {GGUF} backbone and {NeuCodec} decoder},
  year         = {2026},
  version      = {0.1.0},
  license      = {MIT},
  url          = {https://github.com/eugenehp/neutts-rs}
}
```

If you also use the underlying NeuTTS model or NeuCodec, please cite those works
directly via their respective HuggingFace repositories at
[huggingface.co/neuphonic](https://huggingface.co/neuphonic).

---

## License

MIT
