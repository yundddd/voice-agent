//! Basic NeuTTS example — downloads the backbone and synthesises speech.
//!
//! The NeuCodec Burn decoder and encoder are compiled directly into the binary
//! at build time (`cargo run --example download_models && cargo build`), so no
//! ONNX Runtime or separate model files are needed at runtime.
//!
//! ## Backend selection
//!
//! By default the **Wgpu** (GPU) backend is tried first and falls back to
//! **NdArray** (pure-Rust CPU) if no GPU stack is available.  The active
//! backend is printed in the configuration block.  Force CPU-only with:
//!
//! ```sh
//! cargo run --example basic --no-default-features --features espeak
//! ```
//!
//! ## Usage
//!
//! ```sh
//! # Default: NeuTTS-Nano Q4, bundled Jo voice
//! cargo run --example basic --features espeak
//!
//! # Custom text and reference codes
//! cargo run --example basic --features espeak -- \
//!   --text       "The quick brown fox jumps over the lazy dog." \
//!   --ref-codes  samples/jo.npy \
//!   --ref-text   samples/jo.txt \
//!   --output     output.wav
//!
//! # Different backbone (Air model)
//! cargo run --example basic --features espeak -- \
//!   --backbone neuphonic/neutts-air-q4-gguf
//!
//! # CPU-only (NdArray, no GPU)
//! cargo run --example basic --no-default-features --features espeak
//! ```
//!
//! ## Requirements
//!
//! - espeak-ng installed (`brew install espeak-ng` / `apt install espeak-ng`)
//! - Reference codes as a `.npy` file — generate once with `encode_reference`
//! - Internet access on first run (backbone is cached by HuggingFace Hub)

use std::path::{Path, PathBuf};

fn main() -> anyhow::Result<()> {
    // ── Parse CLI arguments ───────────────────────────────────────────────────
    let mut args = std::env::args().skip(1).peekable();

    let mut backbone      = "neuphonic/neutts-nano-q4-gguf".to_string();
    let mut text          = "Hello from Rust! NeuTTS brings voice cloning to your local device.".to_string();
    let mut ref_codes_path = PathBuf::from("samples/jo.npy");
    let mut ref_text_path  = PathBuf::from("samples/jo.txt");
    let mut output        = "output.wav".to_string();

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--backbone"         => { if let Some(v) = args.next() { backbone = v; } }
            "--text"             => { if let Some(v) = args.next() { text = v; } }
            "--ref-codes"        => { if let Some(v) = args.next() { ref_codes_path = PathBuf::from(v); } }
            "--ref-audio"        => {
                // Accept a .wav path and derive the .npy from the same stem.
                if let Some(v) = args.next() {
                    ref_codes_path = Path::new(&v).with_extension("npy");
                }
            }
            "--ref-text"         => { if let Some(v) = args.next() { ref_text_path = PathBuf::from(v); } }
            "--output" | "--out" => { if let Some(v) = args.next() { output = v; } }
            "--help" | "-h"      => { print_help(); return Ok(()); }
            other => {
                eprintln!("Unknown argument: {other}  (use --help for usage)");
                std::process::exit(1);
            }
        }
    }

    // ── Check espeak-ng ───────────────────────────────────────────────────────
    #[cfg(feature = "espeak")]
    if !neutts::phonemize::is_espeak_available("en-us") {
        eprintln!(
            "WARNING: espeak-ng not found.\n\
             Install:  brew install espeak-ng      (macOS)\n\
             Or:       apt  install espeak-ng      (Debian/Ubuntu)\n\
             Or:       apk  add     espeak-ng      (Alpine)"
        );
    }

    // ── Resolve reference text ────────────────────────────────────────────────
    let ref_text = if ref_text_path.exists() {
        std::fs::read_to_string(&ref_text_path)
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    } else {
        ref_text_path.to_string_lossy().into_owned()
    };
    if ref_text.is_empty() {
        anyhow::bail!(
            "Reference text is empty.  Provide --ref-text <PATH|TEXT> or create {}",
            ref_text_path.display()
        );
    }

    // ── Print configuration ───────────────────────────────────────────────────
    println!("Backbone    : {backbone}");
    println!("Codec       : Burn {}", burn_backend_label());
    println!("Text        : {text:?}");
    println!("Ref codes   : {}", ref_codes_path.display());
    println!("Ref text    : {ref_text:?}");
    println!("Output      : {output}");
    println!();

    // ── Download / load models ────────────────────────────────────────────────
    println!("Loading models…");
    let tts = neutts::download::load_from_hub_cb(&backbone, None, |p| {
        use neutts::download::LoadProgress;
        match &p {
            LoadProgress::Fetching { step, total, file, repo } =>
                println!("  [{step}/{total}] Fetching {file} from {repo}…"),
            LoadProgress::Loading { step, total, component } =>
                println!("  [{step}/{total}] Loading {component}…"),
        }
    })?;
    println!("  → codec backend : {}", tts.codec.backend_name());
    println!();

    // ── Load reference codes ──────────────────────────────────────────────────
    if !ref_codes_path.exists() {
        let available: Vec<String> = std::fs::read_dir("samples")
            .into_iter().flatten().flatten()
            .filter_map(|e| {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) == Some("npy") {
                    Some(format!("  samples/{}", p.file_name()?.to_string_lossy()))
                } else { None }
            })
            .collect();
        let hint = if available.is_empty() { String::new() } else {
            format!("\n\nAvailable samples:\n{}", available.join("\n"))
        };
        anyhow::bail!(
            "Reference codes file not found: {}{}\n\
             \nTo generate your own, run:\n\
             \n\
             \tcargo run --example encode_reference -- \\\n\
             \t  --audio reference.wav --out samples/my_voice.npy\n\
             \n\
             Or use the Python helper:\n\
             \n\
             \tfrom neutts import NeuTTS; import numpy as np\n\
             \ttts = NeuTTS(codec_repo='neuphonic/neucodec')\n\
             \tnp.save('ref.npy', tts.encode_reference('ref.wav').numpy().astype('int32'))\n",
            ref_codes_path.display(), hint,
        );
    }

    println!("Loading reference codes from {}…", ref_codes_path.display());
    let ref_codes = tts.load_ref_codes(&ref_codes_path)?;
    println!("  → {} codec tokens  (~{:.1} s of reference audio)",
        ref_codes.len(), ref_codes.len() as f32 / 50.0);

    // ── Synthesise ────────────────────────────────────────────────────────────
    println!("\nSynthesising…");
    let audio = tts.infer(&text, &ref_codes, &ref_text)?;
    println!(
        "  → {} samples  ({:.2} s at {} Hz)",
        audio.len(),
        audio.len() as f32 / neutts::SAMPLE_RATE as f32,
        neutts::SAMPLE_RATE,
    );

    // ── Save WAV ──────────────────────────────────────────────────────────────
    tts.write_wav(&audio, Path::new(&output))?;
    println!("\nDone  →  {output}");
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Human-readable description of the Burn backend that will be selected at
/// runtime.  Actual selection happens inside the codec constructor, so this is
/// a best-effort label shown before models are loaded.
fn burn_backend_label() -> &'static str {
    if cfg!(feature = "wgpu") {
        "wgpu → ndarray fallback"
    } else {
        "ndarray (CPU)"
    }
}

fn print_help() {
    println!(
        "basic — download backbone + synthesise speech with voice cloning\n\
         \n\
         USAGE:\n\
         \tcargo run --example basic --features espeak -- [OPTIONS]\n\
         \n\
         OPTIONS:\n\
         \t--backbone   REPO  HuggingFace backbone repo\n\
         \t                   (default: neuphonic/neutts-nano-q4-gguf)\n\
         \t--text       TEXT  Text to synthesise\n\
         \t--ref-codes  PATH  Pre-encoded reference codes (.npy)\n\
         \t--ref-audio  PATH  Reference audio (.wav) — derives .npy from same stem\n\
         \t--ref-text   PATH  Transcript of the reference recording (file or string)\n\
         \t--output/--out PATH  Output WAV (default: output.wav)\n\
         \t--help / -h        Show this help\n\
         \n\
         BACKEND:\n\
         \twgpu is the default; falls back to ndarray automatically.\n\
         \tForce CPU-only:  cargo run --example basic --no-default-features --features espeak\n\
         \n\
         SETUP (one-time, before first run):\n\
         \tcargo run --example download_models   # fetch NeuCodec ONNX\n\
         \tcargo build                           # embed weights into binary"
    );
}
