import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which page a folder belongs to. Folders never mix scopes: a Telegram photo
/// has no meaning on the YouTube page, so each page keeps its own namespace.
enum FolderScope { local, youtube, telegram }

/// Colours used by the folder chips, index-matched against
/// [MediaFolder.colorIndex] so a folder keeps its identity across exports.
const List<int> kFolderColors = [
  0xFF42A5F5, // blue
  0xFF66BB6A, // green
  0xFFEF5350, // red
  0xFFFFB300, // amber
  0xFFAB47BC, // purple
  0xFF26C6DA, // cyan
  0xFFFF7043, // orange
  0xFF8D6E63, // brown
];

ColorValue folderColorAt(int index) =>
    kFolderColors[(index % kFolderColors.length + kFolderColors.length) %
        kFolderColors.length];

/// A folder colour, as a packed ARGB int so it can be stored in JSON without
/// dragging `dart:ui` into the model.
typedef ColorValue = int;

class MediaFolder {
  MediaFolder({
    required this.id,
    required this.name,
    required this.scope,
    this.colorIndex = 0,
    List<String>? itemIds,
  }) : itemIds = itemIds ?? <String>[];

  final String id;
  String name;
  final FolderScope scope;
  int colorIndex;

  /// Membership is many-to-many on purpose: dropping an item into one folder
  /// never silently empties it out of another, so experimenting with
  /// groupings can't lose work.
  final List<String> itemIds;

  /// Bumped on every membership change so listeners can tell "same folder,
  /// different contents" apart from a no-op notification.
  int revision = 0;

  bool contains(String id) => itemIds.contains(id);

  bool containsAll(Iterable<String> ids) {
    for (final id in ids) {
      if (!itemIds.contains(id)) return false;
    }
    return true;
  }

  int get count => itemIds.length;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'scope': scope.name,
        'color': colorIndex,
        'items': itemIds,
      };

  factory MediaFolder.fromJson(Map<String, dynamic> json) {
    final scopeRaw = '${json['scope']}';
    return MediaFolder(
      id: '${json['id']}',
      name: '${json['name']}',
      scope: FolderScope.values.firstWhere(
        (e) => e.name == scopeRaw,
        orElse: () => FolderScope.local,
      ),
      colorIndex: (json['color'] as num?)?.toInt() ?? 0,
      itemIds: [
        for (final raw in (json['items'] as List?) ?? const [])
          '$raw',
      ],
    );
  }
}

/// Owns every folder in the app: creation, membership, and the backup file
/// used to carry the structure across a reinstall.
///
/// State lives in [SharedPreferences] (fast, survives normal launches) and is
/// exported as a single JSON document, because nothing on the device survives
/// deleting the app.
class FolderStore extends ChangeNotifier {
  static const String _prefsKey = 'media_folders_v1';
  static const String _backupFormat = 'yt-multi-backup/folders';

  final List<MediaFolder> _folders = [];
  bool _loaded = false;
  int _idCounter = 0;

  bool get isLoaded => _loaded;
  List<MediaFolder> get folders => List<MediaFolder>.unmodifiable(_folders);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        _folders
          ..clear()
          ..addAll(_decode(raw));
      }
    } catch (e) {
      // Unreadable storage must not take the app down — start empty instead
      // of blocking every page that waits on this.
      debugPrint('[Folders] could not read stored folders: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _encode());
    } catch (e) {
      debugPrint('[Folders] could not persist: $e');
    }
  }

  String _newId() {
    _idCounter++;
    return '${DateTime.now().microsecondsSinceEpoch}_$_idCounter';
  }

  MediaFolder? byId(String? id) {
    if (id == null) return null;
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  List<MediaFolder> foldersFor(FolderScope scope) =>
      [for (final f in _folders) if (f.scope == scope) f];

  /// Folders in [scope] that already hold [id] — drives the "already here"
  /// tick in the move sheet and the drop-target highlight on the chips.
  List<MediaFolder> containing(FolderScope scope, String id) =>
      [for (final f in foldersFor(scope)) if (f.contains(id)) f];

  /// Ids to filter a grid by, or `null` for "show everything".
  Set<String>? filterIds(FolderScope scope, String? folderId) {
    final folder = byId(folderId);
    if (folder == null || folder.scope != scope) return null;
    return Set<String>.of(folder.itemIds);
  }

  Future<MediaFolder> create(String name, FolderScope scope,
      {int colorIndex = 0}) async {
    final trimmed = name.trim();
    final folder = MediaFolder(
      id: _newId(),
      name: trimmed.isEmpty ? 'New folder' : trimmed,
      scope: scope,
      colorIndex: colorIndex,
    );
    _folders.add(folder);
    await _persist();
    notifyListeners();
    return folder;
  }

  Future<void> rename(String id, String name) async {
    final folder = byId(id);
    if (folder == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == folder.name) return;
    folder.name = trimmed;
    await _persist();
    notifyListeners();
  }

  Future<void> setColor(String id, int colorIndex) async {
    final folder = byId(id);
    if (folder == null || folder.colorIndex == colorIndex) return;
    folder.colorIndex = colorIndex;
    await _persist();
    notifyListeners();
  }

  Future<void> delete(String id) async {
    final before = _folders.length;
    _folders.removeWhere((f) => f.id == id);
    if (_folders.length == before) return;
    await _persist();
    notifyListeners();
  }

  Future<void> addItems(String folderId, Iterable<String> ids) async {
    final folder = byId(folderId);
    if (folder == null) return;
    var changed = false;
    for (final id in ids) {
      if (id.isEmpty || folder.itemIds.contains(id)) continue;
      folder.itemIds.add(id);
      changed = true;
    }
    if (!changed) return;
    folder.revision++;
    await _persist();
    notifyListeners();
  }

  Future<void> removeItems(String folderId, Iterable<String> ids) async {
    final folder = byId(folderId);
    if (folder == null) return;
    final before = folder.itemIds.length;
    folder.itemIds.removeWhere(ids.contains);
    if (folder.itemIds.length == before) return;
    folder.revision++;
    await _persist();
    notifyListeners();
  }

  /// Drops [ids] from every folder in [scope]. Used when the user explicitly
  /// unfiles something, and by "remove from all folders".
  Future<void> clearMembership(FolderScope scope, Iterable<String> ids) async {
    if (ids.isEmpty) return;
    var changed = false;
    for (final folder in foldersFor(scope)) {
      final before = folder.itemIds.length;
      folder.itemIds.removeWhere(ids.contains);
      if (folder.itemIds.length != before) {
        folder.revision++;
        changed = true;
      }
    }
    if (!changed) return;
    await _persist();
    notifyListeners();
  }

  // ---------------------------------------------------------------- backup

  String exportJson() => jsonEncode(<String, dynamic>{
        'format': _backupFormat,
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'folders': [for (final f in _folders) f.toJson()],
      });

  List<MediaFolder> _decode(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('That file is not a folder backup');
    }
    if (decoded is Map) {
      final format = decoded['format'];
      if (format != null && format != _backupFormat) {
        throw const FormatException('That file is not a folder backup');
      }
      final list = decoded['folders'];
      if (list is! List) {
        throw const FormatException('That file is not a folder backup');
      }
      return [
        for (final entry in list)
          if (entry is Map<String, dynamic>) MediaFolder.fromJson(entry),
      ];
    }
    if (decoded is List) {
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) MediaFolder.fromJson(entry),
      ];
    }
    throw const FormatException('That file is not a folder backup');
  }

  /// How many folders a backup holds, without applying it — the caller shows
  /// this before asking merge-or-replace.
  int countIn(String raw) => _decode(raw).length;

  /// Replaces or merges from a decoded backup. Throws [FormatException] on
  /// content that is not a folder backup, so the caller can show a real error
  /// instead of silently importing nothing.
  int importJson(String raw, {required bool replace}) {
    final incoming = _decode(raw);
    if (replace) {
      _folders
        ..clear()
        ..addAll(incoming);
    } else {
      final byKey = <String, MediaFolder>{
        for (final f in _folders) '${f.scope.name}:${f.id}': f,
      };
      for (final folder in incoming) {
        final key = '${folder.scope.name}:${folder.id}';
        final existing = byKey[key];
        if (existing == null) {
          _folders.add(folder);
          byKey[key] = folder;
          continue;
        }
        existing.name = folder.name;
        existing.colorIndex = folder.colorIndex;
        for (final id in folder.itemIds) {
          if (!existing.itemIds.contains(id)) existing.itemIds.add(id);
        }
        existing.revision++;
      }
    }
    _persist();
    notifyListeners();
    return incoming.length;
  }

  /// Writes the backup to a temp file and opens the system share sheet, so
  /// it can go to Files, Drive, AirDrop, or anywhere else — this is the only
  /// thing that survives deleting and reinstalling the app.
  Future<bool> exportToFile() async {
    try {
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final name = 'folders-backup-$stamp.json';
      final file = File('${Directory.systemTemp.path}/$name');
      await file.writeAsString(exportJson(), flush: true);
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json', name: name)],
          subject: 'Folder backup',
        ),
      );
      return result.status == ShareResultStatus.success;
    } catch (e) {
      debugPrint('[Folders] export failed: $e');
      return false;
    }
  }

  /// Opens the document picker and returns the backup's raw JSON, or `null`
  /// when the user cancelled. Throws [FormatException] when the file cannot
  /// be read as text.
  Future<String?> pickBackupJson() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.any,
      withData: true,
      allowMultiple: false,
    );
    if (picked == null || picked.files.isEmpty) return null;

    final file = picked.files.first;
    if (file.bytes != null) {
      return utf8.decode(file.bytes!, allowMalformed: true);
    }
    if (file.path != null) {
      return await File(file.path!).readAsString();
    }
    throw const FormatException('Could not read that file');
  }

  // ---------------------------------------------------------------- helpers

  String _encode() => exportJson();
}
