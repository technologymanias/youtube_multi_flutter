import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

/// Full-screen viewer for local gallery photos, the same experience the
/// Telegram photos get: horizontal swipe between stills, a close button and
/// an "n / total" pill. Opens regardless of the tile's queue/YT/TG state.
class LocalPhotoViewer extends StatefulWidget {
  final List<AssetEntity> photos;
  final int initialIndex;

  const LocalPhotoViewer({
    Key? key,
    required this.photos,
    this.initialIndex = 0,
  }) : super(key: key);

  @override
  State<LocalPhotoViewer> createState() => _LocalPhotoViewerState();
}

class _LocalPhotoViewerState extends State<LocalPhotoViewer> {
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
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.horizontal,
            itemCount: widget.photos.length,
            onPageChanged: (i) => setState(() => _currentIndex = i),
            itemBuilder: (_, i) => _LocalPhotoTile(
              key: ValueKey(widget.photos[i].id),
              asset: widget.photos[i],
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${_currentIndex + 1} / ${widget.photos.length}',
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

/// One full-screen photo: the original file once it decodes, with the
/// thumbnail standing in while it loads and as the fallback if the file is
/// gone (deleted from the gallery while the viewer was open).
class _LocalPhotoTile extends StatefulWidget {
  final AssetEntity asset;

  const _LocalPhotoTile({
    Key? key,
    required this.asset,
  }) : super(key: key);

  @override
  State<_LocalPhotoTile> createState() => _LocalPhotoTileState();
}

class _LocalPhotoTileState extends State<_LocalPhotoTile> {
  Future<File?>? _fileFuture;
  Future<Uint8List?>? _thumbFuture;

  /// The fast stand-in shown until the full-resolution image has a frame,
  /// so paging never lands on a black rectangle.
  Widget _thumbPlaceholder() {
    _thumbFuture ??=
        widget.asset.thumbnailDataWithSize(const ThumbnailSize(1080, 1080));
    return FutureBuilder<Uint8List?>(
      future: _thumbFuture,
      builder: (_, snap) {
        if (snap.hasData && snap.data != null) {
          return Image.memory(
            snap.data!,
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
          );
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
    _fileFuture ??= widget.asset.file;
    return FutureBuilder<File?>(
      future: _fileFuture,
      builder: (_, snap) {
        final file = snap.data;
        if (snap.connectionState != ConnectionState.done ||
            file == null ||
            !file.existsSync()) {
          return _thumbPlaceholder();
        }
        return Image.file(
          file,
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
          frameBuilder: (context, child, frame, wasSyncLoaded) =>
              (wasSyncLoaded || frame != null)
                  ? child
                  : _thumbPlaceholder(),
          errorBuilder: (_, __, ___) => _thumbPlaceholder(),
        );
      },
    );
  }
}
