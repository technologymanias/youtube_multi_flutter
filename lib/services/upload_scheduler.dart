import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'background_service.dart';
import 'media_index.dart';

enum JobStatus { pending, uploading, completed, failed, scheduled }

enum UploadDestination { youtube, telegram, both }

class UploadJob {
  final String id;
  final String assetId;
  String title;
  final String? filePath;

  /// Cross-platform identity for this media item. Assigned when the job is
  /// created and reused for every destination, so the same file lands in the
  /// YouTube title and the Telegram caption carrying the *same* UUID.
  /// Nullable only for jobs written by a build that predates the UUID work —
  /// [UploadScheduler.load] back-fills them on startup.
  String? uuid;

  /// The 8-character display form of [uuid] (`[a1b2c3d4]`). Stored so the
  /// queue UI never has to re-derive it, and so a title already carrying the
  /// tag stays byte-identical across restarts.
  String? shortTag;

  JobStatus status;
  double progress;
  DateTime? scheduledDate;
  DateTime? completedAt;
  String? youtubeVideoId;
  String? telegramMessageId;
  String? error;
  String? statusMessage;
  String channelId;
  String accountEmail;
  UploadDestination destination;
  String? folder;

  /// The Telegram account the copy was sent to, recorded when the upload
  /// finished — "Telegram today" is that account's number, so signing into
  /// a different phone number shows that number's uploads instead.
  String telegramAccountId;

  UploadJob({
    required this.id,
    required this.assetId,
    required this.title,
    this.filePath,
    this.uuid,
    this.shortTag,
    this.status = JobStatus.pending,
    this.progress = 0,
    this.scheduledDate,
    this.completedAt,
    this.youtubeVideoId,
    this.telegramMessageId,
    this.error,
    this.statusMessage,
    this.channelId = '',
    this.accountEmail = '',
    this.destination = UploadDestination.youtube,
    this.folder,
    this.telegramAccountId = '',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'assetId': assetId,
    'title': title,
    'filePath': filePath,
    'uuid': uuid,
    'shortTag': shortTag,
    'status': status.index,
    'progress': progress,
    'scheduledDate': scheduledDate?.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'youtubeVideoId': youtubeVideoId,
    'telegramMessageId': telegramMessageId,
    'error': error,
    'statusMessage': statusMessage,
    'channelId': channelId,
    'accountEmail': accountEmail,
    'destination': destination.index,
    'folder': folder,
    'telegramAccountId': telegramAccountId,
  };

  factory UploadJob.fromJson(Map<String, dynamic> json) => UploadJob(
    id: json['id'] as String,
    assetId: json['assetId'] as String,
    title: json['title'] as String,
    filePath: json['filePath'] as String?,
    uuid: json['uuid'] as String?,
    shortTag: json['shortTag'] as String?,
    status: JobStatus.values[json['status'] as int],
    progress: (json['progress'] as num).toDouble(),
    scheduledDate: json['scheduledDate'] != null ? DateTime.parse(json['scheduledDate'] as String) : null,
    completedAt: json['completedAt'] != null ? DateTime.parse(json['completedAt'] as String) : null,
    youtubeVideoId: json['youtubeVideoId'] as String?,
    telegramMessageId: json['telegramMessageId'] as String?,
    error: json['error'] as String?,
    statusMessage: json['statusMessage'] as String?,
    channelId: json['channelId'] as String? ?? '',
    accountEmail: json['accountEmail'] as String? ?? '',
    destination: json['destination'] != null
        ? UploadDestination.values[json['destination'] as int]
        : UploadDestination.youtube,
    folder: json['folder'] as String?,
    telegramAccountId: json['telegramAccountId'] as String? ?? '',
  );

  String get displayName =>
      title.isNotEmpty ? title : (filePath != null ? filePath!.split('/').last : assetId);

  /// The title as it must be sent to a destination: base title plus the short
  /// UUID tag (`02 October 2026 15:30 [a1b2c3d4]`). Identical for YouTube and
  /// Telegram — that byte-identity is what lets one be matched to the other —
  /// and capped at 100 characters because that is YouTube's title limit.
  String get taggedTitle => MediaIndex.fitTitle(title, shortTag);

  bool get uploadedToYoutube => destination == UploadDestination.youtube || destination == UploadDestination.both;
  bool get uploadedToTelegram => destination == UploadDestination.telegram || destination == UploadDestination.both;
}

class UploadScheduler extends ChangeNotifier {
  static const int youtubeDailyLimit = 15;
  static const String _storageKey = 'upload_queue';
  static const _storage = FlutterSecureStorage();

  List<UploadJob> _jobs = [];
  DateTime _lastUiNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// When the whole queue is paused, [claimNext] hands out nothing: the page
  /// keeps showing every job exactly as it was, but no new upload starts
  /// until it is resumed. An upload already in flight runs to completion —
  /// aborting mid-file would only throw away the bytes already sent.
  bool _paused = false;

  bool get paused => _paused;

  Future<void> setPaused(bool value) async {
    if (_paused == value) return;
    _paused = value;
    await _save();
    notifyListeners();
    debugPrint('[Queue] ${value ? "paused" : "resumed"}');
  }

  /// Progress/status updates fire for every upload chunk; notifying the UI on
  /// each one saturates the main isolate, so these are rate-limited.
  void _notifyThrottled({int minIntervalMs = 300}) {
    final now = DateTime.now();
    if (now.difference(_lastUiNotify).inMilliseconds < minIntervalMs) return;
    _lastUiNotify = now;
    notifyListeners();
  }

  /// Job ids whose Telegram copy was confirmed deleted inside Telegram.
  ///
  /// Persisted alongside the jobs: a restart must not hand every upload its
  /// badge back just because the answer lived only in memory.
  final Set<String> _deletedTelegramJobIds = {};

  /// Same story as [_deletedTelegramJobIds], for copies deleted on YouTube.
  final Set<String> _deletedYoutubeJobIds = {};

  /// Whether the job's Telegram copy is still believed to exist. The TG badge
  /// is only shown while this is true.
  bool isOnTelegram(UploadJob job) =>
      job.uploadedToTelegram && !_deletedTelegramJobIds.contains(job.id);

  /// Whether the job's YouTube copy is still believed to exist. Mirrors
  /// [isOnTelegram] so the YT badge reflects what is really on the channel
  /// instead of what was true when the upload finished.
  bool isOnYoutube(UploadJob job) =>
      job.uploadedToYoutube && !_deletedYoutubeJobIds.contains(job.id);

  /// Applies one round of verification against Telegram. [present] re-enables
  /// the badge, [absent] clears it, and anything in neither list keeps
  /// whatever it already had — an unverifiable probe must never silently
  /// restore a badge the user already saw disappear.
  void applyTelegramVerdict(
      {required Set<String> present, required Set<String> absent}) {
    if (_applyVerdict(_deletedTelegramJobIds, present: present, absent: absent)) {
      _persistVerdicts();
      notifyListeners();
    }
  }

  /// One round of verification against YouTube, with the same contract as
  /// [applyTelegramVerdict].
  void applyYoutubeVerdict(
      {required Set<String> present, required Set<String> absent}) {
    if (_applyVerdict(_deletedYoutubeJobIds, present: present, absent: absent)) {
      _persistVerdicts();
      notifyListeners();
    }
  }

  bool _applyVerdict(Set<String> store,
      {required Set<String> present, required Set<String> absent}) {
    var changed = false;
    for (final id in present) {
      if (store.remove(id)) changed = true;
    }
    for (final id in absent) {
      if (store.add(id)) changed = true;
    }
    return changed;
  }

  void clearDeletedOnTelegram(String jobId) {
    if (_deletedTelegramJobIds.remove(jobId)) {
      _persistVerdicts();
      notifyListeners();
    }
  }

  void clearDeletedOnYoutube(String jobId) {
    if (_deletedYoutubeJobIds.remove(jobId)) {
      _persistVerdicts();
      notifyListeners();
    }
  }

  /// The verdicts ride in the same secure-storage blob as the jobs, so they
  /// are written through [_save] rather than a key of their own.
  void _persistVerdicts() {
    unawaited(_save());
  }

  List<UploadJob> get jobs => List.unmodifiable(_jobs);
  int get totalCount => _jobs.length;
  int get pendingCount => _jobs.where((j) => j.status == JobStatus.pending).length;
  int get scheduledCount => _jobs.where((j) => j.status == JobStatus.scheduled).length;
  int get uploadingCount => _jobs.where((j) => j.status == JobStatus.uploading).length;
  int get completedCount => _jobs.where((j) => j.status == JobStatus.completed).length;
  int get failedCount => _jobs.where((j) => j.status == JobStatus.failed).length;

  /// Whether [job] counts for [channelId]'s numbers. Jobs queued before the
  /// app recorded a channel carry no id and stay visible for every channel —
  /// they are this device's own history, not another channel's.
  static bool belongsToChannel(UploadJob job, String? channelId) =>
      channelId == null ||
      channelId.isEmpty ||
      job.channelId.isEmpty ||
      job.channelId == channelId;

  /// Whether [job] counts for the Google account [accountEmail]: the same
  /// "no id recorded, so it belongs to whoever is signed in" rule as
  /// [belongsToChannel], for accounts instead of channels.
  static bool belongsToAccount(UploadJob job, String? accountEmail) =>
      accountEmail == null ||
      accountEmail.isEmpty ||
      job.accountEmail.isEmpty ||
      job.accountEmail == accountEmail;

  /// Whether [job] counts for the Telegram account [accountId]. Same rule
  /// again: uploads finished before the app recorded which phone number
  /// they went to belong to every account until they are attributed.
  static bool belongsToTelegramAccount(UploadJob job, String? accountId) =>
      accountId == null ||
      accountId.isEmpty ||
      job.telegramAccountId.isEmpty ||
      job.telegramAccountId == accountId;

  bool _completedOn(UploadJob j, String today) =>
      j.status == JobStatus.completed &&
      j.completedAt != null &&
      j.completedAt!.toIso8601String().substring(0, 10) == today;

  /// Today's YouTube uploads for one channel — the number the 15-a-day ring
  /// is out of. A `both` job counts here (it did use a YouTube slot), which
  /// is the same arithmetic [_youtubeDateCounts] spends the quota with.
  int todayYoutubeCountForChannel(String? channelId) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _jobs
        .where((j) =>
            _completedOn(j, today) &&
            j.uploadedToYoutube &&
            belongsToChannel(j, channelId))
        .length;
  }

  /// Today's Telegram uploads for one account, so signing into a different
  /// phone number shows that number's uploads. Null means "no account
  /// known" and falls back to the whole device's count.
  int todayTelegramCountForAccount(String? accountId) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _jobs
        .where((j) =>
            _completedOn(j, today) &&
            j.uploadedToTelegram &&
            belongsToTelegramAccount(j, accountId))
        .length;
  }

  /// Completed uploads belonging to one Google account.
  int completedCountForAccount(String? accountEmail) => _jobs
      .where((j) =>
          j.status == JobStatus.completed &&
          belongsToAccount(j, accountEmail))
      .length;

  /// Failed jobs belonging to one Google account.
  int failedCountForAccount(String? accountEmail) => _jobs
      .where((j) =>
          j.status == JobStatus.failed && belongsToAccount(j, accountEmail))
      .length;

  /// Work still waiting (pending, uploading or scheduled) for one account.
  int queuedCountForAccount(String? accountEmail) => _jobs
      .where((j) =>
          (j.status == JobStatus.pending ||
              j.status == JobStatus.uploading ||
              j.status == JobStatus.scheduled) &&
          belongsToAccount(j, accountEmail))
      .length;

  /// Credits Telegram uploads finished before the app recorded which
  /// account they went to. They were sent by whatever account is signed in
  /// now — this device has only ever held one session at a time — so they
  /// join that account's numbers instead of floating across every future
  /// login. Jobs that already know their account are never re-stamped.
  void attributeLegacyTelegramJobs(String accountId) {
    if (accountId.isEmpty) return;
    var changed = false;
    for (final j in _jobs) {
      if (j.uploadedToTelegram && j.telegramAccountId.isEmpty) {
        j.telegramAccountId = accountId;
        changed = true;
      }
    }
    if (!changed) return;
    unawaited(_save());
    notifyListeners();
  }

  List<UploadJob> get pendingAndActive =>
      _jobs.where((j) => j.status == JobStatus.pending || j.status == JobStatus.uploading).toList();

  List<UploadJob> get scheduledJobs =>
      _jobs.where((j) => j.status == JobStatus.scheduled).toList();

  List<UploadJob> get completedJobs =>
      _jobs.where((j) => j.status == JobStatus.completed).toList()
        ..sort((a, b) => (b.completedAt ?? DateTime(0)).compareTo(a.completedAt ?? DateTime(0)));

  List<UploadJob> get failedJobs =>
      _jobs.where((j) => j.status == JobStatus.failed).toList();

  Future<void> init() async {
    await load();
  }

  Future<void> load() async {
    final data = await _storage.read(key: _storageKey);
    if (data == null) return;
    final decoded = jsonDecode(data);
    if (decoded is List) {
      // Legacy shape: the raw job list, before the TG verdict was stored.
      _jobs = decoded
          .map((e) => UploadJob.fromJson(e as Map<String, dynamic>))
          .toList();
    } else if (decoded is Map<String, dynamic>) {
      _jobs = [
        for (final e in (decoded['jobs'] as List?) ?? const [])
          UploadJob.fromJson(e as Map<String, dynamic>),
      ];
      _paused = decoded['paused'] as bool? ?? false;
      _deletedTelegramJobIds
        ..clear()
        ..addAll(
            ((decoded['deletedTelegram'] as List?) ?? const [])
                .map((e) => '$e'));
      _deletedYoutubeJobIds
        ..clear()
        ..addAll(
            ((decoded['deletedYoutube'] as List?) ?? const [])
                .map((e) => '$e'));
    }
    // Ids for jobs that no longer exist would otherwise linger forever.
    final known = {for (final j in _jobs) j.id};
    _deletedTelegramJobIds.removeWhere((id) => !known.contains(id));
    _deletedYoutubeJobIds.removeWhere((id) => !known.contains(id));
    await _backfillUuids();
    _rescheduleAfterRestart();
    notifyListeners();
  }

  /// Gives every job a UUID.
  ///
  /// Three cases, in order:
  ///  1. The job already carries a `uuid` from a previous run — nothing to do.
  ///  2. The title already ends in a `[a1b2c3d4]` tag (a run that crashed
  ///     after uploading but before persisting the id) — adopt that tag's
  ///     UUID if it is in the index, otherwise parse it as the short tag.
  ///  3. Legacy job with no UUID at all — ask the index, which **reuses the
  ///     asset's existing entry** so a file uploaded to YouTube last week and
  ///     queued for Telegram this week end up sharing one id.
  Future<void> _backfillUuids() async {
    final index = MediaIndex.instance;
    await index.ensureLoaded();
    var changed = 0;

    for (final job in _jobs) {
      if (job.uuid != null && job.uuid!.isNotEmpty) {
        if (job.shortTag == null || job.shortTag!.isEmpty) {
          job.shortTag = index.byUuid(job.uuid!)?.shortTag;
        }
        continue;
      }

      final tagged = MediaIndex.parseTag(job.title);
      MediaIdentity? identity;
      if (tagged != null) {
        identity = index.byShortTag(tagged);
        job.shortTag = tagged;
      }
      identity ??= await index.resolveOrCreate(
        assetId: job.assetId,
        title: MediaIndex.stripTag(job.title),
        fileName: job.filePath?.split('/').last,
        fileSize: null,
      );
      job.uuid = identity.uuid;
      job.shortTag = identity.shortTag;
      // Keep the stored title canonical (tag-free); the tag is applied at
      // send time by [UploadJob.taggedTitle].
      final clean = MediaIndex.stripTag(job.title);
      if (clean != job.title) {
        job.title = clean;
      }
      changed++;
    }

    if (changed > 0) {
      await index.flush();
      await _save();
      debugPrint('[Queue] back-filled UUID on $changed job(s)');
    }
  }

  Future<void> _save() async {
    final data = jsonEncode(<String, dynamic>{
      'jobs': _jobs.map((j) => j.toJson()).toList(),
      'deletedTelegram': _deletedTelegramJobIds.toList(),
      'deletedYoutube': _deletedYoutubeJobIds.toList(),
      'paused': _paused,
    });
    await _storage.write(key: _storageKey, value: data);
    unawaited(updateBadgeCount(pendingCount + uploadingCount));
  }

  void _rescheduleAfterRestart() {
    for (final job in _jobs) {
      if (job.status == JobStatus.uploading) {
        job.status = JobStatus.pending;
        job.progress = 0;
      }
    }
    // Whose day has arrived is decided by the same quota-aware promotion the
    // live tick uses, so reopening the app after a week away cannot pull four
    // days of YouTube uploads into one morning.
    promoteDueScheduled();
  }

  /// How many of [channelId]'s YouTube slots are already spoken for on each
  /// date: completed uploads sit on the date they finished, scheduled work on
  /// the date it is waiting for, and undated pending work against today.
  ///
  /// This is the same arithmetic [addJobs] uses to decide whether a new video
  /// still fits on a day, so promotion and scheduling can never disagree
  /// about how full today is.
  Map<String, int> _youtubeDateCounts(String channelId, String todayKey) {
    final counts = <String, int>{};
    for (final j in _jobs) {
      if (j.channelId != channelId || !j.uploadedToYoutube) continue;
      String dateKey;
      if (j.status == JobStatus.completed && j.completedAt != null) {
        dateKey = j.completedAt!.toIso8601String().substring(0, 10);
      } else if (j.status == JobStatus.scheduled && j.scheduledDate != null) {
        dateKey = j.scheduledDate!.toIso8601String().substring(0, 10);
      } else if (j.status == JobStatus.pending ||
          j.status == JobStatus.uploading) {
        dateKey = todayKey;
      } else {
        continue;
      }
      counts[dateKey] = (counts[dateKey] ?? 0) + 1;
    }
    return counts;
  }

  /// Turns scheduled jobs whose day has arrived into runnable ones, and
  /// returns whether anything changed.
  ///
  /// [_rescheduleAfterRestart] only runs while the app is loading, so a queue
  /// left open across midnight would otherwise sit on its schedule forever.
  /// YouTube jobs are only promoted while that day still has slots: a queue
  /// that was closed for a week must not dump four days of uploads into one
  /// morning — the plan keeps rolling 15 onto the next day instead. Telegram
  /// has no daily cap, so those promote as soon as they are due.
  bool promoteDueScheduled() {
    final now = DateTime.now();
    final todayKey = now.toIso8601String().substring(0, 10);
    final slotsLeft = <String, int>{};
    var changed = false;

    final due = _jobs
        .where((j) =>
            j.status == JobStatus.scheduled &&
            j.scheduledDate != null &&
            !j.scheduledDate!.isAfter(now))
        .toList()
      ..sort((a, b) =>
          a.scheduledDate!.compareTo(b.scheduledDate!));

    for (final job in due) {
      if (job.uploadedToYoutube) {
        final left = slotsLeft.putIfAbsent(
          job.channelId,
          () => youtubeDailyLimit -
              (_youtubeDateCounts(job.channelId, todayKey)[todayKey] ?? 0),
        );
        if (left <= 0) continue;
        slotsLeft[job.channelId] = left - 1;
      }
      job.status = JobStatus.pending;
      job.scheduledDate = null;
      changed = true;
    }

    if (changed) {
      unawaited(_save());
      notifyListeners();
    }
    return changed;
  }

  /// [folder] tags every created job with the local folder it came from: it
  /// drives the Telegram `#folder` caption, the YouTube playlist the upload
  /// lands in, and the queue row's own label. Nullable so gallery picks —
  /// which are not filed anywhere — stay untagged.
  Future<void> addJobs(List<Map<String, String>> videos, String channelId, String accountEmail, {UploadDestination destination = UploadDestination.youtube, String? folder}) async {
    final today = DateTime.now();
    final index = MediaIndex.instance;
    await index.ensureLoaded();

    if (destination == UploadDestination.telegram) {
      for (final video in videos) {
        final job = UploadJob(
          id: '${video['assetId']}_${DateTime.now().millisecondsSinceEpoch}_${_jobs.length}',
          assetId: video['assetId']!,
          title: video['title']!,
          filePath: video['filePath'],
          channelId: channelId,
          accountEmail: accountEmail,
          destination: destination,
          folder: folder,
        );
        await _assignUuid(job, index, video);
        _jobs.add(job);
      }
    } else {
      final todayStr = today.toIso8601String().substring(0, 10);

      // Count YouTube jobs already assigned to each date for this channel.
      // Shared with promoteDueScheduled() so adding and rolling the queue
      // forward always read the same "how full is this day" answer.
      final dateCounts = _youtubeDateCounts(channelId, todayStr);

      int dayOffset = 0;
      for (final video in videos) {
        while (true) {
          final dateKey = today.add(Duration(days: dayOffset)).toIso8601String().substring(0, 10);
          final count = dateCounts[dateKey] ?? 0;
          if (count < youtubeDailyLimit) {
            dateCounts[dateKey] = count + 1;
            break;
          }
          dayOffset++;
        }

        final job = UploadJob(
          id: '${video['assetId']}_${DateTime.now().millisecondsSinceEpoch}_${_jobs.length}',
          assetId: video['assetId']!,
          title: video['title']!,
          filePath: video['filePath'],
          channelId: channelId,
          accountEmail: accountEmail,
          destination: destination,
          folder: folder,
        );
        await _assignUuid(job, index, video);

        if (dayOffset > 0) {
          job.status = JobStatus.scheduled;
          job.scheduledDate = today.add(Duration(days: dayOffset));
        }

        _jobs.add(job);
      }
    }
    await _save();
    notifyListeners();
  }

  /// Stamps [job] with the UUID for its asset.
  ///
  /// The index is asked first, so re-queueing a file that was already sent
  /// (to either destination) re-uses the id it already wears — YouTube and
  /// Telegram then carry the same tag without any further coordination.
  Future<void> _assignUuid(
    UploadJob job,
    MediaIndex index,
    Map<String, String> video,
  ) async {
    final identity = await index.resolveOrCreate(
      assetId: job.assetId,
      title: MediaIndex.stripTag(video['title'] ?? job.title),
      fileName: video['filePath']?.split('/').last,
    );
    job.uuid = identity.uuid;
    job.shortTag = identity.shortTag;
    job.title = MediaIndex.stripTag(job.title);
  }

  UploadJob? claimNext() {
    // A paused queue claims nothing — this is the single gate every upload
    // path goes through, so pausing here stops the whole queue at once.
    if (_paused) return null;
    // Get the first pending job that is scheduled for today or earlier
    final now = DateTime.now();
    final idx = _jobs.indexWhere((j) =>
      j.status == JobStatus.pending &&
      (j.scheduledDate == null || j.scheduledDate!.isBefore(now) || j.scheduledDate!.day == now.day)
    );
    if (idx == -1) return null;
    _jobs[idx].status = JobStatus.uploading;
    _jobs[idx].progress = 0;
    notifyListeners();
    return _jobs[idx];
  }

  Future<void> markProgress(String id, double progress) async {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx == -1) return;
    _jobs[idx].progress = progress;
    _notifyThrottled();
  }

  Future<void> setStatusMessage(String id, String message) async {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx == -1) return;
    if (_jobs[idx].statusMessage == message) return;
    _jobs[idx].statusMessage = message;
    _notifyThrottled();
  }

  Future<void> markCompleted(String id, {String youtubeVideoId = '', String telegramMessageId = '', String? telegramAccountId}) async {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx == -1) return;
    _jobs[idx].status = JobStatus.completed;
    _jobs[idx].progress = 1.0;
    if (youtubeVideoId.isNotEmpty) _jobs[idx].youtubeVideoId = youtubeVideoId;
    if (telegramMessageId.isNotEmpty) _jobs[idx].telegramMessageId = telegramMessageId;
    if (telegramAccountId != null && telegramAccountId.isNotEmpty) {
      _jobs[idx].telegramAccountId = telegramAccountId;
    }
    _jobs[idx].completedAt = DateTime.now();
    await _save();
    notifyListeners();
  }

  Future<void> markFailed(String id, String error) async {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx == -1) return;
    _jobs[idx].status = JobStatus.failed;
    _jobs[idx].error = error;
    await _save();
    notifyListeners();
  }

  Future<void> retry(String id) async {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx == -1) return;
    _jobs[idx].status = JobStatus.pending;
    _jobs[idx].progress = 0;
    _jobs[idx].error = null;
    await _save();
    notifyListeners();
  }

  Future<void> retryAllFailed() async {
    for (final job in _jobs) {
      if (job.status == JobStatus.failed) {
        job.status = JobStatus.pending;
        job.progress = 0;
        job.error = null;
      }
    }
    await _save();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _jobs.removeWhere((j) => j.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> clearCompleted() async {
    _jobs.removeWhere((j) => j.status == JobStatus.completed);
    await _save();
    notifyListeners();
  }

  int dailyCountForChannel(String channelId) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _jobs.where((j) =>
      j.channelId == channelId &&
      j.status == JobStatus.completed &&
      j.completedAt != null &&
      j.completedAt!.toIso8601String().substring(0, 10) == today &&
      j.destination == UploadDestination.youtube
    ).length;
  }

  /// All jobs sorted by most recent activity (completedAt / scheduledDate / added)
  List<UploadJob> get recentJobs {
    final all = List<UploadJob>.from(_jobs);
    all.sort((a, b) {
      final aDate = a.completedAt ?? a.scheduledDate ?? DateTime(0);
      final bDate = b.completedAt ?? b.scheduledDate ?? DateTime(0);
      return bDate.compareTo(aDate);
    });
    return all;
  }

  /// Scheduled jobs grouped by date key (yyyy-MM-dd) for a specific channel.
  /// If channelId is null, returns all channels.
  Map<String, List<UploadJob>> scheduledByDateForChannel(String? channelId) {
    final map = <String, List<UploadJob>>{};
    final filtered = channelId != null
        ? _jobs.where((j) => j.status == JobStatus.scheduled && j.channelId == channelId)
        : _jobs.where((j) => j.status == JobStatus.scheduled);
    for (final j in filtered) {
      final key = j.scheduledDate?.toIso8601String().substring(0, 10) ?? 'unknown';
      map.putIfAbsent(key, () => []).add(j);
    }
    final sorted = <String, List<UploadJob>>{};
    final keys = map.keys.toList()..sort();
    for (final k in keys) {
      sorted[k] = map[k]!;
    }
    return sorted;
  }

  /// All scheduled jobs (for backward compatibility)
  Map<String, List<UploadJob>> get scheduledByDate => scheduledByDateForChannel(null);

  List<UploadJob> get youtubeCompleted =>
      _jobs.where((j) => j.status == JobStatus.completed && j.uploadedToYoutube).toList()
        ..sort((a, b) => (b.completedAt ?? DateTime(0)).compareTo(a.completedAt ?? DateTime(0)));

  List<UploadJob> get telegramCompleted =>
      _jobs.where((j) => j.status == JobStatus.completed && j.uploadedToTelegram).toList()
        ..sort((a, b) => (b.completedAt ?? DateTime(0)).compareTo(a.completedAt ?? DateTime(0)));

  /// Today's YouTube uploads across every channel. Prefer
  /// [todayYoutubeCountForChannel] wherever a channel is selected — the
  /// 15-a-day budget is per channel, so a total is only the right number
  /// when no channel is in view.
  int get todayYoutubeCount => todayYoutubeCountForChannel(null);

  /// Today's Telegram uploads across every account on this device; see
  /// [todayTelegramCountForAccount] for the per-account number.
  int get todayTelegramCount => todayTelegramCountForAccount(null);

  List<String> get folders =>
      _jobs.map((j) => j.folder).whereType<String>().where((f) => f.isNotEmpty).toSet().toList()..sort();

  List<UploadJob> jobsInFolder(String folder) =>
      _jobs.where((j) => j.folder == folder).toList();

  Future<void> setFolder(String jobId, String? folder) async {
    final idx = _jobs.indexWhere((j) => j.id == jobId);
    if (idx == -1) return;
    _jobs[idx].folder = folder;
    await _save();
    notifyListeners();
  }

  Future<void> rescheduleForLater(String jobId, DateTime date) async {
    final idx = _jobs.indexWhere((j) => j.id == jobId);
    if (idx == -1) return;
    _jobs[idx].status = JobStatus.scheduled;
    _jobs[idx].scheduledDate = date;
    _jobs[idx].progress = 0;
    await _save();
    notifyListeners();
  }

  Future<void> resumePending(String jobId) async {
    final idx = _jobs.indexWhere((j) => j.id == jobId);
    if (idx == -1) return;
    if (_jobs[idx].status == JobStatus.scheduled && _jobs[idx].scheduledDate != null) {
      _jobs[idx].status = JobStatus.pending;
      _jobs[idx].scheduledDate = null;
      await _save();
      notifyListeners();
    }
  }

  List<UploadJob> get todayYoutubeJobs =>
      _jobs.where((j) =>
        j.status == JobStatus.completed &&
        j.completedAt != null &&
        j.completedAt!.toIso8601String().substring(0, 10) == DateTime.now().toIso8601String().substring(0, 10) &&
        j.uploadedToYoutube
      ).toList()
        ..sort((a, b) => (b.completedAt ?? DateTime(0)).compareTo(a.completedAt ?? DateTime(0)));

  List<UploadJob> get todayTelegramJobs =>
      _jobs.where((j) =>
        j.status == JobStatus.completed &&
        j.completedAt != null &&
        j.completedAt!.toIso8601String().substring(0, 10) == DateTime.now().toIso8601String().substring(0, 10) &&
        j.uploadedToTelegram
      ).toList()
        ..sort((a, b) => (b.completedAt ?? DateTime(0)).compareTo(a.completedAt ?? DateTime(0)));
}
