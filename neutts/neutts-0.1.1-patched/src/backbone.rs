//! GGUF backbone — runs the NeuTTS LLM that generates speech token IDs.
//!
//! Wraps [`llama_cpp_4`] v0.2.17 (Rust bindings to llama.cpp) to load a GGUF
//! model and run token generation with temperature + top-k + top-p sampling.
//!
//! ## Pipeline
//!
//! 1. Prompt (text + reference codes) is tokenised by the GGUF model's
//!    built-in tokeniser (which includes the special `<|speech_N|>` tokens).
//! 2. Prompt tokens are fed into the KV cache via `ctx.decode()`.
//! 3. New tokens are sampled (top-k=50, top-p=0.9, temperature=1.0) until
//!    the model emits `<|SPEECH_GENERATION_END|>` or the context limit is
//!    reached.
//! 4. The generated text is returned; the caller extracts speech token IDs
//!    with [`crate::tokens::extract_ids`].

use std::num::NonZeroU32;
use std::path::Path;

use anyhow::{Context, Result};
use llama_cpp_4::{
    context::params::LlamaContextParams,
    llama_backend::LlamaBackend,
    llama_batch::LlamaBatch,
    model::{params::LlamaModelParams, AddBos, LlamaModel, Special},
    sampling::{LlamaSampler, LlamaSamplerParams},
};

use crate::tokens::STOP_TOKEN;

/// Default context window (must match Python's `max_context = 2048`).
pub const DEFAULT_N_CTX: u32 = 2048;

/// VENDORED PATCH: minimum audio tokens (~50 Hz codec rate => 64 is
/// ~1.3 s) that must be generated before an EOS/EOT token may end
/// generation. At temperature=1.0 the sampler emits premature stop
/// tokens that truncate sentences mid-word; the port's probes showed
/// 1-second outputs from 3-second lines.
pub const MIN_EOG_TOKENS: u32 = 64;

/// VENDORED PATCH: abort generation once this many IDENTICAL audio tokens
/// arrive back to back.  A grinding repetition loop (measured: 60+ repeats
/// of one codec frame) is always an artefact — real phonemes change codes
/// every ~2-3 frames — and the duration-aware EOS floor would otherwise
/// ride the loop out burning the whole token budget.
pub const REPETITION_RUN: u32 = 16;

/// NeuTTS GGUF backbone model.
///
/// Holds the loaded [`LlamaModel`] and configuration.  A new [`LlamaContext`]
/// is created for each [`generate`](BackboneModel::generate) call so there is
/// no cross-inference state leakage.
pub struct BackboneModel {
    /// llama.cpp backend handle — must outlive the model.
    _backend: LlamaBackend,
    /// Loaded GGUF model.
    model: LlamaModel,
    /// Context window size (tokens).
    n_ctx: u32,
    /// Random seed for the sampler.  `None` → a fresh random seed per call.
    pub seed: Option<u32>,
    /// VENDORED PATCH: per-call floor of audio tokens that must be produced
    /// before an EOS token may end generation.  Set via [`Self::set_min_eog`]
    /// from the spoken-text length; defaults to [`MIN_EOG_TOKENS`].
    min_eog: std::sync::atomic::AtomicU32,
}

impl BackboneModel {
    /// Load a GGUF model from `path`.
    ///
    /// `n_ctx` — context window size.  Pass [`DEFAULT_N_CTX`] for the default.
    ///
    /// The backbone uses all available CPU threads by default.  Enable the
    /// `metal` or `cuda` Cargo features for GPU acceleration.
    pub fn load(path: &Path, n_ctx: u32) -> Result<Self> {
        let mut backend = LlamaBackend::init()
            .context("Failed to initialise llama.cpp backend")?;

        // Silence llama.cpp / ggml stderr spam unless the `verbose` feature is on.
        #[cfg(not(feature = "verbose"))]
        backend.void_logs();
        let model_params = LlamaModelParams::default();
        let model = LlamaModel::load_from_file(&backend, path, &model_params)
            .with_context(|| format!("Cannot load GGUF model: {}", path.display()))?;
        Ok(Self { _backend: backend, model, n_ctx, seed: None, min_eog: std::sync::atomic::AtomicU32::new(MIN_EOG_TOKENS) })
    }

    /// Run the backbone on `prompt` and return the generated token string.
    ///
    /// Stops when the model produces `<|SPEECH_GENERATION_END|>` or when
    /// `max_new_tokens` tokens have been generated (whichever comes first).
    /// The stop token itself is **not** included in the returned string.
    ///
    /// Use [`crate::tokens::extract_ids`] on the returned string to get the
    /// integer speech token IDs.
    ///
    /// For low-latency applications, prefer [`generate_streaming`](Self::generate_streaming),
    /// which delivers each text piece to a callback as soon as it is produced.
    /// VENDORED PATCH: set the early-EOS floor for subsequent generate
    /// calls.  `model.rs` derives it from the spoken-text length so a long
    /// reply cannot stop after a fraction of its expected duration.  Always
    /// at least [`MIN_EOG_TOKENS`].
    pub fn set_min_eog(&self, tokens: u32) {
        self.min_eog
            .store(tokens.max(MIN_EOG_TOKENS), std::sync::atomic::Ordering::Relaxed);
    }

    pub fn generate(&self, prompt: &str, max_new_tokens: u32) -> Result<String> {
        // ── Create a fresh context for this inference ─────────────────────────
        let ctx_params = LlamaContextParams::default()
            .with_n_ctx(NonZeroU32::new(self.n_ctx));
        let mut ctx = self.model
            .new_context(&self._backend, ctx_params)
            .context("Failed to create llama.cpp context")?;

        // ── Tokenise prompt ───────────────────────────────────────────────────
        let tokens = self.model
            .str_to_token(prompt, AddBos::Always)
            .context("Tokenisation failed")?;

        eprintln!("[backbone] prompt token count: {} / n_ctx={}", tokens.len(), self.n_ctx);
        if tokens.len() as u32 > self.n_ctx {
            anyhow::bail!(
                "Prompt too long: {} tokens exceeds n_ctx={}. \
                 Reduce reference code count.",
                tokens.len(), self.n_ctx
            );
        }

        if tokens.is_empty() {
            return Ok(String::new());
        }

        // ── Fill the KV cache with the prompt ─────────────────────────────────
        let mut batch = LlamaBatch::new(tokens.len().max(1), 1);
        let last_idx = tokens.len() - 1;
        for (i, &tok) in tokens.iter().enumerate() {
            batch
                .add(tok, i as i32, &[0], i == last_idx)
                .context("Failed to add token to batch")?;
        }
        ctx.decode(&mut batch).context("Prompt decode failed")?;

        // ── Sampler: top-k(50) → top-p(0.9) → temperature(1.0) → dist ────────
        // llama-cpp-4: top_p wired after top_k.
        // LlamaSamplerParams carries the seed; top_k/top_p defaults are 50/0.9.
        let seed = self.seed
            .unwrap_or_else(|| LlamaSamplerParams::default().with_seed(rand::random()).seed());
        let mut sampler = LlamaSampler::chain_simple([
            LlamaSampler::top_k(50),
            LlamaSampler::top_p(0.9, 1),
            LlamaSampler::temp(1.0),   // calibrated; 0.7 repetition-loops (measured)   // NeuTTS uses temp=1.0 (higher diversity)
            LlamaSampler::dist(seed),
        ]);

        // ── Generation loop ───────────────────────────────────────────────────
        let mut n_cur = tokens.len() as i32;
        let max_tokens = n_cur + max_new_tokens as i32;
        let mut output = String::new();
        let mut sampled: u32 = 0;
        // VENDORED PATCH: run-length guard (see REPETITION_RUN).
        let mut last_tok: Option<llama_cpp_4::token::LlamaToken> = None;
        let mut rep_run  = 0u32;

        loop {
            // Sample the next token.
            let mut token = sampler.sample(&ctx, batch.n_tokens() - 1);

            // VENDORED PATCH: duration-aware early-EOS suppression.  While
            // below the per-call floor (set_min_eog, derived from the text
            // length), a sampled EOS is REJECTED and the roll redrawn —
            // accepting a rejected draw only advances the sampler's RNG,
            // never the sequence.  Eight straight EOS draws mean the model
            // genuinely wants to stop, so the token finally wins.  (Was:
            // accept-and-break once past a fixed MIN_EOG_TOKENS, which let
            // mid-sentence stops truncate the reply's tail.)
            let floor = self.min_eog.load(std::sync::atomic::Ordering::Relaxed).max(1);
            if self.model.is_eog_token(token) && sampled + 1 < floor {
                let mut tries = 0u32;
                while self.model.is_eog_token(token) && tries < 8 {
                    sampler.accept(token); // reject: advance RNG only
                    token = sampler.sample(&ctx, batch.n_tokens() - 1);
                    tries += 1;
                }
            }
            sampler.accept(token);
            sampled += 1;
            if self.model.is_eog_token(token) {
                break;
            }

            // VENDORED PATCH: repetition-loop guard.  The duration-aware
            // floor keeps generation alive past a premature EOS; when the
            // model instead falls into a grinding loop, it repeats one
            // audio token indefinitely (measured: 60+ identical frames).
            // No natural phoneme holds an identical codec frame for
            // REPETITION_RUN tokens (0.3 s), so cut the run and let the
            // sentence-chunking restart the next phrase cleanly.
            if Some(token) == last_tok {
                rep_run += 1;
                if rep_run >= REPETITION_RUN {
                    break;
                }
            } else {
                last_tok = Some(token);
                rep_run = 1;
            }

            // Decode token bytes → UTF-8 string.
            // token_to_piece_bytes(token, buf_size, special=true, lstrip=None)
            let piece = token_to_piece(&self.model, token)?;
            output.push_str(&piece);

            // Stop at the explicit NeuTTS stop token.
            if let Some(pos) = output.find(STOP_TOKEN) {
                output.truncate(pos);
                break;
            }

            // Context limit reached?
            if n_cur >= max_tokens {
                break;
            }

            // Feed the new token back for the next step.
            batch.clear();
            batch
                .add(token, n_cur, &[0], true)
                .context("Failed to add generated token to batch")?;
            ctx.decode(&mut batch).context("Decode step failed")?;
            n_cur += 1;
        }

        Ok(output)
    }

    /// Run the backbone on `prompt`, calling `on_piece` with each decoded text
    /// fragment as soon as it is produced.
    ///
    /// This is the streaming counterpart of [`generate`](Self::generate).
    /// Instead of buffering the entire output and returning it at the end,
    /// every decoded token piece is forwarded to the closure immediately,
    /// enabling a caller to start decoding speech tokens and producing audio
    /// before the backbone has finished generating.
    ///
    /// # Callback contract
    ///
    /// * `on_piece` receives each raw text piece from the model.
    ///   Speech tokens arrive as complete strings like `"<|speech_42|>"`;
    ///   pass them through [`crate::tokens::extract_ids`] to get the IDs.
    /// * Return `Ok(())` to continue, or any `Err` to abort generation early
    ///   (the error is propagated back to the caller).
    /// * The stop token `<|SPEECH_GENERATION_END|>` is **never** forwarded;
    ///   the callback will not see it.
    ///
    /// # Example
    ///
    /// ```ignore
    /// let mut ids = Vec::new();
    /// backbone.generate_streaming(&prompt, 2048, |piece| {
    ///     ids.extend(neutts::tokens::extract_ids(piece));
    ///     Ok(())
    /// })?;
    /// ```
    pub fn generate_streaming<F>(
        &self,
        prompt:         &str,
        max_new_tokens: u32,
        mut on_piece:   F,
    ) -> Result<()>
    where
        F: FnMut(&str) -> Result<()>,
    {
        // ── Create a fresh context for this inference ─────────────────────────
        let ctx_params = LlamaContextParams::default()
            .with_n_ctx(NonZeroU32::new(self.n_ctx));
        let mut ctx = self.model
            .new_context(&self._backend, ctx_params)
            .context("Failed to create llama.cpp context")?;

        // ── Tokenise prompt ───────────────────────────────────────────────────
        let tokens = self.model
            .str_to_token(prompt, AddBos::Always)
            .context("Tokenisation failed")?;

        eprintln!("[backbone] prompt token count: {} / n_ctx={}", tokens.len(), self.n_ctx);
        if tokens.len() as u32 > self.n_ctx {
            anyhow::bail!(
                "Prompt too long: {} tokens exceeds n_ctx={}. \
                 Reduce reference code count.",
                tokens.len(), self.n_ctx
            );
        }

        if tokens.is_empty() {
            return Ok(());
        }

        // ── Fill the KV cache with the prompt ─────────────────────────────────
        let mut batch = LlamaBatch::new(tokens.len().max(1), 1);
        let last_idx = tokens.len() - 1;
        for (i, &tok) in tokens.iter().enumerate() {
            batch
                .add(tok, i as i32, &[0], i == last_idx)
                .context("Failed to add token to batch")?;
        }
        ctx.decode(&mut batch).context("Prompt decode failed")?;

        // ── Sampler: top-k(50) → top-p(0.9) → temperature(1.0) → dist ────────
        let seed = self.seed
            .unwrap_or_else(|| LlamaSamplerParams::default().with_seed(rand::random()).seed());
        let mut sampler = LlamaSampler::chain_simple([
            LlamaSampler::top_k(50),
            LlamaSampler::top_p(0.9, 1),
            LlamaSampler::temp(1.0),   // calibrated; 0.7 repetition-loops (measured)
            LlamaSampler::dist(seed),
        ]);

        // ── Generation loop ───────────────────────────────────────────────────
        let mut n_cur    = tokens.len() as i32;
        let     max_cur  = n_cur + max_new_tokens as i32;
        let mut sampled: u32 = 0;
        // VENDORED PATCH: run-length guard (see REPETITION_RUN).
        let mut last_tok: Option<llama_cpp_4::token::LlamaToken> = None;
        let mut rep_run  = 0u32;

        loop {
            let mut token = sampler.sample(&ctx, batch.n_tokens() - 1);

            // VENDORED PATCH: duration-aware early-EOS suppression.  While
            // below the per-call floor (set_min_eog, derived from the text
            // length), a sampled EOS is REJECTED and the roll redrawn —
            // accepting a rejected draw only advances the sampler's RNG,
            // never the sequence.  Eight straight EOS draws mean the model
            // genuinely wants to stop, so the token finally wins.  (Was:
            // accept-and-break once past a fixed MIN_EOG_TOKENS, which let
            // mid-sentence stops truncate the reply's tail.)
            let floor = self.min_eog.load(std::sync::atomic::Ordering::Relaxed).max(1);
            if self.model.is_eog_token(token) && sampled + 1 < floor {
                let mut tries = 0u32;
                while self.model.is_eog_token(token) && tries < 8 {
                    sampler.accept(token); // reject: advance RNG only
                    token = sampler.sample(&ctx, batch.n_tokens() - 1);
                    tries += 1;
                }
            }
            sampler.accept(token);
            sampled += 1;
            if self.model.is_eog_token(token) {
                break;
            }

            // VENDORED PATCH: repetition-loop guard.  The duration-aware
            // floor keeps generation alive past a premature EOS; when the
            // model instead falls into a grinding loop, it repeats one
            // audio token indefinitely (measured: 60+ identical frames).
            // No natural phoneme holds an identical codec frame for
            // REPETITION_RUN tokens (0.3 s), so cut the run and let the
            // sentence-chunking restart the next phrase cleanly.
            if Some(token) == last_tok {
                rep_run += 1;
                if rep_run >= REPETITION_RUN {
                    break;
                }
            } else {
                last_tok = Some(token);
                rep_run = 1;
            }

            let piece = token_to_piece(&self.model, token)?;

            // Stop token: special token arriving as a complete piece.
            // Emit any content that precedes it, then halt.
            if let Some(pos) = piece.find(STOP_TOKEN) {
                let before = &piece[..pos];
                if !before.is_empty() {
                    on_piece(before)?;
                }
                break;
            }

            // Deliver this piece to the caller immediately.
            on_piece(&piece)?;

            if n_cur >= max_cur {
                break;
            }

            batch.clear();
            batch
                .add(token, n_cur, &[0], true)
                .context("Failed to add generated token to batch")?;
            ctx.decode(&mut batch).context("Decode step failed")?;
            n_cur += 1;
        }

        Ok(())
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Decode a single llama token to a UTF-8 string.
///
/// Uses `token_to_str_with_size` with an initial 64-byte buffer — large
/// enough for every NeuTTS speech token (`<|speech_65535|>` is 20 bytes).
/// If the buffer ever proves too small the error carries the required size
/// and we retry once.  `Special::Tokenize` ensures that special tokens such
/// as `<|speech_N|>` are rendered as their text representation.
fn token_to_piece(model: &LlamaModel, token: llama_cpp_4::token::LlamaToken) -> Result<String> {
    use llama_cpp_4::TokenToStringError;

    match model.token_to_str_with_size(token, 64, Special::Tokenize) {
        Ok(s) => Ok(s),
        Err(TokenToStringError::InsufficientBufferSpace(needed)) => {
            let size = needed.unsigned_abs() as usize + 1;
            model
                .token_to_str_with_size(token, size, Special::Tokenize)
                .map_err(|e| anyhow::anyhow!("token decode retry failed: {e}"))
        }
        Err(e) => Err(anyhow::anyhow!("token decode error: {e}")),
    }
}
