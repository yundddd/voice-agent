/// The production capture adapter: the `record` plugin in
/// voiceCommunication mode (platform AEC + AGC, speaker ON so the room
/// can hear the reply while the mic keeps listening for the barge-in).
///
/// Deliberately does NOT force AudioManagerMode.modeInCommunication —
/// the plugin's mode juggling around our media playback revokes
/// communication mode and can silently kill capture after the first
/// reply; the source alone still gets us the platform AEC.
///
/// Fresh streams are also lazy and unstable: the communication route
/// needs a moment to attach and the AEC/NS chain needs to lock, so the
/// first hundreds of milliseconds of a just-opened stream are junk —
/// the first takes after a launch (or after any reopen) come out
/// corrupted or empty. [warmUp] drops that many milliseconds of bytes
/// per start, counted IN BYTES (32 B/ms at 16 kHz mono PCM16) so the
/// settled amount of audio dropped is fixed no matter how lumpy the
/// platform channel's delivery is. The drop is logged at open and
/// accounted at the end — an in-flight drop must be traceable.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'mic_source.dart';

class RecordMicSource implements MicSource {
  RecordMicSource({
    AudioRecorder? recorder,
    this.warmUp = const Duration(milliseconds: 400),
    this.log,
  }) : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  /// Bytes of fresh capture to discard per [start] while the
  /// communication route and the AEC settle. Zero disables the drop.
  final Duration warmUp;

  /// Where the warm drop reports itself (the app's debug log); silent
  /// when null.
  final void Function(String msg)? log;

  /// 16 kHz mono PCM16.
  static const int _bytesPerMs = 32;

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
  Future<Stream<Uint8List>> start() async {
    final raw = await _recorder.startStream(_config);
    if (warmUp <= Duration.zero) return raw;
    var owed = warmUp.inMilliseconds * _bytesPerMs;
    var dropped = 0;
    log?.call('mic warm: first ${warmUp.inMilliseconds}ms of fresh capture '
        'will be dropped (route + AEC settle)');
    late final StreamController<Uint8List> out;
    late final StreamSubscription<Uint8List> sub;
    void report(String why) {
      if (dropped > 0) {
        log?.call('mic warm: dropped $dropped bytes ($why)');
      }
    }

    out = StreamController<Uint8List>(onCancel: () => sub.cancel());
    sub = raw.listen(
      (bytes) {
        if (owed > 0) {
          final take = bytes.length <= owed ? bytes.length : owed;
          owed -= take;
          dropped += take;
          if (owed == 0) report('open settled');
          if (take < bytes.length) out.add(bytes.sublist(take));
          return;
        }
        out.add(bytes);
      },
      onError: (Object e, StackTrace st) {
        report('stream errored mid-warm');
        out.addError(e, st);
      },
      onDone: () {
        if (owed > 0) report('stream ended mid-warm');
        out.close();
      },
    );
    return out.stream;
  }

  @override
  Future<void> stop() async {
    try {
      await _recorder.stop();
    } catch (_) {} // an OS-killed stream is already stopped
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
