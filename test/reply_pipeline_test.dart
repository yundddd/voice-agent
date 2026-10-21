// The reply pipeline's end-of-audio routing, at the seam the previews
// live on. The regression this pins (found on device): the end event
// had ONE subscriber, armed by the streamed-reply pump — so a voice
// auditioned BEFORE the first streamed reply heard the event with no
// listener, the broadcast dropped it, and playOnce rode its 120 s
// timeout out while the user watched a finished sentence spin.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/reply_pipeline.dart';
import 'package:voice_agent/src/common/sinks.dart';
import 'package:voice_agent/src/platform/audio_output.dart';

import 'support/fakes.dart';

Future<void> settle({int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  (FakeAudioOutput, FakeSpeechEngine, ReplyPipeline) rig() {
    final out = FakeAudioOutput();
    final engine = FakeSpeechEngine();
    final time = FakeScheduler(DateTime(2026, 1, 1, 12));
    return (
      out,
      engine,
      ReplyPipeline(
        output: out,
        worker: () => engine,
        clock: () => time.now,
        scheduler: time,
        repaint: () {},
        userSpeaking: () => false,
        gatePin: (_) {},
        resetVad: () {},
        onNaturalEnd: () {},
        onStopped: () {},
      ),
    );
  }

  test(
    'a preview completes on the natural end with NO pump ever run',
    () async {
      final (out, _, reply) = rig();
      final playing = reply.playOnce('hello there');
      await settle();
      expect(out.played, isNotEmpty, reason: 'the line reached the player');
      // The natural end: this is where the un-listened pipeline used to
      // lose the event forever. If the await does not return in zero
      // timeouts, the spinner would have sat on the 120 s watchdog.
      out.complete();
      final audio = await playing;
      expect(audio, isA<Float32List>());
      expect(out.tags, contains('voice_preview'));
    },
  );

  test(
    'a cut preview resolves too (stop completes the wait, as before)',
    () async {
      final (out, _, reply) = rig();
      final playing = reply.playOnce('a line that gets interrupted');
      await settle();
      reply.stopPlayback();
      await playing; // completes via the stop path, not the dropped event
      expect(out.stopCount, greaterThan(0));
    },
  );

  test(
    '+270: a cut mid-stream kills the pump; the next paragraph revives it',
    () async {
      // The field signature: a tab switch cuts the mouth of a SURVIVING
      // turn (audio dies, stream lives) — and every later paragraph of
      // that turn synthesised into a readerless queue: 'when I swipe
      // back it is just completely silent'. The pump respawns at the
      // enqueue door whenever the stream is still open and the
      // producer is still current — the cut is allowed to be a cut,
      // not a burial.
      final (out, _, reply) = rig();
      reply.startStream();
      unawaited(reply.runPump(isStale: () => false));
      await settle();
      await reply.speakBlock(
        'first paragraph',
        alive: () => true,
        onAir: (_) {},
      );
      await settle();
      expect(out.played, hasLength(1));
      expect(reply.playing, isTrue);
      reply.stopPlayback(); // the landing cut, mid-utterance
      await settle(); // the completed seam lets the pump reach its exit
      expect(
        reply.pumpAlive,
        isFalse,
        reason: 'the seam check still retires it',
      );
      await reply.speakBlock(
        'second paragraph',
        alive: () => true,
        onAir: (_) {},
      );
      await settle();
      expect(
        out.played,
        hasLength(2),
        reason: 'the queue has a reader again — the voice comes back',
      );
      out.complete();
      reply.closeStream();
      await settle();
    },
  );

  test('+289: a cut inside the play hand-off re-cuts the late start', () async {
    // The race +289 closes: stopPlayback fires while a chunk sits
    // INSIDE output.play (the encode, the plugin hand-off — real
    // time on the real backend). A backend that takes the source
    // past its own stop would talk that chunk's full length over
    // the tab the user swiped to; the pump's belt catches it at
    // the instant it started. The production net is one layer
    // deeper (FilePlayerAudioOutput refuses to start past a cut);
    // this is the second.
    final out = _LateStartOutput();
    final engine = FakeSpeechEngine();
    final time = FakeScheduler(DateTime(2026, 1, 1, 12));
    final reply = ReplyPipeline(
      output: out,
      worker: () => engine,
      clock: () => time.now,
      scheduler: time,
      repaint: () {},
      userSpeaking: () => false,
      gatePin: (_) {},
      resetVad: () {},
      onNaturalEnd: () {},
      onStopped: () {},
    );
    out.gate = Completer<void>();
    reply.startStream();
    unawaited(reply.runPump(isStale: () => false));
    await settle();
    final speak = reply.speakBlock(
      'a tail that starts past its cut',
      alive: () => true,
      onAir: (_) {},
    );
    await settle();
    // The pump is parked inside output.play — the chunk on the seam.
    expect(out.played, isEmpty, reason: 'the gate holds the hand-off');
    final stopsBefore = out.stopCount;
    reply.stopPlayback(); // the cut lands INSIDE the hand-off
    out.gate!.complete(); // and this backend starts anyway
    await speak;
    await settle();
    expect(out.played, hasLength(1), reason: 'late, but it started');
    expect(
      out.stopCount,
      greaterThan(stopsBefore + 1),
      reason: 'stopPlayback cut once; the belt re-cut the late start',
    );
    expect(reply.playing, isFalse);
    expect(reply.pumpAlive, isFalse);
    reply.closeStream();
  });

  test(
    '+270: an ABANDONED stream (closed before the stragglers) stays dead',
    () async {
      // The barge-in law holds: detach abandons the turn and closes the
      // seam first; a late chunk (error paths, races) must NOT revive
      // a pump whose producer walked out — that would replay leftovers
      // to a user who already took the mic.
      final (out, _, reply) = rig();
      reply.startStream();
      unawaited(reply.runPump(isStale: () => false));
      await settle();
      await reply.speakBlock('heard one', alive: () => true, onAir: (_) {});
      await settle();
      reply.stopPlayback();
      reply.clearAndClose(); // the abandonment door
      reply.enqueue(Float32List(2400), 24000); // a straggler
      await settle();
      expect(out.played, hasLength(1), reason: 'no revival for the abandoned');
      expect(reply.pumpAlive, isFalse);
    },
  );
}

/// +289: a backend whose play() sits in flight (the real one encodes
/// a WAV and crosses a platform channel — seconds can live in that
/// await). While [gate] is pending, the chunk has NOT reached the
/// player; completing it starts the late hand-off the belt catches.
class _LateStartOutput extends FakeAudioOutput {
  Completer<void>? gate;

  @override
  Future<void> play(Float32List samples, int sampleRate, {String? tag}) async {
    final g = gate;
    if (g != null) await g.future;
    await super.play(samples, sampleRate, tag: tag);
  }
}
