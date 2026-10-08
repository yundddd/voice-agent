/// Absolute paths to the model files needed by the speech worker.
///
/// Instances are plain data so they can be sent to the worker isolate.
class ModelPaths {
  final String whisperEncoder;
  final String whisperDecoder;
  final String whisperTokens;
  final String vitsModel;
  final String vitsTokens;
  final String espeakDataDir;
  final String vadModel; // optional; '' disables VAD/conversation mode

  const ModelPaths({
    required this.whisperEncoder,
    required this.whisperDecoder,
    required this.whisperTokens,
    required this.vitsModel,
    required this.vitsTokens,
    required this.espeakDataDir,
    this.vadModel = '',
  });

  /// Paths for the layout produced by [unpackModels] (lib/model_packs.dart).
  factory ModelPaths.fromModelsDir(String dir) => ModelPaths(
        whisperEncoder: '$dir/asr-whisper-tiny.en/tiny.en-encoder.int8.onnx',
        whisperDecoder: '$dir/asr-whisper-tiny.en/tiny.en-decoder.int8.onnx',
        whisperTokens: '$dir/asr-whisper-tiny.en/tiny.en-tokens.txt',
        vitsModel: '$dir/tts-lessac-medium/en_US-lessac-medium.onnx',
        vitsTokens: '$dir/tts-lessac-medium/tokens.txt',
        espeakDataDir: '$dir/tts-lessac-medium/espeak-ng-data',
        vadModel: '$dir/silero_vad.onnx',
      );
}
