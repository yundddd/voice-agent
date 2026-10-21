// The speech isolate's whole pipeline, tested with ONNX faked out: the
// real worker isolate, the real job protocol, the real noise gate and
// endpointing choreography — and [FakeBackends] where the native
// Whisper/Silero/Kokoro calls would be. Transcription answers and TTS
// audio are scripted; no libraries, no models, no microphone, no
// LD_LIBRARY_PATH. (The real-model roundtrip lives in roundtrip_test.dart
// and skips itself when the runtime cannot load.)
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/models/model_paths.dart';
import 'package:voice_agent/src/speech/speech_worker.dart';

/// Deterministic pseudo-noise (the quiet-room floor).
Float32List quiet(int seed, {double amp = 0.0004}) {
  final w = Float32List(512);
  var s = seed;
  for (var i = 0; i < w.length; i++) {
    s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
    w[i] = (s / 0x7FFFFFFF - 1) * amp;
  }
  return w;
}

/// Let the worker isolate drain its mailbox and answer.
Future<void> flushed() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

/// A loud window (-15 dBFS 100 Hz tone) — speech-like band energy that
/// sails past every margin the gate can demand (floor starts at -40).
Float32List loud({int skip = 0}) {
  final w = Float32List(512);
  final a = math.pow(10, -15 / 20) * math.sqrt2;
  for (var i = 0; i < w.length; i++) {
    final t = (i + skip) / 16000.0;
    w[i] = (a * math.sin(2 * math.pi * 100 * t)).toDouble();
  }
  return w;
}

void main() {
  Future<SpeechWorker> startFake({
    List<String> transcripts = const ['fake transcript'],
    List<List<String>> partialGroups = const [],
    int vadStartsAt = 1,
    int vadEndsAt = 4,
    int ttsChunkSamples = 600,
    int ttsNumSpeakers = 1,
    void Function(SpeechEvent)? onEvent,
    TtsSpec? tts,
  }) => SpeechWorker.start(
    const ModelPaths(
      whisperEncoder: '',
      whisperDecoder: '',
      whisperTokens: '',
    ), // fakes read no files
    tts: tts,
    onEvent: onEvent,
    backends: FakeBackends(
      transcripts: transcripts,
      partialGroups: partialGroups,
      vadStartsAt: vadStartsAt,
      vadEndsAt: vadEndsAt,
      ttsChunkSamples: ttsChunkSamples,
      ttsNumSpeakers: ttsNumSpeakers,
    ),
  );

  group('fake-backed worker isolate', () {
    test('transcribe answers the script in order (last sticks)', () async {
      final w = await startFake(transcripts: const ['first', 'second']);
      addTearDown(w.dispose);
      expect(await w.transcribe(Float32List(16000), 16000), 'first');
      expect(await w.transcribe(Float32List(16000), 16000), 'second');
      expect(await w.transcribe(Float32List(16000), 16000), 'second');
    });

    test('+236: a chunked decode raises cumulative partials before the '
        'result — the worker relays them as partial: notes', () async {
      final notes = <String>[];
      final w = await startFake(
        transcripts: const ['one two three'],
        partialGroups: const [
          ['one', 'one two', 'one two three'],
        ],
        onEvent: (e) {
          if (e.note != null) notes.add(e.note!);
        },
      );
      addTearDown(w.dispose);
      expect(await w.transcribe(Float32List(16000), 16000), 'one two three');
      await flushed(); // let the event lane deliver what the result raced
      expect(
        notes,
        ['partial:one', 'partial:one two', 'partial:one two three'],
        reason:
            'cumulative, in order, on the note channel — the UI '
            'reads the prefix and fills the placeholder bubble',
      );
    });

    test(
      'no voice loaded yet: synthesis says so instead of babbling',
      () async {
        final w = await startFake(); // tts: null — the lazy-download case
        addTearDown(w.dispose);
        await expectLater(
          w.synthesize('hello'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('No TTS engine'),
            ),
          ),
        );
      },
    );

    test('streamed synthesis splits at sentences and pads the seams', () async {
      final w = await startFake(
        tts: const TtsSpec.titl(
          titlModels: '',
          titlVocabs: '',
          lexiconPaths: '',
        ),
      );
      addTearDown(w.dispose);
      const text =
          'One two three four five six seven eight nine ten. '
          'Eleven twelve thirteen fourteen fifteen sixteen seventeen '
          'eighteen nineteen twenty! Does this split land on more than '
          'one piece, the way a real reply does, with commas, semicolons; '
          'and closing marks? Yes it does.';
      final pieces = splitForTts(text);
      expect(
        pieces.length,
        greaterThan(1),
        reason: 'long prose splits (short prose packs: by design)',
      );

      final chunkLens = <int>[];
      final (audio, rate) = await w.synthesizeStream(
        text,
        onChunk: (chunk, r) => chunkLens.add(chunk.length),
      );
      expect(rate, 24000);
      expect(chunkLens, hasLength(pieces.length));
      // FakeTts renders 600 samples per piece; the worker appends a
      // rate~/16 silent tail to every non-final chunk to hide the seam.
      const seam = 24000 ~/ 16;
      for (var i = 0; i < chunkLens.length; i++) {
        expect(
          chunkLens[i],
          600 + (i < chunkLens.length - 1 ? seam : 0),
          reason: 'chunk ${pieces[i]}',
        );
      }
      expect(audio.length, chunkLens.reduce((a, b) => a + b));
    });

    test('useTts hot-swaps the engine and reports the roster', () async {
      final w = await startFake();
      addTearDown(w.dispose);
      expect(
        await w.useTts(
          const TtsSpec.kokoro(
            kokoroModel: '',
            kokoroVoices: '',
            kokoroTokens: '',
            kokoroDataDir: '',
            kokoroLexicon: '',
            sid: 7,
          ),
        ),
        1, // FakeTts is a humble one-voice model
      );
      final (audio, rate) = await w.synthesize('now I speak');
      expect(audio, isNotEmpty);
      expect(rate, 24000);
    });

    test(
      'synthesize sid override auditions a style without a rebuild',
      () async {
        // FakeTts packs the sid it generated with into the chunk amplitude.
        int heardSid(Float32List audio) =>
            ((audio.first * 100000).round()) % 250;
        const spec = TtsSpec.kokoro(
          kokoroModel: '',
          kokoroVoices: '',
          kokoroTokens: '',
          kokoroDataDir: '',
          kokoroLexicon: '',
          sid: 3,
        );
        final w = await startFake(tts: spec, ttsNumSpeakers: 8);
        addTearDown(w.dispose);
        // In-range override rides this call only…
        expect(heardSid((await w.synthesize('one piece here', sid: 5)).$1), 5);
        // …the engine keeps its configured speaker afterwards…
        expect(heardSid((await w.synthesize('one piece here')).$1), 3);
        // …and a bogus sid falls back to it rather than faulting the graph.
        expect(heardSid((await w.synthesize('one piece here', sid: 99)).$1), 3);
      },
    );

    test(
      'a student pick speaks: the spec sid is the synth default too',
      () async {
        // Same amplitude decode as the override test above: a TitlTts
        // roster rides the spec, so a picked style must be what an
        // un-overridden synthesize speaks (the bug this pins: specIn
        // dropped the sid and every style silently stayed on pack 0).
        int heardSid(Float32List audio) =>
            ((audio.first * 100000).round()) % 250;
        final w = await startFake(
          tts: const TtsSpec.titl(
            titlModels: '',
            titlVocabs: '',
            lexiconPaths: '',
            sid: 2,
          ),
          ttsNumSpeakers: 8,
        );
        addTearDown(w.dispose);
        expect(heardSid((await w.synthesize('one piece here')).$1), 2);
      },
    );

    test('denoise runs the real DSP on the fake worker', () async {
      final w = await startFake();
      addTearDown(w.dispose);
      final out = await w.denoise(
        Float32List.fromList(List.generate(16000, (i) => math.sin(i / 7.0))),
      );
      expect(out.length, 16000); // the frame gate shortens, high-pass never
    });

    test(
      'gate + fake VAD: start, endpoint, and a real segment event',
      () async {
        final events = <SpeechEvent>[];
        final w = await startFake(
          vadStartsAt: 9,
          vadEndsAt: 30,
          onEvent: events.add,
        );
        addTearDown(w.dispose);

        // Settle the noise floor on quiet frames first (the floor drops
        // instantly and only creeps back up at its capped rate).
        for (var i = 0; i < 8; i++) {
          w.sendAudio(quiet(i)); // windows 1..8: VAD stays down
        }
        await flushed();
        expect(
          events.where((e) => e.speechStarted),
          isEmpty,
          reason: 'nothing loud yet',
        );

        // Loud frames from the VAD's detection window on: after the 5-frame
        // confirm streak the worker raises speech.
        for (var i = 0; i < 22; i++) {
          w.sendAudio(loud(skip: i * 512)); // windows 9..30: detected
        }
        await flushed();
        expect(events.map((e) => e.speechStarted).where((v) => v).length, 1);

        // Silence: detection falls, and the buffered utterance comes back
        // as one endpointed segment (22 windows × 512 = 11 264 samples,
        // comfortably past the 0.2 s duty-cycle check).
        for (var i = 0; i < 4; i++) {
          w.sendAudio(quiet(100 + i)); // window 31+: the fall
        }
        await flushed();

        final segs = events.where((e) => e.segment != null).toList();
        expect(segs, hasLength(1));
        expect(segs.single.segment!.length, 22 * 512);
        expect(
          events.map(
            (e) => e.speechStarted
                ? 'start'
                : e.segment != null
                ? 'seg'
                : 'stop',
          ),
          containsAllInOrder(['start', 'stop']),
        );
      },
    );

    test('mid-reply barge-in needs a full 450 ms (the hard gate)', () async {
      final events = <SpeechEvent>[];
      final w = await startFake(
        vadStartsAt: 1,
        vadEndsAt: 200,
        onEvent: events.add,
      );
      addTearDown(w.dispose);
      for (var i = 0; i < 8; i++) {
        w.sendAudio(quiet(i)); // settle the floor
      }
      w.setPlaying(true); // the gate goes into hard mode

      // 10 loud frames (≈160 ms): past the ordinary streak, under the
      // playing streak — AEC leaks and AGC swells die here.
      for (var i = 0; i < 10; i++) {
        w.sendAudio(loud(skip: i * 512));
      }
      await flushed();
      expect(
        events.where((e) => e.speechStarted),
        isEmpty,
        reason: '160 ms of leak is not an interruption',
      );

      for (var i = 10; i < 20; i++) {
        w.sendAudio(loud(skip: i * 512));
      }
      await flushed();
      expect(
        events.where((e) => e.speechStarted),
        hasLength(1),
        reason: '14 sustained frames = ~450 ms: a real cut-in',
      );
    });

    test('resetVad drops a half-heard utterance', () async {
      final events = <SpeechEvent>[];
      final w = await startFake(
        vadStartsAt: 1,
        vadEndsAt: 200,
        onEvent: events.add,
      );
      addTearDown(w.dispose);
      for (var i = 0; i < 8; i++) {
        w.sendAudio(quiet(i));
      }
      for (var i = 0; i < 8; i++) {
        w.sendAudio(loud());
      }
      await flushed();
      expect(events.where((e) => e.speechStarted), hasLength(1));

      w.resetVad();
      await flushed();
      // The fall no longer yields a segment: the VAD buffer was dropped.
      for (var i = 0; i < 4; i++) {
        w.sendAudio(quiet(50 + i));
      }
      await flushed();
      expect(
        events.where((e) => e.segment != null),
        isEmpty,
        reason: 'the abandoned utterance never reaches the ASR',
      );
    });

    test('disposal fails pending work instead of hanging it', () async {
      final w = await startFake();
      final job = w.transcribe(Float32List(16000), 16000);
      w.dispose();
      await expectLater(job, throwsA(isA<StateError>()));
    });
  });
}
