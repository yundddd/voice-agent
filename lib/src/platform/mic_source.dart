/// The microphone seam: the one interface the app's capture logic talks
/// to, and the fake that tests run it against.
///
/// Everything above this ([MicPipeline] and the assistant) is pure Dart —
/// permission prompts, stream stalls, PCM16 encoding and platform audio
/// quirks all hide behind [MicSource], so the capture lifecycle is unit-
/// testable with a [FakeMicSource], and the app can grow a second
/// transport (iOS AVAudioEngine, a Bluetooth LE mic, a desktop loopback)
/// without touching the conversation logic. The production adapter lives
/// in record_mic_source.dart (the only file importing `record`).
library;

import 'dart:async';
import 'dart:typed_data';

abstract interface class MicSource {
  /// False = the user said no (or the OS never asked); capture cannot start.
  Future<bool> hasPermission();

  /// Whether raw PCM16 streaming is available on this platform/device.
  Future<bool> supportsPcm16();

  /// Starts capture and returns the raw PCM16-LE byte stream (16 kHz mono).
  /// Must be safe to call again after [stop] (reopen = same object).
  Future<Stream<Uint8List>> start();

  /// Stops capture; idempotent and error-tolerant (an OS-killed stream
  /// makes this a no-op, never a throw).
  Future<void> stop();

  Future<void> dispose();
}

/// Scripted capture stream for tests: [emit] pushes bytes, [kill] plays
/// the device pulling the mic away (stream error or done), and the
/// counters let a test assert the watchdog's reopen behaviour.
class FakeMicSource implements MicSource {
  FakeMicSource({
    this.permission = true,
    this.pcm16Supported = true,
    this.failStart = false,
  });

  bool permission;
  bool pcm16Supported;
  bool failStart;
  int startCount = 0;
  int stopCount = 0;

  StreamController<Uint8List>? _ctl;

  void emit(Uint8List bytes) => _ctl?.add(bytes);

  /// The device yanked the stream out from under us (Android's habit
  /// when our own playback steals audio focus).
  void kill() => _ctl?.close();

  /// The stream raised an error (the other way capture dies).
  void fail(Object error) => _ctl?.addError(error, StackTrace.empty);

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<bool> supportsPcm16() async => pcm16Supported;

  @override
  Future<Stream<Uint8List>> start() async {
    startCount++;
    if (failStart) throw Exception('mic busy');
    return (_ctl = StreamController<Uint8List>()).stream;
    // A killed stream must be replaceable: the pipeline cancels the old
    // sub before re-listening, so a closed controller is fine.
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final c = _ctl;
    if (c != null && !c.isClosed) await c.close();
  }

  @override
  Future<void> dispose() async {
    if (_ctl != null && !_ctl!.isClosed) await _ctl!.close();
  }
}
