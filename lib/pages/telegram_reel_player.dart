import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/telegram_service.dart';

class TelegramReelPlayer extends StatefulWidget {
  final TelegramService service;
  final List<SavedMessageItem> videos;
  final int initialIndex;

  const TelegramReelPlayer({
    Key? key,
    required this.service,
    required this.videos,
    this.initialIndex = 0,
  }) : super(key: key);

  @override
  State<TelegramReelPlayer> createState() => _TelegramReelPlayerState();
}

class _TelegramReelPlayerState extends State<TelegramReelPlayer> {
  late PageController _pageController;
  int _currentIndex = 0;
  bool _serverReady = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _initServer();
  }

  Future<void> _initServer() async {
    await widget.service.ensureStreamServer();
    if (mounted) setState(() => _serverReady = true);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (!_serverReady)
            const Center(child: CircularProgressIndicator(color: Colors.blue))
          else
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: widget.videos.length,
              onPageChanged: (i) => setState(() => _currentIndex = i),
              itemBuilder: (_, i) => _TelegramReelTile(
                key: ValueKey(widget.videos[i].id),
                service: widget.service,
                item: widget.videos[i],
                isActive: i == _currentIndex,
              ),
            ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _serverReady
                    ? Text(
                        '${_currentIndex + 1} / ${widget.videos.length}',
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TelegramReelTile extends StatefulWidget {
  final TelegramService service;
  final SavedMessageItem item;
  final bool isActive;

  const _TelegramReelTile({
    Key? key,
    required this.service,
    required this.item,
    required this.isActive,
  }) : super(key: key);

  @override
  State<_TelegramReelTile> createState() => _TelegramReelTileState();
}

class _TelegramReelTileState extends State<_TelegramReelTile> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _controlsVisible = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _initVideo();
  }

  @override
  void didUpdateWidget(_TelegramReelTile old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      _initVideo();
    } else if (!widget.isActive && old.isActive) {
      _disposeVideo();
    }
  }

  @override
  void dispose() {
    _disposeVideo();
    super.dispose();
  }

  Future<void> _initVideo() async {
    setState(() { _loading = true; _error = null; });
    final url = widget.service.streamUrlFor(widget.item);
    debugPrint('[ReelTile] url=$url');
    if (url == null) {
      if (mounted) setState(() { _loading = false; _error = 'Stream unavailable'; });
      return;
    }
    try {
      _controller = VideoPlayerController.networkUrl(Uri.parse(url));
      debugPrint('[ReelTile] initializing...');
      await _controller!.initialize();
      debugPrint('[ReelTile] initialized');
      if (!mounted) {
        _controller?.dispose();
        _controller = null;
        return;
      }
      _controller!.play();
      _controller!.setLooping(true);
      setState(() { _initialized = true; _loading = false; });
    } catch (e) {
      debugPrint('[ReelTile] error: $e');
      if (mounted) setState(() { _loading = false; _error = 'Failed: $e'; });
    }
  }

  void _disposeVideo() {
    _controller?.pause();
    _controller?.dispose();
    _controller = null;
    _initialized = false;
    _loading = false;
  }

  void _togglePlay() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
    setState(() => _controlsVisible = !_controlsVisible);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _togglePlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_error != null)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.white)),
                ],
              ),
            )
          else if (_loading)
            const Center(child: CircularProgressIndicator(color: Colors.blue))
          else if (_initialized && _controller != null)
            Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: _controller!.value.size.width,
                  height: _controller!.value.size.height,
                  child: VideoPlayer(_controller!),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          if (_controlsVisible && _initialized) ...[
            Container(color: Colors.black26),
            Center(
              child: Icon(
                _controller?.value.isPlaying == true
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                color: Colors.white,
                size: 64,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
