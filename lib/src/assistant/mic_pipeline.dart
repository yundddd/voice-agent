/// Microphone plumbing shared by both interaction modes and the bench.
///
/// Owns the capture stream's whole lifecycle — open, watchdog, reopen
/// after the OS yanks it, 512-sample alignment for the VAD, and the
/// raw-chunk feed for push-to-talk / bench recording — behind the
/// [MicSource] seam, so `record` plugin quirks live in exactly one
/// adapter and this file is a testable state machine with a
/// [FakeMicSource] and a [FakeScheduler].
///
/// In conversation mode the mic must stay alive through our reply, both
/// for barge-in and so capture recovers if Android kills it during
/// playback — hence the watchdog instead of trusting the stream's own
/// error events. Reopening a voiceComm capture stream can duck or pause
/// media playback (audio focus churn on many devices) — while our reply
/// is audible that is worse than a temporarily deaf barge-in mic, so the
/// reopen waits for the reply to end.
library;

import 'dart:async';
import 'dart:typed_data';

import '../common/clock.dart';
import '../common/sinks.dart';
import '../platform/mic_source.dart';

/// Where the next mic chunk goes.
enum MicRoute {
  /// Debug replay is audible: the stream stays live for the watchdog
  /// only — its bytes must not leak back into the pipeline.
  mute,

  /// Mono float32 chunks as they arrive (push-to-talk buffer, bench
  /// capture).
  raw,

  /// 512-sample windows, aligned (the VAD's exact appetite).
  vad,
}

class MicPipeline {
  MicPipeline({
    required this.source,
    required this.scheduler,
    required this.clock,
    required this.log,
    required this.streamWanted,
    required this.route,
    required this.paused,
    required this.audioBusy,
    required this.onRaw,
    required this.onVadWindow,
    required this.gatePin,
    required this.resetVad,
    required this.userSpeaking,
    required this.reopened,
    required this.failed,
    required this.disposed,
    this.stallAfter = const Duration(milliseconds: 1250),
    this.watchEvery = const Duration(milliseconds: 500),
    this.reopenBackoff = const Duration(milliseconds: 150),
  });

  final MicSource source;
  final Scheduler scheduler;
  final Clock clock;
  final DebugSink log;

  /// Whether a live mic stream is expected right now (drives the
  /// watchdog). In conversation mode the mic must stay alive through our
  /// reply, both for barge-in and so capture recovers if Android kills
  /// it during playback; bench capture counts too (same stream,
  /// different sink).
  final bool Function() streamWanted;

  /// Asked per chunk: which sink these bytes feed.
  final MicRoute Function() route;

  /// App hidden: never reopen behind the user's back (resume owns it).
  final bool Function() paused;

  /// Our reply is audible (player busy or chunks queued): a reopen now
  /// would duck it, so the recover defers until playback ends.
  final bool Function() audioBusy;

  final void Function(Float32List pcm16k) onRaw;
  final void Function(Float32List window512) onVadWindow;

  /// Hard-modes the speech gate while the fresh stream's AEC re-locks
  /// (a mid-reply reopen leaks speaker echo hard for a few hundred ms).
  final void Function(bool on) gatePin;
  final void Function() resetVad;
  final bool Function() userSpeaking;

  /// The stream is back up: the assistant refreshes status (and knows a
  /// listening session survived).
  final void Function() reopened;
  final void Function(String why) failed;

  /// The app is going away under a deferred reopen (Android kills
  /// process mid-recover — the original's `_disposed` gate): the reopen
  /// must silently die rather than fail a dead UI.
  final bool Function() disposed;

  /// No bytes for this long while a stream is wanted = stalled.
  final Duration stallAfter;
  final Duration watchEvery;
  final Duration reopenBackoff;

  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _vadBuf = BytesBuilder(copy: false); // 512-sample aligner
  Timer? _watchdog;
  DateTime _lastByteAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _recovering = false;
  bool _recoverPending = false;
  bool _open = false;

  bool get recoverPending => _recoverPending;

  /// A live capture stream is attached right now (journal flag `micOpen`).
  bool get isOpen => _sub != null;

  /// Clean stop first: makes reopening idempotent (watchdog restarts,
  /// retries after errors, mode switches).
  Future<void> open() async {
    _vadBuf.clear();
    if (!await source.hasPermission()) {
      throw Exception('Microphone permission denied');
    }
    if (!await source.supportsPcm16()) {
      throw Exception('PCM16 capture not supported on this platform');
    }
    await _sub?.cancel();
    _sub = null;
    await source.stop();
    // voiceCommunication source + AEC/AGC: lets the mic hear the user
    // while our own TTS plays through the speaker (barge-in). Note: we
    // deliberately do NOT force AudioManagerMode.modeInCommunication —
    // the plugin's mode juggling around our media playback revokes
    // communication mode and can silently kill capture after the first
    // reply; the source alone still gets us the platform AEC.
    final stream = await source.start();
    _open = true;
    _lastByteAt = clock();
    _recoverPending = false; // a fresh stream voids any deferred reopen
    _sub = stream.listen(
      _onBytes,
      // Android can close the capture stream when our playback changes
      // audio focus/mode/routing — that is exactly what the watchdog is
      // for.
      onError: (Object e) => unawaited(recover('error: $e')),
      onDone: () => unawaited(recover('ended')),
    );
    _startWatchdog();
  }

  /// Tear the capture down completely (mode switch, hide, bench end).
  Future<void> close() async {
    _watchdog?.cancel();
    _watchdog = null;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    await source.stop();
    _vadBuf.clear();
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    void tick() {
      if (_open) {
        if (!_recovering && !_recoverPending && streamWanted()) {
          if (clock().difference(_lastByteAt) > stallAfter) {
            unawaited(recover('stalled'));
          }
        }
        _watchdog = scheduler.after(watchEvery, tick);
      }
    }

    _watchdog = scheduler.after(watchEvery, tick);
  }

  /// Reopen the mic after the OS ends, pauses or stalls the capture
  /// stream (common after our own playback: focus/mode/routing changes).
  Future<void> recover(String why) async {
    if (_recovering || !streamWanted() || paused()) return;
    // Reopening a voiceComm capture stream can duck or pause media
    // playback (audio focus churn on many devices) — while our reply is
    // audible that is worse than a temporarily deaf barge-in mic, so the
    // reopen waits for the reply to end. PTT never bites: no stream is
    // wanted while it plays.
    if (audioBusy()) {
      if (!_recoverPending) {
        _recoverPending = true;
        log('mic recover deferred ($why)');
      }
      return;
    }
    _recovering = true;
    log('mic stream $why — reopening');
    _recoverPending = false;
    await Future<void>.delayed(reopenBackoff);
    if (disposed()) return;
    try {
      await open(); // also resets _lastByteAt and the watchdog
      // Reopening the capture mid-reply is an AEC re-lock event: the
      // fresh stream leaks speaker echo hard for a few hundred ms, and
      // streamed replies make this common (Android stalls capture across
      // the media hand-off of every chunk seam). Without the pin, the
      // leak rides the +20 dB playback bar and our own reply interrupts
      // itself.
      if (audioBusy()) gatePin(true);
      // Don't seed a fresh VAD while the user is mid-utterance: their
      // in-progress segment lives in the VAD ring and stays valid.
      if (!userSpeaking()) resetVad();
      reopened();
    } catch (e) {
      failed('$e');
    } finally {
      _recovering = false;
    }
  }

  /// If capture went silent during our reply (our playback is a common
  /// trigger for Android tearing it down), reopen right now instead of
  /// waiting for the next watchdog tick.
  void fastCheck() {
    // During a bench run the mic is deliberately closed (the echo plays
    // to an unplugged mic; _afterCapture reopens conversation
    // afterwards).
    if (_recovering || !streamWanted()) return;
    if (clock().difference(_lastByteAt) > const Duration(milliseconds: 750)) {
      unawaited(recover('post-reply'));
    }
  }

  /// Playback just ended (naturally or by a stop): a deferred reopen
  /// earned its turn on the mic back.
  void flushPending() {
    if (!_recoverPending) return;
    log('mic recover flush');
    _recoverPending = false;
    unawaited(recover('deferred'));
  }

  void _onBytes(Uint8List bytes) {
    _lastByteAt = clock();
    switch (route()) {
      case MicRoute.mute:
        return;
      case MicRoute.raw:
        onRaw(_pcm16(bytes));
      case MicRoute.vad:
        // Conversation: feed the VAD in exactly 512-sample windows.
        _vadBuf.add(bytes);
        var pending = _vadBuf.toBytes(); // no-op when empty
        while (pending.length >= 512 * 2) {
          onVadWindow(_pcm16(Uint8List.sublistView(pending, 0, 512 * 2)));
          pending = pending.sublist(512 * 2);
        }
        _vadBuf
          ..clear()
          ..add(pending);
    }
  }

  Float32List _pcm16(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}
