/// The speaker seam: what the streamed-reply machinery needs from an
/// audio backend, and the fake that proves the choreography in a unit
/// test.
///
/// The assistant's reply pipeline ([ReplyPipeline] above) works against
/// [AudioOutput]: hand it PCM, it plays; it reports the natural end; a
/// [stop] is a cut, not an end. Temp-file details, plugin quirks and
/// completion-event filtering live in the one production adapter
/// (file_player_output.dart); a second backend (iOS AVAudioEngine,
/// ExoPlayer, an OpenSL path that skips the temp file entirely) can be
/// swapped in underneath the same pipeline.
library;

import 'dart:async';
import 'dart:typed_data';

abstract interface class AudioOutput {
  /// Fires when a [play] finishes on its own (audio drained to silence).
  /// A cut through [stop] must NOT fire this.
  Stream<void> get onNaturalEnd;

  /// Queues [samples] for playback; returns once the player has been
  /// handed the bytes (not once they finished).
  Future<void> play(Float32List samples, int sampleRate, {String? tag});

  /// Cuts current playback immediately; idempotent.
  Future<void> stop();

  /// Frees the storage of the finished/stopped play (and any earlier
  /// ones it still holds).
  void discardCurrent();

  Future<void> dispose();
}

/// Scripted player for tests: [complete] fires "the audio ran out",
/// every handed chunk is recorded for exact-sequence assertions, and
/// [stop] counts prove who cut whom.
class FakeAudioOutput implements AudioOutput {
  final StreamController<void> _ended = StreamController<void>.broadcast();

  /// Every chunk handed to the player, in order.
  final List<(Float32List, int)> played = [];
  final List<String?> tags = [];
  int stopCount = 0;
  bool playing = false;

  @override
  Stream<void> get onNaturalEnd => _ended.stream;

  @override
  Future<void> play(
    Float32List samples,
    int sampleRate, {
    String? tag,
  }) async {
    played.add((samples, sampleRate));
    tags.add(tag);
    playing = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    playing = false;
  }

  /// Model the natural end of the chunk currently playing.
  void complete() {
    if (!playing) return; // a cut chunk ends silently
    playing = false;
    _ended.add(null);
  }

  @override
  void discardCurrent() {}

  @override
  Future<void> dispose() => _ended.close();
}
