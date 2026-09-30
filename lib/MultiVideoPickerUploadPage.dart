import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'package:intl/intl.dart';
import 'main.dart';
import 'youtube_uploader.dart';
import 'video_picker.dart';

class MultiVideoPickerUploadPage extends StatefulWidget {
  final String? accessToken;
  final String? channelId;
  final String userDisplayName;
  final String userEmail;
  final String userPhotoUrl;

  const MultiVideoPickerUploadPage({
    Key? key,
    this.accessToken,
    this.channelId,
    this.userDisplayName = '',
    this.userEmail = '',
    this.userPhotoUrl = '',
  }) : super(key: key);

  @override
  _MultiVideoPickerUploadPageState createState() => _MultiVideoPickerUploadPageState();
}

class _MultiVideoPickerUploadPageState extends State<MultiVideoPickerUploadPage> {
  List<AssetEntity> _videos = [];
  Set<AssetEntity> _selectedVideos = {};
  Set<String> _uploadedVideoIds = {};
  Set<String> _youtubeVideoTitles = {};
  static const _storage = FlutterSecureStorage();
  List<String> _uploadDates = [];
  bool _loading = false;
  bool _syncingYoutube = false;
  bool _isDisposed = false;
  int _todayUploadCount = 0;
  final ScrollController _scrollController = ScrollController();
  String _currentHeaderDate = '';

  final Map<String, ValueNotifier<double>> _uploadProgressNotifiers = {};
  final Map<String, ValueNotifier<String>> _uploadStatusNotifiers = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initPrefsAndVideos();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initPrefsAndVideos() async {
    final idsJson = await _storage.read(key: 'uploadedVideoIds');
    if (idsJson != null) {
      _uploadedVideoIds = (jsonDecode(idsJson) as List).cast<String>().toSet();
    }
    final datesJson = await _storage.read(key: 'uploadDates');
    if (datesJson != null) {
      _uploadDates = (jsonDecode(datesJson) as List).cast<String>();
    }
    _todayUploadCount = _computeTodayCount();
    if (!kIsWeb) {
      await _fetchVideos();
      unawaited(_fetchYoutubeUploads());
    }
  }

  int _computeTodayCount() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _uploadDates.where((d) => d.startsWith(today)).length;
  }

  void _onScroll() {
    if (_videos.isEmpty) return;
    final viewportWidth = MediaQuery.of(context).size.width;
    final itemWidth = (viewportWidth - 40) / 4;
    final rowHeight = itemWidth + 8;
    final totalRows = (_videos.length / 4).ceil();
    final row = ((_scrollController.offset - 8) / rowHeight).floor().clamp(0, totalRows - 1);
    final index = (row * 4).clamp(0, _videos.length - 1);
    final date = _videos[index].createDateTime;
    final formatted = DateFormat('MMM d, yyyy').format(date);
    if (formatted != _currentHeaderDate) {
      setState(() => _currentHeaderDate = formatted);
    }
  }

  Future<void> _recordUpload() async {
    _uploadDates.add(DateTime.now().toIso8601String());
    await _storage.write(key: 'uploadDates', value: jsonEncode(_uploadDates));
    setState(() => _todayUploadCount = _computeTodayCount());
  }

  Future<void> _fetchYoutubeUploads() async {
    final token = widget.accessToken;
    if (token == null) return;
    setState(() => _syncingYoutube = true);

    try {
      final channelRes = await http.get(
        Uri.parse('https://www.googleapis.com/youtube/v3/channels?part=contentDetails&mine=true'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (channelRes.statusCode != 200) return;
      final channelData = jsonDecode(channelRes.body);
      final uploadsId = channelData['items']?[0]?['contentDetails']?['relatedPlaylists']?['uploads'] as String?;
      if (uploadsId == null) return;

      final titles = <String>{};
      String? nextPage;
      do {
        final url = 'https://www.googleapis.com/youtube/v3/playlistItems'
            '?part=snippet&playlistId=$uploadsId&maxResults=50'
            '${nextPage != null ? '&pageToken=$nextPage' : ''}';
        final res = await http.get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'});
        if (res.statusCode != 200) break;
        final data = jsonDecode(res.body);
        for (final item in data['items'] ?? []) {
          final title = item['snippet']?['title'] as String?;
          if (title != null) titles.add(title.trim());
        }
        nextPage = data['nextPageToken'] as String?;
      } while (nextPage != null);

      if (mounted) setState(() => _youtubeVideoTitles = titles);
    } catch (_) {
      // Silently fail — YouTube sync is best-effort
    } finally {
      if (mounted) setState(() => _syncingYoutube = false);
    }
  }

  Future<void> _fetchVideos() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) return PhotoManager.openSetting();

    final albums = await PhotoManager.getAssetPathList(type: RequestType.video);
    List<AssetEntity> allVideos = [];
    for (var album in albums) {
      final videos = await album.getAssetListPaged(page: 0, size: 500);
      allVideos.addAll(videos);
    }
    final uniqueVideos = {for (var v in allVideos) v.id: v}.values.toList();
    uniqueVideos.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    setState(() {
      _videos = uniqueVideos;
      if (uniqueVideos.isNotEmpty) {
        _currentHeaderDate = DateFormat('MMM d, yyyy').format(uniqueVideos.first.createDateTime);
      }
    });
  }

  Future<Uint8List?> _safeThumbnail(AssetEntity video) async {
    if (_isDisposed) return null;
    try {
      final data = await video.thumbnailDataWithSize(const ThumbnailSize(200, 200));
      if (_isDisposed) return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  bool _isOnYoutube(AssetEntity video) {
    final id = video.id;
    if (_uploadedVideoIds.contains(id)) return true;

    final title = _videoTitleFor(video);
    return title != null && _youtubeVideoTitles.contains(title);
  }

  String? _videoTitleFor(AssetEntity video) {
    final id = video.id;
    for (final v in _videos) {
      if (v.id == id) return v.title;
    }
    return null;
  }

  void _toggleSelect(AssetEntity video) {
    if (_isOnYoutube(video)) return;
    setState(() {
      if (_selectedVideos.contains(video)) {
        _selectedVideos.remove(video);
      } else {
        _selectedVideos.add(video);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedVideos = _videos.where((v) => !_isOnYoutube(v)).toSet();
    });
  }

  Future<void> _markSelectedAsUploaded() async {
    setState(() {
      _uploadedVideoIds.addAll(_selectedVideos.map((v) => v.id));
      _selectedVideos.clear();
    });
    await _storage.write(key: 'uploadedVideoIds', value: jsonEncode(_uploadedVideoIds.toList()));
  }

  void _initNotifiersForVideo(String id) {
    _uploadProgressNotifiers.putIfAbsent(id, () => ValueNotifier<double>(0));
    _uploadStatusNotifiers.putIfAbsent(id, () => ValueNotifier<String>(''));
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.red,
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _uploadSelectedVideosWeb() async {
    if (widget.accessToken == null) return;
    setState(() => _loading = true);

    final channelId = widget.channelId ?? '';
    final uploader = YouTubeUploader(widget.accessToken!, selectedChannelId: channelId);

    final files = await pickVideosWebImpl();
    if (files.isEmpty) {
      setState(() => _loading = false);
      return;
    }

    for (final file in files) {
      final bytes = await readVideoBytesImpl(file);
      if (bytes == null) continue;

      final name = file is Map ? (file['name'] as String? ?? 'video') : (file as dynamic).name?.toString() ?? 'video';

      _uploadProgressNotifiers.putIfAbsent(name, () => ValueNotifier<double>(0));
      _uploadStatusNotifiers.putIfAbsent(name, () => ValueNotifier<String>('Uploading...'));

      try {
        final videoId = await uploader.uploadResumable(
          videoBytes: bytes,
          title: name,
          description: 'Uploaded via Flutter web app',
          onProgress: (progress) => _uploadProgressNotifiers[name]?.value = progress,
        );

        if (videoId != null) {
          _uploadStatusNotifiers[name]?.value = 'Uploaded';
        } else {
          _uploadStatusNotifiers[name]?.value = 'Failed';
        }
      } catch (e) {
        _uploadStatusNotifiers[name]?.value = 'Failed: $e';
      }
    }

    setState(() => _loading = false);
  }

  Future<void> _uploadSelectedVideos() async {
    if (widget.accessToken == null) {
      _showSnackBar('No access token. Please sign in again.');
      return;
    }
    if (_selectedVideos.isEmpty) {
      _showSnackBar('Select at least one video first.');
      return;
    }
    setState(() => _loading = true);

    final channelId = widget.channelId ?? '';
    final uploader = YouTubeUploader(widget.accessToken!, selectedChannelId: channelId);

    for (final asset in _selectedVideos) {
      if (_uploadedVideoIds.contains(asset.id)) continue;

      _initNotifiersForVideo(asset.id);
      _uploadStatusNotifiers[asset.id]?.value = 'Uploading...';
      _uploadProgressNotifiers[asset.id]?.value = 0;

      final file = await asset.file;
      if (file == null) {
        _uploadStatusNotifiers[asset.id]?.value = 'Failed (No file)';
        continue;
      }

      final name = file.path.split('/').last;
      final bytes = await file.readAsBytes();

      try {
        final videoId = await uploader.uploadResumable(
          videoBytes: bytes,
          title: name,
          description: 'Uploaded via Flutter app',
          onProgress: (progress) => _uploadProgressNotifiers[asset.id]?.value = progress,
        );

        if (videoId != null) {
          _uploadStatusNotifiers[asset.id]?.value = 'Uploaded';
          _uploadedVideoIds.add(asset.id);
await _storage.write(key: 'uploadedVideoIds', value: jsonEncode(_uploadedVideoIds.toList()));
          await _recordUpload();
        } else {
          _uploadStatusNotifiers[asset.id]?.value = 'Failed';
        }
      } catch (e) {
        _uploadStatusNotifiers[asset.id]?.value = 'Failed: $e';
      }
    }

    setState(() {
      _loading = false;
      _selectedVideos.clear();
    });
  }

  Widget _buildDrawer() {
    return Drawer(
      child: Column(
        children: [
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(color: Colors.black87),
            accountName: Text(
              widget.userDisplayName.isNotEmpty ? widget.userDisplayName : 'User',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            accountEmail: Text(widget.userEmail),
            currentAccountPicture: CircleAvatar(
              backgroundImage: widget.userPhotoUrl.isNotEmpty
                  ? NetworkImage(widget.userPhotoUrl)
                  : null,
              child: widget.userPhotoUrl.isEmpty ? const Icon(Icons.person, size: 40) : null,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.today),
            title: const Text("Today's Uploads"),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$_todayUploadCount',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload),
            title: const Text('Total Uploads'),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blueGrey,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_uploadedVideoIds.length}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const Spacer(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () async {
              await googleSignIn.signOut();
              if (!context.mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => MainShell()),
                (_) => false,
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Version 0.0.1',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridItem(AssetEntity video) {
    final isSelected = _selectedVideos.contains(video);
    final onYoutube = _isOnYoutube(video);

    _initNotifiersForVideo(video.id);

    return GestureDetector(
      onTap: () => _toggleSelect(video),
      child: Stack(
        children: [
          FutureBuilder<Uint8List?>(
            future: _safeThumbnail(video),
            builder: (_, snap) => snap.hasData
                ? Image.memory(snap.data!, fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                : Container(color: Colors.grey[300]),
          ),
          if (onYoutube)
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                color: Colors.orange,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: const Text('On YouTube', style: TextStyle(color: Colors.white, fontSize: 9)),
              ),
            ),
          if (isSelected && !onYoutube)
            Container(
              decoration: BoxDecoration(
                color: Colors.black38,
                border: Border.all(color: Colors.greenAccent, width: 3),
              ),
            ),
          if (!onYoutube)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: _uploadProgressNotifiers[video.id]!,
                    builder: (_, progress, __) => progress > 0
                        ? LinearProgressIndicator(value: progress)
                        : const SizedBox.shrink(),
                  ),
                  ValueListenableBuilder<String>(
                    valueListenable: _uploadStatusNotifiers[video.id]!,
                    builder: (_, status, __) => status.isNotEmpty
                        ? Container(
                            color: Colors.black54,
                            padding: const EdgeInsets.all(2),
                            child: Text(status, style: const TextStyle(color: Colors.white, fontSize: 10)),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _buildDrawer(),
      appBar: AppBar(
        title: _syncingYoutube
            ? const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Library'),
                  SizedBox(width: 8),
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Library', style: TextStyle(fontSize: 18)),
                  if (_currentHeaderDate.isNotEmpty)
                    Text(_currentHeaderDate, style: TextStyle(fontSize: 13, color: Colors.grey[400])),
                ],
              ),
        actions: [
          if (!kIsWeb) IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchVideos),
          if (!kIsWeb) IconButton(icon: const Icon(Icons.select_all), onPressed: _selectAll),
          if (!kIsWeb) IconButton(icon: const Icon(Icons.check_box), onPressed: _markSelectedAsUploaded),
          IconButton(
            icon: const Icon(Icons.cloud_upload, color: Colors.black),
            onPressed: _loading
                ? null
                : () {
                    if (kIsWeb) {
                      _uploadSelectedVideosWeb();
                    } else {
                      _uploadSelectedVideos();
                    }
                  },
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: kIsWeb
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Pick & Upload Videos'),
                  onPressed: _loading ? null : _uploadSelectedVideosWeb,
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: ListView(
                    children: _uploadProgressNotifiers.keys.map((fileName) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(fileName, style: const TextStyle(color: Colors.white)),
                          ValueListenableBuilder<double>(
                            valueListenable: _uploadProgressNotifiers[fileName]!,
                            builder: (_, progress, __) =>
                                LinearProgressIndicator(value: progress, minHeight: 5),
                          ),
                          ValueListenableBuilder<String>(
                            valueListenable: _uploadStatusNotifiers[fileName]!,
                            builder: (_, status, __) => Text(status,
                                style: const TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                          const SizedBox(height: 10),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ],
            )
          : _videos.isEmpty
              ? Center(
                  child: _syncingYoutube
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('Syncing with YouTube...', style: TextStyle(color: Colors.grey)),
                          ],
                        )
                      : const CircularProgressIndicator(),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _videos.length,
                  itemBuilder: (_, i) => _buildGridItem(_videos[i]),
                ),
    );
  }
}
