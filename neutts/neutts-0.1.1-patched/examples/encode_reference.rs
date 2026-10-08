//! Encode a reference WAV file to NeuCodec token IDs and save as `.npy`.
//!
//! This is the Rust equivalent of the Python pre-processing step:
//!
//! ```python
//! from neutts import NeuTTS
//! import numpy as np
//! tts   = NeuTTS(codec_repo="neuphonic/neucodec")
//! codes = tts.encode_reference("reference.wav")
//! np.save("samples/my_voice.npy", codes.numpy().astype("int32"))
//! ```
//!
//! ## One-time setup
//!
//! The NeuCodec encoder must be compiled into the binary first:
//!
//! ```sh
//! cargo run --example download_models   # fetches ONNX → models/
//! cargo build                           # burn-import converts + embeds weights
//! ```
//!
//! ## Backend selection
//!
//! The **Wgpu** (GPU) backend is tried first; if the GPU stack is unavailable
//! it falls back to **NdArray** (pure-Rust CPU) automatically.  The selected
//! backend is printed after the encoder is initialised.
//!
//! Force CPU-only:
//!
//! ```sh
//! cargo run --example encode_reference --no-default-features -- --audio reference.wav
//! ```
//!
//! ## Usage
//!
//! ```sh
//! # Encode a WAV (embedded weights, auto backend)
//! cargo run --example encode_reference -- --audio reference.wav
//!
//! # Explicit output path
//! cargo run --example encode_reference -- \
//!   --audio reference.wav \
//!   --out   samples/my_voice.npy
//!
//! # Load encoder weights from an external BurnPack file (.bpk)
//! cargo run --example encode_reference -- \
//!   --audio   reference.wav \
//!   --encoder /path/to/neucodec_encoder.bpk \
//!   --out     samples/my_voice.npy
//! ```
//!
//! ## Notes
//!
//! - The WAV is resampled to 16 kHz mono automatically — any sample rate /
//!   channel count / bit depth is accepted.
//! - The `.npy` file can be passed to `basic` or `clone_voice` via
//!   `--ref-codes` and is compatible with `np.load()` in Python.
//! - Aim for 5–30 seconds of clean, noise-free speech for best results.

use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    // ── Parse CLI arguments ───────────────────────────────────────────────────
    let mut args = std::env::args().skip(1).peekable();

    let mut encoder_bpk: Option<PathBuf> = None; // optional external .bpk weight file
    let mut audio_path:  Option<PathBuf> = None;
    let mut out_path:    Option<PathBuf> = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--encoder"      => { if let Some(v) = args.next() { encoder_bpk = Some(PathBuf::from(v)); } }
            "--audio" | "-i" => { if let Some(v) = args.next() { audio_path = Some(PathBuf::from(v)); } }
            "--out"   | "-o" => { if let Some(v) = args.next() { out_path   = Some(PathBuf::from(v)); } }
            "--help"  | "-h" => { print_help(); return Ok(()); }
            other => {
                eprintln!("Unknown argument: {other}  (use --help for usage)");
                std::process::exit(1);
            }
        }
    }

    // ── Validate inputs ───────────────────────────────────────────────────────
    let audio_path = audio_path.ok_or_else(|| {
        anyhow::anyhow!("No audio file specified.  Use --audio <path.wav>  (--help for more)")
    })?;

    if !audio_path.exists() {
        anyhow::bail!("Audio file not found: {}", audio_path.display());
    }

    let out_path = out_path.unwrap_or_else(|| audio_path.with_extension("npy"));

    // ── Print configuration ───────────────────────────────────────────────────
    match &encoder_bpk {
        Some(p) => println!("Encoder  : external BurnPack  {}", p.display()),
        None    => println!("Encoder  : embedded weights  (wgpu → ndarray fallback)"),
    }
    println!("Audio    : {}", audio_path.display());
    println!("Output   : {}", out_path.display());
    println!();

    // ── Load encoder ──────────────────────────────────────────────────────────
    println!("Initialising encoder…");
    let encoder = match encoder_bpk {
        Some(ref p) => neutts::NeuCodecEncoder::load(p)
            .map_err(|e| anyhow::anyhow!("Failed to load encoder from {}: {e}", p.display()))?,
        None => neutts::NeuCodecEncoder::new()
            .map_err(|e| anyhow::anyhow!(
                "{e}\n\n\
                 Run the one-time setup to embed the encoder:\n\
                 \n\
                 \tcargo run --example download_models\n\
                 \tcargo build\n"
            ))?,
    };
    println!("  → backend : {}", encoder.backend_name());
    println!();

    // ── Encode ────────────────────────────────────────────────────────────────
    println!("Encoding {}…", audio_path.display());
    let codes = encoder.encode_wav(&audio_path)?;

    let duration_s = codes.len() as f32 / 50.0;
    println!(
        "  → {} tokens  ({:.2} s of audio at 50 tokens/s)",
        codes.len(),
        duration_s,
    );

    if duration_s < 3.0 {
        eprintln!(
            "WARNING: reference is only {duration_s:.1} s — \
             5–30 s of clean speech gives the best cloning quality."
        );
    }

    // ── Save ──────────────────────────────────────────────────────────────────
    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).ok();
        }
    }

    neutts::npy::write_npy_i32(&out_path, &codes)?;
    println!("Saved  →  {}", out_path.display());

    println!();
    println!(
        "Use these codes for synthesis:\n\
         \n\
         \tcargo run --example basic --features espeak -- \\\n\
         \t  --text       \"Your text here.\" \\\n\
         \t  --ref-codes  {} \\\n\
         \t  --ref-text   \"Transcript of the reference recording.\"",
        out_path.display()
    );

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn print_help() {
    println!(
        "encode_reference — encode a WAV to NeuCodec token IDs (.npy)\n\
         \n\
         The NeuCodec encoder is compiled into the binary — no external ONNX Runtime.\n\
         Wgpu (GPU) is tried first; falls back to NdArray (CPU) automatically.\n\
         \n\
         SETUP (one-time):\n\
         \tcargo run --example download_models && cargo build\n\
         \n\
         USAGE:\n\
         \tcargo run --example encode_reference -- [OPTIONS]\n\
         \n\
         OPTIONS:\n\
         \t--audio  / -i  PATH  Input WAV file (required)\n\
         \t--out    / -o  PATH  Output .npy (default: same stem as audio)\n\
         \t--encoder      PATH  External BurnPack (.bpk) weight file\n\
         \t                     (default: use weights embedded in binary)\n\
         \t--help   / -h        Show this help\n\
         \n\
         FORCE CPU (no wgpu):\n\
         \tcargo run --example encode_reference --no-default-features -- --audio <WAV>"
    );
}
