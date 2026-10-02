import 'dart:convert';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/media_index.dart';
import 'package:flutter_app/services/upload_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> vault;

  setUp(() {
    vault = <String, String>{};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(vault);
    MediaIndex.instance.resetForTest();
  });

  group('tag encoding', () {
    test('append and strip round-trips', () {
      const base = '02 October 2026 15:30';
      final tagged = MediaIndex.encodeTag(base, 'a1b2c3d4');
      expect(tagged, '$base [a1b2c3d4]');
      expect(MediaIndex.stripTag(tagged), base);
      expect(MediaIndex.parseTag(tagged), 'a1b2c3d4');
    });

    test('encoding twice does not stack tags', () {
      const base = '02 October 2026 15:30';
      final once = MediaIndex.encodeTag(base, 'a1b2c3d4');
      final twice = MediaIndex.encodeTag(once, 'ffffffff');
      expect(twice, '$base [ffffffff]');
      expect(MediaIndex.parseTag(twice), 'ffffffff');
    });

    test('an all-digit bracket is not mistaken for a tag', () {
      // `20261002` is 8 hex characters — without the letter requirement this
      // would parse as a UUID tag and silently rebind an unrelated title.
      expect(MediaIndex.parseTag('Backup 20261002'), isNull);
      expect(MediaIndex.isShortTag('20261002'), isFalse);
      expect(MediaIndex.isShortTag('a1b2c3d4'), isTrue);
      expect(MediaIndex.parseTag('[A1B2C3D4]'), isNull,
          reason: 'only lowercase tags are ever written, so an uppercase '
              'bracket cannot be one');
    });

    test('legacy double tags are both stripped', () {
      expect(
        MediaIndex.stripTag('Title [a1b2c3d4] [ffffffff]'),
        'Title',
      );
    });

    test('fitTitle never exceeds the YouTube limit and keeps the tag', () {
      final long = 'x' * 200;
      final out = MediaIndex.fitTitle(long, 'a1b2c3d4');
      expect(out.length, lessThanOrEqualTo(100));
      expect(out.endsWith('[a1b2c3d4]'), isTrue);
      expect(MediaIndex.parseTag(out), 'a1b2c3d4');
    });

    test('fitTitle truncates rather than dropping the tag', () {
      final out = MediaIndex.fitTitle('02 October 2026 15:30', null);
      expect(out, '02 October 2026 15:30');
      expect(
        MediaIndex.fitTitle('a' * 95, 'ffffffff').length,
        lessThanOrEqualTo(100),
      );
    });
  });

  group('identity resolution', () {
    test('the same asset always resolves to the same UUID', () async {
      final index = MediaIndex.instance;
      final first = await index.resolveOrCreate(
          assetId: 'asset-1', title: 'One');
      final second = await index.resolveOrCreate(
          assetId: 'asset-1', title: 'One');

      expect(second.uuid, first.uuid);
      expect(second.shortTag, first.shortTag);
      expect(index.length, 1);
    });

    test('different assets get different UUIDs and different tags',
        () async {
      final index = MediaIndex.instance;
      final a = await index.resolveOrCreate(assetId: 'a', title: 'A');
      final b = await index.resolveOrCreate(assetId: 'b', title: 'B');

      expect(a.uuid, isNot(b.uuid));
      expect(a.shortTag, isNot(b.shortTag));
      expect(index.length, 2);
    });

    test('lookups find the identity by every id it wears', () async {
      final index = MediaIndex.instance;
      final id = await index.resolveOrCreate(assetId: 'asset-9', title: 'Z');
      await index.link(
        uuid: id.uuid,
        youtubeVideoId: 'yt-123',
        telegramMessageId: '4242',
        telegramAccountKey: '+1000',
      );

      expect(index.byUuid(id.uuid), isNotNull);
      expect(index.byShortTag(id.shortTag)?.uuid, id.uuid);
      expect(index.byAssetId('asset-9')?.uuid, id.uuid);
      expect(index.byYoutubeVideoId('yt-123')?.uuid, id.uuid);
      expect(index.byTelegramMessageId('4242')?.uuid, id.uuid);
      expect(index.byTelegramMessageId('4242', accountKey: '+1000')?.uuid,
          id.uuid);
      expect(index.byTelegramMessageId('4242', accountKey: '+2000'), isNull);
    });

    test('unknown UUIDs are ignored rather than throwing', () async {
      final index = MediaIndex.instance;
      await index.resolveOrCreate(assetId: 'a', title: 'A');
      expect(index.link(uuid: 'nope', youtubeVideoId: 'x'),
          completion(isNull));
      expect(index.byUuid('nope'), isNull);
    });

    test('adoptTag keeps a tag the index has never seen', () async {
      final index = MediaIndex.instance;
      final id = await index.adoptTag(
        shortTag: 'DEADBEEF',
        assetId: 'asset-7',
        title: 'Adopted',
      );

      expect(id.shortTag, 'deadbeef');
      expect(index.byShortTag('deadbeef')?.uuid, id.uuid);
      expect(index.byAssetId('asset-7')?.uuid, id.uuid);
      expect(index.byShortTag('deadbeef')?.title, 'Adopted');
    });

    test('byTitle matches on the tag-stripped form', () async {
      final index = MediaIndex.instance;
      await index.resolveOrCreate(assetId: 'a', title: '02 October 2026 15:30');

      expect(index.byTitle('02 October 2026 15:30'), isNotNull);
      expect(index.byTitle('02 October 2026 15:30 [a1b2c3d4]'), isNotNull);
      expect(index.byTitle('some other title'), isNull);
    });
  });

  group('persistence', () {
    test('entries survive a restart', () async {
      final index = MediaIndex.instance;
      final id = await index.resolveOrCreate(
          assetId: 'asset-x', title: 'X', fileName: 'x.mp4');
      await index.link(uuid: id.uuid, youtubeVideoId: 'yt-1');
      await index.flush();

      index.resetForTest();
      await index.ensureLoaded();

      final reloaded = index.byUuid(id.uuid);
      expect(reloaded, isNotNull);
      expect(reloaded!.shortTag, id.shortTag);
      expect(reloaded.assetId, 'asset-x');
      expect(reloaded.fileName, 'x.mp4');
      expect(reloaded.youtubeVideoId, 'yt-1');
    });

    test('an unreadable store starts empty instead of throwing', () async {
      final index = MediaIndex.instance;
      vault[MediaIndex.storageKey] = 'not json at all';
      index.resetForTest();
      await index.ensureLoaded();
      expect(index.length, 0);
    });
  });

  group('queue migration', () {
    test('a legacy job without a UUID gets one on load', () async {
      // Simulate a build that predates UUIDs: the job has no uuid field.
      final legacy = UploadJob(
        id: 'legacy_1',
        assetId: 'asset-legacy',
        title: '01 January 2024 10:00',
      );
      vault['upload_queue'] = _encodeQueue(legacy);

      final scheduler = UploadScheduler();
      await scheduler.load();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final job = scheduler.jobs.single;
      expect(job.uuid, isNotNull);
      expect(job.shortTag, isNotNull);
      expect(job.title, '01 January 2024 10:00',
          reason: 'stored titles stay tag-free');
      expect(MediaIndex.instance.byAssetId('asset-legacy')?.uuid, job.uuid);
      expect(job.taggedTitle, '01 January 2024 10:00 [${job.shortTag}]');
    });

    test('two destinations on one asset share a single UUID', () async {
      final scheduler = UploadScheduler();
      await scheduler.addJobs(
        [{'assetId': 'shared', 'title': '02 October 2026 15:30'}],
        'channel',
        'someone@example.com',
        destination: UploadDestination.both,
      );
      await scheduler.addJobs(
        [{'assetId': 'shared', 'title': '02 October 2026 15:31'}],
        'channel',
        'someone@example.com',
        destination: UploadDestination.telegram,
      );

      expect(scheduler.jobs, hasLength(2));
      expect(scheduler.jobs[1].uuid, scheduler.jobs[0].uuid);
      expect(scheduler.jobs[1].shortTag, scheduler.jobs[0].shortTag);
      expect(MediaIndex.instance.length, 1);
    });

    test('the tag is applied identically for both destinations', () async {
      final scheduler = UploadScheduler();
      await scheduler.addJobs(
        [{'assetId': 'a', 'title': '02 October 2026 15:30'}],
        'channel',
        'someone@example.com',
        destination: UploadDestination.both,
      );
      final job = scheduler.jobs.single;
      expect(job.taggedTitle, contains('[${job.shortTag}]'));
      expect(MediaIndex.parseTag(job.taggedTitle), job.shortTag);
      expect(MediaIndex.stripTag(job.taggedTitle), job.title);
    });
  });
}

String _encodeQueue(UploadJob job) {
  final json = job.toJson()
    ..remove('uuid')
    ..remove('shortTag');
  return jsonEncode({
    'jobs': [json],
    'deletedTelegram': <String>[],
    'deletedYoutube': <String>[],
    'paused': false,
  });
}
