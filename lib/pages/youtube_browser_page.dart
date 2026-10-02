import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import 'package:url_launcher/url_launcher.dart';

import '../services/account_manager.dart';
import '../services/media_index.dart';
import '../services/folder_store.dart';
import '../youtube_uploader.dart';
import 'folder_strip.dart';
import 'video_player_page.dart';

class YoutubeVideoInfo {
  final String id;
  final String title;
  final String? thumbnailUrl;
  final DateTime? publishedAt;
  final bool isPrivate;
  bool hasLocalCopy;

  YoutubeVideoInfo({
    required this.id,
    required this.title,
    this.thumbnailUrl,
    this.publishedAt,
    this.isPrivate = false,
    this.hasLocalCopy = false,
  });
}

/// Privacy + best thumbnail URL for one video, from videos.list.
class _VideoMeta {
  final bool isPrivate;
  final String? thumbnailUrl;

  const _VideoMeta({required this.isPrivate, required this.thumbnailUrl});
}

class YoutubeBrowserPage extends StatefulWidget {
  final AccountManager accountManager;
  final Set<String> localVideoTitles;

  /// Maps a YouTube video (by id, falling back to title) to a device
  /// photo-library asset id, so private videos can show a local frame.
  final String? Function(String videoId, String title)? resolveLocalAssetId;

  final FolderStore? folderStore;

  const YoutubeBrowserPage({
    Key? key,
    required this.accountManager,
    required this.localVideoTitles,
    this.resolveLocalAssetId,
    this.folderStore,
  }) : super(key: key);

  @override
  State<YoutubeBrowserPage> createState() => _YoutubeBrowserPageState();
}

class _YoutubeBrowserPageState extends State<YoutubeBrowserPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  List<YoutubeVideoInfo> _videos = [];
  bool _loading = false;
  String? _nextPageToken;
  bool _loadingMore = false;
  final _searchCtrl = TextEditingController();
  final Set<String> _selectedIds = {};

  /// assetId -> device thumbnail bytes (memoized so FutureBuilders are stable).
  final Map<String, Future<Uint8List?>> _localThumbCache = {};

  /// Thumb URLs that already returned an error this session, so cells stop
  /// re-firing 404 requests on every rebuild.
  final Set<String> _failedThumbUrls = {};

  /// Folder the grid is filtered to, or `null` for everything.
  String? _selectedFolderId;

  @override
  void initState() {
    super.initState();
    widget.folderStore?.addListener(_onFoldersChanged);
    _fetchVideos();
  }

  void _onFoldersChanged() {
    if (!mounted) return;
    if (_selectedFolderId != null &&
        widget.folderStore?.byId(_selectedFolderId) == null) {
      _selectedFolderId = null;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.folderStore?.removeListener(_onFoldersChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  String? _error;

  /// Whether a remote YouTube title refers to something already in the queue.
  ///
  /// The UUID tag is the authoritative link when present; otherwise fall back
  /// to a tag-stripped title comparison so pre-tag uploads still match.
  bool _hasLocal(String remoteTitle) {
    final tag = MediaIndex.parseTag(remoteTitle);
    if (tag != null && MediaIndex.instance.byShortTag(tag) != null) {
      return true;
    }
    final stripped = MediaIndex.stripTag(remoteTitle).trim();
    return stripped.isNotEmpty && widget.localVideoTitles.contains(stripped);
  }

  Future<void> _fetchVideos({bool loadMore = false}) async {
    final token = widget.accountManager.accessToken;
    if (token == null) {
      setState(() { _loading = false; _loadingMore = false; _error = 'Not signed in'; });
      return;
    }

    if (loadMore) {
      if (_nextPageToken == null || _loadingMore) return;
      setState(() => _loadingMore = true);
    } else {
      _failedThumbUrls.clear();
      setState(() { _loading = true; _error = null; });
    }

    try {
      final channelRes = await http.get(
        Uri.parse('https://www.googleapis.com/youtube/v3/channels?part=contentDetails&mine=true'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (channelRes.statusCode == 401) {
        setState(() { _loading = false; _loadingMore = false; _error = 'Session expired. Please re-sign in.'; });
        return;
      }
      if (channelRes.statusCode != 200) {
        setState(() { _loading = false; _loadingMore = false; _error = 'Failed to load channel (${channelRes.statusCode})'; });
        return;
      }

      final channelData = jsonDecode(channelRes.body);
      final uploadsId = channelData['items']?[0]?['contentDetails']?['relatedPlaylists']?['uploads'] as String?;
      if (uploadsId == null) {
        setState(() { _loading = false; _loadingMore = false; _error = 'No YouTube channel found. Create one first.'; });
        return;
      }

      var url = 'https://www.googleapis.com/youtube/v3/playlistItems'
          '?part=snippet&playlistId=$uploadsId&maxResults=50';
      if (loadMore && _nextPageToken != null) {
        url += '&pageToken=$_nextPageToken';
      }

      final res = await http.get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'});
      if (res.statusCode != 200) {
        setState(() { _loading = false; _loadingMore = false; _error = 'Failed to load videos (${res.statusCode})'; });
        return;
      }

      final data = jsonDecode(res.body);
      final items = data['items'] as List? ?? [];

      final rawVideos = items.map((item) {
        final snippet = item['snippet'] as Map? ?? {};
        final title = (snippet['title'] as String?) ?? '';
        final videoId = snippet['resourceId']?['videoId'] as String? ?? '';
        return {
          'id': videoId,
          'title': title,
          'publishedAt': snippet['publishedAt'] as String?,
        };
      }).toList();

      // Private videos have no public thumbnail, so ask videos.list for the
      // privacy flag and YouTube's own best thumbnail URL (1 quota unit/page).
      final meta = await _fetchVideoMeta(
        rawVideos.map((r) => r['id'] as String).toList(),
      );

      final newVideos = rawVideos.map<YoutubeVideoInfo>((raw) {
        final videoId = raw['id'] as String;
        final title = raw['title'] as String;
        final m = meta[videoId];
        return YoutubeVideoInfo(
          id: videoId,
          title: title,
          thumbnailUrl: m?.thumbnailUrl ??
              (videoId.isNotEmpty
                  ? 'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg'
                  : null),
          isPrivate: m?.isPrivate ?? false,
          publishedAt: raw['publishedAt'] != null
              ? DateTime.tryParse(raw['publishedAt'] as String)
              : null,
          hasLocalCopy: _hasLocal(title),
        );
      }).toList();

      setState(() {
        if (loadMore) {
          _videos.addAll(newVideos);
        } else {
          _videos = newVideos;        }
        _nextPageToken = data['nextPageToken'] as String?;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      setState(() { _loading = false; _loadingMore = false; });
    }
  }

  /// Fetches privacy + best thumbnail URL per video. Never throws; on any
  /// failure the grid falls back to plain public CDN URLs.
  Future<Map<String, _VideoMeta>> _fetchVideoMeta(List<String> ids) async {
    final result = <String, _VideoMeta>{};
    final clean = ids.where((id) => id.isNotEmpty).toList();
    final token = widget.accountManager.accessToken;
    if (clean.isEmpty || token == null) return result;
    try {
      final res = await http.get(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/videos?part=snippet,status&id=${clean.join(',')}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode != 200) return result;
      final items = jsonDecode(res.body)['items'] as List? ?? [];
      for (final item in items) {
        final id = item['id'] as String? ?? '';
        if (id.isEmpty) continue;
        final snippet = item['snippet'] as Map?;
        result[id] = _VideoMeta(
          isPrivate: (item['status'] as Map?)?['privacyStatus'] == 'private',
          thumbnailUrl: _bestThumbUrl(snippet?['thumbnails'] as Map?),
        );
      }
    } catch (_) {}
    return result;
  }

  String? _bestThumbUrl(Map? thumbs) {
    if (thumbs == null) return null;
    for (final key in const ['maxres', 'standard', 'high', 'medium', 'default']) {
      final url = thumbs[key]?['url'] as String?;
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  Future<Uint8List?> _localThumb(String assetId) =>
      _localThumbCache.putIfAbsent(assetId, () async {
        try {
          final asset = await AssetEntity.fromId(assetId);
          if (asset == null) return null;
          return await asset.thumbnailDataWithSize(const ThumbnailSize(480, 270));
        } catch (_) {
          return null;
        }
      });

  List<String> _thumbUrls(YoutubeVideoInfo v) {
    final urls = <String>[
      if (v.thumbnailUrl != null && v.thumbnailUrl!.isNotEmpty) v.thumbnailUrl!,
      'https://i.ytimg.com/vi/${v.id}/maxresdefault.jpg',
      'https://i.ytimg.com/vi/${v.id}/hqdefault.jpg',
      'https://i.ytimg.com/vi/${v.id}/mqdefault.jpg',
    ];
    return urls.toSet().toList();
  }

  /// Thumbnail priority:
  ///  * private + local copy -> device frame (public CDN 404s for private)
  ///  * private              -> CDN with the saved OAuth session, then lock tile
  ///  * public               -> CDN, then device frame, then placeholder
  Widget _buildThumb(YoutubeVideoInfo v) {
    if (v.id.isEmpty) return _placeholderThumb();
    final assetId = widget.resolveLocalAssetId?.call(v.id, v.title);
    final local = assetId == null ? null : _localThumb(assetId);

    if (v.isPrivate) {
      if (local == null) return _networkThumb(v, withAuth: true, fallback: _lockThumb());
      return FutureBuilder<Uint8List?>(
        future: local,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Container(color: Colors.grey[850]);
          }
          if (snap.data != null) return Image.memory(snap.data!, fit: BoxFit.cover);
          return _networkThumb(v, withAuth: true, fallback: _lockThumb());
        },
      );
    }

    final Widget fallback;
    if (local == null) {
      fallback = _placeholderThumb();
    } else {
      fallback = FutureBuilder<Uint8List?>(
        future: local,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Container(color: Colors.grey[850]);
          }
          if (snap.data != null) return Image.memory(snap.data!, fit: BoxFit.cover);
          return _placeholderThumb();
        },
      );
    }
    return _networkThumb(v, withAuth: false, fallback: fallback);
  }

  Widget _networkThumb(YoutubeVideoInfo v, {required bool withAuth, required Widget fallback}) {
    final token = widget.accountManager.accessToken;
    final headers = (withAuth && token != null)
        ? <String, String>{'Authorization': 'Bearer $token'}
        : null;
    return _ThumbChain(
      urls: _thumbUrls(v),
      headers: headers,
      failed: _failedThumbUrls,
      fallback: fallback,
    );
  }

  Widget _lockThumb() => Container(
        color: Colors.grey[850],
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock, color: Colors.grey[600], size: 24),
            const SizedBox(height: 4),
            Text('Private',
                style: TextStyle(color: Colors.grey[600], fontSize: 9)),
          ],
        ),
      );

  Widget _placeholderThumb() => Container(
        color: Colors.grey[850],
        alignment: Alignment.center,
        child: Icon(Icons.video_library_outlined, color: Colors.grey[700], size: 24),
      );

  void _openVideo(YoutubeVideoInfo video) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          videoId: video.id,
          title: video.title,
          thumbnailUrl: video.thumbnailUrl,
        ),
      ),
    );
  }

  /// The long-press path for a multi-selection: one sheet files every picked
  /// video at once, instead of dragging them onto chips one by one.
  Future<void> _moveSelectionToFolder() async {
    final store = widget.folderStore;
    if (store == null || _selectedIds.isEmpty) return;
    await showMoveToFolderSheet(
      context,
      store: store,
      scope: FolderScope.youtube,
      itemIds: [..._selectedIds],
      currentFolderId: _selectedFolderId,
    );
  }

  Future<void> _downloadSelected() async {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No videos selected')),
      );
      return;
    }

    final quality = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Download Quality', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _qualityOption(ctx, 'Best available', null, Icons.hd),
            _qualityOption(ctx, '1080p (Full HD)', '1080', Icons.high_quality),
            _qualityOption(ctx, '720p (HD)', '720', Icons.high_quality),
            _qualityOption(ctx, '480p (SD)', '480', Icons.sd),
            _qualityOption(ctx, 'Audio only (MP3)', 'audio', Icons.audiotrack),
          ],
        ),
      ),
    );
    if (quality == null) return;

    for (final id in _selectedIds) {
      final url = 'https://www.youtube.com/watch?v=$id';
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Opening YouTube…')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot open YouTube. Try installing the YouTube app or Safari.')),
        );
      }
    }
    setState(() => _selectedIds.clear());
  }

  Widget _qualityOption(BuildContext ctx, String label, String? value, IconData icon) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      onTap: () => Navigator.pop(ctx, value),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      tileColor: Colors.grey[850],
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final search = _searchCtrl.text.toLowerCase();
    final searched = search.isEmpty
        ? _videos
        : _videos
            .where((v) => v.title.toLowerCase().contains(search))
            .toList();
    final folderIds = widget.folderStore
        ?.filterIds(FolderScope.youtube, _selectedFolderId);
    final filtered = folderIds == null
        ? searched
        : [for (final v in searched) if (folderIds.contains(v.id)) v];

    String? emptyMessage;
    if (!_loading && _error == null) {
      if (_videos.isEmpty) {
        emptyMessage = 'No videos found';
      } else if (filtered.isEmpty) {
        emptyMessage = _selectedFolderId != null
            ? 'Nothing in this folder yet'
            : 'No matching videos';
      }
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // Search bar + download button
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 60, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search videos...',
                      hintStyle: TextStyle(color: Colors.grey[600]),
                      prefixIcon: Icon(Icons.search, color: Colors.grey[500], size: 20),
                      filled: true,
                      fillColor: Colors.grey[900],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.folderStore != null && _selectedIds.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.folder, color: Colors.amber),
                    tooltip: 'Move to folder',
                    onPressed: () => showMoveToFolderSheet(
                      context,
                      store: widget.folderStore!,
                      scope: FolderScope.youtube,
                      itemIds: [..._selectedIds],
                    ),
                  ),
                IconButton(
                  icon: Icon(Icons.download, color: _selectedIds.isNotEmpty ? Colors.green : Colors.grey[500]),
                  onPressed: _downloadSelected,
                ),
              ],
            ),
          ),
          if (widget.folderStore != null)
            FolderStrip(
              store: widget.folderStore!,
              scope: FolderScope.youtube,
              selectedId: _selectedFolderId,
              onSelected: (id) => setState(() {
                _selectedFolderId = id;
                _selectedIds.clear();
              }),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.error_outline, size: 48, color: Colors.red[400]),
                              const SizedBox(height: 16),
                              Text(_error!, textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                              const SizedBox(height: 20),
                              OutlinedButton.icon(
                                onPressed: () => _fetchVideos(),
                                icon: const Icon(Icons.refresh, size: 18),
                                label: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : emptyMessage != null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                    _selectedFolderId != null
                                        ? Icons.folder_open
                                        : Icons.video_library_outlined,
                                    size: 64,
                                    color: Colors.grey[600]),
                                const SizedBox(height: 16),
                                Text(emptyMessage,
                                    style: TextStyle(color: Colors.grey[400])),
                                if (_selectedFolderId != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                        'Long-press a tile to drag it in here',
                                        style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 12)),
                                  ),
                              ],
                            ),
                          )
              : NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollEndNotification && _nextPageToken != null) {
                      _fetchVideos(loadMore: true);
                    }
                    return false;
                  },
                  child: GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 6,
                      mainAxisSpacing: 6,
                      childAspectRatio: 0.7,
                    ),
                    itemCount: filtered.length + (_loadingMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= filtered.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final v = filtered[i];
                      final selected = _selectedIds.contains(v.id);
                      // One long-press, one job: with several tiles picked it
                      // opens "move selected to folders", otherwise it drags
                      // the single tile onto a chip.
                      final moveSelection =
                          _selectedIds.length > 1 && selected;
                      final tile = GestureDetector(
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selectedIds.remove(v.id);
                            } else {
                              _selectedIds.add(v.id);
                            }
                          });
                        },
                        onDoubleTap: () => _openVideo(v),
                        onLongPress:
                            moveSelection ? _moveSelectionToFolder : null,
                        child: Stack(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.grey[900],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                                      child: _buildThumb(v),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (widget.folderStore != null &&
                                            hasFolderTags(widget.folderStore!,
                                                FolderScope.youtube, v.id)) ...[
                                          FolderTags(
                                            store: widget.folderStore!,
                                            scope: FolderScope.youtube,
                                            itemId: v.id,
                                          ),
                                          const SizedBox(height: 3),
                                        ],
                                        Text(v.title,
                                            style: const TextStyle(color: Colors.white, fontSize: 10),
                                            maxLines: 2, overflow: TextOverflow.ellipsis),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (v.hasLocalCopy)
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
                      if (moveSelection) return tile;
                      return LongPressDraggable<List<String>>(
                        data: selected
                            ? [for (final id in _selectedIds) id]
                            : [v.id],
                        feedback: Material(
                          color: Colors.transparent,
                          child: Container(
                            width: 92,
                            height: 116,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.red.shade700
                                  .withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: const Icon(Icons.play_arrow,
                                color: Colors.white, size: 36),
                          ),
                        ),
                        childWhenDragging:
                            Opacity(opacity: 0.3, child: tile),
                        child: tile,
                      );
                    },
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

/// Tries each thumbnail URL in order; on error moves to the next one and
/// records the failure in [failed] so rebuilds stop re-requesting dead URLs.
class _ThumbChain extends StatelessWidget {
  const _ThumbChain({
    required this.urls,
    required this.fallback,
    this.headers,
    this.failed,
  });

  final List<String> urls;
  final Map<String, String>? headers;
  final Set<String>? failed;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final pending = urls.where((u) => !(failed?.contains(u) ?? false)).toList();
    if (pending.isEmpty) return fallback;
    return Image.network(
      pending.first,
      headers: headers,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) {
        failed?.add(pending.first);
        return _ThumbChain(urls: urls, headers: headers, failed: failed, fallback: fallback);
      },
    );
  }
}
