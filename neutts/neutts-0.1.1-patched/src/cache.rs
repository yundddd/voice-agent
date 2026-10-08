//! Reference-code cache — avoids re-encoding the same WAV file twice.
//!
//! [`RefCodeCache`] uses the SHA-256 hash of the WAV file's raw bytes as a
//! cache key.  If the file content changes (even a single byte), the hash
//! changes and the codes are re-encoded automatically.
//!
//! ## Storage layout
//!
//! ```text
//! <cache_dir>/
//!   <sha256_of_wav>.npy   ← one file per unique reference audio
//! ```
//!
//! The default cache directory is platform-specific:
//!
//! | Platform       | Path                                     |
//! |----------------|------------------------------------------|
//! | Linux          | `~/.cache/neutts/ref_codes/`             |
//! | macOS          | `~/Library/Caches/neutts/ref_codes/`     |
//! | Windows        | `%LOCALAPPDATA%\neutts\ref_codes\`       |
//! | fallback       | `.neutts_cache/ref_codes/` (cwd)         |
//!
//! ## Example
//!
//! ```no_run
//! use neutts::{RefCodeCache, NeuCodecEncoder};
//! use std::path::Path;
//!
//! let encoder = neutts::download::load_encoder_from_hub(
//!     "neuphonic/neucodec-onnx-encoder"
//! ).unwrap();
//!
//! let cache = RefCodeCache::new().unwrap();
//!
//! // First call: encodes and caches (~seconds).
//! let (codes, cached) = cache.get_or_encode(Path::new("ref.wav"), &encoder).unwrap();
//! assert!(!cached);
//!
//! // Second call: loads from disk instantly.
//! let (codes2, cached2) = cache.get_or_encode(Path::new("ref.wav"), &encoder).unwrap();
//! assert!(cached2);
//! assert_eq!(codes, codes2);
//! ```

use std::io::Read;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};

use crate::codec::NeuCodecEncoder;
use crate::npy;

// ─────────────────────────────────────────────────────────────────────────────
// RefCodeCache
// ─────────────────────────────────────────────────────────────────────────────

/// Disk cache for pre-encoded NeuCodec reference codes.
///
/// Each cached entry is a `.npy` file whose name is the SHA-256 hex digest of
/// the source WAV file's raw bytes.  This means:
///
/// - **Same file, same codes** — the cached entry is reused instantly.
/// - **File changed** — the hash changes, the old entry is ignored, new codes
///   are encoded and cached under the new hash.
/// - **Portable** — the cache can be pre-populated on one machine and shared
///   with another; as long as the WAV bytes are identical the hash matches.
pub struct RefCodeCache {
    dir: PathBuf,
}

impl RefCodeCache {
    /// Create a cache backed by the platform default cache directory.
    ///
    /// The directory is created automatically if it does not exist.
    pub fn new() -> Result<Self> {
        let base = dirs::cache_dir()
            .unwrap_or_else(|| PathBuf::from(".neutts_cache"));
        Self::with_dir(base.join("neutts").join("ref_codes"))
    }

    /// Create a cache backed by a specific directory.
    ///
    /// The directory is created automatically if it does not exist.
    pub fn with_dir(dir: impl Into<PathBuf>) -> Result<Self> {
        let dir = dir.into();
        std::fs::create_dir_all(&dir)
            .with_context(|| format!("Cannot create cache directory: {}", dir.display()))?;
        Ok(Self { dir })
    }

    /// The directory where cached `.npy` files are stored.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Return the path where codes for a given WAV file would be cached,
    /// without reading the file or touching the cache.
    ///
    /// Useful for displaying the cache location to the user.
    pub fn cache_path_for(&self, wav_path: &Path) -> Result<PathBuf> {
        let hash = sha256_file(wav_path)?;
        Ok(self.dir.join(format!("{hash}.npy")))
    }

    /// Check whether a WAV file's codes are already cached.
    ///
    /// Reads and hashes the file to compute the key; does not decode the
    /// cached data.
    pub fn is_cached(&self, wav_path: &Path) -> Result<bool> {
        let path = self.cache_path_for(wav_path)?;
        Ok(path.exists())
    }

    /// Try to load cached codes for `wav_path` without encoding anything.
    ///
    /// Returns `Some((codes, outcome))` on a cache hit, `None` on a miss.
    /// Hashing the file is the only I/O performed on a miss.
    ///
    /// Use this when you want to decide *whether* to download an encoder
    /// before actually trying to load one:
    ///
    /// ```no_run
    /// # use neutts::{RefCodeCache, NeuCodecEncoder};
    /// # use std::path::Path;
    /// # let cache = RefCodeCache::new().unwrap();
    /// # let encoder: NeuCodecEncoder = todo!();
    /// let wav = Path::new("reference.wav");
    /// if let Some((codes, outcome)) = cache.try_load(wav).unwrap() {
    ///     println!("{outcome}");   // cache hit — no encoder needed
    /// } else {
    ///     let codes = encoder.encode_wav(wav).unwrap();
    ///     let outcome = cache.store(wav, &codes).unwrap();
    ///     println!("{outcome}");   // cache miss — freshly encoded
    /// }
    /// ```
    pub fn try_load(&self, wav_path: &Path) -> Result<Option<(Vec<i32>, CacheOutcome)>> {
        let hash       = sha256_file(wav_path)
            .with_context(|| format!("Failed to hash: {}", wav_path.display()))?;
        let cache_file = self.dir.join(format!("{hash}.npy"));

        if cache_file.exists() {
            let codes = npy::load_npy_i32(&cache_file)
                .with_context(|| format!("Failed to load cached codes: {}", cache_file.display()))?;
            Ok(Some((codes, CacheOutcome::Hit { path: cache_file, hash })))
        } else {
            Ok(None)
        }
    }

    /// Store pre-encoded codes in the cache and return a [`CacheOutcome::Miss`]
    /// describing the written file.
    ///
    /// The cache key is derived from the SHA-256 hash of `wav_path`'s raw bytes,
    /// so the same file will always map to the same cache entry.
    pub fn store(&self, wav_path: &Path, codes: &[i32]) -> Result<CacheOutcome> {
        let hash       = sha256_file(wav_path)
            .with_context(|| format!("Failed to hash: {}", wav_path.display()))?;
        let cache_file = self.dir.join(format!("{hash}.npy"));
        npy::write_npy_i32(&cache_file, codes)
            .with_context(|| format!("Failed to write cache: {}", cache_file.display()))?;
        Ok(CacheOutcome::Miss { path: cache_file, hash })
    }

    /// Return cached codes for `wav_path` if they exist, otherwise encode with
    /// `encoder`, cache the result, and return it.
    ///
    /// The cache key is the SHA-256 hash of the WAV file's raw bytes, so the
    /// entry is automatically invalidated whenever the file content changes.
    ///
    /// Prefer [`try_load`](Self::try_load) + [`store`](Self::store) when you
    /// want to avoid downloading the encoder on a cache hit.
    pub fn get_or_encode(
        &self,
        wav_path: &Path,
        encoder: &NeuCodecEncoder,
    ) -> Result<(Vec<i32>, CacheOutcome)> {
        if let Some(hit) = self.try_load(wav_path)? {
            return Ok(hit);
        }
        // Cache miss — encode and persist.
        let codes = encoder.encode_wav(wav_path)
            .with_context(|| format!("Failed to encode: {}", wav_path.display()))?;
        let outcome = self.store(wav_path, &codes)?;
        Ok((codes, outcome))
    }

    /// Evict the cached entry for `wav_path`, if any.
    ///
    /// Returns `true` if an entry was deleted, `false` if there was nothing to
    /// evict.
    pub fn evict(&self, wav_path: &Path) -> Result<bool> {
        let path = self.cache_path_for(wav_path)?;
        if path.exists() {
            std::fs::remove_file(&path)
                .with_context(|| format!("Failed to evict cache entry: {}", path.display()))?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// Delete all cached entries in this cache directory.
    ///
    /// Returns the number of files removed.
    pub fn clear(&self) -> Result<usize> {
        let mut count = 0;
        for entry in std::fs::read_dir(&self.dir)
            .with_context(|| format!("Cannot read cache dir: {}", self.dir.display()))?
        {
            let entry = entry.context("Failed to read dir entry")?;
            let path  = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("npy") {
                std::fs::remove_file(&path)
                    .with_context(|| format!("Failed to remove: {}", path.display()))?;
                count += 1;
            }
        }
        Ok(count)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CacheOutcome
// ─────────────────────────────────────────────────────────────────────────────

/// Result of a [`RefCodeCache::get_or_encode`] call.
#[derive(Debug, Clone)]
pub enum CacheOutcome {
    /// Codes were loaded from a cached `.npy` file — no encoding was needed.
    Hit {
        /// Path of the cached file that was read.
        path: PathBuf,
        /// SHA-256 hex digest used as the cache key.
        hash: String,
    },
    /// No cached entry existed; codes were freshly encoded and written to disk.
    Miss {
        /// Path of the newly written cache file.
        path: PathBuf,
        /// SHA-256 hex digest used as the cache key.
        hash: String,
    },
}

impl CacheOutcome {
    /// `true` if codes came from cache.
    pub fn is_hit(&self) -> bool {
        matches!(self, Self::Hit { .. })
    }

    /// Path of the cache file (read on hit, written on miss).
    pub fn path(&self) -> &Path {
        match self {
            Self::Hit  { path, .. } => path,
            Self::Miss { path, .. } => path,
        }
    }

    /// SHA-256 hex digest of the source WAV file.
    pub fn hash(&self) -> &str {
        match self {
            Self::Hit  { hash, .. } => hash,
            Self::Miss { hash, .. } => hash,
        }
    }
}

impl std::fmt::Display for CacheOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Hit  { hash, path } =>
                write!(f, "cache hit  (sha256: {}…)  ← {}", &hash[..16], path.display()),
            Self::Miss { hash, path } =>
                write!(f, "cache miss (sha256: {}…)  → {}", &hash[..16], path.display()),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hashing
// ─────────────────────────────────────────────────────────────────────────────

/// Compute the SHA-256 hex digest of a file's raw bytes using a streaming
/// 64 KiB read buffer (avoids loading the entire file into memory).
pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path)
        .with_context(|| format!("Cannot open file for hashing: {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf    = [0u8; 65_536];
    loop {
        let n = file.read(&mut buf)
            .with_context(|| format!("IO error while hashing: {}", path.display()))?;
        if n == 0 { break; }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "neutts_cache_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn test_sha256_file_deterministic() {
        // Write a known file and verify the hash is stable.
        let dir  = tmp_dir();
        let path = dir.join("test.bin");
        std::fs::write(&path, b"hello neutts").unwrap();

        let h1 = sha256_file(&path).unwrap();
        let h2 = sha256_file(&path).unwrap();
        assert_eq!(h1, h2);
        assert_eq!(h1.len(), 64); // SHA-256 = 32 bytes = 64 hex chars
    }

    #[test]
    fn test_sha256_changes_with_content() {
        let dir = tmp_dir();
        let p1  = dir.join("a.bin");
        let p2  = dir.join("b.bin");
        std::fs::write(&p1, b"file a").unwrap();
        std::fs::write(&p2, b"file b").unwrap();
        assert_ne!(sha256_file(&p1).unwrap(), sha256_file(&p2).unwrap());
    }

    #[test]
    fn test_cache_path_is_hash_based() {
        let dir   = tmp_dir();
        let cache = RefCodeCache::with_dir(&dir).unwrap();

        let wav = dir.join("ref.wav");
        std::fs::write(&wav, b"fake wav content").unwrap();

        let path = cache.cache_path_for(&wav).unwrap();
        let hash = sha256_file(&wav).unwrap();
        assert_eq!(path, dir.join(format!("{hash}.npy")));
    }

    #[test]
    fn test_is_cached_returns_false_before_write() {
        let dir   = tmp_dir();
        let cache = RefCodeCache::with_dir(&dir).unwrap();
        let wav   = dir.join("ref.wav");
        std::fs::write(&wav, b"fake wav").unwrap();
        assert!(!cache.is_cached(&wav).unwrap());
    }

    #[test]
    fn test_try_load_miss_then_store_then_hit() {
        let dir   = tmp_dir();
        let cache = RefCodeCache::with_dir(&dir).unwrap();
        let wav   = dir.join("ref.wav");
        std::fs::write(&wav, b"fake wav content 123").unwrap();

        // Miss before storing.
        assert!(cache.try_load(&wav).unwrap().is_none());

        // Store some fake codes.
        let codes: Vec<i32> = vec![1, 2, 3, 42, 1023];
        let outcome = cache.store(&wav, &codes).unwrap();
        assert!(!outcome.is_hit());

        // Hit after storing.
        let (loaded, outcome2) = cache.try_load(&wav).unwrap().unwrap();
        assert!(outcome2.is_hit());
        assert_eq!(loaded, codes);

        // store() and try_load() agree on the path.
        assert_eq!(outcome.path(), outcome2.path());
    }

    #[test]
    fn test_evict_removes_entry() {
        let dir   = tmp_dir();
        let cache = RefCodeCache::with_dir(&dir).unwrap();
        let wav   = dir.join("ref.wav");
        std::fs::write(&wav, b"fake wav").unwrap();

        // Manually write a fake cache entry.
        let hash = sha256_file(&wav).unwrap();
        let npy  = dir.join(format!("{hash}.npy"));
        std::fs::write(&npy, b"placeholder").unwrap();
        assert!(cache.is_cached(&wav).unwrap());

        let removed = cache.evict(&wav).unwrap();
        assert!(removed);
        assert!(!cache.is_cached(&wav).unwrap());
    }

    #[test]
    fn test_evict_nonexistent_returns_false() {
        let dir   = tmp_dir();
        let cache = RefCodeCache::with_dir(&dir).unwrap();
        let wav   = dir.join("ref.wav");
        std::fs::write(&wav, b"fake wav").unwrap();
        assert!(!cache.evict(&wav).unwrap());
    }

    #[test]
    fn test_clear_removes_all_npy() {
        let dir   = tmp_dir();
        let cache = RefCodeCache::with_dir(&dir).unwrap();

        // Write two fake .npy entries and one non-.npy file.
        std::fs::write(dir.join("aaa.npy"), b"x").unwrap();
        std::fs::write(dir.join("bbb.npy"), b"y").unwrap();
        std::fs::write(dir.join("keep.txt"), b"z").unwrap();

        let removed = cache.clear().unwrap();
        assert_eq!(removed, 2);
        assert!(!dir.join("aaa.npy").exists());
        assert!(!dir.join("bbb.npy").exists());
        assert!(dir.join("keep.txt").exists()); // non-.npy untouched
    }

    #[test]
    fn test_cache_outcome_display() {
        let hit = CacheOutcome::Hit {
            path: PathBuf::from("/cache/abc.npy"),
            hash: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890".to_string(),
        };
        let s = format!("{hit}");
        assert!(s.contains("cache hit"));
        assert!(s.contains("abcdef12345678"));
    }
}
