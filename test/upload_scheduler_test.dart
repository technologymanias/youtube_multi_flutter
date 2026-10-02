import 'dart:convert';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/upload_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> vault;

  setUp(() {
    vault = <String, String>{};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(vault);
  });

  Future<UploadScheduler> schedulerWith(List<String> titles,
      {UploadDestination destination = UploadDestination.telegram}) async {
    final scheduler = UploadScheduler();
    await scheduler.addJobs(
      [for (final t in titles) {'assetId': t, 'title': t}],
      'channel',
      'someone@example.com',
      destination: destination,
    );
    return scheduler;
  }

  /// Lets the fire-and-forget `_save()` that backs a verdict land in the
  /// in-memory vault before we assert on it.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('an upload only loses its badge when Telegram confirms it is gone',
      () async {
    final scheduler = await schedulerWith(['a', 'b', 'c']);
    expect(scheduler.jobs, hasLength(3));
    expect(scheduler.jobs.every(scheduler.isOnTelegram), isTrue);

    final ids = {for (final j in scheduler.jobs) j.title: j.id};

    // 'a' is confirmed deleted, 'b' is confirmed still there, 'c' is never
    // probed — an unverifiable probe must leave it alone.
    scheduler.applyTelegramVerdict(
      present: {ids['b']!},
      absent: {ids['a']!},
    );

    expect(scheduler.isOnTelegram(scheduler.jobs[0]), isFalse);
    expect(scheduler.isOnTelegram(scheduler.jobs[1]), isTrue);
    expect(scheduler.isOnTelegram(scheduler.jobs[2]), isTrue);
  });

  test('a later round that finds the message again restores the badge',
      () async {
    final scheduler = await schedulerWith(['a']);
    final id = scheduler.jobs.single.id;

    scheduler.applyTelegramVerdict(absent: {id}, present: const {});
    expect(scheduler.isOnTelegram(scheduler.jobs.single), isFalse);

    scheduler.applyTelegramVerdict(present: {id}, absent: const {});
    expect(scheduler.isOnTelegram(scheduler.jobs.single), isTrue);
  });

  test('an empty verdict is a no-op and does not notify listeners', () async {
    final scheduler = await schedulerWith(['a']);
    var notifications = 0;
    scheduler.addListener(() => notifications++);

    scheduler.applyTelegramVerdict(
        present: const {}, absent: const {});

    expect(notifications, 0);
  });

  test('the verdict survives an app restart', () async {
    final scheduler = await schedulerWith(['a', 'b']);
    final first = scheduler.jobs.first.id;

    scheduler.applyTelegramVerdict(absent: {first}, present: const {});
    await settle();

    final relaunched = UploadScheduler();
    await relaunched.load();

    expect(relaunched.jobs, hasLength(2));
    expect(relaunched.isOnTelegram(relaunched.jobs.first), isFalse);
    expect(relaunched.isOnTelegram(relaunched.jobs.last), isTrue);
  });

  test('re-uploading clears the verdict, and that also persists', () async {
    final scheduler = await schedulerWith(['a']);
    final id = scheduler.jobs.single.id;

    scheduler.applyTelegramVerdict(absent: {id}, present: const {});
    await settle();
    scheduler.clearDeletedOnTelegram(id);
    await settle();

    final relaunched = UploadScheduler();
    await relaunched.load();
    expect(relaunched.isOnTelegram(relaunched.jobs.single), isTrue);
  });

  test('verdicts for jobs that no longer exist are dropped on load', () async {
    final scheduler = await schedulerWith(['a']);
    final id = scheduler.jobs.single.id;
    scheduler.applyTelegramVerdict(absent: {id}, present: const {});
    await settle();

    // Wipe the jobs but keep the verdict, as an older build would have
    // written it — loading must not resurrect a ghost entry.
    final decoded = (await _readJobs(vault))!;
    decoded['jobs'] = <dynamic>[];
    vault['upload_queue'] = _encodeJobs(decoded);

    final relaunched = UploadScheduler();
    await relaunched.load();
    expect(relaunched.jobs, isEmpty);
  });

  test('a legacy job-list blob still loads', () async {
    final job = UploadJob(
      id: 'legacy',
      assetId: 'asset',
      title: 'Legacy title',
      status: JobStatus.completed,
      destination: UploadDestination.telegram,
    );
    vault['upload_queue'] = jsonEncode([job.toJson()]);

    final scheduler = UploadScheduler();
    await scheduler.load();

    expect(scheduler.jobs, hasLength(1));
    expect(scheduler.jobs.single.id, 'legacy');
    // Nothing recorded about it, so the badge starts on and waits for a
    // real check against Telegram.
    expect(scheduler.isOnTelegram(scheduler.jobs.single), isTrue);
  });

  test('a YouTube badge only falls when YouTube confirms the video is gone',
      () async {
    final scheduler = await schedulerWith(['a', 'b', 'c'],
        destination: UploadDestination.youtube);
    expect(scheduler.jobs, hasLength(3));
    expect(scheduler.jobs.every(scheduler.isOnYoutube), isTrue);
    // A YouTube-only upload never had a Telegram copy, so its TG badge must
    // stay off no matter what the YouTube probe says.
    expect(scheduler.jobs.any(scheduler.isOnTelegram), isFalse);

    final ids = {for (final j in scheduler.jobs) j.title: j.id};
    scheduler.applyYoutubeVerdict(
      present: {ids['b']!},
      absent: {ids['a']!},
    );

    expect(scheduler.isOnYoutube(scheduler.jobs[0]), isFalse);
    expect(scheduler.isOnYoutube(scheduler.jobs[1]), isTrue);
    expect(scheduler.isOnYoutube(scheduler.jobs[2]), isTrue);
  });

  test('the YouTube verdict survives an app restart', () async {
    final scheduler = await schedulerWith(['a', 'b'],
        destination: UploadDestination.youtube);
    final first = scheduler.jobs.first.id;

    scheduler.applyYoutubeVerdict(absent: {first}, present: const {});
    await settle();

    final relaunched = UploadScheduler();
    await relaunched.load();

    expect(relaunched.jobs, hasLength(2));
    expect(relaunched.isOnYoutube(relaunched.jobs.first), isFalse);
    expect(relaunched.isOnYoutube(relaunched.jobs.last), isTrue);
  });

  test('re-uploading a video restores its YouTube badge', () async {
    final scheduler = await schedulerWith(['a'],
        destination: UploadDestination.youtube);
    final id = scheduler.jobs.single.id;

    scheduler.applyYoutubeVerdict(absent: {id}, present: const {});
    expect(scheduler.isOnYoutube(scheduler.jobs.single), isFalse);

    scheduler.clearDeletedOnYoutube(id);
    expect(scheduler.isOnYoutube(scheduler.jobs.single), isTrue);
  });

  test('a due YouTube job waits while today is at the daily cap', () async {
    // 15 fit today, the 16th rolls onto tomorrow — the same split addJobs
    // makes when the queue is longer than one day.
    final scheduler = await schedulerWith(
      [for (var i = 0; i < 16; i++) 'v$i'],
      destination: UploadDestination.youtube,
    );
    expect(scheduler.jobs.where((j) => j.status == JobStatus.pending),
        hasLength(15));
    final rolled =
        scheduler.jobs.firstWhere((j) => j.status == JobStatus.scheduled);
    expect(rolled.status, JobStatus.scheduled);

    // Its day has not arrived, so nothing moves yet.
    expect(scheduler.promoteDueScheduled(), isFalse);
    expect(rolled.status, JobStatus.scheduled);

    // Pretend the app was closed over the night that held it back, so the
    // job is overdue from yesterday rather than merely due today.
    rolled.scheduledDate = DateTime.now().subtract(const Duration(days: 1));
    await settle();

    // Today still has 15 jobs against it, so the cap holds the rolled job
    // back rather than dumping two days of uploads into one morning.
    expect(scheduler.promoteDueScheduled(), isFalse);
    expect(rolled.status, JobStatus.scheduled);

    // Dropping one of today's jobs frees exactly one slot, which the rolled
    // job then takes.
    final todayJob =
        scheduler.jobs.firstWhere((j) => j.status == JobStatus.pending);
    await scheduler.remove(todayJob.id);
    expect(scheduler.promoteDueScheduled(), isTrue);
    expect(rolled.status, JobStatus.pending);
    expect(rolled.scheduledDate, isNull);
  });

  test('a due Telegram job promotes even when YouTube is at its cap',
      () async {
    final scheduler = await schedulerWith(
      [for (var i = 0; i < 15; i++) 'y$i'],
      destination: UploadDestination.youtube,
    );
    await scheduler.addJobs(
      [
        {'assetId': 'photo', 'title': 'photo'}
      ],
      'channel',
      'someone@example.com',
      destination: UploadDestination.telegram,
    );
    final telegramJob = scheduler.jobs.last;
    telegramJob.status = JobStatus.scheduled;
    telegramJob.scheduledDate = DateTime.now().subtract(const Duration(minutes: 1));
    await settle();

    // Telegram has no daily quota, so a full YouTube day must not hold it
    // back.
    expect(scheduler.promoteDueScheduled(), isTrue);
    expect(telegramJob.status, JobStatus.pending);
    expect(scheduler.jobs.where((j) => j.status == JobStatus.scheduled),
        isEmpty);
  });

  test('a folder upload tags every job with the folder, on both sides',
      () async {
    final scheduler = UploadScheduler();
    await scheduler.addJobs(
      [{'assetId': 'a', 'title': 'A'}],
      'channel',
      'someone@example.com',
      destination: UploadDestination.telegram,
      folder: 'Trip 2026',
    );
    await scheduler.addJobs(
      [{'assetId': 'a', 'title': 'A'}],
      'channel',
      'someone@example.com',
      destination: UploadDestination.youtube,
      folder: 'Trip 2026',
    );

    expect(scheduler.jobs, hasLength(2));
    expect([for (final j in scheduler.jobs) j.folder],
        ['Trip 2026', 'Trip 2026']);
    expect(scheduler.jobsInFolder('Trip 2026'), hasLength(2));
    expect(scheduler.folders, ['Trip 2026']);
    await settle();
  });

  test('one asset holds a Telegram job and a YouTube job side by side',
      () async {
    // The "upload to both" path queues the same selection twice, once per
    // destination; coverage is checked per side, so the first pass must not
    // make the second one look redundant.
    final scheduler = UploadScheduler();
    await scheduler.addJobs(
      [{'assetId': 'a', 'title': 'A'}],
      'channel',
      'someone@example.com',
      destination: UploadDestination.telegram,
    );
    await scheduler.addJobs(
      [{'assetId': 'a', 'title': 'A'}],
      'channel',
      'someone@example.com',
      destination: UploadDestination.youtube,
    );

    expect(scheduler.jobs, hasLength(2));
    expect(
        [for (final j in scheduler.jobs) j.destination],
        [UploadDestination.telegram, UploadDestination.youtube]);
    expect(scheduler.jobs.every((j) => j.status == JobStatus.pending), isTrue);
    await settle();
  });

  test('a paused queue claims nothing, and the pause survives a restart',
      () async {
    final scheduler = await schedulerWith(['a', 'b']);
    await scheduler.setPaused(true);

    expect(scheduler.paused, isTrue);
    expect(scheduler.claimNext(), isNull);
    // Pausing must not disturb the jobs themselves — they are still there,
    // just not runnable.
    expect(scheduler.jobs.every((j) => j.status == JobStatus.pending), isTrue);
    expect((await _readJobs(vault))?['paused'], isTrue);

    final reloaded = UploadScheduler();
    await reloaded.load();
    expect(reloaded.paused, isTrue);
    expect(reloaded.claimNext(), isNull);

    await reloaded.setPaused(false);
    expect(reloaded.paused, isFalse);
    expect(reloaded.claimNext()?.title, 'a');
    await settle();
    expect((await _readJobs(vault))?['paused'], isFalse);
  });

  group('statistics are counted per account', () {
    Future<UploadScheduler> completedFor(
      List<({String channel, String email})> owners, {
      UploadDestination destination = UploadDestination.youtube,
    }) async {
      final scheduler = UploadScheduler();
      for (final owner in owners) {
        await scheduler.addJobs(
          [
            {
              'assetId': '${owner.email}-${owner.channel}',
              'title': '${owner.email}-${owner.channel}',
            }
          ],
          owner.channel,
          owner.email,
          destination: destination,
        );
        await scheduler.markCompleted(scheduler.jobs.last.id);
      }
      return scheduler;
    }

    test("today's YouTube uploads are per channel, not per device", () async {
      final scheduler = await completedFor([
        (channel: 'channel-a', email: 'a@example.com'),
        (channel: 'channel-a', email: 'a@example.com'),
        (channel: 'channel-b', email: 'a@example.com'),
      ]);

      expect(scheduler.todayYoutubeCountForChannel('channel-a'), 2);
      expect(scheduler.todayYoutubeCountForChannel('channel-b'), 1);
      expect(scheduler.todayYoutubeCountForChannel(null), 3);
      expect(scheduler.todayYoutubeCount, 3);
    });

    test('total uploads are per Google account', () async {
      final scheduler = await completedFor([
        (channel: 'channel-a', email: 'a@example.com'),
        (channel: 'channel-a', email: 'b@example.com'),
      ]);

      expect(scheduler.completedCountForAccount('a@example.com'), 1);
      expect(scheduler.completedCountForAccount('b@example.com'), 1);
      expect(scheduler.completedCountForAccount(null), 2);
    });

    test("today's Telegram uploads are per phone-number account", () async {
      final scheduler = await completedFor(
        [
          (channel: 'channel-a', email: 'a@example.com'),
          (channel: 'channel-a', email: 'a@example.com'),
        ],
        destination: UploadDestination.telegram,
      );
      await scheduler.markCompleted(scheduler.jobs[0].id,
          telegramAccountId: '+111');
      await scheduler.markCompleted(scheduler.jobs[1].id,
          telegramAccountId: '+222');

      expect(scheduler.todayTelegramCountForAccount('+111'), 1);
      expect(scheduler.todayTelegramCountForAccount('+222'), 1);
      expect(scheduler.todayTelegramCountForAccount('+333'), 0);
      expect(scheduler.todayTelegramCountForAccount(null), 2);
    });

    test('the account an upload belongs to survives a restart', () async {
      final scheduler = await completedFor(
        [(channel: 'channel-a', email: 'a@example.com')],
        destination: UploadDestination.telegram,
      );
      await scheduler.markCompleted(scheduler.jobs.single.id,
          telegramAccountId: '+111');
      await settle();

      final relaunched = UploadScheduler();
      await relaunched.load();

      expect(relaunched.jobs.single.telegramAccountId, '+111');
      expect(relaunched.todayTelegramCountForAccount('+111'), 1);
      expect(relaunched.todayTelegramCountForAccount('+222'), 0);
    });

    test('uploads recorded before accounts were known join the signed-in '
        'one, once', () async {
      final scheduler = await completedFor(
        [
          (channel: 'channel-a', email: 'a@example.com'),
          (channel: 'channel-a', email: 'a@example.com'),
        ],
        destination: UploadDestination.telegram,
      );
      // Nothing recorded on either job — the shape an upgrade starts with.
      expect(scheduler.jobs.every((j) => j.telegramAccountId.isEmpty), isTrue);

      scheduler.attributeLegacyTelegramJobs('+111');
      expect(scheduler.jobs.every((j) => j.telegramAccountId == '+111'),
          isTrue);
      await settle();

      // A restart must not hand them to the next account that signs in.
      final relaunched = UploadScheduler();
      await relaunched.load();
      expect(relaunched.todayTelegramCountForAccount('+111'), 2);
      expect(relaunched.todayTelegramCountForAccount('+222'), 0);

      // And an account that already knows its uploads is never re-stamped.
      relaunched.attributeLegacyTelegramJobs('+222');
      expect(relaunched.todayTelegramCountForAccount('+111'), 2);
    });

    test('jobs queued before either id was recorded still count for '
        'whoever is signed in', () async {
      final job = UploadJob(
        id: 'legacy',
        assetId: 'asset',
        title: 'Legacy title',
        status: JobStatus.completed,
        completedAt: DateTime.now(),
        destination: UploadDestination.telegram,
      );
      vault['upload_queue'] = jsonEncode([job.toJson()]);

      final scheduler = UploadScheduler();
      await scheduler.load();

      expect(scheduler.completedCountForAccount('anyone@example.com'), 1);
      expect(scheduler.todayTelegramCountForAccount('+111'), 1);
      expect(scheduler.todayYoutubeCountForChannel('channel-a'), 0);
    });
  });
}

Future<Map<String, dynamic>?> _readJobs(Map<String, String> vault) async {
  final raw = vault['upload_queue'];
  if (raw == null) return null;
  return (jsonDecode(raw) as Map).cast<String, dynamic>();
}

String _encodeJobs(Map<String, dynamic> data) => jsonEncode(data);
