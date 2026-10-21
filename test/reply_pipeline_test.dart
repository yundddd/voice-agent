// The reply pipeline's end-of-audio routing, at the seam the previews
// live on. The regression this pins (found on device): the end event
// had ONE subscriber, armed by the streamed-reply pump — so a voice
// auditioned BEFORE the first streamed reply heard the event with no
// listener, the broadcast dropped it, and playOnce rode its 120 s
// timeout out while the user watched a finished sentence spin.
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
}
