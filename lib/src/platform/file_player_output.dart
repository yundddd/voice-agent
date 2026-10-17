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

  // +117: the assistant audio context. The plugin default is plain MEDIA
  // usage, and a media track does not ask Android for audio focus — so
  // while another app owned the session (the field log: an APK install
  // with Telegram in front), our chunks 'played' to a silent route and
  // only the first blips reached the ear before something else stayed
  // on top. ASSISTANT usage with transient-duck focus is what voice
  // UIs get: it ducks music, yields to ringers, and never plays
  // unheard behind a hog. Applied once, lazily, before the first play.
  static final _voiceContext = AudioContext(
    android: AudioContextAndroid(
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.assistant,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );
  Future<void>? _ctx;

  @override
  Stream<void> get onNaturalEnd => _ended.stream;

  @override
  Future<void> play(Float32List samples, int sampleRate, {String? tag}) async {
    _ctx ??= _player.setAudioContext(_voiceContext).catchError(
      (_) {},
    ); // one shot; failures stay silent, playback continues
    await _ctx;
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
