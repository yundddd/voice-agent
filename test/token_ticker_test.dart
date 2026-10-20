// The live token ticker: the rate-learning rules that turn the bridge's
// ~0.8 s relays into a counting ticker (0.1.0+76/77/84/85/93).
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/token_ticker.dart';
import 'package:voice_agent/src/bridge/bridge_event.dart';
import 'package:voice_agent/src/common/sinks.dart';

BridgeEvent tally({
  int out = 0,
  int inToks = 0,
  String kind = 'thinking',
  String thought = '',
  String draft = '',
}) => BridgeEvent.forTest(
  'tool',
  toolName: 'tokens',
  toolKind: kind,
  outTokens: out,
  inputTokens: inToks,
  thought: thought,
  draft: draft,
);

void main() {
  late FakeScheduler time;
  late TokenTicker t;
  var repaints = 0;

  setUp(() {
    time = FakeScheduler(DateTime(2026, 1, 1, 12));
    repaints = 0;
    t = TokenTicker(clock: () => time.now, repaint: () => repaints++);
  });

  group('labels (+85: words only, numbers belong to the meter)', () {
    test('kinds translate; the fallback covers the wire flight', () {
      expect(t.activityLabel('Asking the bridge…'), 'Asking the bridge…');
      t.onFrame(tally(kind: 'thinking', out: 10));
      expect(t.activityLabel('x'), 'Thinking…');
      t.onFrame(tally(kind: 'answering', out: 20, draft: 'partial'));
      expect(t.activityLabel('x'), 'Answering…');
      expect(t.draft, 'partial'); // +83: painted while answering
      t.onFrame(tally(kind: 'settled', draft: 'partial'));
      expect(t.activityLabel('x'), 'Rendering audio…');
      expect(t.settled, isTrue); // +84: the wheel must stop
      expect(
        t.draft,
        'partial',
        reason:
            '+83: settled carries the final tail — it may hold '
            'sentences whose audio has not played yet',
      );
    });
  });

  group('the learning extrapolator', () {
    test('the first frame anchors, a step-up one relay later teaches', () {
      t.onFrame(tally(out: 100));
      expect(t.tokensOut, 100);
      time.advance(const Duration(seconds: 1));
      expect(t.tokensOut, 100, reason: 'nothing learned yet — no growth');

      t.onFrame(tally(out: 200)); // +100 in 1 s: rate learned ~100/s
      expect(t.tokensOut, 200); // the relay replaces the estimate
      time.advance(const Duration(milliseconds: 500));
      final est = t.tokensOut;
      expect(est, greaterThan(200), reason: 'the eye must see movement');
      expect(est, lessThan(300), reason: '…at a believable rate');
    });

    test('a tool step freezes the counter (nothing is generating)', () {
      t.onFrame(tally(out: 100));
      t.onFrame(tally(out: 200)); // learn a rate
      t.markToolStep();
      time.advance(const Duration(seconds: 30));
      expect(t.tokensOut, 200);
      expect(t.isOn, isFalse);
    });

    test('+170: a tool step voids a settled verdict — the farewell '
        'was message truth, the step is agent truth', () {
      t.onFrame(tally(out: 12, kind: 'settled'));
      expect(t.settled, isTrue);
      t.markToolStep(); // the next message's Bash frame arrives
      expect(
        t.settled,
        isFalse,
        reason:
            'message_stop settles a MESSAGE; a tool round proves the '
            'agent is not done — the relabel must die on arrival or '
            'the box stays dark through the whole round (14:20 field)',
      );
      expect(
        t.isOn,
        isFalse,
        reason: 'the counters stay frozen; only the verdict dies',
      );
    });

    test('growth caps at 5 s of silence (a stalled stream is honest)', () {
      t.onFrame(tally(out: 100));
      t.onFrame(tally(out: 200));
      time.advance(const Duration(seconds: 30));
      expect(t.tokensOut, lessThan(200 + 800 * 5));
    });

    test('a zero relay buries the previous turn (bridge resets too)', () {
      t.onFrame(tally(out: 500));
      t.onFrame(tally(out: 0, kind: 'thinking'));
      expect(t.tokensOut, 0);
    });
  });

  group('the turn-delta in-figure (+93)', () {
    test('first figure anchors; smaller re-anchors; zero clears', () {
      t.noteInputTokens(9000);
      expect(t.tokensIn, 0);
      t.noteInputTokens(9400);
      expect(t.tokensIn, 400);
      t.noteInputTokens(1500); // /compact: re-anchor, never negative
      expect(t.tokensIn, 0);
      t.noteInputTokens(0); // fresh turn's opening zero
      t.noteInputTokens(800);
      expect(t.tokensIn, 0, reason: '800 re-anchors as the first figure');
      t.noteInputTokens(900);
      expect(t.tokensIn, 100);
    });
  });

  test('thought only shows while thinking', () {
    t.onFrame(tally(kind: 'thinking', thought: 'hmm', out: 1));
    expect(t.thought, 'hmm');
    t.onFrame(tally(kind: 'answering', out: 2, draft: 'd'));
    expect(t.thought, isEmpty);
    expect(t.draft, 'd');
  });

  test('resetForTurn kills stale digits without wiping the rate', () {
    t.onFrame(tally(out: 900));
    t.onFrame(tally(out: 1000));
    t.resetForTurn();
    expect(t.isOn, isFalse);
    t.onFrame(tally(out: 0)); // the fresh turn's opening zero
    expect(t.tokensOut, 0);
  });

  test('resetAll blanks the meter (/new)', () {
    t.onFrame(tally(out: 42, inToks: 10));
    t.resetAll();
    expect(t.tokensOut, 0);
    expect(t.tokensIn, 0);
    expect(t.isOn, isFalse);
    expect(t.settled, isFalse);
  });
}
