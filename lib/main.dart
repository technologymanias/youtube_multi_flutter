import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:io' show Platform;

import 'SplashScreen.dart';
import 'services/account_manager.dart';
import 'services/upload_scheduler.dart';
import 'services/background_service.dart';
import 'services/telegram_service.dart';
import 'services/folder_store.dart';
import 'services/media_index.dart';
import 'services/master_sync.dart';
import 'pages/upload_queue_page.dart';
import 'pages/uuid_backfill_page.dart';
import 'pages/youtube_browser_page.dart';
import 'pages/stats_page.dart';
import 'pages/telegram_page.dart';
import 'pages/folder_strip.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeBackgroundService();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.white, centerTitle: false),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
        ),
      ),
      home: SplashScreen(nextScreen: MainShell()),
    ),
  );
}

String get clientIdd {
  if (kIsWeb) {
    return '419479685978-a2i54r2v2bjvkvm5mpd1i4ks5r3f68tt.apps.googleusercontent.com';
  } else if (Platform.isAndroid) {
    return '419479685978-o1lqlg3fq8lcn5leht17t50cp9l3ltj8.apps.googleusercontent.com';
  } else if (Platform.isIOS) {
    return '419479685978-k31nq590lglod4c2sm3tsounmc5ovu5d.apps.googleusercontent.com';
  } else {
    throw UnsupportedError('Unsupported platform');
  }
}

final GoogleSignIn googleSignIn = GoogleSignIn(
  clientId: clientIdd,
  scopes: [
    'email',
    'https://www.googleapis.com/auth/youtube.upload',
    'https://www.googleapis.com/auth/youtube.readonly',
    // Needed only by the UUID back-fill: rewriting an existing video's title
    // is a `videos.update` call, which `youtube.upload` does not cover. Adding
    // a scope invalidates the stored grant, so the user re-consents once.
    'https://www.googleapis.com/auth/youtube',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
  ],
);

// Get your own api_id and api_hash from https://my.telegram.org/apps
const int telegramApiId = 1959019;
const String telegramApiHash = 'b23130118cee6b065cf86ed78c171775';

class MainShell extends StatefulWidget {
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late final AccountManager _accountManager;
  late final UploadScheduler _scheduler;
  late final TelegramService _telegramService;
  late final FolderStore _folderStore;
  late final MasterSync _masterSync;
  bool _initialized = false;
  final PageController _pageCtrl = PageController();

  @override
  void initState() {
    super.initState();
    _accountManager = AccountManager(googleSignIn: googleSignIn);
    _scheduler = UploadScheduler();
    _telegramService = TelegramService(apiId: telegramApiId, apiHash: telegramApiHash);
    _folderStore = FolderStore();
    _masterSync = MasterSync(scheduler: _scheduler, accounts: _accountManager);
    _init();
  }

  Future<void> _init() async {
    try {
      // The UUID registry must be readable before the queue loads: startup
      // migration assigns identities to jobs that predate the UUID work.
      await MediaIndex.instance.ensureLoaded();
      await _scheduler.init();
      await _accountManager.init();
    } catch (_) {
      // Scheduler / account init errors — app may still work
    }
    // Folders are pure local state, so a failed read must never block startup.
    try {
      await _folderStore.load();
    } catch (_) {}
    // Master sync starts its own scan when it was left on, which is what
    // keeps a week-old gallery from needing a manual queue-up.
    try {
      await _masterSync.init();
    } catch (_) {}
    // The signed-in Telegram number scopes the statistics, and it is known
    // from storage before the Telegram page is ever opened. Uploads from
    // before the app recorded an account join whichever number is signed in
    // now — this device only holds one session at a time.
    try {
      await _telegramService.loadAccountKey();
      final tgKey = _telegramService.accountKey;
      if (tgKey != null) _scheduler.attributeLegacyTelegramJobs(tgKey);
    } catch (_) {}
    // Telegram session restore is handled by TelegramPage's _checkAuth()
    _accountManager.addListener(_onAccountChanged);
    _scheduler.addListener(_onSchedulerChanged);
    _folderStore.addListener(_onFoldersChanged);
    _telegramService.addListener(_onTelegramChanged);
    if (mounted) setState(() => _initialized = true);
  }

  void _onAccountChanged() {
    if (mounted) setState(() {});
  }

  void _onSchedulerChanged() {
    if (mounted) setState(() {});
  }

  void _onFoldersChanged() {
    if (mounted) setState(() {});
  }

  /// A sign-in (or a restore that only just finished resolving who it is)
  /// may be the first time this launch knows the Telegram account, which is
  /// when any unattributed uploads get pinned to it.
  void _onTelegramChanged() {
    final key = _telegramService.accountKey;
    if (key != null && key.isNotEmpty) {
      _scheduler.attributeLegacyTelegramJobs(key);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _accountManager.removeListener(_onAccountChanged);
    _scheduler.removeListener(_onSchedulerChanged);
    _folderStore.removeListener(_onFoldersChanged);
    _telegramService.removeListener(_onTelegramChanged);
    // Master sync's periodic timer must stop before the scheduler it feeds.
    _masterSync.dispose();
    _scheduler.dispose();
    _telegramService.dispose();
    _folderStore.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  /// Titles shown for local-vs-remote matching. Tag-stripped so a YouTube
  /// title that now carries a `[a1b2c3d4]` UUID tag still pairs with its
  /// queue row.
  Set<String> _buildLocalTitles() {
    final titles = <String>{};
    for (final job in _scheduler.jobs) {
      final t = MediaIndex.stripTag(job.title).trim();
      if (t.isNotEmpty) titles.add(t);
    }
    return titles;
  }

  /// Resolves a YouTube video to a device gallery asset so the browser page
  /// can show a local frame when YouTube has no public thumbnail (private).
  String? _resolveLocalAssetId(String videoId, String title) {
    if (videoId.isNotEmpty) {
      final byRemote = MediaIndex.instance.byYoutubeVideoId(videoId);
      if (byRemote?.assetId != null) return byRemote!.assetId;
      for (final job in _scheduler.jobs) {
        if (job.youtubeVideoId == videoId) return job.assetId;
      }
    }
    // Prefer the UUID tag: it is exact even when two uploads share a title.
    final tag = MediaIndex.parseTag(title);
    if (tag != null) {
      final byTag = MediaIndex.instance.byShortTag(tag);
      if (byTag?.assetId != null) return byTag!.assetId;
    }
    final trimmed = MediaIndex.stripTag(title).trim();
    if (trimmed.isEmpty) return null;
    for (final job in _scheduler.jobs) {
      if (MediaIndex.stripTag(job.title).trim() == trimmed) return job.assetId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Colors.green)),
      );
    }

    if (!_accountManager.isSignedIn) {
      return _buildSignInScreen();
    }

    return _buildMainApp();
  }

  Widget _buildSignInScreen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube Multi Uploader'),
      ),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Backup your iPhone videos to YouTube',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Upload queue • Scheduling • Multi-channel • 15/day YouTube limit',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _step('1', 'Tap Sign in with Google below'),
                          _step('2', 'Choose your YouTube channel'),
                          _step('3', 'Select videos from your gallery'),
                          _step('4', 'They auto-upload with 15/day YouTube scheduling'),
                          _step('5', 'Free up iPhone space safely'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: ElevatedButton(
                onPressed: _accountManager.loading ? null : () => _accountManager.signIn(),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _accountManager.loading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Sign in with Google', style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(String num, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 24, height: 24,
            decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(12)),
            child: Center(child: Text(num, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(color: Colors.grey[300], fontSize: 14))),
        ],
      ),
    );
  }

  int get _pageCount => 4;

  Widget _buildMainApp() {
    final realPages = <Widget>[
      UploadQueuePage(
        scheduler: _scheduler,
        accountManager: _accountManager,
        accessToken: _accountManager.accessToken,
        telegramService: _telegramService,
        folderStore: _folderStore,
      ),
      YoutubeBrowserPage(
        accountManager: _accountManager,
        localVideoTitles: _buildLocalTitles(),
        resolveLocalAssetId: _resolveLocalAssetId,
        folderStore: _folderStore,
      ),
      TelegramPage(
        service: _telegramService,
        localTitles: _buildLocalTitles(),
        folderStore: _folderStore,
      ),
      StatsPage(
        scheduler: _scheduler,
        accountManager: _accountManager,
        masterSync: _masterSync,
        telegramService: _telegramService,
        onSignOut: () async {
          await _accountManager.signOut();
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => MainShell()),
            (_) => false,
          );
        },
      ),
    ];

    // Wrap with sentinel pages for infinite scroll
    Widget sentinelOf(Widget w) {
      if (w is UploadQueuePage) {
        return UploadQueuePage(
          scheduler: w.scheduler,
          accountManager: w.accountManager,
          accessToken: w.accessToken,
          telegramService: w.telegramService,
          folderStore: w.folderStore,
          isSentinel: true,
        );
      }
      return w;
    }

    final pages = <Widget>[
      sentinelOf(realPages.last),
      ...realPages,
      sentinelOf(realPages.first),
    ];

    return Scaffold(
      drawer: _buildDrawer(),
      body: PageView(
        controller: _pageCtrl,
        children: pages,
        onPageChanged: (i) {
          if (i == 0) {
            _pageCtrl.jumpToPage(_pageCount);
          } else if (i == _pageCount + 1) {
            _pageCtrl.jumpToPage(1);
          }
        },
      ),
    );
  }

  Widget _buildDrawer() {
    final acct = _accountManager.currentAccount;
    final ch = _accountManager.selectedChannel;
    return Drawer(
      child: Column(
        children: [
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(color: Colors.black87),
            accountName: Text(
              acct?.displayName ?? 'User',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            accountEmail: Text(acct?.email ?? ''),
            currentAccountPicture: CircleAvatar(
              backgroundImage: acct?.photoUrl != null ? NetworkImage(acct!.photoUrl!) : null,
              child: acct?.photoUrl == null ? const Icon(Icons.person, size: 40) : null,
            ),
          ),

          // Page navigation
          _drawerItem(Icons.cloud_upload, 'Status Page', 0),
          _drawerItem(Icons.videocam, 'Youtube', 1),
          _drawerItem(Icons.telegram, 'Telegram', 2),
          _drawerItem(Icons.bar_chart, 'Home', 3),

          const Divider(color: Colors.grey, height: 1),

          // Today's count — for the selected channel, since that is whose
          // 15-a-day budget the number is out of.
          ListTile(
            leading: const Icon(Icons.today),
            title: const Text("Today's Uploads"),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(12)),
              child: Text(
                '${_scheduler.todayYoutubeCountForChannel(_accountManager.selectedChannelId)}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),

          // Total uploads for the signed-in account
          ListTile(
            leading: const Icon(Icons.cloud_upload),
            title: const Text('Total Uploads'),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: Colors.blueGrey, borderRadius: BorderRadius.circular(12)),
              child: Text(
                '${_scheduler.completedCountForAccount(_accountManager.currentAccount?.email)}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),

          // Default destination
          FutureBuilder<UploadDestination>(
            future: TelegramService.getDefaultDestination(),
            builder: (_, snap) {
              final dest = snap.data ?? UploadDestination.youtube;
              final labels = {UploadDestination.youtube: 'YouTube', UploadDestination.telegram: 'Telegram', UploadDestination.both: 'YouTube + Telegram'};
              return ListTile(
                leading: const Icon(Icons.settings_input_component),
                title: const Text('Default Destination'),
                subtitle: Text(labels[dest]!, style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                onTap: () => _showDestinationPicker(),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.folder_copy),
            title: const Text('Folder backup'),
            subtitle: Text(
              '${_folderStore.folders.length} folder${_folderStore.folders.length == 1 ? '' : 's'} on this device',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
            onTap: () => showFolderBackupDialog(context, _folderStore),
          ),

          // UUID back-fill for uploads that predate the UUID work.
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('UUID back-fill'),
            subtitle: Text(
              '${MediaIndex.instance.length} item${MediaIndex.instance.length == 1 ? '' : 's'} identified',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
            onTap: () {
              Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => UuidBackfillPage(
                    scheduler: _scheduler,
                    accountManager: _accountManager,
                    telegramService: _telegramService,
                  ),
                ),
              );
            },
          ),

          // Channel selector
          if (_accountManager.channels.length > 1) ...[
            const Divider(color: Colors.grey, height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Upload Channel', style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
            ..._accountManager.channels.map((c) => RadioListTile<ChannelInfo>(
              dense: true,
              title: Text(c.title, style: const TextStyle(color: Colors.white, fontSize: 13)),
              value: c,
              groupValue: ch,
              activeColor: Colors.green,
              onChanged: (v) {
                if (v != null) {
                  _accountManager.selectChannel(v);
                  Navigator.pop(context);
                }
              },
            )),
          ],

          const Spacer(),

          // Logout
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () async {
              await _accountManager.signOut();
              if (!context.mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => MainShell()),
                (_) => false,
              );
            },
          ),

          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Version 0.0.1', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _drawerItem(IconData icon, String title, int pageIndex) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      onTap: () {
        _pageCtrl.jumpToPage(pageIndex + 1);
        Navigator.pop(context);
      },
    );
  }

  Future<void> _showDestinationPicker() async {
    final current = await TelegramService.getDefaultDestination();
    final dest = await showDialog<UploadDestination>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Default Upload Destination', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _destRadio(ctx, UploadDestination.youtube, 'YouTube', current),
            _destRadio(ctx, UploadDestination.telegram, 'Telegram Saved Messages', current),
            _destRadio(ctx, UploadDestination.both, 'YouTube + Telegram', current),
          ],
        ),
      ),
    );
    if (dest != null && dest != current) {
      await TelegramService.setDefaultDestination(dest);
      setState(() {});
    }
  }

  Widget _destRadio(BuildContext ctx, UploadDestination dest, String label, UploadDestination current) {
    return RadioListTile<UploadDestination>(
      dense: true,
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      value: dest,
      groupValue: current,
      activeColor: Colors.green,
      onChanged: (v) {
        if (v != null) Navigator.pop(ctx, v);
      },
    );
  }
}
