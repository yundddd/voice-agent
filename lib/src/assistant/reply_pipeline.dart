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

  // (samples, rate, start-of-audio hook, say tag): the third slot
  // carries the block's once-only onAir callback to the exact moment the
  // pump hands the chunk to the player (+121) — queued is not heard. The
  // fourth rides the say's identity (say#mid sid…) so every chunk receipt
  // names the paragraph it owes the air for — the tape can tie a chunk
  // refused by one pump and served by another's drain to its say.
  final List<(Float32List, int, void Function()?, String?)> _queue = [];
  bool _streamDone = true; // no stream in flight until startStream
  Completer<void>? _wake; // pokes the pump loop
  Completer<void>? _chunkDone; // resolves when the current chunk ends
  Completer<void>? _previewDone; // set while a preview line plays
  StreamSubscription<void>? _endSub;
  bool _playing = false;
  bool _pumpAlive = false;
  bool Function()? _pumpIsStale; // the live pump's producer test (+270)
  DateTime _startedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // The audio epoch: bumped by every door that kills audio THIS ear
  // may never hear again — stopPlayback, clearAndClose, and the
  // switch-cut's invalidatePendingAudio (which fires even with the
  // pipeline idle, the hole the in-flight block used to escape). A
  // synthesis call captures the epoch at its start and re-checks it
  // when pieces land and before any accounting: +289's _cuts clock
  // guards the PLAYER hand-off, this guards the SYNTH hand-off —
  // the same law, one seam earlier, exactly one block deep.
  int _audioEpoch = 0;
  // The in-flight streamed synthesis's cancel door (worker CPU), set
  // by speakBlock while its job is live.
  void Function()? _ttsCancel;

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
    _noteQueueDeath('a new reply begins');
    _audioEpoch++; // a successor's stream also revokes any block still
    // in the renderer from the last one (same law, fourth door)
    _ttsCancel?.call();
    _ttsCancel = null;
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
    _noteQueueDeath('turn abandoned (clearAndClose)');
    _audioEpoch++;
    _ttsCancel?.call();
    _ttsCancel = null;
    _queue.clear();
    closeStream();
  }

  /// The switch-cut's idle door (see [_cutEarOnSwitch] assistant-side):
  /// nothing plays and nothing is queued, but a block may STILL be
  /// synthesising — and its callback would hand it to the tab the
  /// reader just left. Invalidate pending audio unconditionally: the
  /// epoch bump kills its pieces at the seam, and the cancel closes
  /// the worker's CPU debt at the next piece boundary.
  void invalidatePendingAudio() {
    _audioEpoch++;
    _ttsCancel?.call();
    _ttsCancel = null;
  }

  /// +288 (Tim, 'your previous response is missing the last segment
  /// going through TTS'): the tape of a dropped tail must NAME its
  /// killer. A chunk dying unheard is permitted — the barge-in spec
  /// says the press owns the air — but the +234 count line belongs to
  /// the press path only; the other doors that empty the queue (a new
  /// stream, an abandoned turn, the pump's stale guard, a bare stop)
  /// each now speak at the cut itself.
  void _noteQueueDeath(String cause) {
    if (_queue.isNotEmpty) {
      final firstTag = _queue.first.$4;
      _log?.call(
        'reply tail dropped: ${_queue.length} unplayed chunk(s) — $cause'
        '${firstTag == null ? '' : ' (from $firstTag)'}',
      );
    }
  }

  void enqueue(
    Float32List chunk,
    int sampleRate, {
    void Function()? onStarted,
    String? tag,
  }) {
    _queue.add((chunk, sampleRate, onStarted, tag));
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
  /// [tag] is the say's identity (say#mid sid…): it rides each chunk
  /// receipt and the end receipts, so a refused-then-drained paragraph's
  /// audio is nameable on the tape.
  Future<SpeakOutcome> speakBlock(
    String text, {
    required bool Function() alive,
    required void Function(Duration sinceText) onAir,
    bool Function()? drop,
    String? tag,
  }) async {
    final w = worker();
    if (w == null) throw StateError('Models are still loading.');
    final sw = Stopwatch()..start();
    final epoch = _audioEpoch; // the block's birth certificate (see
    // _audioEpoch): any cut while it synthesises revokes its claim on
    // this ear — and hands the cancel back to the worker.
    late final void Function() myCancel;
    var onAirDone = false;
    final (audio, rate) = await w.synthesizeStream(
      text,
      onCancel: (cancel) {
        myCancel = cancel;
        if (epoch == _audioEpoch) {
          _ttsCancel = cancel;
        } else {
          cancel(); // cut mid-await of the CALLER: never even starts
        }
      },
      onChunk: (chunk, sampleRate) {
        if (epoch != _audioEpoch) return; // cut while synthesising (A)
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
            tag: tag,
          );
          return;
        }
        enqueue(chunk, sampleRate, tag: tag);
      },
    );
    sw.stop();
    if (identical(_ttsCancel, myCancel)) _ttsCancel = null; // this block's
    // CPU debt is paid; stop the cancel door from pointing at a corpse.
    if (epoch != _audioEpoch) {
      // The cut landed while this block was still in the renderer:
      // silent, uncounted, and the pump's per-block caller proceeds —
      // the answer's NEXT block rides the focus law, not this one.
      return const SpeakOutcome(onAir: false, durationSeconds: 0);
    }
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
          _noteQueueDeath('pump superseded between chunks');
          _queue.clear();
          return;
        }
        if (_queue.isEmpty) break; // stream drained and closed
        final (chunk, sampleRate, onStarted, tag) = _queue.removeAt(0);
        firstChunk = false;
        final seam = Completer<void>();
        _chunkDone = seam;
        await _playWav(chunk, sampleRate, isStale, onStarted: onStarted, tag: tag);
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
    String? tag,
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
    _chunkLog(samples, rate, tag);
    try {
      onStarted?.call(); // +121: this is the player's hand-off — the
      // block's onAir (ledger stamp, speaking phase, latency number)
      // rides this instant, the last one before the speaker owns it
      onAudible?.call(); // the honest release→ear clock starts at the
      // player's hand-off, not the queue write
      await output.play(samples, rate);
      if (!_playing) {
        // +289 belt: the cut landed INSIDE the play hand-off. The
        // output layer is the first net (a chunk that encoded
        // through its own cut never starts); this is the second, for
        // any backend whose player took the source past the stop.
        // A chunk that started after the ear let go must not talk
        // its full length over the tab the user switched to.
        unawaited(output.stop());
      }
    } catch (e) {
      _playing = false;
      _playedRecently = false;
      gatePin(false);
      output.discardCurrent();
      rethrow;
    }
  }

  bool _playedRecently = false; // chunk-to-chunk carry-over (see above)

  void _chunkLog(Float32List samples, int rate, String? tag) {
    // +290: stamp the receipt's inputs at the hand-off — the seconds
    // this chunk owes the air, and the instant it asked for them.
    _handoffAt = clock();
    _handedSeconds = samples.length / rate;
    _handedTag = tag;
    _log?.call(
      'chunk play ${(samples.length / rate).toStringAsFixed(1)}s'
      '${_queue.isEmpty ? ' (last)' : ' +${_queue.length}'}'
      '${tag == null ? '' : ' $tag'}',
    );
  }

  // +290 (the chunk-end witness): every chunk HANDED to the player
  // owes a receipt at whichever door resolves it — the player's own
  // end event ('chunk ended naturally') or a stop ('chunk ended
  // cut'). Bookkeeping until now stopped at the hand-off, and the
  // platform's door is where a silent start can hide: a play line
  // with no receipt under it while later lines flow is exactly that
  // animal, visible on the tape instead of argued from ears.
  DateTime? _handoffAt;
  double _handedSeconds = 0;
  String? _handedTag;

  String _receipt() {
    final st = _handoffAt;
    final ran = st == null
        ? 0.0
        : clock().difference(st).inMilliseconds / 1000.0;
    return 'ran ${ran.toStringAsFixed(1)}s of '
        '${_handedSeconds.toStringAsFixed(1)}s handed'
        '${_handedTag == null ? '' : ' $_handedTag'}';
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
      // +290 (the chunk-end witness): a chunk HANDED is not a chunk
      // HEARD — the play line and the seam note are bookkeeping about
      // the hand-off, and the ear's complaint lived exactly there
      // ('that chunk didn't go through TTS for sure'). The player's
      // own end event is the only receipt the platform signs; this
      // line is where it lands on the tape.
      _log?.call('chunk ended naturally: ${_receipt()}');
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
    if (!_playing && _queue.isEmpty && _ttsCancel == null) {
      return; // nothing audible, nothing queued, nothing synthesising
    }
    _audioEpoch++; // +A: even the doors that carry no queue kill the
    // in-flight block's claim on the ear (and on the worker's CPU).
    _ttsCancel?.call();
    _ttsCancel = null;
    _playing = false;
    _playedRecently = false;
    gatePin(false);
    _noteQueueDeath('stopPlayback'); // +288: the press path counts its
    // drop at the decision (+234); this names it at the cut.
    _queue.clear(); // streamed reply: drop everything not yet audible
    final cd = _chunkDone;
    _chunkDone = null;
    if (cd != null && !cd.isCompleted) {
      // +290: the other receipt door. A chunk whose seconds were cut
      // short says so — and a hand-off with NEITHER receipt line
      // under it, while later lines flow, is the silent start named
      // by its silence.
      _log?.call('chunk ended cut: ${_receipt()}');
      cd.complete(); // unblock the loop
    }
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
  /// +317: this silence is also where the output's lane is declared
  /// (file_player_output.dart): the launch warm-up is the ONE play that
  /// is guaranteed to run before any mic session, so the play that eats
  /// the platform's route negotiation is guaranteed to be inaudible —
  /// the output twin of the mic's warm-up drop. Keep it at launch.
  bool _warmedUp = false;

  /// +319 (Tim's field tape: the FIRST reply after a launch — thin
  /// phone-line chunks, then the same reply full: the headset's phone
  /// line outlives the mic by a few seconds and the first reply starts
  /// ON it, mid-sentence, when the line finally lets go): the moment
  /// capture is truly closed, leave call mode and lay ~0.4 s of
  /// silence through the same player, so the line's release happens
  /// against nothing instead of against the first word. No-ops while a
  /// reply is on air or still queued — the mode-switch case lets the
  /// narrated answer survive the mic closing, and that release can
  /// wait for a quieter turn.
  void holdOutputRoute() {
    if (_playing || _queue.isNotEmpty) return;
    unawaited(() async {
      try {
        await output.releaseCallRoute();
        await output.play(Float32List(9600), 24000, tag: 'hold'); // 0.4 s
      } catch (_) {}
    }());
  }

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
