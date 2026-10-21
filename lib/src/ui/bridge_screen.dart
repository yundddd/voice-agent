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

  /// The model row's switch: open the menu (GET /models), tap a name
  /// to POST /model. Errors surface as a snack; on success the
  /// /health re-read repaints the row.
  Future<void> _pickModel() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ModelPicker(assistant: widget.assistant),
    );
    if (chosen == null) return;
    final err = await widget.assistant.setBridgeModel(chosen);
    await _refreshHealth();
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not set the model: $err')),
      );
    }
  }

  /// The harness row's switch: flip the bridge between claude and
  /// opencode (POST /harness). Each harness keeps its own pointer, so
  /// the flip is a step sideways, not a deletion — flipping back
  /// resumes. Errors surface as a snack; on success the /health
  /// re-read repaints the row.
  Future<void> _switchHarness() async {
    final cur = _health?['harness'];
    if (cur != 'claude' && cur != 'opencode') return;
    final err = await widget.assistant.setBridgeHarness(
      cur == 'claude' ? 'opencode' : 'claude',
    );
    await _refreshHealth();
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not switch the harness: $err')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.assistant;
    final scheme = Theme.of(context).colorScheme;
    // +230: a SECTION of the merged Settings screen — no Scaffold, no
    // appbar of its own; shrink-wrapped so one page scrolls.
    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
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
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Run the bridge on your computer, then enter its address:\n'
                'node tool/claude_bridge.mjs --dir <project> --token <token>',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'Bridge URL',
                  hintText: 'http://100.99.240.112:8732',
                  border: OutlineInputBorder(),
                  helperText:
                      'The bridge address on your network (LAN or tailscale).',
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
                  helperText: 'The same --token the bridge runs with.',
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
                          ? 'No reply yet — press Save & check.'
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
                          ? 'No reply yet — press Save & check.'
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
              // Which harness this bridge speaks (POST /harness): the
              // switch steps sideways to the other one — an honest /new
              // for whoever holds the seat, but each harness remembers
              // ITS OWN conversation, so flipping back resumes where
              // that one stopped. Pre-switch bridges carry no `harness`
              // field: those are claude-only and the switch lies dead.
              Row(
                children: [
                  Text(
                    'Harness',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _health == null
                          ? 'No reply yet — press Save & check.'
                          : _health!['harness'] == 'opencode'
                          ? 'OpenCode'
                          : _health!['harness'] == 'claude'
                          ? 'Claude Code'
                          : 'Claude Code (bridge too old to switch)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: switch (_health?['harness']) {
                      'claude' => 'Switch to OpenCode — each harness keeps '
                          'its own conversation',
                      'opencode' => 'Switch to Claude Code — each harness '
                          'keeps its own conversation',
                      _ => 'This bridge is too old to switch harnesses',
                    },
                    onPressed: a.bridgeConfigured &&
                        (_health?['harness'] == 'claude' ||
                            _health?['harness'] == 'opencode') &&
                        !a.bridgeBusy &&
                        !working
                        ? _switchHarness
                        : null,
                    icon: const Icon(Icons.swap_horiz),
                  ),
                ],
              ),
              // Which model answers (POST /model): claude's menu is
              // the bridge operator's (--models), opencode's is the
              // service's own catalog — the row and the sheet are
              // identical either way. The switch opens the menu; the
              // label re-reads /health the moment a pick lands.
              Row(
                children: [
                  Text(
                    'Model',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      _health == null
                          ? 'no /health reply — Save & check first'
                          : !_health!.containsKey('model')
                          ? 'unknown (bridge too old for /model)'
                          : _health!['model'] is String &&
                                    _health!['model'] != ''
                                ? _health!['model'] as String
                                : a.bridgeLastModel != null
                                // +218: the bridge has no current YET
                                // (a restart, or opencode before its
                                // first step names itself) — the app's
                                // own memory of this harness's last
                                // pick wears the row, honestly labelled.
                                ? '${a.bridgeLastModel} (last used)'
                                : 'the default (no step has named one '
                                      'yet)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _health?.containsKey('model') ?? false
                        ? 'Choose the model'
                        : 'This bridge is too old to pick models',
                    onPressed: a.bridgeConfigured &&
                                _health?.containsKey('model') == true
                            ? _pickModel
                            : null,
                    icon: const Icon(Icons.tune),
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
                title: const Text('Speak to the assistant'),
                subtitle: Text(
                  a.bridgeConfigured
                      ? 'On: your words go to the AI and the answer comes '
                            'back spoken. Off: the app just repeats your '
                            'words back.'
                      : 'Enter the bridge URL and token first.',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: a.bridgeNarrate,
                onChanged: (v) => a.setBridgeNarrate(v),
                title: const Text('Narrate progress while working'),
                subtitle: const Text(
                  'On: you hear what it is doing as it does it. Off: only '
                  'the answer is spoken.',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: a.bridgeTts,
                onChanged: (v) => a.setBridgeTts(v),
                title: const Text('Speak replies (TTS)'),
                subtitle: const Text(
                  'Off: answers arrive as text only. No voice download '
                  'is needed.',
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

/// The model menu (GET /models): one flat list, current checked, tap
/// to choose — the bridge answers this shape whichever harness backs
/// it (claude's --models config, opencode's service catalog). A pick
/// pops its id back to BridgeScreen, which POSTs /model; the sheet
/// never writes, so an abandoned browse changes nothing.
class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.assistant});
  final VoiceAssistant assistant;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  Map<String, Object>? _menu;
  bool _busy = true;
  String? _why;
  String? _provider; // drilled-into level (+218); null = the top

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    final m = await widget.assistant.bridgeModels();
    if (!mounted) return;
    setState(() {
      _menu = m;
      _why = m == null
          ? 'the bridge answered no model menu — unreachable, or too '
                'old to have /models'
          : null;
      _busy = false;
    });
  }

  /// Models grouped by the provider its id names (`provider/model`;
  /// claude's bare aliases land under ''). The opencode service's
  /// catalog runs to dozens of models across several providers — a
  /// flat list turned the sheet into archaeology, so the picker shows
  /// PROVIDERS first and only the tapped one's models. A menu with
  /// fewer than two groups (claude's alias list, one provider) never
  /// asks for a hop: it stays flat.
  Map<String, List<Map<String, Object?>>> get _byProvider {
    final out = <String, List<Map<String, Object?>>>{};
    for (final m in _models) {
      final id = '${m['id']}';
      final slash = id.indexOf('/');
      out
          .putIfAbsent(slash < 0 ? '' : id.substring(0, slash), () => [])
          .add(m);
    }
    return out;
  }

  List<Map<String, Object?>> get _models =>
      ((_menu?['models'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, Object?>())
          .toList();

  bool get _hierarchical {
    final named = _byProvider.keys.where((k) => k.isNotEmpty);
    return named.length >= 2;
  }

  String _title(String id, String label) => label.isEmpty ? id : label;

  /// +218: the app's own memory for THIS harness — the sheet badges
  /// what was last used even when the bridge has no current to show
  /// (a restart forgets a claude --model that was never persisted;
  /// opencode names its model only once a step runs).
  String? get _last => widget.assistant.bridgeLastModel;

  @override
  Widget build(BuildContext context) {
    final current = _menu?['current'];
    final hasCurrent = current is String && current.isNotEmpty;
    final last = _last;
    final providers = _byProvider.keys.toList()..sort();
    final drilled = _hierarchical && _provider != null;
    final shown = <Map<String, Object?>>[
      if (drilled) ...(_byProvider[_provider!] ?? const []),
      if (!drilled && !_hierarchical) ..._models,
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (drilled)
                  IconButton(
                    tooltip: 'All providers',
                    onPressed: () => setState(() => _provider = null),
                    icon: const Icon(Icons.arrow_back),
                  )
                else
                  Text(
                    'Model',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                const SizedBox(width: 10),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (hasCurrent)
                  Flexible(
                    child: Text(
                      'current: $current',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else if (last != null && last.isNotEmpty)
                  Flexible(
                    child: Text(
                      'last used: $last',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_why != null)
              Text(_why!, style: Theme.of(context).textTheme.bodySmall)
            else if (_hierarchical && !drilled)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: providers.length,
                  itemBuilder: (context, i) {
                    final p = providers[i];
                    final models = _byProvider[p]!;
                    final holdsCurrent = hasCurrent &&
                        (p.isEmpty
                            ? !current.contains('/')
                            : current.startsWith('$p/'));
                    final holdsLast = !holdsCurrent &&
                        last != null &&
                        last.isNotEmpty &&
                        (p.isEmpty
                            ? !last.contains('/')
                            : last.startsWith('$p/'));
                    return ListTile(
                      dense: true,
                      // A provider row names its shelf, not a model:
                      // the check rides here when the CURRENT model
                      // lives in this provider, so the answer to
                      // 'what am I on?' is one glance at the top list.
                      title: Text(p.isEmpty ? 'Models' : p),
                      subtitle: Text(
                        '${models.length} model'
                        '${models.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      trailing: holdsCurrent
                          ? const Icon(Icons.check)
                          : holdsLast
                          // The shelf that holds last time's model:
                          // one tap back to it after a restart wiped
                          // the bridge's memory but not the app's.
                          ? const Icon(Icons.history)
                          : null,
                      onTap: () => setState(() => _provider = p),
                    );
                  },
                ),
              )
            else if (!shown.any(((_) => true)))
              Text(
                'the menu came back empty — nothing to pick',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final m = shown[i];
                    final id = '${m['id']}';
                    final label = _title(id, '${m['label']}');
                    return ListTile(
                      dense: true,
                      title: Text(label),
                      subtitle: label == id
                          ? null
                          : Text(id,
                              style:
                                  Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              )),
                      trailing: id == current
                          ? const Icon(Icons.check)
                          : id == last
                          ? const Icon(Icons.history)
                          : null,
                      onTap: () => Navigator.of(context).pop(id),
                    );
                  },
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Keep it'),
            ),
          ],
        ),
      ),
    );
  }
}
