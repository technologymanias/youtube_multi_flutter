import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  Future<UploadScheduler> schedulerWith(List<String> titles) async {
    final scheduler = UploadScheduler();
    await scheduler.addJobs(
      [for (final t in titles) {'assetId': t, 'title': t}],
      'channel',
      'someone@example.com',
      destination: UploadDestination.telegram,
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
}

Future<Map<String, dynamic>?> _readJobs(Map<String, String> vault) async {
  final raw = vault['upload_queue'];
  if (raw == null) return null;
  return (jsonDecode(raw) as Map).cast<String, dynamic>();
}

String _encodeJobs(Map<String, dynamic> data) => jsonEncode(data);
