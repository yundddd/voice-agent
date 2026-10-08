//! End-to-end voice cloning from either a raw WAV file or a pre-encoded `.npy`.
//!
//! ## Reference input modes
//!
//! | Flag | What happens |
//! |------|-------------|
//! | `--ref-audio WAV` | SHA-256 of WAV checked against cache.<br>**Hit** → load codes instantly, skip encoder.<br>**Miss** → encode with Burn encoder, write to cache. |
//! | `--ref-codes NPY` | Load pre-encoded codes directly — encoder never used. |
//! | *(neither)*       | Default: `samples/jo.npy` (bundled voice). |
//!
//! The encoder is only initialised when it is actually needed (first run with a
//! new `--ref-audio` file).  Every subsequent run with the same WAV hits the
//! SHA-256 cache and skips encoding entirely.
//!
//! ## Backend selection
//!
//! Both the backbone decoder and the encoder (when used) pick the best
//! available Burn backend at runtime:
//!
//! - **Wgpu** (GPU — Vulkan / Metal / DX12) — tried first.
//! - **NdArray** (pure-Rust CPU) — automatic fallback.
//!
//! The active backend is printed after each component is initialised.
//! Force CPU-only with `--no-default-features`.
//!
//! ## Usage
//!
//! ```sh
//! # First run with a WAV — encodes + caches
//! cargo run --example clone_voice --features espeak -- \
//!   --ref-audio samples/jo.wav \
//!   --text      "Hello, this is your cloned voice."
//!
//! # Second run — cache hit, encoder not initialised
//! cargo run --example clone_voice --features espeak -- \
//!   --ref-audio samples/jo.wav \
//!   --text      "A completely different sentence."
//!
//! # Pre-encoded .npy (encoder never used)
//! cargo run --example clone_voice --features espeak -- \
//!   --ref-codes samples/jo.npy \
//!   --ref-text  samples/jo.txt \
//!   --text      "Hello from a .npy file."
//!
//! # Custom cache directory
//! cargo run --example clone_voice --features espeak -- \
//!   --ref-audio reference.wav --cache-dir /tmp/my_cache \
//!   --text      "Hello."
//!
//! # Force re-encode (ignore cache)
//! cargo run --example clone_voice --features espeak -- \
//!   --ref-audio reference.wav --no-cache \
//!   --text      "Hello."
//!
//! # CPU-only (no wgpu)
//! cargo run --example clone_voice --no-default-features --features espeak -- \
//!   --ref-codes samples/jo.npy --text "Hello from CPU."
//! ```

use std::path::{Path, PathBuf};
use std::time::Instant;

// ─────────────────────────────────────────────────────────────────────────────
// Reference input — mutually exclusive
// ─────────────────────────────────────────────────────────────────────────────

enum RefInput {
    Wav(PathBuf),
    Codes(PathBuf),
}

fn main() -> anyhow::Result<()> {
    // ── Parse CLI arguments ───────────────────────────────────────────────────
    let mut args = std::env::args().skip(1).peekable();

    let mut backbone_repo = "neuphonic/neutts-nano-q4-gguf".to_string();
    let mut ref_audio:    Option<PathBuf> = None;
    let mut ref_codes:    Option<PathBuf> = None;
    let mut ref_text_arg: Option<String>  = None;
    let mut text          = "Hello! This voice was cloned entirely on-device with NeuTTS.".to_string();
    let mut out           = PathBuf::from("output.wav");
    let mut cache_dir:    Option<PathBuf> = None;
    let mut no_cache      = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--backbone"         => { if let Some(v) = args.next() { backbone_repo = v; } }
            "--ref-audio"        => { if let Some(v) = args.next() { ref_audio  = Some(PathBuf::from(v)); } }
            "--ref-codes"        => { if let Some(v) = args.next() { ref_codes  = Some(PathBuf::from(v)); } }
            "--ref-text"         => { if let Some(v) = args.next() { ref_text_arg = Some(v); } }
            "--text"             => { if let Some(v) = args.next() { text = v; } }
            "--out" | "--output" => { if let Some(v) = args.next() { out = PathBuf::from(v); } }
            "--cache-dir"        => { if let Some(v) = args.next() { cache_dir = Some(PathBuf::from(v)); } }
            "--no-cache"         => { no_cache = true; }
            "--help" | "-h"      => { print_help(); return Ok(()); }
            other => {
                eprintln!("Unknown argument: {other}  (use --help for usage)");
                std::process::exit(1);
            }
        }
    }

    // ── Validate / resolve reference input ────────────────────────────────────
    if ref_audio.is_some() && ref_codes.is_some() {
        anyhow::bail!("--ref-audio and --ref-codes are mutually exclusive.");
    }

    let ref_input = match (ref_audio, ref_codes) {
        (Some(wav), _) => {
            anyhow::ensure!(wav.exists(), "Reference audio not found: {}", wav.display());
            RefInput::Wav(wav)
        }
        (_, Some(npy)) => {
            anyhow::ensure!(npy.exists(), "Reference codes not found: {}", npy.display());
            RefInput::Codes(npy)
        }
        (None, None) => {
            let default = PathBuf::from("samples/jo.npy");
            anyhow::ensure!(
                default.exists(),
                "No reference input given and samples/jo.npy not found.\n\
                 Provide --ref-audio <wav> or --ref-codes <npy>."
            );
            println!("Note: using default samples/jo.npy + samples/jo.txt");
            RefInput::Codes(default)
        }
    };

    // ── Resolve reference text ────────────────────────────────────────────────
    let ref_text = resolve_ref_text(ref_text_arg, &ref_input)?;

    // ── espeak-ng check ───────────────────────────────────────────────────────
    #[cfg(feature = "espeak")]
    if !neutts::phonemize::is_espeak_available("en-us") {
        eprintln!(
            "WARNING: espeak-ng not found.\n\
             Install: brew install espeak-ng  (macOS) / apt install espeak-ng  (Linux)"
        );
    }

    // ── Cache setup ───────────────────────────────────────────────────────────
    let cache = match &ref_input {
        RefInput::Wav(_) if !no_cache => {
            let c = match cache_dir {
                Some(ref d) => neutts::RefCodeCache::with_dir(d)?,
                None        => neutts::RefCodeCache::new()?,
            };
            Some(c)
        }
        _ => None,
    };

    // Probe cache before downloading any models — a hit means the encoder is
    // not needed at all.
    let cache_probe: Option<(Vec<i32>, neutts::CacheOutcome)> = match (&ref_input, &cache) {
        (RefInput::Wav(wav), Some(c)) => c.try_load(wav)?,
        _ => None,
    };
    let needs_encoder = cache_probe.is_none() && matches!(ref_input, RefInput::Wav(_));

    // ── Print configuration ───────────────────────────────────────────────────
    println!("Backbone  : {backbone_repo}");
    println!("Codec     : Burn {}", if cfg!(feature = "wgpu") { "wgpu → ndarray fallback" } else { "ndarray (CPU)" });
    match &ref_input {
        RefInput::Wav(p)   => println!("Ref audio : {}", p.display()),
        RefInput::Codes(p) => println!("Ref codes : {}", p.display()),
    }
    println!("Ref text  : {:?}", truncate(&ref_text, 80));
    println!("Text      : {:?}", truncate(&text, 80));
    println!("Output    : {}", out.display());
    if let Some(c) = &cache {
        println!("Cache dir : {}", c.dir().display());
    }
    println!();

    // ── Download / load models ────────────────────────────────────────────────
    println!("Loading models…");
    let t_start = Instant::now();

    let tts = neutts::download::load_from_hub_cb(
        &backbone_repo,
        None,
        |p| print_progress(&p),
    )?;
    println!("  → decoder backend : {}", tts.codec.backend_name());

    // Encoder: only initialised when a WAV cache miss requires encoding.
    let encoder_opt: Option<neutts::NeuCodecEncoder> = if needs_encoder {
        let enc = neutts::NeuCodecEncoder::new().map_err(|e| anyhow::anyhow!(
            "{e}\n\n\
             The Burn encoder is not compiled in.  Encode reference audio first:\n\
             \n\
             \tcargo run --example download_models && cargo build\n\
             \n\
             Or use --ref-codes with a pre-encoded .npy file."
        ))?;
        println!("  → encoder backend : {}", enc.backend_name());
        Some(enc)
    } else {
        None
    };

    println!("  → models ready ({:.1} s)\n", t_start.elapsed().as_secs_f32());

    // ── Get reference codes ───────────────────────────────────────────────────
    let ref_codes_vec = match ref_input {
        RefInput::Wav(ref wav) => {
            println!("Reference audio: {}", wav.display());
            let t_enc = Instant::now();

            match cache_probe {
                // ── Cache hit ─────────────────────────────────────────────────
                Some((codes, outcome)) => {
                    println!("  ✓ {outcome}");
                    println!(
                        "  → {} tokens ({:.2} s) loaded from cache in {:.3} s",
                        codes.len(), codes.len() as f32 / 50.0,
                        t_enc.elapsed().as_secs_f32(),
                    );
                    println!();
                    codes
                }
                // ── Cache miss — encode ───────────────────────────────────────
                None => {
                    let enc = encoder_opt.as_ref().expect("encoder must be ready on cache miss");
                    let codes = enc.encode_wav(wav)?;
                    let elapsed = t_enc.elapsed().as_secs_f32();

                    if no_cache {
                        println!(
                            "  (cache disabled) {} tokens ({:.2} s) encoded in {elapsed:.2} s",
                            codes.len(), codes.len() as f32 / 50.0,
                        );
                    } else {
                        let outcome = cache.as_ref().unwrap().store(wav, &codes)?;
                        println!("  ✗ {outcome}");
                        println!(
                            "  → {} tokens ({:.2} s) encoded in {elapsed:.2} s",
                            codes.len(), codes.len() as f32 / 50.0,
                        );
                    }
                    warn_short_ref(codes.len());
                    println!();
                    return finish(tts, codes, &text, &ref_text, &out, t_start);
                }
            }
        }

        RefInput::Codes(ref npy) => {
            println!("Reference codes: {}", npy.display());
            let codes = tts.load_ref_codes(npy)?;
            println!(
                "  → {} tokens ({:.2} s)",
                codes.len(), codes.len() as f32 / 50.0,
            );
            println!();
            codes
        }
    };

    finish(tts, ref_codes_vec, &text, &ref_text, &out, t_start)
}

// ─────────────────────────────────────────────────────────────────────────────
// Synthesis + WAV write
// ─────────────────────────────────────────────────────────────────────────────

fn finish(
    tts: neutts::NeuTTS,
    ref_codes: Vec<i32>,
    text: &str,
    ref_text: &str,
    out: &Path,
    t_start: Instant,
) -> anyhow::Result<()> {
    println!("Synthesising: {:?}", truncate(text, 60));
    let t_syn = Instant::now();

    let audio   = tts.infer(text, &ref_codes, ref_text)?;
    let audio_s = audio.len() as f32 / neutts::SAMPLE_RATE as f32;
    let synth_s = t_syn.elapsed().as_secs_f32();
    println!(
        "  → {audio_s:.2} s of audio  ({} samples, RTF {:.2}x, took {synth_s:.2} s)\n",
        audio.len(),
        synth_s / audio_s,
    );

    if let Some(parent) = out.parent() {
        if !parent.as_os_str().is_empty() { std::fs::create_dir_all(parent).ok(); }
    }
    tts.write_wav(&audio, out)?;
    println!("Done in {:.1} s total  →  {}", t_start.elapsed().as_secs_f32(), out.display());
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn resolve_ref_text(arg: Option<String>, input: &RefInput) -> anyhow::Result<String> {
    let sibling_txt = match input {
        RefInput::Wav(p)   => Some(p.with_extension("txt")),
        RefInput::Codes(p) => Some(p.with_extension("txt")),
    };
    match arg {
        Some(v) => {
            let p = Path::new(&v);
            let text = if p.exists() {
                std::fs::read_to_string(p).map(|s| s.trim().to_string()).unwrap_or(v)
            } else { v };
            anyhow::ensure!(!text.is_empty(), "--ref-text resolved to an empty string.");
            Ok(text)
        }
        None => {
            if let Some(txt) = sibling_txt.filter(|p| p.exists()) {
                println!("Note: auto-detected ref text from {}", txt.display());
                let text = std::fs::read_to_string(&txt)
                    .map(|s| s.trim().to_string()).unwrap_or_default();
                anyhow::ensure!(!text.is_empty(), "{} is empty.", txt.display());
                Ok(text)
            } else {
                anyhow::bail!(
                    "--ref-text is required (transcript of the reference audio).\n\
                     Pass a file path or a literal string:\n\
                     \t--ref-text samples/jo.txt\n\
                     \t--ref-text \"So I just tried Neuphonic and I'm impressed.\""
                )
            }
        }
    }
}

fn warn_short_ref(n_tokens: usize) {
    let secs = n_tokens as f32 / 50.0;
    if secs < 3.0 {
        eprintln!(
            "  WARNING: reference is only {secs:.1} s — \
             5–30 s of clean speech gives the best cloning quality."
        );
    }
}

fn print_progress(p: &neutts::download::LoadProgress) {
    use neutts::download::LoadProgress;
    match p {
        LoadProgress::Fetching { step, total, file, repo } =>
            println!("  [{step}/{total}] Fetching {file} from {repo}…"),
        LoadProgress::Loading { step, total, component } =>
            println!("  [{step}/{total}] Loading {component}…"),
    }
}

fn truncate(s: &str, max_chars: usize) -> String {
    let mut it = s.chars();
    let head: String = it.by_ref().take(max_chars).collect();
    if it.next().is_some() { format!("{head}…") } else { head }
}

fn print_help() {
    println!(
        "clone_voice — end-to-end voice cloning with SHA-256 reference-code cache\n\
         \n\
         Backend: Wgpu (GPU) tried first, NdArray (CPU) fallback — automatic.\n\
         Force CPU:  --no-default-features\n\
         \n\
         USAGE:\n\
         \tcargo run --example clone_voice --features espeak -- [OPTIONS]\n\
         \n\
         REFERENCE INPUT (pick one):\n\
         \t--ref-audio  WAV  Raw WAV — encoded on first run, cached by SHA-256\n\
         \t--ref-codes  NPY  Pre-encoded .npy — encoder never initialised\n\
         \t(neither)         Default: samples/jo.npy\n\
         \n\
         OPTIONS:\n\
         \t--ref-text   TEXT  Transcript (file or literal; auto-detected from .txt)\n\
         \t--text       TEXT  Text to synthesise\n\
         \t--out        PATH  Output WAV  (default: output.wav)\n\
         \t--cache-dir  PATH  Override cache directory\n\
         \t--no-cache         Always re-encode, skip cache\n\
         \t--backbone   REPO  HuggingFace backbone repo\n\
         \t--help / -h        Show this help\n\
         \n\
         EXAMPLES:\n\
         \t# First run: encodes + caches\n\
         \tcargo run --example clone_voice --features espeak -- \\\n\
         \t  --ref-audio samples/jo.wav --text 'Hello.'\n\
         \n\
         \t# Second run: cache hit, no encoding\n\
         \tcargo run --example clone_voice --features espeak -- \\\n\
         \t  --ref-audio samples/jo.wav --text 'Different text.'\n\
         \n\
         \t# Pre-encoded codes, encoder never used\n\
         \tcargo run --example clone_voice --features espeak -- \\\n\
         \t  --ref-codes samples/jo.npy --ref-text samples/jo.txt \\\n\
         \t  --text 'From a .npy file.'"
    );
}
