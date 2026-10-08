//! # neutts
//!
//! Rust port of [NeuTTS](https://github.com/neuphonic/neutts) —
//! an on-device voice-cloning TTS system built on a GGUF LLM backbone and
//! the NeuCodec neural audio codec (pure-Rust CPU inference, no ONNX Runtime).
//!
//! ## Architecture
//!
//! ```text
//!  text  ──► espeak-ng ──► IPA ──► GGUF backbone ──► speech tokens ──► NeuCodec decoder ──► audio
//!                               +  ref codes ──►
//! ```
//!
//! 1. **GGUF backbone** (`llama-cpp-4`) — a small causal LM that generates speech token IDs.
//! 2. **NeuCodec decoder** — pure-Rust FSQ+Vocos+ISTFT decoder; 24 kHz output.
//!
//! ## One-time setup
//!
//! ```sh
//! pip install torch huggingface_hub safetensors
//! python scripts/convert_weights.py     # download + extract decoder weights
//! cargo build                           # codec weights loaded at runtime
//! ```
//!
//! ## Quick start
//!
//! ```ignore
//! use neutts::{NeuTTS, download};
//! use std::path::Path;
//!
//! let tts = download::load_from_hub("neuphonic/neutts-nano-q4-gguf").unwrap();
//! let ref_codes = tts.load_ref_codes(Path::new("samples/jo.npy")).unwrap();
//! let audio = tts.infer("Hello from Rust!", &ref_codes, "Reference transcript.").unwrap();
//! tts.write_wav(&audio, Path::new("output.wav")).unwrap();
//! ```
//!
//! ## Features
//!
//! | Feature    | Default | Effect                                                                       |
//! |------------|---------|------------------------------------------------------------------------------|
//! | `backbone` | ✓       | GGUF backbone via llama-cpp-4 (requires cmake + C++)                         |
//! | `espeak`   |         | Raw-text input via pure-Rust espeak-ng (114 bundled languages, no system deps) |
//! | `wgpu`     |         | GPU-accelerated codec via Burn wgpu; falls back to Burn NdArray then ndarray |
//! | `metal`    |         | macOS Metal GPU for the backbone (passed to llama-cpp-4)                     |
//! | `cuda`     |         | NVIDIA CUDA for the backbone (passed to llama-cpp-4)                         |
//! | `fast`     | ✓       | RoPE: degree-7/6 Horner polynomial, no transcendental calls (~1e-4 error)    |
//! | `precise`  |         | RoPE: stdlib `f32::sin_cos()`, correctly rounded; mutually exclusive w/ fast |

// HuggingFace Hub download — desktop only (hf-hub needs OpenSSL).
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub mod download;

pub mod cache;
pub mod ffi;

#[cfg(feature = "backbone")]
pub mod backbone;

pub mod codec;
pub mod model;
pub mod npy;
pub mod phonemize;
pub mod preprocess;
pub mod tokens;

/// Burn wgpu/NdArray backend for the NeuCodec decoder.
/// Only compiled when the `wgpu` Cargo feature is enabled.
#[cfg(feature = "wgpu")]
pub(crate) mod codec_burn;

// ─── Re-exports ───────────────────────────────────────────────────────────────

/// The main TTS handle.
pub use model::NeuTTS;

/// Disk cache for pre-encoded reference codes, keyed by SHA-256 of the WAV.
pub use cache::RefCodeCache;

/// Result of a [`RefCodeCache`] lookup.
pub use cache::CacheOutcome;

/// NeuCodec encoder stub (encoder not yet implemented in pure-Rust build).
pub use codec::NeuCodecEncoder;

/// NeuCodec decoder — converts speech token IDs to 24 kHz audio.
pub use codec::NeuCodecDecoder;

/// Decoder output sample rate (24 000 Hz).
pub use codec::SAMPLE_RATE;

/// Encoder input sample rate (16 000 Hz).
pub use codec::ENCODER_SAMPLE_RATE;

/// Decoder: audio samples per token (hop_length, nominally 480 = 24 000 / 50).
pub use codec::SAMPLES_PER_TOKEN;

/// Encoder: audio samples consumed per token (320 = 16 000 / 50).
pub use codec::ENCODER_SAMPLES_PER_TOKEN;
