import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'background_service.dart';

enum JobStatus { pending, uploading, completed, failed, scheduled }

enum UploadDestination { youtube, telegram, both }

class UploadJob {
  final String id;
  final String assetId;
  String title;
  final String? filePath;
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

  UploadJob({
    required this.id,
    required this.assetId,
    required this.title,
    this.filePath,
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
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'assetId': assetId,
    'title': title,
    'filePath': filePath,
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
  };

  factory UploadJob.fromJson(Map<String, dynamic> json) => UploadJob(
    id: json['id'] as String,
    assetId: json['assetId'] as String,
    title: json['title'] as String,
    filePath: json['filePath'] as String?,
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
  );

  String get displayName =>
      title.isNotEmpty ? title : (filePath != null ? filePath!.split('/').last : assetId);

  bool get uploadedToYoutube => destination == UploadDestination.youtube || destination == UploadDestination.both;
  bool get uploadedToTelegram => destination == UploadDestination.telegram || destination == UploadDestination.both;
}

class UploadScheduler extends ChangeNotifier {
  static const int youtubeDailyLimit = 15;
  static const String _storageKey = 'upload_queue';
  static const _storage = FlutterSecureStorage();

  List<UploadJob> _jobs = [];
  DateTime _lastUiNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// Progress/status updates fire for every upload chunk; notifying the UI on
  /// each one saturates the main isolate, so these are rate-limited.
  void _notifyThrottled({int minIntervalMs = 300}) {
    final now = DateTime.now();
    if (now.difference(_lastUiNotify).inMilliseconds < minIntervalMs) return;
    _lastUiNotify = now;
    notifyListeners();
  }

  List<UploadJob> get jobs => List.unmodifiable(_jobs);
  int get totalCount => _jobs.length;
  int get pendingCount => _jobs.where((j) => j.status == JobStatus.pending).length;
  int get scheduledCount => _jobs.where((j) => j.status == JobStatus.scheduled).length;
  int get uploadingCount => _jobs.where((j) => j.status == JobStatus.uploading).length;
  int get completedCount => _jobs.where((j) => j.status == JobStatus.completed).length;
  int get failedCount => _jobs.where((j) => j.status == JobStatus.failed).length;

  int get todayYoutubeUploadedCount {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _jobs.where((j) =>
      j.status == JobStatus.completed &&
      j.completedAt != null &&
      j.completedAt!.toIso8601String().substring(0, 10) == today &&
      j.destination == UploadDestination.youtube
    ).length;
  }

  int get todayTelegramUploadedCount {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _jobs.where((j) =>
      j.status == JobStatus.completed &&
      j.completedAt != null &&
      j.completedAt!.toIso8601String().substring(0, 10) == today &&
      j.destination == UploadDestination.telegram
    ).length;
  }

  int todayYoutubeUploadedCountForChannel(String channelId) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _jobs.where((j) =>
      j.channelId == channelId &&
      j.status == JobStatus.completed &&
      j.completedAt != null &&
      j.completedAt!.toIso8601String().substring(0, 10) == today &&
      j.destination == UploadDestination.youtube
    ).length;
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
    final list = jsonDecode(data) as List;
    _jobs = list.map((e) => UploadJob.fromJson(e as Map<String, dynamic>)).toList();
    _rescheduleAfterRestart();
    notifyListeners();
  }

  Future<void> _save() async {
    final data = jsonEncode(_jobs.map((j) => j.toJson()).toList());
    await _storage.write(key: _storageKey, value: data);
    unawaited(updateBadgeCount(pendingCount + uploadingCount));
  }

  void _rescheduleAfterRestart() {
    final now = DateTime.now();
    for (final job in _jobs) {
      if (job.status == JobStatus.uploading) {
        job.status = JobStatus.pending;
        job.progress = 0;
      }
      // Convert scheduled jobs whose date has arrived to pending
      if (job.status == JobStatus.scheduled &&
          job.scheduledDate != null &&
          !job.scheduledDate!.isAfter(now)) {
        job.status = JobStatus.pending;
        job.scheduledDate = null;
      }
    }
  }

  Future<void> addJobs(List<Map<String, String>> videos, String channelId, String accountEmail, {UploadDestination destination = UploadDestination.youtube}) async {
    final today = DateTime.now();

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
        );
        _jobs.add(job);
      }
    } else {
      final todayStr = today.toIso8601String().substring(0, 10);

      // Count YouTube jobs already assigned to each date for this channel
      final dateCounts = <String, int>{};
      for (final j in _jobs.where((j) => j.channelId == channelId && j.destination == UploadDestination.youtube)) {
        String dateKey;
        if (j.status == JobStatus.completed && j.completedAt != null) {
          dateKey = j.completedAt!.toIso8601String().substring(0, 10);
        } else if (j.status == JobStatus.scheduled && j.scheduledDate != null) {
          dateKey = j.scheduledDate!.toIso8601String().substring(0, 10);
        } else if (j.status == JobStatus.pending && j.scheduledDate == null) {
          dateKey = todayStr;
        } else {
          continue;
        }
        dateCounts[dateKey] = (dateCounts[dateKey] ?? 0) + 1;
      }

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
        );

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

  UploadJob? claimNext() {
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

  Future<void> markCompleted(String id, {String youtubeVideoId = '', String telegramMessageId = ''}) async {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx == -1) return;
    _jobs[idx].status = JobStatus.completed;
    _jobs[idx].progress = 1.0;
    if (youtubeVideoId.isNotEmpty) _jobs[idx].youtubeVideoId = youtubeVideoId;
    if (telegramMessageId.isNotEmpty) _jobs[idx].telegramMessageId = telegramMessageId;
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

  int get todayYoutubeCount {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _jobs.where((j) =>
      j.status == JobStatus.completed &&
      j.completedAt != null &&
      j.completedAt!.toIso8601String().substring(0, 10) == today &&
      j.uploadedToYoutube
    ).length;
  }

  int get todayTelegramCount {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _jobs.where((j) =>
      j.status == JobStatus.completed &&
      j.completedAt != null &&
      j.completedAt!.toIso8601String().substring(0, 10) == today &&
      j.uploadedToTelegram
    ).length;
  }

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
