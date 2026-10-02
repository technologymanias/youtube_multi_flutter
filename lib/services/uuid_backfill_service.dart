import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';

import 'media_index.dart';
import 'telegram_service.dart';
import 'upload_scheduler.dart';
import 'uuid_backfill.dart';
import '../youtube_uploader.dart';

/// Secure-storage key holding the remote ids a back-fill run already rewrote,
/// so an interrupted run resumes instead of paying for the same quota twice.
const String kBackfillDoneKey = 'uuid_backfill_done';

/// How far a back-fill run got.
class ApplyProgress {
  ApplyProgress({
    this.total = 0,
    this.localWritten = 0,
    this.telegramEdited = 0,
    this.youtubeEdited = 0,
    this.skipped = 0,
    this.failed = 0,
    this.currentLabel,
  });

  int total;
  int localWritten;
  int telegramEdited;
  int youtubeEdited;
  int skipped;
  int failed;
  String? currentLabel;

  int get finished => localWritten + telegramEdited + youtubeEdited + skipped + failed;

  /// YouTube charges 50 units for every `videos.update`.
  int get youtubeQuotaUsed => youtubeEdited * YouTubeUploader.updateQuotaCost;

  ApplyProgress copy() => ApplyProgress(
        total: total,
        localWritten: localWritten,
        telegramEdited: telegramEdited,
        youtubeEdited: youtubeEdited,
        skipped: skipped,
        failed: failed,
        currentLabel: currentLabel,
      );
}

/// Outcome of one apply pass.
class ApplyReport {
  const ApplyReport({
    this.localWritten = 0,
    this.telegramEdited = 0,
    this.youtubeEdited = 0,
    this.skipped = 0,
    this.failures = const [],
  });

  final int localWritten;
  final int telegramEdited;
  final int youtubeEdited;
  final int skipped;
  final List<String> failures;

  bool get ok => failures.isEmpty;
  int get youtubeQuotaUsed => youtubeEdited * YouTubeUploader.updateQuotaCost;
}

/// Gathers the local/remote candidates a match needs, then writes the decided
/// UUIDs back out.
///
/// Split from the UI on purpose: every method is awaitable and reports
/// progress through a callback, so the review page only owns rendering.
class UuidBackfillService {
  UuidBackfillService({
    required this.scheduler,
    this.telegram,
    MediaIndex? index,
  })  : index = index ?? MediaIndex.instance,
        _storage = const FlutterSecureStorage();

  final UploadScheduler scheduler;
  final TelegramService? telegram;
  final MediaIndex index;
  final FlutterSecureStorage _storage;

  static final DateFormat _titleFormat = DateFormat('dd MMMM yyyy HH:mm');

  // ── Collection ──────────────────────────────────────────────────────────

  /// Everything already in the queue, plus up to [maxGalleryAssets] gallery
  /// items not yet queued.
  ///
  /// Queue rows win on conflict: their title is the one that was actually
  /// uploaded, whereas a gallery title is re-derived from the timestamp and
  /// can differ by a minute for anything queued manually.
  Future<List<LocalCandidate>> collectLocal({int maxGalleryAssets = 3000}) async {
    final byAsset = <String, LocalCandidate>{};

    for (final job in scheduler.jobs) {
      if (job.assetId.isEmpty) continue;
      byAsset[job.assetId] = LocalCandidate(
        assetId: job.assetId,
        title: MediaIndex.stripTag(job.title),
        fileName: job.filePath?.split('/').last,
        createdAt: job.completedAt ?? job.scheduledDate,
      );
    }

    try {
      final album = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
      );
      if (album.isNotEmpty) {
        const pageSize = 500;
        var fetched = 0;
        for (var page = 0; fetched < maxGalleryAssets; page++) {
          final assets = await album.first.getAssetListPaged(
            page: page,
            size: pageSize,
          );
          if (assets.isEmpty) break;
          fetched += assets.length;
          for (final asset in assets) {
            if (byAsset.containsKey(asset.id)) continue;
            String? fileName;
            int? size;
            try {
              fileName = await asset.titleAsync;
            } catch (_) {}
            try {
              size = await asset.fileSize;
            } catch (_) {}
            byAsset[asset.id] = LocalCandidate(
              assetId: asset.id,
              title: _titleFormat.format(asset.createDateTime),
              fileName: (fileName == null || fileName.isEmpty)
                  ? null
                  : fileName,
              createdAt: asset.createDateTime,
              fileSize: size,
              durationSec: asset.type == AssetType.video
                  ? asset.duration
                  : null,
              kind: _kindOf(asset),
            );
          }
          if (assets.length < pageSize) break;
        }
      }
    } catch (e) {
      debugPrint('[Backfill] gallery scan failed: $e');
    }

    return byAsset.values.toList();
  }

  static String _kindOf(AssetEntity asset) {
    switch (asset.type) {
      case AssetType.video:
        return 'video';
      case AssetType.image:
        return 'photo';
      case AssetType.audio:
        return 'audio';
      case AssetType.other:
        return 'file';
    }
  }

  /// The signed-in channel's uploads, newest first.
  Future<List<RemoteCandidate>> collectYoutube(
    String token, {
    int maxPages = 40,
    void Function(int loaded)? onProgress,
  }) async {
    final out = <RemoteCandidate>[];
    if (token.isEmpty) return out;

    final headers = {'Authorization': 'Bearer $token'};
    final channelRes = await http.get(
      Uri.parse(
          'https://www.googleapis.com/youtube/v3/channels?part=contentDetails&mine=true'),
      headers: headers,
    );
    if (channelRes.statusCode != 200) {
      throw Exception('Could not list the channel '
          '(${channelRes.statusCode})');
    }
    final channelData = jsonDecode(channelRes.body);
    final uploadsId = channelData['items']?[0]?['contentDetails']
            ?['relatedPlaylists']?['uploads'] as String?;
    if (uploadsId == null || uploadsId.isEmpty) return out;

    String? pageToken;
    final ids = <String>[];
    final meta = <String, Map<String, dynamic>>{};

    for (var page = 0; page < maxPages; page++) {
      final uri = Uri.parse(
        'https://www.googleapis.com/youtube/v3/playlistItems'
        '?part=snippet&playlistId=$uploadsId&maxResults=50'
        '${pageToken == null ? '' : '&pageToken=$pageToken'}',
      );
      final res = await http.get(uri, headers: headers);
      if (res.statusCode != 200) break;
      final data = jsonDecode(res.body);
      for (final item in (data['items'] as List?) ?? const []) {
        final sn = item['snippet'] as Map? ?? {};
        final rid = sn['resourceId']?['videoId'] as String? ?? '';
        if (rid.isEmpty) continue;
        ids.add(rid);
        meta[rid] = {
          'title': sn['title'] as String? ?? '',
          'date': sn['publishedAt'] as String?,
        };
      }
      pageToken = data['nextPageToken'] as String?;
      onProgress?.call(ids.length);
      if (pageToken == null || pageToken.isEmpty) break;
    }

    // Duration lives on videos.list, not playlistItems — and it is one of the
    // few signals that can separate two same-minute uploads.
    for (var start = 0; start < ids.length; start += 50) {
      final chunk = ids.sublist(
          start, start + 50 > ids.length ? ids.length : start + 50);
      final res = await http.get(
        Uri.parse(
            'https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=${chunk.join(',')}'),
        headers: headers,
      );
      if (res.statusCode != 200) continue;
      for (final v in (jsonDecode(res.body)['items'] as List?) ?? const []) {
        final rid = v['id'] as String? ?? '';
        final dur = v['contentDetails']?['duration'] as String?;
        if (rid.isNotEmpty && meta.containsKey(rid)) {
          meta[rid]!['durationSec'] = _parseIsoDuration(dur);
        }
      }
    }

    for (final id in ids) {
      final m = meta[id]!;
      out.add(RemoteCandidate(
        kind: RemoteKind.youtube,
        remoteId: id,
        title: m['title'] as String? ?? '',
        date: m['date'] != null
            ? DateTime.tryParse(m['date'] as String)
            : null,
        durationSec: m['durationSec'] as int?,
        mediaKind: 'video',
      ));
    }
    return out;
  }

  /// `PT1H2M3S` → seconds.
  static int? _parseIsoDuration(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final m = RegExp(r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$').firstMatch(iso);
    if (m == null) return null;
    final h = int.tryParse(m.group(1) ?? '') ?? 0;
    final min = int.tryParse(m.group(2) ?? '') ?? 0;
    final s = int.tryParse(m.group(3) ?? '') ?? 0;
    return h * 3600 + min * 60 + s;
  }

  /// Everything in Telegram Saved Messages, fetched fresh.
  Future<List<RemoteCandidate>> collectTelegram({
    int maxMessages = 5000,
    void Function(int loaded)? onProgress,
  }) async {
    final tel = telegram;
    if (tel == null || !tel.isAuthenticated) return const [];
    final items = await tel.getSavedMessages(
      maxMessages: maxMessages,
      onPage: (soFar) => onProgress?.call(soFar.length),
    );
    final accountKey = tel.accountKey ?? '';
    return [
      for (final m in items)
        RemoteCandidate(
          kind: RemoteKind.telegram,
          remoteId: '${m.id}',
          title: m.caption ?? '',
          accountKey: accountKey,
          fileName: m.fileName,
          date: m.date,
          fileSize: m.fileSize,
          mediaKind: _tgKind(m),
        ),
    ];
  }

  static String _tgKind(SavedMessageItem m) {
    switch (m.mediaType) {
      case SavedMediaType.photo:
        return 'photo';
      case SavedMediaType.video:
        return 'video';
      case SavedMediaType.audio:
        return 'audio';
      case SavedMediaType.document:
        return 'file';
      case SavedMediaType.none:
        return 'file';
    }
  }

  // ── Apply ───────────────────────────────────────────────────────────────

  /// Writes the decided UUIDs out, in the cheapest order first:
  ///
  ///  1. local index — free, instant, and the source of truth;
  ///  2. Telegram caption edits — free;
  ///  3. YouTube title rewrites — 50 quota units each, so they come last and
  ///     are checkpointed: a quota error mid-run leaves everything before it
  ///     intact and the rest resumable.
  ///
  /// [uploader] is only required when there are YouTube rows to rewrite.
  Future<ApplyReport> apply(
    List<ProposedMatch> matches, {
    YouTubeUploader? uploader,
    void Function(ApplyProgress)? onProgress,
  }) async {
    await index.ensureLoaded();
    final done = await _loadDone();
    final progress = ApplyProgress(total: matches.length);
    final failures = <String>[];

    void report([String? label]) {
      progress.currentLabel = label;
      onProgress?.call(progress.copy());
    }

    report('Recording UUIDs locally…');

    // Pass 1 — local. No remote call, no quota, and it makes every later
    // step idempotent: re-running finds the identity already present.
    final resolved = <ProposedMatch, MediaIdentity>{};
    for (final m in matches) {
      if (!m.isMatched) {
        progress.skipped++;
        continue;
      }
      try {
        final identity = await _writeLocal(m);
        resolved[m] = identity;
        progress.localWritten++;
      } catch (e) {
        progress.failed++;
        failures.add('${m.remote.kind.name}/${m.remote.remoteId}: $e');
      }
      report();
    }

    // Pass 2 — Telegram. Free, so a failure here costs nothing but a retry.
    final tel = telegram;
    for (final m in resolved.entries) {
      final match = m.key;
      if (!match.needsTelegramCaption || !match.needsRemoteRewrite) continue;
      final key = 'tg:${match.remote.remoteId}';
      if (done.contains(key)) {
        progress.skipped++;
        report();
        continue;
      }
      final identity = m.value;
      try {
        if (tel == null || !tel.isAuthenticated) {
          throw Exception('Telegram is not signed in');
        }
        final caption = rebuildCaption(
          match.remote.title,
          identity.title,
          identity.shortTag,
        );
        await tel.editMessageCaption(
          int.parse(match.remote.remoteId),
          caption,
        );
        await index.link(
          uuid: identity.uuid,
          telegramMessageId: match.remote.remoteId,
          telegramAccountKey: match.remote.accountKey,
        );
        await _markDone(key, done);
        progress.telegramEdited++;
      } catch (e) {
        progress.failed++;
        failures.add('telegram/${match.remote.remoteId}: $e');
      }
      report();
    }

    // Pass 3 — YouTube. Quota-bearing, therefore checkpointed.
    for (final m in resolved.entries) {
      final match = m.key;
      if (!match.needsYoutubeTitle || !match.needsRemoteRewrite) continue;
      final key = 'yt:${match.remote.remoteId}';
      if (done.contains(key)) {
        progress.skipped++;
        report();
        continue;
      }
      final identity = m.value;
      try {
        if (uploader == null) {
          throw Exception('Not signed in to YouTube');
        }
        await uploader.updateVideoTitle(
          match.remote.remoteId,
          MediaIndex.fitTitle(identity.title, identity.shortTag),
        );
        await index.link(
          uuid: identity.uuid,
          youtubeVideoId: match.remote.remoteId,
        );
        await _markDone(key, done);
        progress.youtubeEdited++;
      } catch (e) {
        progress.failed++;
        failures.add('youtube/${match.remote.remoteId}: $e');
        // A 403/429 means the scope or the quota is exhausted — every
        // remaining YouTube row would fail the same way, so stop paying for
        // attempts and report.
        final text = '$e';
        if (text.contains('403') || text.contains('429') || text.contains('quota')) {
          failures.add('YouTube stopped the run — remaining title updates '
              'were not attempted');
          break;
        }
      }
      report();
    }

    await index.flush();
    report('Done');
    return ApplyReport(
      localWritten: progress.localWritten,
      telegramEdited: progress.telegramEdited,
      youtubeEdited: progress.youtubeEdited,
      skipped: progress.skipped,
      failures: failures,
    );
  }

  /// Registers the identity behind one accepted match.
  ///
  /// The UUID is always chosen this way: reuse the one the index already has
  /// for this asset, otherwise keep a tag the remote already wears, otherwise
  /// mint one. Nothing here ever rewrites an existing id.
  Future<MediaIdentity> _writeLocal(ProposedMatch m) async {
    final existing = m.identity;
    final local = m.local;
    final tag = m.existingTag;

    MediaIdentity identity;
    if (existing != null) {
      identity = existing;
    } else if (tag != null) {
      identity = await index.adoptTag(
        shortTag: tag,
        assetId: local?.assetId,
        title: MediaIndex.stripTag(m.remote.title),
        fileName: local?.fileName ?? m.remote.fileName,
        kind: m.remote.mediaKind,
        createdAt: local?.createdAt ?? m.remote.date,
        fileSize: local?.fileSize ?? m.remote.fileSize,
        durationSec: local?.durationSec ?? m.remote.durationSec,
      );
    } else {
      identity = await index.resolveOrCreate(
        assetId: local?.assetId,
        title: MediaIndex.stripTag(m.remote.title),
        fileName: local?.fileName ?? m.remote.fileName,
        kind: m.remote.mediaKind,
        createdAt: local?.createdAt ?? m.remote.date,
        fileSize: local?.fileSize ?? m.remote.fileSize,
        durationSec: local?.durationSec ?? m.remote.durationSec,
      );
    }

    if (m.remote.kind == RemoteKind.youtube) {
      await index.link(
        uuid: identity.uuid,
        assetId: local?.assetId,
        youtubeVideoId: m.remote.remoteId,
        fileName: local?.fileName ?? m.remote.fileName,
      );
    } else {
      await index.link(
        uuid: identity.uuid,
        assetId: local?.assetId,
        telegramMessageId: m.remote.remoteId,
        telegramAccountKey: m.remote.accountKey,
        fileName: local?.fileName ?? m.remote.fileName,
      );
    }
    return identity;
  }

  /// Rebuilds a caption/title so it keeps its `#folder` header lines but
  /// carries the current UUID tag.
  static String rebuildCaption(
    String? existing,
    String baseTitle,
    String shortTag, {
    int maxLen = 1024,
  }) {
    final header = <String>[];
    if (existing != null && existing.isNotEmpty) {
      for (final line in existing.split('\n')) {
        if (line.trim().startsWith('#')) {
          header.add(line.trimRight());
        } else {
          break;
        }
      }
    }
    final body = MediaIndex.fitTitle(baseTitle, shortTag, maxLen: maxLen);
    if (header.isEmpty) return body;
    return '${header.join('\n')}\n$body';
  }

  Future<Set<String>> _loadDone() async {
    try {
      final raw = await _storage.read(key: kBackfillDoneKey);
      if (raw == null || raw.isEmpty) return <String>{};
      return ((jsonDecode(raw) as List?) ?? const [])
          .map((e) => '$e')
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _markDone(String key, Set<String> done) async {
    done.add(key);
    try {
      await _storage.write(key: kBackfillDoneKey, value: jsonEncode(done.toList()));
    } catch (e) {
      debugPrint('[Backfill] could not checkpoint: $e');
    }
  }

  /// Forgets the checkpoint so a user can deliberately re-run a pass.
  Future<void> resetCheckpoint() async {
    try {
      await _storage.delete(key: kBackfillDoneKey);
    } catch (_) {}
  }
}
