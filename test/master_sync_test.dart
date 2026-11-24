import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/services/account_manager.dart';
import 'package:flutter_app/services/master_sync.dart';
import 'package:flutter_app/services/upload_scheduler.dart';

void main() {
  group('MasterSync.planFor', () {
    test('a new video goes to both YouTube and Telegram', () {
      final plan = MasterSync.planFor(
        isVideo: true,
        hasYoutubeJob: false,
        hasTelegramJob: false,
      );
      expect(plan.youtube, isTrue);
      expect(plan.telegram, isTrue);
      expect(plan.isEmpty, isFalse);
    });

    test('a photo is queued for Telegram only, YouTube takes video', () {
      final plan = MasterSync.planFor(
        isVideo: false,
        hasYoutubeJob: false,
        hasTelegramJob: false,
      );
      expect(plan.youtube, isFalse);
      expect(plan.telegram, isTrue);
    });

    test('a video already queued for YouTube only needs Telegram', () {
      final plan = MasterSync.planFor(
        isVideo: true,
        hasYoutubeJob: true,
        hasTelegramJob: false,
      );
      expect(plan.youtube, isFalse);
      expect(plan.telegram, isTrue);
    });

    test('a video already on Telegram only needs YouTube', () {
      final plan = MasterSync.planFor(
        isVideo: true,
        hasYoutubeJob: false,
        hasTelegramJob: true,
      );
      expect(plan.youtube, isTrue);
      expect(plan.telegram, isFalse);
    });

    test('an asset covered on both sides is left alone', () {
      final plan = MasterSync.planFor(
        isVideo: true,
        hasYoutubeJob: true,
        hasTelegramJob: true,
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('MasterSync targets', () {
    test('only the YouTube target queues to YouTube', () {
      expect(MasterSync.destinationFor(SyncTarget.youtubeVideos),
          UploadDestination.youtube);
      expect(MasterSync.destinationFor(SyncTarget.telegramVideos),
          UploadDestination.telegram);
      expect(MasterSync.destinationFor(SyncTarget.telegramPhotos),
          UploadDestination.telegram);
      expect(MasterSync.destinationFor(SyncTarget.telegramFiles),
          UploadDestination.telegram);
    });

    test('each target takes its own asset types and nothing else', () {
      expect(MasterSync.assetMatches(SyncTarget.telegramVideos, AssetType.video),
          isTrue);
      expect(MasterSync.assetMatches(SyncTarget.telegramVideos, AssetType.image),
          isFalse);

      expect(MasterSync.assetMatches(SyncTarget.youtubeVideos, AssetType.video),
          isTrue);
      expect(MasterSync.assetMatches(SyncTarget.youtubeVideos, AssetType.image),
          isFalse);

      expect(MasterSync.assetMatches(SyncTarget.telegramPhotos, AssetType.image),
          isTrue);
      expect(MasterSync.assetMatches(SyncTarget.telegramPhotos, AssetType.video),
          isFalse);

      expect(MasterSync.assetMatches(SyncTarget.telegramFiles, AssetType.audio),
          isTrue);
      expect(MasterSync.assetMatches(SyncTarget.telegramFiles, AssetType.other),
          isTrue);
      expect(MasterSync.assetMatches(SyncTarget.telegramFiles, AssetType.video),
          isFalse);
      expect(MasterSync.assetMatches(SyncTarget.telegramFiles, AssetType.image),
          isFalse);
    });

    test('a photos pass never asks the library for videos', () {
      expect(MasterSync.requestTypeFor(SyncTarget.telegramPhotos),
          RequestType.image);
      expect(MasterSync.requestTypeFor(SyncTarget.telegramVideos),
          RequestType.video);
      expect(MasterSync.requestTypeFor(SyncTarget.youtubeVideos),
          RequestType.video);
      expect(MasterSync.requestTypeFor(SyncTarget.telegramFiles).containsVideo(),
          isTrue);
    });
  });

  group('MasterSyncResult', () {
    test('reports queued work across both destinations and skips', () {
      const result = MasterSyncResult(
        youtubeAdded: 3,
        telegramAdded: 5,
        skipped: 7,
      );
      expect(result.added, 8);
      expect(result.skipped, 7);
      expect(result.ok, isTrue);
    });

    test('an error is not ok and queues nothing', () {
      const result = MasterSyncResult(
        youtubeAdded: 0,
        telegramAdded: 0,
        error: 'Photo library access is needed to sync',
      );
      expect(result.ok, isFalse);
      expect(result.added, 0);
    });
  });

  // The switches are a promise about what the app will do unattended, so
  // the state they were left in has to be the state that comes back.
  group('MasterSync switch state', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    MasterSync freshSync() => MasterSync(
          scheduler: UploadScheduler(),
          accounts: AccountManager(googleSignIn: GoogleSignIn()),
        );

    test('the master switch and the category toggles survive a restart',
        () async {
      final before = freshSync();
      await before.init();
      // A fresh install: master off and every category off — nothing
      // queues itself unasked, and a category only runs once its stored
      // state says on.
      expect(before.enabled, isFalse);
      for (final target in SyncTarget.values) {
        expect(before.targetEnabled(target), isFalse, reason: target.name);
      }

      await before.setEnabled(true);
      await before.setTargetEnabled(SyncTarget.telegramVideos, true);
      await before.setTargetEnabled(SyncTarget.youtubeVideos, true);
      await before.setTargetEnabled(SyncTarget.telegramPhotos, false);
      before.dispose();

      final after = freshSync();
      await after.init();
      expect(after.enabled, isTrue);
      expect(after.targetEnabled(SyncTarget.telegramVideos), isTrue);
      expect(after.targetEnabled(SyncTarget.youtubeVideos), isTrue);
      expect(after.targetEnabled(SyncTarget.telegramPhotos), isFalse);
      expect(after.targetEnabled(SyncTarget.telegramFiles), isFalse);
      after.dispose();
    });

    test('everything switched off comes back off, not reset to defaults',
        () async {
      final before = freshSync();
      await before.init();
      await before.setEnabled(true);
      // Turn every category on first — the state a user would have chosen
      // — then off again: that choice must survive the restart instead of
      // being reset to the (off) default.
      for (final target in SyncTarget.values) {
        await before.setTargetEnabled(target, true);
      }
      for (final target in SyncTarget.values) {
        await before.setTargetEnabled(target, false);
      }
      await before.setEnabled(false);
      before.dispose();

      final after = freshSync();
      await after.init();
      expect(after.enabled, isFalse);
      for (final target in SyncTarget.values) {
        expect(after.targetEnabled(target), isFalse, reason: target.name);
      }
      after.dispose();
    });

    test('a toggle that is already in that state does not write', () async {
      final sync = freshSync();
      await sync.init();
      var notifications = 0;
      sync.addListener(() => notifications++);

      // Targets default to off, so turning one off again changes nothing
      // and must not notify (or touch storage).
      await sync.setTargetEnabled(SyncTarget.telegramVideos, false);
      expect(notifications, 0);

      await sync.setTargetEnabled(SyncTarget.telegramVideos, true);
      expect(notifications, 1);
      sync.dispose();
    });
  });
}
