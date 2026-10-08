/**
 * neutts.h — C interface to the NeuTTS Rust library.
 *
 * This header exposes the NeuCodec ONNX decoder for iOS / Android.
 * On mobile the GGUF backbone typically runs server-side; only the local
 * codec is needed.
 *
 * ## Typical mobile flow
 *
 * 1. neutts_set_espeak_data_path(bundled_data_dir);  // if espeak is bundled
 * 2. NeuTtsHandle *model = neutts_model_load("/path/to/decoder.onnx");
 * 3. size_t n_samples;
 *    float *audio = neutts_decode_tokens(model, codes, n_codes, &n_samples);
 * 4. neutts_write_wav(audio, n_samples, "/path/to/output.wav");
 * 5. neutts_free_audio(audio, n_samples);
 * 6. neutts_model_free(model);
 */

#ifndef NEUTTS_H
#define NEUTTS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque handle returned by neutts_model_load(). */
typedef struct NeuTtsHandle NeuTtsHandle;

/**
 * Set the path to the espeak-ng-data/ directory.
 *
 * Call once at app startup, before any synthesis, on iOS / Android.
 * On desktop pass NULL to use the system-default data directory.
 *
 * Has no effect if the library was built without the `espeak` feature.
 */
void neutts_set_espeak_data_path(const char *path);

/**
 * Load a NeuCodec ONNX decoder from disk.
 *
 * @param onnx_path  UTF-8 path to the NeuCodec ONNX model file.
 * @return           Opaque model handle, or NULL on failure (details to stderr).
 *                   Free with neutts_model_free().
 */
NeuTtsHandle *neutts_model_load(const char *onnx_path);

/**
 * Decode speech token IDs to a float32 PCM audio buffer at 24 kHz.
 *
 * @param model        Handle from neutts_model_load().
 * @param codes        Array of int32 NeuCodec speech token IDs (values 0–1023).
 * @param num_codes    Number of token IDs.
 * @param out_len      Written with the number of float32 samples in the result.
 * @return             Heap-allocated float32 buffer, or NULL on error.
 *                     Free with neutts_free_audio().
 */
float *neutts_decode_tokens(
    const NeuTtsHandle *model,
    const int32_t *codes,
    size_t num_codes,
    size_t *out_len
);

/**
 * Write float32 audio samples to a 16-bit PCM WAV file at 24 kHz.
 *
 * @param samples      Pointer to float32 audio samples (range −1.0 … 1.0).
 * @param num_samples  Number of samples.
 * @param output_path  UTF-8 writable path for the output .wav file.
 * @return             NULL on success; heap-allocated UTF-8 error string on failure.
 *                     Free with neutts_free_error().
 */
const char *neutts_write_wav(
    const float *samples,
    size_t num_samples,
    const char *output_path
);

/**
 * Free a float32 audio buffer returned by neutts_decode_tokens().
 *
 * @param ptr          Pointer returned by neutts_decode_tokens().
 * @param num_samples  The out_len value returned when the buffer was created.
 */
void neutts_free_audio(float *ptr, size_t num_samples);

/**
 * Free an error string returned by a neutts function.
 */
void neutts_free_error(const char *s);

/**
 * Destroy a model handle and release all resources.
 */
void neutts_model_free(NeuTtsHandle *model);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* NEUTTS_H */
