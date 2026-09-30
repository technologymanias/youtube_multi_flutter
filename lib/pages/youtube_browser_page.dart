import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:url_launcher/url_launcher.dart';

import '../services/account_manager.dart';
import '../youtube_uploader.dart';
import 'video_player_page.dart';

class YoutubeVideoInfo {
  final String id;
  final String title;
  final String? thumbnailUrl;
  final DateTime? publishedAt;
  bool hasLocalCopy;

  YoutubeVideoInfo({
    required this.id,
    required this.title,
    this.thumbnailUrl,
    this.publishedAt,
    this.hasLocalCopy = false,
  });
}

class YoutubeBrowserPage extends StatefulWidget {
  final AccountManager accountManager;
  final Set<String> localVideoTitles;

  const YoutubeBrowserPage({
    Key? key,
    required this.accountManager,
    required this.localVideoTitles,
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

  @override
  void initState() {
    super.initState();
    _fetchVideos();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String? _error;

  Future<void> _fetchVideos({bool loadMore = false}) async {
    final token = widget.accountManager.accessToken;
    if (token == null) {
      setState(() { _loading = false; _error = 'Not signed in'; });
      return;
    }

    if (loadMore) {
      if (_nextPageToken == null || _loadingMore) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() { _loading = true; _error = null; });
    }

    try {
      final channelRes = await http.get(
        Uri.parse('https://www.googleapis.com/youtube/v3/channels?part=contentDetails&mine=true'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (channelRes.statusCode == 401) {
        setState(() { _loading = false; _error = 'Session expired. Please re-sign in.'; });
        return;
      }
      if (channelRes.statusCode != 200) {
        setState(() { _loading = false; _error = 'Failed to load channel (${channelRes.statusCode})'; });
        return;
      }

      final channelData = jsonDecode(channelRes.body);
      final uploadsId = channelData['items']?[0]?['contentDetails']?['relatedPlaylists']?['uploads'] as String?;
      if (uploadsId == null) {
        setState(() { _loading = false; _error = 'No YouTube channel found. Create one first.'; });
        return;
      }

      var url = 'https://www.googleapis.com/youtube/v3/playlistItems'
          '?part=snippet&playlistId=$uploadsId&maxResults=50';
      if (loadMore && _nextPageToken != null) {
        url += '&pageToken=$_nextPageToken';
      }

      final res = await http.get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'});
      if (res.statusCode != 200) {
        setState(() { _loading = false; _error = 'Failed to load videos (${res.statusCode})'; });
        return;
      }

      final data = jsonDecode(res.body);
      final items = data['items'] as List? ?? [];

      final newVideos = items.map<YoutubeVideoInfo>((item) {
        final snippet = item['snippet'] as Map? ?? {};
        final title = (snippet['title'] as String?) ?? '';
        final videoId = snippet['resourceId']?['videoId'] as String? ?? '';
        return YoutubeVideoInfo(
          id: videoId,
          title: title,
          thumbnailUrl: videoId.isNotEmpty
              ? 'https://img.youtube.com/vi/$videoId/maxresdefault.jpg'
              : null,
          publishedAt: snippet['publishedAt'] != null
              ? DateTime.tryParse(snippet['publishedAt'] as String)
              : null,
          hasLocalCopy: widget.localVideoTitles.contains(title.trim()),
        );
      }).toList();

      setState(() {
        if (loadMore) {
          _videos.addAll(newVideos);
        } else {
          _videos = newVideos;
        }
        _nextPageToken = data['nextPageToken'] as String?;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      setState(() { _loading = false; _loadingMore = false; });
    }
  }

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
    final filtered = _searchCtrl.text.isEmpty
        ? _videos
        : _videos.where((v) =>
            v.title.toLowerCase().contains(_searchCtrl.text.toLowerCase())).toList();

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
                IconButton(
                  icon: Icon(Icons.download, color: _selectedIds.isNotEmpty ? Colors.green : Colors.grey[500]),
                  onPressed: _downloadSelected,
                ),
              ],
            ),
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
                    : _videos.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.video_library_outlined, size: 64, color: Colors.grey[600]),
                                const SizedBox(height: 16),
                                Text('No videos found', style: TextStyle(color: Colors.grey[400])),
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
                      return GestureDetector(
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
                                      child: v.id.isNotEmpty
                                          ? Image.network(
                                              'https://img.youtube.com/vi/${v.id}/maxresdefault.jpg',
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) => Image.network(
                                                'https://img.youtube.com/vi/${v.id}/hqdefault.jpg',
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) => Container(color: Colors.grey[800]),
                                              ),
                                            )
                                          : Container(color: Colors.grey[800]),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Text(v.title,
                                        style: const TextStyle(color: Colors.white, fontSize: 10),
                                        maxLines: 2, overflow: TextOverflow.ellipsis),
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
                    },
                  ),
                ),
          ),
        ],
      ),
    );
  }
}
