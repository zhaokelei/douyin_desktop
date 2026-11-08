import 'dart:async';
import 'dart:io' show Platform, ProcessInfo, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/app_settings.dart';
import '../../core/diag.dart';
import '../../core/error_text.dart';
import '../../core/verify_gate.dart';
import '../../data/douyin_api.dart';
import '../../data/models.dart';
import '../../data/session_store.dart';
import '../../data/video_cache.dart';
import '../feed/video_card.dart';
import '../login/login_page.dart';
import '../player/player_page.dart';
import '../settings/settings_page.dart';

/// 主界面：纯 HTTP 拉取抖音推荐流，不包含任何 WebView。
///
/// 交互：滚动到底自动加载下一页；顶部按钮可刷新；失败有明确提示和重试入口。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final DouyinApi _api = DouyinApi();
  final SessionStore _store = SessionStore();
  final List<AwemeItem> _items = <AwemeItem>[];
  final Set<String> _seen = <String>{};
  final ScrollController _scroll = ScrollController();

  bool _loading = false;
  bool _initialLoading = true;
  bool _hasMore = true;
  String? _error;
  String _accountName = '游客';
  String _status = '准备中';

  /// 非空表示登录态有问题（未找到文件 / 解析失败 / 无 sessionid），
  /// 界面上给出可点击的提示，而不是静默降级成游客。
  String? _cookieHint;
  String? _cookiePath;

  /// 登录态校验失败的具体原因（status_code 等），显示在状态行，避免静默。
  String? _authReason;
  int _loadCount = 0;
  int _totalFrames = 0;
  int _jankFrames = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _bootstrap();
    _installTestHooks();
    // 首屏就把缓存目录索引读进内存：进播放页时 lookup 是纯内存查表，
    // 切换作品不再有"第一次 stat 目录"的延迟（命中更接近"瞬开"）。
    final cache = VideoCache.shared;
    cache.setMaxBytes(AppSettings.instance.cacheLimitBytes);
    unawaited(cache.init());
    // 自测钩子：DOUYIN_OPEN_SETTINGS=1 启动即打开设置页。
    // 配合 DOUYIN_SHOT 离屏截图，可以在不抢焦点的情况下核对设置页的真实渲染。
    if (Platform.environment['DOUYIN_OPEN_SETTINGS'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openSettings());
      });
    }
  }

  /// 自测钩子（仅环境变量触发）：DOUYIN_AUTOSCROLL=1 自动滚到底部加载更多，
  /// 并每 5 秒把条目数、内存和掉帧数写进日志，用于"连续滚动 200 条"压测。
  void _installTestHooks() {
    if (Platform.environment['DOUYIN_AUTOSCROLL'] != '1') return;
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        _totalFrames++;
        if (t.totalSpan.inMilliseconds > 16) _jankFrames++;
      }
    });
    final intervalMs =
        int.tryParse(Platform.environment['DOUYIN_SCROLL_MS'] ?? '') ?? 2500;
    Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (!mounted || _loading) return;
      _loadMore();
      // 同步把视图滚到底，模拟真实用户的"一直往下滑"。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
    Timer.periodic(const Duration(seconds: 5), (_) {
      diag(
          'scroll',
          'items=${_items.length} rss=${(ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1)}MB '
          'frames=$_totalFrames janky=$_jankFrames');
    });
  }

  Future<void> _bootstrap() async {
    final cookiePath = DouyinApi.resolveCookiePath();
    if (cookiePath != null) {
      _cookiePath = cookiePath;
      try {
        final loaded = _api.loadCookieFile(cookiePath);
        diag('home',
            '加载 Cookie 文件成功，${loaded.length} 项，登录=${_api.isLoggedIn}，路径=$cookiePath');
        if (_api.isLoggedIn) {
          // 账号校验不阻塞首屏，和推荐流请求并行跑。
          unawaited(_checkAccount());
        } else {
          _accountName = '游客（Cookie 无 sessionid）';
          _cookieHint = '找到了 $cookiePath，但没有 sessionid：'
              '导出时可能未登录，或 Cookie 已过期。';
        }
      } catch (e) {
        diag('home', '读取 Cookie 文件失败: $e');
        _accountName = '游客（Cookie 读取失败）';
        _cookieHint = '读取 $cookiePath 失败：${ErrorText.from(e)}';
      }
    } else {
      // 磁盘上没有 Cookie 文件：回退到上次登录存进 SharedPreferences 的会话，
      // 并立刻写回文件，避免下次启动又找不到。
      final header = await _store.readCookie();
      final parsed =
          header == null ? const <String, String>{} : DouyinApi.parseCookieInput(header);
      if (parsed.isNotEmpty) {
        _api.applyCookies(parsed);
        final written = _api.saveCookieHeader(header!);
        _cookiePath = written;
        _accountName = '已登录（本地会话已恢复）';
        _cookieHint = null;
        diag('home',
            '磁盘无 Cookie 文件，已从本地会话恢复 ${parsed.length} 项，写回文件=${written ?? "失败"}');
        unawaited(_checkAccount());
      } else {
        diag('home',
            '未找到 douyin_cookies.json，且本地会话为空，使用匿名态；候选路径=${DouyinApi.cookieCandidatePaths()}');
        _accountName = '游客（未检测到 Cookie）';
        _cookieHint = '未检测到登录态：把 douyin_cookies.json 放到下列任一文件路径后，'
            '点顶部"刷新"即可；也可以用 DOUYIN_COOKIES 指定绝对路径。';
      }
    }
    if (!mounted) return;
    setState(() {});
    await _refresh();
  }

  /// 打开登录页（扫码 / 粘贴 Cookie），成功后热更新登录态并刷新推荐流。
  Future<void> _openLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LoginPage(
          api: _api,
          onLoggedIn: () {
            if (!mounted) return;
            setState(() {
              _cookieHint = null;
              _accountName = '已登录';
              _authReason = null;
            });
            unawaited(_checkAccount());
            unawaited(_refresh());
          },
        ),
      ),
    );
    if (ok == true && mounted) unawaited(_refresh());
  }

  /// 打开设置页：解码方式、内存/磁盘缓存、默认清晰度都在这里切换。
  /// 设置写进 AppSettings（持久化），播放页监听同一实例，返回后即刻生效。
  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _showCookieHelp() async {
    final paths = DouyinApi.cookieCandidatePaths();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('登录态 / Cookie 文件'),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_cookieHint != null)
                Text(_cookieHint!,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFFFB74D), height: 1.5)),
              const SizedBox(height: 10),
              if (_cookiePath != null)
                Text('当前已读取：$_cookiePath',
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF8CD98C))),
              const SizedBox(height: 8),
              const Text('按优先级会查找以下位置（把文件放到任一存在路径）：',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFFB9B9B9))),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    paths.join('\n'),
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFFBFBFBF), height: 1.6),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkAccount() async {
    try {
      final self = await _api.fetchSelfProfile();
      final user = (self['user'] as Map?) ?? const {};
      diag('home', '登录态有效，昵称=${user['nickname']}');
      if (!mounted) return;
      setState(() {
        _accountName = (user['nickname'] ?? '已登录').toString();
        _authReason = null;
      });
    } catch (e) {
      diag('home', '登录态校验失败: $e');
      if (!mounted) return;
      // 登录态查询是后台校验，不自动弹浏览器（避免每次启动都打扰）；
      // 只把「需要验证」如实标出来，用户点"刷新 / 登录"时再触发验证流程。
      final needsVerify = e is DouyinException && e.needsVerify;
      setState(() {
        _accountName = needsVerify ? '游客（需要验证）' : '游客（登录态校验失败）';
        _authReason = needsVerify
            ? '${ErrorText.from(e)}（点顶部"登录"扫码，或点"刷新"触发浏览器验证）'
            : _describeAuthFailure(e);
        _status = needsVerify ? '需要验证：${ErrorText.from(e)}' : '校验失败：$_authReason';
        _cookieHint = 'Cookie 已读到（路径：${_cookiePath ?? "未知"}），但账号校验没通过：'
            '${_describeAuthFailure(e)}\n'
            '如果是网络问题可点"刷新"重试；如果是会话失效，请重新导入 Cookie。';
      });
    }
  }

  /// 把校验失败翻译成可判断的原因，避免一律笼统说"Cookie 失效"。
  static String _describeAuthFailure(Object e) {
    if (e is DouyinException) {
      if (e.statusCode == 8) return '服务端返回 status_code=8（会话未登录/已失效）';
      final body = e.body ?? '';
      if (body.isEmpty) {
        return '服务端空响应（疑似风控拦截）'
            '${e.statusCode == null ? "" : "，HTTP ${e.statusCode}"}';
      }
      // 统一中文：e.message 可能是 "HTTP 403" 这类英文。
      return ErrorText.from(e);
    }
    if (e is SocketException) {
      return '网络不可用，未能连上抖音服务器（Cookie 未必失效）';
    }
    return ErrorText.from(e);
  }

  /// [allowVerifyRetry] 为 false 表示这是"验证通过后的重试"，只允许跑一次，
  /// 避免同一个请求在风控里无限循环。
  Future<void> _refresh({bool allowVerifyRetry = true}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _status = '正在请求推荐流';
    });
    try {
      final raw = await _api.fetchFeed(count: 20);
      final parsed = <AwemeItem>[];
      for (final json in raw) {
        final item = AwemeItem.fromJson(json);
        if (item != null) parsed.add(item);
      }
      if (!mounted) return;
      setState(() {
        _items.clear();
        _seen.clear();
        _items.addAll(parsed);
        _seen.addAll(parsed.map((e) => e.id));
        _loadCount = 1;
        _hasMore = true;
        _initialLoading = false;
        _status = '已加载 ${_items.length} 条真实作品';
        if (_items.isEmpty) {
          _error = '服务端返回了 0 条作品';
        }
      });
      diag('home', '刷新完成 ${parsed.length} 条');
      diag('home', '首批数据就绪，耗时 ${kStartupWatch?.elapsedMilliseconds ?? -1} ms');
    } on DouyinException catch (e) {
      if (!mounted) return;
      if (e.needsVerify && allowVerifyRetry) {
        // 命中风控：先把界面恢复成"可操作"，再等用户在浏览器里过验证。
        setState(() {
          _loading = false;
          _initialLoading = false;
          _status = '需要验证：${ErrorText.from(e)}';
        });
        diag('home', '刷新命中风控，等待用户验证');
        final ok = await VerifyGate.instance
            .waitForUser(_api, e, label: '刷新推荐流');
        if (!mounted) return;
        if (ok) {
          await _refresh(allowVerifyRetry: false);
          return;
        }
        setState(() {
          _error = '需要验证但尚未完成：${VerifyGate.instance.message}';
          _status = '验证未完成';
        });
        return;
      }
      setState(() {
        _error = ErrorText.from(e);
        _status = '请求失败';
        _initialLoading = false;
      });
      diag('home', '刷新失败: ${e.message} body=${e.body}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final detail = e is SocketException
            ? '网络不可用：无法连接服务器，请检查网络或代理后重试'
            : e is FormatException
                ? '服务端返回非 JSON（常见于验证码/风控拦截）'
                : ErrorText.from(e);
        _error = _cookieHint == null
            ? detail
            : '$detail\n当前 Cookie 可能已失效，建议点顶部"登录"重新导入。';
        _status = '请求异常';
        _initialLoading = false;
      });
      diag('home', '刷新异常: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted || _items.isEmpty) return;
    // 补齐首屏（必须在 _loading 复位之后，否则 _loadMore 会被拦住）。
    await _fillViewport();
    diag('home', '首屏就绪，冷启动耗时 ${kStartupWatch?.elapsedMilliseconds ?? -1} ms');
    _maybeAutoplay();
  }

  /// 抖音推荐流单次只返回 2 条左右，首屏常常撑不满一屏、也无法滚动，
  /// 所以这里主动补齐到"至少有 8 条且能滚动"为止，否则用户看不到"加载更多"的入口。
  Future<void> _fillViewport() async {
    for (var i = 0; i < 12; i++) {
      if (!mounted || !_hasMore) return;
      final enough = _items.length >= 8 &&
          (!_scroll.hasClients || _scroll.position.maxScrollExtent > 24);
      if (enough) return;
      if (i > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await _loadMore();
    }
  }

  void _maybeAutoplay() {
    if (Platform.environment['DOUYIN_AUTOPLAY'] != '1') return;
    if (_items.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerPage(
          api: _api,
          items: _items,
          initialIndex: 0,
          onLoadMore: _loadMoreForPlayer,
        ),
      ));
    });
  }

  /// 播放页快刷到列表尾部时调用：异步拉下一批并**追加到同一个列表**，
  /// 不打断当前播放。返回本次新增条数（0 表示确实没有更多）。
  Future<int> _loadMoreForPlayer({bool allowVerifyRetry = true}) async {
    if (!_hasMore) return 0;
    try {
      var added = 0;
      for (var attempt = 0; attempt < 4; attempt++) {
        final raw = await _api.fetchFeed(count: 20);
        _loadCount++;
        for (final json in raw) {
          final item = AwemeItem.fromJson(json);
          if (item == null) continue;
          if (_seen.add(item.id)) {
            _items.add(item);
            added++;
          }
        }
        if (added > 0) break;
      }
      if (added == 0) _hasMore = false;
      diag('home', '播放页预加载 +$added 条，共 ${_items.length} 条');
      if (mounted) {
        setState(() => _status = '已加载 ${_items.length} 条真实作品');
      }
      return added;
    } on DouyinException catch (e) {
      if (e.needsVerify && allowVerifyRetry) {
        diag('home', '播放页预加载命中风控，等待用户验证');
        final ok = await VerifyGate.instance
            .waitForUser(_api, e, label: '预加载下一条');
        if (ok) return _loadMoreForPlayer(allowVerifyRetry: false);
        return 0;
      }
      diag('home', '播放页预加载失败: ${e.message}');
      return 0;
    } catch (e) {
      diag('home', '播放页预加载失败: $e');
      return 0;
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// 抖音推荐流每次只返回少量条目，所以"加载更多"要多次请求并去重。
  Future<void> _loadMore({bool allowVerifyRetry = true}) async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var added = 0;
      // 最多连打 4 次，避免偶尔一次全是重复内容导致加载卡死。
      for (var attempt = 0; attempt < 4; attempt++) {
        final raw = await _api.fetchFeed(count: 20);
        _loadCount++;
        for (final json in raw) {
          final item = AwemeItem.fromJson(json);
          if (item == null) continue;
          if (_seen.add(item.id)) {
            _items.add(item);
            added++;
          }
        }
        if (added > 0) break;
      }
      if (!mounted) return;
      setState(() {
        if (added == 0) _hasMore = false;
        _status = '已加载 ${_items.length} 条真实作品';
      });
      diag('home', '加载更多 +$added 条，共 ${_items.length} 条，请求次数=$_loadCount');
    } on DouyinException catch (e) {
      if (!mounted) return;
      if (e.needsVerify && allowVerifyRetry) {
        setState(() {
          _loading = false;
          _status = '需要验证：${ErrorText.from(e)}';
        });
        diag('home', '加载更多命中风控，等待用户验证');
        final ok = await VerifyGate.instance
            .waitForUser(_api, e, label: '加载更多推荐');
        if (!mounted) return;
        if (ok) {
          await _loadMore(allowVerifyRetry: false);
          return;
        }
        setState(() {
          _error = '需要验证但尚未完成：${VerifyGate.instance.message}';
          _status = '验证未完成';
        });
        return;
      }
      // 风控/验证之外的原因才停止翻页，避免把"需要验证"当成"没有更多"。
      setState(() {
        _error = '加载更多失败：${ErrorText.from(e)}';
        _hasMore = false;
      });
      diag('home', '加载更多失败: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载更多失败：${ErrorText.from(e)}';
        _hasMore = false;
      });
      diag('home', '加载更多失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Column(
        children: [
          _Header(
            status: _authReason == null ? _status : '校验失败：$_authReason',
            accountName: _accountName,
            cookieHint: _cookieHint,
            onCookieHelp: _showCookieHelp,
            onLogin: _openLogin,
            onSettings: _openSettings,
            count: _items.length,
            loading: _loading,
            onRefresh: _refresh,
          ),
          Expanded(
            child: _initialLoading
                ? const _LoadingView()
                : (_items.isEmpty ? _ErrorView(message: _error ?? '暂无内容', onRetry: _refresh) : _buildList()),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      itemCount: _items.length + 2,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) return const SizedBox.shrink();
        if (index <= _items.length) {
          final item = _items[index - 1];
          return VideoCard(
            key: ValueKey(item.id),
            item: item,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlayerPage(
                  api: _api,
                  // 传同一个列表引用：播放页刷到尾部时，这里追加的条目
                  // 播放页能直接看到，不需要重建页面。
                  items: _items,
                  initialIndex: index - 1,
                  onLoadMore: _loadMoreForPlayer,
                ),
              ),
            ),
          );
        }
        return _Footer(
          loading: _loading,
          error: _error,
          hasMore: _hasMore,
          onRetry: _loadMore,
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.status,
    required this.accountName,
    required this.cookieHint,
    required this.onCookieHelp,
    required this.onLogin,
    required this.onSettings,
    required this.count,
    required this.loading,
    required this.onRefresh,
  });

  final String status;
  final String accountName;
  final String? cookieHint;
  final VoidCallback onCookieHelp;
  final VoidCallback onLogin;
  final VoidCallback onSettings;
  final int count;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF141414),
        border: Border(bottom: BorderSide(color: Color(0xFF242424))),
      ),
      child: Row(
        children: [
          const Text(
            '抖音',
            style: TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1F1F1F),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2E2E2E)),
            ),
            child: Text(
              accountName,
              style: const TextStyle(color: Color(0xFFB9B9B9), fontSize: 11.5),
            ),
          ),
          if (cookieHint != null) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: onCookieHelp,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0x33FF9800),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0x66FF9800)),
                ),
                child: const Row(children: [
                  Icon(Icons.info_outline, size: 13, color: Color(0xFFFFB74D)),
                  SizedBox(width: 4),
                  Text('未登录？点此查看路径',
                      style:
                          TextStyle(fontSize: 11, color: Color(0xFFFFB74D))),
                ]),
              ),
            ),
          ],
          const SizedBox(width: 12),
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
                ? const CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8A8A8A))
                : null,
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: onLogin,
            icon: const Icon(Icons.login, size: 16, color: Color(0xFFCFCFCF)),
            label: const Text('登录',
                style: TextStyle(color: Color(0xFFCFCFCF), fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: loading ? null : onRefresh,
            icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFCFCFCF)),
            label: const Text('刷新', style: TextStyle(color: Color(0xFFCFCFCF), fontSize: 12.5)),
          ),
          const SizedBox(width: 2),
          IconButton(
            onPressed: onSettings,
            tooltip: '设置（解码方式 / 缓存 / 清晰度）',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.settings_outlined, color: Color(0xFFCFCFCF)),
          ),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8A8A8A)),
          ),
          const SizedBox(height: 16),
          Text(
            '正在加载推荐流…',
            style: TextStyle(color: const Color(0xFF8A8A8A), fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 34, color: Color(0xFFFF6B6B)),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12.5, height: 1.6),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF2D55),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.loading,
    required this.error,
    required this.hasMore,
    required this.onRetry,
  });

  final bool loading;
  final String? error;
  final bool hasMore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8A8A8A)),
          ),
        ),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Column(
            children: [
              Text(error!, style: const TextStyle(color: Color(0xFFFF7B7B), fontSize: 11.5)),
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          hasMore ? '继续下滑加载更多' : '没有更多了',
          style: const TextStyle(color: Color(0xFF666666), fontSize: 11.5),
        ),
      ),
    );
  }
}
