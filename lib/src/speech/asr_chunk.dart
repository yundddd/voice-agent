/// VAD chunking for long push-to-talk clips — pure over the VadBackend
/// interface, tested with the worker's FakeVad (test/asr_chunk_test.dart).
///
/// Why this exists: Whisper is a thirty-second model — sherpa's Dart
/// bindings (1.13.8) expose no enableVad on the offline recognizer, so
/// feeding a longer clip simply loses everything past the window. The
/// live path never notices (its streaming VAD endpoints at 20 seconds),
/// but push-to-talk records the whole hold and posts one transcribe job:
/// a 45-second question used to come back as its first 30 seconds with
/// no hint of the amputation. chunkForWhisper runs the SAME silero model
/// the endpointer uses over the finished clip, hands back the speech
/// segments, and the caller decodes each inside its own window and joins
/// the texts.
library;

import 'dart:typed_data';

import 'worker_backends.dart';

/// A full second of pushed silence to force an endpoint on audio that
/// was still mid-word when the button came up (minSilenceDuration is at
/// most a few hundred ms; a second can't lose a real pause).
const int _endpointPadMs = 1000;

/// Split [samples] (mono, [sampleRate] Hz) into speech segments using
/// [vad]. Windows are fed exactly 512 samples at a time (the model's
/// windowSize — the real sherpa VAD rejects other sizes), the short
/// remainder rides a zero-padded window as silence, and a full second
/// of silence follows so a detection that never fell still surfaces.
/// Returns [] when the VAD found no speech at all — the caller decides
/// (decode the whole clip anyway, or report silence).
List<Float32List> chunkForWhisper(
  VadBackend vad,
  Float32List samples,
  int sampleRate, {
  int window = 512,
}) {
  vad.reset();
  final segments = <Float32List>[];
  void drain() {
    while (!vad.isEmpty()) {
      segments.add(Float32List.fromList(vad.frontSamples()));
      vad.pop();
    }
  }

  final win = Float32List(window);
  var i = 0;
  for (; i + window <= samples.length; i += window) {
    win.setRange(0, window, samples, i);
    vad.acceptWaveform(win);
    drain();
  }
  // The sub-window remainder, as a zero-padded (trailing-silent) window.
  if (samples.length > i) {
    win.fillRange(0, window, 0);
    win.setRange(0, samples.length - i, samples, i);
    vad.acceptWaveform(win);
    drain();
  }
  // Endpoint pad: push silence until any open detection falls.
  win.fillRange(0, window, 0);
  final padWindows = (sampleRate * _endpointPadMs ~/ 1000) ~/ window;
  for (var p = 0; p < padWindows; p++) {
    vad.acceptWaveform(win);
    drain();
  }
  return segments;
}
