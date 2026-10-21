/// +230: the session-creation sheet — the questions the app asks
/// BEFORE a session is born (which harness answers, which model,
/// which working folder), once at first launch and again on every
/// right-swipe past the newest tab. Deliberately NOT the Bridge
/// screen's dense rows: this is a one-handed answer-the-door UI, so
/// every option is a full-width, 56-px-tall button and the whole
/// sheet fits a thumb's reach. The picks are PREVIEWED, not applied:
/// GET /models?harness=&dir= reads the OTHER seat's menu (and a
/// different folder's catalog) before anything moves, and one POST
/// /seat at the bottom creates the session and its tab atomically.
library;

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';

/// One answered question set — what the sheet hands back.
class SessionSetup {
  const SessionSetup({required this.harness, this.model, required this.dir});
  final String harness; // 'claude' | 'opencode'
  final String? model; // null = let the harness answer in its default
  final String dir;
}

/// Opens the creation sheet. Returns the answered setup, or null when
/// the user bailed (no session was created).
Future<SessionSetup?> showSessionSheet(
  BuildContext context, {
  required VoiceAssistant a,
}) =>
    showModalBottomSheet<SessionSetup>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _SessionSheet(a: a),
    );

class _SessionSheet extends StatefulWidget {
  const _SessionSheet({required this.a});
  final VoiceAssistant a;

  @override
  State<_SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends State<_SessionSheet> {
  String _harness = 'claude';
  String? _model; // null = the harness's own default
  String? _dir; // null = the bridge's current folder (shown as such)
  String _in = ''; // folder-browser position (root-relative), '' = root
  List<Map<String, Object>> _dirs = const [];
  List<Map<String, Object>> _models = const [];
  String? _listBaseAbs; // the listing's own absolute folder (GET /dirs'
  // `dir` field) — child paths are this + '/' + name; the relative
  // `path` values are root-relative and the seat wants absolutes.
  bool _loadingModels = false, _loadingDirs = false;
  String? _note; // last fetch complaint, in words (nulls on next try)
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // The sheet opens pre-answered with the seat the bridge is on (if
    // any): first-time users usually mean 'here, keep going', and the
    // two big questions still stand in front of them.
    final h = widget.a.bridgeHealthCache;
    if (h != null) {
      final hm = h['harness'];
      if (hm is String && (hm == 'claude' || hm == 'opencode')) {
        _harness = hm;
      }
      final d = h['dir'];
      if (d is String && d.isNotEmpty) _dir = d;
      final m = h['model'];
      if (m is String && m.isNotEmpty) _model = m;
    }
    _fetchModels();
    _fetchDirs();
  }

  void _fetchModels() {
    setState(() => _loadingModels = true);
    widget.a.bridgeModels(harness: _harness, dir: _dir).then((info) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _models = info == null
            ? const []
            : [
                for (final m in (info['models'] as List? ?? const []))
                  if (m is Map) m.cast<String, Object>(),
              ];
        _note = info == null ? 'the harness named no menu' : null;
      });
    });
  }

  void _fetchDirs() {
    setState(() => _loadingDirs = true);
    widget.a.bridgeDirs(path: _in.isEmpty ? null : _in).then((info) {
      if (!mounted) return;
      setState(() {
        _loadingDirs = false;
        _listBaseAbs = info?['dir'] is String ? info!['dir'] as String : null;
        _dirs = info == null
            ? const []
            : [
                for (final d in (info['dirs'] as List? ?? const []))
                  if (d is Map) d.cast<String, Object>(),
              ];
        _note = info == null ? 'the bridge offers no folders' : null;
      });
    });
  }

  void _pickHarness(String h) {
    if (_harness == h) return;
    setState(() {
      _harness = h;
      _model = null; // the menu changes wholesale — no carry-over lie
    });
    _fetchModels();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final err = await widget.a.createSession(
      harness: _harness,
      model: _model,
      dir: _dir ?? (widget.a.bridgeHealthCache?['dir'] as String? ?? ''),
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _submitting = false;
        _note = err;
      });
      return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final big = ElevatedButton.styleFrom(
      minimumSize: const Size.fromHeight(56),
      textStyle: Theme.of(context).textTheme.titleMedium,
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New session', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text('Which harness, which model, which folder.',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              Text('Answers with', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: big.copyWith(
                      backgroundColor: WidgetStatePropertyAll(
                        _harness == 'claude'
                            ? scheme.primary
                            : scheme.surfaceContainerHighest,
                      ),
                      foregroundColor: WidgetStatePropertyAll(
                        _harness == 'claude'
                            ? scheme.onPrimary
                            : scheme.onSurface,
                      ),
                    ),
                    icon: const Icon(Icons.chat),
                    label: const Text('Claude Code'),
                    onPressed: () => _pickHarness('claude'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: big.copyWith(
                      backgroundColor: WidgetStatePropertyAll(
                        _harness == 'opencode'
                            ? scheme.primary
                            : scheme.surfaceContainerHighest,
                      ),
                      foregroundColor: WidgetStatePropertyAll(
                        _harness == 'opencode'
                            ? scheme.onPrimary
                            : scheme.onSurface,
                      ),
                    ),
                    icon: const Icon(Icons.terminal),
                    label: const Text('Opencode'),
                    onPressed: () => _pickHarness('opencode'),
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              Text('Model', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _BigChoice(
                    label: 'Default',
                    icon: Icons.auto_awesome,
                    selected: _model == null,
                    onTap: () => setState(() => _model = null),
                  ),
                  for (final m in _models)
                    _BigChoice(
                      label: '${m['label'] ?? m['id']}',
                      selected: _model == m['id'],
                      onTap: () => setState(() => _model = '${m['id']}'),
                    ),
                  if (_loadingModels)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('Working folder',
                      style: Theme.of(context).textTheme.labelLarge),
                  const Spacer(),
                  if (_in.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Up'),
                      onPressed: () {
                        final i = _in.lastIndexOf('/');
                        setState(() => _in = i < 0 ? '' : _in.substring(0, i));
                        _fetchDirs();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _BigChoice(
                label: _dir == null
                    ? 'Current (${widget.a.bridgeHealthCache?['dir'] ?? 'unknown'})'
                    : _dir!.split(RegExp(r'[/\\]')).last,
                path: _dir,
                icon: Icons.home_outlined,
                selected: _dir == null,
                onTap: () => setState(() => _dir = null),
              ),
              const SizedBox(height: 8),
              for (final d in _dirs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ).copyWith(),
                        icon: const Icon(Icons.folder_outlined, size: 20),
                        label: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('${d['name']}',
                              overflow: TextOverflow.ellipsis),
                        ),
                        onPressed: () {
                          final p = '${d['path']}';
                          setState(() => _in = p);
                          _fetchDirs();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(104, 48),
                      ),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Here'),
                      onPressed: () {
                        // /dirs names the listing's own absolute folder
                        // (`dir`) and the child NAMES inside it; the
                        // seat wants an absolute path — base + '/' +
                        // name, never the root-relative `path`.
                        final base = _listBaseAbs;
                        if (base == null) return;
                        setState(() => _dir = '$base/${d['name']}');
                      },
                    ),
                  ]),
                ),
              if (_loadingDirs)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                ),
              if (_note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_note!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: big.copyWith(
                  backgroundColor: WidgetStatePropertyAll(scheme.primary),
                  foregroundColor: WidgetStatePropertyAll(scheme.onPrimary),
                ),
                icon: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: const Text('Start session'),
                onPressed: _submitting ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One big answer-button in the sheet (model chips, folder picks).
class _BigChoice extends StatelessWidget {
  const _BigChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.path,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 140, minHeight: 52),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          backgroundColor:
              selected ? scheme.secondaryContainer : Colors.transparent,
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        icon: Icon(icon ?? (selected ? Icons.check : Icons.circle_outlined),
            size: 18),
        label: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, overflow: TextOverflow.ellipsis),
            if (path != null)
              Text(path!,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis),
          ],
        ),
        onPressed: onTap,
      ),
    );
  }
}
