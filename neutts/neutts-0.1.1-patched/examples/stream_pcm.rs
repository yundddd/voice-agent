//! stream_pcm — preload models once, then stream raw PCM to stdout.
//!
//! Unlike `speak`, which decodes all tokens at once and writes a WAV file,
//! this example:
//!
//!  1. **Preloads** the backbone and NeuCodec decoder exactly once at startup
//!     (including eager GPU init).  Subsequent synthesis calls pay no loading
//!     cost.
//!  2. Runs the backbone in **streaming mode**: each speech token is forwarded
//!     to the codec as soon as it is generated, rather than waiting for the
//!     full output.
//!  3. Decodes tokens in **chunks** (default: 25 tokens = 500 ms of audio)
//!     and writes raw **signed 16-bit little-endian PCM** to stdout as each
//!     chunk is ready.
//!  4. Prints timing diagnostics (time-to-first-audio, RTF) to **stderr** so
//!     they do not corrupt the PCM stream.
//!
//! ## Piping the output to a player
//!
//! ```sh
//! # Linux — aplay
//! cargo run --example stream_pcm --features espeak -- \
//!   --codes samples/dave.npy --ref-text samples/dave.txt \
//!   --text "Hello, this is streaming audio." | \
//!   aplay -f S16_LE -r 24000 -c 1
//!
//! # macOS — sox
//! cargo run --example stream_pcm --features espeak -- \
//!   --codes samples/dave.npy --ref-text samples/dave.txt \
//!   --text "Hello, this is streaming audio." | \
//!   sox -t raw -r 24000 -e signed -b 16 -c 1 - -d
//!
//! # Cross-platform — ffplay
//! cargo run --example stream_pcm --features espeak -- \
//!   --codes samples/dave.npy --ref-text samples/dave.txt \
//!   --text "Hello, this is streaming audio." | \
//!   ffplay -f s16le -ar 24000 -ac 1 -nodisp -
//! ```
//!
//! ## Saving to a file instead
//!
//! ```sh
//! cargo run --example stream_pcm --features espeak -- \
//!   --codes samples/dave.npy --ref-text samples/dave.txt \
//!   --text "Hello." > output.pcm
//!
//! # Convert the raw PCM to WAV with sox or ffmpeg:
//! sox  -t raw -r 24000 -e signed -b 16 -c 1 output.pcm output.wav
//! ffmpeg -f s16le -ar 24000 -ac 1 -i output.pcm output.wav
//! ```
//!
//! ## Chunk size trade-off
//!
//! | `--chunk` | Audio buffered | Latency (TTFA) | Quality at boundaries |
//! |-----------|----------------|----------------|-----------------------|
//! | 10        | ~200 ms        | lowest         | may have mild artefacts |
//! | 25        | ~500 ms        | balanced       | good (default)          |
//! | 50        | ~1 s           | higher         | best                    |
//!
//! Each chunk is decoded independently by the NeuCodec transformer, so very
//! small chunks lose cross-chunk attention context.  Values ≥ 25 are
//! recommended for broadcast-quality output.

use std::io::{self, Write as _};
use std::path::PathBuf;
use std::time::Instant;

use anyhow::Context as _;

fn main() -> anyhow::Result<()> {
    // ── CLI ───────────────────────────────────────────────────────────────────
    let mut codes_path:   Option<PathBuf> = None;
    let mut ref_text_arg: Option<String>  = None;
    let mut text         = String::new();
    let mut backbone     = "neuphonic/neutts-nano-q4-gguf".to_string();
    let mut gguf_file:   Option<String>   = None;
    let mut chunk_size:  usize            = 25;

    let mut args = std::env::args().skip(1).peekable();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--codes"     | "-c" => codes_path   = args.next().map(PathBuf::from),
            "--ref-text"  | "-r" => ref_text_arg = args.next(),
            "--text"      | "-t" => text         = args.next().unwrap_or_default(),
            "--backbone"  | "-b" => backbone     = args.next().unwrap_or(backbone),
            "--gguf-file" | "-g" => gguf_file    = args.next(),
            "--chunk"     | "-k" => {
                chunk_size = args.next()
                    .as_deref()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(chunk_size);
            }
            "--help" | "-h" => { print_help(); return Ok(()); }
            other => {
                anyhow::bail!("Unknown argument: {other}\nRun with --help for usage.");
            }
        }
    }

    // ── Validate ──────────────────────────────────────────────────────────────
    if text.is_empty() {
        anyhow::bail!("--text is required.\n\nRun with --help for usage.");
    }
    let codes_path = codes_path
        .ok_or_else(|| anyhow::anyhow!("--codes <path.npy> is required.\n\nRun with --help for usage."))?;

    // Resolve ref-text: explicit arg → sibling .txt file
    let ref_text = match ref_text_arg {
        Some(v) => {
            let p = std::path::Path::new(&v);
            if p.exists() {
                std::fs::read_to_string(p).map(|s| s.trim().to_string()).unwrap_or(v)
            } else {
                v
            }
        }
        None => {
            let sibling = codes_path.with_extension("txt");
            if sibling.exists() {
                eprintln!("[stream_pcm] Auto-loaded ref text from {}", sibling.display());
                std::fs::read_to_string(&sibling)
                    .map(|s| s.trim().to_string())
                    .unwrap_or_default()
            } else {
                anyhow::bail!(
                    "--ref-text is required (transcript of the reference recording).\n\
                     Pass a string or a path to a .txt file."
                );
            }
        }
    };

    if ref_text.is_empty() {
        anyhow::bail!("Reference text is empty — provide a non-empty transcript.");
    }

    // ── Banner ────────────────────────────────────────────────────────────────
    eprintln!("┌─ stream_pcm ────────────────────────────────────────────────────");
    eprintln!("│  backbone  : {backbone}");
    eprintln!("│  codes     : {}", codes_path.display());
    eprintln!("│  ref text  : {:?}", truncate(&ref_text, 72));
    eprintln!("│  text      : {:?}", truncate(&text, 72));
    eprintln!("│  chunk     : {chunk_size} tokens  ({:.0} ms)", chunk_size as f32 * 1000.0 / 50.0);
    eprintln!("│  output    : stdout (raw s16le, 24 kHz, mono)");
    eprintln!("└─────────────────────────────────────────────────────────────────");
    eprintln!();

    // ── Preload models (done once; paid at startup, not per synthesis) ────────
    eprintln!("[stream_pcm] Preloading models…");
    let t_load = Instant::now();

    let tts = neutts::download::load_from_hub_cb(&backbone, gguf_file.as_deref(), |p| {
        use neutts::download::LoadProgress;
        match &p {
            LoadProgress::Fetching { step, total, file, repo, .. } =>
                eprintln!("  [{step}/{total}] Fetching {file} from {repo}…"),
            LoadProgress::Downloading { step, total, downloaded, total_bytes } => {
                let pct = if *total_bytes > 0 {
                    (*downloaded as f64 / *total_bytes as f64 * 100.0) as u32
                } else { 0 };
                eprint!("\r  [{step}/{total}] {pct:3}%  ({:.1} / {:.1} MB)",
                    *downloaded as f64 / 1_048_576.0,
                    *total_bytes  as f64 / 1_048_576.0);
                let _ = io::stderr().flush();
            }
            LoadProgress::Loading { step, total, component } => {
                eprintln!();
                eprintln!("  [{step}/{total}] Loading {component}…");
            }
        }
    })?;

    eprintln!("  → codec   : {}", tts.codec.backend_name());
    eprintln!("  → loaded in {:.2} s", t_load.elapsed().as_secs_f32());
    eprintln!();

    // ── Reference codes ───────────────────────────────────────────────────────
    anyhow::ensure!(codes_path.exists(), "Codes file not found: {}", codes_path.display());
    eprintln!("[stream_pcm] Loading codes from {}…", codes_path.display());
    let ref_codes = tts.load_ref_codes(&codes_path)?;
    eprintln!(
        "  → {} tokens  ({:.1} s of reference audio)",
        ref_codes.len(),
        ref_codes.len() as f32 / 50.0,
    );
    eprintln!();

    // ── Phonemize ─────────────────────────────────────────────────────────────
    eprintln!("[stream_pcm] Phonemizing…");
    let ref_phones = neutts::phonemize::phonemize(&ref_text, "en-us")
        .context("Phonemisation of ref_text failed")?;
    let input_phones = neutts::phonemize::phonemize(&text, "en-us")
        .context("Phonemisation of text failed")?;
    let prompt = neutts::tokens::build_prompt(&ref_phones, &input_phones, &ref_codes);

    // ── Streaming synthesis ───────────────────────────────────────────────────
    eprintln!("[stream_pcm] Synthesising…");

    // Acquire a locked, buffered handle to stdout.  All PCM data is flushed
    // after each chunk so the downstream player receives audio immediately.
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    // Separate borrows of backbone and codec so the closure can use `codec`
    // while `backbone.generate_streaming` holds `&backbone`.
    let backbone_model = &tts.backbone;
    let codec          = &tts.codec;

    let mut pending:       Vec<i32>      = Vec::with_capacity(chunk_size + 8);
    let mut total_samples: usize         = 0;
    let mut total_tokens:  usize         = 0;
    let mut t_first_chunk: Option<f32>   = None;
    let     t_synth                      = Instant::now();

    backbone_model.generate_streaming(&prompt, 2048, |piece| {
        // Speech tokens arrive as complete special-token strings, e.g.
        // "<|speech_42|>".  extract_ids ignores any non-speech text.
        let ids = neutts::tokens::extract_ids(piece);
        if ids.is_empty() {
            return Ok(());
        }

        pending.extend_from_slice(&ids);
        total_tokens += ids.len();

        if pending.len() < chunk_size {
            return Ok(());
        }

        // ── Decode this chunk and write PCM ───────────────────────────────
        let audio = codec.decode(&pending)
            .context("NeuCodec decode failed")?;

        if t_first_chunk.is_none() {
            let ttfa = t_synth.elapsed().as_secs_f32();
            t_first_chunk = Some(ttfa);
            eprintln!(
                "  → first audio chunk after {ttfa:.2} s  \
                 ({} tokens, {:.0} ms of audio)",
                pending.len(),
                pending.len() as f32 * 1000.0 / 50.0,
            );
        }

        write_pcm_chunk(&audio, &mut out)?;
        total_samples += audio.len();
        pending.clear();

        Ok(())
    })?;

    // ── Flush any tokens that didn't fill a full chunk ────────────────────────
    if !pending.is_empty() {
        let audio = codec.decode(&pending)
            .context("NeuCodec decode (tail) failed")?;
        write_pcm_chunk(&audio, &mut out)?;
        total_samples += audio.len();
        total_tokens  += pending.len();
    }

    // Ensure the last bytes reach the downstream reader.
    out.flush().context("stdout flush failed")?;

    // ── Diagnostics ───────────────────────────────────────────────────────────
    let elapsed   = t_synth.elapsed().as_secs_f32();
    let audio_dur = total_samples as f32 / neutts::SAMPLE_RATE as f32;
    let rtf       = if audio_dur > 0.0 { elapsed / audio_dur } else { 0.0 };
    eprintln!();
    eprintln!(
        "[stream_pcm] Done: {total_tokens} tokens → {total_samples} samples \
         ({audio_dur:.2} s of audio)"
    );
    eprintln!(
        "[stream_pcm] Timing: total {elapsed:.2} s | RTF {rtf:.2}x | \
         TTFA {:.2} s",
        t_first_chunk.unwrap_or(elapsed),
    );

    Ok(())
}

// ─── PCM helpers ──────────────────────────────────────────────────────────────

/// Write `samples` as signed 16-bit little-endian PCM to `out`.
///
/// Each f32 sample is clamped to \[−1, 1\] before conversion.  No global
/// peak-normalisation is applied — that would require buffering the entire
/// signal, defeating the purpose of streaming.  The NeuCodec output is
/// already in a well-behaved range for most speech.
fn write_pcm_chunk(samples: &[f32], out: &mut impl io::Write) -> anyhow::Result<()> {
    // Pre-allocate the exact byte buffer to avoid per-sample allocations.
    let mut buf = vec![0u8; samples.len() * 2];
    for (i, &s) in samples.iter().enumerate() {
        let s16 = (s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
        let bytes = s16.to_le_bytes();
        buf[i * 2]     = bytes[0];
        buf[i * 2 + 1] = bytes[1];
    }
    out.write_all(&buf).context("PCM write failed")?;
    out.flush().context("PCM flush failed")?;
    Ok(())
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn truncate(s: &str, max: usize) -> String {
    let mut chars = s.chars();
    let head: String = chars.by_ref().take(max).collect();
    if chars.next().is_some() { format!("{head}…") } else { head }
}

fn print_help() {
    eprintln!(
        "stream_pcm — preload models once, stream raw PCM to stdout\n\
         \n\
         USAGE:\n\
         \tcargo run --example stream_pcm --features espeak -- [OPTIONS] | <player>\n\
         \n\
         REQUIRED:\n\
         \t--codes    / -c PATH   Pre-encoded .npy reference codes\n\
         \t--text     / -t TEXT   Text to synthesise\n\
         \n\
         OPTIONS:\n\
         \t--ref-text / -r TEXT   Transcript of the reference recording\n\
         \t                       (auto-detected from <codes_stem>.txt if omitted)\n\
         \t--backbone / -b REPO   HuggingFace backbone repo\n\
         \t                       (default: neuphonic/neutts-nano-q4-gguf)\n\
         \t--gguf-file / -g FILE  Specific GGUF filename within the repo\n\
         \t--chunk    / -k N      Tokens per decode chunk  (default: 25 = 500 ms)\n\
         \t--help     / -h        Show this help\n\
         \n\
         PCM FORMAT (stdout):\n\
         \tSigned 16-bit little-endian, 24 000 Hz, mono\n\
         \n\
         PLAYBACK EXAMPLES:\n\
         \t... | aplay  -f S16_LE -r 24000 -c 1            # Linux\n\
         \t... | sox    -t raw -r 24000 -e signed -b 16 -c 1 - -d  # macOS\n\
         \t... | ffplay -f s16le -ar 24000 -ac 1 -nodisp - # cross-platform\n\
         \n\
         SAVE TO FILE:\n\
         \t... > output.pcm\n\
         \tsox  -t raw -r 24000 -e signed -b 16 -c 1 output.pcm output.wav\n\
         \tffmpeg -f s16le -ar 24000 -ac 1 -i output.pcm  output.wav"
    );
}
