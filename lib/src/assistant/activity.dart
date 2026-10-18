/// The assistant's status/working line as DATA, not prose.
///
/// The line under the status label used to be a raw String mutated at ~30
/// sites, which made every rewording a behavior-test change and forced the
/// UI to render whatever string was last assigned rather than what is
/// true. An [Activity] names the state the line speaks of (waiting on the
/// bridge, a tool step, paused-with-bridge-live, idle in mode X);
/// [Activity.text] is the single render rule for how each reads. The
/// strings themselves are the ones the field reports taught — moved here
/// verbatim, so prose changes stay a one-line edit per shape and tests
/// assert on the shape, not the wording.
library;

import 'package:path/path.dart' as p;

import 'state.dart';

/// What the status line currently means. Render with [text].
sealed class Activity {
  const Activity();

  /// The exact line the screen shows for this activity in [mode].
  String text({required InteractionMode mode});
}

/// No working line at all (voice preview, bench synth).
final class Blank extends Activity {
  const Blank();
  @override
  String text({required InteractionMode mode}) => '';
}

/// A one-off line owned by its call site (chip notices, dismissal lines,
/// bench status). The verbatim-text escape hatch.
final class StatusText extends Activity {
  const StatusText(this.body);
  final String body;
  @override
  String text({required InteractionMode mode}) => body;
}

/// The at-rest line: what to do next, per interaction mode.
final class IdleHint extends Activity {
  const IdleHint();
  @override
  String text({required InteractionMode mode}) =>
      mode == InteractionMode.conversation
      ? "Tap the mic to start a conversation. Pause about a second and I'll "
            'answer.'
      : 'Ready. Hold the button, speak, release to send.';
}

/// The mic is open: conversation runs on endpointing silence, PTT on the
/// release gesture.
final class ListeningHint extends Activity {
  const ListeningHint();
  @override
  String text({required InteractionMode mode}) =>
      mode == InteractionMode.conversation
      ? 'Listening — just talk.'
      : 'Listening… release to send.';
}

/// The failed sibling of [IdleHint]: same position, retry wording.
final class FailedHint extends Activity {
  const FailedHint();
  @override
  String text({required InteractionMode mode}) =>
      mode == InteractionMode.conversation
      ? 'Error. Tap the mic to retry.'
      : 'Error. Hold the button to retry.';
}

/// Cold start before the worker exists.
final class LoadingModels extends Activity {
  const LoadingModels();
  @override
  String text({required InteractionMode mode}) => 'Loading models…';
}

/// A model pack download in flight; total == 0 renders the label alone
/// (a pack whose size the downloader doesn't know yet).
final class Downloading extends Activity {
  const Downloading(this.label, this.doneBytes, this.totalBytes);
  final String label;
  final int doneBytes, totalBytes;
  @override
  String text({required InteractionMode mode}) => totalBytes > 0
      ? 'Downloading $label: '
            '${(doneBytes / (1024 * 1024)).toStringAsFixed(1)} / '
            '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '$label…';
}

/// A bridge turn is open and the phone is waiting on (or streaming
/// from) the harness. [label] overrides the default while a control turn
/// does housekeeping (/new, /compact name their own work).
final class TurnWaiting extends Activity {
  const TurnWaiting([this.label = 'Asking the bridge…']);
  final String label;
  @override
  String text({required InteractionMode mode}) => label;
}

/// A real harness tool step. The rendering rules the field reports
/// carved: Bash shows the COMMAND (the CLI's own line, ellipsized by the
/// widget), every other step shows its name plus the BASENAME of its
/// detail (a path, not a diff), and pure-plumbing steps still get this
/// label for the eyes even when the gate keeps them from the ears.
final class StepLine extends Activity {
  const StepLine(this.name, this.detail);
  final String name, detail;
  @override
  String text({required InteractionMode mode}) => name == 'Bash'
      ? 'Bash $detail…' // the command itself (+89)
      : '$name${detail.isEmpty ? '' : ' ${p.basename(detail)}'}…';
}

/// The bridge's queue verdict (+99): a press went behind a running turn
/// and the harness answered WHY. It is CONVERSATION ('one moment' plus
/// the reason), not a caption — it also lands as its own chat note
/// (+110), where the turn it waits behind can neither swallow nor
/// pollute it.
final class QueuedVerdict extends Activity {
  const QueuedVerdict(this.reason);
  final String reason;
  @override
  String text({required InteractionMode mode}) => 'One moment — $reason.';
}

/// The app was hidden. The three-way line is the honesty matrix the
/// double-hide field report fixed: a bridge turn in flight promises to
/// show every reply and speak the last one on return; a conversation
/// that merely paused promises its return; neither, and the line is
/// just the idle hint it was before.
final class PausedNotice extends Activity {
  const PausedNotice({required this.bridgeLive, required this.wasLive});
  final bool bridgeLive, wasLive;
  @override
  String text({required InteractionMode mode}) => switch (this) {
    PausedNotice(bridgeLive: true) =>
      "Working in the background — I'll show every reply and speak "
          "the last one when you're back.",
    PausedNotice(wasLive: true) => "Paused — I'll resume when you're back.",
    _ => IdleHint().text(mode: mode),
  };
}

/// A spoken takeover cut the reply mid-flight: the mic is the user's.
final class Interrupted extends Activity {
  const Interrupted();
  @override
  String text({required InteractionMode mode}) => 'Interrupted — go ahead.';
}
