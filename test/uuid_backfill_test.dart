import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/media_index.dart';
import 'package:flutter_app/services/uuid_backfill.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime(2026, 10, 2, 15, 30, 0);

  setUp(() {
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
    MediaIndex.instance.resetForTest();
  });

  LocalCandidate local({
    String assetId = 'asset-1',
    String title = '02 October 2026 15:30',
    String? fileName,
    DateTime? createdAt,
    int? fileSize,
    int? durationSec,
  }) =>
      LocalCandidate(
        assetId: assetId,
        title: title,
        fileName: fileName,
        createdAt: createdAt ?? t0,
        fileSize: fileSize,
        durationSec: durationSec,
      );

  RemoteCandidate remote({
    RemoteKind kind = RemoteKind.youtube,
    String remoteId = 'yt-1',
    String title = '02 October 2026 15:30',
    String? fileName,
    DateTime? date,
    int? fileSize,
    int? durationSec,
    String? accountKey,
  }) =>
      RemoteCandidate(
        kind: kind,
        remoteId: remoteId,
        title: title,
        fileName: fileName,
        date: date ?? t0,
        fileSize: fileSize,
        durationSec: durationSec,
        accountKey: accountKey,
      );

  group('tier 1 — certain', () {
    test('a remote already wearing a known UUID tag matches itself',
        () async {
      final index = MediaIndex.instance;
      final id = await index.resolveOrCreate(
          assetId: 'asset-1', title: '02 October 2026 15:30');

      final results = UuidBackfill.match(
        locals: [local()],
        remotes: [
          remote(title: '02 October 2026 15:30 [${id.shortTag}]'),
        ],
        index: index,
      );

      final m = results.single;
      expect(m.confidence, MatchConfidence.certain);
      expect(m.identity?.uuid, id.uuid);
      expect(m.local?.assetId, 'asset-1');
      expect(m.existingTag, id.shortTag);
      expect(m.needsRemoteRewrite, isFalse,
          reason: 'the remote already carries the right tag');
    });

    test('an unknown tag is still authoritative but needs a new identity',
        () async {
      final results = UuidBackfill.match(
        locals: [local()],
        remotes: [remote(title: '02 October 2026 15:30 [ffffffff]')],
        index: MediaIndex.instance,
      );

      final m = results.single;
      expect(m.confidence, MatchConfidence.certain);
      expect(m.identity, isNull);
      expect(m.existingTag, 'ffffffff');
      expect(m.needsRemoteRewrite, isFalse);
    });

    test('a stored YouTube video id matches without reading the title',
        () async {
      final index = MediaIndex.instance;
      final id = await index.resolveOrCreate(
          assetId: 'asset-1', title: 'anything at all');
      await index.link(uuid: id.uuid, youtubeVideoId: 'yt-1');

      final results = UuidBackfill.match(
        locals: [local()],
        remotes: [remote(title: 'A completely different title')],
        index: index,
      );

      final m = results.single;
      expect(m.confidence, MatchConfidence.certain);
      expect(m.identity?.uuid, id.uuid);
      expect(m.local?.assetId, 'asset-1');
      expect(m.signals, contains('stored video id'));
    });

    test('a stored Telegram message id matches only its own account',
        () async {
      final index = MediaIndex.instance;
      final id = await index.resolveOrCreate(assetId: 'asset-1', title: 'T');
      await index.link(
        uuid: id.uuid,
        telegramMessageId: '4242',
        telegramAccountKey: '+1000',
      );

      final hit = UuidBackfill.match(
        locals: [local()],
        remotes: [
          remote(
            kind: RemoteKind.telegram,
            remoteId: '4242',
            accountKey: '+1000',
            title: 'whatever',
          ),
        ],
        index: index,
      ).single;
      expect(hit.confidence, MatchConfidence.certain);

      final miss = UuidBackfill.match(
        locals: [local()],
        remotes: [
          remote(
            kind: RemoteKind.telegram,
            remoteId: '4242',
            accountKey: '+2000',
            title: 'whatever',
          ),
        ],
        index: index,
      ).single;
      expect(miss.identity, isNull,
          reason: 'another phone number\'s message id is not ours');
    });
  });

  group('tier 2 — exact title', () {
    test('identical titles match exactly', () {
      final m = UuidBackfill.match(
        locals: [local()],
        remotes: [remote()],
        index: MediaIndex.instance,
      ).single;

      expect(m.confidence, MatchConfidence.exact);
      expect(m.local?.assetId, 'asset-1');
      expect(m.signals, containsAll(['title', 'same minute']));
    });

    test('a tagged remote title matches an untagged local title', () {
      final m = UuidBackfill.match(
        locals: [local()],
        remotes: [remote(title: '02 October 2026 15:30 [a1b2c3d4]')],
        index: MediaIndex.instance,
      ).single;

      expect(m.confidence, MatchConfidence.certain);
      expect(m.local?.assetId, 'asset-1');
    });

    test('a title nobody has is not a match', () {
      final m = UuidBackfill.match(
        locals: [local()],
        remotes: [remote(title: 'Nothing like it')],
        index: MediaIndex.instance,
      ).single;

      expect(m.confidence, MatchConfidence.none);
      expect(m.local, isNull);
      expect(m.isMatched, isFalse);
    });

    test('two same-minute locals leave an ambiguous title unresolved', () {
      // Two photos in the same minute produce the same date title; taking
      // one of them at random would be a coin flip.
      final results = UuidBackfill.match(
        locals: [
          local(assetId: 'a'),
          local(assetId: 'b'),
        ],
        remotes: [remote()],
        index: MediaIndex.instance,
      );

      expect(results.single.confidence, isNot(MatchConfidence.exact));
      expect(results.single.signals.first, contains('2 candidates'));
    });
  });

  group('tier 3 — filename', () {
    test('a filename match is strong', () {
      final m = UuidBackfill.match(
        locals: [
          local(assetId: 'a', title: 'Something Else Entirely'),
          local(assetId: 'b', title: 'Also Different', fileName: 'clip.mp4'),
        ],
        remotes: [
          remote(title: 'A third title', fileName: 'CLIP.MP4'),
        ],
        index: MediaIndex.instance,
      ).single;

      expect(m.confidence, MatchConfidence.strong);
      expect(m.local?.assetId, 'b');
      expect(m.signals, contains('filename'));
    });
  });

  group('tier 4 — proximity', () {
    test('date plus size agreeing is only probable', () {
      final m = UuidBackfill.match(
        locals: [
          local(
            assetId: 'a',
            title: 'Some other name',
            createdAt: t0.add(const Duration(minutes: 2)),
            fileSize: 1000000,
          ),
        ],
        remotes: [
          remote(title: 'A different name', fileSize: 1000030),
        ],
        index: MediaIndex.instance,
      ).single;

      expect(m.confidence, MatchConfidence.probable);
      expect(m.local?.assetId, 'a');
      expect(m.note, contains('confirm'));
    });

    test('disagreeing sizes block a proximity match', () {
      final m = UuidBackfill.match(
        locals: [
          local(
            assetId: 'a',
            title: 'Some other name',
            createdAt: t0,
            fileSize: 1000000,
          ),
        ],
        remotes: [
          remote(title: 'A different name', fileSize: 900000),
        ],
        index: MediaIndex.instance,
      ).single;

      expect(m.confidence, MatchConfidence.none);
    });

    test('a date far outside the window blocks a proximity match', () {
      final m = UuidBackfill.match(
        locals: [
          local(
            assetId: 'a',
            title: 'Some other name',
            createdAt: t0.add(const Duration(hours: 3)),
            fileSize: 1000000,
          ),
        ],
        remotes: [
          remote(title: 'A different name', fileSize: 1000000),
        ],
        index: MediaIndex.instance,
      ).single;

      expect(m.confidence, MatchConfidence.none);
    });
  });

  group('scoring', () {
    test('every remote produces exactly one result', () {
      final results = UuidBackfill.match(
        locals: [local()],
        remotes: [
          remote(),
          remote(remoteId: 'yt-2', title: 'Nope'),
          remote(kind: RemoteKind.telegram, remoteId: '99'),
        ],
        index: MediaIndex.instance,
      );

      expect(results, hasLength(3));
      expect(UuidBackfill.summarize(results)[MatchConfidence.none], 2);
      expect(UuidBackfill.summarize(results)[MatchConfidence.exact], 1);
    });

    test('a local asset is never handed to two remotes', () {
      final results = UuidBackfill.match(
        locals: [local()],
        remotes: [
          remote(remoteId: 'yt-1'),
          remote(remoteId: 'yt-2'),
        ],
        index: MediaIndex.instance,
      );

      final winners =
          results.where((r) => r.local != null).toList();
      expect(winners, hasLength(1));
    });
  });
}
