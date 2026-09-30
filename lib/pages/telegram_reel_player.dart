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

  /// Bumped by every `_initVideo`, so an init that was superseded can tell
  /// that it must not touch the tile (or its controller) anymore.
  int _initSeq = 0;

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
    final seq = ++_initSeq;
    _disposeVideo();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final url = widget.service.streamUrlFor(widget.item);
    debugPrint('[ReelTile] url=$url');
    if (url == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Stream unavailable';
        });
      }
      return;
    }

    Object? lastError;
    // First shot normally succeeds; the second one covers the local stream
    // server hiccuping (or a stale file reference) during the very first
    // AVFoundation probe, which is what produced the CoreMedia failures.
    for (var attempt = 0; attempt < 2; attempt++) {
      VideoPlayerController? controller;
      try {
        if (attempt > 0) {
          await Future.delayed(const Duration(milliseconds: 300));
          if (!mounted || seq != _initSeq) return;
        }
        controller = VideoPlayerController.networkUrl(Uri.parse(url));
        _controller = controller;
        debugPrint('[ReelTile] initializing (attempt ${attempt + 1})...');
        await controller.initialize().timeout(const Duration(seconds: 30));
        debugPrint('[ReelTile] initialized');
        // `_disposeVideo()` owns disposal of anything published to
        // `_controller`; touching it here would double-dispose it.
        if (!mounted || seq != _initSeq || _controller != controller) return;
        if (controller.value.hasError) {
          throw StateError(
              controller.value.errorDescription ?? 'Playback error');
        }
        await controller.setLooping(true);
        await controller.play();
        if (!mounted || seq != _initSeq || _controller != controller) return;
        setState(() {
          _initialized = true;
          _loading = false;
        });
        return;
      } catch (e) {
        debugPrint('[ReelTile] error (attempt ${attempt + 1}): $e');
        lastError = e;
        if (controller != null && identical(_controller, controller)) {
          _controller = null;
          try {
            controller.pause();
          } catch (_) {}
          try {
            controller.dispose();
          } catch (_) {}
        }
        _initialized = false;
      }
    }

    if (mounted) {
      setState(() {
        _loading = false;
        _error = _friendlyPlaybackError(lastError);
      });
    }
  }

  String _friendlyPlaybackError(Object? e) {
    if (e == null) return 'Failed to play this video';
    final s = e.toString().toLowerCase();
    if (s.contains('coremedia') ||
        s.contains('avfoundation') ||
        s.contains('nsurlerrordomain') ||
        s.contains('operation couldn') ||
        s.contains('not correctly configured')) {
      return 'Could not read this video stream.\nTap Retry to reconnect.';
    }
    if (s.contains('file_reference')) {
      return 'Telegram expired this file reference.\nTap Retry to refresh it.';
    }
    return 'Failed to play: $e';
  }

  void _disposeVideo() {
    final controller = _controller;
    _controller = null;
    _initialized = false;
    _loading = false;
    _controlsVisible = false;
    if (controller == null) return;
    try {
      controller.pause();
    } catch (_) {}
    try {
      controller.dispose();
    } catch (_) {}
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !_initialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
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
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _initVideo,
                    icon: const Icon(Icons.refresh, color: Colors.white),
                    label: const Text('Retry',
                        style: TextStyle(color: Colors.white)),
                  ),
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
