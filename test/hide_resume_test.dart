// Unit guards for the background → foreground dance (hide_resume.dart).
// The orchestrator-level equivalents live in turn_flow_test.dart; these
// pin the TRANSITIONS themselves — the five fields used to be mutated
// loose on the assistant and every bug in their comments (the double
// pause on the way up, the amnesia replay, the half-heard paragraph)
// was an interaction between two of them.
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_agent/src/assistant/activity.dart';
import 'package:voice_agent/src/assistant/hide_resume.dart';
import 'package:voice_agent/src/assistant/state.dart';

void main() {
  late HideResume h;
  const working = StepLine('Bash', 'flutter test');

  setUp(() => h = HideResume());

  group('the double-hide guard', () {
    test('the SECOND hidden (the one on the way up) changes nothing', () {
      final first = h.hide(
        bridgeLive: true,
        conversationLive: false,
        phase: AssistantPhase.transcribing,
        status: working,
      );
      expect(first.applied, isTrue);
      final second = h.hide(
        bridgeLive: true,
        conversationLive: false,
        phase: AssistantPhase.idle,
        status: const PausedNotice(bridgeLive: true, wasLive: false),
      );
      expect(
        second.applied,
        isFalse,
        reason:
            'a second pass would snapshot the "when you\'re back" '
            'notice itself as the working line — the spinner quoting '
            'the pause notice while we ARE back',
      );
    });

    test('the snapshotted working line is the LIVE step, not the notice', () {
      h.hide(
        bridgeLive: true,
        conversationLive: true,
        phase: AssistantPhase.transcribing,
        status: working,
      );
      final plan = h.resume();
      expect(plan.workingLine, same(working));
      expect(plan.relisten, isTrue);
    });
  });

  group('the cut-paragraph rule (skip, don\'t replay)', () {
    test('a paragraph audible at hide time is marked for silence, not '
        'buffered for replay', () {
      h.noteReplyText('Half-heard paragraph.');
      final r = h.hide(
        bridgeLive: true,
        conversationLive: false,
        phase: AssistantPhase.speaking,
        status: working,
      );
      expect(r.droppedMidPlay, isTrue);
      expect(h.shouldDrop('Half-heard paragraph.'), isTrue);
      final plan = h.resume();
      expect(
        plan.unheardReply,
        isNull,
        reason: 'replaying the half-heard paragraph reads as amnesia',
      );
      expect(
        h.shouldDrop('Half-heard paragraph.'),
        isTrue,
        reason:
            'the mark SURVIVES resume: chunks still synthesising '
            'for the cut paragraph must keep dying on the floor',
      );
    });

    test('a block becoming AUDIBLE outranks any pending drop mark', () {
      h.noteReplyText('Cut one.');
      h.hide(
        bridgeLive: true,
        conversationLive: false,
        phase: AssistantPhase.speaking,
        status: working,
      );
      h.blockAired(); // the NEXT paragraph aired — the mark is history
      expect(h.shouldDrop('Cut one.'), isFalse);
    });

    test('a fresh turn buries the mark', () {
      h.noteReplyText('Cut one.');
      h.hide(
        bridgeLive: true,
        conversationLive: false,
        phase: AssistantPhase.speaking,
        status: working,
      );
      h.buryDropMark();
      expect(h.shouldDrop('Cut one.'), isFalse);
    });

    test('nothing is cut when no reply was audible', () {
      final r = h.hide(
        bridgeLive: true,
        conversationLive: false,
        phase: AssistantPhase.transcribing,
        status: working,
      );
      expect(r.droppedMidPlay, isFalse);
      expect(h.shouldDrop('Half-heard paragraph.'), isFalse);
    });
  });

  group('the resume promise', () {
    test('only says that landed UNHEARD while hidden earn a voice — the '
        'MOST RECENT one', () {
      h.hide(
        bridgeLive: true,
        conversationLive: false,
        phase: AssistantPhase.transcribing,
        status: working,
      );
      h.noteUnheardSay('First while away.');
      h.noteUnheardSay('The answer.');
      final plan = h.resume();
      expect(plan.unheardReply, 'The answer.');
      expect(
        h.resume().unheardReply,
        isNull,
        reason: 'the promise is consumed exactly once',
      );
    });

    test('a hide with no bridge turn takes no snapshot and promises '
        'nothing', () {
      h.hide(
        bridgeLive: false,
        conversationLive: true,
        phase: AssistantPhase.speaking,
        status: working,
      );
      final plan = h.resume();
      expect(plan.workingLine, isNull);
      expect(plan.unheardReply, isNull);
      expect(
        plan.relisten,
        isTrue,
        reason:
            'the plain conversation still comes back exactly as '
            'the user left it',
      );
    });

    test('hidden until resume, relisten cleared by a mode switch', () {
      expect(h.hidden, isFalse);
      h.hide(
        bridgeLive: false,
        conversationLive: true,
        phase: AssistantPhase.listening,
        status: working,
      );
      expect(h.hidden, isTrue);
      h.resetRelisten();
      expect(
        h.resume().relisten,
        isFalse,
        reason: 'a mode switch rewires the input side from scratch',
      );
      expect(h.hidden, isFalse);
    });
  });
}
