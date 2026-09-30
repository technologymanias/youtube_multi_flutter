import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/telegram_service.dart';
import 'telegram_auth_page.dart';
import 'telegram_photo_viewer.dart';
import 'telegram_reel_player.dart';

class TelegramPage extends StatefulWidget {
  final TelegramService service;
  final Set<String> localTitles;

  const TelegramPage({Key? key, required this.service, this.localTitles = const {}}) : super(key: key);

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

  @override
  void initState() {
    super.initState();
    _checkAuth();
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
      setState(() { _messages = msgs; _loading = false; });
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

  List<SavedMessageItem> get _currentMessages {
    switch (_tabIndex) {
      case 0: return _videoMessages;
      case 1: return _imageMessages;
      default: return _fileMessages;
    }
  }

  void _openReel(int index) {
    final videos = _videoMessages;
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
    final photos = _imageMessages;
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
      final index = _videoMessages.indexOf(msg);
      if (index >= 0) _openReel(index);
    } else if (msg.mediaType == SavedMediaType.photo) {
      final index = _imageMessages.indexOf(msg);
      if (index >= 0) _openPhotos(index);
    }
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _buildTab(0, 'Videos', _videoMessages.length, Icons.videocam),
              const SizedBox(width: 8),
              _buildTab(1, 'Images', _imageMessages.length, Icons.image),
              const SizedBox(width: 8),
              _buildTab(2, 'Files', _fileMessages.length, Icons.insert_drive_file),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 12),
            Text('No ${_tabIndex == 0 ? "videos" : _tabIndex == 1 ? "images" : "files"} found',
                style: TextStyle(color: Colors.grey[400])),
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
          return GestureDetector(
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
                                  future: widget.service.getThumbnail(msg),
                                  builder: (_, snap) {
                                    if (snap.hasData && snap.data != null) {
                                      return Image.memory(snap.data!, fit: BoxFit.cover);
                                    }
                                    return Center(
                                      child: Icon(_iconForType(msg.mediaType), size: 32, color: _colorForType(msg.mediaType)),
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
        },
      ),
    );
  }
}
