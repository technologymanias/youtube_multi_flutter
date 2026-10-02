import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:intl/intl.dart';
import 'package:fluttertoast/fluttertoast.dart';

import '../youtube_uploader.dart';
import '../services/upload_scheduler.dart';
import '../services/media_index.dart';
import '../services/account_manager.dart';
import '../services/telegram_service.dart';
import '../services/youtube_sync.dart';
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

  /// Which slice of the queue is on screen. Static for the same reason as
  /// the scroll offsets: the shell rebuilds this page from scratch whenever
  /// it refreshes, and a fresh element must not dump the user back to page 1.
  static int _savedQueuePage = 0;

  /// Jobs per queue page. One tile is a whole row with badges and progress,
  /// so past a couple of dozen the list stops being scannable anyway — and a
  /// bounded page keeps the eagerly-built `ListView` cheap.
  static const int _queuePageSize = 20;

  int _queuePage = 0;

  bool _gridRestored = false;
  bool _queueRestored = false;

  /// Heartbeat for rolling the upload schedule forward and refreshing the
  /// YT/TG badges while the page is alive.
  Timer? _tick;

  /// Folder the picker grid is filtered to, or `null` for everything.
  String? _selectedFolderId;

  @override
  void initState() {
    super.initState();
    if (!widget.isSentinel) {
      _localTabIndex = _savedTabIndex;
      _showPicker = _savedShowPicker;
      _queuePage = _savedQueuePage;
    }
    WidgetsBinding.instance.addObserver(this);
    widget.scheduler.addListener(_onSchedulerChanged);
    widget.telegramService?.addListener(_onTelegramChanged);
    widget.folderStore?.addListener(_onFoldersChanged);
    _scrollCtrl.addListener(_onGridScrolled);
    _queueScrollCtrl.addListener(_onQueueScrolled);
    if (!widget.isSentinel) {
      _tick = Timer.periodic(const Duration(seconds: 60), (_) => _onTick());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateCurrentMonth();
      // Deleting a copy in the official Telegram app is invisible to us
      // until something asks Telegram about it — do that once the page is
      // up rather than waiting for the user to visit the Telegram tab.
      _requestBadgeCheck();
      _refreshDefaultDestination();
    });
    _restoreScrollPosition();
    _loadGallery();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _requestBadgeCheck();
  }

  /// One heartbeat while the page is alive. Scheduling only used to move
  /// forward on a restart, so a queue left open across midnight would sit on
  /// yesterday's date forever; the badge check rides along because deleted
  /// copies on YouTube or Telegram are invisible until something asks.
  void _onTick() {
    if (!mounted || widget.isSentinel) return;
    widget.scheduler.promoteDueScheduled();
    _requestBadgeCheck();
    // The drawer can flip the default destination while this page is behind
    // it; the queue button's count is derived from it, so keep it current.
    _refreshDefaultDestination();
  }

  /// The long-press path for a multi-selection: one sheet files every picked
  /// tile at once, instead of dragging them onto chips one by one.
  Future<void> _moveSelectionToFolder() async {
    final store = widget.folderStore;
    if (store == null || _selectedForQueue.isEmpty) return;
    await showMoveToFolderSheet(
      context,
      store: store,
      scope: FolderScope.local,
      itemIds: [for (final a in _selectedForQueue) a.id],
      currentFolderId: _selectedFolderId,
    );
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
    _tick?.cancel();
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
    if (value) _refreshDefaultDestination();
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

  /// Moves to another slice of the queue. The saved scroll offset belongs to
  /// the page it was taken on, so it is dropped rather than replayed against
  /// a completely different set of tiles.
  void _gotoQueuePage(int page) {
    if (page == _queuePage) return;
    _queuePage = page;
    if (!widget.isSentinel) _savedQueuePage = page;
    _savedQueueOffset = 0;
    _queueRestored = true;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_queueScrollCtrl.hasClients) _queueScrollCtrl.jumpTo(0);
    });
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
    if (!force &&
        DateTime.now().difference(_lastBadgeCheck) <
            const Duration(seconds: 15)) {
      return;
    }
    _lastBadgeCheck = DateTime.now();
    final tel = widget.telegramService;
    if (tel != null) _verifyTelegramBadges(tel);
    _verifyYoutubeBadges();
  }

  bool _verifyingYoutube = false;

  /// The YouTube half of the badge check: asks the channel which of the
  /// uploads still exist, so a video deleted on YouTube stops wearing the YT
  /// badge on the local grid — the same contract the Telegram check gives the
  /// TG badge.
  Future<void> _verifyYoutubeBadges() async {
    if (_verifyingYoutube || widget.isSentinel) return;
    final token = widget.accessToken;
    if (token == null || token.isEmpty) return;
    _verifyingYoutube = true;
    try {
      final jobs = widget.scheduler.jobs
          .where((j) => j.status == JobStatus.completed && j.uploadedToYoutube)
          .toList();
      if (jobs.isEmpty) return;

      final probes = [
        for (final j in jobs)
          YoutubeUploadProbe(
            key: j.id,
            videoId: j.youtubeVideoId,
            // Tagged form: the probe then searches for the UUID, which is
            // unique, instead of a date title that can collide with others.
            title: j.taggedTitle,
          ),
      ];

      final verdict = await YoutubeSync.verifyUploads(token, probes);
      // null = nothing could be verified; keep whatever we already knew
      // instead of handing every badge back.
      if (verdict == null) return;
      widget.scheduler.applyYoutubeVerdict(
        present: verdict.present,
        absent: verdict.absent,
      );
    } catch (e) {
      debugPrint('YouTube badge check failed: $e');
    } finally {
      _verifyingYoutube = false;
    }
  }

  Future<void> _verifyTelegramBadges(TelegramService tel) async {
    if (_verifyingBadges) return;
    _verifyingBadges = true;
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
            title: j.taggedTitle,
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

  /// Cached so the "Add N to Queue" count can mirror the routing
  /// [_handleAddToQueue] will run without awaiting secure storage inside
  /// build. Refreshed whenever that routing actually reads it.
  UploadDestination _defaultDest = UploadDestination.youtube;

  Future<UploadDestination> _readDefaultDestination() async {
    _defaultDest = await TelegramService.getDefaultDestination();
    return _defaultDest;
  }

  /// Re-reads the stored default and rebuilds only when it actually moved —
  /// the drawer can change it while this page sits behind it.
  Future<void> _refreshDefaultDestination() async {
    final dest = await TelegramService.getDefaultDestination();
    if (!mounted || dest == _defaultDest) return;
    setState(() => _defaultDest = dest);
  }

  /// Whether [job] counts as work for [dest]'s side of the upload. Jobs are
  /// created per destination, but a legacy `both` job covers both.
  static bool _jobCovers(UploadJob job, UploadDestination dest) =>
      job.destination == dest || job.destination == UploadDestination.both;

  /// Whether the copy [job] stands for is still believed to be on [dest].
  /// A completed job whose copy has since been deleted (the badge is cleared
  /// by the verification pass) must never block re-uploading that video.
  bool _jobStillThere(UploadJob job, UploadDestination dest) =>
      dest == UploadDestination.telegram
          ? widget.scheduler.isOnTelegram(job)
          : widget.scheduler.isOnYoutube(job);

  /// Whether [v] can still get a new job for [dest]: nothing in flight on
  /// that side, and either no finished upload there or one whose copy is
  /// gone. Everything about "why didn't my selection upload" comes back to
  /// this predicate, so it is per destination — a video already queued for
  /// Telegram is still fair game for YouTube, and a video deleted from
  /// Telegram is fair game for Telegram again.
  bool _canQueue(AssetEntity v, UploadDestination dest) {
    if (dest == UploadDestination.telegram &&
        widget.telegramService == null) {
      return false;
    }
    // YouTube ingests video only; stills and audio would just fail.
    if (dest == UploadDestination.youtube && v.type != AssetType.video) {
      return false;
    }
    for (final j in widget.scheduler.jobs) {
      if (j.assetId != v.id || !_jobCovers(j, dest)) continue;
      if (j.status != JobStatus.completed) return false;
      if (_jobStillThere(j, dest)) return false;
    }
    return true;
  }

  /// How many of [assets] would really get a job from the routing
  /// [_handleAddToQueue] performs for the current default destination. The
  /// button label has to agree with what happens, or the user counts the
  /// tiles and gets a different number of uploads.
  int _addToQueueCount(Iterable<AssetEntity> assets) {
    if (widget.telegramService == null) {
      return assets.where((v) => _canQueue(v, UploadDestination.youtube)).length;
    }
    switch (_defaultDest) {
      case UploadDestination.telegram:
        return assets
            .where((v) => _canQueue(v, UploadDestination.telegram))
            .length;
      case UploadDestination.youtube:
        // Still files cannot go to YouTube, so that case falls through to
        // the destination dialog whose only live option is Telegram.
        if (assets.any((v) => v.type != AssetType.video)) {
          return assets
              .where((v) => _canQueue(v, UploadDestination.telegram))
              .length;
        }
        return assets
            .where((v) => _canQueue(v, UploadDestination.youtube))
            .length;
      case UploadDestination.both:
        return assets
            .where((v) =>
                _canQueue(v, UploadDestination.youtube) ||
                _canQueue(v, UploadDestination.telegram))
            .length;
    }
  }

  /// Queues [assets] once per entry in [destinations] — separately, because
  /// coverage is per destination and a Telegram job must not disqualify the
  /// same video from going to YouTube.
  ///
  /// Returns how many distinct assets received at least one job.
  Future<int> _addAssetsToQueue(
    List<AssetEntity> assets, {
    required List<UploadDestination> destinations,
    String? folder,
    bool clearSelection = false,
  }) async {
    if (assets.isEmpty || destinations.isEmpty) return 0;

    final channelId = widget.accountManager.selectedChannelId;
    final email = widget.accountManager.currentAccount?.email ?? '';
    final now = DateTime.now();
    final titleFmt = DateFormat('dd MMMM yyyy HH:mm');
    final queued = <String>{};

    for (final destination in destinations) {
      final targets = assets.where((v) => _canQueue(v, destination)).toList();
      if (targets.isEmpty) continue;

      final entries = <Map<String, String>>[];
      for (int i = 0; i < targets.length; i++) {
        final v = targets[i];
        final file = await v.file;
        final ts = now.add(Duration(minutes: i));
        entries.add({
          'assetId': v.id,
          'title': titleFmt.format(ts),
          if (file != null) 'filePath': file.path,
        });
      }

      await widget.scheduler.addJobs(entries, channelId, email,
          destination: destination, folder: folder);
      queued.addAll(targets.map((v) => v.id));
    }

    if (clearSelection && mounted) {
      setState(() => _selectedForQueue.clear());
    }
    return queued.length;
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

  bool _hasNonVideo(Iterable<AssetEntity> assets) =>
      assets.any((a) => a.type != AssetType.video);

  /// Routes [assets] through the app-wide default destination and queues
  /// them there. [folder], when given, tags the jobs so the upload lands in
  /// that folder on both sides (Telegram `#caption`, YouTube playlist) and
  /// the queue row shows where it came from.
  ///
  /// Returns how many assets actually received a job.
  /// [announce] is turned off by callers that show their own, more specific
  /// toast — two back-to-back toasts for one action just talk over each other.
  Future<int> _handleAddToQueue({
    required List<AssetEntity> assets,
    String? folder,
    bool clearSelection = false,
    bool announce = true,
  }) async {
    if (assets.isEmpty) return 0;
    final tel = widget.telegramService;
    if (tel == null) {
      return _addAssetsToQueue(assets,
          destinations: const [UploadDestination.youtube],
          folder: folder,
          clearSelection: clearSelection);
    }
    final defaultDest = await _readDefaultDestination();
    final mixed = _hasNonVideo(assets);

    switch (defaultDest) {
      case UploadDestination.telegram:
        final n = await _addAssetsToQueue(assets,
            destinations: const [UploadDestination.telegram],
            folder: folder,
            clearSelection: clearSelection);
        if (n > 0 && announce) {
          Fluttertoast.showToast(msg: 'Added to Telegram queue');
        }
        return n;

      case UploadDestination.both:
        // One pass, both sides. Queueing Telegram first and then reading the
        // selection again for YouTube used to find it empty — the first pass
        // had already cleared it — which is how "both" uploaded to Telegram
        // only. Coverage is per destination, so the second destination still
        // queues the same videos.
        final n = await _addAssetsToQueue(assets,
            destinations: const [
              UploadDestination.telegram,
              UploadDestination.youtube,
            ],
            folder: folder,
            clearSelection: clearSelection);
        if (n > 0 && announce) {
          Fluttertoast.showToast(msg: 'Added to YouTube + Telegram queue');
        }
        return n;

      case UploadDestination.youtube:
        if (!mixed) {
          return _addAssetsToQueue(assets,
              destinations: const [UploadDestination.youtube],
              folder: folder,
              clearSelection: clearSelection);
        }
        final dest = await _showDestinationPicker(true);
        if (dest == null) return 0;
        return _addAssetsToQueue(assets,
            destinations: [dest],
            folder: folder,
            clearSelection: clearSelection);
    }
  }

  /// Long-press a folder chip → "Upload folder": every item in the folder is
  /// queued through the default destination (YouTube / Telegram / both),
  /// tagged with the folder name — so the Telegram copy carries the
  /// `#folder` caption, the YouTube copy lands in that playlist, and the
  /// folder itself keeps holding exactly the videos that went up.
  Future<void> _uploadFolder(MediaFolder folder) async {
    final store = widget.folderStore;
    if (store == null) return;
    final ids = store.filterIds(FolderScope.local, folder.id);
    final assets = ids == null
        ? <AssetEntity>[]
        : _galleryVideos.where((v) => ids.contains(v.id)).toList();
    if (assets.isEmpty) {
      Fluttertoast.showToast(msg: '${folder.name} has nothing to upload');
      return;
    }

    // Membership is by asset id and idempotent, so re-filing is a no-op for
    // items already dropped in and a catch-up for anything that arrived by
    // another route (move sheet, backup import).
    await store.addItems(folder.id, [for (final a in assets) a.id]);

    final queued = await _handleAddToQueue(
        assets: assets, folder: folder.name, announce: false);
    if (!mounted) return;
    Fluttertoast.showToast(
      msg: queued == 0
          ? '${folder.name}: everything is already queued'
          : 'Queued $queued of ${assets.length} from ${folder.name}',
    );
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

      var asset = _findAsset(job.assetId);
      if (asset == null) {
        // The grid only holds the first page of each album, and a sync queues
        // the oldest videos first — exactly the ones that may not be loaded
        // here. Resolve by id rather than failing the upload as inaccessible.
        try {
          asset = await AssetEntity.fromId(job.assetId);
        } catch (_) {
          asset = null;
        }
      }
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
        // The short UUID tag rides on the caption exactly as it does on the
        // YouTube title, so the two remote copies identify the same item.
        final tgCaption = job.folder != null && job.folder!.isNotEmpty
            ? '#${job.folder!.replaceAll(' ', '_')}\n${job.taggedTitle}'
            : job.taggedTitle;
        final result = await tel.uploadToSavedMessages(
          file.path,
          caption: tgCaption,
          onStatus: (msg) => widget.scheduler.setStatusMessage(job.id, msg),
          videoWidth: asset?.width ?? 0,
          videoHeight: asset?.height ?? 0,
          videoDuration: asset?.duration ?? 0,
          thumbBytes: asset != null ? await _telegramThumb(asset) : null,
          videoHint: asset?.type == AssetType.video ? true : null,
        );
        // Record the real message id so the TG badge can later be verified
        // against Telegram instead of being trusted forever. Only a numeric
        // id is usable — dumping the raw RPC result here would leave a value
        // that can never be probed, forcing every upload onto caption search.
        final sentId = TelegramService.extractSentMessageId(result);
        await widget.scheduler.markCompleted(
          job.id,
          telegramMessageId: sentId?.toString() ?? '',
          // Whose account this landed in — the "Telegram today" number
          // follows the phone number signed in, not the device.
          telegramAccountId: tel.accountKey ?? '',
        );
        if (sentId != null && job.uuid != null) {
          await MediaIndex.instance.link(
            uuid: job.uuid!,
            telegramMessageId: sentId.toString(),
            telegramAccountKey: tel.accountKey ?? '',
            title: job.title,
          );
        }
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
          title: job.taggedTitle,
          description: 'Uploaded via Flutter app',
          onProgress: (p) => widget.scheduler.markProgress(job.id, p),
        );

        if (videoId != null && videoId.isNotEmpty) {
          await MediaIndex.instance.link(
            uuid: job.uuid ?? '',
            youtubeVideoId: videoId,
            title: job.title,
          );
        }

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

  /// A JPEG frame to send with a Telegram upload. Telegram never generates a
  /// preview for an uploaded video itself — official clients always attach
  /// one — so without this the message arrives in Saved Messages with no
  /// thumbnail. The first rendition that fits the API's ~200 KB thumb budget
  /// wins, and a frame that never fits is dropped rather than failing the
  /// upload.
  Future<Uint8List?> _telegramThumb(AssetEntity asset) async {
    if (asset.type == AssetType.audio || asset.type == AssetType.other) {
      return null;
    }
    const maxBytes = 190 * 1024;
    const attempts = [
      (ThumbnailSize.square(320), 80),
      (ThumbnailSize.square(240), 70),
      (ThumbnailSize.square(160), 60),
    ];
    for (final (size, quality) in attempts) {
      if (_isDisposed) return null;
      try {
        final bytes =
            await asset.thumbnailDataWithSize(size, quality: quality);
        if (bytes == null) return null;
        if (bytes.length <= maxBytes) return bytes;
      } catch (_) {
        return null;
      }
    }
    return null;
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
    final uploadedToYoutube = <String>{};
    final uploadedToTelegram = <String>{};
    for (final j in widget.scheduler.jobs) {
      if (j.status != JobStatus.completed) {
        alreadyInQueue.add(j.assetId);
      } else {
        // Both badges answer "is it still there", not "did it once
        // upload" — a copy deleted on the service must stop claiming credit.
        if (widget.scheduler.isOnYoutube(j)) uploadedToYoutube.add(j.assetId);
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

    // Counts behind the V/P/F tooltips, taken from the folder in view so
    // they agree with what the grid will show after a switch.
    final videoCount = inFolder.where((v) => v.type == AssetType.video).length;
    final photoCount = inFolder.where((v) => v.type == AssetType.image).length;
    final fileCount = inFolder
        .where((v) => v.type == AssetType.audio || v.type == AssetType.other)
        .length;

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
          // Counted against the same per-destination rule the routing uses,
          // so a video already on Telegram (or deleted from it) is picked up
          // here instead of being silently skipped by the queue call.
          if (_addToQueueCount(_selectedForQueue) > 0)
            TextButton(
              onPressed: () async {
                await _handleAddToQueue(
                  assets: _selectedForQueue.toList(),
                  clearSelection: true,
                );
                _setShowPicker(false);
              },
              child: Text(
                  'Add ${_addToQueueCount(_selectedForQueue)} to Queue'),
            ),
          if (_selectedForQueue.isNotEmpty)
            IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.red[300]),
              onPressed: () => _deleteSelected(),
            ),
          // The media filters moved up here from their own row: one letter
          // each keeps all three narrow enough to live in the bar, and the
          // grid gets the full height the old row used to eat.
          _buildAppBarTab(0, 'V', videoCount),
          _buildAppBarTab(1, 'P', photoCount),
          _buildAppBarTab(2, 'F', fileCount),
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
                // The V/P/F filters live in the app bar now, so this is only
                // the clearance the tab row used to provide under the
                // transparent bar — the grid starts right below it.
                SizedBox(
                  height:
                      MediaQuery.of(context).padding.top + kToolbarHeight + 8,
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
                    onUploadFolder: _uploadFolder,
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
                      final onYt = uploadedToYoutube.contains(v.id);
                      final onTg = uploadedToTelegram.contains(v.id);
                      // With several tiles picked, a long-press on one of
                      // them opens the "move selected to folders" sheet; the
                      // drag-to-chip gesture keeps the tile when nothing is
                      // picked. One long-press cannot be both.
                      final moveSelection =
                          _selectedForQueue.length > 1 && selected;
                      // Selection is gated on still having somewhere to send
                      // the tile, not on "has any job at all": a video whose
                      // Telegram copy was deleted, or that is queued for
                      // Telegram only, still has an upload left to do.
                      final queueable = _canQueue(v, UploadDestination.youtube) ||
                          _canQueue(v, UploadDestination.telegram);
                      final tile = GestureDetector(
                        onTap: () {
                          if (!queueable) return;
                          setState(() {
                            if (selected) {
                              _selectedForQueue.remove(v);
                            } else {
                              _selectedForQueue.add(v);
                            }
                          });
                        },
                        onLongPress:
                            moveSelection ? _moveSelectionToFolder : null,
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
                            if (onYt || onTg)
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
                            if (widget.folderStore != null)
                              Positioned(
                                left: 4, bottom: 4,
                                child: FolderTags(
                                  store: widget.folderStore!,
                                  scope: FolderScope.local,
                                  itemId: v.id,
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
                      if (moveSelection) return tile;
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

  /// One media filter in the app bar: a single letter (V/P/F) with the full
  /// name and the live count of the folder in view as its tooltip. Tapping
  /// it swaps the grid exactly as the old tab row did.
  Widget _buildAppBarTab(int index, String letter, int count) {
    const labels = ['Videos', 'Photos', 'Files'];
    final selected = _localTabIndex == index;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: '${labels[index]} ($count)',
        child: GestureDetector(
          onTap: () => _setLocalTabIndex(index),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? Colors.green : Colors.grey[900],
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: selected ? Colors.green : Colors.grey[700]!),
            ),
            child: Text(
              letter,
              style: TextStyle(
                  color: selected ? Colors.white : Colors.grey[400],
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
            ),
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
    // Both counters answer for the account in view: YouTube's 15-a-day is
    // per channel, Telegram's uploads belong to the signed-in phone number.
    final channel = widget.accountManager.selectedChannel;
    final ytToday =
        widget.scheduler.todayYoutubeCountForChannel(channel?.id);
    final tgToday = widget.scheduler
        .todayTelegramCountForAccount(widget.telegramService?.accountKey);
    final tgPhone = widget.telegramService?.accountPhone;
    final paused = widget.scheduler.paused;
    final all = widget.scheduler.jobs;
    final active = all.where((j) => j.status == JobStatus.pending || j.status == JobStatus.uploading).toList();
    final scheduled = widget.scheduler.scheduledJobs.toList();
    final completed = widget.scheduler.completedJobs.toList();
    final failed = widget.scheduler.failedJobs.toList();

    // One flat list in display order, then a slice of it per page. Sections
    // are rebuilt from the slice, so a header only appears when its kind has
    // rows on this page — and Active always sorts first, which keeps the
    // upload in flight on page 1 no matter how much history piled up behind.
    final ordered = <UploadJob>[
      ...active, ...scheduled, ...failed, ...completed,
    ];
    var totalPages = (ordered.length + _queuePageSize - 1) ~/ _queuePageSize;
    if (totalPages < 1) totalPages = 1;
    var page = _queuePage;
    if (page > totalPages - 1) page = totalPages - 1;
    if (page < 0) page = 0;
    final slice = ordered
        .skip(page * _queuePageSize)
        .take(_queuePageSize)
        .toList();
    final pageActive =
        slice.where((j) => j.status == JobStatus.pending || j.status == JobStatus.uploading).toList();
    final pageScheduled =
        slice.where((j) => j.status == JobStatus.scheduled).toList();
    final pageFailed =
        slice.where((j) => j.status == JobStatus.failed).toList();
    final pageCompleted =
        slice.where((j) => j.status == JobStatus.completed).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(widget.telegramService != null && widget.scheduler.jobs.any((j) => j.destination == UploadDestination.telegram)
            ? 'Queue (Telegram)'
            : 'Upload Queue'),
        actions: [
          IconButton(
            icon: paused
                ? const Icon(Icons.play_circle, color: Colors.green)
                : const Icon(Icons.pause_circle, color: Colors.amber),
            tooltip: paused ? 'Resume whole queue' : 'Pause whole queue',
            onPressed: () => widget.scheduler.setPaused(!paused),
          ),
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
                          Flexible(
                            child: Text(
                                channel != null &&
                                        widget.accountManager.channels.length > 1
                                    ? 'YouTube Today · ${channel.title}'
                                    : 'YouTube Today',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.grey[300], fontSize: 13)),
                          ),
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
                          Flexible(
                            child: Text(
                                tgPhone != null
                                    ? 'Telegram Today · $tgPhone'
                                    : 'Telegram Today',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.grey[300], fontSize: 13)),
                          ),
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
                if (paused) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.pause_circle, color: Colors.amber, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Queue paused — nothing new will start until you resume',
                            style: TextStyle(color: Colors.amber[200], fontSize: 12),
                          ),
                        ),
                        TextButton(
                          onPressed: () => widget.scheduler.setPaused(false),
                          child: const Text('Resume',
                              style: TextStyle(color: Colors.green, fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),

                if (pageActive.isNotEmpty) ...[
                  Text('Active (${pageActive.length})', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...pageActive.map((job) => _buildJobTile(job)),
                  const SizedBox(height: 16),
                ],

                if (pageScheduled.isNotEmpty) ...[
                  Text('Scheduled (${pageScheduled.length})', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...pageScheduled.map((job) => _buildJobTile(job)),
                  const SizedBox(height: 16),
                ],

                if (pageFailed.isNotEmpty) ...[
                  Text('Failed (${pageFailed.length})', style: TextStyle(color: Colors.red[400], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...pageFailed.map((job) => _buildJobTile(job)),
                  const SizedBox(height: 16),
                ],

                if (pageCompleted.isNotEmpty) ...[
                  Text('Completed (${completed.length})', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...pageCompleted.map((job) => _buildJobTile(job)),
                ],

                if (totalPages > 1) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left, color: Colors.white70),
                        onPressed:
                            page > 0 ? () => _gotoQueuePage(page - 1) : null,
                      ),
                      Text('Page ${page + 1} of $totalPages',
                          style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, color: Colors.white70),
                        onPressed: page < totalPages - 1
                            ? () => _gotoQueuePage(page + 1)
                            : null,
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  String _channelName(String channelId) {
    final c = widget.accountManager.channels.where((ch) => ch.id == channelId).firstOrNull;
    return c?.title ?? channelId;
  }

  /// The swipe only *offers* the delete; nothing leaves the queue until
  /// this says yes, so a stray flick cannot take a queued or finished
  /// upload — and the history behind the statistics — with it.
  Future<bool> _confirmRemove(UploadJob job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Remove from queue?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          job.displayName,
          style: TextStyle(color: Colors.grey[400]),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Widget _buildJobTile(UploadJob job) {
    final dateFmt = DateFormat('MMM d, HH:mm');
    return Dismissible(
      key: Key(job.id),
      direction: DismissDirection.endToStart,
      background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white)),
      confirmDismiss: (_) => _confirmRemove(job),
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
            if (widget.scheduler.isOnYoutube(job))
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