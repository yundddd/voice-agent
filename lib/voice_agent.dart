/// Public surface of the voice-agent app: the assistant orchestrator,
/// the state vocabulary the UI renders, and the seams (interfaces +
/// fakes) that everything else plugs into.
///
/// Layout of lib/:
///   main.dart            — entry point (bindings + theme + home screen)
///   src/common/          — clock & scheduler seams (the fakeable time)
///   src/assistant/       — the orchestrator + its extracted components:
///                          turn_session.dart   the bridge-turn truth (single writer)
///                          bridge_turn.dart    the ONE harness event loop
///                          hide_resume.dart    the background→foreground dance
///                          reattach_chain.dart the lost-view retry ladder
///                          activity.dart       the status line as data
///                          view.dart           the screen as one immutable snapshot
///   src/bridge/          — harness gateway, SSE protocol, reattach, rules
///   src/platform/        — mic & speaker adapters (record / audioplayers)
///   src/speech/          — the worker isolate, TTS specs & voice packs
///   src/audio/           — wav I/O and the DSP front end (pure)
///   src/chat/            — the conversation log model
///   src/journal/         — the app event journal (phone-side forensics)
///   src/models/          — model pack download/unpack
///   src/ui/              — screens, widgets, theme (render AssistantView only)
library;

export 'src/assistant/activity.dart';
export 'src/assistant/assistant.dart';
export 'src/assistant/bridge_turn.dart';
export 'src/assistant/chat_store.dart';
export 'src/assistant/hide_resume.dart';
export 'src/assistant/hop_tracker.dart';
export 'src/assistant/mic_pipeline.dart';
export 'src/assistant/narration_gate.dart';
export 'src/assistant/ptt_hold.dart';
export 'src/assistant/reattach_chain.dart';
export 'src/assistant/reply_pipeline.dart';
export 'src/assistant/token_ticker.dart';
export 'src/assistant/turn_session.dart';
export 'src/assistant/view.dart';
export 'src/audio/audio_dsp.dart';
export 'src/audio/audio_io.dart';
export 'src/bridge/bridge.dart';
export 'src/chat/chat_log.dart';
export 'src/common/clock.dart';
export 'src/common/sinks.dart';
export 'src/journal/app_events.dart';
export 'src/models/model_packs.dart';
export 'src/models/model_paths.dart';
export 'src/models/model_unpack.dart';
export 'src/platform/audio_output.dart';
export 'src/platform/mic_source.dart';
export 'src/speech/kokoro_voices.dart';
export 'src/speech/speech_worker.dart';
export 'src/speech/titl_engine.dart';
export 'src/speech/tts_split.dart';
export 'src/speech/tts_voices.dart';
