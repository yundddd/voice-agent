/// The production capture adapter: the `record` plugin in
/// voiceCommunication mode (platform AEC + AGC, speaker ON so the room
/// can hear the reply while the mic keeps listening for the barge-in).
///
/// Deliberately does NOT force AudioManagerMode.modeInCommunication —
/// the plugin's mode juggling around our media playback revokes
/// communication mode and can silently kill capture after the first
/// reply; the source alone still gets us the platform AEC.
library;

import 'dart:typed_data';

import 'package:record/record.dart';

import 'mic_source.dart';

class RecordMicSource implements MicSource {
  RecordMicSource({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  static const _config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    autoGain: true,
    echoCancel: true,
    androidConfig: AndroidRecordConfig(
      audioSource: AndroidAudioSource.voiceCommunication,
      speakerphone: true,
    ),
  );

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<bool> supportsPcm16() =>
      _recorder.isEncoderSupported(AudioEncoder.pcm16bits);

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(_config);

  @override
  Future<void> stop() async {
    try {
      await _recorder.stop();
    } catch (_) {} // an OS-killed stream is already stopped
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
