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
import 'bridge_screen.dart' show ModelPickerSheet;
import 'chat_view.dart';
import 'session_sheet.dart';
import 'settings_screen.dart';
import 'context_bar.dart';
import 'latency_strip.dart';
import 'cone_overlay.dart';
import 'talk_surface.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, this.assistant});

  /// The machine to paint; tests inject a scripted one, production
  /// lets the screen own its own (+152's widget-test seam pattern,
  /// same as BridgeScreen's assistant parameter).
  final VoiceAssistant? assistant;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _chipIcons = {
    '/model': Icons.auto_awesome, // pops the picker; never a prompt
    '/new': Icons.restart_alt, // same glyph as the settings-page reset
    '/compact': Icons.compress,
  };

  late final VoiceAssistant _assistant = widget.assistant ?? VoiceAssistant();

  /// True when the screen built its own machine (only then does
  /// dispose() own its death; an injected assistant is its test's).
  bool get _ownsAssistant => widget.assistant == null;
  final ScrollController _scroll = ScrollController();

  /// +230: the creation sheet's one-flight guard — build re-runs on
  /// every notify, and an unanswered first-launch question must not
  /// stack copies of itself; set when the sheet opens, cleared when
  /// it leaves.
  bool _sheetUp = false;

  /// The tab strip's own last-painted index (+230): a THREAD CHANGE
  /// always opens at its newest word — unseen messages are the point
  /// of coming back — so the stick re-arms and the view lands on the
  /// tail whatever position the old thread left behind. (Within a
  /// thread the +192 law stands: the reader's scroll-away is sacred,
  /// the follow only re-pins a view already resting at the tail.)
  int _lastPaintedTab = -1;

  /// +273: the PTT press point, GLOBAL, fixed at the DOWN edge — the
  /// cone overlay's apex. Kept through the fade (a released hold
  /// shows the cones shrinking back to where they opened, not to a
  /// corner); replaced by the next press.
  Offset? _conePressGlobal;
  final GlobalKey _coneKey = GlobalKey();

  /// +230: swipe classification for the tab gestures. Tabs live on a
  /// horizontal strip in creation order; a fling LEFT walks NEWER, a
  /// fling RIGHT walks OLDER. (+268: and the strip is the whole map —
  /// past either edge there is nothing to walk to, and the swipe
  /// that used to turn "past the oldest" into the creation question
  /// is retired below.)
  ///
  /// +264 (after the third redesign Tim said it plainly: 'it looks
  /// like shit. just make it horizontal swiping'): the swipe is NOW
  /// NOTHING BUT A HORIZONTAL SLIDE. The +230 theatre (edge glow,
  /// card tilt, + fade) and the +261..+263 choreography (springs,
  /// held seams, crossfades, inherited fractions) all retired —
  /// every one had its reason, none of them looked like a swipe.
  /// What remains is ONE horizontal value with ONE animation and the
  /// simplest grammar a gesture can have:
  ///
  ///  * the finger drags the thread 1:1 (duration zero — the value IS
  ///    the gesture, painted as stated);
  ///  * a committed release keeps going the SAME WAY out (160 ms);
  ///    /seat answers behind the thread's own absence — the content
  ///    swap happens off-screen, invisible by construction, so the
  ///    async receipt has no act of its own and cannot stutter;
  ///  * the new thread is hop-swapped to the far edge (a zero-duration
  ///    move at the off-screen edge, and there is nothing to see) and
  ///    eases home (240 ms). Every leg starts from where the previous
  ///    one stood: one continuous slide in, one continuous slide out.
  ///
  /// Refusal (the seat-rest law, a dead bridge, the 1.5 s fuse on a
  /// silent one): the thread eases home from wherever it got to —
  /// the same single value, the same curve. The words ride the
  /// snackbar; the thread only ever slides.
  ///
  /// +230's tail-correction fires at the off-screen hop — the
  /// entering thread appears already resting at its newest word.
  double _dragDx = 0; // the finger's 1:1 offset while it owns the stick
  bool _dragLive = false;

  // +269 (Tim on the fast swipe: 'is there computation happening on
  // every swipe? super fast, I notice weirdness'): the painted X is
  // a VALUE NOTIFIER, not rebuild-state. The +264 shape rebuilt the
  // ENTIRE screen — every bubble, every chip, the metrics strip —
  // on every pointer event (setState), so a fast swipe starved its
  // own frames (the tape's 140 ms ui spikes were partly this), and
  // the leg animations were postFrame-scheduled rebuild deltas that
  // a second, faster swipe could interleave: old legs stomping a
  // new drag's offset, the entering-pin releasing mid-fling of the
  // NEXT swap. Now the finger writes the notifier (one AnimatedBuilder
  // repaints a lone Transform over a CACHED thread subtree — the
  // screen's build never runs during a drag), and every leg is a
  // _beginLeg under a GENERATION TOKEN: a new gesture retires the
  // old token, so a stale leg can only ever die quietly, never steer.
  final ValueNotifier<double> _paintX = ValueNotifier<double>(0);
  late final AnimationController _leg; // the leg clock (one ticker)
  int _legGen = 0; // bumped by every _beginLeg / re-grab
  double _exitDir = 1; // committed exit side: +1 right (walked OLDER)
  bool _flipArmed = false; // awaiting the receipt beyond the edge
  Timer? _flipFuse; // a silent bridge behaves as a refusing one

  /// The press point in the overlay's own coordinates (the overlay is
  /// the body-sized Stack, so this is the global point minus the
  /// body's screen offset). Null-safe by design: before the first
  /// press ever lands there is no apex, and the overlay is invisible
  /// anyway.
  Offset _coneLocal() {
    final g = _conePressGlobal;
    final box = _coneKey.currentContext?.findRenderObject();
    if (g == null || box is! RenderBox || !box.hasSize) return Offset.zero;
    return box.globalToLocal(g);
  }

  /// The thread eases home and the gesture is over: the ONLY way a
  /// swipe ends without a swap, and the way a refused one ends too.
  void _slideHome() {
    _flipFuse?.cancel();
    if (_dragLive) return; // the finger owns the stick; it decides
    setState(() => _flipArmed = false);
    _beginLeg(0, const Duration(milliseconds: 240));
  }

  /// Start (or replace) the painted slide: from WHEREVER it stands
  /// now — finger position, mid-leg, off-screen edge — to [to], over
  /// [d] (zero = land it this frame). The generation token dies with
  /// the next begin or re-grab: a leg that loses its token stops
  /// writing, mid-frame, without touching the value — which is what
  /// makes a double-fast swipe behave like one gesture at a time.
  void _beginLeg(double to, Duration d) {
    _legGen++;
    final gen = _legGen;
    _leg.stop();
    if (d == Duration.zero) {
      _paintX.value = to;
      _dragDx = to;
      return;
    }
    final anim = Tween<double>(
      begin: _paintX.value,
      end: to,
    ).animate(CurvedAnimation(parent: _leg, curve: Curves.easeOutCubic));
    anim.addListener(() {
      if (gen != _legGen) return; // superseded: die quietly
      _paintX.value = anim.value;
      _dragDx = anim.value;
    });
    _leg
      ..duration = d
      ..forward(from: 0);
  }

  /// Commit: keep sliding the way the finger was going. The receipt
  /// (the tab index actually moving — see the hand-off in build)
  /// takes the thread off-screen and brings the new one home.
  void _slideOut(VoiceAssistant a, int index) {
    setState(() {
      _dragLive = false;
      _exitDir = index >= a.view.tabIndex ? -1 : 1;
      _flipArmed = true;
    });
    _beginLeg(
      _exitDir * MediaQuery.sizeOf(context).width,
      const Duration(milliseconds: 160),
    );
    _flipFuse?.cancel();
    // An away-network /seat; silence behaves as a refusal — the
    // thread glides home and the seam of the swap is simply never
    // seen. (The snackbar's reason, if the bridge ever answers, is
    // still honest.)
    _flipFuse = Timer(const Duration(milliseconds: 1500), _slideHome);
    _tabTap(a, index);
  }

  /// +230: the session's own wash — see [AssistantScreenSupport].
  static List<Color> _sessionTint(int hue) => [
    AssistantScreenSupport.sessionTint(hue).withValues(alpha: 0.10),
    AssistantScreenSupport.sessionTint(hue).withValues(alpha: 0.02),
  ];

  /// +271: the CURRENT tab's hue from the projection (the tab list is
  /// already carried there; falling back to the legacy law keeps a
  /// no-tabs render honest).
  int _hueOf(AssistantView v) => v.tabs.isEmpty
      ? 0
      : v.tabs
            .firstWhere(
              (t) => t.index == v.tabIndex,
              orElse: () => v.tabs.first,
            )
            .hue;

  void _onTabDragUpdate(DragUpdateDetails d) {
    if (!_dragLive) {
      // Re-grab (a leg in flight, or an entering thread still off-
      // screen): one rebuild to claim the stick, and the CURRENT
      // painted value is the finger's starting point — no jump.
      setState(() {
        _dragLive = true;
        _enteringPending = false; // the thumb cancels the reveal
      });
      _legGen++; // whatever leg was running is dead
      _leg.stop();
      _dragDx = _paintX.value;
    }
    _dragDx += d.delta.dx;
    _paintX.value = _dragDx; // the ONLY cost of a frame: one
  } // notifier write, one Transform

  /// +264 (the field's second read of the new slide: 'it scrolls
  /// from top to bottom when I swipe'): the tail correction (+230)
  /// used to ride the swap's first VISIBLE frame — the +200 glide
  /// covered a few thousand pixels in eight frames and the reader
  /// watched a brand-new session do its housekeeping. Now the
  /// entering thread is pinned to its newest word while it is still
  /// OFF-SCREEN, at the hop's edge: by the time the slide-in paints,
  /// the scroll has nothing left to move. These two fields carry the
  /// duty across the hop's frames; _followTick honours them at the
  /// tail, and the slide-in leg waits on the pin (a frame's debt,
  /// not a timer's guess).
  bool _enteringPending = false;
  double _enteringPinned = -1; // extent the pin last landed on
  int _enteringSettled = 0; // consecutive ticks with an unchanging tail
  int _enteringWaits = 0; // total — a thread that never stops growing
  // reveals anyway (the follow owns it from there)

  /// A stolen gesture (the vertical scroll claimed the pointer) is
  /// not a commit: the thread was never away from home.
  void _onTabDragCancel() {
    setState(() => _dragLive = false);
    _dragDx = 0;
    _beginLeg(0, Duration.zero);
  }

  void _onTabSwipe(VoiceAssistant a, double vx) {
    final was = _dragDx;
    _dragLive = false; // the leg (if any) carries the paint now —
    // no rebuild owed: the notifier owns every pixel of this.
    // No separate fling threshold, no velocity law: past half a
    // screen of PARTED thread the neighbour is the answer the finger
    // gave; a hard flick counts as the same answer early (the
    // velocity can only speak where the position could not yet).
    // +268: a swipe only ever MOVES. For as long as the strip has
    // existed, the edge on the OLDER side was not a wall but a
    // question — past the first tab, the right-swipe opened the
    // creation sheet ('swipe right, be asked'), and on a fresh
    // install any right-swipe was that question outright. Tim's
    // verdict: the gesture that CREATES by arriving from a
    // direction nobody asked about is a trap dressed as a
    // shortcut — and the sheet can never be far to find anyway:
    // the + pill is pinned outside the scroller in the bar, the
    // boot gate opens it by itself when there is nothing to show,
    // and both were here before the gesture was. Past either edge
    // the thread now does exactly what the middle refuses when
    // half-dragged: eases home. Create is a button, not a
    // compass reading.
    final v = a.view;
    final committed = was.abs() > 160 || (vx.abs() > 600 && was != 0);
    if (!committed || v.tabs.isEmpty) {
      _slideHome(); // an unfinished drag — ease back, nothing more
      return;
    }
    final toOlder = was.sign > 0;
    final target = toOlder ? v.tabIndex - 1 : v.tabIndex + 1;
    if (target < 0 || target >= v.tabs.length) {
      _slideHome(); // THAT side is nothing: past either edge the
      return; // strip ends, and the strip is the whole law
    }
    _slideOut(a, target);
  }

  /// A pill tap: jump the seat to that tab. A refusal (mid-turn, a
  /// bridge too old, the wire down) surfaces as a one-line snackbar —
  /// the channel simply stayed where it was, which IS the truth.
  /// A pill in the bar's session strip: the harness glyph, the folder
  /// it works in (its label), and an ✕ that FORGETS the tab (and its
  /// thread — the replace law; see removeSessionTab). The pill wears
  /// the conversation's fingerprint as its tooltip — the title line
  /// the strip replaced still has a home. The active tab wears the
  /// container colour; a tap jumps (slides) there.
  Widget _sessionPill(
    BuildContext context,
    VoiceAssistant a,
    dynamic v,
    SessionTabInfo t,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final active = t.index == v.tabIndex;
    final tint = AssistantScreenSupport.sessionTint(t.hue);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message:
            '${t.harness} · ${t.dir}'
            '${t.currentId == null ? '' : '\n${t.currentId}'}',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: active
                ? scheme.secondaryContainer
                : tint.withValues(alpha: 0.10),
            border: Border.all(
              color: active ? scheme.primary : scheme.outlineVariant,
            ),
            borderRadius: const BorderRadius.all(Radius.circular(16)),
          ),
          child: InkWell(
            borderRadius: const BorderRadius.all(Radius.circular(16)),
            onTap: () => _slideOut(a, t.index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    t.harness == 'opencode' ? Icons.terminal : Icons.chat,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 130),
                    child: Text(
                      t.label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: active
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // The ✕ — forget this tab. Greyed while it is the
                  // ONLY tab holding a seat mid-move would refuse
                  // anyway; the refusal's reason comes back as the
                  // snackbar the same _tabTap law uses.
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _tabRemove(a, t.index),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.close,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _tabRemove(VoiceAssistant a, int index) {
    unawaited(() async {
      // (+264 retired the prepared slide here: a ✕ is not a swipe,
      // and the thread that loses its tab simply yields its place —
      // the neighbour's bubbles appear at rest, which is the truth.)
      final err = await a.removeSessionTab(index);
      if (err != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(err)));
      }
    }());
  }

  void _tabTap(VoiceAssistant a, int index) {
    unawaited(() async {
      final err = await a.switchSession(index);
      if (err != null && mounted) {
        _slideHome(); // +264: a refusal glides the thread home — the
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(err))); // words carry the reason
      }
    }());
  }

  /// The creation popup — the first-launch gate's own face: harness,
  /// model, folder, big buttons, and one POST that seats and files
  /// the tab (the sheet submits its own answer; the refusal reason
  /// lands inside it, next to the Start button).
  /// +243: the control row's shared compact skin — tighter internal
  /// padding and zero label padding; the label rides the default body
  /// size, the icon 18 px, the whole chip ~6 dp narrower per side than
  /// the stock ActionChip. Tap targets stay finger-honest (compact
  /// visualDensity, padded target).
  ActionChip _controlChip({
    required Widget avatar,
    required Widget label,
    VoidCallback? onPressed,
  }) => ActionChip(
    avatar: avatar,
    label: label,
    onPressed: onPressed,
    visualDensity: VisualDensity.compact,
    // +245: the law in one line — the ONLY dead space left is the
    // 3 dp the icon needs off the border; every other reclaimed point
    // went back INTO the chip (label 12→13, glyph 16→17) so the verbs
    // are as large as the width allows. Gaps between chips are 2 dp.
    padding: const EdgeInsets.only(left: 3, right: 6),
    labelPadding: EdgeInsets.zero,
    labelStyle: const TextStyle(fontSize: 13),
  );

  /// +242: the '/model' chip's verb — the settings sheet's own picker
  /// (GET /models, current checked) over the talking screen; the pick
  /// lands through setBridgeModel (POST /model + remembered per harness
  /// + the /health re-read), so the context bar's model name and the
  /// settings row update from the same receipt.
  Future<void> _pickModelTap(VoiceAssistant a) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ModelPickerSheet(assistant: a),
    );
    if (chosen == null) return;
    final err = await a.setBridgeModel(chosen);
    if (err != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not set the model: $err')));
    }
  }

  Future<void> _newSessionTap(VoiceAssistant a) async {
    if (_sheetUp) return;
    _sheetUp = true;
    await showSessionSheet(context, a: a);
    _sheetUp = false;
  }

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
      // +264: an ENTERING thread answers to the pin, not to the
      // algebra — snap its tail every frame (the glide is the very
      // thing the field read as 'scrolling from top to bottom'), and
      // the slide-in starts only once the extent has held still for
      // two ticks (or after a ten-tick cap — an endlessly-growing
      // thread reveals anyway, the follow owns it from there).
      if (_enteringPending) {
        final ext = pos.maxScrollExtent;
        if (pos.pixels != ext) pos.jumpTo(ext);
        _enteringWaits++;
        if (ext == _enteringPinned && !_userTouch) {
          _enteringSettled++;
        } else {
          _enteringSettled = 0;
        }
        _enteringPinned = ext;
        if (_enteringSettled >= 2 || _enteringWaits > 12) {
          setState(() => _enteringPending = false);
          _beginLeg(0, const Duration(milliseconds: 240));
        }
      } else if (!_userTouch && _stick) {
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
    // +269: the leg clock — bounded 0..1 progress, duration set per
    // leg, and its animation writes the paint notifier under a
    // generation token (see _beginLeg).
    _leg = AnimationController(vsync: this);
    WidgetsBinding.instance.addObserver(this);
    // +203: the frame-cost witness (see _logChaseCost).
    SchedulerBinding.instance
      ..addTimingsCallback(_onFrameTimings)
      ..addPersistentFrameCallback(_onFrameStart);
    // +192: the sticky-bottom follow — one loop for the life of the
    // screen, re-pinning frames, not events.
    WidgetsBinding.instance.addPostFrameCallback((_) => _followTick());
    _assistant.addListener(() => setState(() {}));
    // +230 seam: an injected assistant is its owner's business — the
    // test that scripted it has already booted it; only a machine
    // this screen built itself is this screen's to boot and bury.
    if (_ownsAssistant) {
      unawaited(_assistant.init());
    }
  }

  @override
  void dispose() {
    _flipFuse?.cancel();
    _leg.dispose();
    _paintX.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _framesAlive = false; // +206: persistent callbacks are forever; disarm
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _scroll.dispose();
    if (_ownsAssistant) _assistant.dispose();
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
    _pruneBubbleCache(v.chat); // +202: evicted entries leave no tombstones
    final scheme = Theme.of(context).colorScheme;
    // +230: the first-launch gate. Fresh install, configured bridge,
    // no tab yet — the question is asked BEFORE any session is
    // created, once per visit to that state (the sheet files its own
    // answer; walking away unanswered just means it asks again the
    // next time the screen wakes).
    if (v.needsSetup && !_sheetUp) {
      _sheetUp =
          true; // claimed BEFORE the frame, so no second build stacks a copy
      SchedulerBinding.instance.addPostFrameCallback((_) async {
        await showSessionSheet(context, a: a);
        if (mounted) _sheetUp = false;
      });
    }
    // +230: the tab changed (or this is the first paint of a ledger)
    // — land the channel on the NEW thread's newest word, unseen
    // messages first. jumpTo after the frame: the new thread's extent
    // is only real once it has been laid out.
    if (v.tabIndex != _lastPaintedTab) {
      // +263 HAND-OFF: a held seam means this index move is the
      // receipt we froze for. Take the motion from the finger
      // WITHOUT a rest stop — mutate the flags mid-build (this frame
      // is the swap's frame one; no setState round trip), measure
      // the held offset into a screen fraction, and let the outgoing
      // card start exactly where it was caught. The tail correction
      // below then rides this same frame, behind that card.
      if (_flipArmed) {
        // +264 HAND-OFF, second reading (Tim: 'it will scroll from
        // top to bottom'): finish the exit (80 ms), hop the absent
        // thread to the far edge (zero duration — off-screen, the
        // content swap rides the hop), and then WAIT: the reveal is
        // released by _followTick only after the fresh thread has
        // been pinned to its tail for two settled frames, so the
        // first painted row of a new session is its LAST message.
        // The scroll's housekeeping never plays in front of anyone.
        _flipArmed = false;
        _flipFuse?.cancel();
        _enteringPending = true;
        _enteringPinned = -1;
        _enteringSettled = 0;
        _enteringWaits = 0;
        // Finish whatever the exit leg has left of it (a receipt
        // that beats the slide gets 60 ms to land at the edge), THEN
        // hop to the far side — both through the leg, so a re-grab
        // between the frames kills the sequence by token, not by
        // luck of callback ordering.
        _beginLeg(
          _exitDir * MediaQuery.sizeOf(context).width,
          const Duration(milliseconds: 60),
        );
        final gen = _legGen;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!mounted || gen != _legGen) return; // superseded
          _beginLeg(
            -_exitDir * MediaQuery.sizeOf(context).width,
            Duration.zero,
          );
        });
      }
      // +266: the band rides the thread — and it rides the CACHE:
      // the tab left files its line, the destination restores its
      // own (away frames kept it current), so neither a borrowed
      // command nor a placeholder rest line ever flashes.
      a.settleBandOnLanding(_lastPaintedTab, v.tabIndex);
      _lastPaintedTab = v.tabIndex;
      _stick = true; // the follow owns the tail again, as on any tail growth
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }

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
        // +230 (field round): the SESSION STRIP lives in the bar —
        // the title and the fingerprint line retire (the Bridge screen
        // still shows the id with its full detail; each pill wears it
        // as a tooltip). The scroller takes the row's flexible middle
        // — SAME LINE as the corner buttons, which never scroll —
        // while the NEW-session + is fixed at the end of the strip:
        // the way out of an empty list must not itself be scrollable.
        titleSpacing: 12,
        centerTitle: false,
        title: Row(
          children: [
            Expanded(
              child: v.tabs.isEmpty
                  ? Text(
                      'Voice Agent',
                      style: Theme.of(context).textTheme.titleMedium,
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final t in v.tabs)
                            _sessionPill(context, a, v, t),
                        ],
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              // ALWAYS shown, outside the scroller.
              tooltip: 'New session',
              icon: const Icon(Icons.add),
              onPressed: () => _newSessionTap(a),
            ),
          ],
        ),
        actions: [
          // +230: ONE gear for both doors — voice and bridge are one
          // settings page now. The busy badge (heard turn / unheard
          // background work) moved onto it: the gear is where the
          // sign of invisible work lives.
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsScreen(assistant: a)),
            ),
            icon: Badge(
              isLabelVisible: v.bridgeBusy || v.harnessBackgrounded,
              child: const Icon(Icons.settings_outlined),
            ),
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
      body: Stack(
        children: [
          SafeArea(
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
                        // +230: a horizontal fling on the channel is the
                        // TAB gesture (the scroll view only claims the
                        // vertical half, so the horizontal drag comes
                        // here free): left = the next tab, right = the
                        // previous one. +268 retired the third answer:
                        // past the oldest tab, a right-swipe USED to open
                        // the creation sheet ("swipe right, be asked");
                        // now past either end there is simply nothing —
                        // the thread eases home, and NEW lives on the +
                        // pill, where it was already one honest tap.
                        child: GestureDetector(
                          behavior: HitTestBehavior.deferToChild,
                          onHorizontalDragUpdate: _onTabDragUpdate,
                          // A stolen gesture is still a release: the
                          // thread springs home from where it stood
                          // rather than snapping (+261).
                          onHorizontalDragCancel: _onTabDragCancel,
                          onHorizontalDragEnd: (d) =>
                              _onTabSwipe(a, d.velocity.pixelsPerSecond.dx),
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
                                    // +267: THE BANNER IS GONE. The
                                    // status line spent the whole +259/
                                    // +266 arc getting an owner, a cache
                                    // and a quieter entrance, and Tim's
                                    // verdict landed anyway: 'I want
                                    // that banner completely gone.' Fair
                                    // — every word it ever showed has a
                                    // better home now: the work says
                                    // itself in the working row (label,
                                    // meter, draft), the ear-state says
                                    // itself in the bottom hint, errors
                                    // own their red line below, and the
                                    // tape keeps the rest. The band
                                    // reserved two lines of height to
                                    // duplicate all three; the channel
                                    // just took them back. (The status
                                    // projection still exists — the
                                    // per-tab cache feeds the spinner's
                                    // label through it; it is simply no
                                    // longer PAINTED on this screen.)
                                    if (v.error.isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        v.error,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: scheme.error),
                                      ),
                                    ],
                                    const SizedBox(height: 16),
                                    // +230: the thread — +264: ONE
                                    // horizontal offset, one transform,
                                    // one animation. It rides the finger
                                    // out, swaps its conversation while
                                    // absent, and eases home; the tab's
                                    // own tint says WHERE you are, not a
                                    // glow, not a tilt, not a crossfade.
                                    AnimatedBuilder(
                                      animation: _paintX,
                                      // +269 (Tim on the fast swipe: 'is
                                      // there computation on every
                                      // swipe?'): the thread subtree is
                                      // the CACHED child — a drag frame
                                      // rebuilds the Transform wrapper
                                      // and NOTHING else (the old shape
                                      // setState'd the whole screen per
                                      // pointer event, so a fast swipe
                                      // starved its own frames). Legs
                                      // animate the same notifier under
                                      // a generation token: a second
                                      // swipe retires the first's
                                      // callbacks instead of interleaving
                                      // them — the 'weirdness' of two
                                      // animations steering one pixel.
                                      builder: (context, child) =>
                                          Transform.translate(
                                            offset: Offset(_paintX.value, 0),
                                            child: child,
                                          ),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius: const BorderRadius.all(
                                            Radius.circular(18),
                                          ),
                                          gradient: LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: _sessionTint(_hueOf(v)),
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              for (final e in v.chat)
                                                if (e.fromUser ||
                                                    e.blocks.isNotEmpty ||
                                                    // A file bubble has no text
                                                    // blocks — the slip IS the
                                                    // bubble.
                                                    e.isFile)
                                                  _bubbleFor(e, a, context),
                                            ],
                                          ),
                                        ),
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
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        opacity: v.showWorkingRow ? 1.0 : 0.0,
                                        child: WorkingRowCard(
                                          source: () => a.view,
                                        ),
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
                          // (+244: the row's own leading SizedBox is gone —
                          // the chips' left padding now IS the inset.)
                          for (final chip in VoiceAssistant.controlChips)
                            Padding(
                              // +243: chips wear a compact skin; +244
                              // tightens it again at Tim's read: four
                              // verbs must fit the width, no sideways hunt.
                              padding: const EdgeInsets.only(right: 2),
                              child: _controlChip(
                                avatar: Icon(_chipIcons[chip], size: 17),
                                label: Text(chip),
                                onPressed: v.bridgeBusy
                                    ? null
                                    // +242: the model chip pops the SAME
                                    // sheet the settings page uses — the
                                    // session's brain is a one-tap
                                    // decision on the talking screen now.
                                    : () => chip == '/model'
                                          ? _pickModelTap(a)
                                          : a.bridgeControl(chip),
                              ),
                            ),
                          _controlChip(
                            avatar: Icon(
                              Icons.stop_circle_outlined,
                              size: 17,
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
                  if (a.debugUi &&
                      (a.asrAudioSeconds > 0 || a.lastTtsSeconds > 0))
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
                          Text(
                            hint,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
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
                          onPointerDown: (p) {
                            // +273: the cone overlay fixes its apex NOW,
                            // at the press point — the compass rose is
                            // anchored where the thumb landed, not where
                            // it wanders.
                            setState(() => _conePressGlobal = p);
                            _assistant.pttDown(p);
                          },
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
                        if (a.debugUi)
                          Text(
                            'hold edges: ${_assistant.pttEdgeCount}  '
                            'pointers: ${_assistant.mode == InteractionMode.pushToTalk ? "ptt" : "conv"}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.outline),
                          ),
                        const SizedBox(height: 8),
                        if (a.debugUi && a.debugLog.isNotEmpty)
                          SelectableText(
                            a.debugLog.reversed.take(14).join('\n'),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
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
          // +273: the DECISION overlay — the gesture cones lifted to
          // the whole screen (cone_overlay.dart). It eats nothing
          // (IgnorePointer inside), so the hold keeps living in the
          // talk panel below; it is painted above everything the
          // body holds so the amber/red fans read across the entire
          // channel, not across 128 px of panel.
          Positioned.fill(
            child: ConeOverlay(
              key: _coneKey,
              visible: v.ptt.holdActive && _conePressGlobal != null,
              origin: _coneLocal(),
              guide: v.ptt,
              errorColor: scheme.error,
              idleLabelColor: scheme.onSurfaceVariant,
            ),
          ),
        ],
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

/// +230: the session's own wash — a barely-there hue per session
/// (+271: random at creation, maximally distant from its siblings,
/// so neighbours never collide), painted as a
/// top-left → bottom-right gradient behind the bubbles, worn as the
/// pill's inactive tint, and glowed from the edge mid-drag. Subtle
/// at rest, unmistakable in motion: a different session is visibly a
/// different PLACE.
class AssistantScreenSupport {
  const AssistantScreenSupport._();

  /// +271: the parameter is a HUE (the session's own, random at
  /// creation), not a tab index — deleting a neighbour used to
  /// recolour every session to its right, which is not how faces
  /// work. The legacy golden-angle law survives only as the
  /// pre-+271 fallback (SessionTab.hueOrDefault).
  static Color sessionTint(int hue) =>
      HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.55).toColor();
}
