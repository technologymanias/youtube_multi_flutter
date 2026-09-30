import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class VideoPlayerPage extends StatefulWidget {
  final String videoId;
  final String title;
  final String? thumbnailUrl;

  const VideoPlayerPage({
    Key? key,
    required this.videoId,
    required this.title,
    this.thumbnailUrl,
  }) : super(key: key);

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  bool _loading = true;
  bool _showSignIn = false;
  InAppWebViewController? _controller;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // Check if YouTube cookies already exist in the persistent WKWebView store
    final cs = await CookieManager.instance().getCookies(
      url: WebUri('https://www.youtube.com'),
    );
    final signedIn = cs.any(
      (c) => c.name == 'LOGIN_INFO' || c.name.contains('SID'),
    );
    if (mounted) {
      if (signedIn) {
        setState(() {
          _showSignIn = false;
          _loading = true;
        });
      } else {
        setState(() => _showSignIn = true);
      }
    }
  }

  Future<void> _onSignInDetected() async {
    // WKWebView persists cookies automatically — no manual save needed
    // Just navigate to the video
    if (mounted) {
      setState(() {
        _showSignIn = false;
        _loading = true;
      });
      await _controller?.loadUrl(
        urlRequest: URLRequest(
          url: WebUri('https://www.youtube.com/shorts/${widget.videoId}'),
        ),
      );
    }
  }

  Future<void> _pollCookies() async {
    for (int i = 0; i < 60; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      try {
        final cs = await CookieManager.instance().getCookies(
          url: WebUri('https://www.youtube.com'),
        );
        if (cs.any((c) => c.name == 'LOGIN_INFO' || c.name.contains('SID'))) {
          await _onSignInDetected();
          return;
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _showSignIn
          ? AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(widget.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            )
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(widget.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              bottom: _loading
                  ? const PreferredSize(
                      preferredSize: Size.fromHeight(2),
                      child: LinearProgressIndicator(),
                    )
                  : null,
            ),
      body: _showSignIn ? _buildSignIn() : _buildPlayer(),
    );
  }

  Widget _buildSignIn() {
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri('https://www.youtube.com'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useWideViewPort: true,
          ),
          onWebViewCreated: (c) {
            _controller = c;
            _pollCookies();
          },
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Material(
            color: Colors.black87,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      color: Colors.orange, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Sign in to YouTube here.\nThis is a one-time step.',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayer() {
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(
          url: WebUri('https://www.youtube.com/shorts/${widget.videoId}'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            allowsInlineMediaPlayback: true,
            mediaPlaybackRequiresUserGesture: false,
            useWideViewPort: true,
          ),
          onLoadStop: (_, __) {
            if (mounted) setState(() => _loading = false);
          },
        ),
        if (_loading)
          Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.videoId.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        'https://img.youtube.com/vi/${widget.videoId}/maxresdefault.jpg',
                        height: 200, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Image.network(
                          'https://img.youtube.com/vi/${widget.videoId}/hqdefault.jpg',
                          height: 200, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox(height: 200),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text('Loading video...',
                      style:
                          TextStyle(color: Colors.grey[400], fontSize: 13)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
