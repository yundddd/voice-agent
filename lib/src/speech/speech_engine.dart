/// The model seam: everything the assistant needs from the on-device
/// speech stack (ASR, TTS, VAD front end) as a pure interface.
///
/// [SpeechWorker] implements it behind an isolate + FFI; tests implement
/// it in three lines and drive the whole conversation lifecycle — turn
/// taking, barge-in, streamed replies, bench runs — without a single
/// native library. [TtsSpec] lives here too (plain data either way),
/// which is what lets the interface stay free of the worker import.
library;

import 'dart:typed_data';

/// Which TTS voice the worker should speak with — plain data so it can be
/// sent to the worker isolate at startup or swapped via
/// [SpeechEngine.useTts].
///
/// Kokoro-82M v1.0 (the k2-fsa kokoro-multi-lang-v1_0 pack, fp32 — our A/B
/// measured the int8 build audible-muted AND ~4x slower on CPU (RTF 0.37 vs
/// 0.10): ORT's int8 kernels lose to plain fp32 at this model size). The app
/// ships this one engine only — the Piper/VITS, Pocket, ZipVoice and NeuTTS
/// engines were removed when Kokoro proved the best-sounding by a wide
/// margin. No cold-start ritual, no codec bottleneck: one forward pass,
/// clean heads, so it rides the generic OfflineTts synth arm. [sid] indexes
/// the 54-voice roster (reported by the model itself, so the voice screen's
/// style slider picks it up). [kokoroLexicon] is a comma-joined list of
/// absolute lexicon paths; zh would additionally need the jieba dict, which
/// the Dart binding does not plumb (dictDir is dropped), so we wire English
/// only. espeak-ng under [kokoroDataDir] backs out-of-lexicon words.
class TtsSpec {
  final String engine; // 'kokoro' | 'titl'
  final String kokoroModel, kokoroVoices, kokoroTokens, kokoroDataDir;
  final String kokoroLexicon;
  // Teacher-in-the-loop: the 8M student graph + Kokoro phoneme vocab;
  // words come from the lexicon files in [lexiconPaths] (the students'
  // espeak-free front-end, lib/lexicon_pronouncer.dart — Kokoro's own
  // us-en/gb-en files). Students are single-voice models, so a speaker
  // style here is *another graph*: [titlModels]/[titlVocabs] are
  // comma-joined parallel lists indexed by sid (same shape as
  // [kokoroLexicon]), each student pack carrying its own model + vocab
  // copy. The Italian pair (and with it the GPL piper_phonemize
  // plugin) retired: the students speak English, fully off the lexicon.
  final String titlModels, titlVocabs;

  /// Comma-joined lexicon-us-en/gb-en paths in priority order; the
  /// first readable file wins per word. No readable file at all is a
  /// TitlException at synth time, not a silent fallback: the plugin
  /// that could fall back is gone.
  final String lexiconPaths;
  final int sid;

  const TtsSpec.kokoro({
    required this.kokoroModel,
    required this.kokoroVoices,
    required this.kokoroTokens,
    required this.kokoroDataDir,
    required this.kokoroLexicon,
    this.sid = 0,
  }) : engine = 'kokoro',
       titlModels = '',
       titlVocabs = '',
       lexiconPaths = '';

  const TtsSpec.titl({
    required this.titlModels,
    required this.titlVocabs,
    required this.lexiconPaths,
    this.sid = 0,
  }) : engine = 'titl',
       kokoroModel = '',
       kokoroVoices = '',
       kokoroTokens = '',
       kokoroDataDir = '',
       kokoroLexicon = '';
}

/// One-way speech pipeline notification.
///
/// [speechStarted]/[speechStopped] track the live speech flag — they fire
/// only when Silero AND the SNR gate agree, so neither a door slam nor the
/// app's own TTS echo can fake them. [segment] carries a finished utterance
/// (endpointed after the configured silence of *joint* silence) that also
/// passed the duty-cycle check — clean enough to transcribe. [note] carries
/// periodic gate diagnostics (level/floor in dBFS) for logcat.
class SpeechEvent {
  final bool speechStarted;
  final Float32List? segment;
  final String? note;
  const SpeechEvent.started()
    : speechStarted = true,
      segment = null,
      note = null;
  const SpeechEvent.stopped()
    : speechStarted = false,
      segment = null,
      note = null;
  const SpeechEvent.ofSegment(this.segment)
    : speechStarted = false,
      note = null;
  const SpeechEvent.diagnostic(this.note)
    : speechStarted = false,
      segment = null;
}

abstract interface class SpeechEngine {
  /// Feed one microphone chunk (any length) to the VAD. Fire-and-forget.
  void sendAudio(Float32List samples);

  /// Drop any in-progress utterance (e.g. when the session is toggled).
  void resetVad();

  /// Tell the engine our TTS started/stopped playing: while it plays the
  /// gate goes into hard mode (self-interruption protection).
  void setPlaying(bool on);

  /// Swap the speaking voice (the Kokoro style roster index rides in the
  /// spec). Blocks until the new engine is loaded; returns the new
  /// engine's speaker count.
  Future<int> useTts(TtsSpec spec);

  /// Speaker count of the currently loaded engine (0 = none): >1 means
  /// the voice has a style roster the UI should offer.
  int get ttsNumSpeakers;

  Future<String> transcribe(Float32List samples, int sampleRate);

  /// Render [text] with the loaded engine. [sid] overrides the engine's
  /// configured speaker for this one call (the style picker's audition
  /// button) — the Kokoro graph takes the speaker per forward pass, so
  /// trying a style costs no engine rebuild.
  Future<(Float32List samples, int sampleRate)> synthesize(
    String text, {
    int? sid,
  });

  /// Synthesise [text] in sentence chunks, invoking [onChunk] per chunk
  /// AS IT IS RENDERED — a later sentence is still synthesising while an
  /// earlier one already plays. The returned future resolves with the
  /// concatenation once the whole reply is done.
  Future<(Float32List samples, int sampleRate)> synthesizeStream(
    String text, {
    void Function(Float32List chunk, int sampleRate)? onChunk,
    int? sid,
  });

  /// Offline cleanup for a finished push-to-talk clip (high-pass + frame
  /// noise gate). The returned audio is what should go to [transcribe].
  Future<Float32List> denoise(Float32List pcm);

  void dispose();
}
