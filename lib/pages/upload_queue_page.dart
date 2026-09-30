import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:intl/intl.dart';
import 'package:fluttertoast/fluttertoast.dart';

import '../youtube_uploader.dart';
import '../services/upload_scheduler.dart';
import '../services/account_manager.dart';
import '../services/telegram_service.dart';
import '../services/folder_store.dart';
import 'folder_strip.dart';
import 'reel_player_page.dart';

class UploadQueuePage extends StatefulWidget {
  final UploadScheduler scheduler;
  final AccountManager accountManager;
  final String? accessToken;
  final TelegramService? telegramService;
  final FolderStore? folderStore;

  /// The infinite-scroll loop mounts a second copy of this page as its end
  /// sentinel. That copy shares the scheduler but must never claim jobs —
  /// otherwise both copies run an upload at once over one Telegram socket.
  final bool isSentinel;

  const UploadQueuePage({
    Key? key,
    required this.scheduler,
    required this.accountManager,
    this.accessToken,
    this.telegramService,
    this.folderStore,
    this.isSentinel = false,
  }) : super(key: key);

  @override
  State<UploadQueuePage> createState() => _UploadQueuePageState();
}

class _UploadQueuePageState extends State<UploadQueuePage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;
  bool _isUploading = false;
  bool _isDisposed = false;
  List<AssetEntity> _galleryVideos = [];
  Set<AssetEntity> _selectedForQueue = {};
  bool _showPicker = true;
  final ScrollController _scrollCtrl = ScrollController();
  final ScrollController _queueScrollCtrl = ScrollController();
  ValueNotifier<String?> _headerDateNotifier = ValueNotifier(null);
  int _localTabIndex = 0;

  /// The Local page sits inside a `PageView`, so its element can be rebuilt
  /// from scratch whenever the shell refreshes — and then the grid comes back
  /// at the top even though the user had scrolled halfway down. These live
  /// outside the State so the new element can pick the position back up.
  /// Only the real page (never the infinite-scroll sentinel) records state.
  static double _savedGridOffset = 0;
  static double _savedQueueOffset = 0;
  static int _savedTabIndex = 0;
  static bool _savedShowPicker = true;

  bool _gridRestored = false;
  bool _queueRestored = false;

  /// Folder the picker grid is filtered to, or `null` for everything.
  String? _selectedFolderId;

  @override
  void initState() {
    super.initState();
    if (!widget.isSentinel) {
      _localTabIndex = _savedTabIndex;
      _showPicker = _savedShowPicker;
    }
    WidgetsBinding.instance.addObserver(this);
    widget.scheduler.addListener(_onSchedulerChanged);
    widget.telegramService?.addListener(_onTelegramChanged);
    widget.folderStore?.addListener(_onFoldersChanged);
    _scrollCtrl.addListener(_onGridScrolled);
    _queueScrollCtrl.addListener(_onQueueScrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateCurrentMonth();
      // Deleting a copy in the official Telegram app is invisible to us
      // until something asks Telegram about it — do that once the page is
      // up rather than waiting for the user to visit the Telegram tab.
      _requestBadgeCheck();
    });
    _restoreScrollPosition();
    _loadGallery();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _requestBadgeCheck();
  }

  void _onFoldersChanged() {
    if (_isDisposed) return;
    if (_selectedFolderId != null &&
        widget.folderStore?.byId(_selectedFolderId) == null) {
      _selectedFolderId = null;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    widget.scheduler.removeListener(_onSchedulerChanged);
    widget.telegramService?.removeListener(_onTelegramChanged);
    widget.folderStore?.removeListener(_onFoldersChanged);
    _scrollCtrl.removeListener(_onGridScrolled);
    _queueScrollCtrl.removeListener(_onQueueScrolled);
    _scrollCtrl.dispose();
    _queueScrollCtrl.dispose();
    _headerDateNotifier.dispose();
    super.dispose();
  }

  void _onGridScrolled() {
    _updateCurrentMonth();
    if (widget.isSentinel || !_scrollCtrl.hasClients) return;
    _savedGridOffset = _scrollCtrl.offset;
  }

  void _onQueueScrolled() {
    if (widget.isSentinel || !_queueScrollCtrl.hasClients) return;
    _savedQueueOffset = _queueScrollCtrl.offset;
  }

  /// Puts the user back where they were, but only once the list it applies to
  /// actually exists — jumping any earlier would clamp against a zero extent
  /// and immediately lose the position again.
  void _restoreScrollPosition() {
    if (widget.isSentinel || !mounted) return;
    // Only bother for the list that is actually on screen; a controller with
    // no clients would silently swallow the jump and mark it as done.
    final needGrid = !_gridRestored && _showPicker;
    final needQueue = !_queueRestored && !_showPicker;
    if (!needGrid && !needQueue) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.isSentinel) return;

      if (!_gridRestored &&
          _showPicker &&
          _scrollCtrl.hasClients &&
          _galleryVideos.isNotEmpty) {
        _gridRestored = true;
        final target = _savedGridOffset;
        final max = _scrollCtrl.position.maxScrollExtent;
        if (target > 0 && max > 0) {
          _scrollCtrl.jumpTo(target > max ? max : target);
        }
      }

      if (!_queueRestored && !_showPicker && _queueScrollCtrl.hasClients) {
        _queueRestored = true;
        final target = _savedQueueOffset;
        final max = _queueScrollCtrl.position.maxScrollExtent;
        if (target > 0 && max > 0) {
          _queueScrollCtrl.jumpTo(target > max ? max : target);
        }
      }
    });
  }

  /// Switching between the gallery grid and the queue list tears down the
  /// list that is going away, so its counterpart has to be re-restored when
  /// it comes back instead of staying marked as done.
  void _setShowPicker(bool value) {
    if (!widget.isSentinel) _savedShowPicker = value;
    setState(() => _showPicker = value);
    _gridRestored = false;
    _queueRestored = false;
    _restoreScrollPosition();
  }

  void _setLocalTabIndex(int index) {
    if (!widget.isSentinel) _savedTabIndex = index;
    // An empty tab replaces the grid with a spinner, which drops the
    // position — so the next grid build has to put it back.
    _gridRestored = false;
    setState(() => _localTabIndex = index);
    _restoreScrollPosition();
  }

  /// The Telegram page re-syncs history whenever it loads or refreshes, and
  /// coming back to the app is the other moment deletions happen. Both must
  /// re-check uploads against Telegram so the Local TG badge reflects what is
  /// really still there instead of what was true when the job completed.
  int _lastCheckedSyncGeneration = -1;
  bool _verifyingBadges = false;
  bool _tgRestoreAttempted = false;
  DateTime _lastBadgeCheck = DateTime.fromMillisecondsSinceEpoch(0);

  void _onTelegramChanged() {
    if (!mounted) return;
    setState(() {});
    final tel = widget.telegramService;
    if (tel == null || widget.isSentinel) return;
    // Only a fresh history sync carries new facts; other notifications
    // (connect, thumbnail cache) must not turn into network traffic.
    if (tel.syncGeneration != _lastCheckedSyncGeneration) {
      _requestBadgeCheck(force: true);
    }
  }

  /// [force] bypasses the cooldown, used when something actually changed.
  void _requestBadgeCheck({bool force = false}) {
    if (!mounted || widget.isSentinel) return;
    if (widget.telegramService == null) return;
    if (!force &&
        DateTime.now().difference(_lastBadgeCheck) <
            const Duration(seconds: 15)) {
      return;
    }
    _verifyTelegramBadges(widget.telegramService!);
  }

  Future<void> _verifyTelegramBadges(TelegramService tel) async {
    if (_verifyingBadges) return;
    _verifyingBadges = true;
    _lastBadgeCheck = DateTime.now();
    try {
      // The Telegram page is what usually restores the session, but the Local
      // page has to be able to verify on its own — otherwise the badge can
      // only ever clear after the user has visited that other tab.
      if (!tel.isAuthenticated && !_tgRestoreAttempted) {
        _tgRestoreAttempted = true;
        try {
          await tel.tryRestoreSession();
        } catch (e) {
          debugPrint('Telegram badge check: session restore failed: $e');
        }
      }
      if (!tel.isAuthenticated) return;

      final jobs = widget.scheduler.jobs
          .where((j) => j.status == JobStatus.completed && j.uploadedToTelegram)
          .toList();
      if (jobs.isEmpty) return;

      final probes = [
        for (final j in jobs)
          TelegramUploadProbe(
            key: j.id,
            messageId: int.tryParse(j.telegramMessageId ?? ''),
            title: j.title,
          ),
      ];

      final verdict = await tel.verifyUploads(probes);
      // null = nothing could be verified; keep whatever we already knew
      // instead of handing every badge back.
      if (verdict == null) return;
      _lastCheckedSyncGeneration = tel.syncGeneration;
      widget.scheduler.applyTelegramVerdict(
        present: verdict.present,
        absent: verdict.absent,
      );
    } catch (e) {
      debugPrint('Telegram badge check failed: $e');
    } finally {
      _verifyingBadges = false;
    }
  }

  void _onSchedulerChanged() {
    if (!mounted) return;
    setState(() {});
    // Deferred: scheduler notifications fire synchronously from inside
    // claimNext()/markFailed(), which used to re-enter _processNextIfNeeded()
    // before _isUploading was set and started every pending job at once.
    scheduleMicrotask(() {
      if (mounted) _processNextIfNeeded();
    });
  }

  Future<void> _loadGallery() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) return;
    List<AssetEntity> all = [];
    for (final type in [RequestType.image, RequestType.video, RequestType.audio]) {
      final albums = await PhotoManager.getAssetPathList(type: type);
      for (final album in albums) {
        all.addAll(await album.getAssetListPaged(page: 0, size: 500));
      }
    }
    if (mounted) {
      final videos = {for (final v in all) v.id: v}.values.toList();
      videos.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      setState(() {
        _galleryVideos = videos;
        _thumbnailCache.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateCurrentMonth());
      _restoreScrollPosition();
      _requestBadgeCheck();
    }
    _processNextIfNeeded();
  }

  Future<void> _addSelectedToQueue({UploadDestination destination = UploadDestination.youtube}) async {
    if (_selectedForQueue.isEmpty) return;

    final channelId = widget.accountManager.selectedChannelId;
    final email = widget.accountManager.currentAccount?.email ?? '';
    final now = DateTime.now();
    final titleFmt = DateFormat('dd MMMM yyyy HH:mm');
    final filtered = _selectedForQueue.where((v) {
      for (final j in widget.scheduler.jobs) {
        if (v.id == j.assetId && j.status != JobStatus.completed) return false;
        if (v.id == j.assetId && j.status == JobStatus.completed) return false;
      }
      return true;
    }).toList();
    if (filtered.isEmpty) return;
    final items = filtered;

    final entries = <Map<String, String>>[];
    for (int i = 0; i < items.length; i++) {
      final v = items[i];
      final file = await v.file;
      final ts = now.add(Duration(minutes: i));
      entries.add({
        'assetId': v.id,
        'title': titleFmt.format(ts),
        if (file != null) 'filePath': file.path,
      });
    }

    await widget.scheduler.addJobs(entries, channelId, email, destination: destination);

    setState(() => _selectedForQueue.removeWhere((v) => filtered.contains(v)));
  }

  Future<void> _deleteSelected() async {
    if (_selectedForQueue.isEmpty) return;
    final count = _selectedForQueue.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Delete videos?',
            style: TextStyle(color: Colors.white)),
        content: Text('Move $count video$count to Trash?',
            style: TextStyle(color: Colors.grey[400])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Move to Trash', style: TextStyle(color: Colors.red[300])),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final ids = _selectedForQueue.map((v) => v.id).toList();
    await PhotoManager.editor.deleteWithIds(ids);
    setState(() {
      _galleryVideos.removeWhere((v) => _selectedForQueue.contains(v));
      _selectedForQueue.clear();
    });
  }

  bool get _hasNonVideo =>
      _selectedForQueue.any((a) => a.type == AssetType.image);

  Future<void> _handleAddToQueue() async {
    final tel = widget.telegramService;
    if (tel == null) {
      await _addSelectedToQueue(destination: UploadDestination.youtube);
      return;
    }
    final defaultDest = await TelegramService.getDefaultDestination();
    final mixed = _hasNonVideo;

    if (defaultDest == UploadDestination.telegram) {
      await _addSelectedToQueue(destination: UploadDestination.telegram);
      Fluttertoast.showToast(msg: 'Added to Telegram queue');
      return;
    }

    if (defaultDest == UploadDestination.both && !mixed) {
      await _addSelectedToQueueForBoth();
      Fluttertoast.showToast(msg: 'Added to YouTube + Telegram queue');
      return;
    }

    if (defaultDest == UploadDestination.youtube && !mixed) {
      await _addSelectedToQueue(destination: UploadDestination.youtube);
      return;
    }

    final dest = await _showDestinationPicker(mixed);
    if (dest != null) {
      await _addSelectedToQueue(destination: dest);
    }
  }

  Future<UploadDestination?> _showDestinationPicker(bool mixed) async {
    return showDialog<UploadDestination>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Upload Destination', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _destOption(ctx, UploadDestination.youtube, mixed),
            const SizedBox(height: 8),
            _destOption(ctx, UploadDestination.telegram, false),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _destOption(BuildContext ctx, UploadDestination dest, bool disabled) {
    final icons = {UploadDestination.youtube: Icons.videocam, UploadDestination.telegram: Icons.telegram};
    final labels = {UploadDestination.youtube: 'YouTube', UploadDestination.telegram: 'Telegram Saved Messages'};
    return Opacity(
      opacity: disabled ? 0.4 : 1.0,
      child: ListTile(
        leading: Icon(icons[dest], color: disabled ? Colors.grey : Colors.white),
        title: Text(labels[dest]!, style: TextStyle(color: disabled ? Colors.grey : Colors.white)),
        subtitle: disabled ? const Text('Not available for images/files', style: TextStyle(color: Colors.grey, fontSize: 11)) : null,
        enabled: !disabled,
        onTap: disabled ? null : () => Navigator.pop(ctx, dest),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        tileColor: Colors.grey[850],
      ),
    );
  }

  Future<void> _addSelectedToQueueForBoth() async {
    await _addSelectedToQueue(destination: UploadDestination.telegram);
    await _addSelectedToQueue(destination: UploadDestination.youtube);
  }

  Future<void> _processNextIfNeeded() async {
    if (widget.isSentinel) return;
    if (_isUploading) return;
    // Claim the flag before claimNext(): it notifies listeners synchronously,
    // which re-enters this method and would claim every pending job at once.
    _isUploading = true;
    final job = widget.scheduler.claimNext();
    if (job == null) {
      _isUploading = false;
      return;
    }

    try {
      File? file;

      final asset = _findAsset(job.assetId);
      if (asset != null) {
        file = await asset.file;
      }

      if (file == null && job.filePath != null) {
        final f = File(job.filePath!);
        if (f.existsSync()) file = f;
      }

      if (file == null) {
        await widget.scheduler.markFailed(job.id, 'File not accessible');
        _isUploading = false;
        _processNextIfNeeded();
        return;
      }

      if (job.destination == UploadDestination.telegram) {
        final tel = widget.telegramService;
        if (tel == null) {
          await widget.scheduler.markFailed(job.id, 'Telegram not configured');
          _isUploading = false;
          _processNextIfNeeded();
          return;
        }
        final tgCaption = job.folder != null && job.folder!.isNotEmpty
            ? '#${job.folder!.replaceAll(' ', '_')}\n${job.title}'
            : job.title;
        final result = await tel.uploadToSavedMessages(
          file.path,
          caption: tgCaption,
          onStatus: (msg) => widget.scheduler.setStatusMessage(job.id, msg),
          videoWidth: asset?.width ?? 0,
          videoHeight: asset?.height ?? 0,
          videoDuration: asset?.duration ?? 0,
        );
        // Record the real message id so the TG badge can later be verified
        // against Telegram instead of being trusted forever. Only a numeric
        // id is usable — dumping the raw RPC result here would leave a value
        // that can never be probed, forcing every upload onto caption search.
        final sentId = TelegramService.extractSentMessageId(result);
        await widget.scheduler.markCompleted(
          job.id,
          telegramMessageId: sentId?.toString() ?? '',
        );
        widget.scheduler.clearDeletedOnTelegram(job.id);
      } else {
        final token = widget.accessToken;
        if (token == null) {
          await widget.scheduler.markFailed(job.id, 'Not signed in');
          _isUploading = false;
          _processNextIfNeeded();
          return;
        }

        final uploader = YouTubeUploader(token, selectedChannelId: job.channelId);
        final bytes = await file.readAsBytes();

        final videoId = await uploader.uploadResumable(
          videoBytes: bytes,
          title: job.title,
          description: 'Uploaded via Flutter app',
          onProgress: (p) => widget.scheduler.markProgress(job.id, p),
        );

        if (videoId != null && job.folder != null && job.folder!.isNotEmpty) {
          try {
            widget.scheduler.setStatusMessage(job.id, 'Adding to folder "${job.folder}"…');
            await uploader.addVideoToPlaylist(videoId, job.folder!);
          } catch (_) {
            // Folder creation is best-effort
          }
        }

        await widget.scheduler.markCompleted(job.id, youtubeVideoId: videoId ?? '');
      }
    } catch (e) {
      await widget.scheduler.markFailed(job.id, _friendlyError(e));
    }

    _isUploading = false;
    _processNextIfNeeded();
  }

  String _friendlyError(Object e) {
    const prefix = 'Bad state: ';
    final s = e.toString();
    return s.startsWith(prefix) ? s.substring(prefix.length) : s;
  }

  AssetEntity? _findAsset(String assetId) {
    for (final v in _galleryVideos) {
      if (v.id == assetId) return v;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_showPicker) return _buildPickerView();
    return _buildQueueView();
  }

  final Map<String, Future<Uint8List?>> _thumbnailCache = {};

  /// Memoized: the grid passes this into a FutureBuilder, and rebuilding with
  /// a fresh future re-requested every thumbnail on each scheduler notification.
  Future<Uint8List?> _safeThumbnail(AssetEntity video) =>
      _thumbnailCache.putIfAbsent(video.id, () => _loadThumbnail(video));

  Future<Uint8List?> _loadThumbnail(AssetEntity video) async {
    if (_isDisposed) return null;
    try {
      final data = await video.thumbnailDataWithSize(const ThumbnailSize(300, 420));
      if (_isDisposed) return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  void _updateCurrentMonth() {
    if (!_scrollCtrl.hasClients || _galleryVideos.isEmpty) return;
    final viewportWidth = MediaQuery.of(context).size.width;
    const crossAxisCount = 3;
    const crossAxisSpacing = 6.0;
    const mainAxisSpacing = 6.0;
    const padding = 16.0;
    final availableWidth = viewportWidth - padding;
    final itemWidth = (availableWidth - (crossAxisCount - 1) * crossAxisSpacing) / crossAxisCount;
    final itemHeight = itemWidth / 0.7;
    final rowHeight = itemHeight + mainAxisSpacing;
    final totalRows = (_galleryVideos.length / crossAxisCount).ceil();
    if (totalRows == 0) return;
    final offset = _scrollCtrl.offset;
    final row = (offset / rowHeight).floor().clamp(0, totalRows - 1);
    final index = (row * crossAxisCount).clamp(0, _galleryVideos.length - 1);
    final video = _galleryVideos[index];
    final dateStr = DateFormat('MMM d yyyy').format(video.createDateTime);
    if (_headerDateNotifier.value != dateStr) {
      _headerDateNotifier.value = dateStr;
    }
  }

  Widget _buildPickerView() {
    final alreadyInQueue = <String>{};
    final alreadyUploaded = <String>{};
    final uploadedToYoutube = <String>{};
    final uploadedToTelegram = <String>{};
    for (final j in widget.scheduler.jobs) {
      if (j.status != JobStatus.completed) {
        alreadyInQueue.add(j.assetId);
      } else {
        alreadyUploaded.add(j.assetId);
        if (j.uploadedToYoutube) uploadedToYoutube.add(j.assetId);
        if (widget.scheduler.isOnTelegram(j)) uploadedToTelegram.add(j.assetId);
      }
    }

    final folderIds = widget.folderStore
        ?.filterIds(FolderScope.local, _selectedFolderId);
    final inFolder = folderIds == null
        ? _galleryVideos
        : _galleryVideos.where((v) => folderIds.contains(v.id)).toList();

    final filtered = inFolder.where((v) {
      if (_localTabIndex == 0) return v.type == AssetType.video;
      if (_localTabIndex == 1) return v.type == AssetType.image;
      return v.type == AssetType.audio || v.type == AssetType.other;
    }).toList();

    final inSelectedFolder = _selectedFolderId != null;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: ValueListenableBuilder<String?>(
          valueListenable: _headerDateNotifier,
          builder: (_, dateStr, __) => Text(
            dateStr != null ? 'Local - $dateStr' : 'Local',
          ),
        ),
        actions: [
          if (widget.folderStore != null && _selectedForQueue.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.folder, color: Colors.amber),
              tooltip: 'Move to folder',
              onPressed: () => showMoveToFolderSheet(
                context,
                store: widget.folderStore!,
                scope: FolderScope.local,
                itemIds: [for (final a in _selectedForQueue) a.id],
              ),
            ),
          if (_selectedForQueue.where((v) => !alreadyInQueue.contains(v.id) && !alreadyUploaded.contains(v.id)).isNotEmpty)
            TextButton(
              onPressed: () async {
                await _handleAddToQueue();
                _setShowPicker(false);
              },
              child: Text('Add ${_selectedForQueue.where((v) => !alreadyInQueue.contains(v.id) && !alreadyUploaded.contains(v.id)).length} to Queue'),
            ),
          if (_selectedForQueue.isNotEmpty)
            IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.red[300]),
              onPressed: () => _deleteSelected(),
            ),
          IconButton(
            icon: const Icon(Icons.queue_rounded),
            onPressed: () => _setShowPicker(false),
          ),
        ],
      ),
      body: _galleryVideos.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  padding: EdgeInsets.fromLTRB(12, MediaQuery.of(context).padding.top + kToolbarHeight + 4, 12, 4),
                  child: Row(
                    children: [
                      _buildLocalTab(0, 'Videos', inFolder.where((v) => v.type == AssetType.video).length, Icons.videocam),
                      const SizedBox(width: 8),
                      _buildLocalTab(1, 'Images', inFolder.where((v) => v.type == AssetType.image).length, Icons.image),
                      const SizedBox(width: 8),
                      _buildLocalTab(2, 'Files', inFolder.where((v) => v.type == AssetType.audio || v.type == AssetType.other).length, Icons.insert_drive_file),
                    ],
                  ),
                ),
                if (widget.folderStore != null)
                  FolderStrip(
                    store: widget.folderStore!,
                    scope: FolderScope.local,
                    selectedId: _selectedFolderId,
                    onSelected: (id) => setState(() {
                      _selectedFolderId = id;
                      _selectedForQueue.clear();
                    }),
                  ),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                  inSelectedFolder
                                      ? Icons.folder_open
                                      : Icons.perm_media,
                                  size: 48,
                                  color: Colors.grey[600]),
                              const SizedBox(height: 12),
                              Text(
                                inSelectedFolder
                                    ? 'Nothing in this folder yet'
                                    : 'No ${_localTabIndex == 0 ? 'videos' : _localTabIndex == 1 ? 'images' : 'files'} here',
                                style: TextStyle(color: Colors.grey[400]),
                              ),
                              if (inSelectedFolder)
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
                      : GridView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6,
                      childAspectRatio: 0.7),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final v = filtered[i];
                      final selected = _selectedForQueue.contains(v);
                      final inQueue = alreadyInQueue.contains(v.id);
                      final isUploaded = alreadyUploaded.contains(v.id);
                      final onYt = uploadedToYoutube.contains(v.id);
                      final onTg = uploadedToTelegram.contains(v.id);
                      final tile = GestureDetector(
                        onTap: () {
                          if (inQueue) return;
                          setState(() {
                            if (selected) {
                              _selectedForQueue.remove(v);
                            } else {
                              _selectedForQueue.add(v);
                            }
                          });
                        },
                        onDoubleTap: () {
                          if (inQueue) return;
                          // The grid is filtered per tab while the player is
                          // given one list — the index has to come from that
                          // exact list or the reel opens on a photo/audio file
                          // and spins forever.
                          if (v.type != AssetType.video) return;
                          final reel = filtered
                              .where((x) => x.type == AssetType.video)
                              .toList();
                          final reelIndex = reel.indexOf(v);
                          if (reelIndex < 0) return;
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ReelPlayerPage(
                                videos: reel,
                                initialIndex: reelIndex,
                              ),
                            ),
                          );
                        },
                        child: Stack(
                          children: [
                            FutureBuilder<Uint8List?>(
                              future: _safeThumbnail(v),
                              builder: (_, snap) => snap.hasData
                                  ? Image.memory(snap.data!, fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                                  : Container(color: Colors.grey[800]),
                            ),
                            if (inQueue)
                              Positioned(
                                top: 4, left: 4,
                                child: Container(
                                  color: Colors.blueGrey,
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  child: const Text('In Queue', style: TextStyle(color: Colors.white, fontSize: 8)),
                                ),
                              ),
                            if (isUploaded)
                              Positioned(
                                top: 4, left: 4,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (onYt)
                                      Container(
                                        color: Colors.red,
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                        child: const Text('YT', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                                      ),
                                    if (onTg)
                                      Container(
                                        color: Colors.blue,
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                        child: const Text('TG', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                                      ),
                                  ],
                                ),
                              ),
                            if (selected && !inQueue)
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.black38,
                                  border: Border.all(color: Colors.greenAccent, width: 3),
                                ),
                                child: Center(
                                  child: Icon(Icons.check_circle, color: Colors.greenAccent, size: 30),
                                ),
                              ),
                          ],
                        ),
                      );
                      return LongPressDraggable<List<String>>(
                        data: selected
                            ? [for (final a in _selectedForQueue) a.id]
                            : [v.id],
                        feedback: Material(
                          color: Colors.transparent,
                          child: Container(
                            width: 92,
                            height: 116,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.green.shade700
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
              ],
            ),
    );
  }

  Widget _buildLocalTab(int index, String label, int count, IconData icon) {
    final selected = _localTabIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _setLocalTabIndex(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.green : Colors.grey[900],
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

  String _statusLabel(JobStatus s) {
    switch (s) {
      case JobStatus.pending: return 'Pending';
      case JobStatus.uploading: return 'Uploading';
      case JobStatus.completed: return 'Completed';
      case JobStatus.failed: return 'Failed';
      case JobStatus.scheduled: return 'Scheduled';
    }
  }

  Color _statusColor(JobStatus s) {
    switch (s) {
      case JobStatus.pending: return Colors.orange;
      case JobStatus.uploading: return Colors.blue;
      case JobStatus.completed: return Colors.green;
      case JobStatus.failed: return Colors.red;
      case JobStatus.scheduled: return Colors.blueGrey;
    }
  }

  IconData _statusIcon(JobStatus s) {
    switch (s) {
      case JobStatus.pending: return Icons.hourglass_empty;
      case JobStatus.uploading: return Icons.cloud_upload;
      case JobStatus.completed: return Icons.check_circle;
      case JobStatus.failed: return Icons.error;
      case JobStatus.scheduled: return Icons.schedule;
    }
  }

  Widget _buildQueueView() {
    final ytToday = widget.scheduler.todayYoutubeCount;
    final tgToday = widget.scheduler.todayTelegramCount;
    final all = widget.scheduler.jobs;
    final active = all.where((j) => j.status == JobStatus.pending || j.status == JobStatus.uploading).toList();
    final scheduled = widget.scheduler.scheduledJobs.toList();
    final completed = widget.scheduler.completedJobs.toList();
    final failed = widget.scheduler.failedJobs.toList();

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(widget.telegramService != null && widget.scheduler.jobs.any((j) => j.destination == UploadDestination.telegram)
            ? 'Queue (Telegram)'
            : 'Upload Queue'),
        actions: [
          if (all.where((j) => j.status == JobStatus.pending || j.status == JobStatus.scheduled).isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.play_arrow, color: Colors.green),
              tooltip: 'Resume/Schedule uploads',
              onSelected: (action) {
                if (action == 'resume_all') {
                  for (final j in all.where((j) => j.status == JobStatus.pending)) {
                    widget.scheduler.resumePending(j.id);
                  }
                  _processNextIfNeeded();
                } else if (action == 'resume_scheduled') {
                  for (final j in all.where((j) => j.status == JobStatus.scheduled)) {
                    widget.scheduler.resumePending(j.id);
                  }
                  _processNextIfNeeded();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'resume_all', child: Text('Resume pending')),
                const PopupMenuItem(value: 'resume_scheduled', child: Text('Resume scheduled')),
              ],
            ),
          if (failed.isNotEmpty)
            IconButton(icon: const Icon(Icons.refresh), onPressed: () => widget.scheduler.retryAllFailed()),
          IconButton(
            icon: const Icon(Icons.photo_library),
            onPressed: () {
              _loadGallery();
              _setShowPicker(true);
            },
          ),
        ],
      ),
      body: all.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_upload_outlined, size: 64, color: Colors.grey[600]),
                  const SizedBox(height: 16),
                  Text('Queue is empty', style: TextStyle(color: Colors.grey[400], fontSize: 18)),
                  const SizedBox(height: 8),
                  Text('Tap + to select videos', style: TextStyle(color: Colors.grey[600])),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Local'),
                    onPressed: () {
                      _loadGallery();
                      _setShowPicker(true);
                    },
                  ),
                ],
              ),
            )
          : ListView(
              controller: _queueScrollCtrl,
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
                left: 12, right: 12, bottom: 12),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.videocam, color: Colors.red, size: 18),
                          const SizedBox(width: 8),
                          Text('YouTube Today', style: TextStyle(color: Colors.grey[300], fontSize: 13)),
                          const Spacer(),
                          Text('$ytToday/${UploadScheduler.youtubeDailyLimit}',
                              style: TextStyle(color: Colors.grey[300], fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: ytToday / UploadScheduler.youtubeDailyLimit),
                        duration: const Duration(milliseconds: 500),
                        builder: (_, v, __) => ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: v,
                            minHeight: 5,
                            backgroundColor: Colors.grey[800],
                            color: ytToday >= UploadScheduler.youtubeDailyLimit ? Colors.red : Colors.red,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.telegram, color: Colors.blue, size: 18),
                          const SizedBox(width: 8),
                          Text('Telegram Today', style: TextStyle(color: Colors.grey[300], fontSize: 13)),
                          const Spacer(),
                          Text('$tgToday',
                              style: TextStyle(color: Colors.grey[300], fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: tgToday > 0 ? 1.0 : 0.0),
                        duration: const Duration(milliseconds: 500),
                        builder: (_, v, __) => ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: v,
                            minHeight: 5,
                            backgroundColor: Colors.grey[800],
                            color: Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                if (active.isNotEmpty) ...[
                  Text('Active', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...active.map((job) => _buildJobTile(job)),
                  const SizedBox(height: 16),
                ],

                if (scheduled.isNotEmpty) ...[
                  Text('Scheduled', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...scheduled.map((job) => _buildJobTile(job)),
                  const SizedBox(height: 16),
                ],

                if (failed.isNotEmpty) ...[
                  Text('Failed', style: TextStyle(color: Colors.red[400], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...failed.map((job) => _buildJobTile(job)),
                  const SizedBox(height: 16),
                ],

                if (completed.isNotEmpty) ...[
                  Text('Completed', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...completed.take(20).map((job) => _buildJobTile(job)),
                ],
              ],
            ),
    );
  }

  String _channelName(String channelId) {
    final c = widget.accountManager.channels.where((ch) => ch.id == channelId).firstOrNull;
    return c?.title ?? channelId;
  }

  Widget _buildJobTile(UploadJob job) {
    final dateFmt = DateFormat('MMM d, HH:mm');
    return Dismissible(
      key: Key(job.id),
      direction: job.status == JobStatus.pending || job.status == JobStatus.scheduled || job.status == JobStatus.uploading || job.status == JobStatus.failed
          ? DismissDirection.endToStart
          : DismissDirection.none,
      background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white)),
      onDismissed: (_) => widget.scheduler.remove(job.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(_statusIcon(job.status), color: _statusColor(job.status), size: 20),
            const SizedBox(width: 8),
            if (job.uploadedToYoutube)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(3)),
                child: const Text('YT', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
              ),
            if (widget.scheduler.isOnTelegram(job))
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(3)),
                child: const Text('TG', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
              ),
            const SizedBox(width: 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(job.channelId.isNotEmpty ? _channelName(job.channelId) : job.displayName,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  if (job.status == JobStatus.uploading && job.progress > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: LinearProgressIndicator(value: job.progress, minHeight: 3,
                          backgroundColor: Colors.grey[800], color: Colors.blue),
                    ),
                  if (job.status == JobStatus.uploading && job.statusMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(job.statusMessage!,
                          style: TextStyle(color: Colors.grey[400], fontSize: 10),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  if (job.status == JobStatus.scheduled && job.scheduledDate != null)
                    Text('Scheduled: ${job.displayName}',
                        style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                  if (job.status == JobStatus.completed && job.completedAt != null)
                    Text(job.displayName,
                        style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                  if (job.status == JobStatus.failed && job.error != null)
                    Text('${job.displayName} - ${job.error}',
                        style: TextStyle(color: Colors.red[300], fontSize: 10),
                        maxLines: 5, overflow: TextOverflow.ellipsis),
                  if (job.status == JobStatus.pending)
                    Text(job.displayName,
                        style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (job.status == JobStatus.completed && job.completedAt != null)
              Text(dateFmt.format(job.completedAt!),
                  style: TextStyle(color: Colors.grey[500], fontSize: 11))
            else
              Text(_statusLabel(job.status),
                  style: TextStyle(color: _statusColor(job.status), fontSize: 11, fontWeight: FontWeight.w500)),
            if (job.status == JobStatus.failed)
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => widget.scheduler.retry(job.id),
              ),
            if (job.status == JobStatus.scheduled)
              IconButton(
                icon: const Icon(Icons.play_arrow, size: 18, color: Colors.green),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Resume now (skip schedule)',
                onPressed: () {
                  widget.scheduler.resumePending(job.id);
                  _processNextIfNeeded();
                },
              ),
          ],
        ),
      ),
    );
  }
}