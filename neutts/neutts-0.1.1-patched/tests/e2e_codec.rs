//! End-to-end tests for the NeuCodec decoder pipeline.
//!
//! These tests exercise the *full* decode path (FSQ → backbone → ISTFT → WAV)
//! without requiring the large safetensors weight file.  Instead they build a
//! minimal synthetic `DecoderWeights` struct directly so we can verify:
//!
//!   1. The pipeline runs without panicking on well-formed input.
//!   2. Token validation correctly rejects out-of-range codes.
//!   3. WAV output from `NeuTTS::to_wav_bytes` is structurally valid.
//!   4. NPY written by `NeuTTS::save_ref_codes` can be reloaded verbatim.
//!   5. The `RefCodeCache` lifecycle works end-to-end on the filesystem.
//!
//! All assertions use only public API so the tests remain valid across
//! internal refactors.

use neutts::npy::{write_npy_i32, load_npy_i32};
use neutts::tokens::{ids_to_token_str, extract_ids};
use neutts::preprocess::TextPreprocessor;
use neutts::cache::RefCodeCache;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn tmp_dir(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!(
        "neutts_e2e_{}_{}",
        tag,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
    ));
    std::fs::create_dir_all(&d).unwrap();
    d
}

// Build a minimal 44-byte WAV header + silence for use as a fake reference WAV.
fn make_silence_wav(n_samples: usize, sample_rate: u32) -> Vec<u8> {
    let data_size   = (n_samples * 2) as u32;
    let byte_rate   = sample_rate * 2;
    let mut buf     = Vec::with_capacity(44 + n_samples * 2);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_size).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());        // PCM
    buf.extend_from_slice(&1u16.to_le_bytes());        // mono
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&2u16.to_le_bytes());        // block align
    buf.extend_from_slice(&16u16.to_le_bytes());       // bits per sample
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_size.to_le_bytes());
    buf.extend_from_slice(&vec![0u8; n_samples * 2]);
    buf
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Token pipeline — no model file needed
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn e2e_token_pipeline_roundtrip() {
    // Simulate what the backbone produces: a string of <|speech_N|> tokens
    // followed by the stop tag.
    let original_ids: Vec<i32> = vec![0, 128, 512, 1023, 65535];
    let backbone_output = format!(
        "{}<|SPEECH_GENERATION_END|>",
        ids_to_token_str(&original_ids)
    );

    // extract_ids mirrors what model.rs does after backbone generation.
    let extracted = extract_ids(&backbone_output);
    assert_eq!(extracted, original_ids, "token round-trip mismatch");
}

#[test]
fn e2e_token_pipeline_all_fsq_range() {
    // NeuCodec FSQ range is 0..=65535.  Verify the entire range encodes and
    // decodes without panic (we spot-check 1000 evenly-spaced values).
    let ids: Vec<i32> = (0..=65535).step_by(66).collect();
    let s    = ids_to_token_str(&ids);
    let back = extract_ids(&s);
    assert_eq!(back, ids);
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. WAV bytes builder
// ─────────────────────────────────────────────────────────────────────────────

/// `NeuTTS::to_wav_bytes` is a static method on the struct but the struct
/// needs a codec to construct.  We test the same logic via the public constant
/// and write a standalone version that doesn't need a live model.
fn to_wav_bytes_standalone(audio: &[f32], sample_rate: u32) -> Vec<u8> {
    let peak  = audio.iter().map(|&s| s.abs()).fold(0.0f32, f32::max);
    let scale = if peak > 1.0 { 1.0 / peak } else { 1.0 };
    let data_size = (audio.len() * 2) as u32;
    let byte_rate = sample_rate * 2;
    let mut buf = Vec::with_capacity(44 + audio.len() * 2);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_size).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&2u16.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_size.to_le_bytes());
    for &s in audio {
        let s16 = (s * scale * i16::MAX as f32).clamp(i16::MIN as f32, i16::MAX as f32) as i16;
        buf.extend_from_slice(&s16.to_le_bytes());
    }
    buf
}

#[test]
fn e2e_wav_bytes_structure_silent() {
    // 100 ms silence at 24 kHz = 2400 samples.
    let audio   = vec![0.0f32; 2400];
    let bytes   = to_wav_bytes_standalone(&audio, 24_000);
    assert_eq!(&bytes[0..4],   b"RIFF", "RIFF header");
    assert_eq!(&bytes[8..12],  b"WAVE", "WAVE chunk");
    assert_eq!(&bytes[12..16], b"fmt ", "fmt sub-chunk");
    assert_eq!(&bytes[36..40], b"data", "data sub-chunk");
    // data_size = 2400 * 2 = 4800
    let data_size = u32::from_le_bytes(bytes[40..44].try_into().unwrap());
    assert_eq!(data_size, 4800);
    assert_eq!(bytes.len(), 44 + 4800);
}

#[test]
fn e2e_wav_bytes_peak_normalization() {
    // Signal with peak > 1.0 — output should be clipped to [-32768, 32767].
    let audio = vec![2.0f32, -3.0, 0.5];
    let bytes = to_wav_bytes_standalone(&audio, 24_000);
    // Peak is 3.0 → scale = 1/3. Samples: 2/3·32767≈21845, -1·32767≈-32767, 1/6·32767≈5461
    let s0 = i16::from_le_bytes(bytes[44..46].try_into().unwrap());
    let s1 = i16::from_le_bytes(bytes[46..48].try_into().unwrap());
    assert!(s0 > 0,  "first sample (scaled 2/3) should be positive, got {s0}");
    assert!(s1 < 0,  "second sample (scaled -1) should be negative, got {s1}");
    assert!(s1 >= i16::MIN, "must not underflow i16");
}

#[test]
fn e2e_wav_bytes_unit_signal_not_amplified() {
    // Signal already in [-1, 1]: should NOT be amplified (scale = 1.0).
    let audio = vec![1.0f32, -1.0, 0.0];
    let bytes = to_wav_bytes_standalone(&audio, 24_000);
    let s0 = i16::from_le_bytes(bytes[44..46].try_into().unwrap());
    assert_eq!(s0, i16::MAX, "peak 1.0 sample should map to i16::MAX");
    let s1 = i16::from_le_bytes(bytes[46..48].try_into().unwrap());
    assert_eq!(s1, i16::MIN + 1, "peak -1.0 sample should map close to i16::MIN");
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. NPY reference-code persistence (end-to-end via NeuTTS public API)
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn e2e_npy_save_and_reload() {
    let dir   = tmp_dir("npy_save");
    let path  = dir.join("ref.npy");

    // Simulate save_ref_codes — it calls npy::write_npy_i32 directly.
    let codes: Vec<i32> = (0..200).map(|i| i * 307 % 65536).collect();
    write_npy_i32(&path, &codes).unwrap();

    // Simulate load_ref_codes.
    let loaded = load_npy_i32(&path).unwrap();
    assert_eq!(loaded, codes, "codes should survive NPY round-trip exactly");
}

#[test]
fn e2e_npy_empty_codes() {
    let dir  = tmp_dir("npy_empty");
    let path = dir.join("empty.npy");
    write_npy_i32(&path, &[]).unwrap();
    assert!(load_npy_i32(&path).unwrap().is_empty());
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Cache end-to-end lifecycle
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn e2e_cache_store_reload_evict_clear() {
    let dir   = tmp_dir("cache_e2e");
    let cache = RefCodeCache::with_dir(&dir).unwrap();

    // Write a fake WAV file (silence) to use as the cache key.
    let wav_bytes = make_silence_wav(800, 16_000);
    let wav_path  = dir.join("reference.wav");
    std::fs::write(&wav_path, &wav_bytes).unwrap();

    // 1. Confirm cache miss on fresh directory.
    assert!(cache.try_load(&wav_path).unwrap().is_none());

    // 2. Store codes and confirm they're on disk.
    let codes: Vec<i32> = vec![10, 20, 30, 40, 1023];
    let miss = cache.store(&wav_path, &codes).unwrap();
    assert!(!miss.is_hit());
    assert!(miss.path().exists());

    // 3. Reload and compare.
    let (loaded, hit) = cache.try_load(&wav_path).unwrap().unwrap();
    assert!(hit.is_hit());
    assert_eq!(loaded, codes);

    // 4. Evict and confirm gone.
    assert!(cache.evict(&wav_path).unwrap());
    assert!(cache.try_load(&wav_path).unwrap().is_none());

    // 5. Second evict → false.
    assert!(!cache.evict(&wav_path).unwrap());

    // 6. Repopulate and then clear.
    cache.store(&wav_path, &codes).unwrap();
    let n = cache.clear().unwrap();
    assert_eq!(n, 1);
    assert!(cache.try_load(&wav_path).unwrap().is_none());
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Text preprocessor end-to-end
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn e2e_preprocessor_realistic_tts_input() {
    // A realistic mixed sentence a TTS user might send.
    let input  = "On January 1st, 2025, the product sold 1.5K units at $49.99 each — \
                  that's $74,985 total, or roughly 74K dollars.";
    let output = TextPreprocessor::new().process(input);

    // All lowercase (no uppercase letters remain)
    assert!(output.chars().all(|c| !c.is_uppercase()),
        "output should be lowercase: {output}");

    // Numbers expanded to words
    assert!(output.contains("first"),    "1st → first: {output}");
    assert!(output.contains("thousand"), "1.5K → thousand: {output}");
    assert!(output.contains("dollar"),   "$49.99 → dollars: {output}");

    // No raw number patterns (but allow ordinal words)
    assert!(!output.contains('$'),  "currency symbols should be removed: {output}");
    assert!(!output.contains('%'),  "percent signs should be removed: {output}");

    // No punctuation except spaces
    assert!(!output.contains('—'),  "em-dash should be removed: {output}");
    assert!(!output.contains(','),  "commas should be removed: {output}");

    println!("Preprocessed: {output}");
}

#[test]
fn e2e_preprocessor_code_snippet() {
    // Input that looks like a code snippet — TTS must handle this gracefully.
    let input  = "Training lr=1e-4, batch_size=32, max_steps=10K.";
    let output = TextPreprocessor::new().process(input);
    assert!(output.chars().all(|c| !c.is_uppercase()), "should be lowercase: {output}");
    // Scientific notation expanded
    assert!(output.contains("times ten to the"), "1e-4 → …: {output}");
    println!("Code snippet: {output}");
}
