/// The production [AudioOutput]: `audioplayers` playing temp WAV files —
/// the shape the whole app has always used (one temp file per chunk,
/// deleted at the seam, so the plugin's own buffering never grows across
/// a long answer and the file litter stays one chunk deep).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/audio_io.dart';
import 'audio_output.dart';

class FilePlayerAudioOutput implements AudioOutput {
  FilePlayerAudioOutput({
    AudioPlayer? player,
    Future<Directory> Function()? tempDir,
    this.note,
  }) : _player = player ?? AudioPlayer(),
       _tempDir = tempDir ?? getTemporaryDirectory;

  final AudioPlayer _player;
  final Future<Directory> Function() _tempDir;

  /// +209: the audio seam's own witness. The frame bill says every
  /// entrance loses one fifty-to-sixty-millisecond frame even after
  /// the fade (and its layer upload) died — and the gap lands on the
  /// moment a section's VOICE is queued. audioplayers does its native
  /// work on the platform's main thread, the very thread the UI draws
  /// on, so every stage here (file write, delete, play round trip)
  /// is timed and reported before we accuse the right one.
  final void Function(String)? note;
  final StreamController<void> _ended = StreamController<void>.broadcast();
  String? _file;
  bool _cutting = false;

  @override
  Stream<void> get onNaturalEnd => _ended.stream;

  @override
  Future<void> play(Float32List samples, int sampleRate, {String? tag}) async {
    // +119: the audio-context experiment is REVERTED. +117 (no focus)
    // and +118 (assistant GAIN) both cut replies in the field while the
    // plugin's plain default spoke all morning clean; the journal's
    // full-duration plays under a silent speaker smell like a stuck
    // duck in this device's assistant lane. Dedup and ledger fixes
    // stay; the route question gets re-earned with data, not guesses.
    final seam = Stopwatch()..start();
    final dir = await _tempDir();
    final file = File(
      p.join(
        dir.path,
        'reply_${tag ?? DateTime.now().millisecondsSinceEpoch}.wav',
      ),
    );
    await file.writeAsBytes(encodeWav(samples, sampleRate));
    final wavMs = seam.elapsedMilliseconds;
    final prev = _file;
    _file = file.path;
    if (prev != null) {
      unawaited(File(prev).delete().catchError((_) => File(prev)));
    }
    // +123: a completion event that arrives before the audio could
    // physically have run out is the reset that play() itself performs
    // when swapping sources (audioplayers fires onPlayerComplete on the
    // internal stop on several platforms). The old listener took ANY
    // event as the seam: the incoming chunk's own play() handed us the
    // previous chunk's farewell event, the pump believed the segment
    // had finished, and the next sentence stomped the one on air
    // mid-word — every "cut off but the next segment started fine"
    // report in one line of code. Guard the seam by the chunk's real
    // duration, with a little slack for rounding.
    final minAge = Duration(
      milliseconds: ((samples.length / sampleRate) * 1000 - 120).round(),
    );
    _listenOnce(minAge);
    _cutting = false;
    await _player.play(DeviceFileSource(file.path));
    // The round trip returned — anything past the async handoffs is
    // time the platform's main thread spent ON the player's behalf,
    // and that thread is the one the channel draws on.
    final playMs = seam.elapsedMilliseconds - wavMs;
    if (note != null && (playMs >= 8 || wavMs >= 8)) {
      note!(
        'audio seam: wav ${wavMs}ms play ${playMs}ms'
        ' (${samples.length ~/ sampleRate}s of ${tag ?? 'say'})',
      );
    }
  }

  void _listenOnce(Duration minAge) {
    final started = Stopwatch()..start();
    late StreamSubscription<void> sub;
    sub = _player.onPlayerComplete.listen((_) {
      // The completion of a play we deliberately cut is not a natural
      // end: the pipeline owns that transition itself (and audioplayers
      // fires the event on stop() too on several platforms).
      if (_cutting) {
        sub.cancel();
        return;
      }
      if (started.elapsed < minAge) return; // source-reset artifact, not
      // the end of this chunk: stay armed for the real one.
      sub.cancel();
      _ended.add(null);
    });
  }

  @override
  Future<void> stop() async {
    _cutting = true;
    try {
      await _player.stop();
    } catch (_) {}
  }

  @override
  void discardCurrent() {
    final f = _file;
    _file = null;
    if (f != null) {
      unawaited(File(f).delete().catchError((_) => File(f)));
    }
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
    await _ended.close();
  }
}
