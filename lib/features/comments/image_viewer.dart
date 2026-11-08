import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';

Future<void> showCommentImageViewer(
  BuildContext context,
  List<CommentImage> images,
  int initialIndex,
) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (context) => _ImageViewer(images: images, initialIndex: initialIndex),
  );
}

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.images, required this.initialIndex});

  final List<CommentImage> images;
  final int initialIndex;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late int _index = widget.initialIndex;
  late final PageController _page = PageController(initialPage: widget.initialIndex);

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          PageView.builder(
            controller: _page,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, index) {
              final image = widget.images[index];
              return InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: image.url,
                    fit: BoxFit.contain,
                    placeholder: (context, url) => const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    errorWidget: (context, url, error) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 48,
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            top: 14,
            right: 14,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: Colors.white, size: 22),
              tooltip: '关闭',
            ),
          ),
          if (widget.images.length > 1)
            Positioned(
              bottom: 18,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_index + 1} / ${widget.images.length}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
