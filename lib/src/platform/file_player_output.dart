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
  }) : _player = player ?? AudioPlayer(),
       _tempDir = tempDir ?? getTemporaryDirectory;

  final AudioPlayer _player;
  final Future<Directory> Function() _tempDir;
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
    final dir = await _tempDir();
    final file = File(
      p.join(
        dir.path,
        'reply_${tag ?? DateTime.now().millisecondsSinceEpoch}.wav',
      ),
    );
    await file.writeAsBytes(encodeWav(samples, sampleRate));
    final prev = _file;
    _file = file.path;
    if (prev != null) {
      unawaited(File(prev).delete().catchError((_) => File(prev)));
    }
    _listenOnce();
    _cutting = false;
    await _player.play(DeviceFileSource(file.path));
  }

  void _listenOnce() {
    late StreamSubscription<void> sub;
    sub = _player.onPlayerComplete.listen((_) {
      sub.cancel();
      if (!_cutting) _ended.add(null); // the completion of a play we
      // deliberately cut is not a natural end: the pipeline owns that
      // transition itself (and audioplayers fires the event on stop()
      // too on several platforms).
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
