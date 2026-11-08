import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/platform_style.dart';
import '../../data/models.dart';

class VideoCard extends StatefulWidget {
  const VideoCard({super.key, required this.item, required this.onTap});

  final AwemeItem item;
  final VoidCallback onTap;

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 116,
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFF262626) : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovered ? const Color(0xFF4A4A4A) : const Color(0xFF303030),
            ),
            boxShadow: _hovered
                ? const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.all(5),
          child: Row(
            children: [
              _Cover(item: item),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.desc.isEmpty ? '无标题作品' : item.desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 13.5,
                          height: 1.45,
                          color: const Color(0xFFEDEDED),
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          _Avatar(url: item.author.avatarUrl),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              item.author.nickname,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFFBDBDBD),
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          const Spacer(),
                          _Metric(
                            icon: Icons.favorite_border,
                            value: formatCount(item.diggCount),
                          ),
                          const SizedBox(width: 14),
                          _Metric(
                            icon: Icons.chat_bubble_outline,
                            value: formatCount(item.commentCount),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.item});

  final AwemeItem item;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        width: 194,
        height: 106,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: const Color(0xFF2A2A2A),
              child: item.coverUrl.isEmpty
                  ? const Icon(Icons.movie_outlined, color: Color(0xFF6C6C6C), size: 28)
                  : CachedNetworkImage(
                      imageUrl: item.coverUrl,
                      fit: BoxFit.cover,
                      // 限制解码尺寸：封面只有 194x106，按 2x 解码即可，
                      // 否则 1080x1920 的原图会按张吃掉 8MB 内存。
                      memCacheWidth: 400,
                      maxWidthDiskCache: 480,
                      fadeInDuration: const Duration(milliseconds: 220),
                      placeholder: (context, url) =>
                          const ColoredBox(color: Color(0xFF2A2A2A)),
                      errorWidget: (context, url, error) => const Icon(
                        Icons.broken_image_outlined,
                        color: Color(0xFF6C6C6C),
                        size: 24,
                      ),
                    ),
            ),
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  item.isImage ? '图文' : formatDuration(item.durationMs),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: SizedBox(
        width: 20,
        height: 20,
        child: url.isEmpty
            ? const ColoredBox(color: Color(0xFF3A3A3A))
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 60,
                errorWidget: (context, _, _) =>
                    const ColoredBox(color: Color(0xFF3A3A3A)),
              ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: const Color(0xFF9A9A9A)),
        const SizedBox(width: 4),
        Text(
          value,
          style: const TextStyle(color: Color(0xFF9A9A9A), fontSize: 11.5),
        ),
      ],
    );
  }
}
