import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'assistant.dart';
import 'tts_voices.dart';

/// Settings page for the assistant's voice: pick/preview/download/delete the
/// stock Piper voices, and record, audition and manage a ZipVoice clone of
/// the user's own voice. All voice packs download lazily — only voices the
/// user actually picks end up on disk, and any of them can be deleted again.
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
  TextEditingController? _transcriptCtrl;
  String _savedTranscript = '';

  VoiceAssistant get a => widget.assistant;

  @override
  void initState() {
    super.initState();
    _refreshInstalled();
  }

  @override
  void dispose() {
    _transcriptCtrl?.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // NeuTTS needs our arm64 Rust bridge; iOS/macOS builds don't ship it yet.
    final voices = a.voices
        .where((v) => !v.isClone && !(v.isNeutts && !Platform.isAndroid))
        .toList();
    final clone = a.voices.firstWhere((v) => v.isClone);

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
                'STANDARD VOICES',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              for (final v in voices) _voiceTile(v),
              if (a.ttsNumSpeakers > 1) _speakerSlider(),
              const SizedBox(height: 20),
              Text(
                'MY VOICE (CLONING)',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              _cloneCard(clone),
              const SizedBox(height: 16),
              Text(
                'Voices download only when you pick them and can be deleted '
                'again with the trash icon; re-picking a deleted voice '
                'downloads it fresh. Cloned replies take a little longer to '
                'generate than the stock voices. The NeuTTS entry ships its '
                'own engine inside the download (arm64 phones).',
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

  Widget _cloneCard(TtsVoice clone) {
    final scheme = Theme.of(context).colorScheme;
    final installed = _installed[clone.id] ?? false;
    final active = a.ttsVoiceId == clone.id;

    final actions = <Widget>[];
    if (a.cloneCapturing) {
      actions.add(
        Text(
          'Recording… ${a.cloneSeconds.toStringAsFixed(1)}s',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
      actions.add(const SizedBox(width: 12));
      actions.add(
        FilledButton.icon(
          onPressed: () =>
              unawaited(a.stopCloneCapture().then((_) => _refreshInstalled())),
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
        ),
      );
      actions.add(const SizedBox(width: 8));
      actions.add(
        TextButton(
          onPressed: a.cancelCloneCapture,
          child: const Text('Cancel'),
        ),
      );
    } else if (!a.hasCloneSample) {
      actions.add(
        FilledButton.icon(
          onPressed: a.voiceBusy ? null : a.startCloneCapture,
          icon: const Icon(Icons.mic),
          label: const Text('Record voice sample'),
        ),
      );
    } else {
      // Sample on disk: transcript + use / re-record / delete controls.
      actions.add(
        FilledButton.icon(
          onPressed: a.voiceBusy ? null : () => _pick(clone, force: true),
          icon: const Icon(Icons.voicemail_outlined),
          label: Text(active ? 'Re-apply my voice' : 'Use my voice'),
        ),
      );
      actions.add(const SizedBox(width: 8));
      if (active) {
        actions.add(
          IconButton(
            tooltip: 'Preview my voice',
            onPressed: a.voiceBusy ? null : a.previewVoice,
            icon: const Icon(Icons.headphones),
          ),
        );
        actions.add(const SizedBox(width: 8));
      }
      actions.add(
        OutlinedButton.icon(
          onPressed: a.voiceBusy ? null : a.startCloneCapture,
          icon: const Icon(Icons.fiber_manual_record),
          label: const Text('Re-record'),
        ),
      );
      actions.add(const SizedBox(width: 8));
      actions.add(
        TextButton(
          onPressed: a.voiceBusy
              ? null
              : () => unawaited(
                  a.deleteCloneSample().then((_) => _refreshInstalled()),
                ),
          child: const Text('Delete recording'),
        ),
      );
    }

    Widget transcriptEditor() {
      final ctrl = _transcriptCtrl ??= TextEditingController(
        text: a.cloneSampleText,
      );
      if (ctrl.text == _savedTranscript && ctrl.text != a.cloneSampleText) {
        // A newer recording superseded it while the user was not editing.
        ctrl.text = a.cloneSampleText;
      }
      _savedTranscript = ctrl.text;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your sample says:',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          TextField(
            controller: ctrl,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              helperText:
                  'Fix any mis-heard words — the clone speaks this '
                  'text, so it shapes the recording.',
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: a.voiceBusy
                  ? null
                  : () => unawaited(
                      a.updateCloneSampleText(ctrl.text).then((_) {
                        _savedTranscript = a.cloneSampleText;
                        _refreshInstalled();
                      }),
                    ),
              child: const Text('Save transcript'),
            ),
          ),
        ],
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (a.hasCloneSample && !a.cloneCapturing)
              transcriptEditor()
            else if (!a.cloneCapturing)
              Text(
                'Record one clear sentence (8–15 s). Whisper writes the '
                'transcript, then the ZipVoice model (about ${clone.sizeLabel} '
                'total, one time) learns to speak your voice. Reading any '
                'short passage works — one sentence is plenty.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
            if (installed && !active && a.hasCloneSample)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: a.voiceBusy
                      ? null
                      : () => unawaited(
                          a
                              .deleteVoice(clone.id)
                              .then((_) => _refreshInstalled()),
                        ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete clone model'),
                ),
              ),
            if (active)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Cloning your voice is in use. The preview button up top '
                  'speaks a test line.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.tertiary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
