import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/upload_scheduler.dart';
import '../services/account_manager.dart';
import '../services/master_sync.dart';
import '../services/telegram_service.dart';

enum _ChartRange { week, month, year }

class StatsPage extends StatefulWidget {
  final UploadScheduler scheduler;
  final AccountManager accountManager;
  final MasterSync? masterSync;
  final TelegramService? telegramService;
  final VoidCallback? onSignOut;

  const StatsPage({
    Key? key,
    required this.scheduler,
    required this.accountManager,
    this.masterSync,
    this.telegramService,
    this.onSignOut,
  }) : super(key: key);

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  _ChartRange _chartRange = _ChartRange.week;
  int _recentPage = 0;
  int _historyFilter = 0;
  static const int _pageSize = 10;

  @override
  void initState() {
    super.initState();
    widget.masterSync?.addListener(_onDataChanged);
    // The Telegram account is resolved asynchronously (and again whenever
    // someone signs into a different number), so this page has to follow it
    // to keep "Telegram today" showing the right account's uploads.
    widget.telegramService?.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    widget.masterSync?.removeListener(_onDataChanged);
    widget.telegramService?.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) setState(() {});
  }

  void _showChannelPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Select Channel', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const Divider(color: Colors.grey, height: 1),
            ...widget.accountManager.channels.map((c) => ListTile(
              leading: const Icon(Icons.account_box, color: Colors.red),
              title: Text(c.title, style: const TextStyle(color: Colors.white)),
              trailing: c.id == widget.accountManager.selectedChannelId
                  ? const Icon(Icons.check, color: Colors.green)
                  : null,
              onTap: () {
                widget.accountManager.selectChannel(c);
                Navigator.pop(context);
              },
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(_ChartRange range, String label) {
    final selected = _chartRange == range;
    return GestureDetector(
      onTap: () => setState(() => _chartRange = range),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? Colors.green : Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
            style: TextStyle(color: selected ? Colors.white : Colors.grey[400], fontSize: 11, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildFilterChip2(int index, String label) {
    final selected = _historyFilter == index;
    return GestureDetector(
      onTap: () => setState(() {
        _historyFilter = index;
        _recentPage = 0;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? Colors.green : Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
            style: TextStyle(color: selected ? Colors.white : Colors.grey[400], fontSize: 11, fontWeight: FontWeight.w600)),
      ),
    );
  }

  String _channelName(String channelId) {
    final c = widget.accountManager.channels.where((ch) => ch.id == channelId).firstOrNull;
    return c?.title ?? channelId;
  }

  /// The app-wide switch that keeps every un-sent video and photo moving.
  /// Shown as an explicit ON/OFF rather than a bare toggle so the state is
  /// readable at a glance, with what it will do spelled out underneath — the
  /// behaviour (15 a day on YouTube, no cap on Telegram) is not something a
  /// switch can explain by itself.
  Widget _buildMasterSyncCard() {
    final sync = widget.masterSync;
    if (sync == null) return const SizedBox.shrink();
    final on = sync.enabled;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: on ? Colors.green.withValues(alpha: 0.5) : Colors.grey[800]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sync,
                  size: 20, color: on ? Colors.green : Colors.grey[600]),
              const SizedBox(width: 8),
              Text('Master Sync',
                  style: TextStyle(
                      color: Colors.grey[300],
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(on ? 'ON' : 'OFF',
                  style: TextStyle(
                      color: on ? Colors.green : Colors.grey[500],
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
              const SizedBox(width: 4),
              Switch(
                value: on,
                activeThumbColor: Colors.green,
                // Never disabled: a pass can run for minutes, and a switch
                // that refuses to move is a switch whose state the app then
                // restarts with. Turning it off mid-pass is supported — the
                // pass checks the flag between steps.
                onChanged: sync.setEnabled,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'While on, every category switched on below is queued '
            'automatically. Videos go to YouTube (15 a day, the rest '
            'rolls onto the next days) and to Telegram (no daily limit); '
            'photos and files go to Telegram.',
            style: TextStyle(color: Colors.grey[600], fontSize: 11),
          ),
          if (on) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (sync.running) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.green),
                  ),
                  const SizedBox(width: 8),
                  Text('Syncing…',
                      style:
                          TextStyle(color: Colors.grey[400], fontSize: 12)),
                ] else ...[
                  Icon(Icons.history, size: 14, color: Colors.grey[600]),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      sync.lastRun == null
                          ? 'Not synced yet'
                          : 'Last sync ${DateFormat('MMM d, HH:mm').format(sync.lastRun!)}',
                      style:
                          TextStyle(color: Colors.grey[500], fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
            if (sync.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(sync.lastError!,
                    style: TextStyle(color: Colors.red[300], fontSize: 11)),
              )
            else if (sync.lastYoutubeAdded > 0 ||
                sync.lastTelegramAdded > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Last pass queued ${sync.lastYoutubeAdded} for YouTube '
                  'and ${sync.lastTelegramAdded} for Telegram',
                  style:
                      TextStyle(color: Colors.grey[500], fontSize: 11),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// One on/off toggle per category — Telegram videos, Telegram photos,
  /// Telegram files and YouTube videos — because "has this gone up?" is
  /// always asked about one destination at a time.
  ///
  /// A category that is on is queued automatically by the master pass, and
  /// switching it on also runs that category straight away so the press has
  /// an immediate answer instead of waiting for the next tick. The line
  /// underneath reports what the last run actually did rather than leaving
  /// the user to guess whether anything happened.
  Widget _buildCategorySyncCard() {
    final sync = widget.masterSync;
    if (sync == null) return const SizedBox.shrink();

    final target = sync.lastSyncedTarget;
    final result = target == null ? null : sync.lastResultFor(target);
    final at = target == null ? null : sync.lastRunFor(target);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[800]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.playlist_add, size: 20, color: Colors.grey[400]),
              const SizedBox(width: 8),
              Text('Sync categories',
                  style: TextStyle(
                      color: Colors.grey[300],
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Turn a category on to queue everything not uploaded to that '
            'destination yet, oldest first. YouTube takes 15 a day and the '
            'rest is scheduled onto the following days; Telegram has no '
            'daily limit.',
            style: TextStyle(color: Colors.grey[600], fontSize: 11),
          ),
          const SizedBox(height: 12),
          _syncToggle(sync, SyncTarget.telegramVideos, Icons.videocam,
              Colors.blue),
          _syncToggle(sync, SyncTarget.telegramPhotos, Icons.image,
              Colors.blue),
          _syncToggle(sync, SyncTarget.telegramFiles,
              Icons.insert_drive_file, Colors.blue),
          _syncToggle(sync, SyncTarget.youtubeVideos, Icons.ondemand_video,
              Colors.red),
          if (result != null && target != null && at != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _syncStatusLine(target, result, at),
                style: TextStyle(
                    color: result.ok ? Colors.grey[500] : Colors.red[300],
                    fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  String _syncStatusLine(
      SyncTarget target, MasterSyncResult result, DateTime at) {
    final time = DateFormat('MMM d, HH:mm').format(at);
    if (!result.ok) {
      return '${target.label}: ${result.error} ($time)';
    }
    if (result.added == 0) {
      return result.skipped == 0
          ? '${target.label}: nothing to queue ($time)'
          : '${target.label}: all ${result.skipped} already uploaded ($time)';
    }
    return '${target.label}: queued ${result.added}'
        '${result.skipped > 0 ? ', ${result.skipped} already uploaded' : ''}'
        ' ($time)';
  }

  /// One row of the category card: the label, an explicit ON/OFF reading and
  /// the switch itself. Switching on kicks off that category immediately
  /// (unless a pass is already running, which the row shows as a spinner);
  /// switching off simply means the next automatic pass skips it.
  Widget _syncToggle(
      MasterSync sync, SyncTarget target, IconData icon, Color color) {
    final on = sync.targetEnabled(target);
    final busy = sync.runningTarget == target;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: on ? color.withValues(alpha: 0.45) : Colors.grey[800]!,
        ),
      ),
      child: Row(
        children: [
          busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 16, color: on ? color : Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(target.label,
                style: TextStyle(
                    color: on ? Colors.grey[200] : Colors.grey[600],
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          Text(on ? 'ON' : 'OFF',
              style: TextStyle(
                  color: on ? Colors.green : Colors.grey[600],
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
          Switch(
            value: on,
            activeThumbColor: color,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            // Same rule as the master switch: the state is saved either
            // way, so the toggle must work while another pass is running.
            onChanged: (value) async {
              await sync.setTargetEnabled(target, value);
              // Turning a category on is the old "sync now" button:
              // queue what is missing straight away instead of waiting
              // for the next automatic pass. One pass at a time, though —
              // while another is going, the next pass takes it on.
              if (value && !sync.running) await sync.syncTarget(target);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final acct = widget.accountManager.currentAccount;
    final ch = widget.accountManager.selectedChannel;
    final email = acct?.email;
    // Every number on this page answers for the account in view: the
    // signed-in Google account owns the YouTube channels, and the
    // signed-in Telegram number owns its own uploads. Jobs recorded before
    // the app knew who uploaded them carry no id and stay visible for the
    // account that is signed in now.
    final completed = widget.scheduler.completedJobs
        .where((j) => UploadScheduler.belongsToAccount(j, email))
        .toList();
    final failed = widget.scheduler.failedJobs
        .where((j) => UploadScheduler.belongsToAccount(j, email))
        .toList();

    // Compute chart stats based on selected range
    final chartData = <String, int>{};
    final today = DateTime.now();
    String label;

    // The chart follows the selected channel — the 15-a-day budget and the
    // history behind it are per channel, not per device.
    final channelCompleted = completed
        .where((j) => UploadScheduler.belongsToChannel(j, ch?.id))
        .toList();

    switch (_chartRange) {
      case _ChartRange.month:
        label = 'Last 30 Days';
        for (int w = 0; w < 4; w++) {
          int count = 0;
          for (int d = w * 7; d < (w + 1) * 7 && d < 30; d++) {
            final day = today.subtract(Duration(days: d));
            final dayStr = day.toIso8601String().substring(0, 10);
            count += channelCompleted.where((j) =>
              j.completedAt != null && j.completedAt!.toIso8601String().substring(0, 10) == dayStr
            ).length;
          }
          chartData['Week ${w + 1}'] = count;
        }
        break;
      case _ChartRange.year:
        label = 'Last Year';
        for (int m = 0; m < 12; m++) {
          final month = today.month - m;
          final year = today.year + (month <= 0 ? -1 : 0);
          final mClamped = month <= 0 ? month + 12 : month;
          int count = 0;
          for (final j in channelCompleted) {
            if (j.completedAt != null &&
                j.completedAt!.year == year &&
                j.completedAt!.month == mClamped) {
              count++;
            }
          }
          chartData[DateFormat('MMM').format(DateTime(2024, mClamped))] = count;
        }
        break;
      default:
        label = 'Last 7 Days';
        for (int i = 6; i >= 0; i--) {
          final day = today.subtract(Duration(days: i));
          final key = DateFormat('MM/dd').format(day);
          final dayStr = day.toIso8601String().substring(0, 10);
          final count = channelCompleted.where((j) =>
            j.completedAt != null && j.completedAt!.toIso8601String().substring(0, 10) == dayStr
          ).length;
          chartData[key] = count;
        }
    }
    int maxVal = 0;
    for (final v in chartData.values) {
      if (v > maxVal) maxVal = v;
    }

    final ytToday = widget.scheduler.todayYoutubeCountForChannel(ch?.id);
    final tgToday = widget.scheduler
        .todayTelegramCountForAccount(widget.telegramService?.accountKey);
    final queued = widget.scheduler.queuedCountForAccount(email);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Home')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          // Profile card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Stack(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              children: [
                Column(
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundImage: acct?.photoUrl != null ? NetworkImage(acct!.photoUrl!) : null,
                      child: acct?.photoUrl == null ? const Icon(Icons.person, size: 40) : null,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      acct?.displayName ?? 'User',
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      acct?.email ?? '',
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                    ),
                  ],
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    icon: const Icon(Icons.swap_horiz, color: Colors.orange, size: 24),
                    onPressed: () async {
                      await widget.accountManager.switchAccount();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildMasterSyncCard(),
          const SizedBox(height: 12),
          _buildCategorySyncCard(),
          const SizedBox(height: 12),
          if (widget.accountManager.channels.length > 1) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _showChannelPicker(context),
                icon: const Icon(Icons.swap_horiz, color: Colors.blue),
                label: Text(
                  ch != null ? 'Switch Channel (${ch.title})' : 'Select Channel',
                  style: const TextStyle(color: Colors.white),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.blueGrey),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Today's Uploads - YouTube
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.videocam, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Text("Today's Uploads", style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('$ytToday', style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    SizedBox(
                      width: 40, height: 40,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CircularProgressIndicator(
                            value: ytToday / UploadScheduler.youtubeDailyLimit,
                            backgroundColor: Colors.grey[800],
                            color: ytToday >= UploadScheduler.youtubeDailyLimit ? Colors.red : Colors.red,
                            strokeWidth: 4,
                          ),
                          Center(
                            child: Text(
                              '${(ytToday / UploadScheduler.youtubeDailyLimit * 100).toInt()}%',
                              style: TextStyle(color: Colors.grey[300], fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Text('/ ${UploadScheduler.youtubeDailyLimit} YouTube daily limit${ch != null ? ' (${ch.title})' : ''}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 11)),
              ],
            ),
          ),

          // Today's Uploads - Telegram
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.telegram, color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    Text("Telegram Today", style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Text('$tgToday', style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  widget.telegramService?.accountPhone != null
                      ? 'account ${widget.telegramService!.accountPhone}'
                      : 'signed-in Telegram account',
                  style: TextStyle(color: Colors.grey[600], fontSize: 11),
                ),
              ],
            ),
          ),

          // Total + Queue row
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.cloud_done, color: Colors.blue, size: 20),
                          const SizedBox(width: 8),
                          Text('Total', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('${completed.length}', style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('uploads', style: TextStyle(color: Colors.grey[600], fontSize: 11)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.queue, color: Colors.orange, size: 20),
                          const SizedBox(width: 8),
                          Text('In Queue', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$queued',
                        style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Failed
          if (failed.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red, size: 20),
                  const SizedBox(width: 8),
                  Text('Failed', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                  const Spacer(),
                  Text('${failed.length}', style: const TextStyle(color: Colors.red, fontSize: 22, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          const SizedBox(height: 24),

          // Chart
          Row(
            children: [
              Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              _buildFilterChip(_ChartRange.week, 'Week'),
              const SizedBox(width: 4),
              _buildFilterChip(_ChartRange.month, 'Month'),
              const SizedBox(width: 4),
              _buildFilterChip(_ChartRange.year, 'Year'),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(
              height: 120,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: chartData.entries.map((entry) {
                  final ratio = maxVal > 0 ? entry.value / maxVal : 0.0;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (entry.value > 0)
                            Text('${entry.value}',
                                style: TextStyle(color: Colors.grey[400], fontSize: 10)),
                          const SizedBox(height: 2),
                          Container(
                            height: ratio * 70,
                            decoration: BoxDecoration(
                              color: entry.value > 0 ? Colors.green : Colors.grey[800],
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(entry.key, style: TextStyle(color: Colors.grey[500], fontSize: 9)),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Scheduled by date
          if (widget.scheduler.scheduledByDateForChannel(ch?.id).isNotEmpty) ...[
            Text('Scheduled', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ...widget.scheduler.scheduledByDateForChannel(ch?.id).entries.map((entry) {
              final date = DateTime.tryParse(entry.key);
              final label = date != null ? DateFormat('MMM d, yyyy').format(date) : entry.key;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.schedule, color: Colors.blueGrey, size: 16),
                        const SizedBox(width: 6),
                        Text(label,
                            style: TextStyle(color: Colors.blueGrey[200], fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blueGrey[800],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('${entry.value.length}',
                              style: const TextStyle(color: Colors.white, fontSize: 10)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...entry.value.take(5).map((job) => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.video_file, color: Colors.white38, size: 14),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(job.displayName,
                                style: TextStyle(color: Colors.grey[400], fontSize: 11),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    )),
                    if (entry.value.length > 5)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('+${entry.value.length - 5} more',
                            style: TextStyle(color: Colors.grey[600], fontSize: 10)),
                      ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 24),
          ],

          // Upload history tabs
          Row(
            children: [
              Text('Recent Uploads', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              _buildFilterChip2(0, 'All'),
              const SizedBox(width: 4),
              _buildFilterChip2(1, 'YT'),
              const SizedBox(width: 4),
              _buildFilterChip2(2, 'TG'),
            ],
          ),
          const SizedBox(height: 8),
          () {
            final all = widget.scheduler.recentJobs
                .where((j) => UploadScheduler.belongsToAccount(j, email))
                .toList();
            final filtered = _historyFilter == 0
                ? all
                : _historyFilter == 1
                    ? all.where(widget.scheduler.isOnYoutube).toList()
                    : all.where((j) => widget.scheduler.isOnTelegram(j)).toList();
            final totalPages = filtered.isEmpty ? 1 : (filtered.length / _pageSize).ceil();
            final page = _recentPage.clamp(0, totalPages - 1);
            final items = filtered.skip(page * _pageSize).take(_pageSize).toList();

            if (items.isEmpty) {
              return Text('No uploads yet', style: TextStyle(color: Colors.grey[600], fontSize: 13));
            }

            return Column(
              children: [
                ...items.map((job) {
                  final dateFmt = DateFormat('MMM d, HH:mm');
                  IconData icon;
                  Color iconColor;
                  String dateText;
                  if (job.status == JobStatus.completed) {
                    icon = Icons.check_circle;
                    iconColor = Colors.green;
                    dateText = job.completedAt != null ? dateFmt.format(job.completedAt!) : '';
                  } else if (job.status == JobStatus.failed) {
                    icon = Icons.error;
                    iconColor = Colors.red;
                    dateText = '';
                  } else if (job.status == JobStatus.scheduled) {
                    icon = Icons.schedule;
                    iconColor = Colors.blueGrey;
                    dateText = job.scheduledDate != null ? dateFmt.format(job.scheduledDate!) : 'Scheduled';
                  } else {
                    icon = Icons.hourglass_empty;
                    iconColor = Colors.orange;
                    dateText = '';
                  }
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        border: Border(bottom: BorderSide(color: Colors.grey[800]!)),
                      ),
                      child: Row(
                        children: [
                          Icon(icon, color: iconColor, size: 16),
                          const SizedBox(width: 6),
                          if (widget.scheduler.isOnYoutube(job))
                            Container(
                              margin: const EdgeInsets.only(right: 3),
                              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                              decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(3)),
                              child: const Text('YT', style: TextStyle(color: Colors.white, fontSize: 7, fontWeight: FontWeight.bold)),
                            ),
                          if (widget.scheduler.isOnTelegram(job))
                            Container(
                              margin: const EdgeInsets.only(right: 3),
                              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                              decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(3)),
                              child: const Text('TG', style: TextStyle(color: Colors.white, fontSize: 7, fontWeight: FontWeight.bold)),
                            ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  job.channelId.isNotEmpty ? _channelName(job.channelId) : job.displayName,
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(job.displayName,
                                    style: TextStyle(color: Colors.grey[500], fontSize: 10),
                                    overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                          Text(dateText, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                        ],
                      ),
                    );
                }),
                if (totalPages > 1) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left, color: Colors.white70),
                        onPressed: _recentPage > 0
                            ? () => setState(() => _recentPage--)
                            : null,
                      ),
                      Text('${page + 1} / $totalPages',
                          style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, color: Colors.white70),
                        onPressed: page < totalPages - 1
                            ? () => setState(() => _recentPage++)
                            : null,
                      ),
                    ],
                  ),
                ],
              ],
            );
          }(),
          const SizedBox(height: 24),

          // Logout button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout, color: Colors.red),
              label: const Text('Logout', style: TextStyle(color: Colors.red)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Version
          Center(
            child: Text('Version 0.0.1', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
