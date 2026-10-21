/// Streamed reply playback: chunks synthesise while earlier ones play.
///
/// Plays reply chunks in order as they arrive. Sequential playback
/// leaves audio-identical boundaries (the worker appends a short silence
/// to every non-final chunk), while the player being momentarily idle
/// between chunks never loosens the gate: [playing] stays set for the
/// whole stream, so barge-in treats mid-synthesis gaps exactly like a
/// held reply.
///
/// Owns everything audible: the chunk queue and its pump, one-shot
/// plays (voice preview, debug replay of raw ASR/TTS bytes), and the
/// silent warm-up that holds the output route while the harness thinks
/// — all through the [AudioOutput] seam. The assistant keeps the
/// conversation meaning: what a first chunk does to the phase, the
/// latency strip, and the chat log.
///
/// Keep the output route BUSY from the moment a turn ends until the
/// first reply chunk replaces it: a few seconds of INAUDIBLE silence
/// played through the same player, so Android never gets a chance to
/// idle the output path (a one-shot 100 ms tick did not survive the
/// wait — the pipeline power-cycles within a couple hundred ms and the
/// real chunk paid the connect+ramp cost with its first words anyway;
/// this also rides through the mic-teardown transition on PTT).
/// Measured: PTT replies truncated the first word, while the Settings
/// voice preview — same synthesised bytes, no mic session before it —
/// played clean.
library;

import 'dart:async';
import 'dart:typed_data';

import '../common/clock.dart';
import '../common/sinks.dart';
import '../platform/audio_output.dart';
import '../speech/speech_engine.dart';

/// One streamed answer block, end-to-end.
class SpeakOutcome {
  const SpeakOutcome({required this.onAir, required this.durationSeconds});
  final bool onAir; // at least one chunk reached the queue
  final double durationSeconds; // of synthesised audio
}

class ReplyPipeline {
  ReplyPipeline({
    required this.output,
    required this.worker,
    required this.clock,
    required this.scheduler,
    required this.repaint,
    required this.userSpeaking,
    required this.gatePin,
    required this.resetVad,
    required this.onNaturalEnd,
    required this.onStopped,
    this.onAudible,
  });

  final AudioOutput output;

  /// The model factory may still be loading (null until init finishes);
  /// [speakBlock] surfaces that as an error to its caller.
  final SpeechEngine? Function() worker;
  final Clock clock;
  final Scheduler scheduler;
  final Repaint repaint;
  final bool Function() userSpeaking;

  /// Hard-modes the speech gate while we hear ourselves.
  final void Function(bool on) gatePin;
  final void Function() resetVad;

  /// Audio ran out on its own: the assistant idles or resumes listening
  /// and flushes any deferred mic reopen.
  final void Function() onNaturalEnd;

  /// The assistant's barge-in re-check hook (the mic pipeline's
  /// fastCheck) — every cut ends with a live-audio audit.
  final void Function() onStopped;

  /// Bytes entered the PLAYER (not just the queue): the bench stamps
  /// its release→first-audio number here — the temp-wav write in
  /// between is real latency the user hears as dead air, and the route
  /// warm-up from the release is included (a real PTT round trip pays
  /// that latency too, and pretending otherwise would flatter the
  /// panel's headline number).
  final void Function()? onAudible;

  // (samples, rate, start-of-audio hook): the third slot carries the
  // block's once-only onAir callback to the exact moment the pump hands
  // the chunk to the player (+121) — queued is not heard.
  final List<(Float32List, int, void Function()?)> _queue = [];
  bool _streamDone = true; // no stream in flight until startStream
  Completer<void>? _wake; // pokes the pump loop
  Completer<void>? _chunkDone; // resolves when the current chunk ends
  Completer<void>? _previewDone; // set while a preview line plays
  StreamSubscription<void>? _endSub;
  bool _playing = false;
  bool _pumpAlive = false;
  bool Function()? _pumpIsStale; // the live pump's producer test (+270)
  DateTime _startedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Debug replay state (see [replayDebug]) ──
  bool _debugPlaying = false;
  Completer<void>? _debugDone;

  // ── Forensics for the latency strip / journal flags ──
  double playSeconds = 0; // seconds of audio handed to the player
  Float32List? _lastTts; // exact audio the last synth produced
  int _lastTtsRate = 16000;

  bool get playing => _playing;
  bool get pumpAlive => _pumpAlive;
  bool get debugPlaying => _debugPlaying;
  int get queuedCount => _queue.length;
  bool get streamDone => _streamDone;

  /// Exact audio the TTS engine last generated (reply or voice preview)
  /// — the raw engine output, before playback; for replay/diagnostics.
  Float32List? get lastTtsAudio => _lastTts;
  int get lastTtsRate => _lastTtsRate;
  double get lastTtsSeconds =>
      _lastTts == null ? 0 : _lastTts!.length / _lastTtsRate;

  /// How long the current reply has been audible — the barge-in
  /// forensic line ('kill reply after 1320ms of reply') and the
  /// 450 ms trust guard both read it.
  Duration get audibleFor => clock().difference(_startedAt);

  /// The 450 ms AEC guard: an interruption that lands this early into a
  /// reply is too young to trust — AEC has not locked yet, so this
  /// "speech" may be our own reply. Keep talking; the word-overlap echo
  /// guard still discards the resulting text, and a genuine
  /// interruption a few hundred ms later mutes us as usual. (Was keyed
  /// on the phase the first chunk arrived with; keyed on play activity
  /// instead — same protection, one less cross-wire.)
  bool get tooYoungToTrust =>
      _playing &&
      clock().difference(_startedAt) < const Duration(milliseconds: 450);

  void _wakeNow() {
    final w = _wake;
    _wake = null;
    w?.complete();
  }

  /// Keep the most recent synth output for [debugReplayTts].
  void noteTts(Float32List audio, int rate) {
    _lastTts = audio;
    _lastTtsRate = rate;
  }

  /// A new streamed reply begins: drop any leftovers, reopen the pump's
  /// attention.
  void startStream() {
    _queue.clear();
    _streamDone = false;
    _playedRecently = false; // a new utterance re-arms the first-chunk
    // stamp (the phase-based rule of the original loops, expressed
    // against stream boundaries)
  }

  /// The producer is done: let the pump drain and idle.
  void closeStream() {
    _streamDone = true;
    _wakeNow();
  }

  /// An abandoned turn leaves no unplayed words behind: drain the queue
  /// and close the seam (the abandoned loop can't clobber a successor's
  /// fresh [startStream] set after this call).
  void clearAndClose() {
    _queue.clear();
    closeStream();
  }

  void enqueue(
    Float32List chunk,
    int sampleRate, {
    void Function()? onStarted,
  }) {
    _queue.add((chunk, sampleRate, onStarted));
    _wakeNow();
    // +270 (Tim's tape: return to a cut turn is 'completely silent'):
    // a pump KILLED mid-stream by stopPlayback — the switch landing
    // cut, a hide cut — died with the queue cleared, and every chunk
    // the STILL-LIVE turn synthesised after it went into a queue with
    // no reader: text arriving, voice never, for as long as the turn
    // ran (the tape: 119 s unheard after the return). The barge-in
    // case genuinely wants the pump gone (the turn itself is being
    // abandoned, and clearAndClose closes the stream first — the
    // guard below sees it). A SURVIVING producer does not: if the
    // stream is still open and the pump's producer is still current,
    // the next chunk respawns the pump. The rule lives HERE, at the
    // one enqueue door every producer passes, precisely so no speak
    // call site has to remember to revive anyone.
    final stale = _pumpIsStale;
    if (!_pumpAlive && !_streamDone && stale != null && !stale()) {
      unawaited(runPump(isStale: stale));
    }
  }

  /// Speak one answer block end-to-end: synth streamed into the play
  /// queue, and [onAir] fires the moment the FIRST chunk is about to
  /// queue — so the conversation log can stamp text-and-audio together.
  /// Waiting for the whole sentence to synthesise (the old order) let
  /// the voice win the race on long answers: audible seconds before any
  /// text. The first-chunk stamp also can't lead the audio (the chunk
  /// still has to reach the player after this), while an interrupted
  /// turn keeps the sections whose audio actually started — tail chunks
  /// still drop on the [alive] guard, so the card never grows while the
  /// loop has already stopped feeding the player (the old "text with no
  /// audio").
  ///
  /// [onAir] receives the elapsed synth time at the first chunk: the
  /// FIRST-WORD latency — received-to-ear — the wait the user actually
  /// hears as dead air (the strip's tts number).
  /// [drop] is consulted per chunk: a paragraph a hide cut mid-play is
  /// skipped whole (its chunks die here, no replay on return).
  Future<SpeakOutcome> speakBlock(
    String text, {
    required bool Function() alive,
    required void Function(Duration sinceText) onAir,
    bool Function()? drop,
  }) async {
    final w = worker();
    if (w == null) throw StateError('Models are still loading.');
    final sw = Stopwatch()..start();
    var onAirDone = false;
    final (audio, rate) = await w.synthesizeStream(
      text,
      onChunk: (chunk, sampleRate) {
        if (!alive()) return;
        if (drop != null && drop()) return; // hide cut this paragraph
        final ms = sw.elapsedMilliseconds;
        if (!onAirDone) {
          onAirDone = true;
          // +121: the reply→audio hop is crossed when the PLAYER
          // takes the chunk, not when the queue does. Paragraphs
          // dropped before their turn (the pump's stale-clear racing
          // a reattach drain or a supersede) must not fossilise as
          // 'heard' in the ledger, and the phase must not flip on a
          // silent speaker — the afternoon-long signature of the cut
          // at spinner dismissal was this stamp firing one paragraph
          // too early. The stopwatch still began when the text
          // arrived, so the reported elapsed IS the dead air.
          enqueue(
            chunk,
            sampleRate,
            onStarted: () => onAir(Duration(milliseconds: ms)),
          );
          return;
        }
        enqueue(chunk, sampleRate);
      },
    );
    sw.stop();
    // No cumulative synth sum anymore: the strip's tts number is the
    // first-word latency, stamped on the first chunk above, where the
    // pause the user actually feels lives.
    playSeconds += audio.length / rate;
    noteTts(audio, rate); // last message's raw audio: debug replay
    return SpeakOutcome(onAir: onAirDone, durationSeconds: audio.length / rate);
  }

  /// Plays streamed reply chunks in order as they arrive. The seam is
  /// captured, not re-read: [stopPlayback] nulls the shared field and
  /// completes it (a hide-mode pause cuts an audible chunk right here),
  /// and a naive `_chunkDone!` re-reads then null-threw the pump stone
  /// dead — which is how a survived bridge turn ended up streaming
  /// text-only forever.
  /// Arm the single end-of-audio router. EVERY waiter — the streamed
  /// pump, the one-shot preview, the debug replay — must hold this
  /// subscription before it awaits its end: onNaturalEnd is a
  /// broadcast stream, and an event with no listener is not queued,
  /// it is gone. A preview started before the first streamed reply
  /// used to hit exactly that: the audible end vanished, and the
  /// spinner rode the 120 s timeout out of pure politeness.
  void _armEnd() => _endSub ??= output.onNaturalEnd.listen((_) => _onEnd());

  Future<void> runPump({required bool Function() isStale}) async {
    var firstChunk = true;
    _pumpAlive = true;
    // +269: remember the staleness rule of the CURRENT pump so an
    // enqueue can respawn with the SAME producer identity (a respawn
    // under a newer generation's rule would play an abandoned turn's
    // leftovers back to us).
    _pumpIsStale = isStale;
    _armEnd();
    try {
      while (true) {
        while (_queue.isEmpty && !_streamDone) {
          await (_wake ??= Completer<void>()).future;
        }
        if (isStale()) {
          _queue.clear();
          return;
        }
        if (_queue.isEmpty) break; // stream drained and closed
        final (chunk, sampleRate, onStarted) = _queue.removeAt(0);
        firstChunk = false;
        final seam = Completer<void>();
        _chunkDone = seam;
        await _playWav(chunk, sampleRate, isStale, onStarted: onStarted);
        if (isStale()) return; // user resumed: drop the rest
        await seam.future; // ends on natural end... or a stop
        // Seam complete: the loop owns playback again. Clearing the flag
        // re-arms the end routing for any later one-shot play.
        _chunkDone = null;
        if (!_playing) return; // barge-in won: _stopPlayback cleaned up
      }
      if (firstChunk) return; // engine produced nothing (error path covers)
      // The queue drained and closed: the last chunk ended on its own
      // (its seam woke us), so this is the natural end of the whole
      // reply — route it through the same teardown the one-shot path
      // uses, so the assistant hook sees `playing` clear exactly once.
      noteNaturalEnd();
    } finally {
      // Dead pump, by whichever exit path: tells [resumeConversation]
      // whether the survived turn's queue needs a respawn to keep an
      // ear on the speaker.
      _pumpAlive = false;
    }
  }

  Future<void> _playWav(
    Float32List samples,
    int rate,
    bool Function() isStale, {
    void Function()? onStarted,
  }) async {
    _playing = true;
    // _startedAt marks only the FIRST chunk of an utterance: the 450 ms
    // AEC guard must not re-arm per chunk (a chunk boundary would
    // otherwise re-open the "too early to trust an interruption" window
    // every few seconds). A gap longer than 2 s within one stream is a
    // new live utterance for our purposes — the long-tool-call case
    // where the guard must re-arm too.
    if (!_playedRecently ||
        clock().difference(_startedAt) > const Duration(seconds: 2)) {
      _startedAt = clock();
    }
    _playedRecently = true;
    gatePin(true);
    _chunkLog(samples, rate);
    try {
      onStarted?.call(); // +121: this is the player's hand-off — the
      // block's onAir (ledger stamp, speaking phase, latency number)
      // rides this instant, the last one before the speaker owns it
      onAudible?.call(); // the honest release→ear clock starts at the
      // player's hand-off, not the queue write
      await output.play(samples, rate);
    } catch (e) {
      _playing = false;
      _playedRecently = false;
      gatePin(false);
      output.discardCurrent();
      rethrow;
    }
  }

  bool _playedRecently = false; // chunk-to-chunk carry-over (see above)

  void _chunkLog(Float32List samples, int rate) {
    _log?.call(
      'chunk play ${(samples.length / rate).toStringAsFixed(1)}s'
      '${_queue.isEmpty ? ' (last)' : ' +${_queue.length}'}',
    );
  }

  /// Journal hook for chunk seams (screenshot-able forensics).
  set log(void Function(String)? v) => _log = v;
  void Function(String)? _log;

  /// The single end-of-audio router: a pump seam wakes the streamed
  /// loop; anything else (preview, debug replay, or no listener at all)
  /// is a one-shot end and runs the full teardown + assistant hook —
  /// whose own `playing` guard keeps the no-op cases (a debug replay's
  /// end, a warm-up tick) silent, exactly like the global listener this
  /// router replaces.
  void _onEnd() {
    final seam = _chunkDone;
    if (seam != null && !seam.isCompleted) {
      seam.complete(); // streamed mode: runPump decides on end
      return;
    }
    final d = _debugDone;
    if (_debugPlaying && d != null && !d.isCompleted) d.complete();
    final p = _previewDone;
    if (p != null && !p.isCompleted) p.complete();
    noteNaturalEnd();
  }

  /// Audio ran out and nothing is mid-flight: close the playback
  /// bookkeeping and let the assistant own the aftermath (mic flush,
  /// phase transitions, the fast mic re-check).
  void noteNaturalEnd() {
    if (!_playing) return; // the pump's own end-of-stream call, or a
    // hook for a one-shot whose teardown already happened: no-op
    _playing = false;
    _playedRecently = false;
    gatePin(false);
    output.discardCurrent();
    if (!userSpeaking()) resetVad();
    onNaturalEnd();
  }

  /// Cut everything audible: the streamed reply's unplayed words, the
  /// current chunk, the preview waiter. Stop, not natural end: release
  /// any preview waiter right away.
  void stopPlayback() {
    // +270 (Tim's field: 'when I swipe back it is just completely
    // silent'): the early return on !_playing used to skip the FLUSH
    // too — a cut landing between chunks (audio done, the next block
    // queued, nothing audible this instant) stopped nothing and left
    // the whole backlog alive to speak on the tab you switched TO
    // (a drop whose name was a lie), while the pump — returning on
    // the !_playing seam check below — took the queue with it and
    // left the surviving turn's EVERY later paragraph synthesising
    // into a readerless queue: silent forever, however many times
    // you came back. Flush is the point; hearing audio is optional.
    if (!_playing && _queue.isEmpty) return; // nothing audible, nothing queued
    _playing = false;
    _playedRecently = false;
    gatePin(false);
    _queue.clear(); // streamed reply: drop everything not yet audible
    final cd = _chunkDone;
    _chunkDone = null;
    if (cd != null && !cd.isCompleted) cd.complete(); // unblock the loop
    unawaited(output.stop());
    final p = _previewDone;
    if (p != null && !p.isCompleted) p.complete();
    output.discardCurrent();
    if (!userSpeaking()) resetVad();
    onStopped();
  }

  /// Synthesise [text] in one shot and play it, waiting (bounded) for
  /// the natural end — the voice preview path. The CALLER keeps the
  /// phase (the screen's buttons must not change while it plays).
  /// [sid] auditions a different speaker style without switching to it.
  Future<Float32List?> playOnce(
    String text, {
    Duration timeout = const Duration(seconds: 120),
    int? sid,
  }) async {
    final w = worker();
    if (w == null) return null;
    final (audio, sampleRate) = await w.synthesize(text, sid: sid);
    noteTts(audio, sampleRate); // voice preview counts as TTS output too
    _previewDone = Completer<void>();
    _playing = true; // treat it like a reply for stop/barge-in bookkeeping
    _startedAt = clock();
    gatePin(true);
    _armEnd(); // the end event needs a listener BEFORE it can fire
    try {
      await output.play(audio, sampleRate, tag: 'voice_preview');
      await _previewDone!.future.timeout(timeout, onTimeout: () {});
    } finally {
      _previewDone = null;
      _playing = false;
      gatePin(false);
      output.discardCurrent();
    }
    return audio;
  }

  /// Replays exact bytes (what ASR heard / what TTS emitted) through the
  /// speaker. Capture stays open but is muted while it plays (the
  /// assistant's route policy), so nothing leaks back into the VAD. A
  /// second call while playing is the stop. The natural end (or a 90 s
  /// watchdog) settles it; [restore] lets the caller bring its status
  /// line back afterwards.
  Future<void> replayDebug(
    Float32List samples,
    int rate, {
    required String tag,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (_debugPlaying) {
      stopDebug();
      return;
    }
    _debugPlaying = true;
    stopPlayback(); // a live reply would fight the replay for the speaker
    final done = _debugDone = Completer<void>();
    _armEnd(); // same law as the preview: listen before it can end
    try {
      await output.play(samples, rate, tag: tag);
      final guard = scheduler.after(timeout, () {
        if (!done.isCompleted) done.complete(); // timeout = a cut
      });
      await done.future;
      guard.cancel();
    } finally {
      _debugPlaying = false;
      _debugDone = null;
      output.discardCurrent();
    }
  }

  void stopDebug() {
    if (!_debugPlaying) return;
    unawaited(output.stop().catchError((_) {}));
    final d = _debugDone;
    if (d != null && !d.isCompleted) d.complete();
  }

  /// Fire-and-forget route warm-up: inaudible silence through the same
  /// player. The completion lands as a no-op (nothing playing, no seam,
  /// no waiter); the first real play() simply takes over, and a dead
  /// round ends with silence no one hears. Same path each round: it
  /// just gets overwritten, no litter.
  /// +120: the route needs opening ONCE per process, and the launch call
  /// in the assistant's init does it before any press can collide with
  /// it. The field signature this kills: a fresh app start answering
  /// its first question into silence while the SECOND reply played
  /// fine — the two-second warm-up, fired on release, still owning the
  /// player when the quick local TTS handed it the real chunk; the
  /// overlap killed the chunk and the once-per-release call sites just
  /// re-armed the same race all afternoon long.
  bool _warmedUp = false;

  void warmUpRoute() {
    if (_warmedUp) return;
    _warmedUp = true;
    unawaited(() async {
      try {
        await output.play(Float32List(48000), 24000, tag: 'warmup'); // 2 s
      } catch (_) {
        _warmedUp = false; // a failed opening may be tried again later
      }
    }());
  }

  Future<void> dispose() async {
    await _endSub?.cancel();
    await output.dispose();
  }
}
