import 'media_index.dart';

/// Which remote service a candidate came from.
enum RemoteKind { youtube, telegram }

/// How sure we are that a remote item and a local item are the same file.
///
/// Ordered worst to best so callers can filter with a single comparison.
enum MatchConfidence {
  /// Nothing lined up. Shown separately so the user can see what was skipped.
  none,

  /// Date and byte size agree but nothing identifies the file. Suggest it,
  /// never auto-apply it.
  probable,

  /// Original filename matches, or title and date agree to the minute.
  strong,

  /// Titles are byte-identical after tag-stripping.
  exact,

  /// A stored remote id, or a UUID tag already on the item. Never a guess.
  certain,
}

/// A video/photo/file sitting in the device gallery (or already queued).
class LocalCandidate {
  const LocalCandidate({
    required this.assetId,
    required this.title,
    this.fileName,
    this.createdAt,
    this.fileSize,
    this.durationSec,
    this.kind = 'video',
  });

  final String assetId;

  /// Date-formatted display title — the same string this app writes into
  /// YouTube titles and Telegram captions on upload.
  final String title;

  final String? fileName;
  final DateTime? createdAt;
  final int? fileSize;
  final int? durationSec;
  final String kind;
}

/// An already-uploaded item that has no UUID yet (or one the index cannot
/// place).
class RemoteCandidate {
  const RemoteCandidate({
    required this.kind,
    required this.remoteId,
    required this.title,
    this.accountKey,
    this.fileName,
    this.date,
    this.fileSize,
    this.durationSec,
    this.mediaKind = 'video',
  });

  /// Which service it lives on.
  final RemoteKind kind;

  /// YouTube video id, or Telegram message id as a string.
  final String remoteId;

  /// YouTube title or Telegram caption, verbatim (may already carry a tag).
  final String title;

  /// Telegram only — the account the message belongs to.
  final String? accountKey;

  /// Telegram only — read from `DocumentAttributeFilename`.
  final String? fileName;

  final DateTime? date;
  final int? fileSize;
  final int? durationSec;
  final String mediaKind;
}

/// One proposed pairing, ready for the review screen.
class ProposedMatch {
  const ProposedMatch({
    required this.remote,
    required this.confidence,
    this.local,
    this.identity,
    this.existingTag,
    this.signals = const [],
    this.note,
  });

  final RemoteCandidate remote;
  final MatchConfidence confidence;

  /// The gallery asset we believe this remote item is. Null when the remote
  /// carries a UUID but points at an asset that is no longer on the device —
  /// the identity is still worth recording, it just has nothing to link to.
  final LocalCandidate? local;

  /// Existing registry entry, when the UUID is already known locally.
  final MediaIdentity? identity;

  /// Tag already present on the remote item, if any.
  final String? existingTag;

  /// Human-readable evidence, shown as chips in the review UI.
  final List<String> signals;

  /// Why this pairing is weak, or why it could not be made.
  final String? note;

  bool get isMatched => confidence != MatchConfidence.none;

  /// True when the remote copy still needs a title/caption write to carry the
  /// UUID. False when it already wears the right tag — in that case only the
  /// local index has work to do, which is free.
  bool get needsRemoteRewrite => isMatched && existingTag == null;

  /// A YouTube title rewrite, which costs 50 quota units.
  bool get needsYoutubeTitle => remote.kind == RemoteKind.youtube;

  /// A Telegram caption edit, which costs nothing.
  bool get needsTelegramCaption => remote.kind == RemoteKind.telegram;

  @override
  String toString() =>
      'ProposedMatch(${remote.kind.name} ${remote.remoteId} -> '
      '${local?.assetId ?? identity?.uuid ?? '-'} '
      '${confidence.name} $signals)';
}

/// Pure matching logic: given what is local and what is remote, decide which
/// pairs belong together.
///
/// Deliberately free of I/O so it can be tested with fixtures, and so the
/// review screen can re-run it as more gallery pages arrive without ever
/// writing anything.
class UuidBackfill {
  const UuidBackfill._();

  /// Title equality is minute-resolution (the titles are `dd MMMM yyyy
  /// HH:mm`), so anything inside this window is "the same minute".
  static const Duration titleTolerance = Duration(minutes: 1);

  /// Weaker, size-backed window used by the [MatchConfidence.probable] tier.
  static const Duration dateTolerance = Duration(minutes: 5);

  /// Two files of the same kind rarely differ by less than this.
  static const int sizeToleranceBytes = 64;

  /// Relative size allowance for the weakest tier.
  static const double sizeToleranceRatio = 0.02;

  /// Duration allowance for videos.
  static const Duration durationTolerance = Duration(seconds: 2);

  /// Pairs every remote candidate with at most one local asset.
  ///
  /// Every remote produces exactly one result — including unmatched ones, with
  /// [MatchConfidence.none] — so the caller can show a complete picture and
  /// count what will be skipped.
  static List<ProposedMatch> match({
    required List<LocalCandidate> locals,
    required List<RemoteCandidate> remotes,
    MediaIndex? index,
  }) {
    final registry = index ?? MediaIndex.instance;

    // Bucket locals by the three keys we match on. Lists, not single values:
    // two photos taken in the same minute share a title, and silently taking
    // the first would be a coin flip.
    final byTitle = <String, List<LocalCandidate>>{};
    final byFile = <String, List<LocalCandidate>>{};
    final byAsset = <String, LocalCandidate>{};
    for (final l in locals) {
      final t = MediaIndex.stripTag(l.title).trim();
      if (t.isNotEmpty) byTitle.putIfAbsent(t, () => []).add(l);
      final f = l.fileName?.trim().toLowerCase();
      if (f != null && f.isNotEmpty) byFile.putIfAbsent(f, () => []).add(l);
      byAsset[l.assetId] = l;
    }

    final usedAssetIds = <String>{};
    return [
      for (final r in remotes)
        _matchOne(
          r: r,
          registry: registry,
          byTitle: byTitle,
          byFile: byFile,
          byAsset: byAsset,
          usedAssetIds: usedAssetIds,
        ),
    ];
  }

  /// Groups results by whether anything needs doing at all, for the summary
  /// bar on the review screen.
  static Map<MatchConfidence, int> summarize(List<ProposedMatch> results) {
    final counts = <MatchConfidence, int>{};
    for (final r in results) {
      counts[r.confidence] = (counts[r.confidence] ?? 0) + 1;
    }
    return counts;
  }

  static ProposedMatch _matchOne({
    required RemoteCandidate r,
    required MediaIndex registry,
    required Map<String, List<LocalCandidate>> byTitle,
    required Map<String, List<LocalCandidate>> byFile,
    required Map<String, LocalCandidate> byAsset,
    required Set<String> usedAssetIds,
  }) {
    final signals = <String>[];
    final strippedRemoteTitle = MediaIndex.stripTag(r.title).trim();
    final tag = MediaIndex.parseTag(r.title);

    // ── Tier 1a: the remote already wears a UUID tag ──────────────────────
    if (tag != null) {
      final known = registry.byShortTag(tag);
      if (known != null) {
        signals.add('uuid tag');
        final local =
            known.assetId == null ? null : byAsset[known.assetId];
        return ProposedMatch(
          remote: r,
          confidence: MatchConfidence.certain,
          local: local,
          identity: known,
          existingTag: tag,
          signals: signals,
          note: (local == null && known.assetId != null)
              ? 'UUID known but its gallery asset is gone'
              : null,
        );
      }
      // A tag the index has never seen — still authoritative, because only
      // this app writes them, but it needs a brand-new identity.
      signals.add('uuid tag (new)');
      final titleHits = strippedRemoteTitle.isEmpty
          ? const <LocalCandidate>[]
          : (byTitle[strippedRemoteTitle] ?? const <LocalCandidate>[]);
      final freeHits = titleHits
          .where((c) => !usedAssetIds.contains(c.assetId))
          .toList();
      LocalCandidate? local;
      if (freeHits.isNotEmpty) {
        signals.add('title');
        local = freeHits.first;
        usedAssetIds.add(local.assetId);
      } else {
        local = _nearestByProximity(
          r: r,
          pool: [
            for (final list in byTitle.values)
              for (final c in list)
                if (!usedAssetIds.contains(c.assetId)) c,
          ],
        );
        if (local != null) {
          signals.add('date/size');
          usedAssetIds.add(local.assetId);
        }
      }
      return ProposedMatch(
        remote: r,
        confidence: MatchConfidence.certain,
        local: local,
        existingTag: tag,
        signals: signals,
        note: 'Tag not in the local index — it will be registered as-is',
      );
    }

    // ── Tier 1b: the registry already knows this remote id ────────────────
    final knownById = r.kind == RemoteKind.youtube
        ? registry.byYoutubeVideoId(r.remoteId)
        : registry.byTelegramMessageId(r.remoteId,
            accountKey: r.accountKey);
    if (knownById != null) {
      signals.add(r.kind == RemoteKind.youtube
          ? 'stored video id'
          : 'stored message id');
      final local = knownById.assetId == null
          ? null
          : byAsset[knownById.assetId];
      return ProposedMatch(
        remote: r,
        confidence: MatchConfidence.certain,
        local: local,
        identity: knownById,
        signals: signals,
      );
    }

    // ── Tier 2: exact title ───────────────────────────────────────────────
    if (strippedRemoteTitle.isNotEmpty) {
      final titleHits = byTitle[strippedRemoteTitle] ?? const [];
      final freeHits = titleHits
          .where((c) => !usedAssetIds.contains(c.assetId))
          .toList();
      if (freeHits.length == 1) {
        signals.add('title');
        final local = freeHits.first;
        usedAssetIds.add(local.assetId);
        return ProposedMatch(
          remote: r,
          confidence: MatchConfidence.exact,
          local: local,
          signals: _withDateSignal(r, local, signals),
        );
      }
      if (freeHits.length > 1) {
        // Several gallery items share this date title. Guessing would be a
        // coin flip, and the weaker tiers below have nothing extra to go on
        // either — surface it as ambiguous instead of picking one.
        signals.add('title (${freeHits.length} candidates)');
        return ProposedMatch(
          remote: r,
          confidence: MatchConfidence.probable,
          signals: signals,
          note: '${freeHits.length} local items share this exact title — '
              'none was chosen',
        );
      }
    }

    // ── Tier 3: original filename ─────────────────────────────────────────
    final fileKey = r.fileName?.trim().toLowerCase();
    if (fileKey != null && fileKey.isNotEmpty) {
      final hits = (byFile[fileKey] ?? const [])
          .where((c) => !usedAssetIds.contains(c.assetId))
          .toList();
      if (hits.length == 1) {
        signals.add('filename');
        final local = hits.first;
        usedAssetIds.add(local.assetId);
        return ProposedMatch(
          remote: r,
          confidence: MatchConfidence.strong,
          local: local,
          signals: _withDateSignal(r, local, signals),
        );
      }
      if (hits.length > 1) {
        signals.add('filename (${hits.length} candidates)');
      }
    }

    // ── Tier 4: date + bytes/duration ─────────────────────────────────────
    final candidate = _nearestByProximity(
      r: r,
      pool: [
        for (final list in byTitle.values)
          for (final c in list)
            if (!usedAssetIds.contains(c.assetId)) c,
      ],
    );
    if (candidate != null) {
      signals.add('date/size');
      usedAssetIds.add(candidate.assetId);
      return ProposedMatch(
        remote: r,
        confidence: MatchConfidence.probable,
        local: candidate,
        signals: signals,
        note: 'Only timestamps and size line up — please confirm',
      );
    }

    return ProposedMatch(
      remote: r,
      confidence: MatchConfidence.none,
      signals: const [],
      note: 'No local item looks like this',
    );
  }

  static List<String> _withDateSignal(
    RemoteCandidate r,
    LocalCandidate local,
    List<String> signals,
  ) {
    if (r.date != null &&
        local.createdAt != null &&
        r.date!.difference(local.createdAt!).abs() <= titleTolerance) {
      return [...signals, 'same minute'];
    }
    return signals;
  }

  /// Picks the free local asset whose timestamp is closest to the remote's,
  /// but only when bytes or duration corroborate it.
  ///
  /// Date alone is not evidence: every item uploaded in the same five minutes
  /// sits inside the window, so accepting it would pair a remote with
  /// whichever asset happened to be iterated first.
  static LocalCandidate? _nearestByProximity({
    required RemoteCandidate r,
    required List<LocalCandidate> pool,
  }) {
    if (r.date == null) return null;
    LocalCandidate? best;
    var bestDelta = Duration.zero;

    for (final c in pool) {
      if (c.createdAt == null) continue;
      final delta = c.createdAt!.difference(r.date!).abs();
      if (delta > dateTolerance) continue;

      final sizeKnown = r.fileSize != null && c.fileSize != null;
      final durationKnown =
          r.durationSec != null && c.durationSec != null;
      // Nothing but the clock to compare — not enough to call it a match.
      if (!sizeKnown && !durationKnown) continue;
      if (sizeKnown && !_sizeAgrees(r.fileSize, c.fileSize)) continue;
      if (durationKnown && !_durationAgrees(r.durationSec, c.durationSec)) {
        continue;
      }

      if (best == null || delta < bestDelta) {
        best = c;
        bestDelta = delta;
      }
    }
    return best;
  }

  static bool _sizeAgrees(int? a, int? b) {
    if (a == null || b == null) return true;
    if (a == b) return true;
    final diff = (a - b).abs();
    if (diff <= sizeToleranceBytes) return true;
    final larger = a > b ? a : b;
    return larger > 0 && diff / larger <= sizeToleranceRatio;
  }

  static bool _durationAgrees(int? a, int? b) {
    if (a == null || b == null) return true;
    return (a - b).abs() <= durationTolerance.inSeconds;
  }
}
