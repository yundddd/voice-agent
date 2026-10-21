/// +230: the session-creation sheet — the questions the app asks
/// BEFORE a session is born (which harness answers, which model,
/// which working folder), once at first launch and again on every
/// right-swipe at the first tab. Deliberately NOT the Bridge
/// screen's dense rows: this is a one-handed answer-the-door UI, so
/// every option is a tall button and the whole sheet SCROLLS inside
/// a capped height (a dozens-of-models catalog must not flood the
/// screen — models fold under provider shelves, and the folder
/// section is a browser, not a list of duplicate confirm buttons:
/// tap a folder to ENTER it, and one SELECT button up top files
/// whatever folder you are standing in). The picks are PREVIEWED,
/// not applied: GET /models?harness=&dir= reads the OTHER seat's
/// menu before anything moves, and one POST /seat at the bottom
/// creates the session and its tab atomically.
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
  String? _dir; // the PICKED folder — null until SELECT pressed
  String _in = ''; // folder-browser position (root-relative), '' = root
  List<Map<String, Object>> _dirs = const [];
  List<Map<String, Object>> _models = const [];
  String? _listBaseAbs; // the listing's own absolute folder (GET /dirs'
  // `dir` field): SELECT files this path, and child rows are named
  // inside it — no per-row confirm button, the ENTER gesture is the
  // navigation and SELECT is the answer.
  final Set<String> _open = {}; // expanded provider shelves
  bool _loadingModels = false, _loadingDirs = false;
  String? _note; // last fetch complaint, in words (nulls on next try)
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // The sheet opens on the bridge's own folder level (the browser
    // starts where the bridge lives, which IS the dir-root level
    // typically) — but nothing is SELECTED: the folder question
    // deserves an explicit answer, and a pre-ticked 'current' row
    // read as a fourth question the user never asked.
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

  /// Models grouped by the provider in their id (opencode ids are
  /// providerID/model by law; a claude menu is bare aliases and lands
  /// in one flat shelf). Two or more shelves means you browse
  /// PROVIDERS first — one shelf stays open flat, there is nothing
  /// to hide behind.
  Map<String, List<Map<String, Object>>> get _shelves {
    final m = <String, List<Map<String, Object>>>{};
    for (final e in _models) {
      final id = '${e['id']}';
      final slash = id.indexOf('/');
      final prov = slash <= 0 ? '' : id.substring(0, slash);
      (m[prov] ??= []).add(e);
    }
    return m;
  }

  Future<void> _submit() async {
    final dir = _dir;
    if (dir == null) {
      setState(() => _note = 'pick a working folder first');
      return;
    }
    setState(() => _submitting = true);
    final err = await widget.a.createSession(
      harness: _harness,
      model: _model,
      dir: dir,
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
    final shelves = _shelves;
    final fold = shelves.length > 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        // Capped so the sheet SCROLLS instead of flooding the screen
        // (isScrollControlled removed the 9/16 cap; this puts a
        // thumb-reachable floor back under the Start button).
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('New session',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text('Which harness, which model, which folder.',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 16),
                Text('Answers with',
                    style: Theme.of(context).textTheme.labelLarge),
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
                const SizedBox(height: 8),
                // +230: provider shelves — folded by default when the
                // catalog earns it, one tap to browse, so dozens of
                // models never flood the sheet.
                for (final entry in shelves.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      icon: Icon(
                        _open.contains(entry.key) || !fold
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 20,
                      ),
                      label: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          entry.key.isEmpty
                              ? 'Models'
                              : '${entry.key} · ${entry.value.length}',
                        ),
                      ),
                      onPressed: () => setState(() =>
                          _open.contains(entry.key)
                              ? _open.remove(entry.key)
                              : _open.add(entry.key)),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: (_open.contains(entry.key) || !fold)
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final m in entry.value)
                                  _BigChoice(
                                    label: '${m['label'] ?? m['id']}',
                                    selected: _model == m['id'],
                                    onTap: () => setState(
                                        () => _model = '${m['id']}'),
                                  ),
                              ],
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
                const SizedBox(height: 12),
                // +230: the folder BROWSER. One SELECT button up top
                // files the folder you are standing in (the listing
                // names its own absolute path); the rows below are
                // folders you can ENTER, not a wall of duplicate
                // confirm buttons. The path you stand on is spelled
                // out, and Up walks back.
                Text('Working folder',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Text(_listBaseAbs ?? '…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        )),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor:
                            _dir != null && _dir == _listBaseAbs
                                ? scheme.tertiaryContainer
                                : scheme.primary,
                        foregroundColor:
                            _dir != null && _dir == _listBaseAbs
                                ? scheme.onTertiaryContainer
                                : scheme.onPrimary,
                      ),
                      icon: Icon(_dir != null && _dir == _listBaseAbs
                          ? Icons.check_circle
                          : Icons.check),
                      label: Text(_dir != null && _dir == _listBaseAbs
                          ? 'Selected'
                          : 'Select this folder'),
                      onPressed: _listBaseAbs == null
                          ? null
                          : () => setState(() => _dir = _listBaseAbs),
                    ),
                  ),
                  if (_in.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(88, 52),
                      ),
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Up'),
                      onPressed: () {
                        final i = _in.lastIndexOf('/');
                        setState(() => _in = i < 0 ? '' : _in.substring(0, i));
                        _fetchDirs();
                      },
                    ),
                  ],
                ]),
                const SizedBox(height: 10),
                for (final d in _dirs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      icon: const Icon(Icons.chevron_right, size: 20),
                      label: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('${d['name']}',
                            overflow: TextOverflow.ellipsis),
                      ),
                      // Tap to ENTER: the folder expands, the SELECT
                      // on top follows.
                      onPressed: () {
                        final p = '${d['path']}';
                        setState(() => _in = p);
                        _fetchDirs();
                      },
                    ),
                  ),
                if (_loadingDirs)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                ),
                if (_dir != null && _dir != _listBaseAbs)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Selected: $_dir',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.tertiary,
                            fontFamily: 'monospace',
                          ),
                    ),
                  ),
                if (_note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_note!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: big.copyWith(
                    backgroundColor: WidgetStatePropertyAll(
                        _dir == null
                            ? scheme.surfaceContainerHighest
                            : scheme.primary),
                    foregroundColor: WidgetStatePropertyAll(
                        _dir == null
                            ? scheme.onSurfaceVariant
                            : scheme.onPrimary),
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
      ),
    );
  }
}

/// One big answer-button in the sheet (model chips).
class _BigChoice extends StatelessWidget {
  const _BigChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

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
        label: Text(label, overflow: TextOverflow.ellipsis),
        onPressed: onTap,
      ),
    );
  }
}
