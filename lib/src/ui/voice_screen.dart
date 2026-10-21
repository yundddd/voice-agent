import 'dart:async';

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';
import '../speech/kokoro_voices.dart';

/// Settings page for the assistant's voice: pick/preview/download/delete
/// the voice pack and slide through its speaker styles. The pack downloads
/// lazily on first pick and can be deleted again when not in use.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.assistant});

  final VoiceAssistant assistant;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  /// voiceId (and asrModelId) -> pack on disk. Refreshed on open and
  /// after every action.
  final Map<String, bool> _installed = {};

  VoiceAssistant get a => widget.assistant;

  @override
  void initState() {
    super.initState();
    _refreshInstalled();
  }

  Future<void> _refreshInstalled() async {
    final map = <String, bool>{};
    for (final v in a.voices) {
      map[v.id] = a.ttsVoiceId == v.id || await v.installedIn(a.modelsDir);
    }
    for (final m in a.asrOptions) {
      map['asr:${m.id}'] =
          a.asrModelId == m.id || await m.installedIn(a.modelsDir);
    }
    if (mounted) setState(() => _installed.addAll(map));
  }

  void _pick(TtsVoice v, {bool force = false}) {
    unawaited(
      a.selectVoice(v.id, force: force).then((_) => _refreshInstalled()),
    );
  }

  void _pickAsr(AsrModel m) {
    unawaited(a.selectAsr(m.id).then((_) => _refreshInstalled()));
  }

  // ── Round-trip bench ────────────────────────────────────────────────────
  // Push-to-talk -> Whisper -> echo in the just-picked voice, timed from the
  // button release. The point is comparing voices back to back without the
  // LLM's thinking time muddying the numbers: switch voice, run the bench,
  // read the release->first-audio column.

  Widget _benchCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speed_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Echoing as: ${a.benchVoiceLabel}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Say something and the model will say the same thing back '
              'in its voice.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Center(child: _benchButton()),
            if (a.benchNote.isNotEmpty) ...[
              const SizedBox(height: 10),
              SelectableText(
                a.benchNote,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (a.benchRuns.isNotEmpty) ...[
              const SizedBox(height: 8),
              _benchRow(
                'voice',
                'release→text',
                'release→audio',
                'synth (rtf)',
                header: true,
              ),
              for (final r in a.benchRuns)
                _benchRow(
                  r.voice,
                  '${r.asrMs} ms',
                  '${r.firstAudioMs} ms',
                  '${r.synthTotalMs} ms (${r.rtf.toStringAsFixed(2)})',
                  heard: r.heard,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _benchButton() {
    final scheme = Theme.of(context).colorScheme;
    final capturing = a.benchCapturing;
    final busy = a.benchBusy;
    return Listener(
      // Same raw pointer edges as the main push-to-talk button: press and
      // release are bound to this path even if the finger drifts off it.
      onPointerDown: (_) => unawaited(a.benchDown()),
      onPointerUp: (_) => unawaited(a.finishBenchCapture()),
      onPointerCancel: (_) => a.cancelBenchCapture(),
      child: Container(
        width: 132,
        height: 132,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: capturing ? scheme.primary : scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.outlineVariant, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              const CircularProgressIndicator(strokeWidth: 2.5)
            else
              Icon(
                capturing ? Icons.mic : Icons.mic_none,
                size: 34,
                color: capturing ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                busy
                    ? 'measuring…'
                    : capturing
                    ? '${a.benchSeconds.toStringAsFixed(1)}s — release'
                    : 'hold to talk',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: capturing ? scheme.onPrimary : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _benchRow(
    String v,
    String asr,
    String first,
    String synth, {
    bool header = false,
    String heard = '',
  }) {
    final style =
        (header
                ? Theme.of(context).textTheme.labelSmall
                : Theme.of(context).textTheme.bodySmall)
            ?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: header ? null : Theme.of(context).colorScheme.onSurface,
            );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 88,
                child: Text(
                  v,
                  overflow: TextOverflow.ellipsis,
                  style: style?.copyWith(
                    fontWeight: header ? null : FontWeight.w600,
                  ),
                ),
              ),
              Expanded(child: Text(asr, style: style)),
              Expanded(child: Text(first, style: style)),
              Expanded(child: Text(synth, style: style)),
            ],
          ),
          if (!header && heard.isNotEmpty)
            Text(
              '“$heard”',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // +230: a SECTION of the merged Settings screen (see bridge_screen).
    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: a,
        builder: (context, _) {
          return ListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (a.voiceStatus.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      if (a.voiceBusy) ...[
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(child: Text(a.voiceStatus)),
                    ],
                  ),
                ),
              // (the merged page owns the section header — this is the
              // voice list proper)
              for (final v in a.voices) _voiceTile(v),
              if (a.ttsNumSpeakers > 1)
                _styleCard()
              else if (a.ttsNumSpeakers == 1)
                const ListTile(
                  contentPadding: EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(Icons.record_voice_over_outlined),
                  title: Text('Single voice'),
                  subtitle: Text('This model speaks with one style only.'),
                ),
              const SizedBox(height: 20),
              Text(
                'UNDERSTANDING (SPEECH RECOGNITION)',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              for (final m in a.asrOptions) _asrTile(m),
              const SizedBox(height: 20),
              Text(
                'ROUND TRIP TEST',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              _benchCard(),
            ],
          );
        },
      ),
    );
  }

  Widget _voiceTile(TtsVoice v) {
    final scheme = Theme.of(context).colorScheme;
    final active = a.ttsVoiceId == v.id;
    final installed = _installed[v.id] ?? false;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? scheme.primary : null,
      ),
      title: Text(v.label),
      subtitle: Text(
        installed
            ? active
                  ? '${v.note} · ${v.sizeLabel} · in use'
                  : '${v.note} · ${v.sizeLabel} · downloaded — trash to remove'
            : '${v.note} · ${v.sizeLabel} · downloads when picked',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active)
            IconButton(
              tooltip: 'Preview this voice',
              onPressed: a.voiceBusy ? null : a.previewVoice,
              icon: const Icon(Icons.headphones),
            ),
          if (installed && !active)
            IconButton(
              tooltip: 'Delete downloaded model',
              onPressed: a.voiceBusy
                  ? null
                  : () => unawaited(
                      a.deleteVoice(v.id).then((_) => _refreshInstalled()),
                    ),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      onTap: () => _pick(v),
    );
  }

  Widget _asrTile(AsrModel m) {
    final scheme = Theme.of(context).colorScheme;
    final active = a.asrModelId == m.id;
    final installed = _installed['asr:${m.id}'] ?? false;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? scheme.primary : null,
      ),
      title: Text(m.label),
      subtitle: Text(
        installed
            ? active
                  ? '${m.note} · ${m.sizeLabel} · in use'
                  : '${m.note} · ${m.sizeLabel} · downloaded'
            : '${m.note} · ${m.sizeLabel} · downloads when selected',
      ),
      trailing: installed && !active
          ? IconButton(
              tooltip: 'Delete downloaded model',
              onPressed: a.voiceBusy
                  ? null
                  : () => unawaited(
                      a.deleteAsr(m.id).then((_) => _refreshInstalled()),
                    ),
              icon: const Icon(Icons.delete_outline),
            )
          : null,
      onTap: () => _pickAsr(m),
    );
  }

  Widget _styleCard() {
    final scheme = Theme.of(context).colorScheme;
    final current = a.ttsRoster.firstWhere(
      (s) => s.sid == a.ttsSid.clamp(0, a.ttsNumSpeakers - 1),
    );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(Icons.record_voice_over_outlined, color: scheme.primary),
      title: Text(current.name),
      subtitle: Text('Speaker style · ${current.description}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: a.voiceBusy
          ? null
          : () => unawaited(
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => _StylePicker(assistant: a),
              ),
            ),
    );
  }
}

/// Full-height roster sheet: every speaker style by name, grouped by
/// language/accent, each auditionable with one tap (the sid rides the
/// synth job once — no engine switch) and selected with the row itself.
/// Works for both engines: Kokoro's 54 style embeddings and the
/// students' three distilled voices share the picker. The old slider
/// made "Speaker 27 of 54" the entire UX; this makes the styles
/// listable, searchable and listenable.
class _StylePicker extends StatefulWidget {
  const _StylePicker({required this.assistant});

  final VoiceAssistant assistant;

  @override
  State<_StylePicker> createState() => _StylePickerState();
}

class _StylePickerState extends State<_StylePicker> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  VoiceAssistant get a => widget.assistant;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(KokoroSpeaker s) =>
      _query.isEmpty ||
      s.name.contains(_query) ||
      s.description.toLowerCase().contains(_query);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final roster = a.ttsRoster;
    final shown = roster.where(_matches).toList();
    // Group by description in first-appearance order: the sid-ordered
    // roster already puts the English styles (the ones this app speaks
    // well) at the top, and filtering keeps each surviving group's rows
    // under the header that introduced it.
    final groups = <String, List<KokoroSpeaker>>{};
    for (final s in shown) {
      (groups[s.description] ??= []).add(s);
    }
    final busy = a.voiceBusy;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: AnimatedBuilder(
          animation: a,
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Icon(Icons.record_voice_over, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Speaker styles',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.expand_more),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _search,
                  onChanged: (v) =>
                      setState(() => _query = v.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Search — af_heart, British, male…',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              if (a.voiceStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      if (busy) ...[
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          a.voiceStatus,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final g in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                        child: Text(
                          g.key +
                              (g.value.first.english ? '' : ' · non-English'),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      for (final s in g.value) _speakerRow(s, busy),
                    ],
                    if (groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No style matches “$_query”.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Text(
                        a.ttsVoiceId == 'titl'
                            ? 'Play auditions a style without switching to '
                                  'it. Tapping a row picks it; a style not '
                                  'yet on disk downloads its 9 MB graph '
                                  'first. Student styles speak their own '
                                  'language — the Italian pair audition in '
                                  'Italian.'
                            : 'Play auditions a style without switching to '
                                  'it. Tapping a row switches — the engine '
                                  'reloads once. Non-English styles read '
                                  'English text with an accent; only '
                                  'English is wired for synthesis here.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _speakerRow(KokoroSpeaker s, bool busy) {
    final scheme = Theme.of(context).colorScheme;
    final active = s.sid == a.ttsSid;
    return ListTile(
      dense: true,
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? scheme.primary : null,
      ),
      title: Text(
        s.name,
        style: TextStyle(
          fontWeight: active ? FontWeight.w600 : null,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      trailing: IconButton(
        tooltip: 'Audition this style',
        // The audition plays through the SAME loaded engine with a
        // one-shot sid: on the teacher that costs one forward pass, on
        // the students one extra 9 MB graph — never a useTts rebuild,
        // unlike selecting.
        onPressed: busy
            ? null
            : () => a.previewVoice(sid: s.sid, text: s.previewText),
        icon: Icon(active ? Icons.headphones : Icons.play_arrow_outlined),
      ),
      onTap: active || busy
          ? null
          : () => unawaited(a.selectVoice(a.ttsVoiceId, sid: s.sid)),
    );
  }
}
