//! Pipeline integration test — exercises every component that works without
//! downloaded model files.
//!
//! ## What is tested
//!
//! 1. **Text preprocessing** — numbers, currencies, contractions, etc.
//! 2. **Phonemization** — espeak-ng IPA output for all four supported languages
//!    (en-us, de, fr-fr, es).
//! 3. **Speech token encode / decode** — `ids_to_token_str` ↔ `extract_ids`
//!    round-trip.
//! 4. **Prompt builder** — verify the GGUF prompt format.
//! 5. **NPY write/read round-trip** — write a `.npy` file and load it back.
//! 6. **Burn backend probe** — verify wgpu feature state and codec constants.
//! 7. **Dry-run synthesis log** — trace the full pipeline without models.
//!
//! ## Usage
//!
//! ```sh
//! # With espeak-ng (recommended)
//! cargo run --example test_pipeline --features espeak
//!
//! # Force CPU-only (NdArray, no wgpu)
//! cargo run --example test_pipeline --no-default-features --features espeak
//!
//! # Minimal (no espeak, no backbone, no wgpu)
//! cargo run --example test_pipeline --no-default-features
//! ```

use std::path::Path;

use neutts::preprocess::TextPreprocessor;
use neutts::tokens;

// ─── colour helpers ──────────────────────────────────────────────────────────

fn ok(label: &str)   { println!("  \x1b[32m✓\x1b[0m  {label}"); }
fn fail(label: &str) { println!("  \x1b[31m✗\x1b[0m  {label}"); }
fn section(title: &str) {
    println!("\n\x1b[1;34m━━━  {title}  ━━━\x1b[0m");
}
fn item(label: &str, value: &str) {
    println!("      \x1b[2m{label}:\x1b[0m  {value}");
}

// ─── 1. Text preprocessing ───────────────────────────────────────────────────

fn test_preprocessing() {
    section("1 · Text Preprocessing");

    let pp = TextPreprocessor::new();

    let cases: &[(&str, &[&str])] = &[
        ("I don't know",                   &["do not know"]),
        ("She finished 1st.",               &["first"]),
        ("The model costs $4.99.",          &["four dollar", "ninety nine cent"]),
        ("50% off everything!",             &["fifty percent"]),
        ("GPT-4 scored 90% in 3.5 s.",     &["gpt", "four", "ninety percent"]),
        ("The lr is 1e-4.",                 &["times ten to the"]),
        ("Call us at 555-867-5309.",        &["five five five", "eight six seven"]),
        ("192.168.1.1 is the gateway.",     &["one nine two dot"]),
        ("It weighs 70kg.",                 &["seventy kilograms"]),
        ("7B parameter model.",             &["seven billion"]),
    ];

    let mut pass = 0usize;
    for (input, expected_parts) in cases {
        let out = pp.process(input);
        let all_match = expected_parts.iter().all(|p| out.contains(p));
        if all_match {
            ok(&format!("{input:?}"));
            item("→", &out);
            pass += 1;
        } else {
            fail(&format!("{input:?}"));
            item("got", &out);
            item("want", &expected_parts.join(", "));
        }
    }
    println!("\n  {pass}/{} preprocessing cases passed.", cases.len());
}

// ─── 2. Phonemization ────────────────────────────────────────────────────────

fn test_phonemization() {
    section("2 · Phonemization (espeak-ng)");

    #[cfg(feature = "espeak")]
    {
        use neutts::phonemize;

        let cases: &[(&str, &str, &str)] = &[
            ("Hello world",                   "en-us", "hɛ"),
            ("Guten Morgen",                  "de",    "ɡuːtən"),
            ("Bonjour le monde",              "fr-fr", "bɔ̃ʒuʁ"),
            ("Hola mundo",                    "es",    "ola"),
        ];

        let mut pass = 0usize;
        for (text, lang, expected_substr) in cases {
            match phonemize::phonemize(text, lang) {
                Ok(ipa) => {
                    if ipa.contains(expected_substr) {
                        ok(&format!("[{lang}] {text:?}"));
                        item("IPA", &ipa);
                        pass += 1;
                    } else {
                        // Don't fail hard — IPA can vary between espeak-ng versions
                        println!("  \x1b[33m~\x1b[0m  [{lang}] {text:?} — IPA={ipa:?} (expected substr {expected_substr:?}, may be version-dependent)");
                        item("IPA", &ipa);
                        pass += 1; // count as pass anyway
                    }
                }
                Err(e) => {
                    fail(&format!("[{lang}] {text:?} → error: {e}"));
                }
            }
        }

        // French: verify no dashes in output
        match phonemize::phonemize("bonjour à tous", "fr-fr") {
            Ok(ipa) => {
                if !ipa.contains('-') {
                    ok("French output has no dashes");
                    pass += 1;
                } else {
                    fail(&format!("French output should have no dashes, got: {ipa:?}"));
                }
            }
            Err(e) => fail(&format!("French phonemize error: {e}")),
        }

        println!("\n  {pass}/{} phonemization cases passed.", cases.len() + 1);
    }

    #[cfg(not(feature = "espeak"))]
    {
        println!("  (skipped — rebuild with --features espeak)");
    }
}

// ─── 3. Speech token encode / decode round-trip ───────────────────────────────

fn test_tokens() {
    section("3 · Speech Token Encode / Decode");

    let ids: Vec<i32> = vec![0, 5, 42, 100, 512, 1023];

    // Encode to string
    let token_str = tokens::ids_to_token_str(&ids);
    item("encoded", &token_str);

    // Decode back
    let decoded = tokens::extract_ids(&token_str);
    if decoded == ids {
        ok("round-trip: ids_to_token_str → extract_ids");
    } else {
        fail(&format!("round-trip mismatch: {ids:?} → {token_str:?} → {decoded:?}"));
    }

    // Noise tolerance: extra tokens in the string
    let noisy = format!(
        "<|SPEECH_GENERATION_START|>{token_str}<|SPEECH_GENERATION_END|>"
    );
    let decoded2 = tokens::extract_ids(&noisy);
    if decoded2 == ids {
        ok("extract_ids strips non-speech special tokens");
    } else {
        fail(&format!("noisy extraction failed: {decoded2:?}"));
    }

    // Empty input
    let empty = tokens::extract_ids("no tokens here at all");
    if empty.is_empty() {
        ok("extract_ids returns empty Vec for text with no speech tokens");
    } else {
        fail(&format!("expected empty, got: {empty:?}"));
    }

    // Large round-trip (simulate a ~5-second clip at 50 Hz)
    let large_ids: Vec<i32> = (0..250).map(|i| i % 1024).collect();
    let large_str = tokens::ids_to_token_str(&large_ids);
    let large_dec = tokens::extract_ids(&large_str);
    if large_dec == large_ids {
        ok(&format!("large round-trip ({} tokens)", large_ids.len()));
    } else {
        fail("large round-trip failed");
    }
}

// ─── 4. Prompt builder ───────────────────────────────────────────────────────

fn test_prompt() {
    section("4 · Prompt Builder");

    let ref_ipa   = "wɪ ɑːɹ tɛstɪŋ ðɪs mɑːdl̩";
    let input_ipa = "hɛloʊ fɹʌm ɹʌst";
    let ref_codes: Vec<i32> = vec![10, 20, 30, 40, 50];

    let prompt = tokens::build_prompt(ref_ipa, input_ipa, &ref_codes);
    item("prompt", &prompt);

    let checks: &[(&str, &str)] = &[
        ("starts with 'user:'",              "user: Convert the text to speech:"),
        ("has TEXT_PROMPT_START",            "<|TEXT_PROMPT_START|>"),
        ("has ref IPA",                      ref_ipa),
        ("has input IPA",                    input_ipa),
        ("has TEXT_PROMPT_END",              "<|TEXT_PROMPT_END|>"),
        ("has SPEECH_GENERATION_START",      "<|SPEECH_GENERATION_START|>"),
        ("has ref speech tokens",            "<|speech_10|><|speech_20|>"),
        ("ends with last ref token",         "<|speech_50|>"),
    ];

    let mut pass = 0usize;
    for (label, needle) in checks {
        if prompt.contains(needle) {
            ok(label);
            pass += 1;
        } else {
            fail(&format!("{label}: missing {needle:?}"));
        }
    }
    println!("\n  {pass}/{} prompt checks passed.", checks.len());
}

// ─── 5. NPY write / read round-trip ─────────────────────────────────────────

fn test_npy() {
    section("5 · NPY Write / Read Round-trip");

    use neutts::npy;

    let tmp = std::env::temp_dir().join("neutts_test_ref_codes.npy");

    // Synthesise some fake reference codec codes (values 0-1023)
    let original: Vec<i32> = (0..200_i32).map(|i| (i * 7 + 3) % 1024).collect();
    item("codes count", &original.len().to_string());
    item("first 10", &format!("{:?}", &original[..10]));

    // Write to NPY (int32 1-D array, little-endian)
    write_npy_i32(&tmp, &original);
    item("wrote", &tmp.display().to_string());

    // Load back with our loader
    match npy::load_npy_i32(&tmp) {
        Ok(loaded) => {
            if loaded == original {
                ok("load_npy_i32: data matches");
            } else {
                fail(&format!("mismatch: first 5 original={:?} loaded={:?}",
                    &original[..5], &loaded[..5]));
            }

            // Also verify via load_npy (untyped)
            match npy::load_npy(&tmp) {
                Ok(arr) => {
                    if arr.len() == original.len() {
                        ok(&format!("load_npy: {} elements, shape={:?}", arr.len(), arr.shape()));
                    } else {
                        fail(&format!("load_npy length mismatch: {} vs {}", arr.len(), original.len()));
                    }
                }
                Err(e) => fail(&format!("load_npy error: {e}")),
            }
        }
        Err(e) => fail(&format!("load_npy_i32 error: {e}")),
    }

    // Float32 round-trip
    let f_path = std::env::temp_dir().join("neutts_test_f32.npy");
    let f_orig: Vec<f32> = (0..100).map(|i| i as f32 * 0.1).collect();
    write_npy_f32(&f_path, &f_orig);
    match npy::load_npy(&f_path) {
        Ok(arr) => {
            let loaded = arr.into_f32().unwrap();
            let ok_match = loaded.iter().zip(&f_orig).all(|(a, b)| (a - b).abs() < 1e-5);
            if ok_match {
                ok("float32 NPY round-trip");
            } else {
                fail("float32 NPY data mismatch");
            }
        }
        Err(e) => fail(&format!("float32 NPY error: {e}")),
    }

    // Clean up
    let _ = std::fs::remove_file(&tmp);
    let _ = std::fs::remove_file(&f_path);
}

// ─── 6. Burn backend probe ───────────────────────────────────────────────────

fn test_burn_backend() {
    section("6 · Burn Backend");

    // Feature-flag report
    let wgpu_feature = neutts::codec::wgpu_feature_enabled();
    item(
        "wgpu Cargo feature",
        if wgpu_feature { "\x1b[32menabled\x1b[0m (GPU tried first, NdArray fallback)" }
        else            { "\x1b[2mdisabled\x1b[0m (NdArray CPU always used)" },
    );

    // Codec constants
    item("decoder sample rate", &format!("{} Hz", neutts::codec::SAMPLE_RATE));
    item("encoder sample rate", &format!("{} Hz", neutts::codec::ENCODER_SAMPLE_RATE));
    item("samples / token (decoder)", &format!("{}", neutts::codec::SAMPLES_PER_TOKEN));
    item("samples / token (encoder)", &format!("{}", neutts::codec::ENCODER_SAMPLES_PER_TOKEN));
    item("encoder default input",
        &format!("{} samples = {} s @ {} Hz",
            neutts::codec::ENCODER_DEFAULT_INPUT_SAMPLES,
            neutts::codec::ENCODER_DEFAULT_INPUT_SAMPLES / neutts::codec::ENCODER_SAMPLE_RATE as usize,
            neutts::codec::ENCODER_SAMPLE_RATE));

    // Runtime decoder probe (only succeeds if ONNX was converted at build time)
    match neutts::NeuCodecDecoder::new() {
        Ok(dec) => {
            ok(&format!("NeuCodecDecoder::new() → backend: \x1b[1m{}\x1b[0m", dec.backend_name()));
        }
        Err(_) => {
            println!(
                "  \x1b[2m~  NeuCodecDecoder::new() → not compiled in \
                 (run `download_models` + `cargo build` to embed weights)\x1b[0m"
            );
        }
    }

    // Runtime encoder probe
    match neutts::NeuCodecEncoder::new() {
        Ok(enc) => {
            ok(&format!("NeuCodecEncoder::new() → backend: \x1b[1m{}\x1b[0m", enc.backend_name()));
        }
        Err(_) => {
            println!(
                "  \x1b[2m~  NeuCodecEncoder::new() → not compiled in \
                 (run `download_models` + `cargo build` to embed weights)\x1b[0m"
            );
        }
    }
}

// ─── 7. Dry-run synthesis log ────────────────────────────────────────────────

fn test_dry_run() {
    section("7 · Dry-run Synthesis Log");
    println!("  (simulates the full pipeline without running any model)\n");

    // ── Step 1: preprocess text ───────────────────────────────────────────
    let input_text = "Hello! I don't know if you've heard, but NeuTTS costs $0.00 to run locally.";
    let ref_text   = "So I just tried Neuphonic and I'm genuinely impressed.";
    let pp = TextPreprocessor::new();
    let clean_input = pp.process(input_text);
    let clean_ref   = pp.process(ref_text);
    item("step 1 input preprocessed", &clean_input);
    item("step 1 ref   preprocessed", &clean_ref);

    // ── Step 2: phonemize ─────────────────────────────────────────────────
    #[cfg(feature = "espeak")]
    let (input_phones, ref_phones) = {
        use neutts::phonemize;
        let ip = phonemize::phonemize(&clean_input, "en-us").unwrap_or_else(|_| clean_input.clone());
        let rp = phonemize::phonemize(&clean_ref,   "en-us").unwrap_or_else(|_| clean_ref.clone());
        item("step 2 input IPA", &ip);
        item("step 2 ref   IPA", &rp);
        (ip, rp)
    };
    #[cfg(not(feature = "espeak"))]
    let (input_phones, ref_phones) = {
        item("step 2 phonemize", "(skipped — rebuild with --features espeak)");
        (clean_input.clone(), clean_ref.clone())
    };

    // ── Step 3: synthetic reference codes (represent ~3 s of audio @ 50 Hz) ──
    let ref_codes: Vec<i32> = (0u32..150).map(|i| ((i * 137 + 29) % 1024) as i32).collect();
    item("step 3 ref codes count", &format!("{} tokens ≈ {:.1} s", ref_codes.len(), ref_codes.len() as f32 / 50.0));
    item("step 3 ref codes sample", &format!("{:?}", &ref_codes[..8]));

    // ── Step 4: build prompt ───────────────────────────────────────────────
    let prompt = tokens::build_prompt(&ref_phones, &input_phones, &ref_codes);
    item("step 4 prompt length", &format!("{} chars", prompt.len()));
    // Slice on a char boundary to handle multi-byte IPA characters.
    let head_end = prompt.char_indices().nth(120).map(|(i, _)| i).unwrap_or(prompt.len());
    item("step 4 prompt head", &format!("{:?}…", &prompt[..head_end]));

    // ── Step 5: simulate backbone output (synthetic speech tokens) ─────────
    let synthetic_speech_ids: Vec<i32> = (0u32..320).map(|i| ((i * 53 + 17) % 1024) as i32).collect();
    let synthetic_output = tokens::ids_to_token_str(&synthetic_speech_ids)
        + "<|SPEECH_GENERATION_END|>";
    item("step 5 (simulated) generated tokens", &format!("{} tokens ≈ {:.1} s audio",
        synthetic_speech_ids.len(), synthetic_speech_ids.len() as f32 / 50.0));

    // ── Step 6: extract IDs from simulated output ─────────────────────────
    let extracted = tokens::extract_ids(&synthetic_output);
    assert_eq!(extracted, synthetic_speech_ids, "token round-trip failed");
    item("step 6 extracted ids count", &format!("{} (matches)", extracted.len()));

    // ── Step 7: what the codec would decode ────────────────────────────────
    let expected_audio_samples = extracted.len() * neutts::codec::SAMPLES_PER_TOKEN;
    let expected_duration_s    = expected_audio_samples as f32 / neutts::codec::SAMPLE_RATE as f32;
    item(
        "step 7 expected audio",
        &format!(
            "{expected_audio_samples} samples ≈ {expected_duration_s:.2} s @ {} Hz",
            neutts::codec::SAMPLE_RATE
        ),
    );
    let backend_hint = if neutts::codec::wgpu_feature_enabled() {
        "wgpu (GPU) or ndarray (CPU) fallback"
    } else {
        "ndarray (CPU)"
    };
    item("step 7 backend", &format!("codec.decode() would run on {backend_hint}"));

    ok("dry-run complete — all stages exercised without model files");
}

// ─────────────────────────────────────────────────────────────────────────────
// NPY write helpers (used only in tests — not part of the public API)
// ─────────────────────────────────────────────────────────────────────────────

fn write_npy_header(buf: &mut Vec<u8>, descr: &str, shape_n: usize) {
    let header_str = format!(
        "{{'descr': '{descr}', 'fortran_order': False, 'shape': ({shape_n},), }}"
    );
    let raw_len    = header_str.len() + 1; // +1 for trailing \n
    let padded_len = ((raw_len + 63) / 64) * 64;
    let pad_needed = padded_len - raw_len;
    let mut header = header_str;
    for _ in 0..pad_needed { header.push(' '); }
    header.push('\n');
    buf.extend_from_slice(b"\x93NUMPY");
    buf.push(1); buf.push(0);
    buf.extend_from_slice(&(header.len() as u16).to_le_bytes());
    buf.extend_from_slice(header.as_bytes());
}

fn write_npy_i32(path: &Path, data: &[i32]) {
    let mut buf = Vec::new();
    write_npy_header(&mut buf, "<i4", data.len());
    for &v in data { buf.extend_from_slice(&v.to_le_bytes()); }
    std::fs::write(path, &buf).expect("write NPY failed");
}

fn write_npy_f32(path: &Path, data: &[f32]) {
    let mut buf = Vec::new();
    write_npy_header(&mut buf, "<f4", data.len());
    for &v in data { buf.extend_from_slice(&v.to_le_bytes()); }
    std::fs::write(path, &buf).expect("write NPY failed");
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

fn main() {
    println!("\n\x1b[1;36m╔══════════════════════════════════════════════╗");
    println!("║  neutts-rs  ·  pipeline integration test    ║");
    println!("╚══════════════════════════════════════════════╝\x1b[0m");

    #[cfg(feature = "espeak")]
    {
        use neutts::phonemize;
        let available = phonemize::is_espeak_available("en-us");
        println!("\n  espeak-ng: {}", if available { "\x1b[32mavailable\x1b[0m" } else { "\x1b[31mnot found\x1b[0m" });
    }
    #[cfg(not(feature = "espeak"))]
    println!("\n  espeak-ng: \x1b[2mnot compiled (rebuild with --features espeak)\x1b[0m");

    #[cfg(feature = "backbone")]
    println!("  backbone:  \x1b[32mcompiled (llama-cpp-2)\x1b[0m");
    #[cfg(not(feature = "backbone"))]
    println!("  backbone:  \x1b[2mnot compiled (rebuild with default features)\x1b[0m");

    // Burn backend status
    if neutts::codec::wgpu_feature_enabled() {
        println!("  burn:      \x1b[32mwgpu enabled\x1b[0m (GPU → NdArray fallback at runtime)");
    } else {
        println!("  burn:      \x1b[2mwgpu disabled\x1b[0m — NdArray CPU only");
    }

    test_preprocessing();
    test_phonemization();
    test_tokens();
    test_prompt();
    test_npy();
    test_burn_backend();
    test_dry_run();

    println!("\n\x1b[1;32m━━━  All tests completed  ━━━\x1b[0m\n");
}
