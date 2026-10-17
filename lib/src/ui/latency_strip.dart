/// The round-trip metrics strip under the chat: heard / asr / reply /
/// tts numbers plus the flow arrows the HopTracker lights while data is
/// crossing each stage.
library;

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';

class LatencyStrip extends StatelessWidget {
  const LatencyStrip({super.key, required this.assistant});

  final VoiceAssistant assistant;

  @override
  Widget build(BuildContext context) {
    // A metric that has never fired this session shows a grey dash, not a
    // confident-looking '0.00s' — that zero reads like a broken stopwatch
    // when it really means "hasn't happened yet". Real timings, including
    // genuine sub-second ones, print in full.
    Widget cell(String label, double seconds, int digits) => Column(
      children: [
        Text(
          seconds <= 0 ? '–' : '${seconds.toStringAsFixed(digits)}s',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: seconds <= 0 ? Theme.of(context).disabledColor : null,
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
    // A hop that completed shows lit; the road ahead waits in grey.
    Widget arrow(bool done) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Icon(
        Icons.arrow_forward,
        size: 14,
        color: done ? Colors.green : Theme.of(context).disabledColor,
      ),
    );
    final lit =
        assistant.hopReply; // the PC wakes when the first byte back lands

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        cell('heard', assistant.recordSeconds, 1),
        arrow(assistant.hopAsr),
        cell('asr', assistant.asrSeconds, 2),
        arrow(assistant.hopSent),
        Icon(
          Icons.computer,
          size: 18,
          color: lit ? Colors.green : Theme.of(context).disabledColor,
        ),
        arrow(assistant.hopReply),
        cell('reply', assistant.playSeconds, 1),
        arrow(assistant.hopTts),
        cell('tts', assistant.ttsSeconds, 2),
      ],
    );
  }
}
