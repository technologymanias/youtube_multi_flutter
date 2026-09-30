import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/telegram_service.dart';

class TelegramPhotoViewer extends StatefulWidget {
  final TelegramService service;
  final List<SavedMessageItem> photos;
  final int initialIndex;

  const TelegramPhotoViewer({
    Key? key,
    required this.service,
    required this.photos,
    this.initialIndex = 0,
  }) : super(key: key);

  @override
  State<TelegramPhotoViewer> createState() => _TelegramPhotoViewerState();
}

class _TelegramPhotoViewerState extends State<TelegramPhotoViewer> {
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
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (!_serverReady)
            const Center(child: CircularProgressIndicator(color: Colors.blue))
          else
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.horizontal,
              itemCount: widget.photos.length,
              onPageChanged: (i) => setState(() => _currentIndex = i),
              itemBuilder: (_, i) => _PhotoTile(
                key: ValueKey(widget.photos[i].id),
                service: widget.service,
                item: widget.photos[i],
              ),
            ),
          Positioned(
            top: top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Positioned(
            top: top + 8,
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
                        '${_currentIndex + 1} / ${widget.photos.length}',
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

class _PhotoTile extends StatefulWidget {
  final TelegramService service;
  final SavedMessageItem item;

  const _PhotoTile({
    Key? key,
    required this.service,
    required this.item,
  }) : super(key: key);

  @override
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> {
  Future<Uint8List?>? _thumbFuture;

  Widget _thumbFallback() {
    _thumbFuture ??= widget.service.getThumbnail(widget.item);
    return FutureBuilder<Uint8List?>(
      future: _thumbFuture,
      builder: (_, snap) {
        if (snap.hasData && snap.data != null) {
          return Image.memory(snap.data!, fit: BoxFit.contain);
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.blue),
          );
        }
        return const Center(
          child: Icon(Icons.broken_image, size: 48, color: Colors.white38),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final url = widget.service.streamUrlFor(item);
    if (url == null || item.fileSize == null) return _thumbFallback();

    return Image.network(
      url,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
        return const Center(
          child: CircularProgressIndicator(color: Colors.blue),
        );
      },
      errorBuilder: (_, __, ___) => _thumbFallback(),
    );
  }
}
