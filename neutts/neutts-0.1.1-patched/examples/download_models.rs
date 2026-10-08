//! One-time NeuCodec ONNX download helper.
//!
//! Downloads the NeuCodec decoder (and optionally encoder) ONNX files from
//! HuggingFace into the workspace `models/` directory so that `build.rs` can
//! convert them to Burn Rust code at the **next** `cargo build`.
//!
//! After `cargo build` the Burn weights are **embedded in the binary** via
//! `include_bytes!` — no ONNX Runtime or separate weight files are needed at
//! runtime.
//!
//! ## Backend
//!
//! At runtime the embedded model runs on:
//! - **Wgpu** (GPU — Vulkan / Metal / DX12) — tried first (default feature).
//! - **NdArray** (pure-Rust CPU) — automatic fallback when no GPU is available.
//!
//! ## Usage
//!
//! ```sh
//! # Download both decoder and encoder, then rebuild:
//! cargo run --example download_models
//! cargo build
//!
//! # Decoder only (encode workflow not needed):
//! SKIP_ENCODER=1 cargo run --example download_models
//! cargo build
//!
//! # CPU-only binary (skip wgpu):
//! SKIP_ENCODER=1 cargo run --example download_models
//! cargo build --no-default-features --features espeak
//! ```

fn main() -> anyhow::Result<()> {
    use std::path::Path;

    println!("\n\x1b[1;36m╔══════════════════════════════════════════════════════╗");
    println!("║  neutts-rs  ·  NeuCodec ONNX model downloader       ║");
    println!("╚══════════════════════════════════════════════════════╝\x1b[0m\n");

    // Allow overriding repos via env or CLI args.
    let mut args = std::env::args().skip(1).peekable();
    let mut decoder_repo = "neuphonic/neucodec-onnx-decoder".to_string();
    let mut encoder_repo = "neuphonic/neucodec-onnx-encoder".to_string();
    let mut models_dir_arg = "models".to_string();
    let mut skip_encoder = std::env::var("SKIP_ENCODER").is_ok();

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--decoder-repo"  => { if let Some(v) = args.next() { decoder_repo = v; } }
            "--encoder-repo"  => { if let Some(v) = args.next() { encoder_repo = v; } }
            "--models-dir"    => { if let Some(v) = args.next() { models_dir_arg = v; } }
            "--skip-encoder"  => { skip_encoder = true; }
            "--help" | "-h"   => {
                println!(
                    "download_models — fetch NeuCodec ONNX files for build-time Burn conversion\n\
                     \n\
                     USAGE:\n\
                     \tcargo run --example download_models -- [OPTIONS]\n\
                     \n\
                     OPTIONS:\n\
                     \t--decoder-repo REPO  HuggingFace decoder repo (default: neuphonic/neucodec-onnx-decoder)\n\
                     \t--encoder-repo REPO  HuggingFace encoder repo (default: neuphonic/neucodec-onnx-encoder)\n\
                     \t--models-dir   PATH  Staging directory (default: models/)\n\
                     \t--skip-encoder       Skip encoder download (also: SKIP_ENCODER=1)\n\
                     \t--help / -h          Show this help"
                );
                return Ok(());
            }
            other => { eprintln!("Unknown argument: {other}  (use --help)"); }
        }
    }

    let models_dir = Path::new(&models_dir_arg);

    std::fs::create_dir_all(models_dir)?;
    println!("  staging directory : {}/\n", models_dir.display());

    // ── Decoder ───────────────────────────────────────────────────────────────
    let decoder_dest = models_dir.join("neucodec_decoder.onnx");
    if decoder_dest.exists() {
        println!("  \x1b[32m✓\x1b[0m  decoder already staged: {}", decoder_dest.display());
    } else {
        println!("  ↓  Fetching NeuCodec decoder ONNX from HuggingFace…");
        println!("     repo: {decoder_repo}");

        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        neutts::download::download_decoder_onnx(&decoder_repo, models_dir)
            .map_err(|e| anyhow::anyhow!("{e:#}"))?;

        #[cfg(any(target_os = "ios", target_os = "android"))]
        anyhow::bail!(
            "HuggingFace downloads are not supported on iOS/Android.\n\
             Copy models/neucodec_decoder.onnx manually."
        );

        println!("  \x1b[32m✓\x1b[0m  decoder staged: {}", decoder_dest.display());
    }

    // ── Encoder ───────────────────────────────────────────────────────────────
    if skip_encoder {
        println!("\n  (encoder skipped — SKIP_ENCODER / --skip-encoder)");
        println!("  Without the encoder, --ref-audio encoding is unavailable at runtime.");
        println!("  Use --ref-codes with a pre-encoded .npy file instead.");
    } else {
        let encoder_dest = models_dir.join("neucodec_encoder.onnx");
        if encoder_dest.exists() {
            println!("\n  \x1b[32m✓\x1b[0m  encoder already staged: {}", encoder_dest.display());
        } else {
            println!("\n  ↓  Fetching NeuCodec encoder ONNX from HuggingFace…");
            println!("     repo: {encoder_repo}");

            #[cfg(not(any(target_os = "ios", target_os = "android")))]
            match neutts::download::download_encoder_onnx(&encoder_repo, models_dir) {
                Ok(_) => println!(
                    "  \x1b[32m✓\x1b[0m  encoder staged: {}",
                    encoder_dest.display()
                ),
                Err(e) => {
                    // Print the full error chain so the root cause (e.g. 404,
                    // auth error, wrong filename) is visible.
                    println!(
                        "  \x1b[33m~\x1b[0m  encoder download failed (optional):\n\
                         \n\
                         \x1b[31m{e:#}\x1b[0m\n\
                         \n\
                         \x1b[2mTips:\x1b[0m\n\
                         \x1b[2m  • Check the repo exists:  https://huggingface.co/{encoder_repo}\x1b[0m\n\
                         \x1b[2m  • Override repo:  --encoder-repo <HF_REPO_ID>\x1b[0m\n\
                         \x1b[2m  • Supply ONNX manually:  cp encoder.onnx {}/neucodec_encoder.onnx\x1b[0m\n\
                         \x1b[2m  • Skip encoder:  --skip-encoder  (use --ref-codes .npy instead)\x1b[0m",
                        models_dir.display()
                    );
                }
            }

            #[cfg(any(target_os = "ios", target_os = "android"))]
            println!("  (skipped — downloads not available on this platform)");
        }
    }

    // ── Next steps ────────────────────────────────────────────────────────────
    println!("\n\x1b[1;32m━━━  Next step  ━━━\x1b[0m\n");
    println!("  Rebuild to convert ONNX → Burn and embed weights in the binary:\n");
    println!("    \x1b[1mcargo build\x1b[0m\n");

    println!(
        "  build.rs runs `burn-import` on each ONNX in models/ and embeds\n\
         the weights via include_bytes!.  After that no ONNX files or\n\
         ONNX Runtime are needed at runtime.\n"
    );

    println!("  \x1b[2mRuntime backend selection (automatic):\x1b[0m");
    println!("    Wgpu  (GPU — Vulkan / Metal / DX12)  ← tried first  [default feature]");
    println!("    NdArray  (pure-Rust CPU)              ← automatic fallback");
    println!();
    println!("  Force CPU-only binary:");
    println!("    \x1b[1mcargo build --no-default-features --features espeak\x1b[0m\n");

    Ok(())
}
