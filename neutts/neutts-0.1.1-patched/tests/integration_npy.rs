//! Integration tests for the NPY read/write round-trip.
//!
//! These tests verify that data written with `write_npy_i32` can be read back
//! by `load_npy_i32` with exact bit-level equality, and that the resulting
//! files are compatible with the NumPy `.npy` format spec.

use neutts::npy::{load_npy_i32, write_npy_i32};
fn tmp_path(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "neutts_it_{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

// ── Round-trip ───────────────────────────────────────────────────────────────

#[test]
fn npy_roundtrip_empty() {
    let path = tmp_path("empty.npy");
    write_npy_i32(&path, &[]).unwrap();
    let loaded = load_npy_i32(&path).unwrap();
    assert!(loaded.is_empty());
}

#[test]
fn npy_roundtrip_single() {
    let path = tmp_path("single.npy");
    write_npy_i32(&path, &[42]).unwrap();
    assert_eq!(load_npy_i32(&path).unwrap(), &[42]);
}

#[test]
fn npy_roundtrip_typical_ref_codes() {
    // Simulate a 10-second reference recording at 50 tokens/s → 500 codes.
    let codes: Vec<i32> = (0..500).map(|i| (i * 131) % 65536).collect();
    let path = tmp_path("ref_codes.npy");
    write_npy_i32(&path, &codes).unwrap();
    let loaded = load_npy_i32(&path).unwrap();
    assert_eq!(loaded, codes);
}

#[test]
fn npy_roundtrip_boundary_values() {
    let codes = vec![i32::MIN, -1, 0, 1, 65535, i32::MAX];
    let path = tmp_path("boundary.npy");
    write_npy_i32(&path, &codes).unwrap();
    assert_eq!(load_npy_i32(&path).unwrap(), codes);
}

// ── File format compliance ────────────────────────────────────────────────────

#[test]
fn npy_file_starts_with_magic() {
    let path = tmp_path("magic_check.npy");
    write_npy_i32(&path, &[1, 2, 3]).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..6], b"\x93NUMPY", "NPY magic bytes mismatch");
    assert_eq!(bytes[6], 1, "expected NPY version 1");
}

#[test]
fn npy_header_padded_to_64_bytes() {
    // The NPY spec (§2.1) requires the header *string* (the bytes after the
    // 10-byte fixed prefix) to be padded so that the data starts on a 64-byte
    // aligned boundary.  The HEADER_LEN field (u16 at bytes 8–9) stores the
    // padded length of the header string (including the trailing '\n').
    // Therefore `HEADER_LEN % 64 == 0` is the invariant we enforce.
    let path = tmp_path("padding.npy");
    write_npy_i32(&path, &[0, 1, 2]).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    // Header length field is at bytes 8–9 (u16 LE) per NPY v1.0 format.
    let hdr_len = u16::from_le_bytes([bytes[8], bytes[9]]) as usize;
    assert_eq!(
        hdr_len % 64,
        0,
        "HEADER_LEN ({hdr_len}) should be a multiple of 64"
    );
}

// ── Error handling ────────────────────────────────────────────────────────────

#[test]
fn npy_load_missing_file_returns_error() {
    let path = std::path::Path::new("/nonexistent/path/does_not_exist.npy");
    assert!(load_npy_i32(path).is_err());
}

#[test]
fn npy_load_bad_magic_returns_error() {
    let path = tmp_path("bad_magic.npy");
    std::fs::write(&path, b"NOTANPY\x00\x00\x00").unwrap();
    assert!(load_npy_i32(&path).is_err());
}

#[test]
fn npy_load_truncated_returns_error() {
    let path = tmp_path("truncated.npy");
    // Valid magic + version but header_len claims 128 bytes while file is tiny.
    let mut buf = b"\x93NUMPY\x01\x00".to_vec();
    buf.extend_from_slice(&128u16.to_le_bytes());
    buf.extend_from_slice(b"short"); // far less than 128 bytes
    std::fs::write(&path, &buf).unwrap();
    assert!(load_npy_i32(&path).is_err());
}
