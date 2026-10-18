/// The assistant's vocabulary of states: interaction styles, the phase
/// the round trip is in, the push-to-talk slide directions, and one
/// measured bench run. Plain values — no behaviour, no timers.
library;

/// Interaction styles.
enum InteractionMode {
  /// Hands-free: the mic runs continuously; an utterance ends when the user
  /// pauses for a second; talking over the reply mutes it right away.
  conversation,

  /// Classic push-to-talk: the mic only records while the user holds the floor
  /// open with the button.
  pushToTalk,
}

enum AssistantPhase { idle, listening, transcribing, speaking, error }

/// The direction a push-to-talk hold is being SLID toward, tracked live
/// while the finger is down (see [PttHold.move]): the same thresholds
/// [PttHold.release] reads on release — `up` armed means releasing now
/// interrupts the working turn, `right` armed means releasing now
/// discards the recording — so the button can show exactly what letting
/// go right now would do.
enum PttSlide { none, up, right }

/// One measured round trip of the latency bench (voice screen panel):
/// push-to-talk in, transcript out, transcript echoed by the *current* TTS
/// engine — bridge and LLM deliberately skipped so every number belongs to
/// the models the user picked. All latencies key off the button *release*:
/// [asrMs] is release→text ready, [firstAudioMs] is release→the moment the
/// player got its first chunk (the round-trip figure worth optimising),
/// [synthTotalMs] covers the whole utterance and yields [rtf].
class BenchRun {
  final String voice;
  final double recordedSeconds;
  final String heard;
  final int asrMs;
  final int firstAudioMs;
  final int synthTotalMs;
  final double audioSeconds;
  final double rtf;
  const BenchRun({
    required this.voice,
    required this.recordedSeconds,
    required this.heard,
    required this.asrMs,
    required this.firstAudioMs,
    required this.synthTotalMs,
    required this.audioSeconds,
    required this.rtf,
  });
}
