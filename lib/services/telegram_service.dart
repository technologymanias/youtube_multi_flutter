import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;

import 'telegram_socket.dart';
import 'upload_scheduler.dart';

class TelegramService extends ChangeNotifier {
  static const String _sessionKey = 'telegram_auth_session';

  /// Auth keys are per-datacenter. Without remembering which DC minted the
  /// key, every cold start reconnects to the default DC, the server cannot
  /// decrypt our requests, and the restore silently times out — which looks
  /// exactly like "I was logged out" and forces a fresh OTP login.
  static const String _dcKey = 'telegram_session_dc';
  static const String _defaultDestKey = 'telegram_default_destination';
  static const _storage = FlutterSecureStorage();

  /// Telegram's server decides whether a document is a "video" from the
  /// registered MIME type it receives, not from the filename. `video/$ext`
  /// sent `video/mov` for QuickTime files, which is not a real MIME type, so
  /// the server never set the video flag and the message landed in the
  /// chat's Files tab instead of Videos. Official clients always send
  /// `video/quicktime` for .mov.
  static const Map<String, String> _videoMimeTypes = {
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'mov': 'video/quicktime',
    'qt': 'video/quicktime',
    'avi': 'video/x-msvideo',
    'mkv': 'video/x-matroska',
    'webm': 'video/webm',
    '3gp': 'video/3gpp',
    '3g2': 'video/3gpp2',
    'mts': 'video/mp2t',
    'm2ts': 'video/mp2t',
    'ts': 'video/mp2t',
    'mpg': 'video/mpeg',
    'mpeg': 'video/mpeg',
    'wmv': 'video/x-ms-wmv',
    'flv': 'video/x-flv',
  };

  static const Map<String, String> _imageMimeTypes = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'bmp': 'image/bmp',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'tiff': 'image/tiff',
  };

  final int apiId;
  final String apiHash;

  tg.Client? _client;
  IoSocket? _ioSocket;
  bool _connected = false;
  bool _authenticated = false;
  StreamSubscription? _streamSub;

  String? _phoneNumber;
  t.AuthSentCode? _sentCode;
  t.DcOption _currentDc = const t.DcOption(
    id: 1,
    ipv6: false,
    mediaOnly: false,
    tcpoOnly: false,
    cdn: false,
    static: false,
    thisPortOnly: false,
    ipAddress: '149.154.167.50',
    port: 443,
  );
  final List<t.DcOption> _dcs = [];

  TelegramService({required this.apiId, required this.apiHash});

  bool get isConnected => _connected;
  bool get isAuthenticated => _authenticated;

  /// Production datacenters, used only when a session was saved without a DC.
  static t.DcOption _mkDc(int id, String ip) => t.DcOption(
        id: id,
        ipv6: false,
        mediaOnly: false,
        tcpoOnly: false,
        cdn: false,
        static: false,
        thisPortOnly: false,
        ipAddress: ip,
        port: 443,
      );

  static final Map<int, t.DcOption> _knownDcs = {
    for (final e in [
      [1, '149.154.167.50'],
      [2, '149.154.167.51'],
      [3, '149.154.167.54'],
      [4, '149.154.167.91'],
      [5, '149.154.167.99'],
    ])
      e[0] as int: _mkDc(e[0] as int, e[1] as String),
  };

  Future<bool> tryRestoreSession() async {
    final saved = await _storage.read(key: _sessionKey);
    if (saved == null) {
      debugPrint('tryRestoreSession: no stored session in keychain');
      return false;
    }

    final storedDc = await _readStoredDc();
    final candidates = <t.DcOption?>[];
    if (storedDc != null) {
      candidates
        ..add(storedDc) // remembered DC — the fast, normal path
        ..add(null); // then the default, as a safety net
    } else {
      // Older builds stored only the key. An auth key is only valid on the DC
      // that minted it; the others drop our packets without replying, which
      // looks exactly like a hang. Probe them so the user keeps the session
      // instead of being asked to sign in with a new OTP.
      candidates.add(null);
      candidates.addAll(_knownDcs.values.where((d) => d.id != 1));
    }

    Object? lastError;
    for (var i = 0; i < candidates.length; i++) {
      final dc = candidates[i];
      try {
        await _connectWithKey(
          saved,
          dc: dc,
          initTimeoutSec: i == 0 ? 20 : 10,
        );

        // Cheap authorized round-trip: proves the stored key is still one
        // Telegram recognises before we declare the session restored.
        final check = await _client!.users
            .getUsers(id: [const t.InputUserSelf()])
            .timeout(const Duration(seconds: 15));
        final err = check.error;
        if (err != null && err.errorMessage == 'AUTH_KEY_UNREGISTERED') {
          debugPrint('Stored auth key no longer registered — clearing session');
          await clearSession();
          return false;
        }
        if (check.result == null) {
          throw StateError('Telegram session check failed: $err');
        }

        _authenticated = true;
        await _persistDc();
        notifyListeners();
        return true;
      } catch (e) {
        lastError = e;
        debugPrint(
            'tryRestoreSession dc=${dc?.id ?? "default"} failed: $e');
        await disconnect();
        if (_isNonRetryable(e)) return false;
      }
    }

    // Transient failure (socket timeout, flaky wifi): keep the stored session
    // so the next attempt can still restore it. Never overwrite or delete it.
    debugPrint('tryRestoreSession giving up, stored session kept: $lastError');
    return false;
  }

  Future<void> _connectWithKey(
    String sessionJson, {
    t.DcOption? dc,
    int initTimeoutSec = 30,
  }) async {
    final json = jsonDecode(sessionJson);
    final authKey = tg.AuthorizationKey.fromJson(json);
    await _doConnect(authKey: authKey, dc: dc, initTimeoutSec: initTimeoutSec);
  }

  Future<void> _doConnect({
    tg.AuthorizationKey? authKey,
    t.DcOption? dc,
    int initTimeoutSec = 30,
  }) async {
    dc ??= _currentDc;
    debugPrint('[Connect] dc=${dc.id} ${dc.ipAddress}:${dc.port} '
        'authKey=${authKey == null ? "fresh" : "stored"}');
    final socket = await Socket.connect(dc.ipAddress, dc.port, timeout: const Duration(seconds: 8));
    _ioSocket = IoSocket(socket);
    final obfuscation = tg.Obfuscation.random(false, dc.id);
    final idGenerator = tg.MessageIdGenerator();

    await _ioSocket!.send(obfuscation.preamble);

    if (authKey == null) {
      authKey = await tg.Client.authorize(_ioSocket!, obfuscation, idGenerator);
    }
    // NOTE: when a stored authKey is supplied we must use it as-is. The server
    // never speaks first on an idle connection, so waiting for a message here
    // would always time out and silently mint a brand-new, unauthorized key —
    // discarding the logged-in session and forcing the user to sign in again.

    _client = tg.Client(
      socket: _ioSocket!,
      obfuscation: obfuscation,
      authorizationKey: authKey,
      idGenerator: idGenerator,
    );

    final configResult = await _client!.initConnection<t.Config>(
      apiId: apiId,
      deviceModel: 'iPhone',
      systemVersion: 'iOS 17.0',
      appVersion: '1.0.0',
      systemLangCode: 'en',
      langPack: '',
      langCode: 'en',
      query: const t.HelpGetConfig(),
    ).timeout(Duration(seconds: initTimeoutSec));

    if (configResult.result != null) {
      final config = configResult.result as t.Config;
      _dcs
        ..clear()
        ..addAll(config.dcOptions.map((e) => e as t.DcOption));
    }

    _currentDc = dc;
    _connected = true;
    _streamSub = _client!.stream.listen((event) {
      debugPrint('Telegram event: $event');
    });
  }

  Future<void> connect() async {
    if (_client != null) await disconnect();
    await _doConnect();
    notifyListeners();
  }

  Future<t.Result<t.AuthSentCodeBase>> sendCode(String phoneNumber) async {
    if (_client == null) throw StateError('Not connected. Call connect() first.');
    _phoneNumber = phoneNumber;
    var result = await _client!.auth.sendCode(
      apiId: apiId,
      apiHash: apiHash,
      phoneNumber: phoneNumber,
      settings: const t.CodeSettings(
        allowFlashcall: false,
        currentNumber: true,
        allowAppHash: false,
        allowMissedCall: false,
        allowFirebase: false,
        unknownNumber: false,
      ),
    );
    if (result.error != null && result.error!.errorCode == 303) {
      final msg = result.error!.errorMessage;
      if (msg.startsWith('PHONE_MIGRATE_')) {
        final dcId = int.parse(msg.split('_').last);
        final dc = _dcs.firstWhere((x) => x.id == dcId && !x.ipv6);
        debugPrint('[Connect] PHONE_MIGRATE_$dcId → moving to '
            '${dc.ipAddress}:${dc.port}');
        await disconnect();
        _currentDc = dc;
        await _doConnect();
        result = await _client!.auth.sendCode(
          apiId: apiId,
          apiHash: apiHash,
          phoneNumber: phoneNumber,
          settings: const t.CodeSettings(
            allowFlashcall: false,
            currentNumber: true,
            allowAppHash: false,
            allowMissedCall: false,
            allowFirebase: false,
            unknownNumber: false,
          ),
        );
      }
    }
    if (result.result != null) {
      _sentCode = result.result as t.AuthSentCode;
    }
    return result;
  }

  Future<t.Result<t.AuthAuthorizationBase>> signIn(String code) async {
    if (_client == null) throw StateError('Not connected');
    if (_phoneNumber == null || _sentCode == null) {
      throw StateError('Send code first');
    }
    return _client!.auth.signIn(
      phoneNumber: _phoneNumber!,
      phoneCodeHash: _sentCode!.phoneCodeHash,
      phoneCode: code,
    );
  }

  Future<t.Result<t.AccountPasswordBase>> getPassword() async {
    if (_client == null) throw StateError('Not connected');
    return _client!.account.getPassword();
  }

  Future<t.Result<t.AuthAuthorizationBase>> checkPassword(String password) async {
    if (_client == null) throw StateError('Not connected');
    final pwdResult = await _client!.account.getPassword();
    if (pwdResult.error != null) throw Exception('Failed to get password info');
    final accountPassword = pwdResult.result as t.AccountPassword;
    final pwd = await tg.check2FA(accountPassword, password);
    return _client!.auth.checkPassword(password: pwd);
  }

  Future<void> saveSession() async {
    if (_client == null) return;
    final json = _client!.authorizationKey.toJson();
    await _storage.write(key: _sessionKey, value: jsonEncode(json));
    await _persistDc();
    _authenticated = true;
    notifyListeners();
  }

  Future<void> _persistDc() async {
    final dc = _currentDc;
    await _storage.write(
      key: _dcKey,
      value: jsonEncode({
        'id': dc.id,
        'ipAddress': dc.ipAddress,
        'port': dc.port,
        'ipv6': dc.ipv6,
      }),
    );
  }

  Future<t.DcOption?> _readStoredDc() async {
    final raw = await _storage.read(key: _dcKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final ip = m['ipAddress'];
      final port = m['port'];
      if (ip is! String || ip.isEmpty || port is! int) return null;
      return t.DcOption(
        id: (m['id'] as num?)?.toInt() ?? 1,
        ipv6: m['ipv6'] == true,
        mediaOnly: false,
        tcpoOnly: false,
        cdn: false,
        static: false,
        thisPortOnly: false,
        ipAddress: ip,
        port: port,
      );
    } catch (e) {
      debugPrint('stored DC unreadable: $e');
      return null;
    }
  }

  Future<void> clearSession() async {
    await _storage.delete(key: _sessionKey);
    await _storage.delete(key: _dcKey);
    _authenticated = false;
    _connected = false;
    await _streamSub?.cancel();
    _client = null;
    clearThumbnailCache();
    notifyListeners();
  }

  Future<void>? _connecting;

  /// Ensures a usable connection exists, reconnecting from the saved session
  /// when needed. Concurrent callers share a single in-flight attempt.
  /// Throws a user-facing [StateError] when there is no saved session.
  Future<void> ensureConnected({bool force = false}) {
    if (!force && _client != null && _connected) return Future<void>.value();
    final pending = _connecting;
    if (pending != null) return pending;
    final future = _reconnectFromSession().whenComplete(() => _connecting = null);
    _connecting = future;
    return future;
  }

  Future<void> _reconnectFromSession() async {
    final saved = await _storage.read(key: _sessionKey);
    if (saved == null || saved.isEmpty) {
      _authenticated = false;
      notifyListeners();
      throw StateError('Telegram session expired — sign in again');
    }
    await disconnect();
    await _connectWithKey(saved, dc: await _readStoredDc());
    _authenticated = true;
    notifyListeners();
  }

  Future<void> reconnect() => ensureConnected(force: true);

  Future<void>? _uploadChain;
  bool _uploadBusy = false;

  /// One connection, one upload at a time. Two uploads on the same socket
  /// interleave, and the reconnect one performs destroys the other's in-flight
  /// request — both then sit in the 60s timeout and the loop repeats for every
  /// part (one part per minute).
  Future<T> _serialized<T>(Future<T> Function() body) {
    final prev = _uploadChain ?? Future<void>.value();
    final result = prev.then((_) => body());
    _uploadChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<t.Result<t.UpdatesBase>> uploadToSavedMessages(
    String filePath, {
    String caption = '',
    void Function(String)? onStatus,
    int videoWidth = 0,
    int videoHeight = 0,
    int videoDuration = 0,
  }) {
    if (_uploadBusy) onStatus?.call('Waiting for the current upload…');
    return _serialized(() async {
      _uploadBusy = true;
      try {
        return await _uploadToSavedMessages(
          filePath,
          caption: caption,
          onStatus: onStatus,
          videoWidth: videoWidth,
          videoHeight: videoHeight,
          videoDuration: videoDuration,
        );
      } finally {
        _uploadBusy = false;
      }
    });
  }

  Future<t.Result<t.UpdatesBase>> _uploadToSavedMessages(
    String filePath, {
    String caption = '',
    void Function(String)? onStatus,
    int videoWidth = 0,
    int videoHeight = 0,
    int videoDuration = 0,
  }) async {
    final file = File(filePath);
    final fileBytes = await file.readAsBytes();
    final fileName = filePath.split('/').last;
    final fileSize = fileBytes.length;

    // Stable across retries: the server keeps the parts keyed by fileId, so a
    // reconnect can resume at the first missing part instead of starting over
    // at 1/N. randomId stays stable too, so Telegram dedupes a resend of a
    // sendMedia that actually landed before we timed out.
    final fileId = Random().nextInt(1 << 30) + (Random().nextInt(1 << 30) << 30);
    final randomId = Random().nextInt(1 << 31);
    final uploadedParts = <int>{};

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        if (attempt > 0) {
          onStatus?.call(
              'Reconnecting… (resuming at part ${uploadedParts.length + 1}/'
              '${(fileSize / (512 * 1024)).ceil()})');
        }
        await ensureConnected(force: attempt > 0);
        return await _doUploadFile(fileBytes, fileName, fileSize,
            caption: caption,
            onStatus: onStatus,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            videoDuration: videoDuration,
            fileId: fileId,
            randomId: randomId,
            uploadedParts: uploadedParts);
      } catch (e) {
        debugPrint('[Upload] attempt ${attempt + 1} failed: $e');
        if (attempt < 2 && !_isNonRetryable(e)) {
          continue;
        }
        rethrow;
      }
    }
    throw StateError('Upload failed');
  }

  bool _isNonRetryable(Object e) {
    final s = e.toString();
    if (s.contains('AUTH_KEY_UNREGISTERED')) return true;
    if (s.contains('session expired')) return true;
    if (s.contains('Send code first')) return true;
    return false;
  }

  Future<t.Result<t.UpdatesBase>> _doUploadFile(
    Uint8List fileBytes,
    String fileName,
    int fileSize, {
    String caption = '',
    void Function(String)? onStatus,
    int videoWidth = 0,
    int videoHeight = 0,
    int videoDuration = 0,
    required int fileId,
    required int randomId,
    required Set<int> uploadedParts,
  }) async {
    const chunkSize = 512 * 1024;
    const bigFileThreshold = 10 * 1024 * 1024;
    final totalParts = (fileSize / chunkSize).ceil();
    final isBigFile = fileSize > bigFileThreshold;

    for (int i = 0; i < totalParts; i++) {
      if (uploadedParts.contains(i)) continue;
      onStatus?.call('Uploading part ${i + 1}/$totalParts…');
      final start = i * chunkSize;
      final end = start + chunkSize > fileSize ? fileSize : start + chunkSize;
      final chunk = fileBytes.sublist(start, end);

      await _saveUploadPart(
        fileId: fileId,
        part: i,
        totalParts: totalParts,
        isBigFile: isBigFile,
        chunk: chunk,
        uploadedParts: uploadedParts,
        onStatus: onStatus,
      );
    }

    final t.InputFileBase inputFile = isBigFile
        ? t.InputFileBig(id: fileId, parts: totalParts, name: fileName)
        : t.InputFile(id: fileId, parts: totalParts, name: fileName, md5Checksum: '');

    final ext = fileName.split('.').last.toLowerCase();
    final isVideo = _videoMimeTypes.containsKey(ext);
    final isImage = _imageMimeTypes.containsKey(ext);

    late t.InputMediaBase media;
    if (isVideo) {
      media = t.InputMediaUploadedDocument(
        nosoundVideo: false,
        forceFile: false,
        spoiler: false,
        file: inputFile,
        mimeType: _videoMimeTypes[ext]!,
        attributes: [
          t.DocumentAttributeVideo(
            roundMessage: false,
            supportsStreaming: true,
            nosound: false,
            duration: videoDuration.toDouble(),
            w: videoWidth,
            h: videoHeight,
          ),
          t.DocumentAttributeFilename(fileName: fileName),
        ],
      );
    } else if (isImage && !isBigFile) {
      // inputMediaUploadedPhoto accepts InputFile only. Over 10MB Telegram
      // requires saveBigFilePart → InputFileBig, which cannot be a photo
      // upload, so a larger image has to travel as a document.
      media = t.InputMediaUploadedPhoto(
        spoiler: false,
        livePhoto: false,
        file: inputFile as t.InputFile,
      );
    } else {
      media = t.InputMediaUploadedDocument(
        nosoundVideo: false,
        forceFile: isImage,
        spoiler: false,
        file: inputFile,
        mimeType: isImage
            ? _imageMimeTypes[ext]!
            : 'application/octet-stream',
        attributes: [
          t.DocumentAttributeFilename(fileName: fileName),
        ],
      );
    }

    onStatus?.call('Sending to Telegram…');
    final sendResult = await _client!.messages.sendMedia(
      peer: const t.InputPeerSelf(),
      media: media,
      message: caption,
      randomId: randomId,
      silent: true,
      background: false,
      clearDraft: false,
      noforwards: false,
      updateStickersetsOrder: false,
      invertMedia: false,
      allowPaidFloodskip: false,
    ).timeout(const Duration(seconds: 60));

    if (sendResult.error != null) {
      throw Exception('Telegram ${sendResult.error!.errorCode}: ${sendResult.error!.errorMessage}');
    }

    return sendResult;
  }

  /// Uploads one chunk, retrying with a forced reconnect on timeout/socket
  /// errors. A part is only marked done once the server confirms it, so a
  /// resume starts at the first missing part instead of part 1.
  Future<void> _saveUploadPart({
    required int fileId,
    required int part,
    required int totalParts,
    required bool isBigFile,
    required Uint8List chunk,
    required Set<int> uploadedParts,
    void Function(String)? onStatus,
  }) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (attempt > 0) {
          onStatus?.call('Reconnecting… (part ${part + 1}/$totalParts)');
          await ensureConnected(force: true);
        }
        final client = _client;
        if (client == null) throw StateError('Not connected');

        final bytes = Uint8List.fromList(chunk);
        final result = isBigFile
            ? await client.upload
                .saveBigFilePart(
                  fileId: fileId,
                  filePart: part,
                  fileTotalParts: totalParts,
                  bytes: bytes,
                )
                .timeout(const Duration(seconds: 60))
            : await client.upload
                .saveFilePart(
                  fileId: fileId,
                  filePart: part,
                  bytes: bytes,
                )
                .timeout(const Duration(seconds: 60));

        if (result.error != null) {
          throw Exception('Upload failed at part $part: ${result.error}');
        }
        if (result.result == null || !result.result!.value) {
          throw Exception('Upload failed at part $part: server rejected part');
        }
        uploadedParts.add(part);
        return;
      } catch (e) {
        last = e;
        debugPrint(
            '[Upload] part ${part + 1}/$totalParts attempt ${attempt + 1} failed: $e');
        if (_isNonRetryable(e)) rethrow;
      }
    }
    throw last ?? StateError('Upload failed at part $part');
  }

  List<SavedMessageItem> _lastFetchedMessages = [];
  int _syncGeneration = 0;
  bool _hasSyncedMessages = false;

  /// Bumped on every successful history fetch. Listeners use it to know that
  /// a fresh sync happened without having to diff the message list themselves.
  int get syncGeneration => _syncGeneration;

  /// True once at least one history fetch has succeeded in this run.
  bool get hasSynced => _hasSyncedMessages;

  Future<List<SavedMessageItem>> getSavedMessages({int limit = 50}) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        await ensureConnected(force: attempt > 0);
        final msgs = await _fetchSavedMessages(limit: limit);
        _lastFetchedMessages = msgs;
        _hasSyncedMessages = true;
        _syncGeneration++;
        // A refresh is the user telling us the current tiles are wrong, so
        // give the ones that came back empty another chance.
        clearFailedThumbnails();
        notifyListeners();
        return msgs;
      } catch (e) {
        if (attempt == 0 && !_isNonRetryable(e)) {
          continue;
        }
        rethrow;
      }
    }
    throw StateError('Failed to get saved messages');
  }

  Future<t.InputPeerBase> _resolveSelfPeer() async {
    final usersResult = await _client!.users.getUsers(id: [
      const t.InputUserSelf(),
    ]);
    if (usersResult.error != null || usersResult.result == null) {
      return t.InputPeerSelf();
    }
    final users = usersResult.result as t.Vector<t.UserBase>;
    for (final u in users.items) {
      if (u is t.User) {
        return t.InputPeerUser(userId: u.id, accessHash: u.accessHash ?? 0);
      }
    }
    return t.InputPeerSelf();
  }

  Future<List<SavedMessageItem>> _fetchSavedMessages({int limit = 50}) async {
    final peer = await _resolveSelfPeer();

    final historyResult = await _client!.messages.getHistory(
      peer: peer,
      offsetId: 1 << 30,
      offsetDate: DateTime(1970),
      addOffset: 0,
      limit: limit,
      maxId: 0,
      minId: 0,
      hash: 0,
    );

    if (historyResult.error != null) {
      debugPrint('getHistory failed: ${historyResult.error}');
      final err = historyResult.error;
      if (err != null && err.errorCode == 401 && err.errorMessage == 'AUTH_KEY_UNREGISTERED') {
        debugPrint('Auth key unregistered — clearing session');
        await clearSession();
        throw StateError('AUTH_KEY_UNREGISTERED');
      }
      final savedResult = await _client!.messages.getSavedHistory(
        peer: peer,
        offsetId: 1 << 30,
        offsetDate: DateTime(1970),
        addOffset: 0,
        limit: limit,
        maxId: 0,
        minId: 0,
        hash: 0,
      );
      if (savedResult.error != null) {
        throw Exception('Failed to get messages: ${savedResult.error}');
      }
      debugPrint('getSavedHistory type: ${savedResult.result.runtimeType}');
      return _parseMessagesBase(savedResult.result);
    }

    debugPrint('getHistory type: ${historyResult.result.runtimeType}');
    final base = historyResult.result;
    if (base is t.MessagesMessages) {
      debugPrint('getHistory: ${base.messages.length} messages');
      for (final m in base.messages) {
        debugPrint('  msg: ${m.runtimeType} id=${m is t.Message ? m.id : "?"} media=${m is t.Message ? m.media?.runtimeType : "?"}');
      }
    } else if (base is t.MessagesMessagesSlice) {
      debugPrint('getHistory Slice: ${base.messages.length} messages, count=${base.count}');
      for (final m in base.messages) {
        debugPrint('  msg: ${m.runtimeType} id=${m is t.Message ? m.id : "?"} media=${m is t.Message ? m.media?.runtimeType : "?"}');
      }
    } else {
      debugPrint('getHistory: ${base.runtimeType}');
    }

    final items = _parseMessagesBase(base);
    debugPrint('parsed items: ${items.length}');
    return items;
  }

  List<SavedMessageItem> _parseMessagesBase(t.MessagesMessagesBase? base) {
    final items = <SavedMessageItem>[];
    if (base == null) return items;
    if (base is t.MessagesMessages) {
      debugPrint('getSavedHistory: MessagesMessages count=${base.messages.length}');
      items.addAll(_parseMessages(base.messages));
    } else if (base is t.MessagesMessagesSlice) {
      debugPrint('getSavedHistory: MessagesMessagesSlice count=${base.messages.length}');
      items.addAll(_parseMessages(base.messages));
    } else if (base is t.MessagesChannelMessages) {
      debugPrint('getSavedHistory: MessagesChannelMessages count=${base.messages.length}');
      items.addAll(_parseMessages(base.messages));
    } else if (base is t.MessagesMessagesNotModified) {
      debugPrint('getSavedHistory: MessagesMessagesNotModified count=${base.count}');
    } else {
      debugPrint('getSavedHistory: unknown type ${base.runtimeType}');
    }
    return items;
  }

  /// Raw message vector for any `messages.*` result, including entries that
  /// [_parseMessages] would drop (service messages, `messageEmpty`).
  static List<t.MessageBase> _rawMessages(t.MessagesMessagesBase? base) {
    if (base is t.MessagesMessages) return base.messages;
    if (base is t.MessagesMessagesSlice) return base.messages;
    if (base is t.MessagesChannelMessages) return base.messages;
    return const [];
  }

  /// Pulls the id of the message that [uploadToSavedMessages] just created so
  /// the upload queue can later tell whether that copy still exists.
  static int? extractSentMessageId(t.Result<t.UpdatesBase> result) {
    final updates = result.result;
    if (updates == null) return null;
    if (updates is t.UpdateShortSentMessage) return updates.id;
    if (updates is t.UpdateShort) return _idFromUpdate(updates.update);
    if (updates is t.Updates) {
      for (final u in updates.updates) {
        final id = _idFromUpdate(u);
        if (id != null) return id;
      }
    }
    return null;
  }

  static int? _idFromUpdate(t.UpdateBase update) {
    if (update is t.UpdateNewMessage) {
      final m = update.message;
      if (m is t.Message) return m.id;
      if (m is t.MessageEmpty) return m.id;
    }
    return null;
  }

  /// Checks which uploaded copies still exist in Telegram.
  ///
  /// Returns null when nothing could be verified at all — no session, no
  /// connection — so the caller can keep its previous answer instead of
  /// wiping it. Never reports an upload as deleted without positive evidence.
  Future<TelegramUploadVerdict?> verifyUploads(
      List<TelegramUploadProbe> probes) async {
    final present = <String>{};
    final absent = <String>{};
    if (probes.isEmpty) {
      return TelegramUploadVerdict(present: present, absent: absent);
    }
    if (!_authenticated) return null;
    try {
      await ensureConnected();
    } catch (e) {
      debugPrint('verifyUploads: not connected: $e');
      return null;
    }

    // Message ids are always re-checked against Telegram itself. The history
    // window cached from the Telegram page can be arbitrarily old, so "it was
    // in the last fetch" says nothing about whether it is still there — and
    // that staleness is exactly what left deleted uploads wearing the badge.
    // The one exception is a caption we just fetched, which is positive
    // evidence of life.
    final byId = <String, int>{};
    final titleProbes = <TelegramUploadProbe>[];
    for (final p in probes) {
      final id = p.messageId;
      if (id != null) {
        byId[p.key] = id;
      } else if (p.title != null && p.title!.trim().isNotEmpty) {
        if (_captionMatchesFetched(p.title!)) {
          present.add(p.key);
        } else {
          titleProbes.add(p);
        }
      }
    }

    if (byId.isNotEmpty) {
      const chunkSize = 100;
      final ids = byId.values.toList();
      for (var start = 0; start < ids.length; start += chunkSize) {
        final end =
            start + chunkSize > ids.length ? ids.length : start + chunkSize;
        final chunk = ids.sublist(start, end);
        final alive = <int>{};
        try {
          final res = await _client!.messages
              .getMessages(
                id: [for (final id in chunk) t.InputMessageID(id: id)],
              )
              .timeout(const Duration(seconds: 20));
          if (res.error != null || res.result == null) {
            // A failed probe is not proof of deletion; drop this round's
            // id results rather than wiping out a correct earlier answer.
            debugPrint('verifyUploads getMessages: ${res.error}');
            continue;
          }
          for (final m in _rawMessages(res.result)) {
            if (m is t.Message) alive.add(m.id);
          }
        } catch (e) {
          debugPrint('verifyUploads getMessages failed: $e');
          continue;
        }
        for (final e in byId.entries) {
          if (!chunk.contains(e.value)) continue;
          if (alive.contains(e.value)) {
            present.add(e.key);
          } else {
            // Telegram answers with `messageEmpty` for an id that no longer
            // resolves — that is the positive evidence we were missing.
            absent.add(e.key);
          }
        }
      }
    }

    if (titleProbes.isNotEmpty) {
      t.InputPeerBase peer;
      try {
        peer = await _resolveSelfPeer();
      } catch (e) {
        debugPrint('verifyUploads peer failed: $e');
        peer = const t.InputPeerSelf();
      }
      for (final p in titleProbes) {
        final needle = p.title!.trim();
        try {
          final res = await _client!.messages
              .search(
                peer: peer,
                q: needle,
                fromId: null,
                savedPeerId: null,
                savedReaction: null,
                topMsgId: null,
                filter: const t.InputMessagesFilterEmpty(),
                minDate: DateTime(1970),
                maxDate: DateTime(2100),
                offsetId: 0,
                addOffset: 0,
                limit: 10,
                maxId: 0,
                minId: 0,
                hash: 0,
              )
              .timeout(const Duration(seconds: 15));
          if (res.error != null || res.result == null) {
            debugPrint('verifyUploads search "$needle": ${res.error}');
            continue;
          }
          // Search is fuzzy: "something matched" is not evidence that *this*
          // upload still exists, so the caption has to actually be there.
          final alive = _rawMessages(res.result).any((m) {
            final text = m is t.Message ? m.message.trim() : '';
            return text.isNotEmpty && text.contains(needle);
          });
          if (alive) {
            present.add(p.key);
          } else {
            absent.add(p.key);
          }
        } catch (e) {
          debugPrint('verifyUploads search "$needle" failed: $e');
        }
      }
    }

    debugPrint('verifyUploads: ${probes.length} probed, '
        '${present.length} present, ${absent.length} deleted');
    return TelegramUploadVerdict(present: present, absent: absent);
  }

  bool _captionMatchesFetched(String title) {
    final needle = title.trim();
    if (needle.isEmpty) return true;
    for (final m in _lastFetchedMessages) {
      final caption = m.caption?.trim() ?? '';
      if (caption.isEmpty) continue;
      if (caption == needle || caption.endsWith(needle)) return true;
    }
    return false;
  }

  static List<String> _unique(List<String> values) {
    final seen = <String>{};
    return [for (final v in values) if (seen.add(v)) v];
  }

  List<SavedMessageItem> _parseMessages(List<t.MessageBase> messages) {
    final items = <SavedMessageItem>[];
    for (final msgBase in messages) {
      if (msgBase is t.Message) {
        final mediaType = _detectMediaType(msgBase.media);
        if (mediaType != SavedMediaType.none) {
          final item = SavedMessageItem(
            id: msgBase.id,
            date: msgBase.date,
            caption: msgBase.message,
            mediaType: mediaType,
          );
          if (msgBase.media is t.MessageMediaPhoto) {
            item.mimeType = 'image/jpeg';
            final photo = (msgBase.media as t.MessageMediaPhoto).photo;
            if (photo is t.Photo) {
              item.thumbnailId = photo.id;
              item.thumbnailAccessHash = photo.accessHash;
              item.thumbnailFileReference = photo.fileReference;
              // Largest available rendition — what the full-screen viewer
              // streams. `thumbSizes` (below) keeps every rendition from
              // smallest upward so the grid stays cheap but can still fall
              // back when one size is refused.
              String? fullType;
              int fullBytes = 0;
              final candidates = <MapEntry<String, int>>[];
              for (final s in photo.sizes) {
                int total = 0;
                String? type;
                if (s is t.PhotoSize) {
                  total = s.size;
                  type = s.type;
                } else if (s is t.PhotoSizeProgressive) {
                  total = s.sizes.isNotEmpty ? s.sizes.last : 0;
                  type = s.type;
                }
                if (total <= 0 || type == null || type.isEmpty) continue;
                candidates.add(MapEntry(type, total));
                if (total > fullBytes) {
                  fullBytes = total;
                  fullType = type;
                }
              }
              if (fullType != null && fullBytes > 0) {
                item.fullSizeType = fullType;
                item.fileSize = fullBytes;
              }
              candidates.sort((a, b) => a.value.compareTo(b.value));
              item.thumbSizes =
                  _unique([for (final e in candidates) e.key]);
              item.thumbSize = item.thumbSizes.isNotEmpty
                  ? item.thumbSizes.first
                  : 's';
              if (item.thumbSizes.isEmpty) item.thumbSizes = ['s', 'm'];
              debugPrint('Photo thumb: id=${photo.id} sizes=${photo.sizes.length} candidates=${item.thumbSizes}');
            } else {
              debugPrint('Photo not Photo type: ${photo.runtimeType}');
            }
          } else if (msgBase.media is t.MessageMediaDocument) {
            final doc = (msgBase.media as t.MessageMediaDocument).document;
            if (doc is t.Document) {
              item.thumbnailId = doc.id;
              item.thumbnailAccessHash = doc.accessHash;
              item.thumbnailFileReference = doc.fileReference;
              item.fileSize = doc.size;
              item.mimeType = doc.mimeType;
              item.dcId = doc.dcId;

              // Telegram stores frame captures in `videoThumbs` (types like
              // "i"/"j") and extension thumbnails in `thumbs` (types like
              // "s"/"m"). A video almost always only has the former, so
              // asking for "s" on a video came back as an RPC error and the
              // tile fell back to an icon — probe the matching family first.
              final frameSizes = <String>[];
              for (final vt in doc.videoThumbs ?? const <t.VideoSizeBase>[]) {
                if (vt is t.VideoSize && vt.type.isNotEmpty) {
                  frameSizes.add(vt.type);
                }
              }
              final extCandidates = <MapEntry<String, int>>[];
              for (final th in doc.thumbs ?? const <t.PhotoSizeBase>[]) {
                int total = 0;
                String? type;
                if (th is t.PhotoSize) {
                  total = th.size;
                  type = th.type;
                } else if (th is t.PhotoSizeProgressive) {
                  total = th.sizes.isNotEmpty ? th.sizes.last : 0;
                  type = th.type;
                }
                if (total <= 0 || type == null || type.isEmpty) continue;
                extCandidates.add(MapEntry(type, total));
              }
              extCandidates.sort((a, b) => a.value.compareTo(b.value));

              final isVideo = mediaType == SavedMediaType.video;
              final ordered = isVideo
                  ? [...frameSizes, ...extCandidates.map((e) => e.key)]
                  : [...extCandidates.map((e) => e.key), ...frameSizes];
              item.thumbSizes = _unique(ordered);
              if (item.thumbSizes.isEmpty) {
                item.thumbSizes = isVideo ? ['i', 's'] : ['s', 'i'];
              }
              item.thumbSize = item.thumbSizes.first;
              debugPrint('Doc thumb: id=${doc.id} dc=${doc.dcId} '
                  'thumbs=${doc.thumbs?.length} videoThumbs=${doc.videoThumbs?.length} '
                  'candidates=${item.thumbSizes}');
            }
          }
          items.add(item);
        }
      }
    }
    return items;
  }

  SavedMediaType _detectMediaType(t.MessageMediaBase? media) {
    if (media == null) return SavedMediaType.none;
    if (media is t.MessageMediaPhoto) {
      return SavedMediaType.photo;
    } else if (media is t.MessageMediaDocument) {
      final doc = media.document;
      if (doc is t.Document) {
        for (final attr in doc.attributes) {
          if (attr is t.DocumentAttributeVideo) return SavedMediaType.video;
        }
        if (doc.mimeType.startsWith('video/')) return SavedMediaType.video;
        if (doc.mimeType.startsWith('audio/')) return SavedMediaType.audio;
        return SavedMediaType.document;
      }
      return SavedMediaType.document;
    }
    return SavedMediaType.none;
  }

  Future<void> disconnect() async {
    _streamSub?.cancel();
    _streamSub = null;
    _client = null;
    _connected = false;
    if (_ioSocket != null) {
      try { await _ioSocket!.close(); } catch (_) {}
      _ioSocket = null;
    }
    notifyListeners();
  }

  HttpServer? _streamServer;
  int _streamPort = 0;

  Future<int> ensureStreamServer() async {
    if (_streamServer != null) return _streamPort;
    _streamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _streamPort = _streamServer!.port;
    debugPrint('[Stream] started on 127.0.0.1:$_streamPort');
    _streamServer!.listen(_handleRequest);
    return _streamPort;
  }

  void closeStreamServer() {
    _streamServer?.close();
    _streamServer = null;
    debugPrint('[Stream] closed');
  }

  String? streamUrlFor(SavedMessageItem item) {
    if (_streamServer == null) return null;
    return 'http://127.0.0.1:$_streamPort/stream?id=${item.id}';
  }

  void _handleRequest(HttpRequest req) {
    _serveStream(req);
  }

  static const _chunkSize = 512 * 1024;

  Future<void> _serveStream(HttpRequest req) async {
    final idStr = req.uri.queryParameters['id'];
    if (idStr == null) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    final id = int.tryParse(idStr);
    if (id == null) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }

    final item = _findItemById(id);
    if (item == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    if (item.thumbnailId == null || item.thumbnailAccessHash == null || item.thumbnailFileReference == null) {
      req.response.statusCode = 500;
      await req.response.close();
      return;
    }

    final total = item.fileSize ?? 0;
    if (total <= 0) {
      debugPrint('[Stream] id=$id has no known size (fileSize=${item.fileSize}) — refusing to range-serve');
      req.response.statusCode = 500;
      await req.response.close();
      return;
    }

    debugPrint('[Stream] ${req.method} id=$id total=$total');

    // Mutable: a FILE_REFERENCE_EXPIRED below re-reads the message and swaps
    // in the refreshed reference, so the location has to be rebuildable.
    t.InputFileLocationBase buildLocation(SavedMessageItem it) {
      if (it.mediaType == SavedMediaType.photo) {
        return t.InputPhotoFileLocation(
          id: it.thumbnailId!,
          accessHash: it.thumbnailAccessHash!,
          fileReference: it.thumbnailFileReference!,
          thumbSize: it.fullSizeType ?? it.thumbSize ?? '',
        );
      }
      return t.InputDocumentFileLocation(
        id: it.thumbnailId!,
        accessHash: it.thumbnailAccessHash!,
        fileReference: it.thumbnailFileReference!,
        thumbSize: '',
      );
    }

    var location = buildLocation(item);

    // AVFoundation always probes with "Range: bytes=0-1" and requires a 206
    // whose Content-Range/Content-Length match the requested window exactly.
    int start = 0;
    int end = total - 1;
    bool partial = false;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHeader.trim());
      if (match == null) {
        req.response.statusCode = 416;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await req.response.close();
        return;
      }
      final rawStart = match.group(1) ?? '';
      final rawEnd = match.group(2) ?? '';
      if (rawStart.isEmpty && rawEnd.isEmpty) {
        req.response.statusCode = 416;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await req.response.close();
        return;
      }
      if (rawStart.isEmpty) {
        final suffix = int.tryParse(rawEnd) ?? 0;
        start = suffix <= 0 ? total - 1 : total - suffix;
        if (start < 0) start = 0;
        end = total - 1;
      } else {
        start = int.tryParse(rawStart) ?? 0;
        end = rawEnd.isEmpty ? total - 1 : (int.tryParse(rawEnd) ?? total - 1);
      }
      if (start >= total || start > end) {
        req.response.statusCode = 416;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await req.response.close();
        return;
      }
      if (end > total - 1) end = total - 1;
      partial = true;
    }
    final length = end - start + 1;

    // AVFoundation is pickier than a browser: an octet-stream/mp4 label that
    // contradicts the container makes it bail out with a CoreMedia error.
    String contentType;
    final mime = item.mimeType;
    if (item.mediaType == SavedMediaType.photo) {
      contentType = 'image/jpeg';
    } else if (mime != null && (mime.startsWith('video/') || mime.startsWith('audio/'))) {
      contentType = mime;
    } else if (item.mediaType == SavedMediaType.video) {
      contentType = 'video/mp4';
    } else {
      contentType = 'application/octet-stream';
    }

    void setHeaders() {
      req.response.statusCode = partial ? 206 : 200;
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      req.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      req.response.headers.contentLength = length;
      if (partial) {
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      }
    }

    if (req.method == 'HEAD') {
      setHeaders();
      await req.response.close();
      debugPrint('[Stream] HEAD id=$id length=$length');
      return;
    }

    if (_client == null) {
      try {
        await ensureConnected();
      } catch (e) {
        debugPrint('[Stream] reconnect failed: $e');
      }
    }
    if (_client == null) {
      req.response.statusCode = 503;
      await req.response.close();
      return;
    }

    // getFile only accepts 4096-aligned offsets, so every fetch starts at
    // alignDown(pos) and the leading bytes before `pos` are dropped.
    // `pos` is the first byte still owed to the client.
    int pos = start;
    int sent = 0;

    // One dropped chunk used to truncate a response whose Content-Length was
    // already committed — AVFoundation then reports a CoreMedia/NSURLError
    // failure for a file that is perfectly fine. Retry hard instead.
    Future<Uint8List?> fetchChunk(int offset) async {
      var precise = true;
      for (var attempt = 0; attempt < 3; attempt++) {
        if (_client == null) {
          try {
            await ensureConnected();
          } catch (e) {
            debugPrint('[Stream] reconnect failed: $e');
          }
        }
        final client = _client;
        if (client == null) return null;
        try {
          final result = await client.upload.getFile(
            precise: precise,
            cdnSupported: false,
            location: location,
            offset: offset,
            limit: _chunkSize,
          ).timeout(const Duration(seconds: 30));
          final err = result.error;
          if (err != null) {
            debugPrint('[Stream] getFile offset=$offset attempt=$attempt '
                'precise=$precise: $err');
            final msg = err.errorMessage;
            if (msg.contains('FILE_REFERENCE') && attempt < 2) {
              if (await _refreshMessageReference(id)) {
                location = buildLocation(item);
                continue;
              }
            }
            precise = false;
            continue;
          }
          if (result.result is! t.UploadFile) {
            debugPrint('[Stream] unexpected type at offset=$offset: '
                '${result.result.runtimeType}');
            precise = false;
            continue;
          }
          final bytes = (result.result as t.UploadFile).bytes;
          if (bytes.isEmpty) return null;
          return bytes;
        } catch (e) {
          debugPrint('[Stream] getFile offset=$offset attempt=$attempt error: $e');
          final s = e.toString();
          if (s.contains('SocketException') ||
              s.contains('TimeoutException') ||
              s.contains('Closed')) {
            try {
              await ensureConnected(force: true);
            } catch (_) {}
          }
          precise = false;
        }
      }
      return null;
    }

    Uint8List? buf;
    int bufPos = 0;

    try {
      final firstAligned = (pos ~/ 4096) * 4096;
      final first = await fetchChunk(firstAligned);
      if (first == null || first.isEmpty) {
        req.response.statusCode = 502;
        await req.response.close();
        return;
      }
      buf = first;
      bufPos = pos - firstAligned;
      if (bufPos >= buf.length) {
        req.response.statusCode = 502;
        await req.response.close();
        return;
      }

      // Headers are committed only after the first chunk is in hand, so a
      // Telegram failure becomes an honest 502 instead of a truncated 200 that
      // AVPlayer reports as "the server is not correctly configured".
      setHeaders();

      while (sent < length) {
        if (buf == null) {
          final aligned = (pos ~/ 4096) * 4096;
          final chunk = await fetchChunk(aligned);
          if (chunk == null || chunk.isEmpty) break;
          buf = chunk;
          bufPos = pos - aligned;
          // The server handed back less than the alignment gap: nothing here
          // covers `pos`, so continuing would loop forever.
          if (bufPos < 0 || bufPos >= buf.length) break;
        }

        final available = buf.length - bufPos;
        var take = available;
        if (sent + take > length) take = length - sent;

        req.response.add(buf.sublist(bufPos, bufPos + take));
        bufPos += take;
        sent += take;
        pos += take;
        if (sent >= length) break;

        // Back-pressure: without it the whole requested range is pulled out
        // of Telegram into memory as fast as the network allows, no matter
        // how little of it AVPlayer has asked for so far.
        try {
          await req.response.flush();
        } catch (e) {
          debugPrint('[Stream] flush aborted: $e');
          return;
        }

        if (bufPos >= buf.length) buf = null;
      }
    } catch (e) {
      debugPrint('[Stream] error: $e');
    }

    debugPrint('[Stream] served id=$id bytes=$sent/$length');
    try {
      await req.response.close();
    } catch (e) {
      debugPrint('[Stream] close failed: $e');
    }
  }

  /// Re-reads a single message so an expired file reference can be replaced.
  /// Returns true when the cached item was refreshed.
  Future<bool> _refreshMessageReference(int id) async {
    try {
      await ensureConnected();
      final res = await _client!.messages
          .getMessages(id: [t.InputMessageID(id: id)])
          .timeout(const Duration(seconds: 20));
      if (res.error != null) {
        debugPrint('[Stream] refresh ref id=$id: ${res.error}');
        return false;
      }
      SavedMessageItem? fresh;
      for (final it in _parseMessages(_rawMessages(res.result))) {
        if (it.id == id) {
          fresh = it;
          break;
        }
      }
      final existing = _findItemById(id);
      if (fresh == null || existing == null) return false;
      if (fresh.thumbnailFileReference == null) return false;
      existing.thumbnailId = fresh.thumbnailId;
      existing.thumbnailAccessHash = fresh.thumbnailAccessHash;
      existing.thumbnailFileReference = fresh.thumbnailFileReference;
      existing.thumbSize = fresh.thumbSize;
      existing.thumbSizes = fresh.thumbSizes;
      existing.dcId = fresh.dcId;
      existing.fullSizeType = fresh.fullSizeType;
      existing.fileSize = fresh.fileSize;
      existing.mimeType = fresh.mimeType;
      debugPrint('[Stream] refreshed file reference for id=$id');
      return true;
    } catch (e) {
      debugPrint('[Stream] refresh ref id=$id failed: $e');
      return false;
    }
  }

  SavedMessageItem? _findItemById(int id) {
    for (final item in _lastFetchedMessages) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<String?> downloadVideoFile(
    SavedMessageItem item, {
    void Function(double)? onProgress,
    void Function(String)? onStatus,
  }) async {
    if (item.thumbnailId == null || item.thumbnailAccessHash == null || item.thumbnailFileReference == null) {
      return null;
    }
    final dir = Directory('${Directory.systemTemp.path}/tg_downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    final fileName = 'tg_${item.id}_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final filePath = '${dir.path}/$fileName';
    final file = File(filePath);

    final location = t.InputDocumentFileLocation(
      id: item.thumbnailId!,
      accessHash: item.thumbnailAccessHash!,
      fileReference: item.thumbnailFileReference!,
      thumbSize: '',
    );

    try {
      final raf = await file.open(mode: FileMode.write);
      int offset = 0;
      const chunkSize = 512 * 1024;
      int totalDownloaded = 0;
      int? totalSize;

      onStatus?.call('Starting download…');

      while (true) {
        final result = await _client!.upload.getFile(
          precise: false,
          cdnSupported: false,
          location: location,
          offset: offset,
          limit: chunkSize,
        ).timeout(const Duration(seconds: 30));

        if (result.error != null) break;
        if (result.result is! t.UploadFile) break;

        final uploadFile = result.result as t.UploadFile;
        if (uploadFile.bytes.isEmpty) break;

        await raf.writeFrom(uploadFile.bytes);
        totalDownloaded += uploadFile.bytes.length;
        offset += uploadFile.bytes.length;

        totalSize ??= uploadFile.bytes.length;
        onProgress?.call(totalDownloaded / (totalSize + 1));
        onStatus?.call('Downloaded ${(totalDownloaded / 1024 / 1024).toStringAsFixed(1)} MB');
      }

      await raf.close();
      onStatus?.call('Download complete');
      onProgress?.call(1.0);
      return filePath;
    } catch (e) {
      debugPrint('downloadVideoFile error: $e');
      return null;
    }
  }

  /// One in-flight request per file id. The grid builds a `FutureBuilder`
  /// for every tile on every rebuild, so without this a single tap on the
  /// screen re-fired dozens of `getFile` RPCs down the one MTProto socket
  /// and starved them all past their timeouts.
  final Map<int, Future<Uint8List?>> _thumbnailRequests = {};

  /// Ids whose fetch came back empty, so a refresh can retry them.
  final Set<int> _failedThumbnails = {};
  final _Semaphore _thumbSlots = _Semaphore(6);

  void clearThumbnailCache() {
    _thumbnailCache.clear();
    _thumbnailRequests.clear();
    _failedThumbnails.clear();
  }

  /// Drops only the requests that returned nothing. A cached failure would
  /// otherwise be served to every later rebuild and the tile would stay an
  /// icon until the app restarted.
  void clearFailedThumbnails() {
    for (final key in _failedThumbnails) {
      _thumbnailRequests.remove(key);
    }
    _failedThumbnails.clear();
  }

  Future<Uint8List?> getThumbnail(SavedMessageItem item) {
    final key = item.thumbnailId;
    if (key == null) return Future<Uint8List?>.value(null);
    final pending = _thumbnailRequests[key];
    if (pending != null) return pending;

    final future = _fetchThumbnail(item, key);
    _thumbnailRequests[key] = future;
    future.then((bytes) {
      if (bytes != null) return;
      _failedThumbnails.add(key);
      // Don't pin a broken tile forever, but don't hammer the socket either.
      Future.delayed(const Duration(seconds: 5), () {
        if (identical(_thumbnailRequests[key], future)) {
          _thumbnailRequests.remove(key);
          _failedThumbnails.remove(key);
        }
      });
    }, onError: (_) {
      // Never leave a rejected future in the map: every later request would
      // be handed the same rejection and the tile could never recover.
      _thumbnailRequests.remove(key);
      _failedThumbnails.remove(key);
    });
    return future;
  }

  Future<Uint8List?> _fetchThumbnail(SavedMessageItem item, int cacheKey) async {
    await _thumbSlots.acquire();
    try {
      final cached = _thumbnailCache[cacheKey];
      if (cached != null) return cached;

      if (_client == null) {
        debugPrint('[getThumb] client null, reconnecting…');
        try {
          await ensureConnected();
        } catch (e) {
          debugPrint('[getThumb] reconnect failed: $e');
        }
      }
      if (item.thumbnailId == null || _client == null) {
        debugPrint('[getThumb] skip client=${_client != null} thumbId=${item.thumbnailId}');
        return null;
      }

      final sizes = item.thumbSizes.isNotEmpty
          ? item.thumbSizes
          : <String>[item.thumbSize ?? 's'];
      var refRefreshed = false;

      for (final size in sizes) {
        final bytes = await _fetchThumbAtSize(item, size, refreshRef: () async {
          if (refRefreshed) return false;
          refRefreshed = true;
          return _refreshMessageReference(item.id);
        });
        if (bytes != null) {
          _thumbnailCache[cacheKey] = bytes;
          return bytes;
        }
      }
      debugPrint('[getThumb] giving up id=${item.id} type=${item.mediaType} '
          'dc=${item.dcId} sizes=$sizes');
      return null;
    } finally {
      _thumbSlots.release();
    }
  }

  /// One rendition, a few passes. The second pass flips `precise`, which is
  /// the mode `downloadVideoFile` uses successfully, and a thrown error
  /// forces the socket back up before the last try.
  Future<Uint8List?> _fetchThumbAtSize(
    SavedMessageItem item,
    String size, {
    required Future<bool> Function() refreshRef,
  }) async {
    var refRefreshed = false;
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        // Built per pass: a FILE_REFERENCE refresh below rewrites the fields
        // on `item` in place, so the location has to be rebuilt to pick it up.
        final location = _buildThumbnailLocation(item, size);
        if (location == null) return null;

        final result = await _client!.upload.getFile(
          precise: attempt == 1,
          cdnSupported: false,
          location: location,
          offset: 0,
          // Progressive renditions can be larger than 128 KB, and a
          // truncated JPEG fails to decode — the tile then shows nothing.
          limit: 512 * 1024,
        ).timeout(const Duration(seconds: 15));

        if (result.error != null) {
          final err = '${result.error}';
          debugPrint('[getThumb] id=${item.id} size=$size attempt=$attempt err=$err');
          if (err.contains('FILE_REFERENCE') && !refRefreshed) {
            refRefreshed = true;
            if (await refreshRef()) {
              attempt--;
              continue;
            }
          }
          // This rendition is unusable; let the caller try the next size
          // rather than burning the remaining passes on the same one.
          return null;
        }

        if (result.result is t.UploadFile) {
          final bytes = (result.result as t.UploadFile).bytes;
          if (bytes.isEmpty) return null;
          debugPrint('[getThumb] id=${item.id} size=$size bytes=${bytes.length}');
          return bytes;
        }
        return null;
      } catch (e) {
        debugPrint('[getThumb] id=${item.id} size=$size attempt=$attempt threw $e');
        if (attempt < 2 && !_isNonRetryable(e)) {
          // Only tear the socket down when it actually looks dead — a
          // forced reconnect would also kill a video that is streaming.
          try {
            await ensureConnected(force: true);
          } catch (_) {}
          continue;
        }
        return null;
      }
    }
    return null;
  }

  t.InputFileLocationBase? _buildThumbnailLocation(
      SavedMessageItem item, String size) {
    if (item.thumbnailId == null ||
        item.thumbnailAccessHash == null ||
        item.thumbnailFileReference == null) {
      debugPrint('_buildThumbnailLocation: missing fields id=${item.thumbnailId} hash=${item.thumbnailAccessHash} ref=${item.thumbnailFileReference != null} size=$size type=${item.mediaType}');
      return null;
    }
    if (item.mediaType == SavedMediaType.photo) {
      return t.InputPhotoFileLocation(
        id: item.thumbnailId!,
        accessHash: item.thumbnailAccessHash!,
        fileReference: item.thumbnailFileReference!,
        thumbSize: size,
      );
    }
    return t.InputDocumentFileLocation(
      id: item.thumbnailId!,
      accessHash: item.thumbnailAccessHash!,
      fileReference: item.thumbnailFileReference!,
      thumbSize: size,
    );
  }

  static Future<void> setDefaultDestination(UploadDestination dest) async {
    await _storage.write(key: _defaultDestKey, value: dest.name);
  }

  static Future<UploadDestination> getDefaultDestination() async {
    final val = await _storage.read(key: _defaultDestKey);
    if (val == null) return UploadDestination.youtube;
    return UploadDestination.values.firstWhere(
      (e) => e.name == val,
      orElse: () => UploadDestination.youtube,
    );
  }
}

enum SavedMediaType { none, photo, video, document, audio }

class SavedMessageItem {
  final int id;
  final DateTime date;
  final String? caption;
  final SavedMediaType mediaType;
  int? thumbnailId;
  int? thumbnailAccessHash;
  Uint8List? thumbnailFileReference;
  String? thumbSize;

  /// Every rendition Telegram advertised, best first. One guess is not
  /// enough: a size the server never generated comes back as an RPC error,
  /// which is how video tiles ended up permanently without a thumbnail.
  List<String> thumbSizes = const [];

  /// The datacenter that hosts the underlying file. Only used for logging —
  /// a mismatch shows up as FILE_MIGRATE in the thumbnail diagnostics.
  int? dcId;

  String? fullSizeType;
  int? fileSize;
  String? mimeType;
  bool hasLocalCopy;

  SavedMessageItem({
    required this.id,
    required this.date,
    this.caption,
    required this.mediaType,
    this.fileSize,
    this.mimeType,
    this.hasLocalCopy = false,
  });
}

/// One entry of the upload queue that should be checked against Telegram.
class TelegramUploadProbe {
  const TelegramUploadProbe({required this.key, this.messageId, this.title});

  /// Caller-scoped id (the upload job id).
  final String key;

  /// Telegram message id, when the upload recorded one.
  final int? messageId;

  /// Caption/title used to find legacy uploads that predate message ids.
  final String? title;
}

/// Result of one round of checking uploads against Telegram.
///
/// Only what was actually determined is listed. Anything in neither set was
/// not verifiable this round (no id, failed search) and must keep whatever the
/// caller already believed about it — a failed probe is not proof of anything.
class TelegramUploadVerdict {
  const TelegramUploadVerdict({required this.present, required this.absent});

  /// Confirmed still in Telegram.
  final Set<String> present;

  /// Confirmed deleted from Telegram.
  final Set<String> absent;
}

/// Counting semaphore that hands its slot straight to the next waiter so the
/// active count never dips and a burst cannot slip past the limit.
class _Semaphore {
  _Semaphore(this._max);

  final int _max;
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() async {
    if (_active < _max) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    _active--;
  }
}

final Map<int, Uint8List> _thumbnailCache = {};
