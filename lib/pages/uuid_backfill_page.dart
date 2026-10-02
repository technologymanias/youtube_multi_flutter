import 'package:flutter/material.dart';

import '../services/account_manager.dart';
import '../services/media_index.dart';
import '../services/telegram_service.dart';
import '../services/upload_scheduler.dart';
import '../services/uuid_backfill.dart';
import '../services/uuid_backfill_service.dart';
import '../youtube_uploader.dart';

/// Lets the user see — and veto — every pairing before any UUID is written or
/// any remote title/caption is rewritten.
///
/// The order of operations matters: scan is read-only, selection is local, and
/// only Apply touches YouTube (50 quota units per title) or Telegram.
class UuidBackfillPage extends StatefulWidget {
  const UuidBackfillPage({
    super.key,
    required this.scheduler,
    required this.accountManager,
    required this.telegramService,
  });

  final UploadScheduler scheduler;
  final AccountManager accountManager;
  final TelegramService telegramService;

  @override
  State<UuidBackfillPage> createState() => _UuidBackfillPageState();
}

class _UuidBackfillPageState extends State<UuidBackfillPage> {
  late final UuidBackfillService _service;

  bool _scanning = false;
  String _scanLabel = '';
  List<ProposedMatch> _results = const [];
  final Set<int> _selected = <int>{};

  bool _applying = false;
  ApplyProgress _progress = ApplyProgress();
  ApplyReport? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = UuidBackfillService(
      scheduler: widget.scheduler,
      telegram: widget.telegramService,
    );
  }

  static const MatchConfidence _autoSelectFrom = MatchConfidence.strong;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _report = null;
      _results = const [];
      _selected.clear();
    });

    try {
      setState(() => _scanLabel = 'Reading the gallery…');
      final locals = await _service.collectLocal();

      setState(() => _scanLabel = 'Reading the queue…');
      final remotes = <RemoteCandidate>[];

      final token = widget.accountManager.accessToken;
      if (token != null && token.isNotEmpty) {
        setState(() => _scanLabel = 'Listing YouTube uploads…');
        remotes.addAll(await _service.collectYoutube(
          token,
          onProgress: (n) =>
              setState(() => _scanLabel = 'Listing YouTube uploads… $n'),
        ));
      }

      if (widget.telegramService.isAuthenticated) {
        setState(() => _scanLabel = 'Reading Telegram Saved Messages…');
        remotes.addAll(await _service.collectTelegram(
          onProgress: (n) => setState(
              () => _scanLabel = 'Reading Telegram… $n messages'),
        ));
      }

      setState(() => _scanLabel = 'Matching…');
      final results = UuidBackfill.match(
        locals: locals,
        remotes: remotes,
        index: MediaIndex.instance,
      );

      // Sort by how sure we are, so the rows worth acting on sit at the top
      // and the ones with nothing to do sink to the bottom.
      final sorted = [...results]
        ..sort((a, b) => b.confidence.index.compareTo(a.confidence.index));

      setState(() {
        _results = sorted;
        _selected.addAll([
          for (var i = 0; i < sorted.length; i++)
            if (sorted[i].confidence.index >= _autoSelectFrom.index &&
                sorted[i].needsRemoteRewrite)
              i,
        ]);
        _scanLabel = '';
        _scanning = false;
      });
    } catch (e) {
      setState(() {
        _scanning = false;
        _scanLabel = '';
        _error = '$e';
      });
    }
  }

  /// Rows whose remote copy already wears the UUID tag need no write at all.
  List<ProposedMatch> get _selectedMatches =>
      [for (final i in _selected) _results[i]];

  int get _youtubeSelected => [
        for (final m in _selectedMatches)
          if (m.needsYoutubeTitle && m.needsRemoteRewrite) m
      ].length;

  int get _telegramSelected => [
        for (final m in _selectedMatches)
          if (m.needsTelegramCaption && m.needsRemoteRewrite) m
      ].length;

  Future<void> _apply() async {
    if (_selected.isEmpty) return;
    final youtubeCount = _youtubeSelected;
    final quota = youtubeCount * YouTubeUploader.updateQuotaCost;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apply UUIDs?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_selected.length} item(s) selected.'),
            const SizedBox(height: 8),
            if (youtubeCount > 0)
              Text(
                '• YouTube: $youtubeCount title update(s) — '
                '$quota API quota units.',
                style: TextStyle(
                  color: quota > 5000 ? Colors.orange[800] : null,
                ),
              ),
            if (_telegramSelected > 0)
              Text('• Telegram: $_telegramSelected caption edit(s) — free.'),
            const SizedBox(height: 12),
            const Text(
              'Local UUIDs are written first, so a failure later can be '
              're-run without redoing them.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _applying = true;
      _report = null;
      _progress = ApplyProgress(total: _selected.length);
    });

    try {
      final token = widget.accountManager.accessToken;
      final uploader = (token == null || token.isEmpty)
          ? null
          : YouTubeUploader(
              token,
              selectedChannelId: widget.accountManager.selectedChannelId,
            );

      final matches = [for (final i in _selected) _results[i]];
      final report = await _service.apply(
        matches,
        uploader: uploader,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );

      setState(() {
        _applying = false;
        _report = report;
        // Everything applied is no longer pending — drop it so a second
        // scan shows only what is left.
        _results = [
          for (var i = 0; i < _results.length; i++)
            if (!_selected.contains(i)) _results[i],
        ];
        _selected.clear();
      });
    } catch (e) {
      setState(() {
        _applying = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = UuidBackfill.summarize(_results);
    return Scaffold(
      appBar: AppBar(
        title: const Text('UUID back-fill'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            tooltip: 'Discard the checkpoint and allow a full re-run',
            icon: const Icon(Icons.restart_alt),
            onPressed: _applying
                ? null
                : () async {
                    await _service.resetCheckpoint();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Checkpoint cleared')),
                    );
                  },
          ),
        ],
      ),
      body: Column(
        children: [
          _header(summary),
          if (_error != null) _errorBar(),
          if (_applying) _progressBar(),
          if (_report != null) _reportBar(),
          Expanded(child: _list()),
        ],
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  Widget _header(Map<MatchConfidence, int> summary) {
    return Material(
      color: Colors.black87,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Finds the videos, photos and files you already uploaded to '
              'YouTube and Telegram, matches them to your gallery, and gives '
              'each one the same UUID locally and remotely.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (_scanning)
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.green),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _scanLabel,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _applying ? null : _scan,
                      icon: const Icon(Icons.search),
                      label: Text(_results.isEmpty
                          ? 'Scan for matches'
                          : 'Scan again'),
                    ),
                  ),
                  if (_results.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${_selected.length}/${_results.length}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ],
              ),
            if (summary.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final e in summary.entries)
                    Chip(
                      label: Text(
                          '${e.value} ${e.key.name}'),
                      labelStyle: const TextStyle(fontSize: 11),
                      visualDensity: VisualDensity.compact,
                      backgroundColor:
                          _confidenceColor(e.key).withValues(alpha: 0.25),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _errorBar() => Material(
        color: Colors.red[900],
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('$_error',
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      );

  Widget _progressBar() {
    final p = _progress;
    final total = p.total == 0 ? 1 : p.total;
    return Material(
      color: Colors.grey[900],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: p.finished / total,
              color: Colors.green,
              backgroundColor: Colors.grey[800],
            ),
            const SizedBox(height: 6),
            Text(
              p.currentLabel ??
                  '${p.finished}/${p.total} — '
                      'YouTube ${p.youtubeEdited} (${p.youtubeQuotaUsed} units), '
                      'Telegram ${p.telegramEdited}, local ${p.localWritten}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportBar() {
    final r = _report!;
    return Material(
      color: r.ok ? Colors.green[900] : Colors.orange[900],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Local ${r.localWritten} · Telegram ${r.telegramEdited} · '
              'YouTube ${r.youtubeEdited} (${r.youtubeQuotaUsed} units) · '
              'skipped ${r.skipped} · failed ${r.failures.length}',
              style: const TextStyle(
                  color: Colors.white, fontSize: 12),
            ),
            for (final f in r.failures.take(5))
              Text('– $f',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    if (_results.isEmpty && !_scanning) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nothing scanned yet.\nPress "Scan for matches" to begin.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (_, i) => _row(i),
    );
  }

  Widget _row(int index) {
    final m = _results[index];
    final checked = _selected.contains(index);
    final color = _confidenceColor(m.confidence);
    return CheckboxListTile(
      value: checked,
      onChanged: _applying
          ? null
          : (v) => setState(() {
                if (v == true) {
                  _selected.add(index);
                } else {
                  _selected.remove(index);
                }
              }),
      dense: true,
      activeColor: color,
      title: Text(
        m.remote.title.isEmpty ? '(no title)' : m.remote.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            m.remote.kind == RemoteKind.youtube ? 'YouTube' : 'Telegram',
            style: TextStyle(fontSize: 11, color: color),
          ),
          if (m.local != null)
            Text(
              'local: ${m.local!.fileName ?? m.local!.assetId}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          Wrap(
            spacing: 4,
            children: [
              for (final s in m.signals)
                Chip(
                  label: Text(s),
                  labelStyle: const TextStyle(fontSize: 10),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
            ],
          ),
          if (m.note != null)
            Text(
              m.note!,
              style: TextStyle(fontSize: 11, color: Colors.orange[700]),
            ),
        ],
      ),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }

  Widget _bottomBar() {
    final youtubeCount = _youtubeSelected;
    return SafeArea(
      child: Material(
        color: Colors.black87,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  youtubeCount > 0
                      ? '$youtubeCount YouTube title update(s) — '
                          '${youtubeCount * YouTubeUploader.updateQuotaCost} '
                          'quota units'
                      : 'Telegram edits are free',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ),
              FilledButton(
                onPressed: (_selected.isEmpty || _scanning || _applying)
                    ? null
                    : _apply,
                child: Text('Apply (${_selected.length})'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _confidenceColor(MatchConfidence c) {
    switch (c) {
      case MatchConfidence.certain:
        return Colors.green;
      case MatchConfidence.exact:
        return Colors.lightGreen;
      case MatchConfidence.strong:
        return Colors.blue;
      case MatchConfidence.probable:
        return Colors.orange;
      case MatchConfidence.none:
        return Colors.red;
    }
  }
}
