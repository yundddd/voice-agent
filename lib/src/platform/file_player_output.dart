/// The production [AudioOutput]: `audioplayers` playing temp WAV files —
/// the shape the whole app has always used (one temp file per chunk,
/// deleted at the seam, so the plugin's own buffering never grows across
/// a long answer and the file litter stays one chunk deep).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/audio_io.dart';
import 'audio_output.dart';

/// +289: the slice of the platform player this adapter drives, kept
/// as a seam so the cut races below are provable in a plain unit
/// test (the real AudioPlayer wants a live binding the moment it is
/// constructed; the fake wants nothing). One production
/// implementation: [_AudioPlayerAdapter].
abstract interface class FilePlayerPlatform {
  Future<void> play(Source source);
  Future<void> stop();
  Stream<void> get onPlayerComplete;
  Future<void> dispose();
}

class _AudioPlayerAdapter implements FilePlayerPlatform {
  _AudioPlayerAdapter(this._player);
  final AudioPlayer _player;

  @override
  Future<void> play(Source source) => _player.play(source);

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<void> get onPlayerComplete => _player.onPlayerComplete;

  @override
  Future<void> dispose() => _player.dispose();
}

class FilePlayerAudioOutput implements AudioOutput {
  FilePlayerAudioOutput({
    FilePlayerPlatform? player,
    Future<Directory> Function()? tempDir,
    this.note,
  }) : _player = player ?? _AudioPlayerAdapter(AudioPlayer()),
       _tempDir = tempDir ?? getTemporaryDirectory;

  final FilePlayerPlatform _player;
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
  // +289 (Tim: 'swipe away — the TTS should be stopped immediately,
  // but is still speaking'): the cut's own clock. Every stop()
  // counts, and a play() that crossed a number since it began is
  // DEAD ON ARRIVAL — the speaker belongs to whoever speaks next,
  // not to a chunk still encoding while its cut landed. The old code
  // reset _cutting mid-flight and started the player anyway, so a
  // chunk caught in the hand-off talked its full length (seconds;
  // the +288 tape's were twelve) over the tab the user swiped to.
  int _cuts = 0;

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
    final cuts0 = _cuts; // +289: this chunk's cut epoch at birth
    final dir = await _tempDir();
    if (_cuts != cuts0) {
      // +289: a cut landed while the temp dir was still a promise —
      // the chunk never even became a file.
      return;
    }
    final file = File(
      p.join(
        dir.path,
        'reply_${tag ?? DateTime.now().millisecondsSinceEpoch}.wav',
      ),
    );
    // +210: an eight-second section is 384 000 float samples, and the
    // float-to-PCM loop measured THIRTY-THREE MILLISECONDS on the
    // seam witness — on the platform thread, which in this app is
    // the thread the channel draws on. Big clips encode on a worker
    // isolate now (the message copy is a memcpy; the loop is not our
    // frame's problem anymore); small ones stay inline, because
    // spawning a worker is not free below a tenth of a second of
    // audio.
    if (samples.length >= 24000) {
      final bytes = await Isolate.run(() => encodeWav(samples, sampleRate));
      await file.writeAsBytes(bytes);
    } else {
      await file.writeAsBytes(encodeWav(samples, sampleRate));
    }
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
    if (_cuts != cuts0) {
      // +289: the cut landed across the encode (an isolate round
      // trip is real time) — the file exists, the player must never
      // see it. discardCurrent takes it down.
      discardCurrent();
      return;
    }
    _listenOnce(minAge);
    _cutting = false;
    await _player.play(DeviceFileSource(file.path));
    if (_cuts != cuts0) {
      // +289: the cut crossed the play round trip itself — some
      // platforms start the source past their own stop. Re-cut; the
      // completion event lands suppressed (_cutting).
      await stop();
    }
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

  /// +291 (the field tape's 'chunk ended naturally: ran 0.0s of 5.4s
  /// handed'): ONE listener, the current play's. The +123 minAge guard
  /// swallows play()'s own source-reset artifact and stays armed for
  /// the real end — but a swallowed-then-never-satisfied listener is
  /// a landmine: once its minAge ages past, ANY later event satisfies
  /// it — typically the NEXT chunk's own hand-off artifact, minutes
  /// or merely rows later. The stale sub consumes that event, the
  /// CURRENT chunk's seam closes at its own hand-off, the pump steps
  /// forward while the murdered chunk is still on air, and the next
  /// play's source swap eats its seconds unheard: short paragraphs
  /// (small minAge, aged instantly) are the usual victims, and
  /// 'ran 0.0s of Ys handed' is the fingerprint. A fresh play retires
  /// its predecessor's listener before arming its own — an answer
  /// period ends when the question changes.
  StreamSubscription<void>? _pendingEnd;

  void _listenOnce(Duration minAge) {
    unawaited(_pendingEnd?.cancel()); // +291: the previous play's landmine
    // is defused before this one arms; its seam is already resolved
    // (the pump plays in order), and an event no one waits for is
    // worth losing.
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
    _pendingEnd = sub;
  }

  @override
  Future<void> stop() async {
    _cuts++; // +289: the clock ticks before anything else — a play
    // in flight reads the new number at its next await and dies.
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
    await _pendingEnd?.cancel(); // +291: no landmine outlives the output
    await _player.dispose();
    await _ended.close();
  }
}
