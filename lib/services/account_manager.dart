import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ChannelInfo {
  final String id;
  final String title;
  final String? thumbnailUrl;

  ChannelInfo({required this.id, required this.title, this.thumbnailUrl});

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'thumbnailUrl': thumbnailUrl,
  };

  factory ChannelInfo.fromJson(Map<String, dynamic> json) => ChannelInfo(
    id: json['id'] as String,
    title: json['title'] as String,
    thumbnailUrl: json['thumbnailUrl'] as String?,
  );
}

class AccountManager extends ChangeNotifier {
  /// The channel picked by hand, remembered so per-channel statistics keep
  /// pointing at the same channel after a restart instead of quietly
  /// moving to whatever the account lists first.
  static const String _selectedChannelKey = 'selected_channel_id';

  final GoogleSignIn _googleSignIn;

  GoogleSignInAccount? _currentAccount;
  String? _accessToken;
  List<ChannelInfo> _channels = [];
  ChannelInfo? _selectedChannel;
  bool _loading = false;

  GoogleSignInAccount? get currentAccount => _currentAccount;
  String? get accessToken => _accessToken;
  List<ChannelInfo> get channels => _channels;
  ChannelInfo? get selectedChannel => _selectedChannel;
  String get selectedChannelId => _selectedChannel?.id ?? '';
  bool get loading => _loading;
  bool get isSignedIn => _currentAccount != null;

  AccountManager({required GoogleSignIn googleSignIn})
      : _googleSignIn = googleSignIn;

  Future<void> init() async {
    final account = await _googleSignIn.signInSilently();
    if (account != null) {
      _currentAccount = account;
      await _refreshAccessToken();
      await fetchChannels();
    }

    notifyListeners();
  }

  Future<void> _refreshAccessToken() async {
    if (_currentAccount == null) return;
    final auth = await _currentAccount!.authentication;
    _accessToken = auth.accessToken;
  }

  Future<void> signIn() async {
    _loading = true;
    notifyListeners();

    try {
      final account = await _googleSignIn.signIn();
      if (account != null) {
        _currentAccount = account;
        await _refreshAccessToken();
        await fetchChannels();
      }
    } catch (e) {
      debugPrint('Sign in failed: $e');
    }

    _loading = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _currentAccount = null;
    _accessToken = null;
    _channels = [];
    _selectedChannel = null;
    notifyListeners();
  }

  Future<void> switchAccount() async {
    await _googleSignIn.disconnect();
    _currentAccount = null;
    _accessToken = null;
    _channels = [];
    _selectedChannel = null;
    notifyListeners();
    await signIn();
  }

  Future<void> fetchChannels() async {
    if (_accessToken == null) return;

    try {
      final res = await http.get(
        Uri.parse('https://www.googleapis.com/youtube/v3/channels?mine=true&part=id,snippet'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        _channels = (data['items'] as List?)?.map<ChannelInfo>((item) => ChannelInfo(
          id: item['id'] as String,
          title: item['snippet']?['title'] as String? ?? 'Unknown',
          thumbnailUrl: item['snippet']?['thumbnails']?['default']?['url'] as String?,
        )).toList() ?? [];

        if (_channels.isNotEmpty && _selectedChannel == null) {
          await _restoreSelectedChannel();
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Failed to fetch channels: $e');
    }
  }

  /// Picks the remembered channel when this account still has it, and falls
  /// back to the first one otherwise — an id saved for another account can
  /// never select a channel that is not on screen.
  Future<void> _restoreSelectedChannel() async {
    String? saved;
    try {
      final prefs = await SharedPreferences.getInstance();
      saved = prefs.getString(_selectedChannelKey);
    } catch (e) {
      debugPrint('Could not read selected channel: $e');
    }
    if (_channels.isEmpty) return;
    _selectedChannel = saved == null
        ? null
        : _channels.where((c) => c.id == saved).firstOrNull;
    _selectedChannel ??= _channels.first;
  }

  Future<void> selectChannel(ChannelInfo channel) async {
    _selectedChannel = channel;
    notifyListeners();
    // Statistics are per channel, so the choice has to outlive the app.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedChannelKey, channel.id);
    } catch (e) {
      debugPrint('Could not persist selected channel: $e');
    }
  }
}
