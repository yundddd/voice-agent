/// The conversation screen as ONE immutable value.
///
/// The widgets used to pull a dozen getters off the live
/// [VoiceAssistant] mid-build, so "what this screen should show" existed
/// only during a render pass against a running app — verifying a UI
/// change meant running the phone. [AssistantView] is the projection:
/// every field the conversation screens render, computed in one place
/// from the core state, snapshotted per repaint. Widgets take the view
/// (or a `source` callback that re-projects on their own tick) and paint;
/// intent methods stay on the assistant. A behavior change is now visible
/// as a view difference in a VM test, and a widget change is testable
/// against a hand-built view with no assistant, no fakes, no device.
library;

import 'dart:ui' show Offset;

import '../bridge/text_rules.dart';
import '../chat/chat_log.dart';
import 'activity.dart';
import 'state.dart';

/// Re-projects the live view — the spinner's and the background line's
/// ticks read fresh state on their own cadence, which is the one thing
/// a snapshot cannot do for them.
typedef ViewSource = AssistantView Function();

/// The polite-queue pin card: a press parked behind live work, wearing
/// its send-time stamp because the pin's age IS the queue-delay symptom.
final class QueuedPin {
  const QueuedPin({required this.text, required this.createdMs});
  final String text;
  final int createdMs;
}

/// The persistent bottom row for UNHEARD work — the badge (a detached
/// turn), the cut-tool promise, or the agent's own backgrounded shell.
/// A queue pin is NOT a warrant (+145): parked-behind-and-hearing is a
/// wait the pin card and spinner tell, not a background. [visible] is
/// the whole dismissal policy, precomputed from those three proofs,
/// and every completion path clears them — so an absent row is never
/// a bug the screen has to explain.
final class BgWork {
  const BgWork({
    required this.visible,
    required this.label,
    required this.sinceMs,
    required this.elapsed,
  });
  static const hidden = BgWork(
    visible: false,
    label: '',
    sinceMs: 0,
    elapsed: Duration.zero,
  );
  final bool visible;

  /// The newest real tool step the work attested to ('' = name it
  /// generically on screen).
  final String label;
  final int sinceMs;
  final Duration elapsed;
}

/// The live tally the spinner paints between bridge relays.
final class TokenMeter {
  const TokenMeter({
    required this.on,
    required this.out,
    required this.inTok,
    required this.thought,
    required this.draft,
    required this.settled,
    required this.activityLabel,
  });
  final bool on;
  final int out, inTok;
  final String thought, draft;

  /// The bridge says the text is final — the wheel must stop (+84).
  final bool settled;

  /// What the harness is doing, words only (numbers belong to [meter]).
  final String activityLabel;

  /// '12.4k out · 21.0k in · 34s' — the meter line, formatted at the
  /// projection edge so the widget only paints it.
  String meter(int seconds) =>
      '${(out > 0 || inTok > 0) ? '${fmtTokenCount(out)} out · ${fmtTokenCount(inTok)} in · ' : ''}$seconds'
      's';
}

/// The context-usage bar above the talk button.
final class ContextBarView {
  const ContextBarView({
    required this.tokensIn,
    required this.window,
    required this.busy,
  });
  final int tokensIn, window;
  final bool busy; // a turn is running (drives the indeterminate shimmer)

  double get frac => window > 0 ? (tokensIn / window).clamp(0.0, 1.0) : 0;

  /// The one-line readout; 'measuring…' until a `result` names a number.
  String get label {
    final pct = frac * 100;
    return tokensIn == 0
        ? 'context · measuring…'
        : frac > 0
        ? 'context ${fmtTokenCount(tokensIn)} / ${fmtTokenCount(window)} '
              '· ${pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1)}%'
        : 'context ${fmtTokenCount(tokensIn)} · window unknown';
  }

  /// null = the indeterminate shimmer (window unknown but the harness
  /// is working); otherwise the fraction to paint.
  double? get fill => frac > 0 ? frac : (busy ? null : 0);
}

/// The round-trip metrics strip.
final class LatencyView {
  const LatencyView({
    required this.recordSeconds,
    required this.asrSeconds,
    required this.ttsSeconds,
    required this.playSeconds,
    required this.hopAsr,
    required this.hopSent,
    required this.hopReply,
    required this.hopTts,
  });
  final double recordSeconds, asrSeconds, ttsSeconds, playSeconds;
  final bool hopAsr, hopSent, hopReply, hopTts;
}

/// The hold-guide state the talk surface mirrors (never independently
/// derived: the same PttHold classifies the release, so the picture is
/// exactly "what letting go now would do"; micLevel is the same law for
/// the ripples — straight from the capture meter, never a guess).
final class PttGuide {
  const PttGuide({
    required this.holdActive,
    required this.slide,
    required this.drag,
    required this.holdOverTurn,
    this.micLevel = 0,
  });
  final bool holdActive, holdOverTurn;
  final PttSlide slide;
  final Offset drag;

  /// Recent mic energy, 0..1 (fast attack, slow decay) — drives the
  /// talk surface's ripple spawn rate and size while a hold is down.
  final double micLevel;
}

/// One consistent snapshot of everything the conversation screens
/// render. Built by VoiceAssistant.view; widgets take this, not the
/// machine.
final class AssistantView {
  const AssistantView({
    required this.phase,
    required this.mode,
    required this.activity,
    required this.error,
    required this.chat,
    required this.chatVersion,
    required this.queued,
    required this.backgrounded,
    required this.bridgeBusy,
    required this.harnessBackgrounded,
    required this.drainOwed,
    required this.bridgeConfigured,
    required this.ttsOn,
    required this.userSpeaking,
    required this.token,
    required this.context,
    required this.latency,
    required this.ptt,
    required this.sessionId,
    this.harnessElapsed = Duration.zero,
  });

  final AssistantPhase phase;
  final InteractionMode mode;
  final Activity activity;
  final String error;
  final List<ChatEntry> chat;
  final int chatVersion;
  final QueuedPin? queued;
  final BgWork backgrounded;
  final bool bridgeBusy, harnessBackgrounded, bridgeConfigured, userSpeaking;

  /// The TTS kill switch (BridgePrefs.tts). +153 retired the composer
  /// bar and with it the volume icon — the flag persists; the field
  /// keeps projecting it so any later mute affordance reads the truth.
  final bool ttsOn;
  final TokenMeter token;
  final ContextBarView context;
  final LatencyView latency;
  final PttGuide ptt;
  final String? sessionId;

  /// How long the in-flight (or badge-kept) bridge turn has been
  /// working — zero when idle; the spinner's and background row's clock.
  final Duration harnessElapsed;

  /// The status line, rendered from [activity] — the single place
  /// activity becomes prose.
  String get status => activity.text(mode: mode);

  /// The spinner's visibility law (moved out of the widget): pure
  /// playback IS the status — while the app is only speaking with no
  /// open bridge turn, the wheel hides; anything working keeps it live
  /// even through its own voice. +151 reads the turn flags directly:
  /// the elapsed-clock proxy went wrong at re-anchors (a pickup
  /// re-anchors the age, and for a tick the wheel went dark on work
  /// that was verifiably still open). +167: the law reads
  /// [agentWorking], not [agentBusy] — a parked drain (+124/+164) is
  /// phone-side audio bookkeeping, and the wheel must not turn for
  /// the speaker.
  bool get spinnerVisible =>
      !(phase == AssistantPhase.speaking && !agentWorking);

  /// The agent itself is churning — a heard turn open on the wire, or
  /// a detached one working out of earshot. +167 names it for the ONE
  /// claim the box is allowed to make: user dictate 'the spinning box
  /// is exclusively to show agent status. TTS is independent of it.'
  /// The field counter-example to +164's optimism: after a slide-up
  /// cut's done clean, missed=2 parked the drain while the phone was
  /// merely finishing the sentence it was reading — the box spun
  /// through it and there was in truth no next message coming. When a
  /// follow-on turn IS coming (the fold), its own ATTACH lights the
  /// box for real — bridgeBusy is the honest signal, a parked drain
  /// never was.
  bool get agentWorking => bridgeBusy || harnessBackgrounded;

  /// Any bridge work in flight — heard, unheard, or owed. The Stop
  /// chip's enablement (+154): grey when nothing can be stopped, lit
  /// when something can — INCLUDING a parked drain, whose silencing
  /// the lit brake now performs (+166). The box itself asks the
  /// narrower [agentWorking]; the owed reply (+164) keeps the brake
  /// honest without making the agent look busy while the phone is
  /// only talking.
  bool get agentBusy => agentWorking || drainOwed;

  /// +164: a parked drain verdict — the wire owes this phone a reply
  /// it has taken but not yet heard, waiting for the speaker to fall
  /// silent (+124's no-interruptions rule). Projected straight from
  /// VoiceAssistant._drainAfterSpeech.
  final bool drainOwed;

  /// +151: THE WORKING ROW — the spinner, its one-line activity and the
  /// meter — sits at the bottom of the channel, attached to NO bubble.
  /// It shows while a bridge turn is heard OR a detached one keeps
  /// working (the +72/+91 honesty, now structural: no press, pin,
  /// placeholder or drain shell can move it, because it has no place
  /// to move to). +167 tightens it to the agent alone:
  /// [agentWorking] gates the row, pure playback hides it
  /// ([spinnerVisible]), and a settled turn — text final, only the
  /// phone's TTS pipeline remaining — hides it too (the +165 retire-
  /// ment of 'Rendering audio…', the +83 draft preview superseded by
  /// +161's take-time bubbles). A turn's own bubble appears in the
  /// flow the moment it has something to say.
  bool get showWorkingRow =>
      agentWorking && spinnerVisible && !token.settled;

  /// The backgrounded-work row's visibility (see [BgWork]): THE
  /// PROJECTED LAW — the badge, a queue pin, the cut-tool promise, or
  /// the agent's own backgrounded shell (+133). The screen renders
  /// this, so a fourth warrant added to the machine must land HERE,
  /// not in a duplicated rule (the port bug this law's single
  /// definition exists to prevent: agent-initiated `backgrounded`
  /// frames lit the coordinator but never the row).
  bool get showBackgroundedRow => backgrounded.visible;
}
