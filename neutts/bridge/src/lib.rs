//! C FFI bridge over the [`neutts`] crate for use from Dart FFI.
//!
//! Exposes a small, stable surface the app's `SpeechWorker` uses:
//!
//! 1. [`nt_set_espeak_data_path`] — point the phonemizer at an app-writable
//!    directory (Android's `std::env::temp_dir()` is not writable).
//! 2. [`nt_engine_new`] — load the GGUF backbone + NeuCodec decoder from
//!    paths on disk.
//! 3. [`nt_engine_set_reference_file`] / [`nt_engine_set_reference_bytes`] —
//!    set the reference voice (encoded NeuCodec tokens as `.npy` plus the
//!    reference transcript text).
//! 4. [`nt_synth`] — synthesize text to 24 kHz mono PCM (`f32`, caller frees
//!    with [`nt_free_audio`]).
//!
//! All functions return errors via [`nt_last_error`] (copy the string before
//! the next call; the pointer is owned by the library).  The engine is
//! single-threaded: create it on, and use it from, one thread (the TTS
//! worker isolate thread).
//!
//! Build (host probe):   `cargo build --release`
//! Build (Android):      `cargo ndk -t arm64-v8a -o android/app/src/main/jniLibs build --release`

use std::ffi::{CStr, CString, c_char, c_int};
use std::path::Path;
use std::ptr;
use std::sync::Mutex;

use neutts::NeuTTS;

/// Output sample rate of [`nt_synth`] (Hz).
pub const NT_SAMPLE_RATE: i32 = neutts::SAMPLE_RATE as i32;

/// Opaque engine handle (returned as `*mut c_void` across C).
pub struct Engine {
    tts: NeuTTS,
    ref_codes: Vec<i32>,
    ref_text: String,
}

/// Last error message, kept as a `CString` so [`nt_last_error`] can hand out
/// a stable pointer until the next error.
static LAST_ERR: Mutex<Option<CString>> = Mutex::new(None);

fn push_err(msg: String) {
    // Replace any embedded NULs so CString::new can't fail pathologically.
    let cleaned: String = msg.chars().filter(|c| *c != '\0').collect();
    let s = CString::new(cleaned).unwrap_or_else(|_| CString::new("error").expect("static"));
    *LAST_ERR.lock().unwrap() = Some(s);
}

fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    // SAFETY: caller passes either null or a valid NUL-terminated C string.
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// Redirect the espeak-ng bundled-data extraction directory.  Must be called
/// before the first [`nt_engine_new`] on platforms where the default temp dir
/// is not writable (Android).  Pass an app-private writable directory.
#[no_mangle]
pub extern "C" fn nt_set_espeak_data_path(path: *const c_char) {
    let Some(p) = cstr(path) else {
        push_err("nt_set_espeak_data_path: null path".to_string());
        return;
    };
    neutts::phonemize::set_data_path(Path::new(p));
}

/// Load the backbone GGUF + NeuCodec decoder safetensors.  `lang` is an
/// espeak-ng language code (e.g. `"en-us"`); null defaults to `"en-us"`.
/// Returns null on failure; see [`nt_last_error`].
#[no_mangle]
pub extern "C" fn nt_engine_new(
    gguf: *const c_char,
    decoder: *const c_char,
    lang: *const c_char,
) -> *mut Engine {
    let (Some(gguf), Some(decoder)) = (cstr(gguf), cstr(decoder)) else {
        push_err("nt_engine_new: null path".to_string());
        return ptr::null_mut();
    };
    let lang = cstr(lang).unwrap_or("en-us").to_string();
    match NeuTTS::load_with_decoder(Path::new(gguf), Path::new(decoder), &lang) {
        Ok(tts) => Box::into_raw(Box::new(Engine {
            tts,
            ref_codes: Vec::new(),
            ref_text: String::new(),
        })),
        Err(e) => {
            // {:#} gives the full anyhow context chain.
            push_err(format!("{e:#}"));
            ptr::null_mut()
        }
    }
}

/// Set the reference voice from a `.npy` codes file plus a UTF-8 transcript
/// text file.  Returns 0 on success, nonzero on failure.
#[no_mangle]
pub extern "C" fn nt_engine_set_reference_file(
    e: *mut Engine,
    npy_path: *const c_char,
    text_path: *const c_char,
) -> c_int {
    let Some(eng) = (unsafe { e.as_mut() }) else {
        push_err("nt_engine_set_reference_file: null engine".to_string());
        return -1;
    };
    let (Some(npy), Some(txt)) = (cstr(npy_path), cstr(text_path)) else {
        push_err("nt_engine_set_reference_file: null path".to_string());
        return -2;
    };
    match eng.tts.load_ref_codes(Path::new(npy)) {
        Ok(codes) => match std::fs::read_to_string(txt) {
            Ok(text) => {
                eng.ref_codes = codes;
                eng.ref_text = text.trim().to_string();
                0
            }
            Err(err) => {
                push_err(format!("reading reference text {txt}: {err}"));
                -3
            }
        },
        Err(err) => {
            push_err(format!("loading reference codes {npy}: {err:#}"));
            -4
        }
    }
}

/// Set the reference voice from in-memory `.npy` bytes plus transcript text
/// (for references that live outside the filesystem, e.g. a freshly recorded
/// clone sample staged in memory).  Returns 0 on success.
#[no_mangle]
pub extern "C" fn nt_engine_set_reference_bytes(
    e: *mut Engine,
    npy: *const u8,
    npy_len: usize,
    ref_text: *const c_char,
) -> c_int {
    let Some(eng) = (unsafe { e.as_mut() }) else {
        push_err("nt_engine_set_reference_bytes: null engine".to_string());
        return -1;
    };
    if npy.is_null() || npy_len == 0 {
        push_err("nt_engine_set_reference_bytes: empty codes".to_string());
        return -2;
    }
    // SAFETY: caller passes a valid pointer to npy_len readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(npy, npy_len) };
    let Some(text) = cstr(ref_text) else {
        push_err("nt_engine_set_reference_bytes: null text".to_string());
        return -3;
    };
    match eng.tts.load_ref_codes_from_bytes(bytes) {
        Ok(codes) => {
            eng.ref_codes = codes;
            eng.ref_text = text.trim().to_string();
            0
        }
        Err(err) => {
            push_err(format!("decoding reference codes: {err:#}"));
            -4
        }
    }
}

/// Synthesize `text` with the current reference voice.  On success returns a
/// buffer of `*out_len` mono f32 samples at [`nt_sample_rate`] Hz (free with
/// [`nt_free_audio`]).  On failure returns null; see [`nt_last_error`].
#[no_mangle]
pub extern "C" fn nt_synth(e: *mut Engine, text: *const c_char, out_len: *mut usize) -> *mut f32 {
    let Some(eng) = (unsafe { e.as_mut() }) else {
        push_err("nt_synth: null engine".to_string());
        return ptr::null_mut();
    };
    let Some(t) = cstr(text) else {
        push_err("nt_synth: null text".to_string());
        return ptr::null_mut();
    };
    if eng.ref_codes.is_empty() {
        push_err("nt_synth: reference voice not set".to_string());
        return ptr::null_mut();
    }
    match eng.tts.infer(t, &eng.ref_codes, &eng.ref_text) {
        Ok(pcm) => {
            if !out_len.is_null() {
                // SAFETY: caller passes null or a valid usize out-pointer.
                unsafe { *out_len = pcm.len() };
            }
            let mut boxed = pcm.into_boxed_slice();
            let p = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            p as *mut f32
        }
        Err(err) => {
            push_err(format!("{err:#}"));
            ptr::null_mut()
        }
    }
}

/// Free a buffer returned by [`nt_synth`].
#[no_mangle]
pub extern "C" fn nt_free_audio(ptr: *mut f32, len: usize) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: exactly one call per nt_synth result, with the reported length.
    unsafe { drop(Box::from_raw(std::slice::from_raw_parts_mut(ptr, len))) };
}

/// Free an engine created by [`nt_engine_new`].  Null-safe.
#[no_mangle]
pub extern "C" fn nt_engine_free(e: *mut Engine) {
    if !e.is_null() {
        // SAFETY: exactly one call per nt_engine_new result.
        unsafe { drop(Box::from_raw(e)) };
    }
}

/// Output sample rate of [`nt_synth`] (Hz).
#[no_mangle]
pub extern "C" fn nt_sample_rate() -> c_int {
    NT_SAMPLE_RATE
}

/// Full context chain of the most recent failed call, or null.  The pointer
/// is valid until the next failing call; copy the string immediately.
#[no_mangle]
pub extern "C" fn nt_last_error() -> *const c_char {
    match LAST_ERR.lock().unwrap().as_ref() {
        Some(s) => s.as_ptr(),
        None => ptr::null(),
    }
}
