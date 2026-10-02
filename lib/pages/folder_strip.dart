import 'package:flutter/material.dart';

import '../services/folder_store.dart';

/// Horizontal chip row shown above every media grid: the current folder
/// filter, every folder on that page, and the controls to make more.
///
/// Each folder chip is a [DragTarget] so a long-pressed grid tile can be
/// dropped straight onto it, and a tap switches the grid to that folder.
class FolderStrip extends StatelessWidget {
  const FolderStrip({
    super.key,
    required this.store,
    required this.scope,
    required this.selectedId,
    required this.onSelected,
    this.onUploadFolder,
  });

  final FolderStore store;
  final FolderScope scope;

  /// Currently filtered folder, or `null` for "show everything".
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  /// Long-press → "Upload folder": queue the whole folder through the app's
  /// default destination. Only the Local page supplies it — the Telegram and
  /// YouTube grids show what is already on those services, so there is
  /// nothing there to queue.
  final Future<void> Function(MediaFolder folder)? onUploadFolder;

  @override
  Widget build(BuildContext context) {
    final folders = store.foldersFor(scope);
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        children: [
          _allChip(),
          for (final folder in folders) _folderChip(context, folder),
          _createChip(context),
          if (folders.isNotEmpty) _backupChip(context),
        ],
      ),
    );
  }

  Widget _allChip() {
    final selected = selectedId == null;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => onSelected(null),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.grey[900],
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[800]!),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_view_rounded,
                  size: 14, color: selected ? Colors.black : Colors.grey[400]),
              const SizedBox(width: 6),
              Text('All',
                  style: TextStyle(
                      color: selected ? Colors.black : Colors.grey[300],
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _folderChip(BuildContext context, MediaFolder folder) {
    final selected = selectedId == folder.id;
    final color = Color(folderColorAt(folder.colorIndex));
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DragTarget<List<String>>(
        builder: (context, incoming, __) {
          final hovering = incoming.isNotEmpty;
          return GestureDetector(
            onTap: () => onSelected(selected ? null : folder.id),
            onLongPress: () => _showFolderMenu(context, folder),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: hovering
                    ? color.withValues(alpha: 0.45)
                    : (selected ? color : Colors.grey[900]),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: hovering || selected ? color : Colors.grey[800]!,
                  width: hovering ? 2 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_rounded,
                      size: 15,
                      color: selected || hovering ? Colors.white : color),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 6),
                  Text('${folder.count}',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 10)),
                ],
              ),
            ),
          );
        },
        onWillAcceptWithDetails: (details) {
          final ids = details.data;
          if (ids.isEmpty) return false;
          for (final id in ids) {
            if (!folder.contains(id)) return true;
          }
          return false;
        },
        onAcceptWithDetails: (details) {
          final ids = details.data;
          store.addItems(folder.id, ids);
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Added ${ids.length} to ${folder.name}'),
            duration: const Duration(seconds: 1),
          ));
        },
      ),
    );
  }

  Widget _createChip(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => _createFolder(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[700]!),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 15, color: Colors.grey[400]),
              const SizedBox(width: 4),
              Text('New',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _backupChip(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => showFolderBackupDialog(context, store),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey[800]!),
          ),
          child: Icon(Icons.save_alt, size: 16, color: Colors.grey[400]),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ folder menu

  Future<void> _showFolderMenu(BuildContext context, MediaFolder folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.folder_rounded,
                  color: Color(folderColorAt(folder.colorIndex))),
              title: Text(folder.name,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: Text('${folder.count} items',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12)),
            ),
            const Divider(color: Colors.grey, height: 1),
            if (onUploadFolder != null)
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined,
                    color: Colors.white70),
                title: const Text('Upload this folder',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text(
                    'Sends all ${folder.count} items to your default destination',
                    style:
                        TextStyle(color: Colors.grey[400], fontSize: 12)),
                onTap: () => Navigator.pop(ctx, 'upload'),
              ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white70),
              title: const Text('Rename',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.palette, color: Colors.white70),
              title: const Text('Change colour',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'color'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red[300]),
              title: Text('Delete folder',
                  style: TextStyle(color: Colors.red[300])),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'upload':
        await onUploadFolder?.call(folder);
      case 'rename':
        await _renameFolder(context, folder);
      case 'color':
        await _pickFolderColor(context, folder);
      case 'delete':
        await _deleteFolder(context, folder);
    }
  }

  Future<void> _renameFolder(BuildContext context, MediaFolder folder) async {
    final controller = TextEditingController(text: folder.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Rename folder',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Folder name',
            hintStyle: TextStyle(color: Colors.grey[600]),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.grey[700]!)),
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    await store.rename(folder.id, name);
  }

  Future<void> _pickFolderColor(
      BuildContext context, MediaFolder folder) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Folder colour',
            style: TextStyle(color: Colors.white)),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (var i = 0; i < kFolderColors.length; i++)
              GestureDetector(
                onTap: () {
                  store.setColor(folder.id, i);
                  Navigator.pop(ctx);
                },
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Color(kFolderColors[i]),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: folder.colorIndex == i
                          ? Colors.white
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteFolder(BuildContext context, MediaFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text('Delete "${folder.name}"?',
            style: const TextStyle(color: Colors.white)),
        content: Text(
          'The folder is removed. The ${folder.count} item${folder.count == 1 ? '' : 's'} '
          'inside it stay in your library.',
          style: TextStyle(color: Colors.grey[400]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: Colors.red[300])),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.delete(folder.id);
    if (folder.id == selectedId) onSelected(null);
  }

  Future<void> _createFolder(BuildContext context) async {
    final controller = TextEditingController();
    var colorIndex = 0;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title:
              const Text('New folder', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Folder name',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.grey[700]!)),
                ),
                onSubmitted: (value) => Navigator.pop(ctx, value),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < kFolderColors.length; i++)
                    GestureDetector(
                      onTap: () => setDialogState(() => colorIndex = i),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Color(kFolderColors[i]),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorIndex == i
                                ? Colors.white
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final folder = await store.create(name, scope, colorIndex: colorIndex);
    onSelected(folder.id);
  }
}

/// Chips naming the folders an item has been filed into, drawn on top of a
/// grid tile so something that was moved into a folder is visibly filed
/// instead of silently missing from the main view.
///
/// Empty when the item is in no folder, which costs the caller nothing extra
/// than a zero-height box.
class FolderTags extends StatelessWidget {
  const FolderTags({
    super.key,
    required this.store,
    required this.scope,
    required this.itemId,
    this.max = 2,
  });

  final FolderStore store;
  final FolderScope scope;
  final String itemId;

  /// How many folder names to print before collapsing the rest into "+n" —
  /// a tile in eight folders must still read as one tile.
  final int max;

  @override
  Widget build(BuildContext context) {
    final folders = store.containing(scope, itemId);
    if (folders.isEmpty) return const SizedBox.shrink();
    final shown = folders.take(max).toList();
    final extra = folders.length - shown.length;
    // Wrap rather than Row: a narrow tile must fold a second chip onto its
    // own line instead of spilling out of the caption box.
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: [
        for (final folder in shown) _tag(folder),
        if (extra > 0) _moreTag(extra),
      ],
    );
  }

  Widget _tag(MediaFolder folder) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Color(folderColorAt(folder.colorIndex)).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_rounded, size: 9, color: Colors.white),
            const SizedBox(width: 3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 70),
              child: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );

  Widget _moreTag(int extra) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '+$extra',
          style: const TextStyle(
              color: Colors.white70, fontSize: 9, fontWeight: FontWeight.w700),
        ),
      );
}

/// Whether [itemId] is filed anywhere in [scope]. Lets a caption layout keep
/// its tight spacing instead of always reserving a gap for chips that are
/// usually not there.
bool hasFolderTags(FolderStore store, FolderScope scope, String itemId) =>
    store.containing(scope, itemId).isNotEmpty;

/// Bottom sheet listing every folder on a page, used from the app bar as the
/// non-drag path into the same place.
Future<void> showMoveToFolderSheet(
  BuildContext context, {
  required FolderStore store,
  required FolderScope scope,
  required List<String> itemIds,
  String? currentFolderId,
  String title = 'Move to folder',
}) async {
  if (itemIds.isEmpty) return;
  final folders = store.foldersFor(scope);

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.grey[900],
    builder: (ctx) => SafeArea(
      child: StatefulBuilder(
        builder: (ctx, setSheetState) {
          final live = store.foldersFor(scope);
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('$title · ${itemIds.length} selected',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
              const Divider(color: Colors.grey, height: 1),
              for (final folder in live)
                ListTile(
                  leading: Icon(Icons.folder_rounded,
                      color: Color(folderColorAt(folder.colorIndex))),
                  title: Text(folder.name,
                      style: const TextStyle(color: Colors.white)),
                  trailing: folder.containsAll(itemIds)
                      ? const Icon(Icons.check, color: Colors.green, size: 18)
                      : null,
                  onTap: () async {
                    await store.addItems(folder.id, itemIds);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              if (currentFolderId != null)
                ListTile(
                  leading: const Icon(Icons.folder_off,
                      color: Colors.orange, size: 22),
                  title: const Text('Remove from this folder',
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    await store.removeItems(currentFolderId, itemIds);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined,
                    color: Colors.white70),
                title: const Text('New folder…',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  final controller = TextEditingController();
                  final name = await showDialog<String>(
                    context: ctx,
                    builder: (dialogCtx) => AlertDialog(
                      backgroundColor: Colors.grey[850],
                      title: const Text('New folder',
                          style: TextStyle(color: Colors.white)),
                      content: TextField(
                        controller: controller,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'Folder name',
                          hintStyle: TextStyle(color: Colors.grey[600]),
                        ),
                        onSubmitted: (value) =>
                            Navigator.pop(dialogCtx, value),
                      ),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dialogCtx),
                            child: const Text('Cancel')),
                        TextButton(
                          onPressed: () =>
                              Navigator.pop(dialogCtx, controller.text),
                          child: const Text('Create'),
                        ),
                      ],
                    ),
                  );
                  controller.dispose();
                  if (name == null || name.trim().isEmpty) return;
                  final folder =
                      await store.create(name, scope, colorIndex: folders.length);
                  await store.addItems(folder.id, itemIds);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Export / import entry point. This is the only thing that carries folders
/// across deleting and reinstalling the app, so it is reachable from every
/// page that has folders.
Future<void> showFolderBackupDialog(
    BuildContext context, FolderStore store) async {
  final messenger = ScaffoldMessenger.of(context);

  // `context` outlives several awaits here; every snackbar goes through this
  // guard so a page that went away mid-pick cannot be messaged.
  void flash(String message) {
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> export() async {
    final ok = await store.exportToFile();
    if (!context.mounted) return;
    Navigator.of(context).pop();
    flash(ok ? 'Backup shared' : 'Export cancelled — nothing was saved');
  }

  Future<void> import() async {
    String? raw;
    try {
      raw = await store.pickBackupJson();
    } catch (e) {
      flash('$e');
      return;
    }
    if (raw == null) return;

    int count;
    try {
      count = store.countIn(raw);
    } on FormatException catch (e) {
      flash(e.message);
      return;
    }
    if (!context.mounted) return;

    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Import folder backup',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Found $count folder${count == 1 ? '' : 's'} in the backup.\n\n'
          'Merge keeps the folders you already have. Replace overwrites them.',
          style: TextStyle(color: Colors.grey[400], fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Merge'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (replace == null || !context.mounted) return;

    try {
      store.importJson(raw, replace: replace);
    } on FormatException catch (e) {
      flash(e.message);
      return;
    }
    Navigator.of(context).pop();
    flash('Restored $count folder${count == 1 ? '' : 's'}');
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.grey[900],
      title:
          const Text('Folder backup', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Folders are kept on this device. Export a backup before you delete '
            'the app — import it after reinstalling and every folder comes back.',
            style: TextStyle(color: Colors.grey[400], fontSize: 13),
          ),
          const SizedBox(height: 12),
          _BackupAction(
            icon: Icons.ios_share,
            label: 'Export backup',
            onTap: export,
          ),
          const SizedBox(height: 8),
          _BackupAction(
            icon: Icons.download,
            label: 'Import backup',
            onTap: import,
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close')),
      ],
    ),
  );
}

class _BackupAction extends StatelessWidget {
  const _BackupAction(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.grey[850],
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: Colors.green, size: 20),
              const SizedBox(width: 12),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}
