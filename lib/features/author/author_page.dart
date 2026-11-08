import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/diag.dart';
import '../../core/error_text.dart';
import '../../core/platform_style.dart';
import '../../core/verify_gate.dart';
import '../../data/douyin_api.dart';
import '../../data/models.dart';
import '../player/player_page.dart';

/// 作者主页「TA的作品」：网格列表 + 触底分页 + 点开直接播放。
///
/// 作品列表来自 `/aweme/v1/web/aweme/post/`，分页游标用响应里的
/// `max_cursor`，`has_more=1` 才继续请求，避免空转。
class AuthorPage extends StatefulWidget {
  const AuthorPage({super.key, required this.api, required this.author});

  final DouyinApi api;
  final Author author;

  @override
  State<AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<AuthorPage> {
  final List<AwemeItem> _items = <AwemeItem>[];
  final Set<String> _seen = <String>{};
  final ScrollController _scroll = ScrollController();

  int _cursor = 0;
  bool _loading = false;
  bool _hasMore = true;
  bool _initial = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 320) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool allowVerifyRetry = true}) async {
    if (_loading || !_hasMore) return;
    final secUid = widget.author.secUid;
    if (secUid.isEmpty) {
      setState(() {
        _initial = false;
        _error = '接口没有返回该作者的 sec_uid，无法拉取主页作品';
      });
      return;
    }
    setState(() {
      _loading = true;
      if (_items.isEmpty) _initial = true;
      _error = null;
    });
    diag('author', '请求 sec_uid=$secUid cursor=$_cursor');
    try {
      final body =
          await widget.api.fetchUserPosts(secUid, maxCursor: _cursor, count: 20);
      var added = 0;
      for (final raw in asList(body['aweme_list'])) {
        final item = AwemeItem.fromJson(asMap(raw));
        if (item == null) continue;
        if (_seen.add(item.id)) {
          _items.add(item);
          added++;
        }
      }
      final hasMore = asInt(body['has_more']) == 1;
      final cursor = asInt(body['max_cursor']);
      diag('author',
          'sec_uid=$secUid cursor=$cursor hasMore=$hasMore +$added total=${_items.length}');
      if (!mounted) return;
      setState(() {
        _cursor = cursor;
        // 一页全是已见过的作品时直接停，防止同一游标反复请求。
        _hasMore = hasMore && added > 0;
        _initial = false;
      });
    } on DouyinException catch (e) {
      if (!mounted) return;
      if (e.needsVerify && allowVerifyRetry) {
        // 验证期间先把界面恢复成可操作状态，验证通过后自动重试这一页。
        setState(() {
          _loading = false;
          _initial = false;
          _error = null;
        });
        diag('author', '作者作品命中风控，等待用户验证');
        final ok = await VerifyGate.instance
            .waitForUser(widget.api, e, label: '加载作者作品');
        if (!mounted) return;
        if (ok) {
          await _load(allowVerifyRetry: false);
          return;
        }
        setState(() {
          _error = '需要验证但尚未完成：${VerifyGate.instance.message}';
          _initial = false;
        });
        return;
      }
      setState(() {
        _error = '拉取作者作品失败：${ErrorText.from(e)}';
        _initial = false;
      });
      diag('author', '失败: ${e.message} body=${e.body}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '拉取作者作品失败：${ErrorText.from(e)}';
        _initial = false;
      });
      diag('author', '异常: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openItem(int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        api: widget.api,
        items: List<AwemeItem>.from(_items),
        initialIndex: index,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Column(
        children: [
          _Header(
            author: widget.author,
            count: _items.length,
            status: _initial
                ? '正在加载 TA 的作品'
                : _items.isEmpty
                    ? '没有可播放的作品'
                    : '已加载 ${_items.length} 条作品',
            loading: _loading,
            onRefresh: () {
              setState(() {
                _items.clear();
                _seen.clear();
                _cursor = 0;
                _hasMore = true;
                _error = null;
              });
              unawaited(_load());
            },
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_initial && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 13)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                setState(() => _error = null);
                unawaited(_load());
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final width = MediaQuery.of(context).size.width;
    final columns = width > 1400 ? 5 : (width > 1000 ? 4 : 3);
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 16,
        crossAxisSpacing: 14,
        childAspectRatio: 0.58,
      ),
      itemCount: _items.length + (_hasMore || _loading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return _TailLoading(hasMore: _hasMore, loading: _loading, onRetry: _load);
        }
        return _AuthorVideoTile(
          item: _items[index],
          onTap: () => _openItem(index),
        );
      },
    );
  }
}

class _TailLoading extends StatelessWidget {
  const _TailLoading({
    required this.hasMore,
    required this.loading,
    required this.onRetry,
  });

  final bool hasMore;
  final bool loading;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: loading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: hasMore ? onRetry : null,
              child: Text(hasMore ? '加载更多' : '没有更多了',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF9A9A9A)),
            ),
          ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.author,
    required this.count,
    required this.status,
    required this.loading,
    required this.onRefresh,
  });

  final Author author;
  final int count;
  final String status;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Color(0xFF141414),
        border: Border(bottom: BorderSide(color: Color(0xFF242424))),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, size: 18, color: Color(0xFFCFCFCF)),
            tooltip: '返回',
          ),
          ClipOval(
            child: SizedBox(
              width: 34,
              height: 34,
              child: author.avatarUrl.isEmpty
                  ? const ColoredBox(color: Color(0xFF2A2A2A))
                  : CachedNetworkImage(
                      imageUrl: author.avatarUrl,
                      fit: BoxFit.cover,
                      memCacheWidth: 80,
                      errorWidget: (context, _, _) =>
                          const ColoredBox(color: Color(0xFF2A2A2A)),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            author.nickname,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              '$status · 共 $count 条',
              style: const TextStyle(color: Color(0xFF6F6F6F), fontSize: 12),
            ),
          ),
          SizedBox(
            width: 18,
            height: 18,
            child: loading
                ? const CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFF8A8A8A))
                : null,
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: loading ? null : onRefresh,
            icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFCFCFCF)),
            label: const Text('刷新',
                style: TextStyle(color: Color(0xFFCFCFCF), fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _AuthorVideoTile extends StatelessWidget {
  const _AuthorVideoTile({required this.item, required this.onTap});

  final AwemeItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: const Color(0xFF1E1E1E),
                      child: item.coverUrl.isEmpty
                          ? const Icon(Icons.movie_outlined,
                              color: Color(0xFF6C6C6C), size: 26)
                          : CachedNetworkImage(
                              imageUrl: item.coverUrl,
                              fit: BoxFit.cover,
                              memCacheWidth: 400,
                              fadeInDuration:
                                  const Duration(milliseconds: 200),
                              errorWidget: (context, _, _) => const Icon(
                                Icons.broken_image_outlined,
                                color: Color(0xFF6C6C6C),
                                size: 24,
                              ),
                            ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.play_arrow,
                                size: 11, color: Colors.white),
                            const SizedBox(width: 2),
                            Text(
                              item.isImage
                                  ? '图文'
                                  : formatDuration(item.durationMs),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              item.desc.isEmpty ? '无标题作品' : item.desc,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Color(0xFFE6E6E6), fontSize: 12.5, height: 1.35),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.favorite_border,
                    size: 12, color: Color(0xFF8A8A8A)),
                const SizedBox(width: 4),
                Text(formatCount(item.diggCount),
                    style: const TextStyle(
                        color: Color(0xFF8A8A8A), fontSize: 11)),
                const Spacer(),
                Text(_timeAgo(item.createTime),
                    style: const TextStyle(
                        color: Color(0xFF6F6F6F), fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(int createTime) {
    if (createTime <= 0) return '';
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(createTime * 1000));
    if (diff.inDays >= 30) return '${(diff.inDays / 30).floor()}个月前';
    if (diff.inDays >= 1) return '${diff.inDays}天前';
    if (diff.inHours >= 1) return '${diff.inHours}小时前';
    return math.max(1, diff.inMinutes).toString() + '分钟前';
  }
}
