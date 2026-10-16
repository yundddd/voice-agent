import 'dart:async';

import 'package:flutter/material.dart';

import 'assistant.dart';
import 'tts_voices.dart';

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
  /// voiceId -> pack on disk. Refreshed on open and after every action.
  final Map<String, bool> _installed = {};
  int? _dragSid; // visual-only slider position while dragging (multi-speaker)

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
    if (mounted) setState(() => _installed.addAll(map));
  }

  void _pick(TtsVoice v, {bool force = false}) {
    unawaited(
      a.selectVoice(v.id, force: force).then((_) => _refreshInstalled()),
    );
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
              'Hold the button and speak; on release the app transcribes '
              'your words and speaks them straight back with the voice '
              'above — no Claude turn, so every millisecond measured is '
              'the models you picked. Switch voices and re-run to compare.',
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

    return Scaffold(
      appBar: AppBar(title: const Text('Assistant voice')),
      body: AnimatedBuilder(
        animation: a,
        builder: (context, _) {
          return ListView(
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
              Text(
                'VOICE',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              for (final v in a.voices) _voiceTile(v),
              if (a.ttsNumSpeakers > 1) _speakerSlider(),
              const SizedBox(height: 20),
              Text(
                'ROUND-TRIP BENCH',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              _benchCard(),
              const SizedBox(height: 16),
              Text(
                'The voice pack downloads only when you pick it and can be '
                'deleted again with the trash icon; re-picking a deleted '
                'voice downloads it fresh.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
                  : '${v.note} · ${v.sizeLabel} · downloaded'
            : '${v.note} · ${v.sizeLabel} · downloads when selected',
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

  Widget _speakerSlider() {
    final shownSid = _dragSid ?? a.ttsSid;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text('Speaker ${shownSid + 1} of ${a.ttsNumSpeakers}'),
      subtitle: Slider(
        min: 0,
        max: (a.ttsNumSpeakers - 1).toDouble(),
        divisions: a.ttsNumSpeakers - 1,
        value: shownSid.toDouble().clamp(0, (a.ttsNumSpeakers - 1).toDouble()),
        label: 'Voice ${shownSid + 1}',
        // Only swap the engine when the finger lifts — every intermediate
        // value would rebuild the TTS model.
        onChanged: (s) => setState(() => _dragSid = s.round()),
        onChangeEnd: (s) {
          setState(() => _dragSid = null);
          _pickSpeaker(s.round());
        },
      ),
    );
  }

  void _pickSpeaker(int sid) {
    if (!a.voiceBusy) {
      unawaited(
        a.selectVoice(a.ttsVoiceId, sid: sid).then((_) => _refreshInstalled()),
      );
    }
  }

}
