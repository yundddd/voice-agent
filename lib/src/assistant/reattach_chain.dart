/// The reattach retry chain as a state unit.
///
/// A bridge turn the phone lost (view died while hidden, process
/// killed, zombie route hopped off) is the bridge's problem to finish
/// and OUR problem to rejoin. The chain used to be five loose fields on
/// the orchestrator (`_reattachGen/Seq/Step/Retire/Timer`) driven from
/// six call sites — the same shape that produced the +52 orphan stomp
/// (a zero-delay probe idling the UI under a finger that was DOWN) and
/// the request-loop risk on a flaky link. Here the ladder is one class:
/// `start` (arm with a verdict), `cancel` (a new utterance's ear won),
/// and the pump — probe /health, reattach or climb, retire honestly.
///
/// Phones wake their NETWORK late; one failed probe must never drop a
/// live turn, so an unreachable bridge retries the [kReattachDelays]
/// ladder (~63 s of grace) and a spent ladder retires the orphan — the
/// spinner stops claiming it is still streaming.
library;

import 'dart:async';

import '../bridge/text_rules.dart';
import '../bridge/wire_lease.dart';
import '../common/sinks.dart';
import 'activity.dart';

/// The assistant-side surface the chain drives (function tear-offs; the
/// assistant owns the gateway, the worker, the badge and the mic).
final class ReattachEnv {
  const ReattachEnv({
    required this.canProbe,
    required this.busy,
    required this.generation,
    required this.turnSeq,
    required this.pointersDown,
    required this.probe,
    required this.noteHealth,
    required this.reattach,
    required this.retireWork,
    required this.idleReady,
    required this.setStatus,
    required this.log,
    required this.repaint,
  });

  /// A gateway and a worker exist to reattach with.
  final bool Function() canProbe;

  /// A heard turn owns the slot right now (a resume or a chip attached
  /// while we probed): the chain bows out, that turn's own watchdog
  /// takes over.
  final bool Function() busy;
  final int Function() generation;
  final int Function() turnSeq;

  /// A finger is DOWN on the PTT button: its hold owns the phase, and
  /// idling under it throws the recording away (the +52 field bug).
  final bool Function() pointersDown;

  /// GET /health (null = unreachable).
  final Future<Map<String, Object>?> Function() probe;

  /// Fold the snapshot into the transport (skew, poll capability) and
  /// render the verdict line — the exact fields the decision turns on,
  /// so desktop triage reads WHY the app chose attach/idle/retry.
  final String Function(Map<String, Object>?) noteHealth;

  /// Steal a fresh heard view of the turn ([health] carries the probe
  /// already in hand). True = heard again.
  final Future<bool> Function(Map<String, Object> health) reattach;

  /// Badge out, clock stopped, snapshot blanked.
  final void Function() retireWork;
  final void Function() idleReady;
  final void Function(Activity a) setStatus;
  final void Function(String line) log;
  final void Function() repaint;
}

final class ReattachChain {
  ReattachChain({required this.scheduler, required this.env});

  final Scheduler scheduler;
  final ReattachEnv env;

  int _gen = -1, _seq = -1, _step = 0;
  bool _retire = false; // chain end = retire the spinner (zombie hop failed)
  Timer? _timer; // next probe of the retry chain
  // +148: cancel()/start() must veto a pump already sitting on its
  // /health await, not just the next timer rung — a PTT queue release
  // cancels the press's deferred steal-back, and the release's own
  // /talk becomes the successor view. Without the epoch the in-flight
  // probe resolved over that decision, painted 'Reattached — working…'
  // over the running tool's spinner box, and its bubble was withdrawn
  // a beat later by the supersede — a caption about a view that never
  // was, left on the box the queue is required to leave untouched.
  int _epoch = 0;

  /// Ladder rungs spent on the current orphan (journal flag).
  int get step => _step;
  bool get armed => _timer != null;

  /// A bridge turn wants hearing but our view of it died: probe
  /// /health NOW and climb the ladder from there. [retire] marks a
  /// chain born from a ZOMBIE stream: a definite "nothing open, nothing
  /// unheard" verdict (or a spent ladder) must also retire the spinner
  /// the dead view was still pretending to watch — the flag ORs in, so
  /// a chain re-armed by a quieter path keeps an earlier zombie's
  /// retirement duty. [firstProbe] delays the first probe — the pace a
  /// REATTACHED stream dying again pays between attach attempts, so a
  /// flaky link never request-loops at RTT speed.
  void start({
    required int gen,
    required int seq,
    bool retire = false,
    bool resetStep = true,
    Duration? firstProbe,
  }) {
    if (!env.canProbe()) return;
    _epoch++; // a re-arm supersedes any pump still mid-probe (+148)
    if (resetStep) _step = 0;
    _gen = gen;
    _seq = seq;
    _retire = retire || _retire;
    _timer?.cancel();
    _timer = null;
    if (firstProbe != null) {
      _timer = scheduler.after(firstProbe, _pump);
      return;
    }
    unawaited(_pump());
  }

  /// This superseded story is not to be re-heared (a new prompt owns
  /// the ear now).
  void cancel() {
    _epoch++; // veto the pump parked on its probe await (+148)
    _timer?.cancel();
    _timer = null;
    _step = 0;
    _retire = false;
  }

  Future<void> _pump() async {
    _timer = null;
    if (!env.canProbe() || env.busy()) return;
    final myEpoch = _epoch;
    final probe = await env.probe();
    if (_epoch != myEpoch) return; // cancelled or re-armed while probing
    if (env.busy()) return; // a resume or a chip attached while we probed
    final need = bridgeReattachNeeded(probe);
    final verdict = need == null
        ? 'UNREACHABLE (network may still be waking), will retry'
        : need
        ? 'ATTACH'
        : 'nothing open, nothing unheard: go idle';
    env.log(
      'reattach probe ${_step + 1}/${kReattachDelays.length + 1}: '
      '${env.noteHealth(probe)} → $verdict',
    );
    if (need == false) {
      _retireOrphan(); // definite verdict: nothing left to hear
      return;
    }
    if (need == true) {
      if (await env.reattach(probe!)) {
        _retire = false;
        _step = 0;
        return; // heard again — its own watchdog and teardown take over
      }
      // Hidden, bench in the way, or the attach raced a teardown: the
      // next rung tries again (and the resume path probes for itself,
      // so a backgrounded chain may simply end here — foregrounding
      // restarts the whole recovery).
    }
    final next = reattachDelay(_step++);
    if (next == null) {
      _retireOrphan(); // ladder spent; the network never came up
      return;
    }
    _timer = scheduler.after(next, _pump);
  }

  /// End a chain that heard nothing, and — for a chain born from a
  /// zombie stream — retire the spinner that was quoting a dead view.
  void _retireOrphan() {
    _timer = null;
    final retire = _retire;
    _retire = false;
    if (!retire || env.busy()) return;
    if (_gen != env.generation() || _seq != env.turnSeq()) return;
    if (env.pointersDown()) {
      // A finger is DOWN right now (the press that detached this very
      // turn): its hold owns the phase, and the mic is already open
      // beneath this chain. Retiring the badge is honest; idling is not
      // — the field bug: the idle-stomp races the mic open and the
      // release lands on 'not listening' with the recording thrown away.
      env.retireWork(); // retired work is not background work any more
      env.log('orphan retired DURING a live press — phase left alone');
      return;
    }
    env.retireWork(); // the bridge just said nothing is open (or we
    // stopped listening on its only channel) — the badge must not lie
    env.idleReady();
    env.setStatus(
      const StatusText(
        'Lost the bridge mid-turn — its answer '
        'ended unheard.',
      ),
    );
    env.log('ORPHAN retired: spinner cleared, answer gone unheard');
    env.repaint();
  }
}
