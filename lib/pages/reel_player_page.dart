import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

class ReelPlayerPage extends StatefulWidget {
  final List<AssetEntity> videos;
  final int initialIndex;

  const ReelPlayerPage({
    Key? key,
    required this.videos,
    this.initialIndex = 0,
  }) : super(key: key);

  @override
  State<ReelPlayerPage> createState() => _ReelPlayerPageState();
}

class _ReelPlayerPageState extends State<ReelPlayerPage> {
  late PageController _pageController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
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
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: widget.videos.length,
            onPageChanged: (i) => setState(() => _currentIndex = i),
            itemBuilder: (_, i) => _ReelVideoTile(
              key: ValueKey(widget.videos[i].id),
              entity: widget.videos[i],
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
                child: Text(
                  '${_currentIndex + 1} / ${widget.videos.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReelVideoTile extends StatefulWidget {
  final AssetEntity entity;
  final bool isActive;

  const _ReelVideoTile({Key? key, required this.entity, required this.isActive})
      : super(key: key);

  @override
  State<_ReelVideoTile> createState() => _ReelVideoTileState();
}

class _ReelVideoTileState extends State<_ReelVideoTile> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _controlsVisible = false;
  bool _loading = false;
  String? _error;

  /// Bumped by every `_initVideo`, so an init that was superseded (swiped
  /// away and back, or retried) can tell that it must not touch state anymore.
  int _initSeq = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _initVideo();
  }

  @override
  void didUpdateWidget(_ReelVideoTile old) {
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

    VideoPlayerController? controller;
    try {
      final file = await widget.entity.file;
      if (file == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'File is not available';
          });
        }
        return;
      }
      // Superseded while the file handle was resolving — no controller has
      // been published yet, so there is nothing to clean up.
      if (!mounted || !widget.isActive || seq != _initSeq) return;

      controller = VideoPlayerController.file(file);
      _controller = controller;
      await controller.initialize().timeout(const Duration(seconds: 30));

      // Everything that clears or replaces `_controller` goes through
      // `_disposeVideo()`, which has already disposed this instance. Touching
      // it again would double-dispose a ChangeNotifier.
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
    } catch (e) {
      debugPrint('[ReelPlayer] init failed: $e');
      if (controller != null && identical(_controller, controller)) {
        _disposeVideo();
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _initialized = false;
          _error = 'Cannot play this video';
        });
      }
    }
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
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  if (_loading) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Loading…',
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
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
