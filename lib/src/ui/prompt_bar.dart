/// Typed prompts: the text bar under the conversation, with the TWO
/// queue flavours as the two buttons they are. The voice path decides
/// interrupt-vs-queue with the release gesture (slide up / plain
/// release — see PttHold); typing has no gesture, so the flavour is
/// literal: **Queue** parks the prompt behind whatever is running
/// (it wears the pin until the harness takes it) — and, as the phone's
/// queue-with-backgrounding contract, a RUNNING TOOL is put into
/// background so the agent is freed for this prompt as soon as the
/// thinking ends (cuttool at the bridge; the bottom banner keeps
/// naming the tool until its receipt lands). **Interrupt** supersedes
/// the in-flight turn the way a typed prompt always has (a mere
/// thinking turn is cut in-band, an open tool finishes and this goes
/// next). Enter means Interrupt — the button on the right, the flavour
/// a keyboard press implies.
///
/// A trailing volume icon is the TTS kill switch (BridgePrefs.tts):
/// off, replies land as text only, nothing synthesises, and sends work
/// even while the voice pack is still down.
///
/// Pure I/O: renders its own text field, calls [onSend] with the
/// trimmed text and the flavour, and clears on send. The assistant
/// side is one call: runQuickCommand(text, bubble: text, interrupt:,
/// cutTool:).
library;

import 'package:flutter/material.dart';

class PromptBar extends StatefulWidget {
  const PromptBar({
    super.key,
    required this.onSend,
    this.hint = 'Ask the agent…',
    this.ttsOn,
    this.onToggleTts,
  });

  /// Hands over the trimmed text and what to do with a turn in flight:
  /// true cuts a thinking turn (the interrupt button / Enter), false
  /// queues politely behind the running work (and backgrounds a
  /// running tool).
  final void Function(String text, {required bool interrupt}) onSend;
  final String hint;

  /// The TTS kill switch state and flip — null hides the icon.
  final bool? ttsOn;
  final VoidCallback? onToggleTts;

  @override
  State<PromptBar> createState() => _PromptBarState();
}

class _PromptBarState extends State<PromptBar> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send(bool interrupt) {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text, interrupt: interrupt);
    _text.clear();
    // Keep the keyboard: typing the next prompt is the likely next act.
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // AnimatedBuilder on the controller: the buttons light and dim as
    // the field gains or loses its text, without rebuilding the screen.
    return AnimatedBuilder(
      animation: Listenable.merge([_text, _focus]),
      builder: (context, _) {
        final hasText = _text.text.trim().isNotEmpty;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(true),
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    isDense: true,
                    filled: true,
                    fillColor: hasText
                        ? scheme.surfaceContainerHighest
                        : scheme.surfaceContainerHigh,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              // Queue first: it is the safe press — the one that can
              // never lose the turn in flight. Tooltips name the
              // contract in the same words the chat uses (pin, queue).
              IconButton.filledTonal(
                tooltip:
                    'Queue — polite behind the current turn '
                    '(a running tool is put into background)',
                onPressed: hasText ? () => _send(false) : null,
                icon: const Icon(Icons.schedule),
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                tooltip: 'Interrupt — cut the thinking turn, this goes now',
                onPressed: hasText ? () => _send(true) : null,
                icon: const Icon(Icons.bolt),
              ),
              if (widget.onToggleTts != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: widget.ttsOn == true
                      ? 'TTS on — tap to silence replies'
                      : 'TTS off — tap to speak replies',
                  icon: Icon(
                    widget.ttsOn == true ? Icons.volume_up : Icons.volume_off,
                  ),
                  onPressed: widget.onToggleTts,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
