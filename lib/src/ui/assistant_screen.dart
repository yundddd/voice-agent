/// The main screen: conversation channel, control chips, metrics strip,
/// and the big button. It renders [VoiceAssistant] state and forwards
/// intents — the phase/hint decisions are the assistant's, the pixels
/// are this file's.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
    '/compact': Icons.compress,
  };

  final VoiceAssistant _assistant = VoiceAssistant();
  bool _debugMode = false;
  final ScrollController _scroll = ScrollController();

  /// +190: a finger DOWN on the channel outranks the follow — tracked
  /// by pointer, not by activity: DrivenScrollActivity (what animateTo
  /// drives) also reports isScrolling, so the +187 guard made the
  /// glide's own existence a reason to skip its next re-pin, every
  /// glide aimed stale, and the last died short of a tail still
  /// growing (field, twice: 'I think I see the scroll bug again').
  bool _userTouch = false;

  /// The extent as of the previous tick — what 'was at the tail' is
  /// measured against, so one frame of growth can never fool it.
  double _lastMax = -1;

  /// +196: the sticky STATE, not a per-frame geometry comparison. The
  /// +192 test (pixels ≥ LAST frame's max − 2) died quietly: any
  /// content SHRINK (a bubble settling, a caption reflow — the file
  /// slip's 'Receiving 45%' relabels itself shorter every update)
  /// clamps pixels down to the new max, and the clamp is invisible to
  /// the loop — from the next frame on, pixels sat below the old
  /// _lastMax, the view read as 'user scrolled away', the follow
  /// retired itself mid-conversation, and every arrival after filed
  /// below the fold (field: 'whenever the file transfer bubble shows
  /// up, the weird scrolling happens', tape: 'grew +N UNPINNED, pixels
  /// 23812 last 24178' forever). Stick now means: at the tail NOW
  /// (within 2 px of the CURRENT max), or still exactly where last
  /// frame's tail was while growth alone is the distance; a real
  /// scroll-away is the only thing that clears it, and returning to
  /// the bottom re-arms it.
  bool _stick = true;

  /// +200: the eased chase. +196 made stickiness a STATE, which retires
  /// the only reason +190 could not animate: its guard consulted the
  /// scrolling notifier — true for the glide's own DrivenScrollActivity
  /// — so every re-pin saw 'scroll in progress', skipped itself, and the
  /// glide aimed stale forever. The guard is _userTouch now, so a
  /// mid-glide touch or scroll-away updates the verdict at once (the
  /// hand outranks the pin, and the hand cancels the chase). Without
  /// this, every growth — a streaming section's new line, a file slip's
  /// relabel, a receipt landing — moved the whole channel up by a LINE
  /// in one teleporting jumpTo (field: 'the old segment gets pushed up
  /// as if it's getting scrolled up, and that scroll is not very
  /// smooth'). The push stays mandatory and the distance stays honest;
  /// only the step becomes a glide. The first shape of the chase WAS an
  /// animateTo re-targeted every frame, and the tape executed it: the
  /// delta froze at exactly +90, cont never moving. A driven activity
  /// counts elapsed time from its ticker's FIRST pulse, so replacing it
  /// every frame before its next pulse restarts the glide at zero
  /// progress forever — an animateTo re-targeted per tick is a glide
  /// that can never move. The chase therefore carries its own easing:
  /// each frame it jumps over a fraction of the remaining gap, sized by
  /// real elapsed time, so re-targeting is just… the next frame.
  bool _pinGliding = false;

  /// When the chase last stepped — the easing is time-sized, so a
  /// janky 25 fps frame and a smooth 60 fps one move the same
  /// distance per millisecond.
  int _lastPinUs = 0;

  /// +203/206: frame-cost forensics, now with honest instrumentation.
  /// +203 billed the chase from the scheduler's FrameTiming and it
  /// named the thief (a 71 ms build spike — the history encode), but
  /// +205's tape then went blind: 'timings lag (none delivered)'
  /// every chase, because Android delivers those batches whenever the
  /// platform thread feels like it — the one batch that did arrive
  /// carried 43 frames and landed LONG after the entrance it
  /// described. A witness that testifies minutes after the crime
  /// testifies about nothing. The bill is therefore paid from two
  /// purses: the frame PERIOD and the UI-side time (frame start to
  /// this frame's post-frame tick — every callback, build, layout,
  /// and paint dispatch lives in that span) are measured on the spot
  /// from the scheduler's own callbacks, zero batching, and they are
  /// exactly the half we can fix in our code; the GPU's raster half
  /// rides the late FrameTiming ring and is quoted whenever it
  /// happens to be present ('raster pending' means the batch, not
  /// the frames, is behind).
  final List<(int, int)> _frames = []; // (period µs, UI µs) per frame
  int _fStartUs = 0;
  int _fPeriodUs = 0;

  /// +207: a ring buffer's indices LIE to a saved mark. +206 marked
  /// the window by list index and went blind the moment the ring hit
  /// its 240-frame cap: appends from then on evict from the front,
  /// the length never grows, and the old index sits at or past the
  /// end — every window sliced to nothing (the tape: 'no frames in
  /// window' despite the ring brimming). The honest currency is a
  /// SEQUENCE NUMBER: it only ever grows, and the window's start
  /// index is the mark's distance below what has been seen.
  int _framesSeen = 0;
  int _framesMark = -1;
  final List<FrameTiming> _timings = [];
  int _timingsSeen = 0;
  int _timingsMark = -1;

  /// Persistent (every-frame, START-of-frame) callback: stamps the
  /// frame's arrival and the distance since the last one — the true
  /// period, measured where no platform batching can hide it.
  /// Persistent callbacks can never be removed (the scheduler offers
  /// no removePersistentFrameCallback), so the witness disarms itself
  /// on dispose: the callback survives, sees the flag down, and costs
  /// one branch forever.
  bool _framesAlive = true;

  void _onFrameStart(Duration _) {
    if (!_framesAlive) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    _fPeriodUs = _fStartUs == 0 ? 0 : now - _fStartUs;
    _fStartUs = now;
  }

  void _onFrameTimings(List<FrameTiming> batch) {
    _timings.addAll(batch);
    _timingsSeen += batch.length;
    if (_timings.length > 240) {
      _timings.removeRange(0, _timings.length - 240);
    }
  }

  /// +204: when the chase landed (µs), so the bill files after the
  /// dust rather than mid-glide.
  int _chaseEndUs = 0;

  /// Summarize the frames a chase rode. The period/UI halves come
  /// from the on-the-spot ring (always present by flush time); the
  /// raster half quotes whatever the late FrameTiming ring has for
  /// the window, and says 'pending' when the batch is still traveling.
  void _logChaseCost() {
    if (_framesMark < 0) return;
    final mark = _framesMark;
    _framesMark = -1;
    _chaseEndUs = 0;
    // +207: sequence maths, not list indices — the ring's oldest
    // surviving frame is (seen - length), and the window opens at
    // however far the mark sits above that.
    final start = (mark - (_framesSeen - _frames.length)).clamp(
      0,
      _frames.length,
    );
    final window = _frames.sublist(start);
    if (window.isEmpty) {
      _assistant.logFollow('fps chase: no frames in window');
      return;
    }
    final p = window.map((f) => f.$1 / 1000.0).toList()..sort();
    final u = window.map((f) => f.$2 / 1000.0).toList()..sort();
    final line = StringBuffer(
      'fps chase: n ${window.length} '
      'period ${p[p.length ~/ 2].toStringAsFixed(1)}/${p.last.toStringAsFixed(1)} '
      'ui ${u[u.length ~/ 2].toStringAsFixed(1)}/${u.last.toStringAsFixed(1)}',
    );
    final tStart = _timingsMark < 0
        ? _timings.length
        : (_timingsMark - (_timingsSeen - _timings.length)).clamp(
            0,
            _timings.length,
          );
    _timingsMark = -1;
    final tw = _timings.sublist(tStart);
    if (tw.isEmpty) {
      line.write(' raster pending');
    } else {
      final r = tw.map((t) => t.rasterDuration.inMicroseconds / 1000.0).toList()
        ..sort();
      line.write(
        ' raster ${r[r.length ~/ 2].toStringAsFixed(1)}/${r.last.toStringAsFixed(1)}',
      );
    }
    _assistant.logFollow('$line ms');
  }

  /// +192: THE STICKY BOTTOM. The follow no longer waits for chat
  /// events: every frame, if the view was resting at the tail (within
  /// 2 px of last frame's maximum) it re-pins — so ANY growth below
  /// the fold keeps the newest bubble in view, whatever its cause:
  /// entrances opening, the recording panel collapsing, a band
  /// reflowing, the keyboard stealing height. Away from the tail the
  /// reader's position is sacred: re-reading history now survives
  /// every new event, and the follow returns the moment the hand
  /// brings the view back to the bottom. +190's event window relapsed
  /// because it only knew about LOG growth; the layout itself grows
  /// too, and layout does not file events.
  void _followTick() {
    if (mounted && _scroll.hasClients) {
      final pos = _scroll.position;
      // +206: this tick IS the end of a frame — the span from the
      // persistent callback (frame start) to here is every callback,
      // build, layout, and paint dispatch this frame ran, measured
      // with no platform in the loop. And the distance between frame
      // starts is the period the eye actually got.
      if (_fStartUs != 0) {
        _frames.add((
          _fPeriodUs,
          DateTime.now().microsecondsSinceEpoch - _fStartUs,
        ));
        _framesSeen++;
        if (_frames.length > 240) {
          _frames.removeRange(0, _frames.length - 240);
        }
      }
      // +204: file a finished chase's frame bill once the scheduler's
      // late batch has had time to land.
      if (_timingsMark >= 0 &&
          _chaseEndUs != 0 &&
          DateTime.now().microsecondsSinceEpoch - _chaseEndUs > 600000) {
        _logChaseCost();
      }
      // +196 stick algebra, in the order the truth allows: resting at
      // the CURRENT tail says stick (and re-arms a reader who scrolled
      // back down); pixels still exactly on LAST frame's tail while
      // the tail moved says growth-only — stick unchanged; anything
      // else means the distance was made by a hand, and stick yields.
      final atTailNow = pos.pixels >= pos.maxScrollExtent - 2.0;
      if (atTailNow) {
        _stick = true;
      } else if (pos.pixels < _lastMax - 2.0 && !_pinGliding) {
        // +200 caveat: a chase in flight owns pixels — a content SHRINK
        // mid-glide clamps the extent down under us with no hand
        // involved, and that clamp must not retire the stick (it is
        // +196's quiet killer, re-armable only by reaching the tail).
        // The chase itself is cancelled the moment stick or touch
        // changes, so this exemption can never outlive its reason.
        _stick = false;
      }
      if (!_userTouch && _stick) {
        final delta = pos.maxScrollExtent - pos.pixels;
        if (delta > 8) {
          _assistant.logFollow(
            'pin +${delta.round()} to ${pos.maxScrollExtent.round()} '
            '(vp ${pos.viewportDimension.round()} '
            'cont ${(pos.maxScrollExtent + pos.viewportDimension).round()} '
            'n ${_assistant.chat.length})',
          );
        }
        // +200: short distances glide (an arrival's push-up reads as a
        // scroll), long ones snap (a keyboard leaving, a panel
        // collapsing — no reader wants to watch a 3000-pixel commute,
        // and the chase would look like losing control).
        if (delta > 160) {
          pos.jumpTo(pos.maxScrollExtent);
          _pinGliding = false;
          _lastPinUs = 0;
          // a snap is one frame; no window to weigh
          _timingsMark = -1;
          _framesMark = -1;
          _chaseEndUs = 0;
        } else if (delta > 0.5) {
          // Cover ~1 - e^(-dt/65ms) of the remaining gap this frame:
          // a 90 px arrival lands inside a handful of visible frames,
          // a tail that keeps opening stays a constant short hop
          // ahead, and the time base means a smooth 120 fps device and
          // a busy 25 fps one glide the same distance per
          // millisecond. Re-targeting is just the next frame — no
          // driven activity to restart at zero forever.
          final now = DateTime.now().microsecondsSinceEpoch;
          final dtMs = _lastPinUs == 0 ? 16.0 : (now - _lastPinUs) / 1000.0;
          _lastPinUs = now;
          var step = delta * (1 - exp(-dtMs / 65));
          if (step > delta) step = delta;
          if (step < 1) step = 1; // never stall the landing on tiny dt
          pos.jumpTo(pos.pixels + step);
          if (!_pinGliding) {
            // +203/206/207: mark where the window opens — by
            // sequence number, immune to the ring evicting under it.
            _timingsMark = _timingsSeen;
            _framesMark = _framesSeen;
          }
          _pinGliding = true;
        } else {
          // +204: the bill files itself when the timings arrive.
          if (_pinGliding) {
            _chaseEndUs = DateTime.now().microsecondsSinceEpoch;
          }
          _pinGliding = false; // landed (or nothing ever opened)
          _lastPinUs = 0;
        }
      } else {
        if (_pinGliding) {
          // +204: even a cancelled chase reports.
          _chaseEndUs = DateTime.now().microsecondsSinceEpoch;
          // The hand outranks the pin: a touch (or a scroll-away)
          // mid-chase stops it where it stands. The chase owns no
          // driven activity — nothing to quench, only the verdict
          // that it moves no more.
          _pinGliding = false;
          _lastPinUs = 0;
        }
      }
      if (!_stick) {
        // The crime-scene camera: growth that went UNPINNED is exactly
        // the 'new message below the fold' the field keeps seeing.
        final grew = pos.maxScrollExtent - _lastMax;
        if (grew > 8) {
          _assistant.logFollow(
            'grew +${grew.round()} UNPINNED (pixels ${pos.pixels.round()} '
            'last ${_lastMax.round()} touch=$_userTouch '
            'vp ${pos.viewportDimension.round()} '
            'cont ${(pos.maxScrollExtent + pos.viewportDimension).round()} '
            'n ${_assistant.chat.length})',
          );
        }
      }
      _lastMax = pos.maxScrollExtent;
    }
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followTick());
    }
  }

  /// +202: entry → (revision at paint, theme behind it, the exact
  /// widget instance). One view, one truth means every notification
  /// rebuilds the whole channel; +199 fenced the REPAINT, but the
  /// rebuild itself — eighty ChatBubble subtrees, a thousand widget
  /// objects per event — was the entrance's frame tax, and the tape
  /// proved the toll: follow ticks 30–40 ms apart, ~25 fps, and any
  /// glide at 25 fps is a hop. A cache hit hands back the identical
  /// widget, and Flutter does not even look inside. Live things opt
  /// out: the queue pin (a wall-clock label that ticks on its own)
  /// and the file slip (memory-only progress).
  final Map<ChatEntry, (int, ThemeData, Widget)> _bubbleCache = {};

  /// The channel's one bubble wrapper — key, fence, entrance, card —
  /// minted once per revision.
  Widget _bubbleFor(ChatEntry e, VoiceAssistant a, BuildContext context) {
    final cacheable = !e.isFile && !e.queued;
    final theme = Theme.of(context);
    if (cacheable) {
      final hit = _bubbleCache[e];
      if (hit != null && hit.$1 == e.rev && identical(hit.$2, theme)) {
        return hit.$3;
      }
    }
    final widget = Padding(
      // +197: the key LIVES HERE, on the Column's actual child. The
      // ObjectKey used to sit on the FadeInBubble one level DOWN —
      // invisible to the Column, which pairs children by POSITION:
      // the moment the 80-entry cap evicts the oldest bubble, every
      // entry shifts one slot, the position pairing hands each old
      // Padding a new entry, the inner key mismatch re-mounts every
      // State, and all eighty bubbles replay their entrance at once
      // — the collapse-and-regrow the scroll telemetry caught (n 80,
      // content −4600 and back) and the field felt as the scrolling
      // bug every send since the log filled up.
      key: ObjectKey(e),
      padding: const EdgeInsets.symmetric(vertical: 4),
      // A whole bubble opening is also a height arrival (+187): grow
      // with the same ease the segments use.
      child: RepaintBoundary(
        // +199: one fence per bubble. Every notification rebuilds the
        // whole log (one view, one truth); without the fence an
        // entrance's opacity frame repainted all eighty cards beside
        // it, and that cost — not the ease — was the lag the field
        // felt on arrivals.
        child: FadeInBubble(
          grow: true,
          child: ChatBubble(
            entry: e,
            maxWidthFrac: 0.86,
            source: () => a.view,
            onFileTap: a.fetchChatFile,
            onQueueTap: (_) => a.interruptForQueued(),
          ),
        ),
      ),
    );
    if (cacheable) {
      _bubbleCache[e] = (e.rev, theme, widget);
    } else {
      _bubbleCache.remove(e); // opt-out: never serve a stale slip or pin
    }
    return widget;
  }

  /// Cap evictions (and withdrawals) must not leave tombstones: after
  /// any rebuild, drop cached entries no longer in the log.
  void _pruneBubbleCache(List<ChatEntry> chat) {
    if (_bubbleCache.length > chat.length) {
      _bubbleCache.removeWhere((k, _) => !chat.any((x) => identical(x, k)));
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // +203: the frame-cost witness (see _logChaseCost).
    SchedulerBinding.instance
      ..addTimingsCallback(_onFrameTimings)
      ..addPersistentFrameCallback(_onFrameStart);
    // +192: the sticky-bottom follow — one loop for the life of the
    // screen, re-pinning frames, not events.
    WidgetsBinding.instance.addPostFrameCallback((_) => _followTick());
    _assistant
      ..addListener(() => setState(() {}))
      ..init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _framesAlive = false; // +206: persistent callbacks are forever; disarm
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
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

  /// The static band the status line rides: two lines of the status
  /// style at the user's font scale. The 1.45 margin is the slack
  /// between a declared line height (multiplies exactly) and the font's
  /// intrinsic metrics when the style declares none (Roboto rides
  /// ~1.17) — it is what keeps a long 'Bash …' command ellipsized
  /// INSIDE the band instead of overflowing it.
  static double _statusBand(BuildContext context) {
    final ts = Theme.of(context).textTheme.titleMedium;
    final px = MediaQuery.textScalerOf(context).scale(ts?.fontSize ?? 16);
    return px * (ts?.height ?? 1.0) * 2 * 1.45;
  }

  @override
  Widget build(BuildContext context) {
    final a = _assistant;
    // The whole screen renders from ONE snapshot (see view.dart): the
    // machine below can move mid-build, but every pixel on this frame
    // agrees with every other. Intents still go straight to the
    // assistant; state comes only through the projection.
    final v = a.view;
    _pruneBubbleCache(v.chat); // +202: evicted entries leave no tombstones
    final scheme = Theme.of(context).colorScheme;

    // +192: the auto-follow is no longer an event hook at all — the
    // sticky-bottom loop (_followTick, started in initState) answers
    // to the LAYOUT every frame, which is the only honest witness of
    // how tall the conversation has become. The old event-gated pin
    // relapsed twice for the same reason: growth that comes from
    // anywhere but the log itself (panel collapse, band reflow, the
    // keyboard) files no event, and a view pinned against yesterday's
    // extent shows the newest bubble below the fold — where the
    // animation plays for nobody. jumpTo on maxScrollExtent is always
    // in range; the tail's own presence is now what decides to follow,
    // and a scroll-up to re-read holds until the hand returns.
    //
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
          // Bottom ZERO: the talk panel sits flush with the screen's
          // bottom edge (the inner bottom SafeArea still lifts it past
          // the navigation-gesture strip, where a hold would die in
          // the system's hands).
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Listener(
                    // +190: the hand on the channel owns the
                    // viewport while it's down; the follow resumes
                    // at the next event once it lets go.
                    onPointerDown: (_) => _userTouch = true,
                    onPointerUp: (_) => _userTouch = false,
                    onPointerCancel: (_) => _userTouch = false,
                    child: SingleChildScrollView(
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
                              // The status line rides a STATIC two-line
                              // band. The wording changes HEIGHT as it
                              // changes — the idle two-liner, a bare
                              // 'Thinking…', a long 'Bash …' command
                              // (StepLine's promise of being "ellipsized
                              // by the widget", finally kept) — and under
                              // this centered column every reflow walked
                              // the whole conversation up and down: the
                              // jitter the static band kills. Two lines
                              // reserved at any font scale; more is
                              // ellipsized, never reflowed.
                              SizedBox(
                                height: _statusBand(context),
                                child: Center(
                                  child: Text(
                                    v.status,
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
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
                                  _bubbleFor(e, a, context),

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
              ),
              if (v.bridgeConfigured) ...[
                // Session housekeeping: /new and /compact (see
                // VoiceAssistant.bridgeControl for what they do on the
                // wire). Taps deliberately interrupt any voice reply
                // mid-flight (runQuickCommand supersedes), which is the
                // right feel: a chip press means "do THIS now". /compact
                // left the row at +154 because mid-turn it parked an
                // ordinary stream and died wordless; +171's seatless
                // fold made it chip-safe (the notice answers, the CLI
                // relays a live 'tool compact' line, the re-stamped
                // done closes the pump) — so +178 brought it back, BY
                // DICTATE, between /new and Stop (the list order is the
                // row order, and the Stop chip sits after them all).
                // Stop itself is PERMANENT —
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
                    // Conversation mode's label rides ABOVE the panel
                    // (the field asked the button itself to sit at the
                    // screen's bottom edge — a label under it would
                    // lift it off again; the label is gone entirely in
                    // PTT mode, the slide bands say it all).
                    if (v.mode == InteractionMode.conversation) ...[
                      Text(hint, style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                    ],
                    // The whole bottom panel IS the talk button (see
                    // talk_surface.dart): press anywhere and the hold
                    // records (same PttHold edges, same release
                    // semantics), the touch seeds an expanding ripple,
                    // mic amplitude storm-fires more waves, and the two
                    // release slides appear as WIDE bands — top edge =
                    // interrupt, right edge = discard. Conversation
                    // mode: a tap anywhere toggles, exactly as the old
                    // FAB, but without aiming. SHORTER (128 vs the old
                    // 208): the chat owns more of the screen; the press
                    // area and both edge bands stay wide enough to hit
                    // with a thumb.
                    TalkSurface(
                      height: 128,
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
                    // No trailing spacer: the panel is the last word at
                    // the bottom edge.
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
