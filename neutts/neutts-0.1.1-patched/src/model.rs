//! NeuTTS model — ties the GGUF backbone and NeuCodec Burn decoder together.
//!
//! ## Pipeline
//!
//! ```text
//!            ┌──────────────┐
//!  text ─────►  phonemize   │  (espeak feature)
//!            └──────┬───────┘
//!                   │ IPA
//!            ┌──────▼───────────────────────────────────┐
//!  ref_codes ►   build_prompt()  →  GGUF backbone       │  (backbone feature)
//!            └──────────────────────┬───────────────────┘
//!                                   │ generated text
//!            ┌──────────────────────▼────────────────┐
//!            │  tokens::extract_ids()                │
//!            └──────────────────────┬────────────────┘
//!                                   │ speech token IDs
//!            ┌──────────────────────▼────────────────┐
//!            │  NeuCodec Burn decoder                │
//!            └──────────────────────┬────────────────┘
//!                                   │ audio (Vec<f32>, 24 kHz)
//! ```

use std::path::Path;

use anyhow::{Context, Result};

use crate::codec::{NeuCodecDecoder, NeuCodecEncoder, SAMPLE_RATE};
use crate::npy;

#[cfg(feature = "backbone")]
use crate::tokens;

#[cfg(all(feature = "backbone", feature = "espeak"))]
use crate::phonemize;

#[cfg(feature = "backbone")]
use crate::backbone::{BackboneModel, DEFAULT_N_CTX};

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Generation hyper-parameters passed to the backbone.
#[derive(Debug, Clone)]
pub struct GenerationConfig {
    /// Maximum number of *new* tokens the backbone may generate.
    /// Maps to Python `max_context = 2048`.
    pub max_new_tokens: u32,
}

impl Default for GenerationConfig {
    fn default() -> Self {
        Self { max_new_tokens: 2048 }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NeuTTS
// ─────────────────────────────────────────────────────────────────────────────

/// The main NeuTTS handle.
///
/// Obtained via [`crate::download::load_from_hub`] (desktop) or constructed
/// directly with [`NeuTTS::load`] (mobile / offline).
pub struct NeuTTS {
    /// GGUF LLM backbone — generates speech tokens from a text prompt.
    #[cfg(feature = "backbone")]
    pub backbone: BackboneModel,

    /// NeuCodec Burn decoder — converts speech token IDs to audio.
    pub codec: NeuCodecDecoder,

    /// espeak-ng language code (e.g. `"en-us"`, `"de"`, `"fr-fr"`, `"es"`).
    pub language: String,

    /// Generation hyper-parameters.
    pub config: GenerationConfig,
}

impl NeuTTS {
    // ── Constructors ──────────────────────────────────────────────────────────

    /// Load NeuTTS from files on disk.
    ///
    /// # Arguments
    ///
    /// * `backbone_path` — Path to a NeuTTS GGUF model file.
    ///   **Requires the `backbone` Cargo feature.**
    /// * `language`      — espeak-ng language code (e.g. `"en-us"`).
    ///   Used only when the `espeak` feature is enabled.
    ///
    /// The Burn codec decoder uses the weights compiled into the binary (from
    /// the build-time ONNX conversion).  No codec path is needed at runtime.
    /// Load from a backbone GGUF and an explicit decoder safetensors path.
    ///
    /// Prefer this over [`load`] when the decoder weights are stored in a
    /// location other than `models/neucodec_decoder.safetensors` — e.g. when
    /// they have been downloaded by hf-hub into the HuggingFace cache.
    #[cfg(feature = "backbone")]
    pub fn load_with_decoder(
        backbone_path: &Path,
        decoder_path:  &Path,
        language:      &str,
    ) -> Result<Self> {
        eprintln!("[neutts] Loading backbone: {}", backbone_path.display());
        let backbone = BackboneModel::load(backbone_path, DEFAULT_N_CTX)
            .context("Failed to load backbone")?;

        eprintln!("[neutts] Loading NeuCodec decoder: {}", decoder_path.display());
        let codec = NeuCodecDecoder::from_file(decoder_path)
            .with_context(|| format!("Failed to load NeuCodec decoder from {}", decoder_path.display()))?;

        Ok(Self {
            backbone,
            codec,
            language: language.to_string(),
            config: GenerationConfig::default(),
        })
    }

    /// Load from a backbone GGUF, resolving the decoder from the default path
    /// (`models/neucodec_decoder.safetensors`).
    ///
    /// For most runtime use, prefer [`load_with_decoder`] with a path returned
    /// by [`crate::download::load_from_hub_cb`], which downloads and caches
    /// both files via hf-hub.
    #[cfg(feature = "backbone")]
    pub fn load(backbone_path: &Path, language: &str) -> Result<Self> {
        let decoder_path = std::path::Path::new("models/neucodec_decoder.safetensors");
        Self::load_with_decoder(backbone_path, decoder_path, language)
    }

    /// Load NeuTTS with only the codec (no backbone).
    ///
    /// Use this when you already have generated speech token IDs and only need
    /// the Burn decoder step (e.g. on mobile where the backbone is called
    /// server-side).
    #[cfg(not(feature = "backbone"))]
    pub fn load_codec_only() -> Result<Self> {
        let codec = NeuCodecDecoder::new()
            .context("Failed to initialise NeuCodec Burn decoder")?;
        Ok(Self {
            codec,
            language: "en-us".to_string(),
            config: GenerationConfig::default(),
        })
    }

    // ── Reference code loading / saving ──────────────────────────────────────

    /// Load pre-encoded NeuCodec reference codes from a `.npy` file.
    pub fn load_ref_codes(&self, path: &Path) -> Result<Vec<i32>> {
        npy::load_npy_i32(path)
            .with_context(|| format!("Failed to load reference codes: {}", path.display()))
    }

    /// Load pre-encoded NeuCodec reference codes from raw `.npy` bytes.
    ///
    /// Useful when the file is embedded in the binary with `include_bytes!`
    /// rather than read from disk at runtime.
    pub fn load_ref_codes_from_bytes(&self, bytes: &[u8]) -> Result<Vec<i32>> {
        npy::parse_npy(bytes)
            .context("Failed to parse embedded NPY reference codes")?
            .into_i32()
            .context("Failed to convert embedded NPY to i32")
    }

    /// Encode a reference WAV file to NeuCodec token IDs.
    ///
    /// `encoder` is obtained from [`crate::download::load_encoder`] or
    /// [`NeuCodecEncoder::new`].
    pub fn encode_reference(&self, wav_path: &Path, encoder: &NeuCodecEncoder) -> Result<Vec<i32>> {
        encoder.encode_wav(wav_path)
            .with_context(|| format!("Failed to encode reference audio: {}", wav_path.display()))
    }

    /// Save pre-encoded NeuCodec reference codes to a `.npy` file.
    pub fn save_ref_codes(&self, codes: &[i32], path: &Path) -> Result<()> {
        npy::write_npy_i32(path, codes)
            .with_context(|| format!("Failed to save reference codes: {}", path.display()))
    }

    // ── Synthesis ─────────────────────────────────────────────────────────────

    /// Generate audio from `text` using `ref_codes` and `ref_text` for voice
    /// cloning.
    ///
    /// **Requires both the `backbone` and `espeak` Cargo features.**
    ///
    /// Returns a flat `Vec<f32>` at [`SAMPLE_RATE`] Hz (24 kHz, mono).
    #[cfg(all(feature = "backbone", feature = "espeak"))]
    pub fn infer(&self, text: &str, ref_codes: &[i32], ref_text: &str) -> Result<Vec<f32>> {
        let ref_phones   = phonemize::phonemize(ref_text, &self.language)
            .context("Phonemisation of ref_text failed")?;
        let input_phones = phonemize::phonemize(text, &self.language)
            .context("Phonemisation of input text failed")?;

        self.infer_from_ipa(&input_phones, ref_codes, &ref_phones)
    }

    /// Generate audio from pre-phonemized IPA strings.
    ///
    /// **Requires the `backbone` Cargo feature.**
    #[cfg(feature = "backbone")]
    pub fn infer_from_ipa(
        &self,
        input_ipa: &str,
        ref_codes: &[i32],
        ref_ipa: &str,
    ) -> Result<Vec<f32>> {
        // Build prompt.
        let prompt = tokens::build_prompt(ref_ipa, input_ipa, ref_codes);

        // Run backbone to generate speech token string.
        let generated = self.backbone
            .generate(&prompt, self.config.max_new_tokens)
            .context("Backbone generation failed")?;

        // Extract speech token IDs.
        let speech_ids = tokens::extract_ids(&generated);
        if speech_ids.is_empty() {
            anyhow::bail!(
                "No speech tokens found in backbone output.\n\
                 Prompt may have exceeded the context window, or the model produced no output.\n\
                 Generated text snippet: {:?}",
                &generated[..generated.len().min(200)]
            );
        }

        // Decode with NeuCodec Burn decoder.
        self.codec.decode(&speech_ids)
            .context("NeuCodec Burn decode failed")
    }

    /// Decode a pre-generated sequence of speech token IDs directly to audio.
    ///
    /// This is the mobile / streaming path: the backbone runs server-side and
    /// the client only calls the codec.
    pub fn decode_tokens(&self, speech_ids: &[i32]) -> Result<Vec<f32>> {
        self.codec.decode(speech_ids).context("NeuCodec Burn decode failed")
    }

    // ── WAV output ────────────────────────────────────────────────────────────

    /// Write `audio` samples to a 16-bit PCM WAV file at [`SAMPLE_RATE`] Hz.
    ///
    /// The samples are **peak-normalised** before conversion: if the loudest
    /// sample exceeds ±1.0 the whole signal is scaled down to just fit in
    /// [-1, 1], preventing hard clipping.  Signals that are already within
    /// [-1, 1] are written as-is (no amplification is applied).
    pub fn write_wav(&self, audio: &[f32], output_path: &Path) -> Result<()> {
        // Peak normalization: scale down only if necessary, never amplify.
        let peak = audio.iter().map(|&s| s.abs()).fold(0.0f32, f32::max);
        let scale = if peak > 1.0 { 1.0 / peak } else { 1.0 };

        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: SAMPLE_RATE,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(output_path, spec)
            .with_context(|| format!("Cannot create WAV: {}", output_path.display()))?;
        for &s in audio {
            let s16 = (s * scale * i16::MAX as f32)
                .clamp(i16::MIN as f32, i16::MAX as f32) as i16;
            writer.write_sample(s16).context("WAV write error")?;
        }
        writer.finalize().context("WAV finalise error")?;
        println!(
            "Saved {} samples ({:.2} s) to {}  [peak={peak:.4}, scale={scale:.4}]",
            audio.len(),
            audio.len() as f32 / SAMPLE_RATE as f32,
            output_path.display()
        );
        Ok(())
    }

    /// Encode `audio` samples into an in-memory WAV buffer (16-bit PCM, 24 kHz,
    /// mono) and return the raw bytes.
    ///
    /// Same peak-normalisation as [`write_wav`] but writes directly into a
    /// `Vec<u8>` without touching the filesystem.  All chunk sizes are known
    /// before writing begins, so the canonical 44-byte header is constructed
    /// in a single forward pass — no seeking required.
    ///
    /// Useful for in-process audio playback via decoders that accept a byte
    /// cursor (e.g. `rodio::Decoder::new(std::io::Cursor::new(bytes))`).
    ///
    /// [`write_wav`]: Self::write_wav
    pub fn to_wav_bytes(&self, audio: &[f32]) -> Vec<u8> {
        // Peak normalisation: scale down only if necessary, never amplify.
        let peak  = audio.iter().map(|&s| s.abs()).fold(0.0f32, f32::max);
        let scale = if peak > 1.0 { 1.0 / peak } else { 1.0 };

        let num_channels:   u16 = 1;
        let bits_per_sample: u16 = 16;
        let sample_rate:    u32 = SAMPLE_RATE;
        let byte_rate:      u32 = sample_rate * num_channels as u32 * bits_per_sample as u32 / 8;
        let block_align:    u16 = num_channels * bits_per_sample / 8;
        let data_size:      u32 = (audio.len() * 2) as u32; // 2 bytes per 16-bit sample

        // 44-byte canonical WAV header + PCM data.
        let mut buf = Vec::with_capacity(44 + audio.len() * 2);

        // ── RIFF chunk ────────────────────────────────────────────────────────
        buf.extend_from_slice(b"RIFF");
        buf.extend_from_slice(&(36 + data_size).to_le_bytes());   // file size − 8
        buf.extend_from_slice(b"WAVE");

        // ── fmt sub-chunk ─────────────────────────────────────────────────────
        buf.extend_from_slice(b"fmt ");
        buf.extend_from_slice(&16u32.to_le_bytes());              // chunk size (PCM = 16)
        buf.extend_from_slice(&1u16.to_le_bytes());               // audio format: PCM
        buf.extend_from_slice(&num_channels.to_le_bytes());
        buf.extend_from_slice(&sample_rate.to_le_bytes());
        buf.extend_from_slice(&byte_rate.to_le_bytes());
        buf.extend_from_slice(&block_align.to_le_bytes());
        buf.extend_from_slice(&bits_per_sample.to_le_bytes());

        // ── data sub-chunk ────────────────────────────────────────────────────
        buf.extend_from_slice(b"data");
        buf.extend_from_slice(&data_size.to_le_bytes());
        for &s in audio {
            let s16 = (s * scale * i16::MAX as f32)
                .clamp(i16::MIN as f32, i16::MAX as f32) as i16;
            buf.extend_from_slice(&s16.to_le_bytes());
        }

        buf
    }

    // ── High-level convenience wrappers ───────────────────────────────────────

    /// Generate audio and save to a WAV file in one call.
    ///
    /// **Requires `backbone` + `espeak` features.**
    #[cfg(all(feature = "backbone", feature = "espeak"))]
    pub fn infer_to_file(
        &self,
        text: &str,
        ref_codes: &[i32],
        ref_text: &str,
        output_path: &Path,
    ) -> Result<()> {
        let audio = self.infer(text, ref_codes, ref_text)?;
        self.write_wav(&audio, output_path)
    }
}
