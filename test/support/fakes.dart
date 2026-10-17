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

  /// Poll transport: pages GET /poll returns, in order (null answers
  /// stand in for an unreachable ring).
  final List<Map<String, Object>?> pollPages = [];
  int pollCount = 0;

  @override
  Stream<BridgeEvent> talk(
    String text, {
    bool interrupt = true,
    void Function()? onActivity,
  }) {
    talkCount++;
    lastInterrupt = interrupt;
    final ctl = StreamController<BridgeEvent>();
    ctl.onCancel = () => viewDetached = true;
    view = ctl;
    return ctl.stream;
  }

  @override
  Future<void> talkPoll(String text, {bool interrupt = true}) async {
    talkPollCount++;
    lastInterrupt = interrupt;
  }

  @override
  Future<Map<String, Object>?> poll(int since) async {
    pollCount++;
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

  @override
  Future<Map<String, Object>?> healthInfo() async => healthState;

  @override
  Future<bool> pushJournal(Map<String, Object> envelope) async => true;

  void emit(BridgeEvent ev) => view?.add(ev);
  void emitAttach(BridgeEvent ev) => attachView?.add(ev);
  void finishView() => view?.close();
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
