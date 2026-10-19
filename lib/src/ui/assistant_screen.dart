/// The main screen: conversation channel, control chips, metrics strip,
/// and the big button. It renders [VoiceAssistant] state and forwards
/// intents — the phase/hint decisions are the assistant's, the pixels
/// are this file's.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';
import 'bridge_screen.dart';
import 'chat_view.dart';
import 'context_bar.dart';
import 'latency_strip.dart';
import 'talk_surface.dart';
import 'voice_screen.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen>
    with WidgetsBindingObserver {
  static const _chipIcons = {
    '/new': Icons.restart_alt, // same glyph as the settings-page reset
  };

  final VoiceAssistant _assistant = VoiceAssistant();
  bool _debugMode = false;
  final ScrollController _scroll = ScrollController();
  int _seenChatVersion = 0; // drives auto-follow while chat grows

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _assistant
      ..addListener(() => setState(() {}))
      ..init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _assistant.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Raw OS state into the journal BEFORE the folding below: the exact
    // order of these callbacks (hidden+paused on the way down, hidden
    // again on the way up) is half of what a resume bug triage is about.
    _assistant.logLifecycle(state.name);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _assistant.pauseConversation();
      case AppLifecycleState.resumed:
        unawaited(_assistant.resumeConversation());
      case AppLifecycleState.inactive:
        break; // transient (notification shade, permission prompt)
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _assistant;
    // The whole screen renders from ONE snapshot (see view.dart): the
    // machine below can move mid-build, but every pixel on this frame
    // agrees with every other. Intents still go straight to the
    // assistant; state comes only through the projection.
    final v = a.view;
    final scheme = Theme.of(context).colorScheme;

    // Auto-follow the conversation: when the log grows (new bubble or a
    // new spoken section), pin the scroll to the bottom (post-frame: the
    // new height exists only after layout). A deliberate scroll-up to
    // re-read history stops the follow until the next stream event.
    //
    // The pin is unconditional. It used to skip when the position read
    // as outOfRange — but out-of-range is precisely the case whose tail
    // it owed: the viewport shrinking under a settled bubble (keyboard
    // animating in, the status line or metrics row growing a line)
    // lowers maxScrollExtent below the current offset, leaving the
    // bottom of the newest message cut off with no further events left
    // to re-pin it, and the user scrolling by hand. jumpTo on
    // maxScrollExtent is always in range, and the chatVersion gate
    // above is what honors a scroll-up to re-read: no event, no pin.
    if (v.chatVersion != _seenChatVersion) {
      _seenChatVersion = v.chatVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }

    // +151: the working line rides NO bubble — it owns the channel's
    // bottom row (WorkingRowCard, below), so the flow shows only what
    // has been said. Empty assistant entries (a turn still thinking, a
    // parked prompt's placeholder, a drain's deduped shell) render
    // nothing at all: the row is their spinner, and the bubble
    // materialises with its first block.

    final (icon, color) = switch ((v.phase, v.userSpeaking)) {
      (AssistantPhase.error, _) => (Icons.error_outline, scheme.error),
      (AssistantPhase.listening, true) => (Icons.graphic_eq, scheme.tertiary),
      (AssistantPhase.listening, false) => (Icons.mic, scheme.error),
      (AssistantPhase.transcribing, _) => (
        Icons.psychology_alt,
        scheme.primary,
      ),
      (AssistantPhase.speaking, _) => (Icons.volume_up, scheme.primary),
      (AssistantPhase.idle, _) => (Icons.mic_none, scheme.primary),
    };

    final hint = hintFor(
      mode: v.mode,
      phase: v.phase,
      slide: v.ptt.slide,
      holdOverTurn: v.ptt.holdOverTurn,
      bridgeBusy: v.bridgeBusy,
      harnessBackgrounded: v.harnessBackgrounded,
    );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Voice Agent'),
            // The conversation's fingerprint, directly under the title: a
            // steady id across many talks is the continuity proof (the
            // bridge --resume's this one after its own restart); a change
            // means /new or a respawn moved it. The Bridge screen shows
            // the same value with its claudeUp/turn detail.
            Text(
              v.sessionId == null || v.sessionId!.isEmpty
                  ? 'no session yet'
                  : 'session ${v.sessionId}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: v.bridgeBusy ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Claude Code bridge',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => BridgeScreen(assistant: a)),
            ),
            icon: Badge(
              // Lit while a turn is heard (spinner covers it) *and* while
              // a detached turn keeps working unheard: the badge is the
              // only sign of invisible background work (plus the hint
              // text under the button).
              isLabelVisible: v.bridgeBusy || v.harnessBackgrounded,
              child: const Icon(Icons.terminal),
            ),
          ),
          IconButton(
            tooltip: 'Assistant voice',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => VoiceScreen(assistant: a)),
            ),
            icon: const Icon(Icons.record_voice_over_outlined),
          ),
          IconButton(
            tooltip: 'Debug tools',
            isSelected: _debugMode,
            onPressed: () => setState(() => _debugMode = !_debugMode),
            icon: const Icon(Icons.bug_report_outlined),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Center(
              child: SegmentedButton<InteractionMode>(
                segments: const [
                  ButtonSegment(
                    value: InteractionMode.conversation,
                    icon: Icon(Icons.forum_outlined),
                    label: Text('Conversation'),
                  ),
                  ButtonSegment(
                    value: InteractionMode.pushToTalk,
                    icon: Icon(Icons.touch_app_outlined),
                    label: Text('Push to talk'),
                  ),
                ],
                selected: {v.mode},
                onSelectionChanged: (s) => _assistant.setMode(s.first),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    controller: _scroll,
                    // Long harness answers grew the reply card without
                    // bounds until it smeared over the chips and metrics:
                    // the text block now scrolls inside this region and
                    // auto-follows the reply while it streams.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              v.status,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (v.error.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                v.error,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.error),
                              ),
                            ],
                            const SizedBox(height: 16),
                            for (final e in v.chat)
                              if (e.fromUser ||
                                          e.blocks.isNotEmpty ||
                                          // A file bubble has no text
                                          // blocks — the slip IS the
                                          // bubble.
                                          e.isFile)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: ChatBubble(
                                    entry: e,
                                    maxWidthFrac: 0.86,
                                    source: () => a.view,
                                    onFileTap: a.fetchChatFile,
                                  ),
                                ),

                            // The working row: spinner, one-line
                            // activity, meter — permanently the
                            // channel's last word while any bridge
                            // turn runs, heard or unheard (+151).
                            // +154: the slot is RESERVED always — a
                            // fixed-height band every professional
                            // chat footer owns; the row fades in and
                            // out inside it, and no bubble ever
                            // slides as the state changes.
                            SizedBox(
                              height: WorkingRowCard.reservedHeight,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 180),
                                opacity: v.showWorkingRow ? 1.0 : 0.0,
                                child: WorkingRowCard(source: () => a.view),
                              ),
                            ),

                            // A backgrounded tool call keeps a permanent
                            // line at the channel's bottom while it works
                            // unheard: the badge (detached turn) or a queue
                            // pin naming the work is its proof-of-life, and
                            // it dismisses itself the moment the turn is
                            // heard again, stopped, or proven finished.
                            if (v.showBackgroundedRow)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: BackgroundedWorkCard(
                                  source: () => a.view,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (v.bridgeConfigured) ...[
                // Session housekeeping: /new (see
                // VoiceAssistant.bridgeControl for what it does on the
                // wire). Taps deliberately interrupt any voice reply
                // mid-flight (runQuickCommand supersedes), which is the
                // right feel: a chip press means "do THIS now". +154:
                // /compact retired from the row (its slash still works
                // typed on the Bridge screen), and Stop is PERMANENT —
                // greyed while the agent is idle, lit the moment any
                // work is in flight, heard or backgrounded. A control
                // that only exists when active teaches nothing; this
                // one reads as the channel's brake at all times.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      for (final chip in VoiceAssistant.controlChips)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            avatar: Icon(_chipIcons[chip], size: 18),
                            label: Text(chip),
                            onPressed: v.bridgeBusy
                                ? null
                                : () => a.bridgeControl(chip),
                          ),
                        ),
                      ActionChip(
                        avatar: Icon(
                          Icons.stop_circle_outlined,
                          size: 18,
                          color: v.agentBusy ? null : scheme.outline,
                        ),
                        label: Text(
                          'Stop',
                          style: TextStyle(
                            color: v.agentBusy ? null : scheme.outline,
                          ),
                        ),
                        onPressed: v.agentBusy ? a.bridgeStop : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              LatencyStrip(latency: v.latency),
              if (_debugMode && (a.asrAudioSeconds > 0 || a.lastTtsSeconds > 0))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    children: [
                      if (a.asrAudioSeconds > 0)
                        TextButton.icon(
                          onPressed: a.playAsrAudio,
                          icon: Icon(
                            a.debugPlaying
                                ? Icons.stop_circle_outlined
                                : Icons.play_circle_outline,
                            size: 22,
                          ),
                          label: Text(
                            a.debugPlaying
                                ? 'Stop replay'
                                : 'Replay exactly what the ASR heard '
                                      '(${a.asrAudioSeconds.toStringAsFixed(1)}s)',
                          ),
                        ),
                      if (a.lastTtsSeconds > 0)
                        TextButton.icon(
                          onPressed: a.playTtsAudio,
                          icon: Icon(
                            a.debugPlaying
                                ? Icons.stop_circle_outlined
                                : Icons.record_voice_over_outlined,
                            size: 22,
                          ),
                          label: Text(
                            a.debugPlaying
                                ? 'Stop replay'
                                : 'Replay my last reply, raw TTS out '
                                      '(${a.lastTtsSeconds.toStringAsFixed(1)}s)',
                          ),
                        ),
                    ],
                  ),
                ),
              // Bottom-anchored block sits in a bottom SafeArea: with
              // edge-to-edge Android (targetSdk 35) the system reserves
              // the bottom edge for navigation gestures, and a HOLD
              // starting in that strip is taken by the system (a bare
              // tap is not) — which is why the old tap-to-latch button
              // seemed fine right where hold-to-talk now sits idle.
              SafeArea(
                top: false,
                bottom: true,
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    // Claude Code-style context-usage readout, right
                    // above the talk button where eyes already sit
                    // mid-turn. Fed by live `context` events (and the
                    // post-turn /health merge).
                    if (v.bridgeConfigured &&
                        (v.context.tokensIn > 0 || v.bridgeBusy))
                      ContextBar(view: v.context, busy: v.bridgeBusy),
                    // The whole bottom panel IS the talk button (see
                    // talk_surface.dart): press anywhere and the hold
                    // records (same PttHold edges, same release
                    // semantics), the touch seeds an expanding ripple,
                    // mic amplitude storm-fires more waves, and the two
                    // release slides appear as WIDE bands — top edge =
                    // interrupt, right edge = discard. Conversation
                    // mode: a tap anywhere toggles, exactly as the old
                    // FAB, but without aiming.
                    TalkSurface(
                      source: () => a.view,
                      icon: icon,
                      color: color,
                      onPointerDown: (p) => _assistant.pttDown(p),
                      onPointerMove: (p) => _assistant.pttMove(p),
                      onPointerUp: (p) => _assistant.pttUp(p),
                      onPointerCancel: () => _assistant.pttCancel(),
                      onTap: () {
                        // Press/release edges own every hold over a
                        // harness turn (tap-to-stop lives in the
                        // release path); this tap remains for the
                        // cases the hold could not open the mic —
                        // where the classic hard stop / toggle apply.
                        if (v.mode == InteractionMode.pushToTalk) {
                          if (v.bridgeBusy) a.bridgeStop();
                        } else {
                          unawaited(a.toggle());
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(hint, style: Theme.of(context).textTheme.labelLarge),
                    if (_debugMode)
                      Text(
                        'hold edges: ${_assistant.pttEdgeCount}  '
                        'pointers: ${_assistant.mode == InteractionMode.pushToTalk ? "ptt" : "conv"}',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: scheme.outline),
                      ),
                    const SizedBox(height: 8),
                    if (_debugMode && a.debugLog.isNotEmpty)
                      SelectableText(
                        a.debugLog.reversed.take(14).join('\n'),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                          fontFamily: 'monospace',
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line under the button: what pressing/releasing/holding means
/// right now. Pure so the policy is unit-guardable next to the hold
/// geometry it mirrors (the arm thresholds and the release branches in
/// PttHold must never disagree with these words).
String hintFor({
  required InteractionMode mode,
  required AssistantPhase phase,
  required PttSlide slide,
  required bool holdOverTurn,
  required bool bridgeBusy,
  required bool harnessBackgrounded,
}) => switch (mode) {
  InteractionMode.pushToTalk => switch (phase) {
    // A hold that opened over a harness turn (pttDown detached it
    // into the background — the tool call keeps working): the
    // release gesture routes the new prompt.
    AssistantPhase.listening =>
      // Past a slide threshold the hint stops teaching and confirms:
      // it names what releasing NOW does (the lit pill beside the
      // button says the same with an arrow).
      switch (slide) {
        PttSlide.up => 'Release to interrupt',
        PttSlide.right => 'Release to discard',
        PttSlide.none =>
          holdOverTurn
              ? 'Release to queue — up to interrupt — right to dismiss'
              : 'Release to send — right to dismiss',
      },
    AssistantPhase.transcribing || AssistantPhase.speaking =>
      // A press now records over the harness too: short tap = hard
      // stop, a hold queues (slide up cuts a thinking turn; over an
      // open tool a plain release STEERS the turn at its next pause —
      // +163 — and behind thinking it still just goes next).
      bridgeBusy
          ? 'Working — press and hold to steer'
          : 'Interrupt — press and talk',
    _ =>
      harnessBackgrounded
          ? 'Hold to talk — the harness keeps working unheard'
          : 'Hold to talk',
  },
  InteractionMode.conversation => switch (phase) {
    AssistantPhase.listening => 'End conversation',
    AssistantPhase.transcribing || AssistantPhase.speaking =>
      bridgeBusy ? 'Stop the harness' : 'Stop my reply',
    _ => 'Start conversation',
  },
};
