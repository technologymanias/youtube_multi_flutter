import 'package:flutter/material.dart';

import '../services/phone_data_service.dart';

/// List screen behind the C / L / N / T bar buttons. Reads through
/// [PhoneDataService] so the phone-data reader can be swapped in without
/// touching this file. Rows are selectable (checkboxes + "N selected" in
/// the bar) so the screens are ready for the upload flow that gets wired
/// next; with no reader connected yet the body shows the empty state.
class PhoneDataListPage extends StatefulWidget {
  final PhoneDataKind kind;

  /// Accent used for the bar letter, checkbox and header — green on the
  /// Local side, blue on the Telegram side, matching each page's VPF tabs.
  final Color accent;

  const PhoneDataListPage({
    Key? key,
    required this.kind,
    this.accent = Colors.green,
  }) : super(key: key);

  @override
  State<PhoneDataListPage> createState() => _PhoneDataListPageState();
}

class _PhoneDataListPageState extends State<PhoneDataListPage> {
  late final Future<List<PhoneDataItem>> _future;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _future = PhoneDataService.instance.load(widget.kind);
  }

  void _toggle(PhoneDataItem item) {
    setState(() {
      if (!_selected.remove(item.id)) _selected.add(item.id);
    });
  }

  /// Placeholder until the upload target for phone data is specified.
  void _uploadSelected() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_selected.length} ${widget.kind.title.toLowerCase()} selected — '
          'upload wiring comes with the next step',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LetterBadge(letter: widget.kind.letter, accent: widget.accent, selected: true),
            const SizedBox(width: 8),
            Text(widget.kind.title),
          ],
        ),
        actions: [
          if (_selected.isNotEmpty) ...[
            Center(
              child: Text(
                '${_selected.length} selected',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.upload_file, color: widget.accent),
              tooltip: 'Upload selected',
              onPressed: _uploadSelected,
            ),
          ],
        ],
      ),
      body: FutureBuilder<List<PhoneDataItem>>(
        future: _future,
        builder: (_, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(
              child: CircularProgressIndicator(color: widget.accent),
            );
          }
          final items = snap.data ?? const <PhoneDataItem>[];
          if (items.isEmpty) {
            return _emptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: items.length,
            separatorBuilder: (_, __) =>
                Divider(color: Colors.grey[850], height: 1),
            itemBuilder: (_, i) {
              final item = items[i];
              final selected = _selected.contains(item.id);
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  backgroundColor: widget.accent.withValues(alpha: 0.2),
                  child: Text(
                    item.title.isNotEmpty
                        ? item.title.substring(0, 1).toUpperCase()
                        : '?',
                    style: TextStyle(color: widget.accent, fontSize: 14),
                  ),
                ),
                title: Text(
                  item.title,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: item.subtitle == null
                    ? null
                    : Text(
                        item.subtitle!,
                        style: TextStyle(
                            color: Colors.grey[500], fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.trailing != null)
                      Text(
                        item.trailing!,
                        style:
                            TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    const SizedBox(width: 8),
                    Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      color: selected ? widget.accent : Colors.grey[600],
                      size: 20,
                    ),
                  ],
                ),
                onTap: () => _toggle(item),
              );
            },
          );
        },
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_kindIcon(), size: 56, color: Colors.grey[600]),
          const SizedBox(height: 14),
          Text(
            'No ${widget.kind.title.toLowerCase()} yet',
            style: TextStyle(color: Colors.grey[400], fontSize: 16),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'The phone-data reader for this category connects next — '
              'this screen is ready to list it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  IconData _kindIcon() {
    switch (widget.kind) {
      case PhoneDataKind.contacts:
        return Icons.people_outline;
      case PhoneDataKind.logs:
        return Icons.call_end_outlined;
      case PhoneDataKind.notes:
        return Icons.notes_outlined;
      case PhoneDataKind.texts:
        return Icons.sms_outlined;
    }
  }
}

/// The single-letter chip shared by the bar buttons and the list header.
class LetterBadge extends StatelessWidget {
  final String letter;
  final Color accent;
  final bool selected;
  final double size;

  const LetterBadge({
    Key? key,
    required this.letter,
    required this.accent,
    this.selected = false,
    this.size = 26,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? accent : Colors.grey[900],
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: selected ? accent : Colors.grey[700]!),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: selected ? Colors.white : Colors.grey[400],
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
