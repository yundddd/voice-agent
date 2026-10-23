/// The production [AudioOutput]: `audioplayers` playing temp WAV files —
/// the shape the whole app has always used (one temp file per chunk,
/// deleted at the seam, so the plugin's own buffering never grows across
/// a long answer and the file litter stays one chunk deep).
///
/// +317: the first Bluetooth reply announced itself — thin and telephone-
/// band for its first part, full and stereo for its second — because the
/// mic session leaves Android's output on the call (SCO) route and the
/// UNDECLARED media stream flips it to the media (A2DP) route UNDER the
/// still-playing first utterance. The fix is one declared lane: the very
/// first play (always the launch silent warm-up) declares the player's
/// lane, so route negotiation happens once, inside silence no one hears —
/// the output twin of the mic's warm-up drop (see record_mic_source.dart),
/// and just as traceable: the declaration journals itself.
///
/// +321 (Tim: '让 Voice Agent 通过音乐音量放出来，通话音量声音太小了'):
/// the declared lane is MEDIA, not voice-communication. The +317 lane
/// won one-lane routing on Bluetooth but cost the volume keys — with a
/// voice-communication stream alive, Android retargets them to the call
/// stream, and a call volume sitting near zero silenced an entire
/// session while this file's own journal recorded full-duration plays
/// ('chunk play 19.0s', 'audio seam … of say' — the +118 silent-speaker
/// signature with a new cause). On the media lane the user's volume keys
/// are the phone's own mixer for the voice, which is where Tim wants it.
///
/// +318 (Tim: 'don't cut the TTS off — turn the volume down gradually,
/// but make it quick'): a cut — barge-in, tab swipe, preview stop —
/// rides a ~75 ms volume ramp into silence before the player stops.
/// Every +289 cut law survives the courtesy; only the HOW of the death
/// changed, from vanish to fade.
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
  /// +317/+321: declare the playback lane — media, the lane the user's
  /// music (volume) speaks on — before the first source is handed over.
  Future<void> declarePlaybackLane();

  /// +318: 0.0..1.0 — the ramp a cut rides down on (and back up on).
  Future<void> setVolume(double volume);

  /// +319: write the GLOBAL audio context — audioplayers' global channel
  /// is the one that touches AudioManager.mode; writing our
  /// voice-communication context with mode=normal is the plugin-side way
  /// of saying 'the call is over', without the app growing Kotlin of its
  /// own for one setter.
  Future<void> releaseCommunicationMode();
  Future<void> play(Source source);
  Future<void> stop();
  Stream<void> get onPlayerComplete;
  Future<void> dispose();
}

class _AudioPlayerAdapter implements FilePlayerPlatform {
  _AudioPlayerAdapter(this._player);
  final AudioPlayer _player;

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> releaseCommunicationMode() => AudioPlayer.global
      .setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.voiceCommunication,
            contentType: AndroidContentType.speech,
            audioMode: AndroidAudioMode.normal,
          ),
        ),
      );

  @override
  Future<void> declarePlaybackLane() => _player.setAudioContext(
    // +321 (Tim: 'can the Voice Agent come out through the music
    // volume? the call volume is too quiet'): usage=MEDIA, content=MUSIC
    // — the reply rides STREAM_MUSIC, so the volume keys the user presses
    // over the speaking app are the ones that raise its voice. The +317
    // voice-communication lane bought one-lane routing on Bluetooth but
    // made Android retarget the keys to the call stream, and a call
    // volume parked near zero silenced a whole session while the app
    // journalled full-duration plays (the +118 signature wearing a new
    // cause). The explicit declaration stands: a lane named in the
    // journal beats a lane inherited from the plugin's default.
    AudioContext(
      android: const AudioContextAndroid(
        usageType: AndroidUsageType.media,
        contentType: AndroidContentType.music,
      ),
    ),
  );

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

  /// +317: the lane declaration is once-per-player — a platform round
  /// trip that must never re-run mid-answer, and whose failure must
  /// never mute one: a lane that will not take the declaration plays
  /// on the plugin default, and the next play re-asks.
  bool _laneDeclared = false;

  /// +318 (Tim: 'rather than cutting off, turn the volume down
  /// gradually — but make it quick'): does the player hold a live
  /// audible source (so a cut's ramp means something), is a ramp in
  /// flight, and is the volume's climb back to full still owed. Four
  /// steps at 25 ms is ~75 ms of ramp plus platform round trips: one
  /// syllable. Every cut law survives the courtesy.
  bool _playing = false;
  bool _restoreVolume = false;
  Future<void>? _fading;
  static const List<double> _fadeSteps = [0.7, 0.45, 0.2, 0.0];
  static const Duration _fadeStep = Duration(milliseconds: 25);

  @override
  Future<void> play(Float32List samples, int sampleRate, {String? tag}) async {
    // +119: the audio-context experiment is REVERTED. +117 (no focus)
    // and +118 (assistant GAIN) both cut replies in the field while the
    // plugin's plain default spoke all morning clean; the journal's
    // full-duration plays under a silent speaker smell like a stuck
    // duck in this device's assistant lane. Dedup and ledger fixes
    // stay; the route question gets re-earned with data, not guesses.
    // +317 re-earned it: the assistant lane died and the field tape
    // (BT speaker, first reply thin-then-full mid-sentence) named the
    // media lane's route flip as the survivor — the player declares its
    // lane once, on the silent warm-up, so the switch costs a heard
    // nothing. +321 moves that declaration to the MEDIA lane (usage
    // media/content music): the voice-communication lane made Android
    // hand the volume keys to the call stream, and the field answer
    // (whole session silent, keys moving the phone-volume, Tim: 'the
    // call volume is too quiet') says the user's ear belongs to the
    // music stream. Watch the journal: a silent speaker with
    // full-duration plays again is the +118 signature and this
    // declaration goes back to the drawer with it; the +317 BT
    // first-reply tape may return too, and gets re-earned on that
    // device, not pre-paid on every one.
    if (!_laneDeclared) {
      final cutsAtDoor = _cuts;
      try {
        await _player.declarePlaybackLane();
        _laneDeclared = true;
        note?.call(
          'audio lane: playback declared media '
          "(the user's music volume speaks; the route switch lands in silence)",
        );
      } catch (_) {}
      if (_cuts != cutsAtDoor) return; // +289: the cut crossed the
      // declaration door — the chunk dies at the door, fileless.
    }
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
    final fade = _fading;
    if (fade != null) {
      await fade; // +318: a chunk may not be handed to a player still
      // ramping down — the fade's bottom stop would take it down
      // unheard (the +289 law wearing a new door).
      if (_cuts != cuts0) {
        discardCurrent(); // another cut landed on the ramp's back
        return;
      }
    }
    if (_restoreVolume) {
      // +318: a ramp may not leave the lane silent — if its own climb
      // back died (a dispose caught mid-fade), the next chunk restores
      // the level before it is handed over. A silent speaker with
      // full-duration plays is the +118 signature; this is the door
      // that keeps the fade from ever writing it.
      _restoreVolume = false;
      try {
        await _player.setVolume(1.0);
      } catch (_) {}
      if (_cuts != cuts0) {
        discardCurrent();
        return;
      }
    }
    _listenOnce(minAge);
    _cutting = false;
    await _player.play(DeviceFileSource(file.path));
    if (_cuts != cuts0) {
      // +289: the cut crossed the play round trip itself — some
      // platforms start the source past their own stop. Re-cut; the
      // completion event lands suppressed (_cutting).
      await stop();
    } else {
      _playing = true; // +318: there is now a live source for a cut's
      // ramp to take down; a cut across this play's own hand-off stays
      // the hard re-cut it always was.
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
      _playing = false; // +318: the audio ran out — there is no live
      // source left for a cut to be smooth about.
      _ended.add(null);
    });
    _pendingEnd = sub;
  }

  @override
  Future<void> stop() async {
    _cuts++; // +289: the clock ticks before anything else — a play
    // in flight reads the new number at its next await and dies.
    _cutting = true;
    final running = _fading;
    if (running != null) {
      await running; // +318: a ramp already falling needs no second
      // ramp — one fade per cut wave.
      return;
    }
    if (!_playing) {
      try {
        await _player.stop();
      } catch (_) {}
      return; // nothing audible to be smooth about
    }
    _playing = false;
    final fade = _fadeThenStop();
    _fading = fade; // set synchronously: a second stop() finds it
    // before the ramp's first await surrenders the turn.
    try {
      await fade;
    } finally {
      _fading = null;
    }
  }

  /// +318: the cut's syllable rides ~75 ms of volume ramp into the
  /// quiet instead of popping mid-word. The cut dies by every law that
  /// matters: the epoch ticked in [stop] before the first await, the
  /// completion event is suppressed as _cutting, the player is STOPPED
  /// at the bottom of the ramp — whoever speaks next owns the speaker
  /// immediately; only the tail of the audio already killed is allowed
  /// to dim rather than vanish. Traced, per the drop law.
  Future<void> _fadeThenStop() async {
    _restoreVolume = true;
    note?.call('audio cut: faded out (not popped) over ~0.1s');
    for (final v in _fadeSteps) {
      try {
        await _player.setVolume(v);
      } catch (_) {
        break;
      }
      if (v > 0) await Future<void>.delayed(_fadeStep);
    }
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _player.setVolume(1.0);
      _restoreVolume = false;
    } catch (_) {} // the flag stands; play()'s restore door takes it
  }

  @override
  Future<void> releaseCallRoute() async {
    // +319: the recorder is gone; tell Android the call is over NOW
    // instead of letting its call line idle for seconds and trapping
    // the first reply on it (the field's thin-first-chunk tape). A
    // platform that refuses the write changes nothing for the voice:
    // the line expires on its own, exactly as it did before +319.
    try {
      await _player.releaseCommunicationMode();
      note?.call(
        'audio hold: left call mode at mic close (the swap absorbs '
        'itself in the silence that follows)',
      );
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
    final fade = _fading;
    if (fade != null) {
      // +318: let an in-flight ramp finish its stop (and its climb
      // back) before the player dies — a fade left running past
      // dispose is how a silent-lane signature gets written.
      try {
        await fade;
      } catch (_) {}
    }
    await _player.dispose();
    await _ended.close();
  }
}
