// +289 (Tim's field: 'swipe away from a session — the TTS should be
// stopped IMMEDIATELY, but is still speaking'): the production
// output's own cut law. A chunk that encoded through its own stop
// used to reset _cutting and start the native player anyway — the
// field's tails were whole paragraphs (tapes up to twelve seconds)
// talking over the tab the user swiped TO. These tests pin the
// promise: a cut that lands anywhere before or inside the hand-off
// kills the chunk — the player never starts it (or is re-cut the
// instant it started), and no wav is left on the disk.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart' show Source;
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/platform/file_player_output.dart';

Future<void> settle({int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('+289: a cut landing on the temp-dir seam means the chunk never '
      'becomes a file, never reaches the player', () async {
    final dir = await Directory.systemTemp.createTemp('racing_dir');
    final gate = Completer<Directory>();
    final platform = _FakePlatform();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () => gate.future,
    );
    final playing = out.play(Float32List(1600), 16000, tag: 'race');
    await settle(); // parked inside _tempDir()
    unawaited(out.stop()); // the switch cut lands here (the count
    // ticks before stop's first await — no need to await the wire)
    gate.complete(dir);
    await playing; // returns at the door
    expect(
      dir.listSync(),
      isEmpty,
      reason: 'the abandoned chunk left nothing behind',
    );
    expect(platform.starts, 0, reason: 'the player never saw it');
  });

  test('+289: a cut crossing the encode takes the written file down — the '
      'player never sees it', () async {
    final dir = await Directory.systemTemp.createTemp('racing_encode');
    final gate = Completer<Directory>();
    final platform = _FakePlatform();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () => gate.future,
    );
    // >= 24 000 samples takes the isolate encode — real event-loop
    // time, the window the field's cut kept losing.
    final playing = out.play(Float32List(48000), 16000, tag: 'race');
    await settle(); // parked inside _tempDir()
    gate.complete(dir);
    // The cut lands AFTER play resumes past the first door (the
    // continuation microtask) and BEFORE the isolate answers (a
    // port event cannot overtake an enqueued microtask): exactly
    // the encode window.
    unawaited(Future<void>.microtask(out.stop));
    await playing;
    // The take-down is an unawaited delete — give the IO a beat.
    await settle();
    expect(
      dir.listSync(),
      isEmpty,
      reason: 'the file existed for a moment and died at the seam',
    );
    expect(platform.starts, 0, reason: 'and the player never saw it');
  });

  test('+289: a cut crossing the play round trip RE-CUTS the started '
      'source — a late start does not talk', () async {
    final dir = await Directory.systemTemp.createTemp('racing_start');
    final platform = _FakePlatform()..holdStart = Completer<void>();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => dir,
    );
    final playing = out.play(Float32List(1600), 16000, tag: 'race');
    await settle(); // the hand-off is in flight: started, unreturned
    expect(platform.starts, 1);
    await out.stop(); // the cut races the platform's own start
    platform.holdStart!.complete();
    await playing; // the guard re-cuts at the far shore
    expect(
      platform.stops,
      greaterThan(1),
      reason:
          'stop landed once before the guard; the guard re-cut '
          'the source the platform started past it',
    );
  });

  test('+291: a stale listener may not spend the NEXT chunk\'s artifact — '
      'the seam closes only on its own end', () async {
    // The 'ran 0.0s of 5.4s handed' fingerprint, reproduced: chunk A's
    // hand-off artifact is swallowed young (the +123 law — stay
    // armed), A's minAge ages past while no event for A ever lands
    // (its audio gets source-swapped), and the NEXT chunk's artifact
    // walks into the landmine: the old code spent it on A's listener,
    // completed B's seam at B's own hand-off, and the pump's next
    // play murdered B's seconds unheard.
    final dir = await Directory.systemTemp.createTemp('stale_mine');
    final platform = _FakePlatform();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => dir,
    );
    final ends = <void>[];
    out.onNaturalEnd.listen(ends.add);
    // 0.2 s at 16 kHz: minAge ~80 ms.
    await out.play(Float32List(3200), 16000, tag: 'A');
    platform.fireComplete(); // A's own artifact: too young, swallowed,
    // the listener stays armed — the landmine is set.
    await Future<void>.delayed(const Duration(milliseconds: 200)); // A's
    // minAge ages past; nothing ever answers for A.
    await out.play(Float32List(6400), 16000, tag: 'B'); // 0.4 s:
    // minAge ~280 ms.
    platform.fireComplete(); // B's hand-off artifact.
    await settle();
    expect(
      ends,
      isEmpty,
      reason:
          'the artifact belongs to no seam — the old code let A\'s '
          'stale listener spend it and closed B\'s at birth',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500)); // B's
    // audio really ran out now.
    platform.fireComplete();
    await settle();
    expect(ends, hasLength(1), reason: 'B\'s real end is heard, once');
  });

  test('+317: the first play declares the lane BEFORE the player is '
      'handed a source — and only the first', () async {
    final dir = await Directory.systemTemp.createTemp('lane_first');
    final platform = _FakePlatform();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => dir,
    );
    await out.play(Float32List(1600), 16000, tag: 'warmup');
    await out.play(Float32List(1600), 16000, tag: 'A');
    expect(
      platform.apiOrder,
      ['declare', 'play', 'play'],
      reason:
          'the route negotiation must be over before any audible byte '
          'is queued, and it must never re-run mid-answer',
    );
    expect(platform.declares, 1);
  });

  test('+317: a refused declaration does not mute the chunk — it plays '
      'on the default lane and the next play re-asks', () async {
    final dir = await Directory.systemTemp.createTemp('lane_refused');
    final platform = _FakePlatform()..failDeclare = true;
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => dir,
    );
    await out.play(Float32List(1600), 16000, tag: 'A');
    expect(platform.starts, 1, reason: 'the voice rides the default lane');
    await out.play(Float32List(1600), 16000, tag: 'B');
    expect(
      platform.declares,
      2,
      reason: 'a failed opening may be tried again — the +120 law',
    );
  });

  test('+317: a cut landing inside the declaration door kills the chunk '
      'at the door — fileless, unheard', () async {
    final dir = await Directory.systemTemp.createTemp('lane_cut');
    final gate = Completer<void>();
    final platform = _FakePlatform()..holdDeclare = gate;
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => dir,
    );
    final playing = out.play(Float32List(1600), 16000, tag: 'race');
    await settle(); // parked inside the platform round trip
    unawaited(out.stop()); // the cut lands on the declaration door
    gate.complete();
    await playing;
    expect(platform.starts, 0, reason: 'the player never saw it');
    expect(
      dir.listSync(),
      isEmpty,
      reason: 'the abandoned chunk never even became a file',
    );
  });

  test('+318: a cut on LIVE audio rides a quick ramp down, stops at the '
      'bottom, and the lane climbs back — make it quick', () async {
    final dir = await Directory.systemTemp.createTemp('fade_live');
    final platform = _FakePlatform();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => dir,
    );
    final sw = Stopwatch()..start();
    await out.play(Float32List(48000), 24000, tag: 'A'); // live now
    await out.stop();
    expect(
      sw.elapsedMilliseconds,
      lessThan(300),
      reason: 'gradual, but a syllable — not a curtain',
    );
    expect(
      platform.volumes,
      [0.7, 0.45, 0.2, 0.0, 1.0],
      reason: 'monotonic down, then the climb back — a ramp may not '
          'leave the lane silent (the +118 signature)',
    );
    expect(
      platform.apiOrder,
      ['declare', 'play', 'vol 0.7', 'vol 0.45', 'vol 0.2', 'vol 0.0',
      'stop', 'vol 1.0'],
      reason: 'the stop lands at the bottom of the ramp, not before it',
    );
  });

  test('+318: a cut with nothing audible spends no ramp — it just '
      'stops, idempotent as ever', () async {
    final platform = _FakePlatform();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => Directory.systemTemp,
    );
    await out.stop();
    expect(platform.volumes, isEmpty, reason: 'nothing to be smooth about');
    expect(platform.stops, 1);
  });

  test('+318: the next chunk waits for the in-flight fade — it never '
      'talks under the old audio\'s tail, and one ramp serves the wave',
      () async {
    final dir = await Directory.systemTemp.createTemp('fade_next');
    final platform = _FakePlatform();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => dir,
    );
    await out.play(Float32List(48000), 24000, tag: 'A');
    final cut = out.stop(); // unawaited: the fade is in flight
    final next = out.play(Float32List(48000), 24000, tag: 'B');
    await cut;
    await next;
    expect(
      platform.apiOrder,
      ['declare', 'play', 'vol 0.7', 'vol 0.45', 'vol 0.2', 'vol 0.0',
      'stop', 'vol 1.0', 'play'],
      reason: 'B was handed over only after A\'s ramp stopped and the '
          'level came back — and the old fade\'s stop is the re-cut',
    );
    expect(platform.stops, 1);
    expect(platform.declares, 1);
  });

  test('+318: a second cut on a falling ramp asks for no second ramp',
      () async {
    final dir = await Directory.systemTemp.createTemp('fade_twice');
    final platform = _FakePlatform();
    final out = FilePlayerAudioOutput(
      player: platform,
      tempDir: () async => dir,
    );
    await out.play(Float32List(48000), 24000, tag: 'A');
    final first = out.stop();
    await out.stop(); // the tab-swipe lands on the barge-in's ramp
    await first;
    expect(
      platform.volumes,
      [0.7, 0.45, 0.2, 0.0, 1.0],
      reason: 'one fade per cut wave',
    );
    expect(platform.stops, 1);
  });
}

class _FakePlatform implements FilePlayerPlatform {
  int starts = 0;
  int stops = 0;
  int declares = 0;

  /// The platform calls this adapter is given, in order (+317: 'the
  /// lane is declared before the first source' is pinned, not wished —
  /// the same apiOrder trick as FakeHarness).
  final List<String> apiOrder = [];

  /// Every level the fade handed the platform, in order (+318).
  final List<double> volumes = [];
  Completer<void>? holdStart;
  Completer<void>? holdDeclare;
  bool failDeclare = false;
  final StreamController<void> _complete = StreamController<void>.broadcast();

  /// Push the platform's own onPlayerComplete event (the hand-off
  /// artifact and the real end look identical from here — which is
  /// exactly the point the minAge guard and +291 adjudicate).
  void fireComplete() => _complete.add(null);

  @override
  Future<void> setVolume(double volume) async {
    apiOrder.add('vol $volume');
    volumes.add(volume);
  }

  @override
  Future<void> declareCommunicationLane() async {
    apiOrder.add('declare');
    declares++;
    await holdDeclare?.future;
    if (failDeclare) throw StateError('lane refused');
  }

  @override
  Future<void> play(Source source) async {
    apiOrder.add('play');
    starts++;
    await holdStart?.future;
  }

  @override
  Future<void> stop() async {
    apiOrder.add('stop');
    stops++;
  }

  @override
  Stream<void> get onPlayerComplete => _complete.stream;

  @override
  Future<void> dispose() async {}
}
