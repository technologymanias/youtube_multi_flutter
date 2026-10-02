import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One entry of the upload queue that should be checked against YouTube.
class YoutubeUploadProbe {
  const YoutubeUploadProbe({required this.key, this.videoId, this.title});

  /// Caller-scoped id (the upload job id).
  final String key;

  /// YouTube video id, when the upload recorded one.
  final String? videoId;

  /// Title used to find uploads that predate recorded video ids.
  final String? title;
}

/// Result of one round of checking uploads against YouTube.
///
/// Only what was actually determined is listed. Anything in neither set was
/// not verifiable this round (failed request, no id, no title) and must keep
/// whatever the caller already believed about it — a failed probe is not
/// proof of anything.
class YoutubeUploadVerdict {
  const YoutubeUploadVerdict({required this.present, required this.absent});

  /// Confirmed still on the channel.
  final Set<String> present;

  /// Confirmed no longer on the channel.
  final Set<String> absent;
}

/// Checks the upload queue against the channel it uploads to, so the local
/// grid's YT badge means "still on YouTube" instead of "was on YouTube when
/// it finished" — the same contract [TelegramService.verifyUploads] gives the
/// TG badge.
class YoutubeSync {
  static const int _idPageSize = 50;
  static const int _titlePages = 10;

  /// Returns null when nothing could be verified at all (no token, quota or
  /// network failure), so the caller can keep its previous answer instead of
  /// wiping it. Never reports an upload as deleted without positive evidence.
  static Future<YoutubeUploadVerdict?> verifyUploads(
    String? accessToken,
    List<YoutubeUploadProbe> probes,
  ) async {
    final present = <String>{};
    final absent = <String>{};
    if (probes.isEmpty) {
      return YoutubeUploadVerdict(present: present, absent: absent);
    }
    final token = accessToken;
    if (token == null || token.isEmpty) return null;

    final headers = {'Authorization': 'Bearer $token'};
    var decided = 0;

    // Preferred probe: videos.list answers for a deleted video by simply not
    // returning it, and private videos we own are still returned.
    final byId = <String, String>{};
    final byTitle = <YoutubeUploadProbe>[];
    for (final p in probes) {
      final id = p.videoId;
      if (id != null && id.trim().isNotEmpty) {
        byId[p.key] = id.trim();
      } else if (p.title != null && p.title!.trim().isNotEmpty) {
        byTitle.add(p);
      }
    }

    if (byId.isNotEmpty) {
      final alive = <String>{};
      final ids = byId.values.toSet().toList();
      var ok = true;
      for (var start = 0; start < ids.length && ok; start += _idPageSize) {
        final end = start + _idPageSize > ids.length
            ? ids.length
            : start + _idPageSize;
        final chunk = ids.sublist(start, end);
        try {
          final res = await http
              .get(
                Uri.parse(
                    'https://www.googleapis.com/youtube/v3/videos?part=id&id=${chunk.join(',')}'),
                headers: headers,
              )
              .timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) {
            debugPrint('youtube verify ids: HTTP ${res.statusCode}');
            ok = false;
            break;
          }
          final items = jsonDecode(res.body)['items'] as List? ?? const [];
          for (final item in items) {
            final id = item is Map ? item['id'] as String? : null;
            if (id != null) alive.add(id);
          }
        } catch (e) {
          debugPrint('youtube verify ids failed: $e');
          ok = false;
          break;
        }
      }
      // A failed page says nothing about any id, so none of them are judged.
      if (ok) {
        for (final e in byId.entries) {
          if (alive.contains(e.value)) {
            present.add(e.key);
          } else {
            absent.add(e.key);
          }
          decided++;
        }
      }
    }

    if (byTitle.isNotEmpty) {
      final titles = await _uploadsTitles(token, headers);
      if (titles != null) {
        for (final p in byTitle) {
          if (titles.contains(p.title!.trim())) {
            present.add(p.key);
          } else {
            absent.add(p.key);
          }
          decided++;
        }
      }
    }

    if (decided == 0) return null;
    debugPrint('youtube verify: ${probes.length} probed, '
        '${present.length} present, ${absent.length} gone');
    return YoutubeUploadVerdict(present: present, absent: absent);
  }

  /// Titles currently on the channel's uploads playlist, or null when they
  /// could not be listed — which leaves every title probe undecidable rather
  /// than marking the whole library deleted.
  static Future<Set<String>?> _uploadsTitles(
      String token, Map<String, String> headers) async {
    try {
      final channelRes = await http
          .get(
            Uri.parse(
                'https://www.googleapis.com/youtube/v3/channels?part=contentDetails&mine=true'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 20));
      if (channelRes.statusCode != 200) {
        debugPrint('youtube verify titles: HTTP ${channelRes.statusCode}');
        return null;
      }
      final uploadsId = jsonDecode(channelRes.body)['items']?[0]?['contentDetails']
          ?['relatedPlaylists']?['uploads'] as String?;
      if (uploadsId == null) return null;

      final titles = <String>{};
      String? pageToken;
      for (var page = 0; page < _titlePages; page++) {
        var url =
            'https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&playlistId=$uploadsId&maxResults=50';
        if (pageToken != null) url += '&pageToken=$pageToken';
        final res = await http
            .get(Uri.parse(url), headers: headers)
            .timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          debugPrint('youtube verify titles: HTTP ${res.statusCode}');
          return titles.isEmpty ? null : titles;
        }
        final data = jsonDecode(res.body);
        for (final item in (data['items'] as List?) ?? const []) {
          if (item is! Map) continue;
          final snippet = item['snippet'];
          final title = snippet is Map ? snippet['title'] as String? : null;
          if (title != null && title.isNotEmpty) titles.add(title.trim());
        }
        pageToken = data['nextPageToken'] as String?;
        if (pageToken == null) break;
      }
      return titles;
    } catch (e) {
      debugPrint('youtube verify titles failed: $e');
      return null;
    }
  }
}
