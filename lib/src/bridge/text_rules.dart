/// Pure wording/decision rules shared by the harness turn loop and the
/// chat UI. Every one is a function of its arguments — the rules the app
/// grew field-report by field-report live here precisely so each stays a
/// unit-tested line instead of a comment nobody dares to touch.
library;

/// Belt-and-braces markdown stripper before TTS: the bridge's voice
/// system prompt already asks for plain spoken sentences, but a harness
/// that ignores it (or a repo report full of bullet lists) would
/// otherwise get its formatting *spoken* ("asterisk asterisk...").
String cleanForSpeech(String t) {
  // +179: tool-call markup emitted AS TEXT — the degraded-upstream
  // shape the 13:11 tape caught: the model wrote its own `
  // <tool_call><function name="Bash"><parameter …` block (a proxy
  // after a /compact re-anchor forgetting the call is a wire object),
  // the CLI saw prose, executed nothing, and the phone got 27.6 s of
  // spoken angle-brackets. Strip SPANS first, on raw text: the
  // markdown pass below eats the underscores that identify them, and
  // the call's ARGUMENTS must vanish with its tags — announcing a
  // lone 'flutter test' would promise a run that never happened.
  var s = t.replaceAll(
    RegExp(
      r'<(antml[:_])?(tool_?calls?|tool_use|function_?calls?|invoke)'
      r'\b[^<>]*>[\s\S]*?(?:</\1?\2\s*>|$)',
      caseSensitive: false,
    ),
    ' ',
  );
  // Orphan tags next (a truncated emission has openers without
  // closers), and the attribute tails a partial span can leave.
  s = s.replaceAll(
    RegExp(
      r'</?\s*(antml[:_])?(tool_?calls?|tool_use|function_?calls?|'
      r'invoke|parameters?|arguments?|description|command)\b[^<>]*>?',
      caseSensitive: false,
    ),
    ' ',
  );
  s = s.replaceAll(RegExp(r'\bname\s*=\s*"[^"]*"'), ' ');
  s = s.replaceAll(RegExp(r'``[\s\S]*?``'), ' (code omitted) ');
  // Links -> their text (replaceAll doesn't expand $1; mapped does).
  s = s.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]*\)'),
    (m) => m.group(1) ?? m.group(0)!,
  );
  s = s.replaceAll(RegExp(r'[*_`~#><|]'), '');
  // espeak (the pack's phonemizer) says the WORD 'period' wherever a dot
  // can't be sentence punctuation: inside filenames ('pubspec.yaml') and
  // at the joins below when the next clause starts lowercase. Neither dot
  // can mean anything spoken, so fold them: the file dot becomes a space,
  // an ellipsis becomes a real full stop, and a clause after a full stop
  // gets capitalized so it lands as sentence intonation, not a spoken
  // 'period'. Decimals keep their dot (the rules only bite on letters).
  s = s.replaceAll('…', '.');
  s = s.replaceAllMapped(RegExp(r'(?<=[a-z])\.(?=[a-z])'), (m) => ' ');
  s = s
      .split('\n')
      .map(
        (l) => l
            .replaceFirst(RegExp(r'^\s*[-•*+]\s*'), 'and ')
            .replaceFirst(': ', ', ')
            .replaceFirst(RegExp(r'[\s:;]+$'), '') // colon before a join dot
            .trim(),
      )
      .where((l) => l.isNotEmpty)
      .join('. ')
      .replaceAll(RegExp(r'\.\s*\.'), '.')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(
        RegExp(r'\. ([a-z])'),
        (m) => '. ${m[1]!.toUpperCase()}',
      )
      .trim();
  // Piper reads a comma-final clause oddly; give the text a stopper.
  if (s.isNotEmpty && !RegExp(r'[.!?]$').hasMatch(s)) s += '.';
  return s;
}

/// Tool steps that are pure plumbing: EYES ONLY. The spinner shows the
/// label; the ears get nothing — no immediate narration and no
/// heartbeat re-speak. (+94, from the queued field report: 'reading a
/// file also goes through TTS, but in fact it's just a tool call, just
/// like editing a file that shouldn't be spoken.' The +73 verdict that
/// file basenames 'speak fine as prose' bought them a pass they never
/// earned: a dozen Read steps in a row is a litany nobody asked to
/// hear.) Unknown/custom tools stay speakable — if it isn't plumbing,
/// the user probably does want to hear what it is.
const kSilentStepTools = {
  'Bash',
  'Read',
  'Write',
  'Edit',
  'MultiEdit',
  'NotebookEdit',
  'Glob',
  'Grep',
  'WebFetch',
  'WebSearch',
  'Agent',
  'TodoWrite',
};
bool stepIsSilentFor(String tool) => kSilentStepTools.contains(tool);

/// The spinner meter's TURN-DELTA anchor (+93): the first input figure
/// a turn reports anchors it, and the meter shows growth since — what
/// THIS turn consumed, not the whole conversation each call carries
/// (the context bar already prices that, in window terms). A figure
/// smaller than the anchor re-anchors it: /compact mid-turn shrinks
/// the world, and the delta must restart at zero rather than go
/// negative and hand the turn credit for a history it no longer
/// carries. A zero (or negative) observation is the fresh turn's
/// opening zero: anchor 0, and the next real figure anchors it. Pure
/// so the rule is unit-guarded.
int turnInAnchor(int observed, int anchor) => observed <= 0
    ? 0
    : (anchor == 0 || observed < anchor)
    ? observed
    : anchor;

/// 12400 -> '12.40k', 467232 -> '467.23k', 1_250_000 -> '1.25M'. Two
/// decimals everywhere (+82 — one made the big counters look like they
/// had stopped moving: 50-token steps vanished in the rounding).
/// Shared by the context bar (ui/) and the live token ticker
/// (TokenTicker), mirroring the bridge's own fmtTok so phone and wire
/// never disagree about how a number reads.
String fmtTokenCount(int n) => n < 1000
    ? '$n'
    : n < 1000000
    ? '${(n / 1000).toStringAsFixed(2)}k'
    : '${(n / 1000000).toStringAsFixed(2)}M';

/// The spinner's first line, translated from the tally's kind — words
/// only, never numbers (those belong to the meter line alone: the same
/// digits on two lines at two cadences is how 'thinking' got buried,
/// 0.1.0+85). Pure and public so the mapping is unit-guarded; the
/// assistant's getter delegates here.
///
/// A tool step prefers the fallback — the step line the tool frame
/// already assembled ('Bash git status --short | head -20…', the
/// command truncated to one line by the widget). 'Running a command…'
/// was progress theater with no information in it, the field report
/// that killed it: while a minute-long build chewed, the honest label
/// of WHICH command was already on the wire, and we threw it away. The
/// generic wording survives only for the sliver before the tool frame
/// lands, or a frame carrying no detail at all.
String activityLabelFor(String kind, String fallback) {
  switch (kind) {
    case 'thinking':
      return 'Thinking…';
    case 'answering':
      return 'Answering…';
    case 'settled':
      return 'Rendering audio…';
    default:
      if (kind.startsWith('calling ')) {
        if (fallback.trim().isNotEmpty) return fallback.trim();
        final t = kind.substring(8);
        return t == 'Bash' ? 'Running a command…' : 'Calling $t…';
      }
      return fallback;
  }
}

/// What the app should do about the bridge after ITS view died — the /talk
/// (or /attach) socket dropped while the app was hidden, the process was
/// killed, or the connection went quiet and black-holed. Fed the GET
/// /health snapshot (or null when the bridge cannot be reached right now):
///
/// * `true` — reattach with GET /attach: a turn is open (`turnOpen`) so
///   attach becomes its heard view again — it STEALS the view even when
///   the bridge still believes the old dead socket is attached (an
///   interrupt-then-repair for the blackhole case, where the server never
///   learns the ear is gone and would keep relaying into the void); or a
///   turn ended unheard and left `missed` events in the replay backlog.
/// * `false` — nothing open, nothing unheard: the turn finished while we
///   were gone and delivered its tail (or never existed) — go idle.
/// * `null` — bridge unreachable: cannot tell whether the turn is alive.
///   Waking phones wake their network late (Tailscale especially), so a
///   failed probe must never silently drop a running turn — retry the
///   probe with backoff instead.
bool? bridgeReattachNeeded(Map<String, Object>? health) {
  if (health == null) return null;
  if (health['turnOpen'] == true) return true;
  final missed = health['missed'];
  return missed is num && missed.toInt() > 0;
}
