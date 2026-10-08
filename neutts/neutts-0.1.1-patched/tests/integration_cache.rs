//! Integration tests for the [`RefCodeCache`].
//!
//! These tests exercise the full store → evict → clear lifecycle using
//! real temporary directories, verifying correct SHA-256 keying and
//! NPY persistence.

use neutts::cache::RefCodeCache;

fn tmp_dir(suffix: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!(
        "neutts_cache_it_{}_{}",
        suffix,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
    ));
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn write_fake_wav(dir: &std::path::Path, name: &str, content: &[u8]) -> std::path::PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, content).unwrap();
    p
}

// ── Store + Hit cycle ─────────────────────────────────────────────────────────

#[test]
fn cache_store_and_hit() {
    let dir   = tmp_dir("store_hit");
    let cache = RefCodeCache::with_dir(&dir).unwrap();
    let wav   = write_fake_wav(&dir, "ref.wav", b"fake wav bytes for test");

    // Miss before storing
    assert!(cache.try_load(&wav).unwrap().is_none());

    // Store
    let codes: Vec<i32> = vec![0, 1, 1023, 65535];
    let miss_outcome = cache.store(&wav, &codes).unwrap();
    assert!(!miss_outcome.is_hit(), "store() should report a Miss");
    assert!(miss_outcome.path().exists(), "cache file should exist after store");

    // Hit
    let (loaded, hit_outcome) = cache.try_load(&wav).unwrap().unwrap();
    assert!(hit_outcome.is_hit(), "try_load() should report a Hit");
    assert_eq!(loaded, codes, "loaded codes should match stored codes");
    assert_eq!(miss_outcome.path(), hit_outcome.path(), "paths should agree");
    assert_eq!(miss_outcome.hash(), hit_outcome.hash(), "hashes should agree");
}

// ── Content-addressed keying ──────────────────────────────────────────────────

#[test]
fn cache_different_content_different_key() {
    let dir   = tmp_dir("diff_keys");
    let cache = RefCodeCache::with_dir(&dir).unwrap();

    let wav_a = write_fake_wav(&dir, "a.wav", b"content A");
    let wav_b = write_fake_wav(&dir, "b.wav", b"content B");

    cache.store(&wav_a, &[1, 2, 3]).unwrap();
    cache.store(&wav_b, &[4, 5, 6]).unwrap();

    let (codes_a, _) = cache.try_load(&wav_a).unwrap().unwrap();
    let (codes_b, _) = cache.try_load(&wav_b).unwrap().unwrap();

    assert_eq!(codes_a, &[1, 2, 3]);
    assert_eq!(codes_b, &[4, 5, 6]);
    assert_ne!(
        cache.cache_path_for(&wav_a).unwrap(),
        cache.cache_path_for(&wav_b).unwrap(),
        "distinct WAV contents should produce distinct cache paths"
    );
}

#[test]
fn cache_same_content_same_key() {
    let dir   = tmp_dir("same_key");
    let cache = RefCodeCache::with_dir(&dir).unwrap();

    let wav_x = write_fake_wav(&dir, "x.wav", b"identical content");
    let wav_y = write_fake_wav(&dir, "y.wav", b"identical content");

    assert_eq!(
        cache.cache_path_for(&wav_x).unwrap(),
        cache.cache_path_for(&wav_y).unwrap(),
        "files with identical bytes should map to the same cache key"
    );
}

// ── Evict ─────────────────────────────────────────────────────────────────────

#[test]
fn cache_evict_clears_entry() {
    let dir   = tmp_dir("evict");
    let cache = RefCodeCache::with_dir(&dir).unwrap();
    let wav   = write_fake_wav(&dir, "ev.wav", b"evict me");

    cache.store(&wav, &[7, 8, 9]).unwrap();
    assert!(cache.is_cached(&wav).unwrap());

    let removed = cache.evict(&wav).unwrap();
    assert!(removed, "evict should return true when an entry existed");
    assert!(!cache.is_cached(&wav).unwrap(), "entry should be gone after evict");

    // Evict again → false
    assert!(!cache.evict(&wav).unwrap());
}

// ── Clear ─────────────────────────────────────────────────────────────────────

#[test]
fn cache_clear_removes_all_npy_leaves_others() {
    let dir   = tmp_dir("clear");
    let cache = RefCodeCache::with_dir(&dir).unwrap();

    // Write two WAV-keyed cache entries + one non-NPY file
    let wav1 = write_fake_wav(&dir, "w1.wav", b"wav1");
    let wav2 = write_fake_wav(&dir, "w2.wav", b"wav2");
    cache.store(&wav1, &[10]).unwrap();
    cache.store(&wav2, &[20]).unwrap();
    std::fs::write(dir.join("readme.txt"), b"keep me").unwrap();

    let removed = cache.clear().unwrap();
    assert_eq!(removed, 2, "clear should remove exactly 2 .npy files");
    assert!(!cache.is_cached(&wav1).unwrap());
    assert!(!cache.is_cached(&wav2).unwrap());
    assert!(dir.join("readme.txt").exists(), "non-npy file must be untouched");
}

// ── Display formatting ────────────────────────────────────────────────────────

#[test]
fn cache_outcome_display_contains_expected_parts() {
    let dir   = tmp_dir("display");
    let cache = RefCodeCache::with_dir(&dir).unwrap();
    let wav   = write_fake_wav(&dir, "disp.wav", b"display test wav content");

    let miss = cache.store(&wav, &[0, 1, 2]).unwrap();
    let s    = format!("{miss}");
    assert!(s.contains("cache miss"), "Miss display: {s}");

    let (_, hit) = cache.try_load(&wav).unwrap().unwrap();
    let s = format!("{hit}");
    assert!(s.contains("cache hit"), "Hit display: {s}");
}
