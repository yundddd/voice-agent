/// Absolute paths to the model files needed by the speech worker.
///
/// Instances are plain data so they can be sent to the worker isolate.
/// TTS is not part of this: the Kokoro pack is a lazy download addressed
/// through TtsSpec.kokoro, not a fixed layout.
class ModelPaths {
  final String whisperEncoder;
  final String whisperDecoder;
  final String whisperTokens;
  final String vadModel; // optional; '' disables VAD/conversation mode

  const ModelPaths({
    required this.whisperEncoder,
    required this.whisperDecoder,
    required this.whisperTokens,
    this.vadModel = '',
  });

  /// Paths for the layout produced by [unpackModels] (lib/model_packs.dart).
  factory ModelPaths.fromModelsDir(String dir) => ModelPaths(
    whisperEncoder: '$dir/asr-whisper-tiny.en/tiny.en-encoder.int8.onnx',
    whisperDecoder: '$dir/asr-whisper-tiny.en/tiny.en-decoder.int8.onnx',
    whisperTokens: '$dir/asr-whisper-tiny.en/tiny.en-tokens.txt',
    vadModel: '$dir/silero_vad.onnx',
  );
}
