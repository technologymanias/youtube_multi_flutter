import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// One media item's cross-platform identity.
///
/// The same [uuid] is what links a local gallery asset to its YouTube video
/// (via a tag appended to the title) and its Telegram message (via the same
/// tag in the caption). Everything else recorded here is a *matching signal*
/// used later when back-filling items that were uploaded before UUIDs existed.
class MediaIdentity {
  /// Full RFC-4122 v4 UUID — the canonical id, never displayed.
  final String uuid;

  /// First 8 hex characters of [uuid], guaranteed to contain at least one
  /// letter so an all-digit date fragment can never be mistaken for a tag.
  /// This is what appears in titles and captions: `[a1b2c3d4]`.
  final String shortTag;

  /// `photo_manager` asset id. Null for entries discovered only remotely;
  /// filled in later by [link] when a back-fill pairs the item with its
  /// gallery asset.
  String? assetId;

  /// YouTube video id, once known.
  String? youtubeVideoId;

  /// Telegram message id per signed-in Telegram account (account key → id).
  final Map<String, String> telegramMessageIds;

  /// Base title — the date-formatted display title *without* the tag.
  String title;

  /// Original filename (`AssetEntity.titleAsync` / Telegram file attribute).
  String? fileName;

  /// `video` | `photo` | `file` | `audio`.
  final String kind;

  final DateTime createdAt;
  final int? fileSize;
  final int? durationSec;

  MediaIdentity({
    required this.uuid,
    required this.shortTag,
    this.assetId,
    this.youtubeVideoId,
    Map<String, String>? telegramMessageIds,
    required this.title,
    this.fileName,
    this.kind = 'video',
    DateTime? createdAt,
    this.fileSize,
    this.durationSec,
  })  : telegramMessageIds = telegramMessageIds ?? <String, String>{},
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'shortTag': shortTag,
        'assetId': assetId,
        'youtubeVideoId': youtubeVideoId,
        'telegramMessageIds': telegramMessageIds,
        'title': title,
        'fileName': fileName,
        'kind': kind,
        'createdAt': createdAt.toIso8601String(),
        'fileSize': fileSize,
        'durationSec': durationSec,
      };

  factory MediaIdentity.fromJson(Map<String, dynamic> json) => MediaIdentity(
        uuid: json['uuid'] as String,
        shortTag: json['shortTag'] as String,
        assetId: json['assetId'] as String?,
        youtubeVideoId: json['youtubeVideoId'] as String?,
        telegramMessageIds: {
          for (final e in ((json['telegramMessageIds'] as Map?) ?? const {})
              .entries)
            '${e.key}': '${e.value}',
        },
        title: json['title'] as String? ?? '',
        fileName: json['fileName'] as String?,
        kind: json['kind'] as String? ?? 'video',
        createdAt: json['createdAt'] != null
            ? DateTime.parse(json['createdAt'] as String)
            : null,
        fileSize: (json['fileSize'] as num?)?.toInt(),
        durationSec: (json['durationSec'] as num?)?.toInt(),
      );

  MediaIdentity copyWith({
    String? youtubeVideoId,
    String? title,
    String? fileName,
    int? fileSize,
    int? durationSec,
  }) =>
      MediaIdentity(
        uuid: uuid,
        shortTag: shortTag,
        assetId: assetId,
        youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
        telegramMessageIds: Map<String, String>.from(telegramMessageIds),
        title: title ?? this.title,
        fileName: fileName ?? this.fileName,
        kind: kind,
        createdAt: createdAt,
        fileSize: fileSize ?? this.fileSize,
        durationSec: durationSec ?? this.durationSec,
      );
}

/// The registry that answers "what is this item's UUID?" for every
/// destination, and "which local asset is this?" for every remote id.
///
/// Persisted as one JSON blob in [FlutterSecureStorage] under
/// [`media_index_v1`]. Lazy singleton: [ensureLoaded] is idempotent so any
/// caller can await it without worrying about construction order.
class MediaIndex extends ChangeNotifier {
  static const String storageKey = 'media_index_v1';
  static const _storage = FlutterSecureStorage();
  static const _uuid = Uuid();

  static final MediaIndex instance = MediaIndex._();
  factory MediaIndex() => instance;
  MediaIndex._();

  final Map<String, MediaIdentity> _byUuid = {};
  bool _loaded = false;
  bool _saving = false;

  List<MediaIdentity> get entries =>
      List<MediaIdentity>.unmodifiable(_byUuid.values);

  int get length => _byUuid.length;
  bool get isLoaded => _loaded;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final data = await _storage.read(key: storageKey);
    if (data == null || data.isEmpty) return;
    try {
      final decoded = jsonDecode(data);
      final list = decoded is List
          ? decoded
          : ((decoded is Map<String, dynamic> ? decoded['entries'] : null)
                  as List?) ??
              const [];
      for (final e in list) {
        if (e is! Map) continue;
        final id = MediaIdentity.fromJson(Map<String, dynamic>.from(e));
        _byUuid[id.uuid] = id;
      }
    } catch (e) {
      debugPrint('[MediaIndex] failed to parse store, starting empty: $e');
    }
  }

  Future<void> _save() async {
    final data = jsonEncode(<String, dynamic>{
      'version': 1,
      'entries': _byUuid.values.map((e) => e.toJson()).toList(),
    });
    // Writes are coalesced: several lookups may resolve in the same tick and
    // each would otherwise rewrite the whole blob.
    if (_saving) return;
    _saving = true;
    try {
      await _storage.write(key: storageKey, value: data);
    } finally {
      _saving = false;
    }
  }

  // ── Tag helpers ────────────────────────────────────────────────────────

  /// `[a1b2c3d4]` — deliberately only lowercase hex.
  static final RegExp _tagPattern = RegExp(r'\[([0-9a-f]{8})\]');

  /// True when [candidate] could be one of our tags: 8 hex chars containing
  /// at least one `a-f`. Without the letter requirement an all-digit title
  /// fragment such as `[20261002]` would parse as a tag.
  static bool isShortTag(String candidate) {
    final t = candidate.toLowerCase();
    return t.length == 8 &&
        RegExp(r'^[0-9a-f]+$').hasMatch(t) &&
        t.contains(RegExp('[a-f]'));
  }

  /// Extracts the short tag from a remote title or caption, or null.
  static String? parseTag(String? text) {
    if (text == null || text.isEmpty) return null;
    for (final m in _tagPattern.allMatches(text)) {
      final t = m.group(1)!;
      if (isShortTag(t)) return t;
    }
    return null;
  }

  /// `Some Title [a1b2c3d4]` — idempotent: an existing tag is replaced, not
  /// stacked.
  static String encodeTag(String baseTitle, String? shortTag) {
    final stripped = stripTag(baseTitle);
    if (shortTag == null || shortTag.isEmpty) return stripped;
    return '$stripped [$shortTag]'.trim();
  }

  /// The title/caption with any tag removed, plus surrounding whitespace.
  static String stripTag(String text) {
    var out = text.trim();
    String? last;
    // Loop: legacy double-tagged titles from a crashed run can stack.
    while (out != last) {
      last = out;
      out = out
          .replaceAll(RegExp(r'\s*\[[0-9a-f]{8}\]'), '')
          .trimRight();
    }
    return out.trim();
  }

  /// Encodes a tag and enforces YouTube's 100-character title limit.
  ///
  /// The tag itself is never sacrificed — only the readable part of the title
  /// is shortened, because a title that lost its tag can no longer be matched
  /// back to its local asset. Returns a string of at most [maxLen].
  static String fitTitle(String baseTitle, String? shortTag,
      {int maxLen = 100}) {
    final tag = (shortTag == null || shortTag.isEmpty) ? null : ' [$shortTag]';
    if (tag == null) {
      final stripped = stripTag(baseTitle);
      return stripped.length <= maxLen
          ? stripped
          : stripped.substring(0, maxLen).trimRight();
    }
    if (tag.length + 1 >= maxLen) return tag.trim(); // pathological
    final room = maxLen - tag.length;
    final stripped = stripTag(baseTitle);
    final base = stripped.length <= room - 1
        ? stripped
        : '${stripped.substring(0, room - 1).trimRight()}…';
    return '$base$tag';
  }

  // ── Lookups ────────────────────────────────────────────────────────────

  MediaIdentity? byUuid(String? uuid) =>
      uuid == null ? null : _byUuid[uuid];

  MediaIdentity? byShortTag(String? tag) {
    if (tag == null || tag.isEmpty) return null;
    final t = tag.toLowerCase();
    for (final e in _byUuid.values) {
      if (e.shortTag == t) return e;
    }
    return null;
  }

  MediaIdentity? byAssetId(String? assetId) {
    if (assetId == null || assetId.isEmpty) return null;
    for (final e in _byUuid.values) {
      if (e.assetId == assetId) return e;
    }
    return null;
  }

  MediaIdentity? byYoutubeVideoId(String? videoId) {
    if (videoId == null || videoId.isEmpty) return null;
    for (final e in _byUuid.values) {
      if (e.youtubeVideoId == videoId) return e;
    }
    return null;
  }

  MediaIdentity? byTelegramMessageId(String messageId, {String? accountKey}) {
    if (messageId.isEmpty) return null;
    for (final e in _byUuid.values) {
      if (accountKey != null &&
          e.telegramMessageIds[accountKey] == messageId) {
        return e;
      }
      if (accountKey == null &&
          e.telegramMessageIds.containsValue(messageId)) {
        return e;
      }
    }
    return null;
  }

  /// Finds an entry whose [title] or [fileName] equals [candidate]
  /// (tag-stripped, case-sensitive on the date title, insensitive on the
  /// filename). Used by the back-fill matcher.
  MediaIdentity? byTitle(String? candidate) {
    if (candidate == null || candidate.isEmpty) return null;
    final needle = stripTag(candidate);
    if (needle.isEmpty) return null;
    for (final e in _byUuid.values) {
      if (stripTag(e.title) == needle) return e;
      final fn = e.fileName;
      if (fn != null && fn.toLowerCase() == needle.toLowerCase()) return e;
    }
    return null;
  }

  // ── Mutation ───────────────────────────────────────────────────────────

  String _freshShortTag() {
    final used = <String>{for (final e in _byUuid.values) e.shortTag};
    for (var attempt = 0; attempt < 64; attempt++) {
      final uuid = _uuid.v4();
      var tag = uuid.replaceAll('-', '').substring(0, 8);
      // Guarantee a letter so `isShortTag` accepts it.
      if (!tag.contains(RegExp('[a-f]'))) {
        tag = '${tag.substring(0, 7)}a';
      }
      if (!used.contains(tag)) return tag;
    }
    // 8 hex chars with a forced letter: reaching here needs ~2^31 tries.
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}a'
        .padRight(8, '0')
        .substring(0, 8);
  }

  /// Resolves the identity for a local asset, **reusing the existing UUID if
  /// the asset is already indexed** — this is the rule that keeps YouTube and
  /// Telegram on the same id when the same file is uploaded to both.
  Future<MediaIdentity> resolveOrCreate({
    String? assetId,
    String? title,
    String? fileName,
    String kind = 'video',
    DateTime? createdAt,
    int? fileSize,
    int? durationSec,
    String? existingUuid,
  }) async {
    await ensureLoaded();

    MediaIdentity? found;
    if (existingUuid != null && existingUuid.isNotEmpty) {
      found = _byUuid[existingUuid];
    }
    found ??= assetId == null || assetId.isEmpty ? null : byAssetId(assetId);
    if (found != null) {
      // Refresh mutable matching signals on every touch — a later scan may
      // learn the filename or size that the first pass never saw.
      final updated = found.copyWith(
        title: (title != null && title.isNotEmpty) ? title : found.title,
        fileName: fileName ?? found.fileName,
        fileSize: fileSize ?? found.fileSize,
        durationSec: durationSec ?? found.durationSec,
      );
      _byUuid[updated.uuid] = updated;
      unawaited(_save());
      return updated;
    }

    final uuid = _uuid.v4();
    final identity = MediaIdentity(
      uuid: uuid,
      shortTag: _freshShortTag(),
      assetId: (assetId == null || assetId.isEmpty) ? null : assetId,
      title: title ?? '',
      fileName: fileName,
      kind: kind,
      createdAt: createdAt,
      fileSize: fileSize,
      durationSec: durationSec,
    );
    _byUuid[uuid] = identity;
    unawaited(_save());
    notifyListeners();
    return identity;
  }

  /// Registers (or updates) an already-known UUID so its remote ids are
  /// recorded. Returns null when [uuid] is unknown — the caller should fall
  /// back to [resolveOrCreate].
  Future<MediaIdentity?> link({
    required String uuid,
    String? assetId,
    String? youtubeVideoId,
    String? telegramMessageId,
    String? telegramAccountKey,
    String? title,
    String? fileName,
  }) async {
    await ensureLoaded();
    final existing = _byUuid[uuid];
    if (existing == null) return null;
    if (assetId != null && assetId.isNotEmpty) existing.assetId = assetId;
    if (youtubeVideoId != null && youtubeVideoId.isNotEmpty) {
      existing.youtubeVideoId = youtubeVideoId;
    }
    if (telegramMessageId != null && telegramMessageId.isNotEmpty) {
      existing.telegramMessageIds[telegramAccountKey ?? ''] =
          telegramMessageId;
    }
    if (title != null && title.isNotEmpty) existing.title = title;
    if (fileName != null && fileName.isNotEmpty) existing.fileName = fileName;
    unawaited(_save());
    notifyListeners();
    return existing;
  }

  /// Inserts a pre-built entry (back-fill path) if its UUID is new.
  Future<MediaIdentity> put(MediaIdentity identity) async {
    await ensureLoaded();
    _byUuid[identity.uuid] = identity;
    unawaited(_save());
    notifyListeners();
    return identity;
  }

  /// Registers an item that already carries a tag this index has never seen.
  ///
  /// Used by back-fill: the tag came from a build (or device) with its own
  /// index, so it is authoritative — we keep it rather than minting a second
  /// id for the same file. A fresh v4 UUID becomes the primary key while
  /// [shortTag] stays as written.
  Future<MediaIdentity> adoptTag({
    required String shortTag,
    String? assetId,
    String? title,
    String? fileName,
    String kind = 'video',
    DateTime? createdAt,
    int? fileSize,
    int? durationSec,
  }) async {
    await ensureLoaded();
    final tag = shortTag.toLowerCase();
    final existing = byShortTag(tag);
    if (existing != null) {
      if (assetId != null && assetId.isNotEmpty) existing.assetId = assetId;
      if (title != null && title.isNotEmpty) existing.title = title;
      if (fileName != null && fileName.isNotEmpty) {
        existing.fileName = fileName;
      }
      unawaited(_save());
      return existing;
    }
    final identity = MediaIdentity(
      uuid: _uuid.v4(),
      shortTag: tag,
      assetId: (assetId == null || assetId.isEmpty) ? null : assetId,
      title: title ?? '',
      fileName: fileName,
      kind: kind,
      createdAt: createdAt,
      fileSize: fileSize,
      durationSec: durationSec,
    );
    _byUuid[identity.uuid] = identity;
    unawaited(_save());
    notifyListeners();
    return identity;
  }

  Future<void> flush() => _save();

  /// Test hook — drops every entry without touching storage.
  @visibleForTesting
  void resetForTest() {
    _byUuid.clear();
    _loaded = false;
    notifyListeners();
  }
}
