//! Pure-Rust weight converter: `pytorch_model.bin` → `neucodec_decoder.safetensors`
//!
//! This is a **one-time setup step**.  After running this example, `cargo
//! build` will find the weight file and the NeuCodec decoder will work at
//! runtime.
//!
//! The conversion is implemented entirely in Rust — no Python, PyTorch, or
//! ONNX Runtime installation is required.  It is equivalent to (and replaces)
//! `scripts/convert_weights.py` and `scripts/convert_weights_nopytorch.py`.
//!
//! ## What it does
//!
//! 1. Downloads `pytorch_model.bin` from `neuphonic/neucodec` on HuggingFace
//!    (cached under `~/.cache/huggingface/hub` — subsequent runs are instant).
//! 2. Parses the PyTorch ZIP/pickle archive in pure Rust.
//! 3. Extracts only the decoder sub-graph tensors (`generator.*`, `fc_post_a.*`).
//! 4. Writes them as a `safetensors` file with embedded hyper-parameter metadata.
//!
//! ## Usage
//!
//! ```sh
//! # Default: downloads from neuphonic/neucodec, writes models/neucodec_decoder.safetensors
//! cargo run --example convert_weights
//!
//! # Custom output path
//! cargo run --example convert_weights -- --out /tmp/decoder.safetensors
//!
//! # Different HuggingFace repo
//! cargo run --example convert_weights -- --repo myorg/mycodec
//!
//! # Override attention-head count recorded in the metadata
//! cargo run --example convert_weights -- --n-heads 8
//!
//! # Combine flags
//! cargo run --example convert_weights -- --repo myorg/mycodec --out /tmp/decoder.safetensors --n-heads 8
//!
//! # Show help
//! cargo run --example convert_weights -- --help
//! ```
//!
//! After conversion, rebuild the library to pick up the new weights:
//!
//! ```sh
//! cargo build
//! cargo run --example test_pipeline
//! cargo run --example basic --features espeak
//! ```

fn main() -> anyhow::Result<()> {
    use std::path::PathBuf;
    use anyhow::Context as _;

    // ── Banner ────────────────────────────────────────────────────────────────
    println!();
    println!("\x1b[1;36m╔════════════════════════════════════════════════════════════╗");
    println!("║  neutts-rs  ·  Pure-Rust NeuCodec weight converter         ║");
    println!("╚════════════════════════════════════════════════════════════╝\x1b[0m");
    println!();

    // ── Parse CLI arguments ───────────────────────────────────────────────────
    let mut args = std::env::args().skip(1).peekable();
    let mut out_path   = PathBuf::from("models/neucodec_decoder.safetensors");
    let mut repo       = neutts::download::CODEC_DECODER_REPO.to_string();
    let mut n_heads: u32 = 16;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--out" | "-o" => {
                out_path = PathBuf::from(
                    args.next().expect("--out requires a path argument")
                );
            }
            "--repo" | "-r" => {
                repo = args.next().expect("--repo requires a repo-id argument");
            }
            "--n-heads" | "--n_heads" => {
                let s = args.next().expect("--n-heads requires an integer argument");
                n_heads = s.parse()
                    .with_context(|| format!("--n-heads: expected integer, got '{s}'"))?;
            }
            "--help" | "-h" => {
                print_help();
                return Ok(());
            }
            other => {
                eprintln!("Unknown argument: {other}  (use --help)");
                std::process::exit(1);
            }
        }
    }

    // ── Check for existing output ─────────────────────────────────────────────
    if out_path.exists() {
        println!("  \x1b[32m✓\x1b[0m  Already converted: {}", out_path.display());
        println!("     Delete it and re-run to force reconversion.");
        println!();
        print_next_steps(&out_path);
        return Ok(());
    }

    // ── Download pytorch_model.bin ────────────────────────────────────────────
    let bin_filename = neutts::download::CODEC_SOURCE_FILE;
    println!("  \x1b[1mStep 1/2\x1b[0m  Downloading `{bin_filename}` from \x1b[4m{repo}\x1b[0m");
    println!("           (cached after first download — subsequent runs are instant)");
    println!();

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let bin_path = {
        use hf_hub::{Cache, Repo, api::sync::Api};

        // ── Cache hit? ────────────────────────────────────────────────────────
        let cache_repo = Cache::from_env().repo(Repo::model(repo.clone()));
        let bin_path = if let Some(cached) = cache_repo.get(bin_filename) {
            println!("  \x1b[2m(cache hit — skipping download)\x1b[0m");
            cached
        } else {
            // ── Live download with progress bar ───────────────────────────────
            let api = Api::new().context("Failed to initialise HuggingFace Hub client")?;
            let api_repo = api.model(repo.clone());

            struct Progress { downloaded: u64, total: u64 }
            impl hf_hub::api::Progress for Progress {
                fn init(&mut self, size: usize, filename: &str) {
                    self.total = size as u64;
                    println!("  Downloading {filename}  ({:.0} MB)", size as f64 / 1_048_576.0);
                }
                fn update(&mut self, size: usize) {
                    self.downloaded += size as u64;
                    let pct = if self.total > 0 {
                        self.downloaded * 100 / self.total
                    } else { 0 };
                    let mb = self.downloaded as f64 / 1_048_576.0;
                    // Overwrite the same line.
                    eprint!("\r  \x1b[2m{mb:.0} MB  ({pct}%)\x1b[0m     ");
                    let _ = std::io::Write::flush(&mut std::io::stderr());
                }
                fn finish(&mut self) {
                    eprintln!(); // newline after progress line
                }
            }

            api_repo.download_with_progress(bin_filename, Progress { downloaded: 0, total: 0 })
                .with_context(|| format!("Failed to download '{bin_filename}' from '{repo}'"))?
        };

        let size_mb = std::fs::metadata(&bin_path)?.len() / 1_048_576;
        println!("  \x1b[32m✓\x1b[0m  {bin_filename}  ({size_mb} MB)  →  {}", bin_path.display());
        println!();
        bin_path
    };

    #[cfg(any(target_os = "ios", target_os = "android"))]
    return Err(anyhow::anyhow!(
        "HuggingFace downloads are not supported on iOS/Android.\n\
         Copy {bin_filename} manually and call convert_neucodec_checkpoint() directly."
    ));

    // ── Convert ───────────────────────────────────────────────────────────────
    println!("  \x1b[1mStep 2/2\x1b[0m  Converting checkpoint (pure Rust — no PyTorch required)");
    println!("           n_heads = {n_heads}  |  repo = {repo}");
    println!("           output  = {}", out_path.display());
    println!();

    neutts::download::convert_neucodec_checkpoint(&bin_path, &out_path, n_heads, &repo)
        .context("Checkpoint conversion failed")?;

    println!();
    let size_mb = std::fs::metadata(&out_path)?.len() / 1_048_576;
    println!("  \x1b[32m✓\x1b[0m  Saved {size_mb} MB  →  {}", out_path.display());
    println!();

    print_next_steps(&out_path);
    Ok(())
}

fn print_help() {
    println!(
        "convert_weights — pure-Rust NeuCodec pytorch_model.bin → safetensors converter\n\
         \n\
         USAGE:\n\
         \tcargo run --example convert_weights -- [OPTIONS]\n\
         \n\
         OPTIONS:\n\
         \t--out  PATH       Output safetensors path  [default: models/neucodec_decoder.safetensors]\n\
         \t--repo REPO       HuggingFace repo ID       [default: neuphonic/neucodec]\n\
         \t--n-heads N       Attention head count for metadata  [default: 16]\n\
         \t--help / -h       Show this help\n\
         \n\
         DESCRIPTION:\n\
         \tDownloads pytorch_model.bin from the HuggingFace Hub (cached after the\n\
         \tfirst run) and converts it to safetensors format using a pure-Rust\n\
         \tpickle parser and ZIP reader.  No Python, PyTorch, or ONNX Runtime\n\
         \tinstallation is required.\n\
         \n\
         \tOnly decoder tensors (generator.* / fc_post_a.*) are extracted;\n\
         \tthe rest of the checkpoint is discarded.\n\
         \n\
         EXAMPLES:\n\
         \tcargo run --example convert_weights\n\
         \tcargo run --example convert_weights -- --out /tmp/decoder.safetensors\n\
         \tcargo run --example convert_weights -- --repo myorg/mycodec --n-heads 8\n"
    );
}

fn print_next_steps(out_path: &std::path::Path) {
    println!("\x1b[1;32m━━━  Done!  Next steps  ━━━\x1b[0m\n");
    println!("  Rebuild to pick up the new weights:\n");
    println!("    \x1b[1mcargo build\x1b[0m\n");
    if out_path != std::path::Path::new("models/neucodec_decoder.safetensors") {
        println!(
            "  \x1b[33mNote:\x1b[0m  weights written to a custom path ({}).",
            out_path.display()
        );
        println!("  Point your loader at that file or copy it to models/neucodec_decoder.safetensors.\n");
    }
    println!("  Then run the synthesis examples:\n");
    println!("    \x1b[1mcargo run --example test_pipeline\x1b[0m");
    println!("    \x1b[1mcargo run --example basic --features espeak\x1b[0m");
    println!();
}
