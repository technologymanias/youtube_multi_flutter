import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/telegram_service.dart';
import '../services/folder_store.dart';
import 'folder_strip.dart';
import 'telegram_auth_page.dart';
import 'telegram_photo_viewer.dart';
import 'telegram_reel_player.dart';

class TelegramPage extends StatefulWidget {
  final TelegramService service;
  final Set<String> localTitles;
  final FolderStore? folderStore;

  const TelegramPage({
    Key? key,
    required this.service,
    this.localTitles = const {},
    this.folderStore,
  }) : super(key: key);

  @override
  State<TelegramPage> createState() => _TelegramPageState();
}

class _TelegramPageState extends State<TelegramPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  List<SavedMessageItem> _messages = [];
  bool _loading = false;
  bool _needsAuth = false;
  bool _reauthRequired = false;
  String? _error;
  final Set<int> _selectedIds = {};
  int _tabIndex = 0;

  /// Folder the grid is filtered to, or `null` for everything.
  String? _selectedFolderId;

  @override
  void initState() {
    super.initState();
    widget.folderStore?.addListener(_onFoldersChanged);
    _checkAuth();
  }

  void _onFoldersChanged() {
    if (!mounted) return;
    // A deleted folder must not leave the grid filtered to something gone.
    if (_selectedFolderId != null &&
        widget.folderStore?.byId(_selectedFolderId) == null) {
      _selectedFolderId = null;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.folderStore?.removeListener(_onFoldersChanged);
    super.dispose();
  }

  Future<void> _checkAuth() async {
    debugPrint('[TG] _checkAuth: restoring session…');
    final restored = await widget.service.tryRestoreSession();
    debugPrint('[TG] _checkAuth: restored=$restored');
    if (restored) {
      _loadMessages();
    } else {
      setState(() => _needsAuth = true);
    }
  }

  bool _isAuthError(Object e) {
    final s = e.toString().toLowerCase();
    // Only treat genuinely terminal auth failures as requiring a re-login.
    // "not connected" is usually a transient socket error — surfacing it as an
    // auth failure would offer a button that wipes a perfectly good session.
    return s.contains('session expired') ||
        s.contains('auth_key_unregistered') ||
        s.contains('session password needed');
  }

  Future<void> _loadMessages() async {
    setState(() { _loading = true; _error = null; _reauthRequired = false; });
    try {
      final msgs = await widget.service.getSavedMessages(limit: 50);
      if (!mounted) return;
      setState(() {
        _messages = msgs;
        _loading = false;
        // A sync can drop messages the user deleted in Telegram; rebuild the
        // memo from what is actually in the new list.
        _thumbFutures.clear();
        _thumbAttempts.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _prefetchThumbnails());
    } catch (e) {
      if (!mounted) return;
      if (_isAuthError(e)) {
        setState(() {
          _reauthRequired = true;
          _error = 'No input to reauthenticate';
          _loading = false;
        });
      } else {
        const prefix = 'Bad state: ';
        final msg = e.toString();
        setState(() {
          _error = msg.startsWith(prefix) ? msg.substring(prefix.length) : msg;
          _loading = false;
        });
      }
    }
  }

  /// One future per tile. A `FutureBuilder` builds a fresh future on every
  /// rebuild, so without this every tap and tab switch restarted every
  /// thumbnail request in view.
  final Map<int, Future<Uint8List?>> _thumbFutures = {};

  /// How many times a tile has already been retried after an empty result.
  final Map<int, int> _thumbAttempts = {};

  Future<Uint8List?> _thumbFor(SavedMessageItem msg) {
    final key = msg.thumbnailId;
    if (key == null) return Future<Uint8List?>.value(null);
    final existing = _thumbFutures[key];
    if (existing != null) return existing;

    final future = widget.service.getThumbnail(msg);
    _thumbFutures[key] = future;
    future.then((bytes) {
      if (bytes != null) return;
      // Empty result: drop it so a later rebuild can ask again instead of
      // pinning the icon for the rest of the session. One nudge only — the
      // service de-dupes, so a tile that keeps failing settles on the icon.
      if (!identical(_thumbFutures[key], future)) return;
      _thumbFutures.remove(key);
      final tries = (_thumbAttempts[key] ?? 0) + 1;
      _thumbAttempts[key] = tries;
      if (tries > 1 || !mounted) return;
      Future.delayed(const Duration(seconds: 6), () {
        if (mounted) setState(() {});
      });
    });
    return future;
  }

  /// Warm the whole list while the grid scrolls, so swiping to another tab or
  /// further down the page finds the bytes already in the cache.
  void _prefetchThumbnails() {
    if (!mounted) return;
    for (final msg in _messages) {
      if (msg.thumbnailId == null) continue;
      if (_thumbFutures.containsKey(msg.thumbnailId)) continue;
      _thumbFutures[msg.thumbnailId!] = widget.service.getThumbnail(msg);
    }
  }

  Future<void> _reauthenticate() async {
    await widget.service.clearSession();
    if (!mounted) return;
    setState(() {
      _error = null;
      _reauthRequired = false;
      _messages = [];
      _needsAuth = true;
    });
  }

  Future<void> _login() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => TelegramAuthPage(service: widget.service)),
    );
    if (result == true) {
      setState(() => _needsAuth = false);
      _loadMessages();
    }
  }

  IconData _iconForType(SavedMediaType type) {
    switch (type) {
      case SavedMediaType.photo: return Icons.image;
      case SavedMediaType.video: return Icons.videocam;
      case SavedMediaType.audio: return Icons.audiotrack;
      case SavedMediaType.document: return Icons.insert_drive_file;
      case SavedMediaType.none: return Icons.description;
    }
  }

  Color _colorForType(SavedMediaType type) {
    switch (type) {
      case SavedMediaType.photo: return Colors.green;
      case SavedMediaType.video: return Colors.blue;
      case SavedMediaType.audio: return Colors.purple;
      case SavedMediaType.document: return Colors.orange;
      case SavedMediaType.none: return Colors.grey;
    }
  }

  List<SavedMessageItem> get _videoMessages =>
      _messages.where((m) => m.mediaType == SavedMediaType.video).toList();

  List<SavedMessageItem> get _imageMessages =>
      _messages.where((m) => m.mediaType == SavedMediaType.photo).toList();

  List<SavedMessageItem> get _fileMessages =>
      _messages.where((m) => m.mediaType == SavedMediaType.document || m.mediaType == SavedMediaType.audio).toList();

  /// Restricts a tab list to the selected folder. The pager and the grid must
  /// both go through this, otherwise a double-tap opens the wrong item.
  List<SavedMessageItem> _inFolder(List<SavedMessageItem> items) {
    final ids = widget.folderStore
        ?.filterIds(FolderScope.telegram, _selectedFolderId);
    if (ids == null) return items;
    return [for (final m in items) if (ids.contains('${m.id}')) m];
  }

  List<SavedMessageItem> get _visibleVideos => _inFolder(_videoMessages);
  List<SavedMessageItem> get _visibleImages => _inFolder(_imageMessages);
  List<SavedMessageItem> get _visibleFiles => _inFolder(_fileMessages);

  List<SavedMessageItem> get _currentMessages {
    switch (_tabIndex) {
      case 0: return _visibleVideos;
      case 1: return _visibleImages;
      default: return _visibleFiles;
    }
  }

  void _openReel(int index) {
    final videos = _visibleVideos;
    if (index < 0 || index >= videos.length) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TelegramReelPlayer(
          service: widget.service,
          videos: videos,
          initialIndex: index,
        ),
      ),
    );
  }

  void _openPhotos(int index) {
    final photos = _visibleImages;
    if (index < 0 || index >= photos.length) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TelegramPhotoViewer(
          service: widget.service,
          photos: photos,
          initialIndex: index,
        ),
      ),
    );
  }

  void _openItem(SavedMessageItem msg) {
    if (msg.mediaType == SavedMediaType.video) {
      final index = _visibleVideos.indexOf(msg);
      if (index >= 0) _openReel(index);
    } else if (msg.mediaType == SavedMediaType.photo) {
      final index = _visibleImages.indexOf(msg);
      if (index >= 0) _openPhotos(index);
    }
  }

  /// What a long-press on [msg] carries: the whole selection when the tapped
  /// tile is part of it, otherwise just that one item.
  List<String> _dragPayload(SavedMessageItem msg) {
    if (_selectedIds.contains(msg.id)) {
      return [for (final id in _selectedIds) '$id'];
    }
    return ['${msg.id}'];
  }

  Future<void> _downloadSelected() async {
    if (_selectedIds.isEmpty) return;
    final toDownload = _messages.where((m) => _selectedIds.contains(m.id)).toList();
    int success = 0;
    for (final item in toDownload) {
      final path = await widget.service.downloadVideoFile(
        item,
        onProgress: (p) {
          if (mounted) setState(() {});
        },
        onStatus: (msg) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
            );
          }
        },
      );
      if (path != null) {
        item.hasLocalCopy = true;
        success++;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded $success/${toDownload.length} items')),
      );
      setState(() => _selectedIds.clear());
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Telegram'),
        actions: [
          if (widget.folderStore != null && _selectedIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.folder, color: Colors.amber),
              tooltip: 'Move to folder',
              onPressed: () => showMoveToFolderSheet(
                context,
                store: widget.folderStore!,
                scope: FolderScope.telegram,
                itemIds: [for (final id in _selectedIds) '$id'],
              ),
            ),
          if (widget.service.isAuthenticated && _selectedIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.download, color: Colors.green),
              onPressed: _downloadSelected,
            ),
          if (widget.service.isAuthenticated)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadMessages,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_needsAuth) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.telegram, size: 80, color: Colors.blue[300]),
            const SizedBox(height: 16),
            const Text('Connect to Telegram', style: TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 8),
            Text('View your Saved Messages', style: TextStyle(color: Colors.grey[400], fontSize: 14)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _login,
              icon: const Icon(Icons.login),
              label: const Text('Sign In'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            ),
          ],
        ),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.blue));
    }

    if (_error != null) {
      final bool reauth = _reauthRequired;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              reauth ? Icons.lock_outline : Icons.error_outline,
              size: 48,
              color: (reauth ? Colors.orange : Colors.red)[300],
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: reauth ? Colors.orange[300] : Colors.red),
              textAlign: TextAlign.center,
            ),
            if (reauth) ...[
              const SizedBox(height: 8),
              Text(
                'Sign in to Telegram again to continue.',
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            if (reauth)
              ElevatedButton.icon(
                onPressed: _reauthenticate,
                icon: const Icon(Icons.login),
                label: const Text('Reauthenticate'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              )
            else
              ElevatedButton(onPressed: _loadMessages, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 64, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text('No saved messages with media', style: TextStyle(color: Colors.grey[400])),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (widget.folderStore != null)
          FolderStrip(
            store: widget.folderStore!,
            scope: FolderScope.telegram,
            selectedId: _selectedFolderId,
            onSelected: (id) => setState(() {
              _selectedFolderId = id;
              _selectedIds.clear();
            }),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _buildTab(0, 'Videos', _visibleVideos.length, Icons.videocam),
              const SizedBox(width: 8),
              _buildTab(1, 'Images', _visibleImages.length, Icons.image),
              const SizedBox(width: 8),
              _buildTab(2, 'Files', _visibleFiles.length, Icons.insert_drive_file),
            ],
          ),
        ),
        Expanded(child: _buildGrid()),
      ],
    );
  }

  Widget _buildTab(int index, String label, int count, IconData icon) {
    final selected = _tabIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() { _tabIndex = index; _selectedIds.clear(); }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.blue : Colors.grey[900],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: selected ? Colors.white : Colors.grey),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: selected ? Colors.white : Colors.grey, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: selected ? Colors.white24 : Colors.grey[800], borderRadius: BorderRadius.circular(8)),
                child: Text('$count', style: TextStyle(color: selected ? Colors.white : Colors.grey, fontSize: 10)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    final items = _currentMessages;
    final dateFmt = DateFormat('MMM d, HH:mm');
    if (items.isEmpty) {
      final inFolder = _selectedFolderId != null;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(inFolder ? Icons.folder_open : Icons.cloud_off,
                size: 48, color: Colors.grey[600]),
            const SizedBox(height: 12),
            Text(
              inFolder
                  ? 'Nothing in this folder yet'
                  : 'No ${_tabIndex == 0 ? "videos" : _tabIndex == 1 ? "images" : "files"} found',
              style: TextStyle(color: Colors.grey[400]),
            ),
            if (inFolder)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Long-press a tile to drag it in here',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12)),
              ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadMessages,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          childAspectRatio: 0.7,
        ),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final msg = items[i];
          final selected = _selectedIds.contains(msg.id);
          final tile = GestureDetector(
            onTap: () {
              setState(() {
                if (selected) {
                  _selectedIds.remove(msg.id);
                } else {
                  _selectedIds.add(msg.id);
                }
              });
            },
            onDoubleTap:
                (msg.mediaType == SavedMediaType.video ||
                        msg.mediaType == SavedMediaType.photo)
                    ? () => _openItem(msg)
                    : null,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                          child: msg.thumbnailId != null
                              ? FutureBuilder<Uint8List?>(
                                  future: _thumbFor(msg),
                                  builder: (_, snap) {
                                    if (snap.connectionState ==
                                        ConnectionState.waiting) {
                                      return Center(
                                        child: SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: _colorForType(msg.mediaType),
                                          ),
                                        ),
                                      );
                                    }
                                    if (snap.hasData && snap.data != null) {
                                      return Image.memory(snap.data!,
                                          fit: BoxFit.cover);
                                    }
                                    return Center(
                                      child: Icon(_iconForType(msg.mediaType),
                                          size: 32,
                                          color: _colorForType(msg.mediaType)),
                                    );
                                  },
                                )
                              : Center(
                                  child: Icon(_iconForType(msg.mediaType), size: 32, color: _colorForType(msg.mediaType)),
                                ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(
                          msg.caption != null && msg.caption!.isNotEmpty
                              ? msg.caption!
                              : dateFmt.format(msg.date),
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                if (msg.hasLocalCopy)
                  Positioned(
                    top: 4, left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('LOCAL',
                          style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                    ),
                  ),
                if (msg.mediaType == SavedMediaType.video && !msg.hasLocalCopy)
                  Positioned(
                    top: 4, left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('VIDEO',
                          style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                    ),
                  ),
                if (msg.mediaType == SavedMediaType.photo && !msg.hasLocalCopy)
                  Positioned(
                    top: 4, left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('IMAGE',
                          style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                    ),
                  ),
                if (selected)
                  Positioned(
                    top: 4, right: 4,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                      ),
                        child: const Icon(Icons.check, color: Colors.white, size: 14),
                    ),
                  ),
              ],
            ),
          );
          return LongPressDraggable<List<String>>(
            data: _dragPayload(msg),
            feedback: Material(
              color: Colors.transparent,
              child: Container(
                width: 92,
                height: 116,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _colorForType(msg.mediaType).withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: Icon(_iconForType(msg.mediaType),
                    color: Colors.white, size: 36),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.3, child: tile),
            child: tile,
          );
        },
      ),
    );
  }
}
