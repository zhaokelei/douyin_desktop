import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/diag.dart';
import '../../core/error_text.dart';
import '../../core/ime_guard.dart';
import '../../core/platform_style.dart';
import '../../core/verify_gate.dart';
import '../../data/douyin_api.dart';
import '../../data/models.dart';
import 'image_viewer.dart';

/// 评论抽屉 tab 索引（顺序与网页版一致）。播放页用它记住用户停留的位置：
/// 按 X 切回评论、换视频后仍停在同一个 tab。
const int kDrawerTabAuthor = 1;
const int kDrawerTabComments = 2;

/// 评论抽屉控制器：播放页用它读当前 tab，并在按 X 时切回「评论」。
/// 比 GlobalKey 更轻：抽屉本身带 ValueKey(视频 id)，换视频要重建，
/// 用 GlobalKey 会把上一条视频的评论状态一起搬过来。
class CommentPanelController extends ChangeNotifier {
  TabController? _tabController;

  int get tab => _tabController?.index ?? kDrawerTabComments;
  bool get isCommentTab => tab == kDrawerTabComments;

  void _attach(TabController controller) => _tabController = controller;

  void _detach(TabController controller) {
    if (identical(_tabController, controller)) _tabController = null;
  }

  void goToCommentsTab() {
    final controller = _tabController;
    if (controller != null && controller.index != kDrawerTabComments) {
      controller.animateTo(kDrawerTabComments);
    }
  }
}

/// 点「TA的作品」里的作品，或点「播放 TA 的全部作品」时回调。
///
/// [posts] 是抽屉里已经拉到的作品（可能有多页），[index] 是起播下标；
/// [secUid] / [maxCursor] / [hasMore] 让播放页能接着这个作者继续分页，
/// 上下切换时始终在这个作者的作品里走，不回到推荐流。
typedef PlayAuthorPosts = void Function(
  List<AwemeItem> posts,
  int index,
  String secUid,
  int maxCursor,
  bool hasMore,
);

/// 右侧评论抽屉：顶部 6 个 tab、评论列表（真实数据）、底部输入框骨架。
///
/// 「详情」「评论」「TA的作品」接真实数据，其余 tab 只保留结构并标注"未接入"。
class CommentPanel extends StatefulWidget {
  const CommentPanel({
    super.key,
    required this.api,
    required this.awemeId,
    required this.item,
    required this.onClose,
    this.initialTab = kDrawerTabComments,
    this.controller,
    this.onTabChanged,
    this.onOpenAuthor,
    this.onPlayAuthorPosts,
    this.onRequestLogin,
  });

  final DouyinApi api;
  final String awemeId;
  final AwemeItem item;
  final VoidCallback onClose;

  /// 初始 tab（换视频时保留上次停留的位置，默认评论）。
  final int initialTab;

  /// 播放页提供的控制器，用于 X 键切回评论。
  final CommentPanelController? controller;

  /// tab 切换上报，播放页据此记住位置。
  final ValueChanged<int>? onTabChanged;

  /// 打开全屏作者主页（次级入口）。
  final VoidCallback? onOpenAuthor;

  /// 直接播放当前作者的作品列表。
  final PlayAuthorPosts? onPlayAuthorPosts;

  /// 未登录时点"发送"调用，由播放页跳转到登录页；为空时只提示。
  final VoidCallback? onRequestLogin;

  @override
  State<CommentPanel> createState() => CommentPanelState();
}

class CommentPanelState extends State<CommentPanel>
    with SingleTickerProviderStateMixin {
  static const _tabs = ['详情', 'TA的作品', '评论', '合集', 'AI 抖音', '相关推荐'];

  late final TabController _tabController;
  final List<CommentItem> _items = [];
  final Set<String> _seen = {};
  final ScrollController _scroll = ScrollController();

  int _activeTab = kDrawerTabComments;
  bool _loading = false;
  bool _hasMore = true;
  int _total = 0;
  int _cursor = 0;
  String? _error;

  /// 播放页按 X 时判断"已经停在评论 tab 了吗"。
  bool get isCommentTab => _tabController.index == kDrawerTabComments;

  /// 播放页按 X 时，若抽屉停在别的 tab，先切回评论而不是直接关掉。
  void goToCommentsTab() {
    if (isCommentTab) return;
    _tabController.animateTo(kDrawerTabComments);
  }

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab.clamp(0, _tabs.length - 1);
    _tabController = TabController(
        length: _tabs.length, vsync: this, initialIndex: _activeTab);
    _tabController.addListener(_onTabChanged);
    widget.controller?._attach(_tabController);
    _scroll.addListener(_onScroll);
    _loadMore();
  }

  void _onTabChanged() {
    final index = _tabController.index;
    if (index == _activeTab) return;
    if (mounted) setState(() => _activeTab = index);
    widget.onTabChanged?.call(index);
  }

  Future<void> _loadMore({bool allowVerifyRetry = true}) async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.fetchComments(
        widget.awemeId,
        cursor: _cursor,
        count: 20,
      );
      final raw = res['comments'];
      final parsed = <CommentItem>[];
      if (raw is List) {
        for (final node in raw) {
          final item = CommentItem.fromJson(asMap(node));
          if (item != null) parsed.add(item);
        }
      }
      if (!mounted) return;
      setState(() {
        for (final item in parsed) {
          if (_seen.add(item.cid)) _items.add(item);
        }
        _hasMore = (res['has_more'] as num?)?.toInt() == 1;
        _total = (res['total'] as num?)?.toInt() ?? _total;
        _cursor = (res['cursor'] as num?)?.toInt() ?? (_cursor + 20);
      });
    } on DouyinException catch (e) {
      if (!mounted) return;
      if (e.needsVerify && allowVerifyRetry) {
        setState(() => _loading = false);
        diag('comment', '加载评论命中风控，等待用户验证');
        final ok = await VerifyGate.instance
            .waitForUser(widget.api, e, label: '加载评论');
        if (!mounted) return;
        if (ok) {
          await _loadMore(allowVerifyRetry: false);
          return;
        }
        setState(() => _error = '需要验证但尚未完成：${VerifyGate.instance.message}');
        return;
      }
      setState(() => _error = _describeError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _describeError(Object e) {
    if (e is DouyinException && (e.body ?? '').isEmpty) {
      return '服务端返回空响应（通常是游客态风控）。\n'
          '解决办法：把浏览器导出的 douyin_cookies.json 放到程序目录后重启。';
    }
    // 统一走中文翻译层，界面上不再出现英文原文。
    return ErrorText.from(e);
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 160) {
      _loadMore();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    widget.controller?._detach(_tabController);
    _tabController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF161616),
        border: Border(left: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: Column(
        children: [
          _HeaderBar(onClose: widget.onClose),
          _Tabs(controller: _tabController),
          const Divider(height: 1, color: Color(0xFF262626)),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _DetailTab(item: widget.item),
                _AuthorWorksTab(
                  api: widget.api,
                  author: widget.item.author,
                  awemeId: widget.awemeId,
                  active: _activeTab == kDrawerTabAuthor,
                  onPlay: widget.onPlayAuthorPosts,
                  onOpenAuthor: widget.onOpenAuthor,
                ),
                _buildComments(),
                _SkeletonTab(text: '合集列表（未接入）'),
                _SkeletonTab(text: 'AI 抖音（未接入）'),
                _SkeletonTab(text: '相关推荐（未接入）'),
              ],
            ),
          ),
          _CommentComposer(
            api: widget.api,
            awemeId: widget.awemeId,
            onPosted: _onCommentPosted,
            onRequestLogin: widget.onRequestLogin,
            // 验证后"上次评论可能已生效"时，由面板负责重新拉第一页确认。
            onRefreshNeeded: () => unawaited(_reloadComments()),
          ),
        ],
      ),
    );
  }

  /// 发表成功后把新评论插到列表顶部（服务端本次返回的 comment 对象即可解析）。
  void _onCommentPosted(Map<String, dynamic> json) {
    final parsed = CommentItem.fromJson(asMap(json['comment']));
    if (!mounted) return;
    setState(() {
      _total += 1;
      if (parsed != null) {
        _items.insert(0, parsed);
        _seen.add(parsed.cid);
      }
    });
    diag('comment', '发布成功并插入列表 cid=${parsed?.cid}');
  }

  /// 清空并重新拉第一页评论（验证后核对"上次是否已发出"用）。
  Future<void> _reloadComments() async {
    if (!mounted) return;
    setState(() {
      _items.clear();
      _seen.clear();
      _cursor = 0;
      _total = 0;
      _hasMore = true;
    });
    await _loadMore(allowVerifyRetry: false);
  }

  Widget _buildComments() {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Text(
            _total > 0 ? '全部评论($_total)' : '全部评论',
            style: const TextStyle(
                color: Color(0xFFE8E8E8),
                fontSize: 13,
                fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          const Text('按热度',
              style: TextStyle(color: Color(0xFF8C8C8C), fontSize: 11.5)),
          const Icon(Icons.expand_more, size: 14, color: Color(0xFF8C8C8C)),
        ],
      ),
    );

    if (_items.isEmpty) {
      return Column(
        children: [
          header,
          Expanded(child: _buildEmpty()),
        ],
      );
    }

    return Column(
      children: [
        header,
        Expanded(
          child: ListView.separated(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            itemCount: _items.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 16),
            itemBuilder: (context, index) {
              if (index == _items.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: _loading
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF8A8A8A)),
                          )
                        : Text(
                            _error ?? (_hasMore ? '继续下滑加载更多评论' : '没有更多评论了'),
                            style: const TextStyle(
                                color: Color(0xFF6E6E6E), fontSize: 11.5),
                          ),
                  ),
                );
              }
              return _CommentTile(
                item: _items[index],
                api: widget.api,
                awemeId: widget.awemeId,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFF8A8A8A)),
              )
            else
              Icon(
                _error == null
                    ? Icons.chat_bubble_outline
                    : Icons.error_outline,
                size: 24,
                color: _error == null
                    ? const Color(0xFF7A7A7A)
                    : const Color(0xFFFF6B6B),
              ),
            const SizedBox(height: 14),
            Text(
              _loading ? '正在请求评论…' : (_error ?? '这条作品暂时没有评论'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(0xFF9A9A9A), fontSize: 12, height: 1.6),
            ),
            if (!_loading) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _loadMore, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeaderBar extends StatelessWidget {
  const _HeaderBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          const SizedBox(width: 16),
          const Text(
            '评论',
            style: TextStyle(
                color: Color(0xFFEDEDED),
                fontSize: 14,
                fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18, color: Color(0xFF9A9A9A)),
            tooltip: '关闭抽屉 (Esc)',
          ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.controller});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.label,
        indicator: const UnderlineTabIndicator(
          borderSide: BorderSide(width: 2, color: Color(0xFFF2F2F2)),
          insets: EdgeInsets.symmetric(horizontal: 2),
        ),
        labelColor: Color(0xFFF2F2F2),
        unselectedLabelColor: Color(0xFF7E7E7E),
        labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 12.5),
        tabs: const [
          Tab(text: '详情'),
          Tab(text: 'TA的作品'),
          Tab(text: '评论'),
          Tab(text: '合集'),
          Tab(text: 'AI 抖音'),
          Tab(text: '相关推荐'),
        ],
      ),
    );
  }
}

class _DetailTab extends StatelessWidget {
  const _DetailTab({required this.item});

  final AwemeItem item;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipOval(
              child: SizedBox(
                width: 38,
                height: 38,
                child: item.author.avatarUrl.isEmpty
                    ? const ColoredBox(color: Color(0xFF333333))
                    : CachedNetworkImage(
                        imageUrl: item.author.avatarUrl,
                        fit: BoxFit.cover,
                        memCacheWidth: 72,
                        errorWidget: (_, _, _) =>
                            const ColoredBox(color: Color(0xFF333333)),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.author.nickname,
                    style: const TextStyle(
                        color: Color(0xFFEDEDED),
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '发布于 ${formatTimeAgo(item.createTime)}',
                    style: const TextStyle(
                        color: Color(0xFF858585), fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (item.desc.isNotEmpty)
          Text(
            item.desc,
            style: const TextStyle(
                color: Color(0xFFE0E0E0), fontSize: 13, height: 1.6),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 18,
          runSpacing: 8,
          children: [
            _Stat(label: '点赞', value: formatCount(item.diggCount)),
            _Stat(label: '评论', value: formatCount(item.commentCount)),
            _Stat(label: '收藏', value: formatCount(item.collectCount)),
            _Stat(label: '分享', value: formatCount(item.shareCount)),
            if (item.playCount > 0)
              _Stat(label: '播放', value: formatCount(item.playCount)),
          ],
        ),
        if (item.musicTitle.isNotEmpty) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.music_note,
                  size: 14, color: Color(0xFF9A9A9A)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.musicTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Color(0xFF9A9A9A), fontSize: 11.5),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: const TextStyle(
                color: Color(0xFFEDEDED),
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(label,
            style:
                const TextStyle(color: Color(0xFF858585), fontSize: 11)),
      ],
    );
  }
}

/// 「TA的作品」tab：点进来就自动拉取当前视频作者的作品，网格 + 触底分页。
///
/// 点单个作品 / 点「播放 TA 的全部作品」都把该作者的作品列表交给播放页
/// 当播放队列起播，不再只是打开一个浏览页（与网页版「查看」的区别）。
class _AuthorWorksTab extends StatefulWidget {
  const _AuthorWorksTab({
    required this.api,
    required this.author,
    required this.awemeId,
    required this.active,
    this.onPlay,
    this.onOpenAuthor,
  });

  final DouyinApi api;
  final Author author;
  final String awemeId;
  final bool active;
  final PlayAuthorPosts? onPlay;
  final VoidCallback? onOpenAuthor;

  @override
  State<_AuthorWorksTab> createState() => _AuthorWorksTabState();
}

class _AuthorWorksTabState extends State<_AuthorWorksTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final List<AwemeItem> _items = <AwemeItem>[];
  final Set<String> _seen = <String>{};
  final ScrollController _scroll = ScrollController();

  int _cursor = 0;
  bool _loading = false;
  bool _hasMore = true;
  bool _initial = true;
  bool _requested = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  @override
  void didUpdateWidget(covariant _AuthorWorksTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换视频 / 换作者后按新作者重新拉，不能留着上一位作者的列表。
    if (oldWidget.author.secUid != widget.author.secUid ||
        oldWidget.awemeId != widget.awemeId) {
      _reset();
    }
    if (widget.active && !_requested) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reset() {
    _items.clear();
    _seen.clear();
    _cursor = 0;
    _hasMore = true;
    _initial = true;
    _error = null;
    _requested = false;
  }

  /// 只有用户真的点到「TA的作品」才发请求，避免一开评论抽屉就多打一次接口；
  /// 换视频时若抽屉正好停在这个 tab，也会自动重新拉取新作者的作品。
  void _maybeStart() {
    if (!mounted || !widget.active || _requested) return;
    _requested = true;
    if (widget.author.secUid.isEmpty) {
      setState(() {
        _initial = false;
        _error = '接口没有返回该作者的主页 ID，暂时无法拉取作品';
      });
      return;
    }
    unawaited(_load());
  }

  Future<void> _load({bool allowVerifyRetry = true}) async {
    if (_loading || !_hasMore) return;
    final secUid = widget.author.secUid;
    if (secUid.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    diag('author-tab', '请求 sec_uid=$secUid cursor=$_cursor');
    try {
      final body =
          await widget.api.fetchUserPosts(secUid, maxCursor: _cursor, count: 18);
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
      if (!mounted) return;
      setState(() {
        _cursor = cursor;
        // 一页全是重复作品时直接停，防止同一游标反复请求。
        _hasMore = hasMore && added > 0;
        _initial = false;
      });
      diag('author-tab',
          'sec_uid=$secUid cursor=$cursor hasMore=$_hasMore +$added total=${_items.length}');
    } on DouyinException catch (e) {
      if (!mounted) return;
      if (e.needsVerify && allowVerifyRetry) {
        setState(() {
          _loading = false;
          _initial = false;
          _error = null;
        });
        diag('author-tab', '作者作品命中风控，等待用户验证');
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
      diag('author-tab', '失败: ${e.message} body=${e.body}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '拉取作者作品失败：${ErrorText.from(e)}';
        _initial = false;
      });
      diag('author-tab', '异常: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 260) {
      unawaited(_load());
    }
  }

  void _playAt(int index) {
    if (_items.isEmpty) return;
    widget.onPlay?.call(
      List<AwemeItem>.from(_items),
      index.clamp(0, _items.length - 1),
      widget.author.secUid,
      _cursor,
      _hasMore,
    );
  }

  /// 「播放 TA 的全部作品」：没拉过就先自动拉，拉到就直接作为播放队列起播。
  /// 当前视频本身在这个作者列表里时，从当前视频开始播，不跳回第一条。
  Future<void> _playAll() async {
    _requested = true;
    if (_items.isEmpty && !_loading) {
      await _load();
    } else if (_loading) {
      while (_loading && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }
    if (!mounted || _items.isEmpty) return;
    final current = _items.indexWhere((e) => e.id == widget.awemeId);
    _playAt(current >= 0 ? current : 0);
  }

  Future<void> _refresh() async {
    _reset();
    _requested = true;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final author = widget.author;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF262626)))),
          child: Column(
            children: [
              Row(
                children: [
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(author.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Color(0xFFEDEDED),
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          _initial
                              ? '正在拉取 TA 的作品…'
                              : 'TA 的作品 · ${_items.length} 个',
                          style: const TextStyle(
                              color: Color(0xFF8A8A8A), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: _loading
                        ? const CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF8A8A8A))
                        : null,
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: '重新拉取该作者的作品',
                    child: IconButton(
                      onPressed:
                          _loading ? null : () => unawaited(_refresh()),
                      icon: const Icon(Icons.refresh,
                          size: 16, color: Color(0xFFCFCFCF)),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 28, minHeight: 28),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFE2C55),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        textStyle: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                      onPressed: _loading && _items.isEmpty
                          ? null
                          : () => unawaited(_playAll()),
                      child: Text(_items.isEmpty
                          ? '拉取并播放 TA 的全部作品'
                          : '播放 TA 的全部作品'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: widget.onOpenAuthor,
                    child: const Text('主页',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFFBDBDBD))),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_initial && _items.isEmpty && _error == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(height: 10),
            Text('正在拉取 TA 的作品…',
                style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 12)),
          ],
        ),
      );
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Color(0xFFFFB74D), fontSize: 12.5)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  setState(() => _error = null);
                  unawaited(_load());
                },
                child: const Text('重试', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text('该作者暂无可播放的作品',
            style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 12)),
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.56,
      ),
      itemCount: _items.length + (_hasMore || _loading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return Center(
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(
                    onPressed: _hasMore ? () => unawaited(_load()) : null,
                    child: Text(_hasMore ? '加载更多' : '没有更多了',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF9A9A9A))),
                  ),
          );
        }
        return _AuthorPostTile(
            item: _items[index], onTap: () => _playAt(index));
      },
    );
  }
}

class _AuthorPostTile extends StatelessWidget {
  const _AuthorPostTile({required this.item, required this.onTap});

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
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: const Color(0xFF1E1E1E),
                      child: item.coverUrl.isEmpty
                          ? const Icon(Icons.movie_outlined,
                              color: Color(0xFF6C6C6C), size: 24)
                          : CachedNetworkImage(
                              imageUrl: item.coverUrl,
                              fit: BoxFit.cover,
                              memCacheWidth: 220,
                              errorWidget: (context, _, _) => const Icon(
                                  Icons.broken_image_outlined,
                                  color: Color(0xFF6C6C6C),
                                  size: 22),
                            ),
                    ),
                    Positioned(
                      left: 5,
                      bottom: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.play_arrow,
                                size: 10, color: Colors.white),
                            const SizedBox(width: 2),
                            Text(
                              item.isImage
                                  ? '图文'
                                  : formatDuration(item.durationMs),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              item.desc.isEmpty ? '无标题作品' : item.desc,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Color(0xFFE6E6E6), fontSize: 11.5, height: 1.35),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                const Icon(Icons.favorite_border,
                    size: 11, color: Color(0xFF8A8A8A)),
                const SizedBox(width: 3),
                Text(formatCount(item.diggCount),
                    style: const TextStyle(
                        color: Color(0xFF8A8A8A), fontSize: 10.5)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonTab extends StatelessWidget {
  const _SkeletonTab({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.construction_outlined,
                size: 22, color: Color(0xFF6A6A6A)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(0xFF8A8A8A), fontSize: 12, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentTile extends StatefulWidget {
  const _CommentTile({
    required this.item,
    required this.api,
    required this.awemeId,
  });

  final CommentItem item;
  final DouyinApi api;
  final String awemeId;

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  /// 长文本展开（正文本身被折叠）。
  bool _expanded = false;

  /// 子回复列表：点"展开 N 条回复"才拉取，再点一次收起。
  bool _showReplies = false;
  bool _loadingReplies = false;
  bool _repliesHasMore = false;
  int _repliesCursor = 0;
  String? _repliesError;
  final List<CommentItem> _replies = [];
  final Set<String> _seenReplies = {};

  Future<void> _toggleReplies() async {
    if (_showReplies) {
      setState(() => _showReplies = false);
      return;
    }
    setState(() => _showReplies = true);
    if (_replies.isEmpty) await _loadReplies();
  }

  /// 拉取子回复；[more] 为 true 时翻页。
  Future<void> _loadReplies({bool more = false, bool allowVerifyRetry = true}) async {
    if (_loadingReplies) return;
    setState(() {
      _loadingReplies = true;
      _repliesError = null;
    });
    try {
      final res = await widget.api.fetchCommentReplies(
        widget.awemeId,
        widget.item.cid,
        cursor: more ? _repliesCursor : 0,
        count: 5,
      );
      final raw = res['comments'];
      final parsed = <CommentItem>[];
      if (raw is List) {
        for (final node in raw) {
          final item = CommentItem.fromJson(asMap(node));
          if (item != null) parsed.add(item);
        }
      }
      if (!mounted) return;
      setState(() {
        if (!more) {
          _replies.clear();
          _seenReplies.clear();
        }
        for (final item in parsed) {
          if (_seenReplies.add(item.cid)) _replies.add(item);
        }
        _repliesCursor =
            (res['cursor'] as num?)?.toInt() ?? (_repliesCursor + 5);
        _repliesHasMore = (res['has_more'] as num?)?.toInt() == 1;
      });
    } on DouyinException catch (e) {
      if (!mounted) return;
      if (e.needsVerify && allowVerifyRetry) {
        setState(() => _loadingReplies = false);
        diag('comment', '子回复命中风控，等待用户验证');
        final ok = await VerifyGate.instance
            .waitForUser(widget.api, e, label: '加载子回复');
        if (!mounted) return;
        if (ok) {
          await _loadReplies(more: more, allowVerifyRetry: false);
          return;
        }
        setState(() {
          _repliesError = '需要验证但尚未完成：${VerifyGate.instance.message}';
        });
        return;
      }
      setState(() => _repliesError = _describeError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _repliesError = _describeError(e));
    } finally {
      if (mounted) setState(() => _loadingReplies = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipOval(
          child: SizedBox(
            width: 32,
            height: 32,
            child: item.avatarUrl.isEmpty
                ? const ColoredBox(color: Color(0xFF333333))
                : CachedNetworkImage(
                    imageUrl: item.avatarUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 72,
                    errorWidget: (_, _, _) =>
                        const ColoredBox(color: Color(0xFF333333)),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      item.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(0xFF8F8F8F), fontSize: 12),
                    ),
                  ),
                  if (item.isAuthor) ...[
                    const SizedBox(width: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0x33FF2D55),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text('作者',
                          style: TextStyle(
                              color: Color(0xFFFF7B95), fontSize: 9.5)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              if (item.text.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    item.text,
                    maxLines: _expanded ? 20 : 4,
                    overflow: _expanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFFE4E4E4), fontSize: 13, height: 1.5),
                  ),
                ),
              if (item.images.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < item.images.length; i++)
                      GestureDetector(
                        onTap: () =>
                            showCommentImageViewer(context, item.images, i),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: SizedBox(
                            width: 82,
                            height: 82,
                            child: CachedNetworkImage(
                              imageUrl: item.images[i].thumb,
                              fit: BoxFit.cover,
                              // 九宫格只有 82px，按 2x 解码即可，否则原图一张就吃几 MB。
                              memCacheWidth: 240,
                              maxWidthDiskCache: 320,
                              placeholder: (_, _) =>
                                  const ColoredBox(color: Color(0xFF2A2A2A)),
                              errorWidget: (_, _, _) =>
                                  const ColoredBox(color: Color(0xFF2A2A2A)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    [
                      formatTimeAgo(item.createTime),
                      if (item.ipLabel.isNotEmpty) item.ipLabel,
                    ].join(' · '),
                    style: const TextStyle(
                        color: Color(0xFF6E6E6E), fontSize: 11),
                  ),
                  const SizedBox(width: 12),
                  const Text('回复',
                      style: TextStyle(
                          color: Color(0xFF6E6E6E), fontSize: 11)),
                  const SizedBox(width: 12),
                  const Text('分享',
                      style: TextStyle(
                          color: Color(0xFF6E6E6E), fontSize: 11)),
                  const Spacer(),
                  const Icon(Icons.favorite_border,
                      size: 13, color: Color(0xFF6E6E6E)),
                  const SizedBox(width: 4),
                  Text(
                    formatCount(item.diggCount),
                    style: const TextStyle(
                        color: Color(0xFF6E6E6E), fontSize: 11),
                  ),
                ],
              ),
              if (item.replyTotal > 0) ...[
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: _toggleReplies,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showReplies
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 14,
                        color: const Color(0xFF9A9A9A),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        _showReplies ? '收起回复' : '展开 ${item.replyTotal} 条回复',
                        style: const TextStyle(
                            color: Color(0xFF9A9A9A), fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ],
              if (_showReplies) _buildReplies(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReplies() {
    if (_loadingReplies && _replies.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF8A8A8A)),
        ),
      );
    }
    if (_repliesError != null && _replies.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: GestureDetector(
          onTap: () => _loadReplies(),
          child: Text(
            '$_repliesError（点击重试）',
            style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 11.5),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(left: 10),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Color(0xFF2E2E2E), width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final reply in _replies) ...[
            _ReplyTile(item: reply),
            const SizedBox(height: 8),
          ],
          if (_loadingReplies)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFF8A8A8A)),
              ),
            )
          else if (_repliesHasMore)
            GestureDetector(
              onTap: () => _loadReplies(more: true),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '展开更多回复',
                  style: TextStyle(color: Color(0xFF8CC8FF), fontSize: 11.5),
                ),
              ),
            )
          else if (_repliesError != null)
            GestureDetector(
              onTap: () => _loadReplies(more: true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '$_repliesError（点击重试）',
                  style: const TextStyle(
                      color: Color(0xFFFF6B6B), fontSize: 11.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 子回复的一行：头像、昵称、内容、时间、点赞数。
class _ReplyTile extends StatelessWidget {
  const _ReplyTile({required this.item});

  final CommentItem item;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipOval(
          child: SizedBox(
            width: 24,
            height: 24,
            child: item.avatarUrl.isEmpty
                ? const ColoredBox(color: Color(0xFF333333))
                : CachedNetworkImage(
                    imageUrl: item.avatarUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 56,
                    errorWidget: (_, _, _) =>
                        const ColoredBox(color: Color(0xFF333333)),
                  ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.userName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: Color(0xFF8F8F8F), fontSize: 11.5),
              ),
              if (item.text.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  item.text,
                  style: const TextStyle(
                      color: Color(0xFFDCDCDC), fontSize: 12.5, height: 1.45),
                ),
              ],
              const SizedBox(height: 3),
              Text(
                [
                  formatTimeAgo(item.createTime),
                  if (item.ipLabel.isNotEmpty) item.ipLabel,
                ].join(' · '),
                style: const TextStyle(color: Color(0xFF6E6E6E), fontSize: 10.5),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.favorite_border, size: 12, color: Color(0xFF6E6E6E)),
            const SizedBox(width: 3),
            Text(
              formatCount(item.diggCount),
              style:
                  const TextStyle(color: Color(0xFF6E6E6E), fontSize: 10.5),
            ),
          ],
        ),
      ],
    );
  }
}

String _describeError(Object e) {
  if (e is DouyinException && (e.body ?? '').isEmpty) {
    return '服务端返回空响应（通常是风控）';
  }
  return ErrorText.from(e);
}

/// 底部发表评论输入条：文本 + 表情 + 发送，带成功/失败/需要登录三种反馈。
class _CommentComposer extends StatefulWidget {
  const _CommentComposer({
    required this.api,
    required this.awemeId,
    this.onPosted,
    this.onRequestLogin,
    this.onRefreshNeeded,
  });

  final DouyinApi api;
  final String awemeId;
  final void Function(Map<String, dynamic> json)? onPosted;
  final VoidCallback? onRequestLogin;

  /// 验证后无法确认上一次是否已发出时，通知面板重新拉第一页核对。
  final VoidCallback? onRefreshNeeded;

  @override
  State<_CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<_CommentComposer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _sending = false;
  bool _showEmoji = false;
  String? _message;
  bool _messageIsError = false;

  /// 常用表情（直接以 Unicode 字符插入正文；抖音自表情包需要 emoji_id，
  /// 没有真实映射就不臆造，这里只保证"带表情的纯文本评论"能发出去）。
  static const List<String> _emojis = [
    '😀', '😁', '😂', '🤣', '😊', '😍', '🥰', '😘',
    '😎', '🤔', '😴', '😭', '😡', '🥳', '👍', '👎',
    '❤️', '🔥', '🎉', '👏', '🙏', '💪', '🌹', '🍉',
  ];

  @override
  void initState() {
    super.initState();
    // 上报 IME 组字状态：播放页的 X/Z/S 快捷键要在这里让位给候选框。
    ImeGuard.watchComposing(_controller);
  }

  @override
  void dispose() {
    ImeGuard.clearComposing();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _setMessage(String? text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  void _insertEmoji(String emoji) {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final text = value.text.replaceRange(start, end, emoji);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _focus.requestFocus();
    setState(() => _showEmoji = false);
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _setMessage('说点什么再发送', error: true);
      return;
    }
    if (!widget.api.isLoggedIn) {
      _setMessage('需要登录后才能发表评论，点顶部「登录」扫码或粘贴 Cookie', error: true);
      widget.onRequestLogin?.call();
      return;
    }
    setState(() {
      _sending = true;
      _message = null;
    });
    try {
      final res = await widget.api.publishComment(widget.awemeId, text);
      _applyPosted(res);
    } on DouyinException catch (e) {
      if (e.needsVerify) {
        diag('comment', '发布命中风控，等待用户验证');
        _setMessage('需要验证：${ErrorText.from(e)}，已尝试在浏览器打开验证页面…', error: true);
        final ok = await VerifyGate.instance
            .waitForUser(widget.api, e, label: '发表评论');
        if (!mounted) return;
        if (ok) {
          // 写接口只重试一次；重试前先确认上一次是否其实已经发出，
          // 避免同一条评论被发两遍。
          final already = await _maybePostedBefore(text);
          if (!mounted) return;
          if (already) {
            // 验证已通过但无法确认上次是否已发出：不重发，改为刷新列表核对。
            _controller.clear();
            _setMessage(
                '验证已通过。上次评论可能已生效，为避免重复未再发送，已重新拉取评论列表，请确认。',
                error: true);
            widget.onRefreshNeeded?.call();
          } else {
            try {
              final res = await widget.api.publishComment(widget.awemeId, text);
              _applyPosted(res);
            } catch (retryError) {
              diag('comment', '验证后重试仍失败: $retryError');
              _setMessage(
                  '验证通过但重试仍失败：${_describePublishError(retryError)}',
                  error: true);
            }
          }
        } else {
          _setMessage('需要验证但未完成：${VerifyGate.instance.message}', error: true);
        }
      } else {
        diag('comment', '发布失败: $e');
        _setMessage('发送失败：${_describePublishError(e)}', error: true);
      }
    } catch (e) {
      diag('comment', '发布失败: $e');
      _setMessage('发送失败：${_describePublishError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 发布成功后的统一收尾（首次发送与验证后重试共用）。
  void _applyPosted(Map<String, dynamic> res) {
    if (!mounted) return;
    _controller.clear();
    _setMessage('评论已发布');
    widget.onPosted?.call(res);
    final cid = (asMap(res['comment'])['cid'] ?? '').toString();
    if (cid.isNotEmpty) unawaited(_verifyVisible(cid));
  }

  /// 验证通过、准备重试写接口前，先拉一页评论确认上次是否其实已经发出。
  ///
  /// 拉取失败时按"可能已生效"处理：宁可少发一条，也不能重复刷屏。
  Future<bool> _maybePostedBefore(String text) async {
    try {
      final res = await widget.api.fetchComments(widget.awemeId, count: 20);
      final list = res['comments'];
      final target = text.trim();
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (list is List) {
        for (final node in list) {
          final map = asMap(node);
          final content = (map['text'] ?? '').toString().trim();
          if (content != target) continue;
          final created = (map['create_time'] as num?)?.toInt() ?? 0;
          if (created == 0 || nowSeconds - created <= 300) {
            diag('comment', '重试前发现疑似已发布的同文本评论，跳过重试');
            return true;
          }
        }
      }
    } catch (e) {
      diag('comment', '重试前确认评论是否已发出失败: $e');
      return true;
    }
    return false;
  }

  /// 发布后用一级评论列表复核是否"公开可见"：接口返回 success 不代表别人能看到，
  /// 出现"仅自己可见/审核中"时必须如实提示，而不是只报成功。
  Future<void> _verifyVisible(String cid) async {
    try {
      final res = await widget.api.fetchComments(widget.awemeId, count: 20);
      final list = res['comments'];
      var found = false;
      if (list is List) {
        for (final node in list) {
          if ((asMap(node)['cid'] ?? '').toString() == cid) {
            found = true;
            break;
          }
        }
      }
      diag('comment', '发布可见性复核 cid=$cid found=$found');
      if (!mounted) return;
      _setMessage(
        found ? '评论已发布，已在公开列表可见' : '已提交成功，但公开列表暂未出现（可能仅自己可见或审核中）',
        error: !found,
      );
    } catch (e) {
      diag('comment', '可见性复核失败: $e');
      if (!mounted) return;
      _setMessage('已提交，但无法复核可见性：${_describePublishError(e)}', error: true);
    }
  }

  String _describePublishError(Object e) {
    if (e is DouyinException) {
      final body = e.body ?? '';
      if (body.isEmpty) {
        return '服务端返回空响应（登录态失效或被风控拦截）';
      }
      final code = RegExp(r'status_code=(\d+)').firstMatch(e.message)
          ?.group(1);
      if (code != null) {
        return switch (code) {
          '8' => '登录态失效（status_code=8），请重新登录后再发',
          '5' => '参数被服务端拒绝（status_code=5）',
          _ => '服务端拒绝（status_code=$code）',
        };
      }
    }
    return ErrorText.from(e);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF1B1B1B),
        border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_message != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Text(
                _message!,
                style: TextStyle(
                  color: _messageIsError
                      ? const Color(0xFFFF7B7B)
                      : const Color(0xFF8CD98C),
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ),
          ],
          if (_showEmoji) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF242424),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final emoji in _emojis)
                    InkWell(
                      onTap: () => _insertEmoji(emoji),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Text(emoji, style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                ],
              ),
            ),
          ],
          Row(
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF262626),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 3,
                          style: const TextStyle(
                              color: Color(0xFFEDEDED), fontSize: 12.5),
                          cursorColor: const Color(0xFFFE2C55),
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          onChanged: (_) {
                            if (_message != null && !_messageIsError) {
                              _setMessage(null);
                            }
                            setState(() {});
                          },
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: '留下你的精彩评论吧',
                            hintStyle: TextStyle(
                                color: Color(0xFF7E7E7E), fontSize: 12),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () => setState(() => _showEmoji = !_showEmoji),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.emoji_emotions_outlined,
                            size: 17,
                            color: _showEmoji
                                ? const Color(0xFFFE2C55)
                                : const Color(0xFF8A8A8A),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              InkWell(
                onTap: (_sending || _controller.text.trim().isEmpty)
                    ? null
                    : _send,
                borderRadius: BorderRadius.circular(17),
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (_sending || _controller.text.trim().isEmpty)
                        ? const Color(0xFF333333)
                        : const Color(0xFFFE2C55),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white70),
                        )
                      : Text(
                          '发送',
                          style: TextStyle(
                            color: (_sending || _controller.text.trim().isEmpty)
                                ? const Color(0xFFB0B0B0)
                                : Colors.white,
                            fontSize: 12,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
