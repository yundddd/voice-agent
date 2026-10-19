library;

/// Test doubles for the assistant's four outer seams: the models
/// ([SpeechEngine]), the harness ([HarnessGateway]), the microphone
/// ([MicSource]) and the speaker ([AudioOutput]). With these four (and
/// the shared FakeScheduler from src/common) the entire
/// [VoiceAssistant] lifecycle runs in milliseconds on the VM — no
/// isolate, no socket, no device.
import 'dart:async';
import 'dart:typed_data';

import 'package:voice_agent/src/bridge/bridge_event.dart';
import 'package:voice_agent/src/bridge/gateway.dart';
import 'package:voice_agent/src/platform/mic_source.dart';
import 'package:voice_agent/src/speech/speech_engine.dart';

/// Scripted models: transcribe answers come from [transcripts] (last one
/// sticks), every synth hands back one small chunk and records the text,
/// and the speech-event callback can be rewired by the test.
class FakeSpeechEngine implements SpeechEngine {
  FakeSpeechEngine({this.transcripts = const ['repeat that']});

  List<String> transcripts;
  void Function(SpeechEvent)? onEvent;

  /// Texts given to synthesizeStream/synthesize, in order.
  final List<String> synthesized = [];
  final List<int?> synthesizedSids = [];
  final List<Float32List> vadWindows = [];
  int vadResets = 0;
  final List<bool> pins = [];

  /// Script failures: the next transcribe/synth call throws.
  Object? failNext;

  /// When set, synthesizeStream waits on this future before handing
  /// over its first chunk — a paragraph committed to the speaker with
  /// audio still unsent, the exact window the +109 ledger stamp closes.
  Future<void>? holdChunks;

  int _turn = 0;

  /// Push a pipeline event (barge-in start, endpointed segment...).
  void deliver(SpeechEvent e) => onEvent?.call(e);

  @override
  void sendAudio(Float32List samples) => vadWindows.add(samples);

  @override
  void resetVad() => vadResets++;

  @override
  void setPlaying(bool on) => pins.add(on);

  @override
  Future<int> useTts(TtsSpec spec) async => 54;

  @override
  Future<String> transcribe(Float32List samples, int sampleRate) async {
    if (failNext != null) throw failNext!;
    final t = _turn < transcripts.length
        ? transcripts[_turn]
        : transcripts.last;
    _turn++;
    return t;
  }

  @override
  int ttsNumSpeakers = 1;

  @override
  Future<Float32List> denoise(Float32List pcm) async => pcm;

  @override
  Future<(Float32List, int)> synthesize(String text, {int? sid}) =>
      synthesizeStream(text, sid: sid);

  @override
  Future<(Float32List, int)> synthesizeStream(
    String text, {
    void Function(Float32List chunk, int sampleRate)? onChunk,
    int? sid,
  }) async {
    if (failNext != null) throw failNext!;
    synthesized.add(text);
    synthesizedSids.add(sid);
    await holdChunks; // the synth-to-speaker gap the ledger must not
    // have to survive
    final chunk = Float32List(2400); // 100 ms at 24 kHz
    onChunk?.call(chunk, 24000);
    return (chunk, 24000);
  }

  @override
  void dispose() {}
}

/// Scripted harness gateway: the test pushes frames onto the view (or
/// poll pages), watches for the phone detaching, and controls /health.
class FakeHarness implements HarnessGateway {
  @override
  int Function()? journalPort;

  /// What healthInfo answers (null = unreachable).
  Map<String, Object>? healthState = {'ok': true, 'claudeUp': true};

  /// The live talk() view; frames pushed with [emit].
  StreamController<BridgeEvent>? view;
  StreamController<BridgeEvent>? attachView;

  /// True once the phone cancelled its subscription — the detach the
  /// bridge would notice as a backgrounded turn.
  bool viewDetached = false;
  bool attachDetached = false;
  int talkCount = 0;
  int talkPollCount = 0;
  int attachCount = 0;
  int stops = 0;
  int resets = 0;

  /// The interrupt flavour of the last talk()/talkPoll().
  bool lastInterrupt = true;

  /// The queue-with-backgrounding flavour of the last send.
  bool lastCutTool = false;

  /// Poll transport: pages GET /poll returns, in order (null answers
  /// stand in for an unreachable ring).
  final List<Map<String, Object>?> pollPages = [];
  int pollCount = 0;
  int lastPollSince = -1;

  /// wire v2: every talkPoll returns the next reserved turn id (echoing
  /// the bridge's {ok,turn} receipt). Tests stamp ring frames against
  /// [lastTurnId] (theirs) or [foreignTurn] (someone else's farewell).
  int lastTurnId = 400000;
  int get foreignTurn => lastTurnId - 1;
  int reserveTurn() => lastTurnId = lastTurnId + 1;

  /// wire v2: the phone's /heard acks, batch by batch — a test asserts
  /// the take was acked (and can fail the send to walk the retry path).
  final List<List<int>> heardBatches = [];
  bool heardOk = true;

  @override
  Stream<BridgeEvent> talk(
    String text, {
    bool interrupt = true,
    bool cutTool = false,
    void Function()? onActivity,
  }) {
    talkCount++;
    lastInterrupt = interrupt;
    lastCutTool = cutTool;
    turnOpenOnServer = true; // the harness holds the floor until done
    final ctl = StreamController<BridgeEvent>();
    ctl.onCancel = () => viewDetached = true;
    view = ctl;
    return ctl.stream;
  }

  @override
  Future<int> talkPoll(
    String text, {
    bool interrupt = true,
    bool cutTool = false,
  }) async {
    talkPollCount++;
    lastInterrupt = interrupt;
    lastCutTool = cutTool;
    return reserveTurn();
  }

  @override
  Future<bool> heard(List<int> mids) async {
    if (mids.isEmpty) return true;
    heardBatches.add(List.of(mids));
    return heardOk;
  }

  @override
  Future<Map<String, Object>?> poll(int since) async {
    pollCount++;
    lastPollSince = since;
    if (pollPages.isEmpty) {
      // Empty ring answer; head pinned high so no test can
      // mistake it for a young ring (the reset rewind).
      return {'ok': true, 'seq': since < 1000 ? 1000 : since, 'events': []};
    }
    return pollPages.removeAt(0);
  }

  @override
  Stream<BridgeEvent> attach({void Function()? onActivity}) {
    attachCount++;
    final ctl = StreamController<BridgeEvent>();
    ctl.onCancel = () => attachDetached = true;
    attachView = ctl;
    return ctl.stream;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> reset() async => resets++;

  @override
  Future<String?> health() async => healthState == null ? 'unreachable' : null;

  /// True while a talk()/talkPoll() turn runs and no finishView() landed:
  /// healthInfo() reports it unless the test scripts `turnOpen` itself —
  /// the phone's banner-retire rule reads this field and must not be
  /// fooled by a default snapshot into clearing a line for live work.
  bool turnOpenOnServer = false;

  @override
  Future<Map<String, Object>?> healthInfo() async {
    final h = healthState;
    if (h == null) return null;
    if (h.containsKey('turnOpen')) return h;
    return {...h, 'turnOpen': turnOpenOnServer};
  }

  @override
  Future<bool> pushJournal(Map<String, Object> envelope) async => true;

  void emit(BridgeEvent ev) {
    if (ev.isDone) turnOpenOnServer = false; // the result closed the turn
    view?.add(ev);
  }

  void emitAttach(BridgeEvent ev) {
    if (ev.isDone) turnOpenOnServer = false;
    attachView?.add(ev);
  }

  void finishView() {
    turnOpenOnServer = false;
    view?.close();
  }

  void finishAttach() => attachView?.close();

  /// A ring page carrying events with seq numbers above [since].
  static Map<String, Object> page(
    int head,
    List<BridgeEvent> evs, {
    int first = 1,
  }) {
    var seq = first;
    return {
      'ok': true,
      'seq': head,
      'events': [
        for (final e in evs)
          {
            'seq': seq++,
            'ev': e.kind,
            'data': {
              if (e.text.isNotEmpty) 'text': e.text,
              if (e.toolName.isNotEmpty) 'name': e.toolName,
              if (e.detail.isNotEmpty) 'detail': e.detail,
              if (e.toolKind.isNotEmpty) 'kind': e.toolKind,
              if (e.thought.isNotEmpty) 'thought': e.thought,
              if (e.draft.isNotEmpty) 'draft': e.draft,
              if (e.inputTokens > 0) 'in': e.inputTokens,
              if (e.outTokens > 0) 'out': e.outTokens,
              if (e.contextWindow > 0) 'window': e.contextWindow,
              if (e.wireMs > 0) '_ts': e.wireMs,
              if (e.mid > 0) '_mid': e.mid,
              if (e.turn > 0) '_turn': e.turn,
              if (e.isError) 'isError': true,
            },
          },
      ],
    };
  }
}

/// A microphone the test feeds: [emit] bytes, [kill] yanks the stream
/// (Android's habit when playback steals audio focus).
class FakeMic implements MicSource {
  bool permission = true;
  bool pcm16Supported = true;
  bool failStart = false;
  int startCount = 0;
  int stopCount = 0;

  StreamController<Uint8List>? _ctl;

  void emit(Uint8List bytes) => _ctl?.add(bytes);
  void kill() {
    final c = _ctl;
    if (c != null && !c.isClosed) c.close();
  }

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<bool> supportsPcm16() async => pcm16Supported;

  @override
  Future<Stream<Uint8List>> start() async {
    startCount++;
    if (failStart) throw Exception('mic busy');
    return (_ctl = StreamController<Uint8List>()).stream;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final c = _ctl;
    if (c != null && !c.isClosed) await c.close();
  }

  @override
  Future<void> dispose() async {}

  /// `n` frames of 16 ms: 256 PCM16 samples, ramping so RMS is well
  /// above the fake floor (the DSP is tested separately, gate_test).
  static Uint8List audio(int n) => Uint8List(n * 512 * 2);
}
