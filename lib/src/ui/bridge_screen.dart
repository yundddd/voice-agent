import 'package:flutter/material.dart';

import '../assistant/assistant.dart';

/// Bridge settings + live check (the terminal icon). Everything voice-
/// related about the bridge is one tap deep and needs no manual editing
/// once the url/token are set here — see docs/claude-code-bridge.md for
/// how to start the bridge process itself (`node tool/claude_bridge.mjs`).
class BridgeScreen extends StatefulWidget {
  const BridgeScreen({super.key, required this.assistant});
  final VoiceAssistant assistant;

  @override
  State<BridgeScreen> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends State<BridgeScreen> {
  late final TextEditingController _url = TextEditingController(
    text: widget.assistant.bridgeUrlText,
  );
  late final TextEditingController _token = TextEditingController(
    text: widget.assistant.bridgeTokenText,
  );
  final TextEditingController _free = TextEditingController();
  String? _check; // null = unchecked, '' = healthy, else the reason
  bool _checking = false;
  Map<String, Object>?
  _health; // raw /health payload (session id + turn activity)
  bool _sawBusy = false; // busy true→false edge: re-fetch the pointer

  @override
  void initState() {
    super.initState();
    // Open the screen already knowing the session: a fresh talk can
    // otherwise fork the id (respawn --resume) before you ever hit
    // Save & check, and the whole point of showing it is that it is
    // current.
    if (widget.assistant.bridgeConfigured) _refreshHealth();
  }

  Future<void> _refreshHealth() async {
    final h = await widget.assistant.bridgeHealth();
    if (mounted) setState(() => _health = h);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _free.dispose();
    super.dispose();
  }

  Future<void> _saveAndCheck() async {
    setState(() => _checking = true);
    await widget.assistant.setBridge(url: _url.text, token: _token.text);
    _check = await widget.assistant.bridgeCheck();
    await _refreshHealth();
    if (mounted) setState(() => _checking = false);
  }

  /// The folder browser: browse the bridge's allowlisted tree, then move
  /// the agent there (POST /dir). Errors surface as a snack; on success
  /// the /health re-read repaints the row.
  Future<void> _pickFolder() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _FolderBrowser(assistant: widget.assistant),
    );
    if (chosen == null) return;
    final err = await widget.assistant.setBridgeDir(chosen);
    await _refreshHealth();
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not move the folder: $err')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assistant;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Claude Code bridge'),
        actions: [
          IconButton(
            tooltip: 'Start a fresh conversation (drop history)',
            onPressed: () => a
                .bridgeControl('/new')
                .whenComplete(
                  _refreshHealth, // the pointer goes blank with the history
                ),
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      // Rebuild on every assistant change (busy state, toggle persistence):
      body: AnimatedBuilder(
        animation: a,
        builder: (context, _) {
          // A turn just ended: the pointer can move during one (the id
          // forks when a dead harness respawns --resume between the
          // detach and the next say), so re-fetch on the busy→idle edge
          // and keep this row the truth of what the bridge is on.
          if (a.bridgeBusy) {
            _sawBusy = true;
          } else if (_sawBusy) {
            _sawBusy = false;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _refreshHealth(),
            );
          }
          final sid = _health?['sessionId'];
          final up = _health?['claudeUp'] == true;
          final working = _health?['turnOpen'] == true;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Point the app at the bridge process started on your desktop:\n'
                'node tool/claude_bridge.mjs --dir <project> --token <token>',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'Bridge URL',
                  hintText:
                      'http://135.180.96.71:8732  (or tailscale http://100.99.240.112:8732)',
                  border: OutlineInputBorder(),
                  helperText:
                      'Plain http works on your LAN/tailnet — the bridge '
                      'is LAN-only by convention and carries a shared token.',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                decoration: const InputDecoration(
                  labelText: 'Token',
                  border: OutlineInputBorder(),
                  helperText: 'must match the bridge\'s --token',
                ),
                obscureText: true,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _checking ? null : _saveAndCheck,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link),
                    label: const Text('Save & check'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _check == null
                          ? (a.bridgeConfigured
                                ? 'configured (not yet checked)'
                                : 'not configured')
                          : _check!.isEmpty
                          ? 'bridge reachable, claude up'
                          : 'problem: $_check',
                      style: TextStyle(
                        color: _check == null || _check!.isEmpty
                            ? scheme.onSurfaceVariant
                            : scheme.error,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // The fingerprint of the conversation every talk shares: the
              // bridge writes this id to disk at each turn's end and
              // --resume's it after its own restart, so one session spans
              // the whole voice history (docs/claude-code-bridge.md). An
              // id that never changes IS the proof the talks kept
              // continuing the same session; a change means /new dropped
              // it (or a respawn forked it onto the pointer's successor).
              // Long-press to copy.
              Row(
                children: [
                  Text(
                    'Session',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      _health == null
                          ? 'no /health reply — Save & check, or the bridge is down'
                          : sid is! String || sid.isEmpty
                          ? 'fresh — the first utterance starts it'
                          : sid,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: up ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (working)
                    Text(
                      'working',
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: scheme.primary),
                    ),
                ],
              ),
              const Divider(height: 28),
              // Where the agent works: the folder the harness is spawned
              // IN (the bridge's /health `dir`). The icon browses inside
              // the bridge's --dir-root; picking is an honest /new there —
              // the conversation drops and the next utterance runs in the
              // picked project.
              Row(
                children: [
                  Text(
                    'Working folder',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      _health == null
                          ? 'no /health reply — Save & check first'
                          : _health?['dir'] is String && _health!['dir'] != ''
                          ? _health!['dir'] as String
                          : 'unknown (bridge too old for /dir)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Change the working folder',
                    onPressed: a.bridgeConfigured && _health?['dir'] is String
                        ? _pickFolder
                        : null,
                    icon: const Icon(Icons.folder_open),
                  ),
                ],
              ),
              // Context consumption, straight from the same numbers the
              // main screen's bar uses (live events + /health snapshot).
              if (_health != null && a.contextIn > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'context: ${a.contextIn} tokens of '
                    '${a.contextWindow > 0 ? a.contextWindow : 'an unknown window'}'
                    '${a.contextWindow > 0 ? ' (${(a.contextFrac * 100).toStringAsFixed(1)}%)' : ''}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (_health != null && !up)
                Text(
                  'the harness process is down — the next utterance '
                  'respawns it and resumes this session',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              const Divider(height: 32),
              // The headline switch: your speech -> the harness -> spoken answer.
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: a.bridgeVoice,
                onChanged: (v) => a.setBridgeVoice(v),
                title: const Text('Speak to Claude Code'),
                subtitle: Text(
                  a.bridgeConfigured
                      ? 'On (factory): whatever you say in push-to-talk or '
                            'conversation mode goes to the harness, and its '
                            'answer comes back spoken. Off: the app repeats '
                            'your words back like the offline demo.'
                      : 'Set a bridge url and token above first — with no '
                            'bridge reachable, voice stays offline.',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: a.bridgeNarrate,
                onChanged: (v) => a.setBridgeNarrate(v),
                title: const Text('Narrate progress while working'),
                subtitle: Text(
                  'Off (factory): only the answer speaks — tool steps show '
                  'as silent text lines, the usual turn. On: you hear the '
                  'harness work AS it happens — every tool step earns a '
                  'short spoken line the moment it starts, a long silent '
                  'step repeats that line about every 45 s, and a message '
                  'queuing behind running work is acknowledged out loud, '
                  'so a turn is a stream of progress instead of dead air '
                  'then one block of speech. Reply audio always outranks '
                  'the chatter. (Also narrates the /new chip, which is a '
                  'harness turn even in parrot mode.)',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: a.bridgeTts,
                onChanged: (v) => a.setBridgeTts(v),
                title: const Text('Speak replies (TTS)'),
                subtitle: const Text(
                  'On (factory): harness answers are spoken back. Off: '
                  'replies land as chat text only — nothing synthesises '
                  'or plays, the voice pack is not even required at '
                  'boot, and typed sends work while models are still '
                  'loading. This switch is the mute: the composer\u2019s '
                  'volume icon retired with the bar (+153).',
                ),
              ),
              Text(
                'Session controls on the main screen',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final (label, blurb) in const [
                (
                  '/new',
                  'Forget the conversation on both sides and start over — '
                      'the past no longer fills the context window, and the '
                      'app\'s chat bubbles clear to a blank screen.',
                ),
              ])
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  subtitle: Text(
                    blurb,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.play_arrow),
                    tooltip: 'Run this control now',
                    onPressed: a.bridgeBusy || !a.bridgeConfigured
                        ? null
                        : () {
                            Navigator.of(
                              context,
                            ).pop(); // talk over on the main screen
                            a.bridgeControl(label);
                          },
                  ),
                ),
              const Divider(height: 32),
              Text(
                'Say anything',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _free,
                decoration: const InputDecoration(
                  labelText: 'Custom command for the harness',
                  border: OutlineInputBorder(),
                  helperText:
                      'sent verbatim as one utterance; the answer is '
                      'spoken with your assistant voice. A line starting '
                      'with / runs as a real Claude Code command (e.g. '
                      '/context to hear how full the window is)',
                ),
                onSubmitted: (v) {
                  if (v.trim().isEmpty) return;
                  Navigator.of(context).pop();
                  a.runQuickCommand(v.trim(), bubble: v.trim());
                },
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed:
                      a.bridgeBusy ||
                          !a.bridgeConfigured ||
                          _free.text.trim().isEmpty
                      ? null
                      : () {
                          final v = _free.text.trim();
                          _free.clear();
                          Navigator.of(context).pop();
                          a.runQuickCommand(v, bubble: v);
                        },
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One level of the bridge's allowlisted folder tree (GET /dirs): tap a
/// folder to browse into it, up-arrow to retreat, and 'Work here' hands
/// the current directory back to BridgeScreen, which POSTs /dir. The
/// listing is relative to the bridge's root — the phone never learns
/// (or can name) anything outside it.
class _FolderBrowser extends StatefulWidget {
  const _FolderBrowser({required this.assistant});
  final VoiceAssistant assistant;

  @override
  State<_FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<_FolderBrowser> {
  /// Root-relative path of the level shown ('' = the root itself).
  String _in = '';
  Map<String, Object>? _listing;
  bool _busy = true;
  String? _why; // honest empty state: unreachable or too-old bridge

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    final l = await widget.assistant.bridgeDirs(path: _in.isEmpty ? null : _in);
    if (!mounted) return;
    setState(() {
      _listing = l;
      _why = l == null
          ? 'the bridge answered no folder listing — unreachable, or too '
                'old to have /dirs'
          : null;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = _listing;
    final here = l?['dir'] as String?;
    final parent = l?['parent'];
    final dirs = (l?['dirs'] as List?) ?? const [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Up one folder',
                  onPressed: parent is String
                      ? () {
                          setState(() => _in = parent);
                          _load();
                        }
                      : null,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: Text(
                    here ?? 'Loading…',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
                FilledButton(
                  onPressed: here == null
                      ? null
                      : () => Navigator.of(context).pop(here),
                  child: const Text('Work here'),
                ),
              ],
            ),
            const Divider(),
            Flexible(
              child: _busy
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _why != null
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_why!, style: TextStyle(color: scheme.error)),
                    )
                  : ListView.builder(
                      itemCount: dirs.length,
                      itemBuilder: (context, i) {
                        final d = (dirs[i] as Map).cast<String, Object>();
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(d['name'] as String),
                          onTap: () {
                            setState(() => _in = d['path'] as String);
                            _load();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
