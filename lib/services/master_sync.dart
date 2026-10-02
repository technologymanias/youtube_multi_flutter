import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_manager.dart';
import 'upload_scheduler.dart';

/// One category the profile page can sync on its own.
///
/// Each value is a complete instruction — where its uploads go, what to ask
/// the photo library for, and which asset types it takes — so the button, the
/// scan and the queue all read the same definition instead of repeating it.
enum SyncTarget {
  telegramVideos('Telegram videos'),
  telegramPhotos('Telegram photos'),
  telegramFiles('Telegram files'),
  youtubeVideos('YouTube videos');

  const SyncTarget(this.label);

  final String label;
}

/// Which destinations an asset still needs a job for.
class MasterSyncPlan {
  const MasterSyncPlan({required this.youtube, required this.telegram});

  final bool youtube;
  final bool telegram;

  bool get isEmpty => !youtube && !telegram;
}

/// What one pass of [MasterSync.syncNow] or [MasterSync.syncTarget] did, so
/// the profile page can show something more useful than "it ran".
class MasterSyncResult {
  const MasterSyncResult({
    required this.youtubeAdded,
    required this.telegramAdded,
    this.skipped = 0,
    this.error,
  });

  final int youtubeAdded;
  final int telegramAdded;

  /// Assets that belonged to this sync's category but already had a job on
  /// its destination — the "already uploaded" half of what someone is asking
  /// about when they press a sync button.
  final int skipped;

  final String? error;

  bool get ok => error == null;

  /// How many jobs this pass put in the queue, across both destinations.
  int get added => youtubeAdded + telegramAdded;
}

/// What one gallery scan found: the assets worth queueing, oldest first, and
/// how many belonged to that category but were already covered.
typedef ScanResult = ({List<AssetEntity> assets, int covered});

/// The app-wide "send everything automatically" switch, plus one on/off
/// toggle per category on the profile page.
///
/// Every path through here obeys the same three rules:
///
///  * only assets with **no job on that destination** are queued — pressing
///    "Telegram videos" twice must not duplicate anything, and a video that
///    is already on Telegram is never queued again;
///  * the queue is filled **oldest first**, so clips that have waited longest
///    go up first and YouTube's 15-a-day budget is spent on the backlog
///    before today's shots;
///  * YouTube jobs past today's cap are not dropped — [UploadScheduler.addJobs]
///    schedules them onto the following days, while Telegram has no cap and
///    everything lands as pending at once.
class MasterSync extends ChangeNotifier {
  MasterSync({required this.scheduler, required this.accounts});

  static const String _prefsKey = 'master_sync_enabled';

  /// Prefix for the per-category switches, so "Telegram photos: off" survives
  /// a restart like the master switch does.
  static const String _targetPrefsPrefix = 'master_sync_target_';

  /// How often the gallery is re-scanned while the switch is on, so a video
  /// shot after the last pass still finds its way up without anyone tapping
  /// anything.
  static const Duration _interval = Duration(minutes: 15);

  /// Ceiling on one pass. A phone with a decade of photos would otherwise
  /// block the UI behind thousands of platform-channel lookups before a
  /// single job exists. The cap counts assets that still need work — see
  /// [_collect].
  static const int _maxAssetsPerPass = 3000;

  final UploadScheduler scheduler;
  final AccountManager accounts;

  bool _enabled = false;
  bool _running = false;
  SyncTarget? _runningTarget;
  DateTime? _lastRun;
  int _lastYoutube = 0;
  int _lastTelegram = 0;
  String? _lastError;
  Timer? _timer;

  /// Per-target outcomes, so each toggle can report its own last run instead
  /// of one line that only describes whichever category ran last.
  final Map<SyncTarget, MasterSyncResult> _lastTargetResults = {};
  final Map<SyncTarget, DateTime> _lastTargetRuns = {};

  /// Categories switched off. Everything starts on, so upgrading never
  /// silently stops a sync the user was relying on.
  final Set<SyncTarget> _disabledTargets = {};

  /// Set on dispose so an in-flight pass cannot notify a dead listener —
  /// a sync spans platform calls that outlive the shell if the app is closed
  /// while a scan runs.
  bool _disposed = false;

  bool get enabled => _enabled;
  bool get running => _running;

  /// The category currently being scanned/queued, or null when idle. Drives
  /// the spinner on the one toggle that is working.
  SyncTarget? get runningTarget => _runningTarget;
  DateTime? get lastRun => _lastRun;
  int get lastYoutubeAdded => _lastYoutube;
  int get lastTelegramAdded => _lastTelegram;
  String? get lastError => _lastError;

  MasterSyncResult? lastResultFor(SyncTarget target) =>
      _lastTargetResults[target];

  DateTime? lastRunFor(SyncTarget target) => _lastTargetRuns[target];

  /// The category with the most recent run, for the single status line under
  /// the buttons.
  SyncTarget? get lastSyncedTarget {
    SyncTarget? newest;
    DateTime? at;
    for (final entry in _lastTargetRuns.entries) {
      if (at == null || entry.value.isAfter(at)) {
        at = entry.value;
        newest = entry.key;
      }
    }
    return newest;
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefsKey) ?? false;
      _disabledTargets.clear();
      for (final target in SyncTarget.values) {
        final on = prefs.getBool('$_targetPrefsPrefix${target.name}') ?? true;
        if (!on) _disabledTargets.add(target);
      }
    } catch (e) {
      debugPrint('[MasterSync] could not read stored state: $e');
      _enabled = false;
    }
    _restartTimer();
    _notify();
    // The switch is a promise that everything missing gets queued, and a
    // restart is exactly when things went missing.
    if (_enabled) unawaited(syncNow());
  }

  /// Whether [target] is switched on. Categories default to on, so a fresh
  /// install syncs everything exactly as it did before the toggles existed.
  bool targetEnabled(SyncTarget target) => !_disabledTargets.contains(target);

  /// Turns one category's toggle on or off and persists it. Off means the
  /// automatic pass skips that category entirely; on means it is queued again
  /// from the next pass on.
  Future<void> setTargetEnabled(SyncTarget target, bool value) async {
    final changed =
        value ? _disabledTargets.remove(target) : _disabledTargets.add(target);
    if (!changed) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_targetPrefsPrefix${target.name}', value);
    } catch (e) {
      debugPrint('[MasterSync] could not persist $target state: $e');
    }
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (e) {
      debugPrint('[MasterSync] could not persist state: $e');
    }
    _restartTimer();
    _notify();
    if (_enabled) unawaited(syncNow());
  }

  void _restartTimer() {
    _timer?.cancel();
    if (!_enabled || _disposed) return;
    _timer = Timer.periodic(_interval, (_) => unawaited(syncNow()));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ one target

  /// Where [target]'s uploads go. Everything but YouTube is Saved Messages.
  static UploadDestination destinationFor(SyncTarget target) =>
      target == SyncTarget.youtubeVideos
          ? UploadDestination.youtube
          : UploadDestination.telegram;

  /// What [target] takes from the gallery. `other`-typed files ride along
  /// with audio when the whole library is asked for, which is how the Local
  /// page's Files tab already defines itself.
  static bool assetMatches(SyncTarget target, AssetType type) =>
      switch (target) {
        SyncTarget.telegramVideos || SyncTarget.youtubeVideos =>
          type == AssetType.video,
        SyncTarget.telegramPhotos => type == AssetType.image,
        SyncTarget.telegramFiles =>
          type == AssetType.audio || type == AssetType.other,
      };

  /// What to ask the photo library for. Narrowing the request keeps a photos
  /// pass from paging through every video on the device first.
  static RequestType requestTypeFor(SyncTarget target) => switch (target) {
        SyncTarget.telegramVideos || SyncTarget.youtubeVideos =>
          RequestType.video,
        SyncTarget.telegramPhotos => RequestType.image,
        SyncTarget.telegramFiles => RequestType.all,
      };

  /// The rule for one asset, used by the automatic switch.
  ///
  /// YouTube only takes video, and a destination is only queued when nothing
  /// is already going there — a job in flight or a finished upload both mean
  /// "already covered", so re-syncing can never duplicate work.
  static MasterSyncPlan planFor({
    required bool isVideo,
    required bool hasYoutubeJob,
    required bool hasTelegramJob,
  }) =>
      MasterSyncPlan(
        youtube: isVideo && !hasYoutubeJob,
        telegram: !hasTelegramJob,
      );

  /// Asset ids that already have a job on [destination], in flight or
  /// finished. Anything in here is skipped by every sync path: "not uploaded
  /// yet" means *no job at all*, because a failed job is already sitting in
  /// the queue where it can be retried — queueing it again would only put a
  /// duplicate next to it.
  Set<String> _coveredIds(UploadDestination destination) => {
        for (final j in scheduler.jobs)
          if (destination == UploadDestination.telegram
              ? j.uploadedToTelegram
              : j.uploadedToYoutube)
            j.assetId,
      };

  /// Queues one category, oldest first.
  ///
  /// Safe to call any time: a pass that is already running is refused with an
  /// error the row can show, rather than interleaving two scans over one
  /// job list.
  Future<MasterSyncResult> syncTarget(SyncTarget target) async {
    if (_running) {
      return const MasterSyncResult(
        youtubeAdded: 0,
        telegramAdded: 0,
        error: 'Another sync is already running',
      );
    }
    _running = true;
    _runningTarget = target;
    _notify();

    MasterSyncResult result;
    try {
      result = await _runTarget(target);
    } catch (e) {
      debugPrint('[MasterSync] $target failed: $e');
      result = MasterSyncResult(youtubeAdded: 0, telegramAdded: 0, error: '$e');
    }

    _lastTargetResults[target] = result;
    _lastTargetRuns[target] = DateTime.now();
    // The automatic switch keeps its own headline numbers: mixing a button's
    // result into "last pass queued …" would make the ON/OFF card claim
    // credit for work it did not do.
    _running = false;
    _runningTarget = null;
    _notify();
    return result;
  }

  Future<MasterSyncResult> _runTarget(SyncTarget target) async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      return const MasterSyncResult(
        youtubeAdded: 0,
        telegramAdded: 0,
        error: 'Photo library access is needed to sync',
      );
    }

    final destination = destinationFor(target);
    final scan = await _collect(
      type: requestTypeFor(target),
      matches: (asset) => assetMatches(target, asset.type),
      covered: _coveredIds(destination),
    );

    if (scan.assets.isEmpty) {
      return MasterSyncResult(
        youtubeAdded: 0,
        telegramAdded: 0,
        skipped: scan.covered,
      );
    }

    final rows = _rows(scan.assets, _titlesFor(scan.assets));
    await scheduler.addJobs(
      rows,
      accounts.selectedChannelId,
      accounts.currentAccount?.email ?? '',
      destination: destination,
    );

    return MasterSyncResult(
      youtubeAdded:
          destination == UploadDestination.youtube ? rows.length : 0,
      telegramAdded:
          destination == UploadDestination.telegram ? rows.length : 0,
      skipped: scan.covered,
    );
  }

  // ------------------------------------------------------- automatic switch

  /// Scans the gallery and queues everything that has not been sent yet.
  ///
  /// Safe to call at any time: a pass that is already running is dropped, and
  /// turning the switch off mid-pass stops anything from being queued.
  Future<MasterSyncResult> syncNow() async {
    if (_running) {
      return const MasterSyncResult(youtubeAdded: 0, telegramAdded: 0);
    }
    _running = true;
    _runningTarget = null;
    _notify();
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        return _finish(const MasterSyncResult(
          youtubeAdded: 0,
          telegramAdded: 0,
          error: 'Photo library access is needed to sync',
        ));
      }
      if (!_enabled) {
        return _finish(const MasterSyncResult(
          youtubeAdded: 0,
          telegramAdded: 0,
          error: 'Master sync was turned off',
        ));
      }

      // Each category has its own switch, so a pass only scans and queues
      // for the ones that are on — no gallery walk for photos nobody wants
      // queued, and no jobs for a destination the user turned off.
      final wantYoutube = targetEnabled(SyncTarget.youtubeVideos);
      final wantTgVideos = targetEnabled(SyncTarget.telegramVideos);
      final wantTgPhotos = targetEnabled(SyncTarget.telegramPhotos);
      final wantTgFiles = targetEnabled(SyncTarget.telegramFiles);
      if (!wantYoutube && !wantTgVideos && !wantTgPhotos && !wantTgFiles) {
        return _finish(const MasterSyncResult(
          youtubeAdded: 0,
          telegramAdded: 0,
          error: 'Every category sync is turned off',
        ));
      }

      final ytCovered = _coveredIds(UploadDestination.youtube);
      final tgCovered = _coveredIds(UploadDestination.telegram);

      final ytAssets = <AssetEntity>[];
      final tgAssets = <AssetEntity>[];
      var skipped = 0;

      if (wantYoutube || wantTgVideos) {
        // A video covered on one side still needs the other, so the scan only
        // skips the ones that need neither.
        final bothCovered = ytCovered.where(tgCovered.contains).toSet();
        final videos = await _collect(
          type: RequestType.video,
          matches: (asset) => asset.type == AssetType.video,
          covered: bothCovered,
        );
        if (!_enabled) {
          return _finish(const MasterSyncResult(
            youtubeAdded: 0,
            telegramAdded: 0,
            error: 'Master sync was turned off',
          ));
        }
        skipped += videos.covered;
        for (final asset in videos.assets) {
          final plan = planFor(
            isVideo: true,
            hasYoutubeJob: ytCovered.contains(asset.id),
            hasTelegramJob: tgCovered.contains(asset.id),
          );
          if (wantYoutube && plan.youtube) ytAssets.add(asset);
          if (wantTgVideos && plan.telegram) tgAssets.add(asset);
        }
      }

      if (wantTgPhotos) {
        final photos = await _collect(
          type: RequestType.image,
          matches: (asset) => asset.type == AssetType.image,
          covered: tgCovered,
        );
        if (!_enabled) {
          return _finish(const MasterSyncResult(
            youtubeAdded: 0,
            telegramAdded: 0,
            error: 'Master sync was turned off',
          ));
        }
        skipped += photos.covered;
        tgAssets.addAll(photos.assets);
      }

      if (wantTgFiles) {
        final files = await _collect(
          type: RequestType.all,
          matches: (asset) =>
              asset.type == AssetType.audio || asset.type == AssetType.other,
          covered: tgCovered,
        );
        if (!_enabled) {
          return _finish(const MasterSyncResult(
            youtubeAdded: 0,
            telegramAdded: 0,
            error: 'Master sync was turned off',
          ));
        }
        skipped += files.covered;
        tgAssets.addAll(files.assets);
      }

      // One destination means one chronological queue, and photos and files
      // were scanned separately from the videos they are mixed in with.
      tgAssets.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));

      if (ytAssets.isEmpty && tgAssets.isEmpty) {
        return _finish(MasterSyncResult(
          youtubeAdded: 0,
          telegramAdded: 0,
          skipped: skipped,
        ));
      }

      // Titles are resolved once for every asset in the pass, so the same
      // video queued to both destinations leaves with the same title on both
      // rows — the YouTube page maps uploads back to local assets by title
      // when it has no video id, and two different titles would resolve to
      // the wrong clip.
      final titles = _titlesFor({...ytAssets, ...tgAssets});

      final channelId = accounts.selectedChannelId;
      final email = accounts.currentAccount?.email ?? '';

      // Telegram first: those jobs go straight to pending, while the
      // YouTube call reads today's occupancy to decide what still fits and
      // what rolls onto the next days.
      if (tgAssets.isNotEmpty) {
        await scheduler.addJobs(_rows(tgAssets, titles), channelId, email,
            destination: UploadDestination.telegram);
      }
      if (ytAssets.isNotEmpty) {
        await scheduler.addJobs(_rows(ytAssets, titles), channelId, email,
            destination: UploadDestination.youtube);
      }

      return _finish(MasterSyncResult(
        youtubeAdded: ytAssets.length,
        telegramAdded: tgAssets.length,
        skipped: skipped,
      ));
    } catch (e) {
      debugPrint('[MasterSync] sync failed: $e');
      return _finish(MasterSyncResult(
        youtubeAdded: 0,
        telegramAdded: 0,
        error: '$e',
      ));
    } finally {
      _running = false;
      _runningTarget = null;
      _notify();
    }
  }

  MasterSyncResult _finish(MasterSyncResult result) {
    _lastRun = DateTime.now();
    _lastYoutube = result.youtubeAdded;
    _lastTelegram = result.telegramAdded;
    _lastError = result.error;
    return result;
  }

  // ------------------------------------------------------------- scanning

  /// Every asset of [type] that [matches] and is not in [covered], oldest
  /// first, capped at [_maxAssetsPerPass].
  ///
  /// Oldest first is the point of a sync: the queue hands its work to the
  /// uploader in list order, so the oldest waiting clip goes up first.
  ///
  /// Coverage is checked **while paging**, not afterwards — otherwise the cap
  /// would be spent on assets that need no work, and a phone with ten years
  /// of already uploaded videos would never reach the handful still waiting.
  Future<ScanResult> _collect({
    required RequestType type,
    required bool Function(AssetEntity asset) matches,
    required Set<String> covered,
  }) async {
    final albums = await PhotoManager.getAssetPathList(type: type);
    final picked = <String, AssetEntity>{};
    var alreadyCovered = 0;

    for (final album in albums) {
      if (picked.length >= _maxAssetsPerPass) break;
      var page = 0;
      while (picked.length < _maxAssetsPerPass) {
        final batch = await album.getAssetListPaged(page: page, size: 500);
        if (batch.isEmpty) break;
        for (final asset in batch) {
          if (picked.length >= _maxAssetsPerPass) break;
          if (!matches(asset)) continue;
          if (covered.contains(asset.id)) {
            alreadyCovered++;
            continue;
          }
          picked[asset.id] = asset;
        }
        if (batch.length < 500) break;
        page++;
      }
    }

    final assets = picked.values.toList()
      ..sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
    return (assets: assets, covered: alreadyCovered);
  }

  /// One title per asset, keyed by id, seeded with every title already in
  /// the queue so a new row can never collide with an existing one.
  Map<String, String> _titlesFor(Iterable<AssetEntity> assets) {
    final fmt = DateFormat('dd MMMM yyyy HH:mm');
    final used = <String>{for (final j in scheduler.jobs) j.title.trim()};
    final titles = <String, String>{};
    for (final asset in assets) {
      titles[asset.id] = _uniqueTitle(fmt, used, asset.createDateTime);
    }
    return titles;
  }

  List<Map<String, String>> _rows(
    List<AssetEntity> assets,
    Map<String, String> titles,
  ) =>
      [
        for (final asset in assets)
          {'assetId': asset.id, 'title': titles[asset.id]!},
      ];

  /// Two clips captured in the same minute must not leave the queue with
  /// identical titles — the YouTube page maps uploads back to local assets by
  /// title when it has no video id, and a tie would resolve to the wrong
  /// one.
  String _uniqueTitle(
    DateFormat fmt,
    Set<String> used,
    DateTime created,
  ) {
    final base = fmt.format(created);
    var title = base;
    var n = 2;
    while (used.contains(title)) {
      title = '$base #$n';
      n++;
    }
    used.add(title);
    return title;
  }
}
