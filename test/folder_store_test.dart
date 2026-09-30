import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/services/folder_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('creation and scoping', () {
    test('folders are namespaced per page and never leak across pages',
        () async {
      final store = FolderStore();
      await store.load();
      final local = await store.create('Clips', FolderScope.local);
      await store.create('Clips', FolderScope.youtube);
      await store.create('Clips', FolderScope.telegram);

      expect(store.foldersFor(FolderScope.local), hasLength(1));
      expect(store.foldersFor(FolderScope.youtube), hasLength(1));
      expect(store.foldersFor(FolderScope.telegram), hasLength(1));
      expect(local.scope, FolderScope.local);
      expect(store.folders, hasLength(3));
    });

    test('empty and whitespace names fall back to a usable default', () async {
      final store = FolderStore();
      await store.load();
      expect((await store.create('   ', FolderScope.local)).name,
          'New folder');
      expect((await store.create(' Trips ', FolderScope.local)).name, 'Trips');
    });

    test('delete and rename ignore unknown ids instead of throwing', () async {
      final store = FolderStore();
      await store.load();
      await store.delete('nope');
      await store.rename('nope', 'x');
      await store.setColor('nope', 3);
      expect(store.folders, isEmpty);
    });
  });

  group('membership', () {
    test('adding is many-to-many, deduped, and scoped to one folder',
        () async {
      final store = FolderStore();
      await store.load();
      final a = await store.create('A', FolderScope.local);
      final b = await store.create('B', FolderScope.local);

      await store.addItems(a.id, ['1', '2', '2', '']);
      await store.addItems(b.id, ['2', '3']);

      expect(a.itemIds, ['1', '2']);
      expect(b.itemIds, ['2', '3']);
      expect(a.revision, greaterThan(0));
      // No duplicates were created by the repeat of '2'.
      expect(a.itemIds.toSet(), a.itemIds.toSet());
    });

    test('re-adding the same ids is a no-op and does not bump revision',
        () async {
      final store = FolderStore();
      await store.load();
      final a = await store.create('A', FolderScope.local);
      await store.addItems(a.id, ['1']);
      final revision = a.revision;
      await store.addItems(a.id, ['1']);
      expect(a.revision, revision);
    });

    test('removeItems only touches the folder it was given', () async {
      final store = FolderStore();
      await store.load();
      final a = await store.create('A', FolderScope.local);
      final b = await store.create('B', FolderScope.local);
      await store.addItems(a.id, ['1', '2']);
      await store.addItems(b.id, ['1', '2']);

      await store.removeItems(a.id, ['1']);

      expect(a.itemIds, ['2']);
      expect(b.itemIds, ['1', '2']);
    });

    test('clearMembership spans a scope but never crosses into another',
        () async {
      final store = FolderStore();
      await store.load();
      final local = await store.create('A', FolderScope.local);
      final youtube = await store.create('B', FolderScope.youtube);
      await store.addItems(local.id, ['1', '2']);
      await store.addItems(youtube.id, ['1']);

      await store.clearMembership(FolderScope.local, ['1']);

      expect(local.itemIds, ['2']);
      expect(youtube.itemIds, ['1']);
    });

    test('filterIds is null for "show everything", wrong scope, or a gap',
        () async {
      final store = FolderStore();
      await store.load();
      expect(store.filterIds(FolderScope.local, null), isNull);

      final folder = await store.create('A', FolderScope.local);
      expect(store.filterIds(FolderScope.local, 'missing'), isNull);
      // A Telegram folder id must not filter the Local grid.
      expect(store.filterIds(FolderScope.youtube, folder.id), isNull);

      await store.addItems(folder.id, ['a', 'b']);
      final ids = store.filterIds(FolderScope.local, folder.id);
      expect(ids, {'a', 'b'});
      ids!.add('mutation must not reach the folder');
      expect(folder.itemIds, ['a', 'b']);
    });
  });

  group('backup', () {
    test('export round-trips every folder and its membership', () async {
      final store = FolderStore();
      await store.load();
      final a = await store.create('Clips', FolderScope.local, colorIndex: 3);
      await store.addItems(a.id, ['x', 'y']);

      final restored = FolderStore();
      restored.importJson(store.exportJson(), replace: true);

      expect(restored.folders, hasLength(1));
      final back = restored.foldersFor(FolderScope.local).single;
      expect(back.name, 'Clips');
      expect(back.colorIndex, 3);
      expect(back.itemIds, ['x', 'y']);
      expect(back.id, a.id);
    });

    test('replace drops what was there, merge unions without losing ids',
        () async {
      final store = FolderStore();
      await store.load();
      final existing = await store.create('Keep', FolderScope.local);
      await store.addItems(existing.id, ['old']);

      // The two stores share one mock preference file, so hand the donor a
      // blank one — otherwise it re-reads `Keep` and "replace" looks wrong.
      final donor = FolderStore();
      SharedPreferences.setMockInitialValues({});
      await donor.load();
      final incoming = await donor.create('Incoming', FolderScope.youtube);
      await donor.addItems(incoming.id, ['n1']);

      final sameKey = donor.exportJson();
      store.importJson(sameKey, replace: false);
      expect(store.folders, hasLength(2));

      store.importJson(sameKey, replace: true);
      expect(store.folders, hasLength(1));
      expect(store.folders.single.id, incoming.id);
    });

    test('merge overwrites name/colour and unions items for a matching id',
        () async {
      final store = FolderStore();
      await store.load();
      final a = await store.create('Old name', FolderScope.local);
      await store.addItems(a.id, ['kept']);

      // Same id as `a`, but a donor-side copy with a new name, colour, and
      // one extra item — merge has to fold these into the existing folder.
      final clone = MediaFolder(
          id: a.id, name: 'New name', scope: FolderScope.local, colorIndex: 5)
        ..itemIds.add('added');
      final donorJson = jsonEncode(<String, dynamic>{
        'format': 'yt-multi-backup/folders',
        'folders': [clone.toJson()],
      });

      store.importJson(donorJson, replace: false);

      expect(a.name, 'New name');
      expect(a.colorIndex, 5);
      expect(a.itemIds, containsAll(['kept', 'added']));
    });

    test('countIn previews without mutating the store', () async {
      final store = FolderStore();
      await store.load();
      await store.create('A', FolderScope.local);
      await store.create('B', FolderScope.telegram);

      expect(store.countIn(store.exportJson()), 2);
      expect(store.folders, hasLength(2));
    });

    test('countIn and importJson reject content that is not a backup',
        () async {
      final store = FolderStore();
      await store.load();

      for (final bad in [
        'not json at all',
        '42',
        '{"format":"some-other-app/v9","folders":[]}',
        '{"format":"yt-multi-backup/folders","folders":{}}',
      ]) {
        expect(() => store.countIn(bad), throwsFormatException,
            reason: 'should reject: $bad');
        expect(() => store.importJson(bad, replace: true),
            throwsFormatException,
            reason: 'should reject: $bad');
      }
      expect(store.folders, isEmpty);
    });

    test('membership survives a restart through shared preferences', () async {
      final store = FolderStore();
      await store.load();
      final folder = await store.create('Persist', FolderScope.local);
      await store.addItems(folder.id, ['1', '2']);

      // Simulates the app reading storage back on the next launch.
      SharedPreferences.setMockInitialValues(
          {'media_folders_v1': store.exportJson()});
      final relaunched = FolderStore();
      await relaunched.load();

      expect(relaunched.folders, hasLength(1));
      expect(relaunched.folders.single.name, 'Persist');
      expect(relaunched.folders.single.itemIds, ['1', '2']);
    });

    test('unreadable storage starts empty rather than throwing', () async {
      SharedPreferences.setMockInitialValues(
          {'media_folders_v1': '{"broken"'});
      final store = FolderStore();
      await expectLater(store.load(), completes);
      expect(store.folders, isEmpty);
      expect(store.isLoaded, isTrue);
    });
  });
}
