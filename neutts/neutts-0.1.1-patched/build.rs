// build.rs — NeuTTS build script
//
// Handles:
//   1. RoPE feature conflict check (fast vs precise)
//   2. NeuCodec safetensors weight file detection
//
// espeak-ng is now a pure-Rust dependency — no native library linking needed.

use std::env;
use std::path::Path;

fn main() {
    // ── RoPE feature conflict check ───────────────────────────────────────────
    if env::var("CARGO_FEATURE_FAST").is_ok() && env::var("CARGO_FEATURE_PRECISE").is_ok() {
        panic!(
            "\n\
             \nFeatures `fast` and `precise` are mutually exclusive.\n\
             \nPick one:\n\
             \n\
             \t  --features fast      # polynomial approx, ~1e-4 error (default)\n\
             \t  --features precise   # stdlib sin/cos, full accuracy\n"
        );
    }

    // ── NeuCodec safetensors weight files ─────────────────────────────────────
    let decoder_path = Path::new("models/neucodec_decoder.safetensors");
    if decoder_path.exists() {
        println!("cargo::rustc-cfg=neucodec_decoder_available");
        println!(
            "cargo::warning=NeuCodec decoder weights found: {}",
            decoder_path.display()
        );
    } else {
        println!(
            "cargo::warning=NeuCodec decoder weights not found at {}. \
             Run `python scripts/convert_weights.py` to generate them.",
            decoder_path.display()
        );
    }

    let encoder_path = Path::new("models/neucodec_encoder.safetensors");
    if encoder_path.exists() {
        println!("cargo::rustc-cfg=neucodec_encoder_available");
    }

    println!("cargo::rustc-check-cfg=cfg(neucodec_decoder_available)");
    println!("cargo::rustc-check-cfg=cfg(neucodec_encoder_available)");
}
