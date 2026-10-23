/// Absolute paths to the model files needed by the speech worker.
///
/// Instances are plain data so they can be sent to the worker isolate.
/// TTS is not part of this: the Kokoro pack is a lazy download addressed
/// through TtsSpec.kokoro, not a fixed layout.
///
/// [modelType] says which family the paths describe — the three the worker
/// builds are 'whisper', 'moonshine' and 'qwen3-asr' — and only that
/// family's fields are filled, and every family reads [vadModel].
class ModelPaths {
  /// sherpa-onnx's own `model_type` string, so it reaches the config unread.
  final String modelType;

  final String whisperEncoder;
  final String whisperDecoder;

  /// The Moonshine v2 pair: `encoder_model.ort` + `decoder_model_merged.ort`.
  /// sherpa's v2 config also names a preprocessor and an uncached/cached
  /// decoder split, but the shipped packages need neither — its own usage
  /// lines pass encoder + merged decoder + tokens and nothing else.
  final String moonshineEncoder;
  final String moonshineMergedDecoder;

  /// The Qwen3-ASR graph set: a convolutional audio frontend, the int8
  /// encoder and decoder, and the directory holding the BPE vocabulary the
  /// decoder's prompt is built from. [tokens] stays empty for this family —
  /// the tokenizer directory replaces it.
  final String qwen3ConvFrontend;
  final String qwen3Encoder;
  final String qwen3Decoder;
  final String qwen3Tokenizer;

  /// Recognition units, one per line — the file role for Whisper and
  /// Moonshine. Qwen3 carries its vocabulary in [qwen3Tokenizer] instead.
  final String tokens;
  final String vadModel; // optional; '' disables VAD/conversation mode

  const ModelPaths({
    this.modelType = 'whisper',
    this.whisperEncoder = '',
    this.whisperDecoder = '',
    this.moonshineEncoder = '',
    this.moonshineMergedDecoder = '',
    this.qwen3ConvFrontend = '',
    this.qwen3Encoder = '',
    this.qwen3Decoder = '',
    this.qwen3Tokenizer = '',
    this.tokens = '',
    this.vadModel = '',
  });

  /// Whether a clip longer than the decoder's own window gets cut by the
  /// Silero gate before it is decoded. Whisper is capped by its 30 s window
  /// and Moonshine's exported graphs by theirs, so a long hold MUST be
  /// split or it amputates; Qwen3 reads the whole utterance as context and
  /// measured worse when split (22.9 percent word error whole against 41.7
  /// chunked on an 88 s noisy clip), so it decodes whole and the endpointer
  /// stays the only splitter — which already caps a hold at 20 s.
  bool get chunksLongClips => modelType != 'qwen3-asr';
}
