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
}

class _FakePlatform implements FilePlayerPlatform {
  int starts = 0;
  int stops = 0;
  Completer<void>? holdStart;
  final StreamController<void> _complete = StreamController<void>.broadcast();

  @override
  Future<void> play(Source source) async {
    starts++;
    await holdStart?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Stream<void> get onPlayerComplete => _complete.stream;

  @override
  Future<void> dispose() async {}
}
