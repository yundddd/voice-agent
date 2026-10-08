//! C FFI — bridges [`NeuTTS`] to iOS / Android callers.
//!
//! All functions are `#[no_mangle] extern "C"` so Swift / Kotlin / JNI can
//! call them through the [`include/neutts.h`](../include/neutts.h) bridging
//! header without any Objective-C wrapper.
//!
//! ## Memory contract
//!
//! | Function                          | Caller frees with          |
//! |-----------------------------------|----------------------------|
//! | [`neutts_model_load`]             | [`neutts_model_free`]      |
//! | [`neutts_decode_tokens`]          | [`neutts_free_audio`]      |
//! | [`neutts_write_wav`]              | [`neutts_free_error`]      |
//!
//! ## Mobile workflow
//!
//! The NeuCodec decoder uses the [Burn](https://burn.dev) ML framework — no
//! ONNX Runtime needed at runtime.  On mobile the backbone typically runs
//! server-side; only the Burn decoder is bundled with the app:
//!
//! 1. Call [`neutts_set_espeak_data_path`] (if espeak is bundled).
//! 2. Load the model with [`neutts_model_load`], passing the path to a Burn
//!    binary record (`.bin`) file.  If the weights are embedded in the binary
//!    (default when built with `cargo build` after `download_models`), pass
//!    an empty string and [`NeuCodecDecoder::new`] is used instead.
//! 3. For each utterance, receive speech token IDs from the server and call
//!    [`neutts_decode_tokens`] to get audio, then write it to a WAV with
//!    [`neutts_write_wav`].

use std::ffi::{CStr, CString, c_char};
use std::path::Path;

use crate::codec::NeuCodecDecoder;
use crate::phonemize;

// ─────────────────────────────────────────────────────────────────────────────
// Opaque handle
// ─────────────────────────────────────────────────────────────────────────────

/// Opaque handle to a loaded NeuCodec decoder.
pub struct NeuTtsHandle {
    codec: NeuCodecDecoder,
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

unsafe fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() { return None; }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
}

fn to_c_str(s: &str) -> *const c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null(),
    }
}

// ─── Public C API ─────────────────────────────────────────────────────────────

/// Set the espeak-ng data directory path.
///
/// With the pure-Rust `espeak-ng` crate and bundled data, this is **optional**.
/// Only needed if you want to override the bundled data with custom dictionaries.
///
/// ```c
/// neutts_set_espeak_data_path("/var/mobile/…/espeak-ng-data");
/// ```
#[no_mangle]
pub unsafe extern "C" fn neutts_set_espeak_data_path(path: *const c_char) {
    if let Some(s) = unsafe { cstr_to_string(path) } {
        phonemize::set_data_path(Path::new(&s));
    }
}

/// Load a NeuCodec Burn decoder.
///
/// @param weights_path  UTF-8 path to a Burn binary record (`.bin`) file, or
///                      an empty string / NULL to use the weights compiled into
///                      the binary (requires `burn_decoder_available` build flag).
/// @return              Opaque handle, or `NULL` on failure (details to stderr).
///                      Free with [`neutts_model_free`].
#[no_mangle]
pub unsafe extern "C" fn neutts_model_load(weights_path: *const c_char) -> *mut NeuTtsHandle {
    let path_opt = unsafe { cstr_to_string(weights_path) }
        .filter(|s| !s.is_empty());

    let result = match path_opt {
        Some(ref p) => NeuCodecDecoder::load(Path::new(p)),
        None        => NeuCodecDecoder::new(),
    };

    match result {
        Ok(codec) => Box::into_raw(Box::new(NeuTtsHandle { codec })),
        Err(e) => {
            eprintln!("[neutts] load error: {e:#}");
            std::ptr::null_mut()
        }
    }
}

/// Decode a buffer of speech token IDs to audio samples.
///
/// Writes `num_codes` int32 token IDs into the NeuCodec decoder and returns
/// a heap-allocated buffer of float32 PCM samples at 24 kHz.
///
/// @param model       Handle from [`neutts_model_load`].
/// @param codes       Pointer to an array of int32 speech token IDs.
/// @param num_codes   Number of token IDs.
/// @param out_len     Written with the number of returned float32 samples.
/// @return            Heap-allocated float32 buffer, or `NULL` on error.
///                    Free with [`neutts_free_audio`].
#[no_mangle]
pub unsafe extern "C" fn neutts_decode_tokens(
    model: *const NeuTtsHandle,
    codes: *const i32,
    num_codes: usize,
    out_len: *mut usize,
) -> *mut f32 {
    if model.is_null() || codes.is_null() || out_len.is_null() {
        return std::ptr::null_mut();
    }
    let h = unsafe { &*model };
    let codes_slice = unsafe { std::slice::from_raw_parts(codes, num_codes) };
    match h.codec.decode(codes_slice) {
        Ok(audio) => {
            let len = audio.len();
            let mut boxed = audio.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            unsafe { *out_len = len; }
            ptr
        }
        Err(e) => {
            eprintln!("[neutts] decode error: {e:#}");
            std::ptr::null_mut()
        }
    }
}

/// Write float32 audio samples to a 16-bit PCM WAV file at 24 kHz.
///
/// @param samples     Pointer to float32 audio buffer (range −1.0 … 1.0).
/// @param num_samples Number of samples.
/// @param output_path UTF-8 path for the output `.wav` file.
/// @return            `NULL` on success; heap-allocated UTF-8 error string on failure.
///                    Free with [`neutts_free_error`].
#[no_mangle]
pub unsafe extern "C" fn neutts_write_wav(
    samples: *const f32,
    num_samples: usize,
    output_path: *const c_char,
) -> *const c_char {
    if samples.is_null() || output_path.is_null() {
        return to_c_str("null argument");
    }
    let path_str = match unsafe { cstr_to_string(output_path) } {
        Some(s) => s,
        None    => return to_c_str("invalid output_path"),
    };
    let audio = unsafe { std::slice::from_raw_parts(samples, num_samples) };

    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: crate::codec::SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = match hound::WavWriter::create(&path_str, spec) {
        Ok(w)  => w,
        Err(e) => return to_c_str(&format!("Cannot create WAV: {e}")),
    };
    for &s in audio {
        let s16 = (s * i16::MAX as f32).clamp(i16::MIN as f32, i16::MAX as f32) as i16;
        if let Err(e) = writer.write_sample(s16) {
            return to_c_str(&format!("WAV write error: {e}"));
        }
    }
    if let Err(e) = writer.finalize() {
        return to_c_str(&format!("WAV finalise error: {e}"));
    }
    std::ptr::null()
}

/// Free a float32 audio buffer returned by [`neutts_decode_tokens`].
///
/// @param ptr      Pointer previously returned by [`neutts_decode_tokens`].
/// @param num_samples  The same `out_len` value returned when the buffer was created.
#[no_mangle]
pub unsafe extern "C" fn neutts_free_audio(ptr: *mut f32, num_samples: usize) {
    if !ptr.is_null() {
        let slice = unsafe { std::slice::from_raw_parts_mut(ptr, num_samples) };
        drop(unsafe { Box::from_raw(slice as *mut [f32]) });
    }
}

/// Free an error string returned by a neutts function.
#[no_mangle]
pub unsafe extern "C" fn neutts_free_error(s: *const c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s as *mut c_char) });
    }
}

/// Destroy a model handle and release all resources.
#[no_mangle]
pub unsafe extern "C" fn neutts_model_free(model: *mut NeuTtsHandle) {
    if !model.is_null() {
        drop(unsafe { Box::from_raw(model) });
    }
}
