//! speak — one-shot voice cloning: WAV in, synthesised audio out.
//!
//! Point it at any WAV file and the text you want to say. On the first run
//! the reference audio is encoded to NeuCodec tokens and cached as a `.npy`
//! alongside the WAV so every subsequent run is instant.
//!
//! ## Usage
//!
//! ```sh
//! # Minimal — encodes reference on first run, uses cache after that
//! cargo run --example speak --features espeak -- \
//!   --wav      my_voice.wav \
//!   --ref-text "Exactly what I said in the recording." \
//!   --text     "Hello, this is my cloned voice."
//!
//! # Explicit output path
//! cargo run --example speak --features espeak -- \
//!   --wav      my_voice.wav \
//!   --ref-text "Exactly what I said in the recording." \
//!   --text     "Hello, this is my cloned voice." \
//!   --out      cloned.wav
//!
//! # ref-text as a .txt file
//! cargo run --example speak --features espeak -- \
//!   --wav      samples/jo.wav \
//!   --ref-text samples/jo.txt \
//!   --text     "Hello from Jo's cloned voice."
//!
//! # Skip the WAV entirely and point straight at pre-encoded codes
//! cargo run --example speak --features espeak -- \
//!   --codes    samples/jo.npy \
//!   --ref-text samples/jo.txt \
//!   --text     "Hello from Jo's cloned voice."
//!
//! # Different backbone model
//! cargo run --example speak --features espeak -- \
//!   --wav       my_voice.wav \
//!   --ref-text  "What I said." \
//!   --text      "Hello." \
//!   --backbone  neuphonic/neutts-air-q4-gguf
//!
//! # List all GGUF variants in a repo, then pick one
//! cargo run --example speak --features espeak -- \
//!   --backbone neuphonic/neutts-nano-q4-gguf --list-files
//!
//! cargo run --example speak --features espeak -- \
//!   --wav      my_voice.wav \
//!   --ref-text "What I said." \
//!   --text     "Hello." \
//!   --backbone neuphonic/neutts-nano-q4-gguf \
//!   --gguf-file neutts-nano-Q4_K_M.gguf
//! ```
//!
//! ## First-run encoding
//!
//! Encoding requires the Python `neucodec` package.  Install once:
//!
//! ```sh
//! pip install neucodec huggingface_hub torchaudio
//! ```
//!
//! The encoded tokens are saved to `<wav_stem>.npy` next to the WAV.
//! Subsequent runs load directly from that file — Python is not called again.
//!
//! ## Bundled sample voices
//!
//! | Voice    | WAV                  | Transcript           |
//! |----------|----------------------|----------------------|
//! | Jo       | samples/jo.wav       | samples/jo.txt       |
//! | Dave     | samples/dave.wav     | samples/dave.txt     |
//! | Juliette | samples/juliette.wav | samples/juliette.txt |
//! | Greta    | samples/greta.wav    | samples/greta.txt    |
//! | Mateo    | samples/mateo.wav    | samples/mateo.txt    |

use anyhow::Context as _;
use std::path::{Path, PathBuf};
use std::time::Instant;

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1).peekable();

    // ── CLI ───────────────────────────────────────────────────────────────────
    let mut wav_path:     Option<PathBuf> = None;
    let mut codes_path:   Option<PathBuf> = None;
    let mut ref_text_arg: Option<String>  = None;
    let mut text      = String::new();
    let mut out       = PathBuf::from("output.wav");
    let mut backbone  = "neuphonic/neutts-nano-q4-gguf".to_string();
    let mut gguf_file: Option<String>    = None;
    let mut list_files  = false;
    let mut list_models = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--wav"         | "-w" => wav_path     = args.next().map(PathBuf::from),
            "--codes"       | "-c" => codes_path   = args.next().map(PathBuf::from),
            "--ref-text"    | "-r" => ref_text_arg = args.next(),
            "--text"        | "-t" => text         = args.next().unwrap_or_default(),
            "--out"         | "-o" => out          = args.next().map(PathBuf::from).unwrap_or(out),
            "--backbone"    | "-b" => backbone     = args.next().unwrap_or(backbone),
            "--gguf-file"   | "-g" => gguf_file    = args.next(),
            "--list-files"         => list_files   = true,
            "--list-models"        => list_models  = true,
            "--help"        | "-h" => { print_help(); return Ok(()); }
            other => {
                eprintln!("Unknown argument: {other}");
                eprintln!("Run with --help for usage.");
                std::process::exit(1);
            }
        }
    }

    // ── --list-models: print known model table and exit ───────────────────────
    if list_models {
        neutts::download::print_model_table();
        return Ok(());
    }

    // ── --list-files: show GGUF files in the chosen repo and exit ─────────────
    if list_files {
        // Annotate with registry info if known.
        if let Some(info) = neutts::download::find_model(&backbone) {
            println!("Backbone : {} — {} ({}, {})",
                info.repo, info.name, info.language, info.params);
        } else {
            println!("Backbone : {backbone}  (unknown repo)");
        }
        println!("Available GGUF files:");
        match neutts::download::list_gguf_files(&backbone) {
            Ok(files) if files.is_empty() =>
                println!("  (none — this repo may use a different format)"),
            Ok(files) => files.iter().for_each(|f| println!("  {f}")),
            Err(e) => eprintln!("  Error fetching file list: {e}"),
        }
        println!();
        println!("Use with:  --gguf-file <filename>");
        println!("Example:");
        println!("  cargo run --example speak --features espeak -- \\");
        println!("    --backbone {backbone} --gguf-file <filename> ...");
        return Ok(());
    }

    // ── Validate ──────────────────────────────────────────────────────────────
    if text.is_empty() {
        anyhow::bail!("--text is required.  What do you want to say?\n\nRun with --help for usage.");
    }
    if wav_path.is_none() && codes_path.is_none() {
        anyhow::bail!(
            "Provide either --wav <voice.wav> or --codes <voice.npy>.\n\nRun with --help for usage."
        );
    }
    if wav_path.is_some() && codes_path.is_some() {
        anyhow::bail!("--wav and --codes are mutually exclusive.");
    }

    // ── Resolve ref text ──────────────────────────────────────────────────────
    // Priority: --ref-text arg > <wav_stem>.txt sibling > <codes_stem>.txt sibling
    let sibling_txt = wav_path.as_deref()
        .or(codes_path.as_deref())
        .map(|p| p.with_extension("txt"));

    let ref_text = match ref_text_arg {
        Some(v) => {
            // Treat as a file path if the file exists, otherwise use as literal.
            let p = Path::new(&v);
            if p.exists() {
                std::fs::read_to_string(p)
                    .map(|s| s.trim().to_string())
                    .unwrap_or(v)
            } else {
                v
            }
        }
        None => {
            match sibling_txt.filter(|p| p.exists()) {
                Some(txt) => {
                    println!("Note: auto-loaded ref text from {}", txt.display());
                    std::fs::read_to_string(&txt)
                        .map(|s| s.trim().to_string())
                        .unwrap_or_default()
                }
                None => {
                    anyhow::bail!(
                        "--ref-text is required (transcript of what is spoken in the reference WAV).\n\
                         \n\
                         Pass it as a string or a path to a .txt file:\n\
                         \n\
                         \t--ref-text \"Exactly what I said in the recording.\"\n\
                         \t--ref-text samples/jo.txt"
                    );
                }
            }
        }
    };

    if ref_text.is_empty() {
        anyhow::bail!("Reference text is empty — please provide a non-empty transcript.");
    }

    // ── espeak-ng check ───────────────────────────────────────────────────────
    #[cfg(feature = "espeak")]
    if !neutts::phonemize::is_espeak_available("en-us") {
        eprintln!(
            "WARNING: espeak-ng not found.\n\
             Install: brew install espeak-ng  (macOS)\n\
             Or:      apt  install espeak-ng  (Linux)"
        );
    }

    // ── Print banner ──────────────────────────────────────────────────────────
    println!("┌─ speak ────────────────────────────────────────────────────────");
    println!("│  backbone  : {backbone}");
    match (&wav_path, &codes_path) {
        (Some(p), _) => println!("│  ref wav   : {}", p.display()),
        (_, Some(p)) => println!("│  ref codes : {}", p.display()),
        _ => {}
    }
    println!("│  ref text  : {:?}", truncate(&ref_text, 72));
    println!("│  text      : {:?}", truncate(&text, 72));
    println!("│  output    : {}", out.display());
    println!("└────────────────────────────────────────────────────────────────");
    println!();

    let t_total = Instant::now();

    // ── Load models ───────────────────────────────────────────────────────────
    println!("Loading models…");
    let t_load = Instant::now();
    let tts = neutts::download::load_from_hub_cb(&backbone, gguf_file.as_deref(), |p| {
        use neutts::download::LoadProgress;
        match &p {
            LoadProgress::Fetching { step, total, file, repo, .. } =>
                println!("  [{step}/{total}] Fetching {file} from {repo}…"),
            LoadProgress::Downloading { step, total, downloaded, total_bytes } => {
                let pct = if *total_bytes > 0 {
                    (*downloaded as f64 / *total_bytes as f64 * 100.0) as u32
                } else { 0 };
                print!("\r  [{step}/{total}] {pct:3}%  ({:.1} / {:.1} MB)",
                    *downloaded as f64 / 1_048_576.0,
                    *total_bytes  as f64 / 1_048_576.0);
                let _ = std::io::Write::flush(&mut std::io::stdout());
            }
            LoadProgress::Loading { step, total, component } => {
                println!();
                println!("  [{step}/{total}] Loading {component}…");
            }
        }
    })?;
    println!("  → codec   : {}", tts.codec.backend_name());
    println!("  → loaded in {:.2} s", t_load.elapsed().as_secs_f32());
    println!();

    // ── Get reference codes ───────────────────────────────────────────────────
    let ref_codes = match (wav_path, codes_path) {
        // ── --codes: pre-encoded, load directly ───────────────────────────────
        (_, Some(ref npy)) => {
            anyhow::ensure!(npy.exists(), "Codes file not found: {}", npy.display());
            println!("Loading codes from {}…", npy.display());
            let t_npy = Instant::now();
            let codes = tts.load_ref_codes(npy)?;
            println!(
                "  → {} tokens  ({:.1} s of reference audio, loaded in {:.0} ms)",
                codes.len(),
                codes.len() as f32 / 50.0,
                t_npy.elapsed().as_secs_f64() * 1000.0,
            );
            println!();
            codes
        }

        // ── --wav: encode (or load cached .npy) ───────────────────────────────
        (Some(ref wav), _) => {
            anyhow::ensure!(wav.exists(), "WAV file not found: {}", wav.display());

            // Cache path: same directory and stem as the WAV, extension .npy
            let cache_npy = wav.with_extension("npy");

            if cache_npy.exists() {
                // ── Cache hit ─────────────────────────────────────────────────
                println!("Loading cached codes from {}…", cache_npy.display());
                let t_npy = Instant::now();
                let codes = tts.load_ref_codes(&cache_npy)?;
                println!(
                    "  → {} tokens  ({:.1} s)  [cached, loaded in {:.0} ms]",
                    codes.len(),
                    codes.len() as f32 / 50.0,
                    t_npy.elapsed().as_secs_f64() * 1000.0,
                );
                println!();
                codes
            } else {
                // ── Cache miss — encode via Python ────────────────────────────
                println!("Encoding reference voice from {}…", wav.display());
                println!("  (first run only — result will be cached to {})", cache_npy.display());
                println!();

                let codes = encode_via_python(wav, &cache_npy)?;
                let dur = codes.len() as f32 / 50.0;
                println!("  → {} tokens  ({dur:.1} s)", codes.len());
                if dur < 3.0 {
                    eprintln!(
                        "  WARNING: reference is only {dur:.1} s — \
                         5–30 s of clean speech gives the best cloning quality."
                    );
                }
                println!();
                codes
            }
        }

        _ => unreachable!(),
    };

    // ── Synthesise ────────────────────────────────────────────────────────────
    println!("Synthesising…");
    let t_syn = Instant::now();
    let audio = tts.infer(&text, &ref_codes, &ref_text)?;
    let audio_s = audio.len() as f32 / neutts::SAMPLE_RATE as f32;
    let synth_s = t_syn.elapsed().as_secs_f32();
    println!(
        "  → {:.2} s of audio  ({} samples, RTF {:.2}x, synth took {synth_s:.2} s)",
        audio_s, audio.len(), synth_s / audio_s,
    );
    println!();

    // ── Save ──────────────────────────────────────────────────────────────────
    if let Some(parent) = out.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).ok();
        }
    }
    tts.write_wav(&audio, &out)?;
    println!(
        "Done in {:.1} s total  →  {}",
        t_total.elapsed().as_secs_f32(),
        out.display()
    );

    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Encoding via Python subprocess
// ─────────────────────────────────────────────────────────────────────────────

/// Encode `wav` → NeuCodec tokens using the Python `neucodec` package,
/// save the result to `npy_out`, and return the token IDs.
///
/// Called only on the first run for a given WAV file; subsequent runs load
/// the cached `.npy` directly.
fn encode_via_python(wav: &Path, npy_out: &Path) -> anyhow::Result<Vec<i32>> {
    // Inline Python script — no external script file needed.
    let py = format!(
        r#"
import sys, numpy as np

# Lazy imports so we give useful errors for missing packages.
try:
    import torch
    import torchaudio
except ImportError:
    sys.exit("ERROR: torchaudio not installed.  Run:  pip install torchaudio")

try:
    from neucodec import NeuCodec
except ImportError:
    sys.exit("ERROR: neucodec not installed.  Run:  pip install neucodec huggingface_hub")

wav_path = {wav_path:?}
npy_path = {npy_path:?}

waveform, sr = torchaudio.load(wav_path)
if waveform.shape[0] > 1:
    waveform = waveform.mean(dim=0, keepdim=True)  # stereo → mono
if sr != 16000:
    waveform = torchaudio.functional.resample(waveform, sr, 16000)

model = NeuCodec.from_pretrained("neuphonic/neucodec")
with torch.no_grad():
    codes = model.encode_code(waveform)  # shape [T] or [1, T]

codes = codes.squeeze().cpu().numpy().astype("int32")
np.save(npy_path, codes)
print(f"Saved {{len(codes)}} tokens to {{npy_path}}", flush=True)
"#,
        wav_path = wav.display().to_string(),
        npy_path = npy_out.display().to_string(),
    );

    // Find a Python interpreter.
    let python = find_python().ok_or_else(|| anyhow::anyhow!(
        "Python 3 not found.  Install it and the neucodec package, then re-run:\n\
         \n\
         \tpip install neucodec huggingface_hub torchaudio\n\
         \n\
         Alternatively, encode the reference audio manually and pass --codes:\n\
         \n\
         \tpython3 -c \"\
import numpy as np, torch, torchaudio\n\
from neucodec import NeuCodec\n\
wf, sr = torchaudio.load('{wav}')\n\
wf = wf.mean(0, keepdim=True) if wf.shape[0]>1 else wf\n\
wf = torchaudio.functional.resample(wf, sr, 16000) if sr!=16000 else wf\n\
m = NeuCodec.from_pretrained('neuphonic/neucodec')\n\
np.save('{npy}', m.encode_code(wf).squeeze().numpy().astype('int32'))\
\"\n\
         \n\
         Then:\n\
         \n\
         \tcargo run --example speak --features espeak -- \\\n\
         \t  --codes {npy} --ref-text \"...\" --text \"...\"",
        wav = wav.display(),
        npy = npy_out.display(),
    ))?;

    println!("  Running: {python} -c <inline script>");

    let output = std::process::Command::new(&python)
        .args(["-c", &py])
        .output()
        .with_context(|| format!("Failed to launch {python}"))?;

    // Forward Python stdout/stderr so the user sees HuggingFace download progress.
    if !output.stdout.is_empty() {
        print!("{}", String::from_utf8_lossy(&output.stdout));
    }
    if !output.stderr.is_empty() {
        eprint!("{}", String::from_utf8_lossy(&output.stderr));
    }

    if !output.status.success() {
        anyhow::bail!(
            "Python encoder exited with status {}.\n\
             Make sure neucodec is installed:\n\
             \n\
             \tpip install neucodec huggingface_hub torchaudio",
            output.status
        );
    }

    anyhow::ensure!(
        npy_out.exists(),
        "Python encoder ran but did not create {}", npy_out.display()
    );

    // Load the codes we just saved.
    neutts::npy::load_npy_i32(npy_out)
        .with_context(|| format!("Failed to read encoded codes from {}", npy_out.display()))
}

/// Try to locate a Python 3 interpreter.  Returns the command name to use.
fn find_python() -> Option<String> {
    for candidate in &["python3", "python"] {
        let ok = std::process::Command::new(candidate)
            .args(["-c", "import sys; assert sys.version_info >= (3, 8)"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if ok {
            return Some(candidate.to_string());
        }
    }
    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn truncate(s: &str, max: usize) -> String {
    let mut chars = s.chars();
    let head: String = chars.by_ref().take(max).collect();
    if chars.next().is_some() { format!("{head}…") } else { head }
}

fn print_help() {
    println!(
        "speak — one-shot voice cloning: WAV in, synthesised audio out\n\
         \n\
         USAGE:\n\
         \tcargo run --example speak --features espeak -- [OPTIONS]\n\
         \n\
         REFERENCE VOICE (pick one):\n\
         \t--wav  / -w  PATH   WAV file of the voice to clone\n\
         \t                    Tokens are encoded on first run via Python\n\
         \t                    and cached as <stem>.npy beside the WAV.\n\
         \t--codes / -c PATH   Pre-encoded .npy — skips encoding entirely.\n\
         \n\
         REQUIRED:\n\
         \t--text  / -t TEXT   What to say (synthesised output)\n\
         \t--ref-text / -r TEXT  Transcript of the reference WAV\n\
         \t                    Can be a file path or a literal string.\n\
         \t                    Auto-detected from <wav_stem>.txt if omitted.\n\
         \n\
         OPTIONS:\n\
         \t--out      / -o PATH   Output WAV  (default: output.wav)\n\
         \t--backbone   / -b REPO  HuggingFace backbone repo\n\
         \t                        (default: neuphonic/neutts-nano-q4-gguf)\n\
         \t--gguf-file  / -g FILE  Specific GGUF filename within the repo.\n\
         \t                        Omit to use the first .gguf found.\n\
         \t--list-files            Print all .gguf files in --backbone and exit.\n\
         \t--list-models           Print table of all known backbone repos and exit.\n\
         \t--help       / -h       Show this help\n\
         \n\
         FIRST-RUN ENCODING:\n\
         \tPython 3 + neucodec are used to encode the WAV on first run.\n\
         \tInstall once:  pip install neucodec huggingface_hub torchaudio\n\
         \tThe result is cached as <wav_stem>.npy — subsequent runs are instant.\n\
         \n\
         BUNDLED SAMPLES (no encoding needed):\n\
         \tcargo run --example speak --features espeak -- \\\n\
         \t  --wav samples/jo.wav --ref-text samples/jo.txt \\\n\
         \t  --text \"Hello from Jo.\"\n\
         \n\
         \tcargo run --example speak --features espeak -- \\\n\
         \t  --wav samples/dave.wav --ref-text samples/dave.txt \\\n\
         \t  --text \"Hello from Dave.\""
    );
}
