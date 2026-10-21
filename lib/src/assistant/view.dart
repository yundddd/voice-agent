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
    this.model,
  });
  final int tokensIn, window;
  final bool busy; // a turn is running (drives the indeterminate shimmer)

  /// +241: the model THIS session last answered with (proven by the
  /// harness's own model.selected event, +219; null before the first
  /// verdict or on a default-model harness). The bar is the one line
  /// the eye checks for context; the model belongs on the same line.
  /// +281: the projection prefers the model the seated conversation's
  /// /health NAMED (a seat answering on its created or default model
  /// was no verdict the old pick-memory ever saw — the bar showed no
  /// name), falling back to the app's remembered pick.
  final String? model;

  double get frac => window > 0 ? (tokensIn / window).clamp(0.0, 1.0) : 0;

  /// The one-line readout; 'measuring…' until a `result` names a number.
  String get label {
    final pct = frac * 100;
    // +285 (Tim, 'the percentage is cut off'): the numbers ride a
    // bare slash and the percent hangs off a single space — no dotted
    // padding around either — so the sentence ends in its percent on
    // one row instead of ellipsizing it away. (The percent sign is
    // its own delimiter; it needs no dots to be read.)
    final body = tokensIn == 0
        ? 'context · measuring…'
        : frac > 0
        ? 'context ${fmtTokenCount(tokensIn)}/${fmtTokenCount(window)} '
              '${pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1)}%'
        : 'context ${fmtTokenCount(tokensIn)} · window unknown';
    final m = model;
    return (m == null || m.isEmpty) ? body : '$m · $body';
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

/// +230: one session tab as the channel paints it — the immutable
/// shadow of the prefs' SessionTab (the view never hands out the
/// mutable store). The pill wears [label]; the tap on it names the
/// [index] back to VoiceAssistant.switchSession.
final class SessionTabInfo {
  const SessionTabInfo({
    required this.index,
    required this.harness,
    required this.label,
    required this.dir,
    required this.hue,
    this.currentId,
  });
  final int index;
  final String harness;
  final String label;
  final String dir;
  final String? currentId;

  /// +271: the session's colour (random at creation, persisted;
  /// legacy tabs carry the index-derived one). 0-359 degrees.
  final int hue;
}

/// One consistent snapshot of everything the conversation screens
/// render. Built by VoiceAssistant.view; widgets take this, not the
/// machine.
final class AssistantView {
  const AssistantView({
    this.turnHomeHere = true,
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
    required this.drainReading,
    required this.bridgeConfigured,
    required this.ttsOn,
    required this.userSpeaking,
    required this.token,
    required this.context,
    required this.latency,
    required this.ptt,
    required this.sessionId,
    this.harnessElapsed = Duration.zero,
    this.tabs = const [],
    this.tabIndex = 0,
    this.needsSetup = false,
    this.canSeat = false,
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

  /// +230: the session tabs (see [SessionTabInfo]), in creation order
  /// — the newest sits at [tabs] last, and that edge is what a
  /// right-swipe answers with the creation sheet. Empty while the
  /// first-launch questions are still owed.
  final List<SessionTabInfo> tabs;

  /// Index of the tab the channel paints (= BridgePrefs.activeTab,
  /// clamped).
  final int tabIndex;

  /// The first-launch gate: the bridge is configured, no tab exists,
  /// and no seed has run yet — the screen owes the harness/model/
  /// folder questions before any session is born.
  final bool needsSetup;

  /// /health said `seat: true` — /seat answers on this bridge, so the
  /// tab verbs (create, switch, replace) may fire. False on an older
  /// bridge: the pills go inert and /new keeps its whole-log wipe.
  final bool canSeat;

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
  ///
  /// +168 completes the honesty: an /attach claimed while /health
  /// said NO turn is open is a mail fetch ([drainReading]) — its
  /// replay surfaces history the ear already owns (the +167 flash-by:
  /// 174 ms of spin before the last reply's words surfaced, generated
  /// long before the attach). Reading mail is not churning. A rejoin
  /// of a GENERATING turn (turnOpen=true at the probe) is real work
  /// and spins.
  ///
  /// +170 named the arm the detach badge never covered and made the box
  /// follow the banner (14:20 field: the agent launched `Bash sleep 300`
  /// run_in_background and the box stayed dark for its whole 13 s run).
  /// +182 REVISES that marriage for the box alone: the field's new word
  /// is that a shell the agent backgrounded by itself — with the turn
  /// closed — means the agent is FREE to answer, and a spinning box
  /// then performs a thinking the agent is not doing. The box asks one
  /// question now: is a TURN open? Heard or streaming that is
  /// [bridgeBusy]; a turn the press detached keeps generating on the
  /// bridge, which is what the detach badge [harnessBackgrounded]
  /// marks — honest motion either way. Out-of-ear SHELL work keeps the
  /// banner (its own row, with name, age and since-clock) and the Stop
  /// brake; it no longer owns the box.
  bool get agentWorking => (bridgeBusy && !drainReading) || harnessBackgrounded;

  /// A live promise of work outside the ear's reach — the detach badge,
  /// the cut-tool promise, or the agent's own backgrounded shell.
  /// Precisely the [backgrounded] row's warrants (a queue pin is NOT
  /// one: a parked notice is an intention, and the turn it waits
  /// behind is bridgeBusy anyway). +182: this set no longer reaches the
  /// box — [agentWorking] keeps only the badge arm; the banner and the
  /// brake answer to the whole of it.
  bool get outOfEarshotWork => harnessBackgrounded || backgrounded.visible;

  /// Any bridge work in flight — heard, unheard, or owed. The Stop
  /// chip's enablement (+154): grey when nothing can be stopped, lit
  /// when something can — INCLUDING a parked drain, whose silencing
  /// the lit brake now performs (+166), a mail fetch whose replay a
  /// press may still cut, and (+182, explicit since the box stopped
  /// covering it) the agent's own backgrounded shell: a press on the
  /// brake kills that task even while the agent itself sits free.
  /// The box asks the narrower [agentWorking]; the owed reply (+164)
  /// keeps the brake honest without making the agent look busy while
  /// the phone is only talking.
  bool get agentBusy =>
      agentWorking || bridgeBusy || drainOwed || backgrounded.visible;

  /// +280 (Tim): the CONTROL ROW's owner law — the +249 doctrine,
  /// extended from the row that SPINS to the row of VERBS. Work
  /// backgrounded by a swipe is real (the gear badge still carries
  /// that cross-session sign, +230), but it is not THIS tab's: the
  /// tab that is not working must read idle and ACT idle — its slash
  /// chips pressable (they speak into its own seat) and its brake
  /// grey (a lit brake that has nothing to stop HERE is the lie the
  /// field caught: 'that agent is not even busy'). Scoped off
  /// [agentBusy]/[bridgeBusy], which stay the machine truths the
  /// queue laws, the talk-surface stop and the hints read.
  bool get stopHere => turnHomeHere && agentBusy;

  /// A live turn THIS conversation has open — the arm that holds the
  /// slash chips greyed mid-turn at home (a press there would supersede
  /// an answer in flight). Away work does not hold them: the seated
  /// tab is free to talk.
  bool get seatBusy => turnHomeHere && bridgeBusy;

  /// +168: the current view is an /attach drain (claimed while
  /// turnOpen=false) — replay only, no generating turn. Projected
  /// from VoiceAssistant._drainReading.
  final bool drainReading;

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
  /// +161's take-time bubbles). +182 narrows the settled veto to the
  /// detach badge: only a turn still GENERATING on the bridge can
  /// outvote a per-message `settled` — an agent free to answer, with
  /// just a shell churning out of earshot, sits quiet in the box while
  /// the banner row names that work. A turn's own bubble appears in
  /// the flow the moment it has something to say.
  bool get showWorkingRow =>
      turnHomeHere &&
      agentWorking &&
      spinnerVisible &&
      (!token.settled || harnessBackgrounded);

  /// +249: the row (spinner, thought, draft) belongs to the conversation
  /// it thinks for. After a mid-turn tab switch the work is backgrounded
  /// and its row travels with its thread — the seated tab shows nothing
  /// until IT has work in flight; the gear badge stays the cross-session
  /// sign of invisible labor (+230), so nothing becomes hidden-unknown,
  /// merely hidden-here. Default true: every pre-tab world, and every
  /// test that does not exercise the switch, sees the unfiltered law.
  final bool turnHomeHere;

  /// The backgrounded-work row's visibility (see [BgWork]): THE
  /// PROJECTED LAW — the badge, a queue pin, the cut-tool promise, or
  /// the agent's own backgrounded shell (+133). The screen renders
  /// this, so a fourth warrant added to the machine must land HERE,
  /// not in a duplicated rule (the port bug this law's single
  /// definition exists to prevent: agent-initiated `backgrounded`
  /// frames lit the coordinator but never the row).
  bool get showBackgroundedRow => backgrounded.visible;
}
