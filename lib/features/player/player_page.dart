import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/legacy.dart' as wm;

import '../../core/app_settings.dart';
import '../../core/diag.dart';
import '../../core/error_text.dart';
import '../../core/ime_guard.dart';
import '../../core/platform_adapter.dart';
import '../../core/platform_style.dart';
import '../../core/screen_probe.dart';
import '../../core/verify_gate.dart';
import '../../data/douyin_api.dart';
import '../../data/models.dart';
import '../../data/video_cache.dart';
import '../author/author_page.dart';
import '../comments/comment_panel.dart';
import '../login/login_page.dart';
import 'debug_overlay.dart';

/// 播放页：布局对齐网页版抖音。
///
/// 主区视频 + 右侧竖排互动栏 + 左下信息区 + 底部控制条 + 右侧评论抽屉。
/// 所有数据都来自已经拿到的 AwemeItem，不做假数据填充。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.api,
    required this.items,
    required this.initialIndex,
    this.onLoadMore,
  });

  final DouyinApi api;

  /// 与首页共享的可增长列表：播放页刷到尾部前，通过 [onLoadMore]
  /// 异步拉下一批追加进来，不影响当前播放。
  final List<AwemeItem> items;
  final int initialIndex;

  /// 拉取下一批推荐流，返回新增条数（0 表示没有更多）。
  final Future<int> Function()? onLoadMore;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  late Player _player;
  late final VideoController _video;
  late int _index;

  /// 上下切换动画：新画面从下方/上方滑入，旧画面反方向滑出。
  /// 240ms，落在需求要求的 200~260ms 区间；打断时直接重置到 0 再前进，
  /// 不会出现"动画排队"或多张画面叠加。
  late final AnimationController _slideCtrl;

  /// 切换瞬间抓取的旧画面快照（滑出层用）。null 表示没有可滑出的旧画面，
  /// 此时切换只做新画面的淡入 + 轻推，不出现空白层。
  ui.Image? _outgoingFrame;

  /// +1 = 切到下一条（旧画面向上滑出、新画面自下滑入）；-1 = 上一条。
  int _slideDir = 1;

  /// 视频画面自己的 RepaintBoundary：切换前抓一张旧帧，供滑出动画使用。
  final GlobalKey _videoBoundaryKey = GlobalKey(debugLabel: 'video-frame');

  /// 加载硬超时：首帧迟迟不来时给出可读原因 + 重试按钮，而不是一直转圈。
  Timer? _loadDeadlineTimer;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<String> _logs = [];

  bool _showComments = false;

  /// 评论抽屉当前停留的 tab：换视频 / 重新打开抽屉时保留位置，
  /// X 键据此决定"切回评论"还是"关抽屉"。
  int _commentTab = kDrawerTabComments;
  final CommentPanelController _commentPanel = CommentPanelController();

  bool _showDebug = false;
  bool _hardware = true;

  /// 当前这条视频实际走了软解（请求了硬解但 mpv 回落）。
  /// 只用于界面显示，不影响 [_hardware] 的"意图"——下一条视频仍会先试硬解。
  bool _hwSoftwareFallback = false;

  /// 本次运行是否已经提示过"硬解不可用已自动软解"，避免每条视频都弹一次。
  bool _hwFallbackNotified = false;

  /// 本次运行已经因为硬解失败自动降到了软件解码：后续视频不再尝试硬解，
  /// 否则每条视频都要失败一次、白等一轮重开。
  bool _hwAutoFallbackActive = false;

  /// 降级流程正在执行（防重入）。
  bool _hwFallbackInProgress = false;

  /// media_kit 渲染层是否走硬件加速。一级降级只关 mpv 的 hwdec，
  /// 二级降级（软解仍然黑屏）会连渲染层加速一起关掉再重建播放器。
  bool _renderHwAccel = true;

  bool _playing = false;
  bool _muted = false;

  /// 自测用：DOUYIN_MUTE=1 时整个播放过程都不出声（离屏验证时不打扰用户）。
  final bool _forceMute = Platform.environment['DOUYIN_MUTE'] == '1';
  bool _autoNext = false;
  bool _danmakuOn = false;
  bool _uiHidden = false;
  bool _fullscreen = false;
  bool _opening = false;
  bool _switching = false;

  /// 首帧到达后撤掉加载遮罩的延时器；切换时重置。
  Timer? _firstFrameTimer;

  /// 滚轮累计增量：一次滚轮/触控板手势会被拆成多个事件，
  /// 只有累计超过阈值才切一条，避免"滚一下连切好几条"。
  double _scrollAccum = 0;
  DateTime _lastSwitchAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastScrollEventAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 单次滚轮触发的累计阈值。Windows 一格滚轮在 Flutter 里通常是 40~60，
   /// 取 45 让"一格 = 一条"；触摸板的小增量需要累积到 45 才会切，
   /// 这样细小抖动不足以构成一次切换。
  static const double _scrollThreshold = 45.0;

  /// 单个滚轮事件最多贡献多少增量：触控板惯性尾巴常有 100+ 的尖峰，
  /// 超出部分直接丢弃，避免"一记惯性把好几条一起滚过去"。
  static const double _scrollEventClamp = 45.0;

  /// 手势静默间隔：超过这个时间没有新的滚轮事件，就认为上一次手势已结束，
  /// 累计值清零。防止"分几次慢慢滚"的残留增量突然凑够阈值造成误切。
  static const Duration _scrollGestureGap = Duration(milliseconds: 200);

  /// 切换冷却（滚轮）：一次切换后这段时间内的滚轮事件全部丢弃、不排队。
  /// 落在需求要求的 350~450ms 区间；长划仍能继续切，但节奏被压到
  /// 每 380ms 最多一条，不会出现"划一下跳过五六条"。
  static const Duration _switchCooldown = Duration(milliseconds: 380);

  /// 键盘 / 按钮的极短防抖：只防同一次按键重复触发，按下去就能立刻打断上一段动画。
  static const Duration _keySwitchGap = Duration(milliseconds: 100);

  /// 首条/末条的回弹反馈：越界时不硬切、不空转，画面轻推一下再弹回。
  late final AnimationController _bounceCtrl;
  int _bounceDir = 0;

  /// 滑动动画与回弹动画合在一个可监听对象里，AnimatedBuilder 只需订阅一次。
  late final Listenable _animListenable;

  // ---------------------------------------------------------- 清晰度

  /// 当前作品接口实际返回的档位（按高度升序）。
  List<VideoVariant> _variants = const [];

  /// 用户偏好：`auto` 或某个档位标签。持久化，下次启动沿用。
  String _qualityPref = 'auto';

  /// 内存保护上限：任何自动/偏好档位都不会超过这一档（见 [_pickVariant]）。
  static const String _memoryQualityCap = '1080P';

  /// 当前实际生效的档位标签；空串表示未知（界面只显示"自动"，不猜）。
  String _activeQuality = '';
  static const String _qualityPrefKey = 'douyin_quality_pref';

  /// 自动下调的冷却与计时器，避免抖动式反复切档。
  DateTime _lastDowngradeAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _bufferTimer;

  bool _mpvConfigured = false;
  int _recycleEvery = 0;
  int _openedSinceRecycle = 0;
  String? _playError;

  /// 当前媒体是否已播到结尾：mpv 在结尾后会卸载轨道，此时再 seek 会报
  /// “error running command _command(seek)”。拖动/跳末尾前先重新打开当前条。
  bool _completed = false;

  /// 重试次数：只用于自测坏地址时"第一次失败、重试恢复真实地址"的判定。
  int _retryCount = 0;
  final bool _badUrlTest =
      Platform.environment['DOUYIN_BAD_URL_TEST'] == '1';

  /// 预加载：快刷到列表尾部时后台拉下一批，避免到最后一个才提示"已结束"。
  bool _prefetching = false;
  bool _noMoreItems = false;
  static const int _prefetchThreshold = 4;

  // ------------------------------------------------------- 视频预缓存（磁盘）

  /// 视频预缓存：把后续作品提前落盘，命中时直接本地播放（秒开 + 可拖进度）。
  /// 全局共享实例：进出播放页不会重建索引，已完成条目跨页面复用。
  final VideoCache _cache = VideoCache.shared;

  /// 当前缓存策略，来自全局设置；设置页改动后无需重启即可切换。
  CacheMode _cacheMode = CacheMode.disk;

  /// 磁盘缓存是否启用（[CacheMode.off] 时关闭）。
  bool _cacheEnabled = true;
  final bool _cacheTestHook = Platform.environment['DOUYIN_SEEK_TEST'] == '1';

  /// 预取条数：默认只往后预取 2 条（当前 +1 / +2）。
  ///
  /// 需求：只看前方，不回头。在 i5-8250U + 16G 的机器上，多下一条就是
  /// 多一份带宽、磁盘写入和页面缓存压力，2 条足够覆盖正常滑动节奏。
  int _cacheAhead = 2;

  /// 当前播放的本地文件路径（null = 在线播放，不可 seek）。
  String? _localPath;

  /// 当前作品的缓存已完成、随时可以切过去（拖动时用）。
  String? _readyLocalPath;

  /// 当前作品对应的缓存坐标，拖动/切换时复用。
  int _currentCacheHeight = 720;

  /// 下一次 open 强制使用的本地文件（拖动时“切本地 + seek”用）。
  String? _forceLocalForNextOpen;

  /// 拖动被延后：等缓存完成后自动跳到目标位置。
  Duration? _pendingLocalSeek;

  double _volume = 100;

  // 点赞 / 收藏：状态以服务端为准，点击时乐观更新，失败回滚并提示原因。
  bool _liked = false;
  bool _collected = false;
  int _diggCount = 0;
  int _collectCount = 0;
  bool _diggBusy = false;
  bool _collectBusy = false;

  /// 首帧上屏前暂存的音量：>0 表示当前处于"打开静音"状态，
  /// 等首帧确认上屏（加载遮罩开始淡出）后恢复，避免声音先于画面。
  double _pendingUnmuteVolume = 0;

  /// 首帧是否已经确认上屏（用来保证一次打开只恢复一次音量）。
  bool _firstFrameShown = false;

  /// 打开代数：快速连续切换时，上一轮的"等首帧"协程必须自动退出，
  /// 否则它会拿旧媒体的 pts 误判成新视频已出帧。
  int _openGeneration = 0;

  /// 逐帧取证：设置 DOUYIN_AVTRACE=1 时把 vo-configured / video-pts /
  /// audio-pts / volume 高频写进 diag 日志，用来核对"声音与画面谁先出现"。
  final bool _avTrace = Platform.environment['DOUYIN_AVTRACE'] == '1';
  double _speed = 1.0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration? _dragValue;

  /// 上一次真正触发 UI 刷新的播放位置：用于把 position 回调节流到 ~150ms。
  Duration _lastUiPosition = Duration.zero;

  bool _controlsVisible = true;
  bool _forceControls = false;
  Timer? _hideTimer;
  Timer? _propertyTimer;

  String _hwdecCurrent = '—';
  String _codec = '—';
  String _resolution = '—';
  String _frameRate = '—';

  /// mpv 日志合批：日志先进这里，最多每 500ms 刷新一次 UI。
  /// 目的是切断"libmpv 内部重试日志 → Flutter 整页重绘"的放大链路。
  final List<String> _pendingLogs = [];
  Timer? _logFlushTimer;

  AwemeItem get _current => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);

    // 先读全局设置：解码方式与缓存策略决定播放器怎么初始化，
    // 必须在 _initPlayer() / 首次 open 之前生效。
    final settings = AppSettings.instance;
    _cacheMode = settings.cacheMode;
    _hardware = settings.hardwareEnabled;
    // 音量沿用上次设置：返回主页再进播放页不能又跳回最大音量。
    _volume = settings.volume;
    if (_volume <= 0) _muted = true;
    // 自测钩子：DOUYIN_CACHE_MODE=disk|off 临时覆盖缓存策略。
    final envCacheMode = Platform.environment['DOUYIN_CACHE_MODE'];
    if (envCacheMode != null && envCacheMode.isNotEmpty) {
      _cacheMode = envCacheMode == 'off' ? CacheMode.off : CacheMode.disk;
    }
    settings.addListener(_onSettingsChanged);

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..value = 1.0;
    _bounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..value = 0.0;
    _animListenable = Listenable.merge([_slideCtrl, _bounceCtrl]);
    _slideCtrl.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      // 动画结束：旧画面快照用完即丢，避免一直占显存。
      final old = _outgoingFrame;
      if (old == null) return;
      if (mounted) {
        setState(() => _outgoingFrame = null);
      } else {
        _outgoingFrame = null;
      }
      old.dispose();
    });

    _initPlayer();

    // 磁盘预缓存：只往后预取 2 条（当前 +1/+2），不回头缓存已看过的。
    // 全部可用环境变量覆盖，离屏自测时用来把缓存目录指到临时目录。
    _cacheEnabled =
        _cacheMode == CacheMode.disk && Platform.environment['DOUYIN_CACHE'] != '0';
    final ahead =
        int.tryParse(Platform.environment['DOUYIN_CACHE_ITEMS'] ?? '') ?? 2;
    _cacheAhead = ahead.clamp(1, 4);
    final envMaxMB =
        int.tryParse(Platform.environment['DOUYIN_CACHE_MAX_MB'] ?? '');
    final limitBytes =
        envMaxMB != null && envMaxMB > 0 ? envMaxMB * 1048576 : settings.cacheLimitBytes;
    _cache.setMaxBytes(limitBytes);
    diag('cache', '缓存上限 ${(limitBytes / 1048576).toStringAsFixed(0)}MB，'
        '预取下 $ahead 条，串行预取');
    if (_cacheEnabled) {
      unawaited(_cache.init());
    } else if (_cacheMode == CacheMode.disk) {
      diag('cache', 'DOUYIN_CACHE=0：磁盘预缓存关闭，全部在线播放');
    }
    unawaited(_loadQualityPref());

    // 常开轮询变成按需轮询：只有调试面板打开时才定时读 mpv 属性，
    // 避免"调试面板关着也每秒一次 setState + mpv 属性请求"。
    // 每秒读 15+ 个 mpv 属性 + setState 整页重绘，在 Intel UHD 620 上
    // 也是 GPU 占用的来源之一。
    if (_showDebug) {
      _propertyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _readProperties();
      });
    }

    _installTestHooks();
    _resetHideTimer();
    _openCurrent();
    // 进入播放页就先看一眼：如果当前索引已经靠近列表尾部，立刻后台预取。
    unawaited(_prefetchIfNeeded());
  }

  /// 创建（或重建）播放器与视频输出，并把所有流订阅挂到当前实例上。
  /// 重建时旧实例会先 dispose，让 mpv 句柄、解码上下文、VideoOutput 纹理一起释放。
  void _initPlayer() {
    _player = Player();
    _video = VideoController(
      _player,
      // 关键：**不要**传 width/height。
      //
      // media_kit 的语义是：width/height 一旦给了，原生纹理就固定按这个
      // 尺寸出帧（VideoOutput.videoSize 直接返回 width/height，不再看视频
      // 自己的 dw/dh）。之前固定 1280x720 带来两个连锁问题：
      //   1. 竖屏视频（9:16）被塞进 16:9 的纹理，libmpv 只能在纹理内部
      //      左右补黑 → 黑边被"烤"进纹理，Flutter 侧再怎么 contain 都去不掉，
      //      表现就是"视频两边有黑块"；
      //   2. 窗口尺寸变化时纹理和窗口纵横比进一步错位，只能靠重建播放器
      //      去纠正 → 重建期间黑屏/卡住 = "全屏和调窗口后卡顿"。
      //
      // 不传时原生按视频本身的 dw/dh 出纹理，Flutter 侧 `Video` 的
      // FittedBox(BoxFit.contain) 负责缩放到窗口，天然自适应、无黑块，
      // 且**窗口怎么缩放都不需要重建播放器**。
      // enableHardwareAcceleration 是渲染层（纹理/GPU 拷贝）的开关，
      // 与 mpv 的 hwdec 不是一回事：某些机器解码能软解、但纹理硬件加速失败，
      // 表现为黑屏+报错，二级降级就靠关掉它来恢复画面。
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: _renderHwAccel,
      ),
    );
    _mpvConfigured = false;
    // 换播放器实例后解码器会重建，软解标记先复位，等首帧后再判定。
    _hwSoftwareFallback = false;

    _subscriptions.add(_player.stream.log.listen((event) {
      diag('mpv', '${event.level}: ${event.text}');
      if (!mounted) return;
      // 关键性能点：**不要每条 mpv 日志都 setState**。
      //
      // 原实现是收到日志就 setState 刷新 _logs，等于让 libmpv 的内部重试
      // （osc / file cache 这类每秒几十次的失败日志）驱动 Flutter 整页重绘。
      // 在 Intel UHD 620 上这是 GPU 占用的主要来源之一。
      // 现在：日志照旧进 diag 落盘，但只有在调试面板真的打开时才更新 UI，
      // 并且合并到最多每 500ms 一次。
      if (!_showDebug) return;
      _pendingLogs.add('[${event.level}] ${event.text}');
      _logFlushTimer ??= Timer(const Duration(milliseconds: 500), () {
        _logFlushTimer = null;
        if (!mounted || _pendingLogs.isEmpty) return;
        final batch = List<String>.from(_pendingLogs);
        _pendingLogs.clear();
        setState(() {
          _logs.addAll(batch);
          if (_logs.length > 24) _logs.removeRange(0, _logs.length - 24);
        });
      });
    }));
    _subscriptions.add(_player.stream.error.listen((event) {
      diag('mpv-error', event);
      // 在线流（seekable=0）的 seek 失败会以错误事件抛出，原文是
      // “You can force it with '--force-seekable=yes'.”。
      // 我们不能把这句话甩给用户，也不该让它挡住播放：吞掉即可，
      // 真正的拖动入口 _seekTo 已经保证在线不走 seek。
      final lower = event.toLowerCase();
      if (lower.contains('seek')) {
        diag('seek', '忽略在线 seek 错误（已改为本地缓存后 seek）：$event');
        return;
      }
      // 硬解相关的错误不能直接弹给用户：先记日志，再静默降级到软解并重开。
      // 成功的话用户只会看到画面，外加一条"已自动切换为软件解码"的提示。
      // 这是"这台机器硬解失败只弹错误、没有自动切 CPU 解码"的修复点。
      if (_isHardwareRelated(event) && (_hardware || _renderHwAccel)) {
        diag('hwdec', 'mpv 报出硬解相关错误，转自动降级：$event');
        if (mounted) {
          setState(() {
            _logs.add('[hwdec] $event');
            if (_logs.length > 24) _logs.removeRange(0, _logs.length - 24);
          });
        }
        unawaited(_handleHardwareErrorEvent(event));
        return;
      }
      if (!mounted) return;
      // 同样不要每条错误都整页重绘：错误文案只在不重复时才 setState。
      final message = ErrorText.play(event);
      final line = '[error] $event';
      if (_playError == message && _logs.isNotEmpty && _logs.last == line) return;
      setState(() {
        // 界面上只显示中文：mpv / libavformat 给的是英文原文，
        // 统一翻成可读的原因；原文仍然进 _logs 与 diag 供排障。
        _playError = message;
        _logs.add(line);
        if (_logs.length > 24) _logs.removeRange(0, _logs.length - 24);
      });
    }));
    _subscriptions.add(_player.stream.position.listen((p) {
      if (!mounted) return;
      // 性能要点（i5-8250U / UHD 620）：position 回调频率跟着 mpv 的属性
      // 刷新走，一秒可能十几次。每次都 setState 等于整棵播放页重建十几次，
      // 而这些重建里唯一要变的只是控制条上的时间文字与进度条。
      // 这里把 UI 刷新节流到 ~150ms（肉眼仍然连续），但 _position 本身
      // 始终更新为最新值，seek / 缓存补跳等逻辑读到的都是准确位置。
      _position = p;
      final delta = (p - _lastUiPosition).inMilliseconds.abs();
      if (delta < 150) return;
      _lastUiPosition = p;
      setState(() {});
    }));
    _subscriptions.add(_player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    }));
    // 自动清晰度：持续缓冲说明当前档位吃紧，稳定 1.5s 后降一档。
    _subscriptions.add(_player.stream.buffering.listen((b) {
      if (!mounted) return;
      if (b) {
        _bufferTimer ??= Timer(const Duration(milliseconds: 1500), () {
          _bufferTimer = null;
          _autoDowngrade();
        });
      } else {
        _bufferTimer?.cancel();
        _bufferTimer = null;
      }
    }));

    _subscriptions.add(_player.stream.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
      // 注意：这里**不能**恢复音量。media_kit 的 playing 事件只代表 pause
      // 被置为 false，此时视频首帧往往还没解码/提交到纹理，提前恢复音量
      // 就是"黑屏先出声"的直接原因。首帧判定统一交给
      // _awaitFirstFrameThenUnmute（vo-configured + video-pts 前进）。
    }));
    _subscriptions.add(_player.stream.completed.listen((done) {
      if (!mounted || !done) return;
      _completed = true;
      diag('player', '播放结束 aweme=${_current.id} autoNext=$_autoNext');
      if (_autoNext) _switchVideo(1);
    }));
  }

  /// 窗口尺寸变化**不再重建视频输出**。
  ///
  /// 历史包袱：早期为了"纹理跟着窗口尺寸走"，在这里监听 LayoutBuilder 的
  /// constraints，去抖后 `_recyclePlayer()` + 重新 open 媒体。实测在
  /// i5-8250U / UHD 620 上这套逻辑是纯负担：
  ///   * 每次重建都要销毁 Player → 释放纹理/EGL → 新建 → 重新解封装，
  ///     这几百毫秒里画面是黑的，用户感知就是"全屏/调窗口后卡顿"；
  ///   * 而且重建换来的纹理尺寸仍然和窗口纵横比不一致，黑边照旧。
  ///
  /// 真正的解法是让纹理保持视频原始尺寸，由 `Video` 组件的
  /// FittedBox(BoxFit.contain) 做展示层缩放——GPU 采样一次即可，
  /// 窗口拖多大都不需要碰播放器。所以这套 resize 机制整体移除。
  ///
  /// 保留 [_recyclePlayer] 本身：内存回收自测钩子（DOUYIN_RECYCLE_EVERY）
  /// 与硬解失败降级还会用到它。
  Future<void> _recyclePlayer() async {
    final old = _player;
    _subscriptions.forEach((s) => s.cancel());
    _subscriptions.clear();
    if (mounted) {
      setState(() {
        _playing = false;
        _position = Duration.zero;
        _duration = Duration.zero;
      });
    }
    try {
      // Player.dispose 会连带释放 VideoController（VideoOutput/纹理/EGL）。
      await old.dispose();
    } catch (e) {
      diag('player', '释放旧播放器失败: $e');
    }
    if (!mounted) return;
    _initPlayer();
    _pendingUnmuteVolume = 0;
    // 新实例默认音量 100，把用户当前音量重新应用，避免重建后声音突然变响。
    _player.setVolume(_volume);
    setState(() {});
    diag('player',
        'recycle 完成 rss=${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1)}MB');
  }

  /// 自测钩子（仅由环境变量触发，正常运行不生效）：
  ///   DOUYIN_OPEN_COMMENTS=1  启动即打开评论抽屉
  ///   DOUYIN_SWITCH_EVERY=5   每 5 秒切到下一条（做切换压力测试）
  void _installTestHooks() {
    final env = Platform.environment;
    if (env['DOUYIN_FORCE_CONTROLS'] == '1') _forceControls = true;
    if (env['DOUYIN_NO_AUTONEXT'] == '1') _autoNext = false;
    final recycle = int.tryParse(env['DOUYIN_RECYCLE_EVERY'] ?? '');
    if (recycle != null && recycle > 0) _recycleEvery = recycle;
    if (env['DOUYIN_HWDEC'] == 'no') _hardware = false;
    // 自测：DOUYIN_SHOW_DEBUG=1 启动即显示解码/缓存浮层（离屏截图核对用）。
    if (env['DOUYIN_SHOW_DEBUG'] == '1') _showDebug = true;
    if (env['DOUYIN_OPEN_COMMENTS'] == '1') {
      _showComments = true;
    }
    final every = int.tryParse(env['DOUYIN_SWITCH_EVERY'] ?? '');
    if (every != null && every > 0) {
      Timer.periodic(Duration(seconds: every), (_) {
        if (!mounted) return;
        if (_index >= widget.items.length - 1) {
          _index = 0;
          _openCurrent();
        } else {
          _switchVideo(1);
        }
      });
    }
    final memLog = env['DOUYIN_MEMLOG'] == '1';
    if (memLog) {
      Timer.periodic(const Duration(seconds: 5), (_) {
        diag(
            'mem',
            'rss=${(ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1)}MB '
            'maxRss=${(ProcessInfo.maxRss / 1024 / 1024).toStringAsFixed(1)}MB '
            'idx=$_index playing=$_playing pos=${_position.inSeconds}s');
      });
    }
    // 抽屉开关压力测试：DOUYIN_TOGGLE_DRAWER=20 表示来回开关 20 次。
    final toggleTimes = int.tryParse(env['DOUYIN_TOGGLE_DRAWER'] ?? '');
    if (toggleTimes != null && toggleTimes > 0) {
      var done = 0;
      Timer.periodic(const Duration(milliseconds: 800), (t) {
        if (!mounted) return;
        if (done >= toggleTimes * 2) {
          diag('hooks',
              '抽屉开关完成 $toggleTimes 次 rss=${(ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1)}MB');
          t.cancel();
          return;
        }
        setState(() => _showComments = !_showComments);
        done++;
      });
    }
    // 离屏滚轮回归：直接注入模拟滚轮事件，不碰系统鼠标、不抢焦点。
    if (env['DOUYIN_WHEEL_TEST'] == '1') unawaited(_runWheelTest());
    // 拖动回归：DOUYIN_SEEK_TEST=1 时先在线拖（缓存未完成），再拖到末尾。
    if (_cacheTestHook) unawaited(_runSeekTest());
    // 命中率回归：DOUYIN_CACHE_HIT_TEST=1 时前进 3 条再回退 3 条。
    if (env['DOUYIN_CACHE_HIT_TEST'] == '1') unawaited(_runCacheHitTest());
    // 坏地址自测：等错误浮层真的出现后自动点一次"重试"，验证重试重走 open。
    // 轮询而不是定时：坏地址 1~2 秒就报错，而"连上但不出帧"要等 15 秒超时。
    if (_badUrlTest) {
      unawaited(() async {
        for (var i = 0; i < 44 && mounted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (_playError != null) break;
        }
        if (!mounted || _retryCount > 0) return;
        if (_playError == null) {
          diag('hooks', 'BAD_URL_TEST：22 秒内仍无错误浮层（异常）');
          return;
        }
        diag('hooks',
            'BAD_URL_TEST：错误浮层已显示，内容=「$_playError」，自动点重试');
        _retry();
      }());
    }
  }

  /// 滚轮阻尼自测（DOUYIN_WHEEL_TEST=1）。
  ///
  /// 每个场景注入一串"和真实设备同量级"的 delta，然后统计这一串事件
  /// 实际切了几条。日志标签 `[wheel-test]`，用于回答
  /// "一次滚动切几条 / 冷却期是否生效 / 惯性尾巴是否误触发"。
  Future<void> _runWheelTest() async {
    Future<void> scene(String name, List<double> deltas, int gapMs) async {
      if (!mounted) return;
      // 场景前留足冷却时间（380ms 冷却 + 余量），避免上一场景的余温干扰。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final before = _index;
      for (final d in deltas) {
        if (!mounted) return;
        _onScroll(d);
        if (gapMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: gapMs));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final switched = _index - before;
      diag('wheel-test',
          '$name：事件=${deltas.length} 间隔=${gapMs}ms 实际切换=$switched 条 '
          '(items=${widget.items.length})');
    }

    // 等首条视频稳定出画，避免和开播抢资源。
    await Future<void>.delayed(const Duration(milliseconds: 2800));

    await scene('①单格滚轮', [53], 0);
    await scene('②双格快滚', [53, 53], 25);
    await scene('③三格连滚', [53, 53, 53], 30);
    await scene('④触控板长划(8x30)', List<double>.filled(30, 8.0), 16);
    await scene('⑤惯性尾巴(30,12,10,8,6,4,3,2)', [30, 12, 10, 8, 6, 4, 3, 2], 16);
    await scene('⑥持续长划(20x40)', List<double>.filled(40, 20.0), 25);

    // 首条边界回弹：先回到第一条，再向下猛拉 3 次。
    if (!mounted) return;
    if (_index != 0) {
      setState(() => _index = 0);
      await _openCurrent();
      await Future<void>.delayed(const Duration(milliseconds: 1800));
    }
    final b0 = _index;
    var bounced = false;
    for (var i = 0; i < 3; i++) {
      _onScroll(-53);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      bounced = bounced || _bounceCtrl.isAnimating;
    }
    await Future<void>.delayed(const Duration(milliseconds: 900));
    diag('wheel-test',
        '⑦首条越界回弹：事件=3 实际切换=${_index - b0} 条（应为 0） '
        '回弹动画=$bounced');
    diag('wheel-test', '滚轮回归结束');
  }

  /// 拖动回归（DOUYIN_SEEK_TEST=1）：
  ///  阶段 1：缓存还没完成时在第 4 秒直接拖到 90%，应“给提示 + 延后补跳”，不报错；
  ///  阶段 2：缓存完成后拖到末尾前 1 秒，应走本地 seek，正常落位且无错误浮层。
  Future<void> _runSeekTest() async {
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    final d = _duration;
    if (d <= Duration.zero) {
      diag('seek-test', '还没拿到时长，跳过（duration=0）');
      return;
    }
    final p90 = Duration(milliseconds: (d.inMilliseconds * 0.9).round());
    diag('seek-test',
        '阶段1 在线拖动 → 90%（${p90.inMilliseconds}ms，本地=${_localPath != null}）');
    _seekTo(p90);

    // 等自动补跳：本地文件就绪（_localPath 有值）即代表已切本地并 seek。
    // 短视频通常 1~2 秒；长视频（十几分钟、几百 MB）需要更久，最多等 45 秒，
    // 不能用一个固定等待把长视频判成失败。
    for (var i = 0; i < 90 && mounted && _localPath == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    diag('seek-test',
        '阶段1 结束：pos=${_position.inMilliseconds}ms 本地=${_localPath != null} '
        '错误=${_playError ?? "无"}');

    final end = Duration(milliseconds: math.max(0, d.inMilliseconds - 1000));
    diag('seek-test',
        '阶段2 拖到末尾前 1 秒（${end.inMilliseconds}ms，本地=${_localPath != null}）');
    _seekTo(end);
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    diag('seek-test',
        '阶段2 结束：pos=${_position.inMilliseconds}ms 本地=${_localPath != null} '
        '错误=${_playError ?? "无"}');
    diag('seek-test', await _cache.statsLine());
  }

  /// 预取命中率回归（DOUYIN_CACHE_HIT_TEST=1）：
  /// 前进 3 条（每条留 14 秒给后台缓存），再回退 3 条；
  /// 回退时应全部命中本地缓存（本地文件可 seek）。
  Future<void> _runCacheHitTest() async {
    await Future<void>.delayed(const Duration(seconds: 6));
    final hit0 = _cache.hitCount;
    final miss0 = _cache.missCount;
    for (var i = 0; i < 3; i++) {
      if (!mounted) return;
      _switchVideo(1, keyboard: true);
      await Future<void>.delayed(const Duration(seconds: 14));
    }
    final forwardHits = _cache.hitCount - hit0;
    final forwardMiss = _cache.missCount - miss0;
    diag('cache-hit-test',
        '前进 3 条：命中 $forwardHits 次 / 未命中 $forwardMiss 次');

    final backHit0 = _cache.hitCount;
    final backMiss0 = _cache.missCount;
    for (var i = 0; i < 3; i++) {
      if (!mounted) return;
      _switchVideo(-1, keyboard: true);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    diag('cache-hit-test',
        '回退 3 条：命中 ${_cache.hitCount - backHit0} 次 / '
        '未命中 ${_cache.missCount - backMiss0} 次 '
        '（回退应全部命中）');
    diag('cache-hit-test', await _cache.statsLine());
    diag('cache-hit-test', '命中率回归结束');
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    if (_forceControls) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  /// 只设置一次：这些都是 mpv 全局选项，反复设置会让 mpv 重建 vo/解码链。
  Future<void> _configureMpvOnce() async {
    if (_mpvConfigured) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      // 机上有多个虚拟显示适配器时，mpv 默认挑到的 D3D11 设备可能建不起来
      // （日志里表现为 "Could not create device" 后回落软解），可用环境变量
      // 指定适配器名（如 Intel / NVIDIA）来验证或规避。
      final adapter = Platform.environment['DOUYIN_D3D11_ADAPTER'];
      if (adapter != null && adapter.isNotEmpty) {
        await platform.setProperty('d3d11-adapter', adapter);
        diag('mpv', 'd3d11-adapter=$adapter');
      }
      final override = Platform.environment['DOUYIN_HWDEC'];
      final requested = (override != null && override.isNotEmpty)
          ? override
          : (_hardware ? PlatformAdapter.preferredHwdec : 'no');
      await platform.setProperty('hwdec', requested);
      // 立刻回读：async 设置失败时这里会原样返回旧值，便于区分
      // "没下发成功"和"下发了但 mpv 内部回退到软解"。
      final applied = await platform.getProperty('hwdec');
      diag('mpv', 'hwdec 下发=$requested 回读=$applied');
      final mpvLog = Platform.environment['DOUYIN_MPVLOG'];
      if (mpvLog != null && mpvLog.isNotEmpty) {
        try {
          await platform.setProperty('log-file', mpvLog);
        } catch (e) {
          diag('mpv', '设置 log-file 失败: $e');
        }
      }
      // 不要手动设 vo：media_kit_video 的 VideoOutput 会把 vo 设为 `libmpv`
      // （走 libmpv render API 渲染到 Flutter texture）。覆盖成 `gpu` 会让 mpv
      // 自建一个独立播放窗口，同时 Flutter 里的 Video 收不到帧（黑屏）。
      await platform.setProperty('keep-open', 'no');
      await platform.setProperty('user-agent', PlatformAdapter.userAgent);
      await platform.setProperty('referrer', 'https://www.douyin.com/');

      // ---- 压制 mpv 内部噪音（Intel 核显 / 沙盒环境尤甚）----
      //
      // 现场表现：调试面板里反复刷
      //   [error] error: property not found _setProperty(osc, 1)
      //   [error] Failed to create file cache.
      // 前者是 libmpv 内部想把 on-screen controller 打开（我们根本不用它的
      // OSC，控制条全是 Flutter 自己画的），每帧都试着设一次、每帧都失败；
      // 后者是 media_kit 默认下发 `cache-on-disk=yes`，而 macOS 沙盒里
      // 那个缓存路径不可写，于是不停重试不停报错。
      // 两者都会走 stream.log → setState，等于**每秒多次触发整页重绘**，
      // 在 UHD 620 这种核显上就是实打实的 GPU 占用。
      try {
        await platform.setProperty('osc', 'no');
        await platform.setProperty('osd-level', '0');
        await platform.setProperty('osd-bar', 'no');
      } catch (e) {
        diag('mpv', '关闭 osc/osd 失败: $e');
      }
      // macOS 沙盒内 disk cache 必然失败：直接关掉，别再让它反复重试。
      if (Platform.isMacOS) {
        try {
          await platform.setProperty('cache-on-disk', 'no');
        } catch (e) {
          diag('mpv', '关闭 cache-on-disk 失败: $e');
        }
      }
      // 把 mpv 日志级别压到 fatal：debug/warn 级别的重试噪音不再进入
      // stream.log，从源头掐掉"每条日志一次 setState"的重绘风暴。
      // 真需要排障时用环境变量放开（DOUYIN_MPV_VERBOSE=1）。
      if (Platform.environment['DOUYIN_MPV_VERBOSE'] != '1') {
        try {
          await platform.setProperty('msg-level', 'all=fatal');
        } catch (e) {
          diag('mpv', '设置 msg-level 失败: $e');
        }
      }
      // 缓冲必须保留：抖音是 fragmented mp4，解析 moov/索引时 ffmpeg 会尝试
      // seek，cache=no / readahead=0 会让部分视频直接 "Failed to open"。
      // 这里取中间值：16MB / 8MB / 3 秒，既比默认小一半，也不破坏可播性。
      await platform.setProperty('cache', 'yes');
      await platform.setProperty('demuxer-max-bytes', '16777216');
      await platform.setProperty('demuxer-max-back-bytes', '8388608');
      await platform.setProperty('demuxer-readahead-secs', '3');
      try {
        await platform.setProperty('vd-lavc-threads', '2');
      } catch (e) {
        diag('mpv', '设置 vd-lavc-threads 失败: $e');
      }
      // 抖音 aweme/v1/play 的签名地址只接受不带 Range 的普通 GET：
      // 带 Range 会被服务端直接 404（实测 bytes=0-1023 → 404，无 Range → 200）。
      // 而 libavformat 的 http 默认会发 Range 探测，导致 mpv 报 "Failed to open"。
      // 关掉 seekable 后 ffmpeg 不再发 Range，代价是拖进度条会重新拉流。
      try {
        await platform.setProperty('stream-lavf-o', 'seekable=0');
        final lavfO = await platform.getProperty('stream-lavf-o');
        diag('mpv', 'stream-lavf-o=$lavfO（禁用 Range 探测，兼容抖音播放地址）');
      } catch (e) {
        diag('mpv', '设置 stream-lavf-o 失败: $e');
      }
      _mpvConfigured = true;
      diag('mpv', '全局属性已设置（缓存上限 16MB/8MB，解码线程=2，keep-open=no）');

      // 首帧问题：音频解码总是比视频首帧快（视频还要过 D3D11 解码 + 提交到
      // Flutter texture），默认行为下会出现"黑屏但声音先出来"。
      // 实测本机 libmpv 没有 audio-wait-for-video 这个运行时属性
      // （mpv 日志：Set property: audio-wait-for-video="yes" -> -3），
      // 所以真正的兜底是"打开后先静音，等首帧上屏再恢复音量"，见 _openCurrentInner。
      // 这里额外尝试 options/ 前缀（mpv 的选项在运行时可通过 options/<name> 修改），
      // 能设上就当第二道保险，设不上不影响播放。
      //   - video-sync=audio：音画以音频为主时钟，就绪后不会追赶跳帧；
      //   - force-window=no：libmpv 自己不开窗口（vo 由 media_kit_video 设为 libmpv）。
      // 单独 try：个别 mpv 构建若不认识某个属性能就地跳过，不影响上面的关键配置，
      // 同时把回读值落盘，避免"以为设了其实没设"。
      try {
        await platform.setProperty('options/audio-wait-for-video', 'yes');
        await platform.setProperty('video-sync', 'audio');
        await platform.setProperty('force-window', 'no');
        final aww = await platform.getProperty('audio-wait-for-video');
        final awwOpt =
            await platform.getProperty('options/audio-wait-for-video');
        final vs = await platform.getProperty('video-sync');
        final fw = await platform.getProperty('force-window');
        diag('mpv',
            '音画配置 回读 audio-wait-for-video=$aww options=$awwOpt '
            'video-sync=$vs force-window=$fw');
      } catch (e) {
        diag('mpv', '音画配置失败: $e');
      }
    } catch (e) {
      debugPrint('[Player] 设置 mpv 属性失败: $e');
    }
  }

  /// 每条视频打开前重新确认 `hwdec` 与用户意图一致。
  ///
  /// 目的：硬件解码**可用时必须用硬件解码**。mpv 的 `hwdec` 是全局属性，
  /// 正常不会被 loadfile 重置，但手动关过一次硬解、或某些后端在重建
  /// 解码链后会把值改回，都会导致后续视频静默走软解。这里便宜地回读一次，
  /// 不一致就重新下发，保证"能用硬解就用硬解"。
  Future<void> _syncHwdecRequest() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final want = _hardware ? PlatformAdapter.preferredHwdec : 'no';
    try {
      final current = (await platform.getProperty('hwdec')).trim();
      if (current == want) return;
      await platform.setProperty('hwdec', want);
      diag('hwdec', '重新下发 hwdec=$want（原=$current）');
    } catch (e) {
      diag('hwdec', '同步 hwdec 失败：$e');
    }
  }

  /// 首帧出来后核对"实际解码器"，落实两条规则：
  ///
  ///   1. 硬件解码可用 → 必须用硬件解码（不需要提示，正常行为）；
  ///   2. 硬件解码不可用 → 自动用软件解码（mpv 的 auto-safe 已经回落），
  ///      但**必须提示用户**，否则用户只会觉得"CPU 好高 / 画质怪"。
  ///
  /// 只在首帧确认后调用：此时解码器已经真正创建，`hwdec-current` 才有意义
  /// （播放开始前它可能是空或是上一次的视频的值）。
  Future<void> _verifyHardwareDecode(int gen) async {
    // 用户主动关掉硬解、或已经自动降级过：不再判定，也不再提示。
    if (!_hardware || _hwAutoFallbackActive) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;

    var requested = '';
    var current = '';
    // 属性在个别后端上有几十毫秒延迟，轮询几次再下结论。
    for (var attempt = 0; attempt < 6; attempt++) {
      if (!mounted || gen != _openGeneration) return;
      try {
        requested = (await platform.getProperty('hwdec')).trim();
        current = (await platform.getProperty('hwdec-current')).trim();
      } catch (e) {
        diag('hwdec', '读取解码器状态失败：$e');
        return;
      }
      // 请求本身就是软解（用户手动关闭 / 环境变量指定）：不提示。
      if (requested.isEmpty || requested == 'no') return;
      if (current.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (!mounted || gen != _openGeneration) return;

    // 状态未知时不下结论：宁可少提示一次，也不能把"还没读到"误报成"硬解失败"。
    final normalized = current.toLowerCase();
    if (normalized.isEmpty || normalized == 'auto-safe') {
      diag('hwdec',
          '解码器状态未知（请求=$requested 实际=${current.isEmpty ? "空" : current}），跳过判定');
      return;
    }

    if (PlatformAdapter.isHardwareDecoder(current)) {
      diag('hwdec', '硬解已生效 请求=$requested 实际=$current');
      if (_hwSoftwareFallback) setState(() => _hwSoftwareFallback = false);
      return;
    }

    // 走到这里说明：请求了硬解，但实际解码器不是硬解 → mpv 已自动回落到软解。
    diag('hwdec',
        '硬解不可用（请求=$requested 实际=${current.isEmpty ? "未知" : current}），'
        '已自动切换软解 aweme=${_current.id}');
    setState(() => _hwSoftwareFallback = true);
    if (_hwFallbackNotified) return; // 一次运行只提示一次，避免每条视频都弹
    _hwFallbackNotified = true;
    _toast('硬件解码不可用，已自动切换为软件解码');
  }

  /// mpv / libavformat 的错误文本是否与硬解（解码器或渲染）有关。
  ///
  /// 只对这类错误做自动降级：网络 403、地址失效、磁盘错误跟硬解无关，
  /// 盲目降级重开只会多等一轮，反而让用户更困惑。
  bool _isHardwareRelated(String text) {
    final t = text.toLowerCase();
    const markers = [
      'hwdec',
      'd3d11',
      'd3d11va',
      'dxva',
      'dxva2',
      'nvdec',
      'cuda',
      'nvcuda',
      'videotoolbox',
      'vaapi',
      'vdpau',
      'could not create device',
      'could not create the surfaces',
      'failed to initialize a decoder',
      'failed to initialize video',
      'hardware decoder',
      'no hardware decoder',
      // libavcodec 硬解失败的真实报错（本机实测就是这一串）：
      //   Failed to allocate AVHWDeviceContext.
      //   AVHWFramesContext: Could not create the surfaces
      //   h264: Failed setup for format dxva2_vld: hwaccel initialisation...
      'avhwdevicecontext',
      'avhwframescontext',
      'hwaccel',
      'libmpv_render',
      'opengl',
      'egl',
      'angle',
      'vo/gpu',
    ];
    return markers.any(t.contains);
  }

  /// 硬解相关的错误事件处理：先判断 mpv 有没有自己回落成功。
  ///
  /// 实测这台机器：mpv 会连报
  /// `Failed to allocate AVHWDeviceContext.` → `Could not create the surfaces`
  /// → `Failed setup for format dxva2_vld`，然后**自行**用软解把视频放出来。
  /// 旧逻辑把这些原文当成普通播放错误弹成红色浮层，用户看到的是
  /// "硬解失败+报错"，其实画面已经在软解下正常播放了。
  ///
  /// 现在：已经在软解播放的，不重开、不弹错，只固化状态并提示一次；
  /// 真的没播起来的，才走 [_fallbackToSoftware] 重开。
  Future<void> _handleHardwareErrorEvent(String event) async {
    if (!_hardware || _hwAutoFallbackActive) {
      // 已经是软解状态，这条错误没有展示意义，顺手把误弹的浮层清掉。
      if (mounted && _playError != null) setState(() => _playError = null);
      return;
    }
    // mpv 的回落是毫秒级的，稍等一下再判断，避免把"正在回落"误判成"播放失败"。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    final playing = _position.inMilliseconds > 0;
    var current = '';
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        current = (await platform.getProperty('hwdec-current')).trim();
      } catch (_) {}
    }
    final fellBack = playing &&
        current.isNotEmpty &&
        !PlatformAdapter.isHardwareDecoder(current);
    if (fellBack) {
      diag('hwdec',
          'mpv 已自行回落到软解且正在播放（current=$current），不重开，只固化状态');
      _hwAutoFallbackActive = true;
      _hwFallbackNotified = true;
      if (!mounted) return;
      setState(() {
        _hardware = false;
        _hwSoftwareFallback = true;
        _playError = null;
      });
      if (platform is NativePlayer) {
        try {
          await platform.setProperty('hwdec', 'no');
        } catch (e) {
          diag('hwdec', '固化 hwdec=no 失败：$e');
        }
      }
      _toast('硬件解码不可用，已自动切换为 CPU 软件解码');
      return;
    }
    await _fallbackToSoftware('mpv 错误：${event.trim()}');
  }

  /// 硬解失败后的自动降级（两级兜底）。
  ///
  /// 用户实测：这台机器上 mpv 尝试硬解时直接报错，界面弹出错误浮层、
  /// 画面不出，并没有自动用 CPU 解码。这里做真正的兜底：
  ///   ① 一级：`hwdec=no`，保留播放进度重开当前视频；
  ///   ② 二级：一级仍失败 → 重建播放器并关掉渲染层硬件加速。
  /// 每级只做一次（[_hwAutoFallbackActive] / [_renderHwAccel] 记录），
  /// 不会死循环；两次都失败才把错误交给用户。
  Future<void> _fallbackToSoftware(String reason) async {
    if (_hwFallbackInProgress) return;
    if (!_hardware && !_renderHwAccel) return; // 已经全软解，无级可降
    final stage2 = !_hardware;
    _hwFallbackInProgress = true;
    final pos = _position;
    diag('hwdec',
        '开始${stage2 ? "二级" : "一级"}降级（$reason），当前位置 ${pos.inMilliseconds}ms');
    try {
      if (!stage2) {
        _hwAutoFallbackActive = true;
        _hwFallbackNotified = true;
        if (mounted) {
          setState(() {
            _hardware = false;
            _hwSoftwareFallback = true;
            _playError = null; // 别让"硬解失败"的红色浮层挡住画面
          });
        }
        final platform = _player.platform;
        if (platform is NativePlayer) {
          try {
            await platform.setProperty('hwdec', 'no');
          } catch (e) {
            diag('hwdec', '一级降级设置 hwdec=no 失败：$e');
          }
        }
      } else {
        _renderHwAccel = false;
        if (mounted) setState(() => _playError = null);
        // 换渲染方式必须重建播放器与视频输出，光改属性不生效。
        await _recyclePlayer();
      }
      // 等当前 open 流程退出，避免两个 open 并发把 mpv 打到中间状态。
      for (var i = 0; i < 60 && _switching; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
      await _openCurrent(seekTo: pos > Duration.zero ? pos : null);
      _toast(stage2
          ? '硬件渲染不可用，已切换为软件渲染并重新播放'
          : '硬件解码不可用，已自动切换为 CPU 软件解码');
    } finally {
      _hwFallbackInProgress = false;
    }
  }

  /// 设置页改值后立刻生效：解码方式 / 缓存策略会重开当前视频，
  /// 缓存上限与清晰度这类不打断播放的原地调整即可。
  Future<void> _onSettingsChanged() async {
    if (!mounted) return;
    final settings = AppSettings.instance;
    final cacheModeChanged = settings.cacheMode != _cacheMode;
    final decodeChanged = settings.hardwareEnabled != _hardware;
    final limitChanged = settings.cacheLimitBytes != _cache.maxBytes;
    final qualityChanged = settings.qualityPref != _qualityPref;

    if (limitChanged) {
      // 上限改动不打断播放：新上限立刻生效，超限部分按 FIFO 当场清掉。
      _cache.setMaxBytes(settings.cacheLimitBytes);
      diag('settings', '缓存上限改为 ${settings.cacheLimitMB}MB');
    }
    if (cacheModeChanged) {
      setState(() {
        _cacheMode = settings.cacheMode;
        _cacheEnabled = _cacheMode == CacheMode.disk &&
            Platform.environment['DOUYIN_CACHE'] != '0';
      });
      if (_cacheEnabled) {
        unawaited(_cache.init());
      } else {
        // 关掉缓存：正在跑的预取也一并停掉，别在后台偷偷下。
        _cache.cancelExcept(const {});
      }
      diag('settings', '缓存模式切换为 ${_cacheMode.name}，重开当前视频');
      await _openCurrent();
      return;
    }
    if (qualityChanged) setState(() => _qualityPref = settings.qualityPref);
    if (!decodeChanged) return;

    setState(() {
      _hardware = settings.hardwareEnabled;
      _hwSoftwareFallback = false;
      // 用户主动开回硬解：清掉本次运行的降级标记，允许重新尝试。
      if (_hardware) {
        _hwAutoFallbackActive = false;
        _hwFallbackNotified = false;
      }
    });
    if (_hardware && !_renderHwAccel) {
      // 上次降到了软件渲染，现在用户要求硬解，必须重建播放器才能恢复。
      _renderHwAccel = true;
      await _recyclePlayer();
    }
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty(
            'hwdec', _hardware ? PlatformAdapter.preferredHwdec : 'no');
      } catch (e) {
        diag('hwdec', '按设置下发 hwdec 失败：$e');
      }
    }
    await _openCurrent();
  }

  /// 打开媒体前切换 `stream-lavf-o`。
  ///
  /// 在线抖音地址带 Range 会 404，所以流必须统一标成 `seekable=0`；
  /// 本地缓存文件天然可 seek，这个属性对它没有影响。
  /// 该属性只在打开流时读取，因此每次 open 前设一次即可。
  Future<void> _applyStreamSeekable() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    const value = 'seekable=0';
    try {
      final current = (await platform.getProperty('stream-lavf-o')).trim();
      if (current == value) return;
      await platform.setProperty('stream-lavf-o', value);
      diag('mpv', 'stream-lavf-o=$value（在线流关闭 Range）');
    } catch (e) {
      diag('mpv', '设置 stream-lavf-o 失败：$e');
    }
  }

  /// 错误浮层的"重试"：清掉当前错误，重新走完整的 open → 首帧确认流程。
  /// 不做"只重设 URL"这种半截操作，避免停在半加载状态。
  void _retry() {
    _retryCount++;
    diag('player', '重试第 $_retryCount 次：重新走 open 流程 aweme=${_current.id}');
    _openCurrent();
  }

  Future<void> _openCurrent(
      {VideoVariant? forceVariant, Duration? seekTo}) async {
    if (_switching) return;
    _switching = true;
    try {
      await _openCurrentInner(forceVariant: forceVariant, seekTo: seekTo);
    } finally {
      _switching = false;
    }
  }

  Future<void> _openCurrentInner(
      {VideoVariant? forceVariant, Duration? seekTo}) async {
    final gen = ++_openGeneration;
    final item = _current;
    // 普通 open（不是"补跳"）时清掉旧的延后跳转，避免缓存完成后误跳到旧位置。
    if (seekTo == null && _forceLocalForNextOpen == null) {
      _pendingLocalSeek = null;
    }
    if (_recycleEvery > 0 && _openedSinceRecycle >= _recycleEvery) {
      await _recyclePlayer();
      _openedSinceRecycle = 0;
    }
    await _configureMpvOnce();
    // 每次打开都确认一次"该硬解就硬解"，避免某次手动切换或后端重置后
    // 后面所有视频都悄悄走软解。
    await _syncHwdecRequest();

    // 档位必须按当前作品实际返回的列表生成；用户选中的档位只作为「上限」，
    // 当前作品没有该档时取 ≤ 上限的最高档（不是一律掉到自动/最低档）。
    _variants = item.variants;
    final chosen = forceVariant ?? _pickVariant(_variants, _qualityPref);
    if (chosen != null) {
      _activeQuality = chosen.label;
      if (_qualityPref != 'auto' && chosen.label != _qualityPref) {
        _toast('当前作品没有 $_qualityPref 档，已按上限选 ${chosen.label}');
      }
    } else {
      _activeQuality = '';
    }
    var useUrl = chosen?.url ?? item.playUrl;
    _currentCacheHeight = chosen?.height ?? 720;

    // 缓存优先：本地文件可 seek，拖进度、跳末尾都不会报
    // “force-seekable=yes”。未命中时仍走在线播放（seekable=0 保证能打开），
    // 同时在后台把这条缓存下来，下次打开/拖动即可用本地。
    // lookup 是纯内存查表（O(1)，无磁盘 IO），这是"秒命中"的关键一环。
    File? local;
    if (_forceLocalForNextOpen != null) {
      final forced = File(_forceLocalForNextOpen!);
      _forceLocalForNextOpen = null;
      // 文件可能刚被淘汰：不存在就当作未命中，别让 open 直接失败。
      if (await forced.exists()) {
        local = forced;
        diag('cache', '按拖动请求切本地文件：${local.path}');
      } else {
        diag('cache', '强制本地文件已不存在，回退在线：${forced.path}');
      }
    }
    if (local == null && _cacheEnabled) {
      local = _cache.lookup(item.id, _currentCacheHeight);
    }
    if (local != null) {
      _cache.hitCount++;
      diag('cache', '命中本地缓存 aweme=${item.id} height=$_currentCacheHeight '
          'path=${local.path}');
    } else if (_cacheEnabled) {
      _cache.missCount++;
      diag('cache', '未命中缓存，先在线播放（后台同步缓存）aweme=${item.id}');
    }
    final previousLocal = _localPath;
    _localPath = local?.path;
    _readyLocalPath = local?.path;
    if (_cacheEnabled) _cache.markActive(local?.path, previous: previousLocal);

    // 自测：DOUYIN_BAD_URL_TEST=1 时首次打开强制用必然失败的地址，
    // 用来验证"错误提示 + 重试按钮"这条链路；重试后恢复正常地址。
    // DOUYIN_BAD_URL 可换成"能连上但永远不出帧"的地址来验证 15 秒超时文案。
    if (local == null && _badUrlTest && _retryCount == 0) {
      useUrl = Platform.environment['DOUYIN_BAD_URL'] ??
          'http://127.0.0.1:9/bad.mp4';
      diag('player', 'BAD_URL_TEST：首次打开使用坏地址 $useUrl（预期报错并等待重试）');
    }

    if (useUrl.isEmpty && local == null) {
      diag('player', 'playUrl 为空，aweme=${item.id}');
      setState(() {
        _playError = '该作品没有可播放的视频地址（可能是图文作品）';
      });
      return;
    }

    setState(() {
      // 互动状态跟着作品走：以接口返回的 user_digged / is_collected 为准。
      _liked = item.userDigged;
      _collected = item.isCollected;
      _diggCount = item.diggCount;
      _collectCount = item.collectCount;
      _diggBusy = false;
      _collectBusy = false;
      _opening = true;
      _firstFrameShown = false;
      _playError = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    });

    diag('player',
        'open aweme=${item.id} pref=$_qualityPref quality=${chosen?.label ?? "unknown"} '
        'variants=[${_variants.map((v) => "${v.label}/${v.height}p/${v.bitRate}").join(", ")}] '
        'hwdec=${_hardware ? PlatformAdapter.preferredHwdec : "no"} '
        'host=${Uri.tryParse(useUrl)?.host}');
    try {
      // 首帧上屏前先静音：mpv 打开媒体后音频解码往往先于视频首帧，
      // 不静音就会"画面还是黑的但声音已经出来"。等首帧确认上屏再恢复音量。
      if (_forceMute) {
        _pendingUnmuteVolume = 0;
        await _player.setVolume(0);
        diag('player', 'DOUYIN_MUTE=1：自测全程静音（mpv volume 固定 0）');
      } else if (_volume > 0 && _pendingUnmuteVolume == 0) {
        _pendingUnmuteVolume = _volume;
        await _player.setVolume(0);
      } else if (_volume <= 0) {
        // 用户上次把音量拖到 0（或静音后重启）：必须显式置 0。
        // 否则新 Player 的默认音量是 100，一开播就"最大声"，
        // 正好是"返回主页再进来音量变最大"的另一条路径。
        _pendingUnmuteVolume = 0;
        await _player.setVolume(0);
      }
      // 不再先 stop()：mpv 的 loadfile 替换媒体时会释放旧解码器，但复用同一个
      // vo/render context 与输出纹理；先 stop() 会把 vo 一并拆掉，导致每条视频
      // 都重建一次视频输出，切得越多内存台阶越高（实测 50 条约 1.5GB）。
      // stop() 只在 _recyclePlayer 和 dispose 时保留。
      final openStarted = DateTime.now();
      // play:false 打开：先把媒体解析出来（拿到宽高/时长），此时不会出声音，
      // 也就不会出现"加载中黑屏但音频已经在响"的空档。
      // 本地文件直接走路径（无网络头），天然可 seek；只有在线才需要 Referer/UA。
      final media = local != null
          ? Media(local.path)
          : Media(
              useUrl,
              httpHeaders: {
                'Referer': 'https://www.douyin.com/',
                'User-Agent': PlatformAdapter.userAgent,
              },
            );
      diag('player',
          'media 来源=${local != null ? "磁盘缓存" : "在线"} '
          'hwdec=${_hardware ? "on" : "off"} seekable=${local != null}');
      // 本地文件可 seek；在线抖音地址带 Range 会 404，必须关掉 seekable。
      // 这个属性在打开流时读取，所以每次 open 前按来源切一次。
      await _applyStreamSeekable();
      _completed = false;
      await _player.open(media, play: false);
      // 切清晰度时保持进度：必须等媒体解析完（宽高可用）再 seek，
      // 否则 seek 会打在还处于 loading 的 mpv 上被丢掉，表现成"从头播"。
      final ready = await _waitForVideoReady(const Duration(milliseconds: 2500));
      diag('avsync',
          'open→视频参数就绪 ${DateTime.now().difference(openStarted).inMilliseconds}ms '
          'ready=$ready 开始播放（此前保持暂停，无音频输出）');
      if (seekTo != null && seekTo > Duration.zero) {
        if (local != null) {
          // 本地文件可 seek：切档后进度不丢。
          await _player.seek(seekTo);
          diag('quality', '切档后 seek 回 ${seekTo.inMilliseconds}ms');
        } else {
          // 在线流已关 seek（seekable=0），硬 seek 会报 “force-seekable=yes”。
          // 这里不硬跳，记下目标位置，等这条缓存完成后自动补跳。
          _pendingLocalSeek = seekTo;
          diag('seek',
              '在线流不可 seek，延后到缓存完成再跳 ${seekTo.inMilliseconds}ms');
        }
      }
      // 播放前再压一次静音：open/stop 之后个别后端会把 volume 复位，
      // 这一行确保"开播瞬间声卡输出为 0"，是首帧前绝对无声的硬保证。
      if (_pendingUnmuteVolume > 0) await _player.setVolume(0);
      await _player.play();
      // 恢复音量必须等"首帧真的上屏"，而不是等时钟走起来（见方法内注释）。
      unawaited(_awaitFirstFrameThenUnmute(openStarted, gen));
      diag('player', 'open 完成');
      // 开播之后才排预取：避免下载和首帧解码抢带宽/磁盘。
      _scheduleCacheAhead(gen);
    } catch (e) {
      diag('player', 'open 异常: $e');
      if (mounted) {
        if (_isHardwareRelated('$e') && (_hardware || _renderHwAccel)) {
          diag('hwdec', 'open 阶段报硬解相关错误，尝试自动降级');
          unawaited(_fallbackToSoftware('open 异常：$e'));
        } else {
          setState(() => _playError = ErrorText.play(e));
        }
      }
    } finally {
      // 不在 open() 返回时就撤遮罩：此时首帧往往还没到，会露出黑屏。
      // 兜底：属性读不到时最多等 2 秒（轮询本身 1.5s 超时），之后也要按
      // "先亮画面、再恢复音量"的顺序放行，避免一直转圈或一直静音。
      _firstFrameTimer?.cancel();
      _firstFrameTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted || gen != _openGeneration) return;
        diag('avsync', '首帧等待兜底超时（2s），按顺序放行');
        _revealFirstFrame(gen);
      });
      // 硬超时：15 秒还没走时钟也没有明确的 mpv 错误时，给出可读原因 + 重试。
      // 重试按钮直接调 _openCurrent()：会清空 _playError、重新选档、
      // 重新走完整 open → 首帧确认流程，等于一次干净的重开。
      _loadDeadlineTimer?.cancel();
      _loadDeadlineTimer = Timer(const Duration(seconds: 15), () {
        if (!mounted || gen != _openGeneration) return;
        if (_position.inMilliseconds > 0 || _playError != null) return;
        diag('player', '加载超时（15s 未出画面）aweme=${item.id} url=$useUrl');
        // 15 秒还没出画面、网络地址又是好的：最可能就是解码/渲染卡住。
        // 先自动降级（硬解 → 软解 → 软件渲染），别直接甩一个错误给用户。
        if (_hardware || _renderHwAccel) {
          diag('hwdec', '15 秒无画面，按硬解失败处理，开始自动降级');
          unawaited(_fallbackToSoftware('加载超时（15 秒无画面）'));
          return;
        }
        setState(() => _playError =
            '加载超时：15 秒内没有拿到可播放的画面。\n'
            '可能原因：视频地址失效、网络受限或解码受阻。\n'
            '可以点“重试”，或用 ↑↓ 切换下一条。');
      });
    }
    await _readProperties();
    _openedSinceRecycle++;
    // 每切换一次记录一行，用于判断内存是否随切换单调增长。
    var res = _resolution;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        final w = await platform.getProperty('width');
        final h = await platform.getProperty('height');
        if (w.isNotEmpty && w != '0') res = '${w}x$h';
      } catch (_) {}
    }
    diag('switch',
        'idx=$_index aweme=${item.id} res=$res texId=${_video.id.value} '
        'rss=${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1)}MB');
  }

  // ------------------------------------------------------- 磁盘预缓存调度

  /// 排预取：**只看前方，不回头**。
  ///
  /// 顺序：`index+1` 第一条开工（用户最可能马上切过去），接着 `index+2`，
  /// 当前条排最后（它已在线在播，本地副本只服务于"拖动进度"）。
  /// 窗口外的任务一律取消——包括已经划过的旧条，这就是"不要把上一个视频
  /// 也缓存下来"的落实点。
  void _scheduleCacheAhead(int gen) {
    if (!mounted || !_cacheEnabled) return;
    final keep = <String>{};

    void enqueue(int i) {
      final it = widget.items[i];
      final v = _pickVariant(it.variants, _qualityPref);
      final height = v?.height ?? 720;
      final url = v?.url ?? it.playUrl;
      if (url.isEmpty) return;
      final isCurrent = i == _index;
      keep.add(VideoCache.keyOf(it.id, height));
      unawaited(_cache.ensure(it.id, height, url).then((f) {
        if (!mounted || f == null) return;
        if (gen != _openGeneration || !isCurrent) return;
        _readyLocalPath = f.path;
        diag('cache', '当前条缓存完成，可切本地 seek：${f.path}');
        // 拖动被延后时：缓存好了立刻补上跳转。
        final pending = _pendingLocalSeek;
        if (pending != null) {
          _pendingLocalSeek = null;
          _forceLocalForNextOpen = f.path;
          unawaited(_openCurrentInner(seekTo: pending));
        }
      }));
    }

    // 只往前：当前 +1 到 +_cacheAhead（默认 2 条），不回头。
    for (var offset = 1; offset <= _cacheAhead; offset++) {
      final i = _index + offset;
      if (i >= widget.items.length) break;
      enqueue(i);
    }
    // 当前条排最后：它已经在线在播，本地副本只服务于"拖动进度"。
    // 排前面会占掉一整个时间片，把"下一条"挤晚——那才是命中率的关键。
    // 用户真拖进度时走 urgent，会取消其他任务独占带宽。
    enqueue(_index);

    // 窗口外的任务全部取消：包括刚才划过的旧条（上一个 / 上上个）。
    // 这是"不缓存已看过的视频"的关键——旧版会刻意保留 index-1 / index-2，
    // 导致缓存里长期积着不会再看的条目。
    _cache.cancelExcept(keep);
    if (_cacheTestHook) {
      unawaited(_cache.statsLine().then((s) => diag('cache-stats', s)));
    }
  }

  /// 拖动进度统一入口。
  ///
  /// 本地文件：直接 seek。
  /// 在线文件（seekable=0）：绝不在线 seek（那正是 “force-seekable=yes”
  /// 报错的来源），改为切换到本地缓存文件后再 seek；缓存还没好就延后补跳。
  void _seekTo(Duration target) {
    _resetHideTimer();
    if (_completed) {
      // 已经播到结尾：mpv 已卸载轨道，此时 seek 会报
      // “error running command _command(seek)”。用本地文件重开再跳，
      // 画面能回来，用户也看不到那句错误。
      diag('seek', '媒体已播完，重新打开当前条后 seek ${target.inMilliseconds}ms');
      if (_localPath != null) _forceLocalForNextOpen = _localPath;
      unawaited(_openCurrentInner(seekTo: target));
      return;
    }
    if (_localPath != null) {
      unawaited(_player.seek(target));
      diag('seek', '缓存源 seek → ${target.inMilliseconds}ms');
      return;
    }
    if (_cacheMode == CacheMode.off) {
      // 用户显式关了缓存：在线流不可 seek，给提示而不是让 mpv 报错。
      diag('seek', '缓存已关闭，忽略在线拖动 ${target.inMilliseconds}ms');
      _toast('缓存已关闭，在线播放暂不支持拖动进度');
      return;
    }
    unawaited(_seekViaCache(target));
  }

  Future<void> _seekViaCache(Duration target) async {
    final cached = _cache.lookup(_current.id, _currentCacheHeight);
    final ready = cached?.path ?? _readyLocalPath;
    if (ready != null) {
      if (await File(ready).exists()) {
        diag('seek', '在线 → 切本地后 seek ${target.inMilliseconds}ms');
        _forceLocalForNextOpen = ready;
        await _openCurrentInner(seekTo: target);
        return;
      }
    }
    // 还没缓存完：给可见提示 + 把当前条提到队首；完成后自动补跳。
    _pendingLocalSeek = target;
    // 拖动时用户就在等这一条：取消后面的预取，让当前条独占带宽，
    // 否则两条后台预取会把当前条挤到最后，出现“拖了半分钟还没反应”。
    _cache.cancelExcept({VideoCache.keyOf(_current.id, _currentCacheHeight)});
    _toast('该视频还在缓存，缓存完成后自动跳到 ${target.inSeconds} 秒');
    final v = _pickVariant(_current.variants, _qualityPref);
    final url = v?.url ?? _current.playUrl;
    if (url.isEmpty) return;
    unawaited(
        _cache
            .ensure(_current.id, _currentCacheHeight, url, urgent: true)
            .then((f) {
      if (!mounted) return;
      if (f == null) {
        // 网络失败 / 磁盘满 / 服务端拒绝：退回在线播放，并明确告诉用户。
        if (_pendingLocalSeek == target) {
          _pendingLocalSeek = null;
          diag('seek', '缓存失败，回退在线播放（拖动未生效）');
          _toast('该视频缓存失败（网络或磁盘），已回退在线播放');
        }
        return;
      }
      if (_pendingLocalSeek != target) return; // 期间已换片，放弃这次补跳
      _pendingLocalSeek = null;
      _readyLocalPath = f.path;
      diag('seek', '缓存完成，自动补跳 ${target.inMilliseconds}ms');
      _forceLocalForNextOpen = f.path;
      unawaited(_openCurrentInner(seekTo: target));
    }));
  }

  /// 首帧确认上屏后恢复音量。mpv 的时钟没有暂停过，所以恢复时音画仍是对齐的，
  /// 只是开头那一小段（首帧渲染前）不出声。
  void _unmuteAfterFirstFrame() {
    final v = _pendingUnmuteVolume;
    if (v <= 0) return;
    _pendingUnmuteVolume = 0;
    _player.setVolume(v);
    final platform = _player.platform;
    if (platform is NativePlayer) {
      unawaited(() async {
        try {
          final pos = await platform.getProperty('time-pos');
          diag('avsync', '恢复音量 ${v.toStringAsFixed(0)}（此刻 time-pos=$pos）');
        } catch (_) {
          diag('avsync', '恢复音量 ${v.toStringAsFixed(0)}');
        }
      }());
    } else {
      diag('avsync', '恢复音量 ${v.toStringAsFixed(0)}');
    }
  }

  /// 等"视频首帧真的输出到 vo"，再撤遮罩、恢复音量。
  ///
  /// 上一版判据用 `video-pts` 连续两次变化，但本机 libmpv 回读 `video-pts`
  /// 始终为空（实测），判据永远不成立，遮罩一直压到 5s 兜底才撤：
  /// 于是声音在 5.7s 恢复、画面还在 300ms 淡入里，用户感知就是"先有声后有画"。
  ///
  /// 现在改用本机确实可读的组合判据（连续两次采样都成立才算）：
  ///   1. `vo-configured=yes`：vo 已为视频配置好；
  ///   2. `width/height > 0`：首帧已解析出视频尺寸；
  ///   3. `time-pos >= 0.12`：播放时钟已推进，30fps 下至少 3 帧；
  ///   4. `estimated-vf-fps > 0`（该属性可读时才要求）：视频输出确实在出帧。
  /// 满足后再等 Flutter 完成一次绘制（endOfFrame）才撤遮罩；遮罩撤掉 350ms
  /// （视频 300ms 淡入完成）之后才恢复音量，保证"先看见画面、再听见声音"。
  /// 上限 1.5s，避免属性异常时长时间黑屏。
  Future<void> _awaitFirstFrameThenUnmute(DateTime since, int gen) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      _revealFirstFrame(gen);
      return;
    }
    var voReady = false;
    var width = 0;
    var height = 0;
    var posSeconds = 0.0;
    var vfFps = 0.0;
    var okSamples = 0;
    var samples = 0;
    final deadline = DateTime.now().add(const Duration(milliseconds: 1500));
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted || _firstFrameShown || gen != _openGeneration) return;
      try {
        final vo = await platform.getProperty('vo-configured');
        final w = await platform.getProperty('width');
        final h = await platform.getProperty('height');
        final pos = await platform.getProperty('time-pos');
        final fps = await platform.getProperty('estimated-vf-fps');
        voReady = vo == 'yes';
        width = int.tryParse(w) ?? 0;
        height = int.tryParse(h) ?? 0;
        posSeconds = double.tryParse(pos) ?? 0;
        vfFps = double.tryParse(fps) ?? 0;
        samples++;
        final advanced = posSeconds >= 0.12;
        // fps 属性读不到（空串）时不作为硬条件，避免又回到"永远不成立"。
        final producing = fps.isEmpty || vfFps > 0;
        final ok = voReady && width > 0 && height > 0 && advanced && producing;
        if (_avTrace) {
          String volume = '';
          String extra = '';
          try {
            volume = await platform.getProperty('volume');
          } catch (_) {}
          // 继续找"视频帧真的显示出来"的可读信号：
          // estimated-frame-number 是已显示帧的估算值；picture-type 是当前帧类型；
          // vo-frame-drop-count 只有 vo 真的在消费帧才会变。
          for (final key in [
            'estimated-frame-number',
            'video-frame-info/picture-type',
            'vo-drop-frame-count',
            'frame-drop-count',
            'decoder-frame-drop-count',
            'vo-delayed-frame-count',
          ]) {
            try {
              extra += ' $key=${await platform.getProperty(key)}';
            } catch (_) {
              extra += ' $key=<err>';
            }
          }
          diag('avtrace',
              't=${DateTime.now().difference(since).inMilliseconds}ms '
              'vo-configured=$vo ${w}x$h time-pos=$pos vf-fps=$fps '
              'volume=$volume ok=$ok$extra');
        }
        if (ok) {
          okSamples++;
          if (okSamples >= 2) break;
        } else {
          okSamples = 0;
        }
      } catch (_) {
        // open 过程中属性可能短暂不可读，继续轮询。
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    if (!mounted || _firstFrameShown || gen != _openGeneration) return;
    // 等一帧真正绘制完成，确保纹理内容已经进入屏幕。
    try {
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}
    if (!mounted || _firstFrameShown || gen != _openGeneration) return;
    diag('avsync',
        '首帧上屏判定完成 ${DateTime.now().difference(since).inMilliseconds}ms '
        'vo=$voReady ${width}x$height time-pos=${posSeconds}s vf-fps=$vfFps '
        '采样=$samples 满足=$okSamples');
    _revealFirstFrame(gen);
  }

  /// 撤掉加载遮罩（只撤遮罩，不出声），随后等"画面真的被渲染出来"再恢复音量。
  ///
  /// 实测证据：`estimated-frame-number` 已经涨到 4（mpv 确实在出帧），
  /// 但同一时刻截图里视频区还是黑的——共享纹理上传到 Flutter 有额外延迟。
  /// 所以不能以 mpv 属性作为"用户看得见"的依据，必须采样真实渲染结果。
  void _revealFirstFrame(int gen) {
    if (gen != _openGeneration) return;
    if (_firstFrameShown) return;
    _firstFrameShown = true;
    _firstFrameTimer?.cancel();
    if (!mounted) {
      _unmuteAfterFirstFrame();
      return;
    }
    if (_opening) setState(() => _opening = false);
    diag('avsync', '遮罩已撤（画面开始淡入），等待画面真实可见后再出声（gen=$gen）');
    // 首帧出现 = 解码器已经真正工作，此时核对硬解是否生效最准确。
    unawaited(_verifyHardwareDecode(gen));
    unawaited(_unmuteWhenVisible(gen));
  }

  /// 轮询真实渲染亮度：连续两次确认"视频主区不再是黑色"后才恢复音量。
  /// 上限 2.5s；始终测不到（极少数 GPU 截不到纹理）时按超时放行并如实记录。
  Future<void> _unmuteWhenVisible(int gen) async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 2500));
    var hits = 0;
    var last = -1.0;
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted || gen != _openGeneration) return;
      final brightness = await sampleScreenBrightness(pixelRatio: 0.08);
      last = brightness;
      if (_avTrace) {
        diag('avtrace', '屏幕亮度=${brightness.toStringAsFixed(1)} 连续命中=$hits');
      }
      if (brightness >= 12) {
        hits++;
        if (hits >= 2) break;
      } else {
        hits = 0;
      }
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    if (!mounted || gen != _openGeneration) return;
    if (last >= 12) {
      // 再等两帧，确保用户眼前是稳定画面而不是一闪而过的残帧。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || gen != _openGeneration) return;
      diag(
          'avsync',
          '画面已可见（亮度=${last.toStringAsFixed(1)}），'
          '${_forceMute ? "保持静音（DOUYIN_MUTE=1）" : "现在开始出声"}（gen=$gen）');
    } else {
      diag('avsync',
          '亮度始终未达阈值（最后=${last.toStringAsFixed(1)}），按 2.5s 超时放行${_forceMute ? "（保持静音）" : "出声"}');
    }
    _unmuteAfterFirstFrame();
  }

  /// 等待 mpv 解析出视频参数（宽高可用），期间保持暂停，因此不会有音频。
  /// 超时也返回 false 并由调用方继续播放，避免坏源一直卡在"加载中"。
  Future<bool> _waitForVideoReady(Duration timeout) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return true;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted) return false;
      try {
        final w = int.tryParse(await platform.getProperty('width')) ?? 0;
        final h = int.tryParse(await platform.getProperty('height')) ?? 0;
        if (w > 0 && h > 0) return true;
      } catch (_) {
        // 属性在 open 过程中可能还不可读，继续轮询。
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    return false;
  }

  Future<void> _readProperties() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      final hwdecReq = await platform.getProperty('hwdec');
      final hwdec = await platform.getProperty('hwdec-current');
      final avhw = await platform.getProperty('avcodec-hw');
      final codec = await platform.getProperty('video-codec');
      final vformat = await platform.getProperty('video-format');
      final vo = await platform.getProperty('current-vo');
      final tracks = await platform.getProperty('track-list/count');
      final pos = await platform.getProperty('time-pos');
      final width = await platform.getProperty('width');
      final height = await platform.getProperty('height');
      final fps = await platform.getProperty('estimated-vf-fps');
      final dropped = await platform.getProperty('frame-drop-count');
      // 音画同步相关选项：用来确认"黑屏有声"修复是否真的下发生效，
      // 以及 libmpv 没有自己开窗口（force-window=no / current-vo=libmpv）。
      final awaitVideo = await platform.getProperty('audio-wait-for-video');
      final vsync = await platform.getProperty('video-sync');
      final forceWindow = await platform.getProperty('force-window');
      final keepOpen = await platform.getProperty('keep-open');
      final paused = await platform.getProperty('pause');
      diag(
          'mpv-props',
          'hwdec=$hwdecReq hwdec-current=$hwdec avcodec-hw=$avhw codec=$codec vformat=$vformat '
          'current-vo=$vo tracks=$tracks pos=$pos ${width}x$height fps=$fps drop=$dropped '
          'audio-wait-for-video=$awaitVideo video-sync=$vsync force-window=$forceWindow '
          'keep-open=$keepOpen pause=$paused');
      if (!mounted) return;
      setState(() {
        _hwdecCurrent = hwdec.isEmpty ? '—' : hwdec;
        _codec = codec.isEmpty ? '—' : codec;
        _resolution =
            (width == '0' || width.isEmpty || height == '0' || height.isEmpty)
                ? '—'
                : '$width × $height';
        _frameRate = fps.isEmpty ? '—' : fps;
      });
    } catch (e) {
      debugPrint('[Player] 读取 mpv 属性失败: $e');
    }
  }

  /// 抓取当前视频画面的快照（切换动画的"旧画面滑出"层）。
  /// 只截视频那一块（[_videoBoundaryKey]），不截互动栏和控制条。
  Future<void> _captureOutgoingFrame() async {
    // 自测开关：DOUYIN_LEAN=1 关掉"旧画面快照"和封面模糊，用来隔离
    // 抓图/封面在内存剖面里的占比。
    if (Platform.environment['DOUYIN_LEAN'] == '1') return;
    final boundary =
        _videoBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    try {
      final image = await boundary.toImage(pixelRatio: 0.7);
      _outgoingFrame?.dispose();
      _outgoingFrame = image;
      diag('anim', '旧画面快照 ${image.width}x${image.height}');
    } catch (e) {
      diag('anim', '抓取旧画面失败（退化为仅新画面滑入）: $e');
    }
  }

  /// 启动（或打断后重启）切换动画。重复调用直接归零重跑，不排队。
  void _startSlide() {
    _slideCtrl.stop();
    _slideCtrl.value = 0.0;
    _slideCtrl.forward();
  }

  /// 触发首条/末条的回弹反馈：画面朝越界方向轻推 12px 再弹回。
  /// 不硬切、不空转——用户能看到"到头了"的物理反馈，同时保留 toast 文案。
  void _bounce(int delta) {
    _bounceDir = delta;
    _bounceCtrl.stop();
    _bounceCtrl.value = 0.0;
    _bounceCtrl.forward();
    diag('gesture', '越界回弹 delta=$delta index=$_index');
  }

  Future<void> _switchVideo(int delta, {bool keyboard = false}) async {
    final now = DateTime.now();
    // 键盘/按钮用极短防抖：按一下就能立刻打断正在跑的滑动动画，不排队。
    final gap = keyboard ? _keySwitchGap : _switchCooldown;
    if (now.difference(_lastSwitchAt) < gap) {
      diag('gesture',
          '切换请求被冷却丢弃 delta=$delta keyboard=$keyboard '
          'elapsed=${now.difference(_lastSwitchAt).inMilliseconds}ms');
      _scrollAccum = 0;
      return;
    }
    _lastSwitchAt = now;
    _scrollAccum = 0;

    // 向下切且已经进入"尾部危险区"：先等后台预取（通常早就跑完了），
    // 再决定能不能切；这样用户不会刷到最后一条才看到"已结束"。
    if (delta > 0 && _index >= widget.items.length - _prefetchThreshold) {
      if (_prefetching) _toast('正在加载下一批…');
      await _prefetchIfNeeded(force: true);
      if (!mounted) return;
    }

    final next = _index + delta;
    if (next < 0 || next >= widget.items.length) {
      _bounce(delta);
      if (delta > 0) {
        _toast(_noMoreItems ? '已经是最后一条了' : '正在加载下一批，请稍候…');
      } else {
        _toast('已经是第一条了');
      }
      return;
    }
    // 切换动画第 1 步：在 stop 之前抓一张旧画面快照，供"反方向滑出"使用。
    // 抓图是异步 GPU 回读（几十毫秒），失败就退化为只有新画面滑入。
    _slideDir = delta;
    // 换片：旧的“等缓存补跳”作废，避免跳到已经划走的作品上。
    _pendingLocalSeek = null;
    _readyLocalPath = null;
    await _captureOutgoingFrame();
    if (!mounted) return;
    setState(() {
      _index = next;
      _hwdecCurrent = '—';
      _codec = '—';
      _resolution = '—';
      _frameRate = '—';
      _dragValue = null;
    });
    _startSlide();
    diag('gesture', '接受切换 → idx=$next（keyboard=$keyboard）');
    await _openCurrent();
    if (mounted) setState(() {});
    unawaited(_prefetchIfNeeded());
  }

  /// 快刷到列表尾部（剩 ≤ [_prefetchThreshold] 条）时异步拉下一批并合并。
  /// 返回新增条数；0 表示这一轮没有拿到新内容。
  Future<int> _prefetchIfNeeded({bool force = false}) async {
    final load = widget.onLoadMore;
    if (load == null || _noMoreItems) return 0;
    if (!force && _index < widget.items.length - _prefetchThreshold) return 0;
    if (_prefetching) {
      // 已有一轮在跑：等它结束（最多 3 秒），调用方随后按新长度重新判断。
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (_prefetching && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return 0;
    }
    _prefetching = true;
    final before = widget.items.length;
    try {
      final added = await load();
      if (added <= 0) _noMoreItems = true;
      if (!mounted) return added;
      setState(() {});
      diag('player',
          '预加载结果 +$added 条（$before→${widget.items.length}），noMore=$_noMoreItems');
      return added;
    } catch (e) {
      diag('player', '预加载异常: $e');
      return 0;
    } finally {
      _prefetching = false;
    }
  }

  /// 鼠标滚轮切换：累计增量 + 阈值 + 冷却 + 手势断开归零。
  ///
  /// 三道闸（对应"一次滚动切好几条"的抱怨）：
  ///   1. 单事件限幅 [_scrollEventClamp]：惯性尖峰只算一格，多余丢弃；
  ///   2. 累计阈值 [_scrollThreshold]：一格滚轮（40~60）恰好触发一条，
  ///      触摸板的小增量必须真的累积够才会切；
  ///   3. 冷却 [_switchCooldown]：切换后 380ms 内的事件全部丢弃且不清零重算，
  ///      冷却结束不会"补切"；超过 [_scrollGestureGap] 的静默视为新手势。
  void _onScroll(double dy) {
    if (dy == 0) return;
    // 评论抽屉 / 调试面板打开时，滚轮属于它们自己的滚动区域，
    // 不能顺带切换视频（否则在评论区翻页会连着换片）。
    if (_showComments || _showDebug) {
      _scrollAccum = 0;
      return;
    }
    final now = DateTime.now();
    final sinceEvent = now.difference(_lastScrollEventAt);
    _lastScrollEventAt = now;
    // 手势断开：上一次滚动的残留增量作废，避免慢慢滚几次凑成一次误切。
    if (sinceEvent > _scrollGestureGap) _scrollAccum = 0;

    if (now.difference(_lastSwitchAt) < _switchCooldown) {
      // 冷却期内不累计，避免冷却一结束立刻"补"切一条。
      diag('gesture', '滚轮冷却丢弃 dy=$dy '
          'elapsed=${now.difference(_lastSwitchAt).inMilliseconds}ms');
      _scrollAccum = 0;
      return;
    }

    // 方向反转先清零，防止来回滚动互相抵消后再误触发。
    if (_scrollAccum != 0 && dy.sign != _scrollAccum.sign) _scrollAccum = 0;
    final contribution = dy > _scrollEventClamp
        ? _scrollEventClamp
        : (dy < -_scrollEventClamp ? -_scrollEventClamp : dy);
    _scrollAccum += contribution;
    if (_scrollAccum.abs() < _scrollThreshold) return;
    final dir = _scrollAccum > 0 ? 1 : -1;
    diag('gesture',
        '滚轮触发 dir=$dir 累计=${_scrollAccum.toStringAsFixed(1)}');
    _scrollAccum = 0;
    _switchVideo(dir);
  }

  /// 打开作者主页「TA 的作品」。跳转前先暂停，避免作者页里还在播当前视频。
  void _openAuthor() {
    final author = _current.author;
    if (author.secUid.isEmpty) {
      _toast('该作品没有返回作者 ID，无法打开主页');
      return;
    }
    _player.pause();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AuthorPage(api: widget.api, author: author),
    ));
  }

  /// X 键：评论。
  /// 抽屉没开 → 打开并默认停在「评论」；停在详情/TA的作品 → 先切回评论；
  /// 已经停在评论 → 关抽屉。与网页版/Python 版的行为一致。
  void _toggleComments() {
    if (!_showComments) {
      setState(() {
        _commentTab = kDrawerTabComments;
        _showComments = true;
      });
      return;
    }
    if (_commentPanel.isCommentTab) {
      setState(() => _showComments = false);
    } else {
      _commentPanel.goToCommentsTab();
    }
  }

  /// 快捷键说明：顶栏按钮 / F1 / Shift+? 都能打开，方便查按键。
  void _showShortcutHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B1B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        title: const Text('快捷键',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ShortcutRow('X', '评论：打开/切回评论，再按关闭'),
              _ShortcutRow('Z', '点赞 / 取消点赞'),
              _ShortcutRow('S', '收藏 / 取消收藏'),
              _ShortcutRow('空格', '播放 / 暂停'),
              _ShortcutRow('← →', '快退 / 快进 5 秒'),
              _ShortcutRow('↑ ↓', '上一条 / 下一条'),
              _ShortcutRow('Shift+↑↓', '音量 + / -'),
              _ShortcutRow('N / P', '下一条 / 上一条'),
              _ShortcutRow('F', '全屏开关'),
              _ShortcutRow('Esc', '关闭抽屉 / 退出全屏'),
              _ShortcutRow('F1 / ?', '打开本说明'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了',
                style: TextStyle(color: Color(0xFFFE6B8B))),
          ),
        ],
      ),
    );
  }

  /// 播放当前作者的作品：把「TA的作品」抽屉里已经拉到的列表当成一条独立
  /// 播放队列，上下切换只在这个作者的作品里走；快到尾部时按同一 sec_uid
  /// 继续分页。首页推荐流用的是同一个 List 引用，这里用副本，不污染首页。
  Future<void> _playAuthorPosts(
    List<AwemeItem> posts,
    int index,
    String secUid,
    int maxCursor,
    bool hasMore,
  ) async {
    if (posts.isEmpty) {
      _toast('没有可播放的作者作品');
      return;
    }
    final items = List<AwemeItem>.from(posts);
    final seen = <String>{for (final e in items) e.id};
    var cursor = maxCursor;
    var more = hasMore;
    var loading = false;

    Future<int> loadMore() async {
      if (!more || loading || secUid.isEmpty) return 0;
      loading = true;
      try {
        final body = await widget.api
            .fetchUserPosts(secUid, maxCursor: cursor, count: 18);
        var added = 0;
        for (final raw in asList(body['aweme_list'])) {
          final parsed = AwemeItem.fromJson(asMap(raw));
          if (parsed == null || !seen.add(parsed.id)) continue;
          items.add(parsed);
          added++;
        }
        cursor = asInt(body['max_cursor']);
        more = asInt(body['has_more']) == 1 && added > 0;
        diag('author-play',
            '续拉 +$added 条 total=${items.length} cursor=$cursor more=$more');
        return added;
      } catch (e) {
        diag('author-play', '续拉失败: $e');
        return 0;
      } finally {
        loading = false;
      }
    }

    final wasPlaying = _playing;
    _player.pause();
    setState(() => _showComments = false);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        api: widget.api,
        items: items,
        initialIndex: index.clamp(0, items.length - 1),
        onLoadMore: loadMore,
      ),
    ));
    if (mounted && wasPlaying) unawaited(_player.play());
  }

  /// 打开登录页（扫码 / 粘贴 Cookie）。登录成功后同一个 DouyinApi 实例已被
  /// 热替换 Cookie，返回播放页即可直接发评论。
  Future<void> _openLogin() async {
    _player.pause();
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LoginPage(api: widget.api),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  /// 浮层里的硬解开关：优先写全局设置（持久化），由 [_onSettingsChanged]
  /// 统一下发 hwdec 并重开，避免两处逻辑分叉。
  ///
  /// 特殊情况：刚被自动降级时 `_hardware` 已经是 false，但设置里仍是"自动"，
  /// 这时 setDecodeMode 不会触发通知，需要就地应用一次。
  Future<void> _toggleHardware() async {
    final settings = AppSettings.instance;
    final target = _hardware ? DecodeMode.software : DecodeMode.auto;
    if (settings.decodeMode != target) {
      await settings.setDecodeMode(target);
      return;
    }
    setState(() {
      _hardware = target == DecodeMode.auto;
      _hwSoftwareFallback = false;
      if (_hardware) {
        _hwAutoFallbackActive = false;
        _hwFallbackNotified = false;
      }
    });
    if (_hardware && !_renderHwAccel) {
      _renderHwAccel = true;
      await _recyclePlayer();
    }
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('hwdec',
          _hardware ? PlatformAdapter.preferredHwdec : 'no');
    }
    await _openCurrent();
  }

  /// 调试浮层里的缓存状态。
  String _cacheStatusLine() {
    if (!_cacheEnabled) return '未启用（直连播放）';
    final used = (_cache.usedBytes / (1024 * 1024)).toStringAsFixed(1);
    final limit = (_cache.maxBytes / (1024 * 1024)).toStringAsFixed(0);
    return '磁盘 $used/$limit MB · ${_cache.itemCount} 条';
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    await wm.windowManager.setFullScreen(next);
    // 不需要（也不应该）在这里等窗口动画结束再去"重建视频输出"：
    // 视频纹理保持视频原始尺寸，展示层由 FittedBox(BoxFit.contain) 缩放，
    // 窗口一变，下一帧布局就自动贴合。等待 + 重建只会引入黑屏空窗期。
  }

  void _toast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message, style: const TextStyle(fontSize: 12.5)),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      width: 280,
      backgroundColor: const Color(0xEE2A2A2A),
    ));
  }

  /// 分享面板：复制链接 / 在浏览器打开作品页。
  ///
  /// 网页端没有"选择好友并私信分享"的公开接口（实测 im 相关路径全部
  /// `404 Unsupported path(Janus)`，真实私信走 imapi protobuf 长连接），
  /// 所以这里只提供真正能生效的两种方式，并在界面里说明原因。
  Future<void> _showShareSheet() async {
    final item = _current;
    final link = 'https://www.douyin.com/video/${item.id}';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1D1D1D),
        title: const Text('分享作品',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.desc.isEmpty ? '抖音作品' : item.desc,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xFFCFCFCF), fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF141414),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  link,
                  style: const TextStyle(
                      color: Color(0xFF8CC8FF), fontSize: 12),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFE2C55),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: link));
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      _toast('作品链接已复制，可粘贴给好友');
                    },
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('复制链接'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFCFCFCF),
                      side: const BorderSide(color: Color(0xFF3A3A3A)),
                    ),
                    onPressed: () => _openInBrowser(link),
                    icon: const Icon(Icons.group_add_outlined, size: 16),
                    label: const Text('在网页版选好友分享'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                '说明：应用内「选择好友并私信分享」需要抖音私信长连接协议（imapi protobuf），'
                '网页端未开放对应 HTTP 端点（实测 /aweme/v1/web/im/*、share/* 全部返回 404 Unsupported path）。'
                '所以这里给出两条真正可用的路径：复制链接发给好友，或在网页版点「分享」选好友。',
                style: TextStyle(
                    color: Color(0xFF8A8A8A), fontSize: 11.5, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:
                const Text('关闭', style: TextStyle(color: Color(0xFFCFCFCF))),
          ),
        ],
      ),
    );
  }

  void _openInBrowser(String url) {
    try {
      if (Platform.isWindows) {
        unawaited(Process.start(
            'cmd', ['/c', 'start', '', url], runInShell: true));
      } else if (Platform.isMacOS) {
        unawaited(Process.start('open', [url]));
      } else {
        unawaited(Process.start('xdg-open', [url]));
      }
    } catch (e) {
      _toast('打开浏览器失败：${ErrorText.from(e)}');
    }
  }
  String _describeInteractionError(Object e) {
    if (e is DouyinException && e.needsVerify) {
      return '${ErrorText.from(e)}（完成验证后可再试）';
    }
    // 统一走中文翻译层：原来兜底是 '$e'，会直接把英文异常甩给用户。
    return ErrorText.from(e);
  }

  /// 评论/回复输入框聚焦时，X/Z/S 必须让给文字输入（否则打字会触发点赞/收藏）。
  ///
  /// 两道判据：
  ///   1. 焦点在 EditableText 里；
  ///   2. 输入法正在组字（候选框已弹出、文字还没提交）——此时即使焦点
  ///      短暂不在输入框上，X/Z/S 也必须交给输入法，不能当成快捷键。
  bool get _isTyping => ImeGuard.composing || focusIsInEditableText();

  /// 快捷键匹配：正常情况看逻辑键；中文输入法把按键改写成 VK_PROCESSKEY
  /// （组字）时逻辑键不可靠，用扫描码对应的物理键兜底。原生侧也会把
  /// VK_PROCESSKEY 还原成真实 VK（见 flutter_window.cpp），两层叠加保证
  /// 候选框出现时 X/Z/S 依然能触发快捷键。
  bool _keyMatches(KeyDownEvent event, LogicalKeyboardKey logical,
          PhysicalKeyboardKey physical) =>
      event.logicalKey == logical || event.physicalKey == physical;

  Future<void> _toggleDigg() async {
    if (_diggBusy) return;
    final item = _current;
    final target = !_liked;
    setState(() {
      _diggBusy = true;
      _liked = target;
      _diggCount += target ? 1 : -1;
    });
    try {
      await _commitInteractionWithVerify(
        commit: () => widget.api.commitDigg(item.id, like: target),
        awemeId: item.id,
        likeAction: true,
        expectOn: target,
        label: target ? '点赞' : '取消点赞',
      );
      diag('interact', '点赞 ${target ? "成功" : "取消成功"} aweme=${item.id}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _liked = !target;
        _diggCount += target ? -1 : 1;
      });
      final msg = _describeInteractionError(e);
      _toast('点赞失败：$msg');
      diag('interact', '点赞失败: $msg');
    } finally {
      if (mounted) setState(() => _diggBusy = false);
    }
  }

  /// 收藏：同上。
  Future<void> _toggleCollect() async {
    if (_collectBusy) return;
    final item = _current;
    final target = !_collected;
    setState(() {
      _collectBusy = true;
      _collected = target;
      _collectCount += target ? 1 : -1;
    });
    try {
      await _commitInteractionWithVerify(
        commit: () => widget.api.commitCollect(item.id, collect: target),
        awemeId: item.id,
        likeAction: false,
        expectOn: target,
        label: target ? '收藏' : '取消收藏',
      );
      diag('interact', '收藏 ${target ? "成功" : "取消成功"} aweme=${item.id}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _collected = !target;
        _collectCount += target ? -1 : 1;
      });
      final msg = _describeInteractionError(e);
      _toast('收藏失败：$msg');
      diag('interact', '收藏失败: $msg');
    } finally {
      if (mounted) setState(() => _collectBusy = false);
    }
  }

  /// 写接口统一封装：命中风控先让用户在浏览器里过验证，通过后**只重试一次**，
  /// 且重试前先读一次详情确认上一次是否其实已经生效，避免重复点赞/收藏。
  Future<void> _commitInteractionWithVerify({
    required Future<bool> Function() commit,
    required String awemeId,
    required bool likeAction,
    required bool expectOn,
    required String label,
  }) async {
    try {
      final ok = await commit();
      if (!ok) throw Exception('接口未返回成功');
    } on DouyinException catch (e) {
      if (!e.needsVerify) rethrow;
      _toast('需要验证：${ErrorText.from(e)}（已尝试打开验证页面）');
      diag('interact', '$label 命中风控，等待用户验证');
      final passed = await VerifyGate.instance
          .waitForUser(widget.api, e, label: label);
      if (!passed) throw Exception('验证未完成：${VerifyGate.instance.message}');
      if (await _interactionAlreadyApplied(awemeId,
          likeAction: likeAction, expectOn: expectOn)) {
        diag('interact', '重试前发现$label已生效，跳过重试');
        return;
      }
      final ok = await commit();
      if (!ok) throw Exception('验证通过但重试仍未成功');
    }
  }

  /// 重试前读一次详情确认状态；详情未提供该字段时返回 false
  /// （点赞/收藏接口本身幂等，重试不会产生重复计数）。
  Future<bool> _interactionAlreadyApplied(String awemeId,
      {required bool likeAction, required bool expectOn}) async {
    try {
      final body = await widget.api.fetchDetail(awemeId);
      final detail = asMap(body?['aweme_detail']);
      final flag = likeAction
          ? (detail['digg_status'] ?? detail['is_digg'])
          : (detail['collect_status'] ?? detail['is_collect']);
      final on = flag is bool ? flag : (flag is num ? flag == 1 : null);
      if (on == null) return false;
      return on == expectOn;
    } catch (e) {
      diag('interact', '重试前读取互动状态失败: $e');
      return false;
    }
  }

  void _togglePlay() {
    _player.playOrPause();
    _resetHideTimer();
  }

  void _seekBy(Duration delta) {
    final target = _position + delta;
    if (target < Duration.zero) {
      _seekTo(Duration.zero);
    } else if (_duration > Duration.zero && target > _duration) {
      _seekTo(_duration);
    } else {
      _seekTo(target);
    }
  }

  void _setVolume(double v) {
    final clamped = v.clamp(0, 100).toDouble();
    setState(() {
      _volume = clamped;
      _muted = clamped == 0;
    });
    // 音量是用户明确设置的偏好：立刻落盘，返回主页再进来要沿用。
    unawaited(AppSettings.instance.setVolume(clamped));
    if (_pendingUnmuteVolume > 0) {
      // 首帧还没上屏，只更新目标音量，等上屏后一起恢复。
      _pendingUnmuteVolume = clamped;
    } else {
      _player.setVolume(clamped);
    }
    _resetHideTimer();
  }

  void _toggleMute() {
    if (_muted) {
      setState(() => _muted = false);
      _player.setVolume(_volume == 0 ? 50 : _volume);
    } else {
      setState(() => _muted = true);
      _player.setVolume(0);
    }
    _resetHideTimer();
  }

  void _cycleSpeed() {
    const speeds = [1.0, 1.25, 1.5, 2.0, 0.5, 0.75];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    setState(() => _speed = next);
    _player.setRate(next);
    _resetHideTimer();
  }

  /// 切换调试面板，同时同步 mpv 属性轮询的开/关。
  ///
  /// 轮询本身是"每秒读 15+ 个 mpv 属性 + setState 整页重绘"，
  /// 面板关着时完全没有必要跑——这是核显机器上白付的 GPU/CPU 开销。
  void _toggleDebug() {
    final next = !_showDebug;
    setState(() => _showDebug = next);
    _propertyTimer?.cancel();
    _propertyTimer = null;
    if (next) {
      _propertyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _readProperties();
      });
    }
  }

  void _handleEsc() {
    if (_showDebug) {
      _toggleDebug();
      return;
    }    if (_showComments) {
      setState(() => _showComments = false);
      return;
    }
    if (_fullscreen) {
      _toggleFullscreen();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _propertyTimer?.cancel();
    _firstFrameTimer?.cancel();
    _loadDeadlineTimer?.cancel();
    _bufferTimer?.cancel();
    _logFlushTimer?.cancel();
    _slideCtrl.dispose();
    _bounceCtrl.dispose();
    _outgoingFrame?.dispose();
    // 离开播放页：取消所有预取任务，避免后台还在下已经不会看的视频。
    // 已下完的文件留在磁盘，下次进来直接命中（跨页面复用）。
    AppSettings.instance.removeListener(_onSettingsChanged);
    if (_cacheEnabled) {
      _cache.cancelExcept(const {});
      _cache.markActive(null, previous: _localPath);
    }
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    // 先停声再释放：dispose 是异步的，直接丢弃实例时音频可能继续播一小段时间
    // （Python 版就踩了"关掉页面后台还在响"这个坑）。
    _player.pause();
    _player.stop();
    unawaited(_player.dispose());
    diag('player', 'dispose 已 stop+release aweme=${_current.id}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _current;
    final totalMs = _duration.inMilliseconds;
    final posMs = _dragValue?.inMilliseconds ??
        _position.inMilliseconds.clamp(0, totalMs == 0 ? 1 << 30 : totalMs);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0B),
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          // 正在输入评论/回复时，快捷键不能抢字符。
          if (_isTyping) return KeyEventResult.ignored;
          bool keyIs(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) =>
              _keyMatches(event, logical, physical);
          if (keyIs(LogicalKeyboardKey.space, PhysicalKeyboardKey.space)) {
            _togglePlay();
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.arrowLeft,
              PhysicalKeyboardKey.arrowLeft)) {
            _seekBy(const Duration(seconds: -5));
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.arrowRight,
              PhysicalKeyboardKey.arrowRight)) {
            _seekBy(const Duration(seconds: 5));
            return KeyEventResult.handled;
          }
          // ↑↓ 切换上一条 / 下一条（与抖音网页版一致）；Shift+↑↓ 保留调音量。
          if (keyIs(LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp)) {
            if (HardwareKeyboard.instance.isShiftPressed) {
              _setVolume(_volume + 5);
            } else {
              _switchVideo(-1, keyboard: true);
            }
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.arrowDown,
              PhysicalKeyboardKey.arrowDown)) {
            if (HardwareKeyboard.instance.isShiftPressed) {
              _setVolume(_volume - 5);
            } else {
              _switchVideo(1, keyboard: true);
            }
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN)) {
            _switchVideo(1, keyboard: true);
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.keyP, PhysicalKeyboardKey.keyP)) {
            _switchVideo(-1, keyboard: true);
            return KeyEventResult.handled;
          }
          // X 评论（默认打开/切回评论，再按关闭）；Z 点赞；S 收藏。
          // 三者与界面按钮走同一套逻辑，可再按一次取消。
          if (keyIs(LogicalKeyboardKey.keyX, PhysicalKeyboardKey.keyX)) {
            _toggleComments();
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ)) {
            _toggleDigg();
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS)) {
            _toggleCollect();
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF)) {
            _toggleFullscreen();
            return KeyEventResult.handled;
          }
          // F1 或 Shift+? 打开快捷键说明。
          if (keyIs(LogicalKeyboardKey.f1, PhysicalKeyboardKey.f1) ||
              (keyIs(LogicalKeyboardKey.slash, PhysicalKeyboardKey.slash) &&
                  HardwareKeyboard.instance.isShiftPressed)) {
            _showShortcutHelp();
            return KeyEventResult.handled;
          }
          if (keyIs(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape)) {
            _handleEsc();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Row(
          children: [
            Expanded(
              child: MouseRegion(
                onHover: (_) => _resetHideTimer(),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      // 滚轮切换：累计增量 + 阈值 + 冷却，一次滚轮只切一条。
                      _onScroll(event.scrollDelta.dy);
                    }
                  },
                  child: GestureDetector(
                    onDoubleTap: _togglePlay,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black),
                        // 切换动画层：旧画面反方向滑出，新内容（封面/视频）滑入。
                        // 用 AnimatedBuilder 直接驱动，不触发整页 setState。
                        AnimatedBuilder(
                          animation: _animListenable,
                          builder: (context, _) {
                            final raw = _slideCtrl.value.clamp(0.0, 1.0);
                            final t = Curves.easeOutCubic.transform(raw);
                            // 越界回弹：sin 单峰，0→1→0，画面轻推一下就弹回。
                            final bounce =
                                math.sin(_bounceCtrl.value * math.pi);

                            // 视频层本体：结构**恒定**，切换动画结束后不会被
                            // 重挂载（重挂载 = Texture 重建 = 闪一下）。
                            final videoLayer = Stack(
                              fit: StackFit.expand,
                              children: [
                                // 首帧前：封面模糊占位，避免纯黑干等。
                                // 不显示就不构建，省掉高斯模糊的 ImageFilterLayer。
                                if (_opening) _CoverBlur(url: item.coverUrl),
                                AnimatedOpacity(
                                  opacity: _opening ? 0.0 : 1.0,
                                  duration:
                                      const Duration(milliseconds: 220),
                                  child: RepaintBoundary(
                                    key: _videoBoundaryKey,
                                    child: Video(
                                      key: ValueKey(_video),
                                      controller: _video,
                                      fit: BoxFit.contain,
                                      fill: Colors.black,
                                      controls: (state) =>
                                          const SizedBox.shrink(),
                                    ),
                                  ),
                                ),
                              ],
                            );

                            final settled =
                                raw >= 1.0 && _bounceCtrl.value == 0;

                            return LayoutBuilder(
                              builder: (context, constraints) {
                                final h = constraints.maxHeight;
                                final dy = settled
                                    ? 0.0
                                    : _slideDir * h * 0.16 * (1 - t) -
                                        _bounceDir * 12.0 * bounce;
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    // 新内容层：位移 + 淡入。
                                    //
                                    // 这里刻意**不用** Transform.translate /
                                    // Transform.scale：它们会给视频纹理套一层
                                    // TransformLayer，合成器每帧都要多做一次
                                    // 变换 + 可能的离屏重采样，在 Intel UHD 620
                                    // 上就是"播放时轻微闪动 + GPU 占用高"。
                                    //
                                    // FractionalTranslation 只偏移绘制位置，
                                    // 不创建任何合成层；Opacity 在 1.0 时走
                                    // RenderOpacity 的零层快路径（alpha==255
                                    // 直接 paintChild）。所以静止期这两层
                                    // 完全等价于"没有包装"。
                                    //
                                    // 轻微缩放（原 0.985→1.0）为性能让路去掉：
                                    // 1.5% 的缩放肉眼几乎无感，但代价是每帧
                                    // 一次 scale 合成。
                                    FractionalTranslation(
                                      translation: Offset(
                                          0, h <= 0 ? 0 : dy / h),
                                      child: Opacity(
                                        opacity: settled
                                            ? 1.0
                                            : (0.45 + 0.55 * t)
                                                .clamp(0.0, 1.0),
                                        child: videoLayer,
                                      ),
                                    ),
                                    // 旧画面滑出层：与进入方向相反，同时淡出。
                                    if (_outgoingFrame != null)
                                      IgnorePointer(
                                        child: Transform.translate(
                                          offset: Offset(
                                              0, -_slideDir * h * 0.34 * t),
                                          child: Opacity(
                                            opacity: (1 - t) * 0.92,
                                            child: RawImage(
                                              image: _outgoingFrame,
                                              fit: BoxFit.contain,
                                              filterQuality:
                                                  FilterQuality.low,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            );
                          },
                        ),
                        // 加载层：半透明暗化 + 进度圈 + 文案（封面占位在其下方）。
                        //
                        // 只在 _opening 为真时构建。原来的写法用 AnimatedOpacity
                        // 把它"藏"起来，但子树始终在渲染树里：即使肉眼看不见，
                        // 每帧照样要布局 + 绘制一层全屏半透明色块，在核显上
                        // 是白付的填充带宽。播放稳定期 _opening 恒为 false，
                        // 所以这里直接不构建最划算。
                        if (_opening)
                          IgnorePointer(
                            child: Container(
                              color: const Color(0x59000000),
                              alignment: Alignment.center,
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 26,
                                    height: 26,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: Colors.white70),
                                  ),
                                  SizedBox(height: 12),
                                  Text('加载中…',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.white70)),
                                ],
                              ),
                            ),
                          ),
                        if (_playError != null)
                          _PlayErrorOverlay(
                            message: _playError!,
                            onRetry: _retry,
                          ),
                        // 顶部返回 + 标题
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          child: AnimatedOpacity(
                            opacity: _uiHidden ? 0 : 1,
                            duration: const Duration(milliseconds: 220),
                            child: IgnorePointer(
                              ignoring: _uiHidden,
                              child: _TopBar(
                                title: item.desc.isEmpty
                                    ? '抖音'
                                    : item.desc,
                                onBack: () => Navigator.of(context).maybePop(),
                                onShortcuts: _showShortcutHelp,
                              ),
                            ),
                          ),
                        ),
                        // 左下信息区
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: AnimatedOpacity(
                            opacity: _uiHidden ? 0 : 1,
                            duration: const Duration(milliseconds: 220),
                            child: IgnorePointer(
                              ignoring: _uiHidden,
                              child: _InfoPanel(item: item, onAuthor: _openAuthor),
                            ),
                          ),
                        ),
                        // 右侧竖排互动栏
                        Positioned(
                          right: 14,
                          bottom: 118,
                          child: AnimatedOpacity(
                            opacity: _uiHidden ? 0 : 1,
                            duration: const Duration(milliseconds: 220),
                            child: IgnorePointer(
                              ignoring: _uiHidden,
                              child: _SideActions(
                                item: item,
                                onAuthor: _openAuthor,
                                onComment: _toggleComments,
                                onDigg: _toggleDigg,
                                onCollect: _toggleCollect,
                                onShare: _showShareSheet,
                                onMore: () => _toast('更多功能暂未接入'),
                                liked: _liked,
                                collected: _collected,
                                diggCount: _diggCount,
                                collectCount: _collectCount,
                              ),
                            ),
                          ),
                        ),
                        if (_showDebug)
                          Positioned(
                            right: _showComments ? 470 : 18,
                            top: 64,
                            child: DebugOverlay(
                              hwdecCurrent: _hwdecCurrent,
                              codec: _codec,
                              resolution: _resolution,
                              frameRate: _frameRate,
                              hardwareEnabled: _hardware,
                              softwareFallback: _hwSoftwareFallback,
                              cacheLine: _cacheStatusLine(),
                              logs: _logs,
                              onToggleHardware: _toggleHardware,
                            ),
                          ),
                        // 底部控制条
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: AnimatedOpacity(
                            opacity: (_uiHidden || !_controlsVisible) ? 0 : 1,
                            duration: const Duration(milliseconds: 260),
                            child: IgnorePointer(
                              ignoring: _uiHidden || !_controlsVisible,
                              child: _ControlBar(
                                positionMs: posMs.toDouble(),
                                durationMs: totalMs.toDouble(),
                                playing: _playing,
                                volume: _volume,
                                muted: _muted,
                                speed: _speed,
                                quality: _qualityLabel,
                                autoNext: _autoNext,
                                danmakuOn: _danmakuOn,
                                onSeekStart: (v) => setState(() => _dragValue =
                                    Duration(milliseconds: v.round())),
                                onSeekChanged: (v) => setState(() => _dragValue =
                                    Duration(milliseconds: v.round())),
                                onSeekEnd: (v) {
                                  _seekTo(Duration(milliseconds: v.round()));
                                  setState(() => _dragValue = null);
                                  _resetHideTimer();
                                },
                                onTogglePlay: _togglePlay,
                                onVolumeChanged: _setVolume,
                                onToggleMute: _toggleMute,
                                onCycleSpeed: _cycleSpeed,
                                onToggleAutoNext: () =>
                                    setState(() => _autoNext = !_autoNext),
                                onToggleDanmaku: () {
                                  setState(() => _danmakuOn = !_danmakuOn);
                                  if (_danmakuOn) {
                                    _toast('弹幕数据接口本期未接入，开关状态已记录');
                                  }
                                },
                                onClearScreen: () =>
                                    setState(() => _uiHidden = true),
                                onToggleFullscreen: _toggleFullscreen,
                                fullscreen: _fullscreen,
                                onOpenComments: _toggleComments,
                                onSend: () => setState(() {
                                      _commentTab = kDrawerTabComments;
                                      _showComments = true;
                                    }),
                                onQuality: _showQualityPicker,
                                onPip: () => _toast('桌面端暂不支持画中画'),
                                onSettings: () => _toggleDebug(),
                              ),
                            ),
                          ),
                        ),
                        if (_uiHidden)
                          Positioned(
                            right: 20,
                            top: 16,
                            child: _RoundIconButton(
                              icon: Icons.visibility_outlined,
                              tooltip: '显示界面',
                              onTap: () => setState(() => _uiHidden = false),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 评论抽屉：从右侧滑出，宽度 440，不停止播放
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              width: _showComments ? 440 : 0,
              child: _showComments
                  ? CommentPanel(
                      key: ValueKey(item.id),
                      controller: _commentPanel,
                      api: widget.api,
                      awemeId: item.id,
                      item: item,
                      initialTab: _commentTab,
                      onTabChanged: (index) => _commentTab = index,
                      onClose: () => setState(() => _showComments = false),
                      onOpenAuthor: _openAuthor,
                      onPlayAuthorPosts: _playAuthorPosts,
                      onRequestLogin: _openLogin,
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------- 清晰度逻辑

  Future<void> _loadQualityPref() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_qualityPrefKey);
    if (saved == null || saved.isEmpty || !mounted) return;
    setState(() => _qualityPref = saved);
  }

  Future<void> _saveQualityPref() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qualityPrefKey, _qualityPref);
  }

  /// 按偏好选档：用户选中的档位是「上限」，不是「必须精确命中」。
  ///
  /// 具体比较规则见 [pickVariantUnderCap]（models.dart，可被工具脚本直接测试）。
  /// 自动档位逻辑保持不变。
  VideoVariant? _pickVariant(List<VideoVariant> variants, String pref) {
    if (variants.isEmpty) return null;
    // 内存上限：默认最高只取 1080P。1440P/4K 的单帧纹理 + d3d11 解码缓冲
    // 让每次切视频的内存台阶明显变大（实测 1440P 单条稳定 ~540MB）。
    final prefHeight = heightOfQualityLabel(pref);
    final capped = prefHeight != null && prefHeight > 1080;
    final effective = capped ? _memoryQualityCap : pref;
    if (effective == 'auto') return _pickAuto(variants);
    final chosen = pickVariantUnderCap(variants, effective);
    if (capped && chosen != null) {
      diag('player', '内存上限生效：偏好 $pref → 实际 ${chosen.label}');
    }
    return chosen ?? _pickAuto(variants);
  }

  /// 自动择档依据：
  /// 1. 上限 = 播放区物理高度（逻辑高 × devicePixelRatio）× 1.1；
  /// 2. 在不超过上限的档位里取最高档（不会一上来就顶最高档）；
  /// 3. 所有档都超过上限时取最低档；
  /// 4. 档位没有高度信息时按码率取中位档，避免直接选最高码率。
  VideoVariant _pickAuto(List<VideoVariant> variants) {
    final withHeight = variants.where((v) => v.height > 0).toList()
      ..sort((a, b) => a.height.compareTo(b.height));
    if (withHeight.isEmpty) {
      final byRate = [...variants]
        ..sort((a, b) => a.bitRate.compareTo(b.bitRate));
      return byRate[(byRate.length - 1) ~/ 2];
    }
    final target = _viewportPhysicalHeight();
    var cap = target + target ~/ 10;
    // 自动档同样封顶 1080P，避免高 DPI/大窗口下自动挑到 1440P 以上。
    if (cap > 1080) cap = 1080;
    VideoVariant best = withHeight.first;
    for (final v in withHeight) {
      if (v.height <= cap) best = v;
    }
    return best;
  }

  int _viewportPhysicalHeight() {
    final mq = MediaQuery.of(context);
    return (mq.size.height * mq.devicePixelRatio).round();
  }

  /// 控制条档位文案。自动模式下当前档位未知时只显示"自动"，
  /// 不猜一个可能错误的档位名。
  String get _qualityLabel {
    if (_current.isImage) return '图文';
    if (_qualityPref == 'auto') {
      return _activeQuality.isEmpty ? '自动' : '自动·$_activeQuality';
    }
    // 用户选了某档，但当前作品没有这一档（已回落）：显示实际生效的档位，
    // 不能把选不中的偏好当成当前档位显示。
    if (_activeQuality.isEmpty) return _qualityPref;
    if (_activeQuality != _qualityPref) return _activeQuality;
    return _qualityPref;
  }

  Future<void> _showQualityPicker() async {
    if (_variants.isEmpty) {
      _toast('该作品接口没有返回清晰度档位');
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1F1F1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (_) => _QualitySheet(
        variants: _variants,
        pref: _qualityPref,
        active: _activeQuality,
      ),
    );
    if (selected == null || !mounted) return;
    await _applyQuality(selected);
  }

  Future<void> _applyQuality(String pref) async {
    if (pref == _qualityPref) return;
    var target = pref;
    VideoVariant? variant;
    if (pref != 'auto') {
      for (final v in _variants) {
        if (v.label == pref) variant = v;
      }
      if (variant == null) {
        // 面板只列出当前作品实际档位，这里只是保险。
        _toast('当前作品没有 $pref 档，已回落到自动');
        target = 'auto';
      }
    }
    final pos = _player.state.position;
    final autoLabel = target == 'auto' && _variants.isNotEmpty
        ? _pickAuto(_variants).label
        : '';
    setState(() {
      _qualityPref = target;
      _activeQuality = variant?.label ?? autoLabel;
      _opening = true;
    });
    await _saveQualityPref();
    diag('quality', '手动切档 pref=$target keep=${pos.inMilliseconds}ms');
    await _openCurrent(forceVariant: variant, seekTo: pos);
  }

  /// 自动模式下持续缓冲时下调一档：只降不升，5 秒冷却，避免抖动。
  Future<void> _autoDowngrade() async {
    if (!mounted || _qualityPref != 'auto' || _opening || _switching) return;
    if (_variants.length < 2) return;
    if (DateTime.now().difference(_lastDowngradeAt) <
        const Duration(seconds: 5)) {
      return;
    }
    final idx = _variants.indexWhere((v) => v.label == _activeQuality);
    if (idx <= 0) return;
    final lower = _variants[idx - 1];
    _lastDowngradeAt = DateTime.now();
    final pos = _player.state.position;
    diag('quality', '持续缓冲，自动下调 ${_activeQuality} → ${lower.label}');
    _toast('播放不流畅，已自动降到 ${lower.label}');
    setState(() => _opening = true);
    await _openCurrent(forceVariant: lower, seekTo: pos);
  }
}

// ---------------- 子组件 ----------------

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow(this.keyLabel, this.desc);

  final String keyLabel;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 56),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2C),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(keyLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFFF2F2F2),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(desc,
                style: const TextStyle(
                    color: Color(0xFFBDBDBD), fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.onBack, this.onShortcuts});

  final String title;
  final VoidCallback onBack;
  final VoidCallback? onShortcuts;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          _RoundIconButton(
              icon: Icons.arrow_back_ios_new,
              size: 16,
              tooltip: '返回',
              onTap: onBack),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
              ),
            ),
          ),
          _RoundIconButton(
            icon: Icons.keyboard_alt_outlined,
            tooltip: '快捷键（F1 / ?）',
            onTap: onShortcuts ?? () {},
          ),
        ],
      ),
    );
  }
}

class _InfoPanel extends StatefulWidget {
  const _InfoPanel({required this.item, this.onAuthor});

  final AwemeItem item;
  final VoidCallback? onAuthor;

  @override
  State<_InfoPanel> createState() => _InfoPanelState();
}

class _InfoPanelState extends State<_InfoPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final timeAgo = formatTimeAgo(item.createTime);
    return IgnorePointer(
      ignoring: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 0, 200, 96),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: widget.onAuthor,
                      child: Text(
                        '@${item.author.nickname}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(color: Color(0x99000000), blurRadius: 8)
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '· $timeAgo',
                  style: const TextStyle(
                    color: Color(0xCCFFFFFF),
                    fontSize: 12.5,
                    shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (item.desc.isNotEmpty) ...[
              Text(
                item.desc,
                maxLines: _expanded ? 12 : 2,
                overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFF2F2F2),
                  fontSize: 14,
                  height: 1.55,
                  shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
                ),
              ),
              if (item.desc.length > 40)
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _expanded ? '收起' : '展开',
                      style: const TextStyle(
                          color: Color(0xCCFFFFFF), fontSize: 12.5),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (item.mixName.isNotEmpty)
                  _Tag(text: '合集 · ${item.mixName}'),
                if (item.mixIsLast) const _Tag(text: '已是最新集'),
                if (item.musicTitle.isNotEmpty)
                  _Tag(text: '♫ ${item.musicTitle}', maxWidth: 240),
                if (item.playCount > 0)
                  _Tag(text: '播放 ${formatCount(item.playCount)}'),
                const _Tag(text: '识别画面'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.maxWidth = 260});

  final String text;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x33FFFFFF),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xE6FFFFFF), fontSize: 11.5),
        ),
      ),
    );
  }
}

class _SideActions extends StatelessWidget {
  const _SideActions({
    required this.item,
    required this.onComment,
    required this.onDigg,
    required this.onCollect,
    required this.onShare,
    required this.onMore,
    required this.liked,
    required this.collected,
    required this.diggCount,
    required this.collectCount,
    this.onAuthor,
  });

  final AwemeItem item;
  final VoidCallback onComment;
  final VoidCallback onDigg;
  final VoidCallback onCollect;
  final VoidCallback onShare;
  final VoidCallback onMore;
  final VoidCallback? onAuthor;
  final bool liked;
  final bool collected;
  final int diggCount;
  final int collectCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _AvatarAction(url: item.author.avatarUrl, onTap: onAuthor),
        const SizedBox(height: 20),
        _ActionIcon(
          icon: liked ? Icons.favorite : Icons.favorite_border,
          color: liked ? const Color(0xFFFF2D55) : Colors.white,
          label: formatCount(diggCount),
          tooltip: liked ? '取消点赞（Z）' : '点赞（Z）',
          onTap: onDigg,
        ),
        const SizedBox(height: 18),
        _ActionIcon(
          icon: Icons.chat_bubble_outline,
          label: formatCount(item.commentCount),
          tooltip: '评论（X）',
          onTap: onComment,
        ),
        const SizedBox(height: 18),
        _ActionIcon(
          icon: collected ? Icons.star : Icons.star_border,
          color: collected ? const Color(0xFFFFC531) : Colors.white,
          label: formatCount(collectCount),
          tooltip: collected ? '取消收藏（S）' : '收藏（S）',
          onTap: onCollect,
        ),
        const SizedBox(height: 18),
        _ActionIcon(
          icon: Icons.reply,
          label: formatCount(item.shareCount),
          tooltip: '分享',
          onTap: onShare,
        ),
        const SizedBox(height: 18),
        const _ActionIcon(
          icon: Icons.headphones_outlined,
          label: '听抖音',
          tooltip: '听抖音',
        ),
        const SizedBox(height: 18),
        _ActionIcon(
          icon: Icons.more_horiz,
          label: '更多',
          tooltip: '更多',
          onTap: onMore,
        ),
      ],
    );
  }
}

class _AvatarAction extends StatelessWidget {
  const _AvatarAction({required this.url, this.onTap});

  final String url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: _avatar(),
      ),
    );
  }

  Widget _avatar() {
    return SizedBox(
      width: 48,
      height: 54,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
              color: const Color(0xFF333333),
              image: url.isEmpty
                  ? null
                  : DecorationImage(
                      image: ResizeImage(NetworkImage(url), width: 96),
                      fit: BoxFit.cover,
                      onError: (_, _) {},
                    ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 14,
            child: Container(
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                color: Color(0xFFFF2D55),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.add, size: 13, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.color = Colors.white,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap ?? () {},
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                color: Color(0x3D000000),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: color,
                size: 23,
                shadows: const [Shadow(color: Color(0x99000000), blurRadius: 8)],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 18,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: const BoxDecoration(
            color: Color(0x59000000),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: size, color: Colors.white),
        ),
      ),
    );
  }
}

/// 首帧到达前的封面模糊占位：既不是纯黑，也不会因为原图过大而占内存
/// （[CachedNetworkImage.memCacheWidth] 限制解码宽度）。
class _CoverBlur extends StatelessWidget {
  const _CoverBlur({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty || Platform.environment['DOUYIN_LEAN'] == '1') {
      return const ColoredBox(color: Color(0xFF141414));
    }
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColorFiltered(
          colorFilter:
              const ColorFilter.mode(Color(0x66000000), BlendMode.darken),
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            memCacheWidth: 480,
            fadeInDuration: const Duration(milliseconds: 120),
            placeholder: (_, _) => const ColoredBox(color: Color(0xFF1A1A1A)),
            errorWidget: (_, _, _) => const ColoredBox(color: Color(0xFF141414)),
          ),
        ),
      ),
    );
  }
}

class _PlayErrorOverlay extends StatelessWidget {
  const _PlayErrorOverlay({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: const Color(0xE6161616),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF3A3A3A)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFFF6B6B), size: 26),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(0xFFDDDDDD), fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 底部控制条：时间 / 进度 / 音量 / 弹幕 / 评论输入 / 连播 / 清屏 /
/// 清晰度 / 倍速 / 播放暂停 / 画中画 / 全屏 / 设置。
class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.volume,
    required this.muted,
    required this.speed,
    required this.quality,
    required this.autoNext,
    required this.danmakuOn,
    required this.onSeekStart,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onTogglePlay,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onCycleSpeed,
    required this.onToggleAutoNext,
    required this.onToggleDanmaku,
    required this.onClearScreen,
    required this.onToggleFullscreen,
    required this.fullscreen,
    required this.onOpenComments,
    required this.onSend,
    required this.onQuality,
    required this.onPip,
    required this.onSettings,
  });

  final double positionMs;
  final double durationMs;
  final bool playing;
  final double volume;
  final bool muted;
  final double speed;
  final String quality;
  final bool autoNext;
  final bool danmakuOn;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final VoidCallback onCycleSpeed;
  final VoidCallback onToggleAutoNext;
  final VoidCallback onToggleDanmaku;
  final VoidCallback onClearScreen;
  final VoidCallback onToggleFullscreen;
  final bool fullscreen;
  final VoidCallback onOpenComments;
  final VoidCallback onSend;
  final VoidCallback onQuality;
  final VoidCallback onPip;
  final VoidCallback onSettings;

  String _fmt(double ms) {
    final total = (ms / 1000).round();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xE6000000), Color(0x00000000)],
        ),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        // 抽屉展开后视频区会变窄，窄屏时收起次要文字按钮，避免溢出。
        final compact = constraints.maxWidth < 760;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一行：播放时间 + 可拖动进度条（悬停显示时间气泡）
            Row(
              children: [
                Text(
                  '${_fmt(positionMs)} / ${_fmt(durationMs)}',
                  style:
                      const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11.5),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ProgressBar(
                    positionMs: positionMs,
                    durationMs: durationMs,
                    onSeekStart: onSeekStart,
                    onSeekChanged: onSeekChanged,
                    onSeekEnd: onSeekEnd,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            // 第二行：音量 → 弹幕 → 评论输入 → 发送 → 连播 → 清屏 →
            //        清晰度 → 倍速 → 播放/暂停 → 画中画 → 全屏 → 设置
            Row(
              children: [
                _BarIcon(
                  icon:
                      muted || volume == 0 ? Icons.volume_off : Icons.volume_up,
                  tooltip: '静音',
                  onTap: onToggleMute,
                ),
                SizedBox(
                  width: 72,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      activeTrackColor: const Color(0xE6FFFFFF),
                      inactiveTrackColor: const Color(0x4DFFFFFF),
                      thumbColor: Colors.white,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 9),
                    ),
                    child: Slider(
                      value: muted ? 0 : volume.clamp(0, 100),
                      max: 100,
                      onChanged: onVolumeChanged,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _TextChip(
                  text: '弹幕',
                  active: danmakuOn,
                  tooltip: '弹幕开关',
                  onTap: onToggleDanmaku,
                ),
                const SizedBox(width: 10),
                // 评论输入框（视觉骨架，点击打开评论抽屉；X 键等效）
                Expanded(
                  child: Tooltip(
                    message: '打开评论（X）',
                    child: GestureDetector(
                      onTap: onOpenComments,
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0x33FFFFFF),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                        child: const Row(
                          children: [
                            Expanded(
                              child: Text(
                                '发一条友好的弹幕吧',
                                style: TextStyle(
                                    color: Color(0x99FFFFFF), fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _TextChip(text: '发送', tooltip: '发送评论', onTap: onSend),
                if (!compact) ...[
                  const SizedBox(width: 8),
                  _TextChip(
                    text: '连播',
                    active: autoNext,
                    tooltip: '自动播放下一条',
                    onTap: onToggleAutoNext,
                  ),
                  const SizedBox(width: 8),
                  _TextChip(
                      text: '清屏', tooltip: '隐藏所有浮层', onTap: onClearScreen),
                ],
                const SizedBox(width: 8),
                _TextChip(
                    text: quality,
                    tooltip: '清晰度（自动 / 手动档位）',
                    onTap: onQuality),
                const SizedBox(width: 8),
                _TextChip(
                  text: speed == 1.0 ? '倍速' : '${speed}x',
                  tooltip: '倍速播放',
                  onTap: onCycleSpeed,
                ),
                const SizedBox(width: 6),
                _BarIcon(
                  icon: playing ? Icons.pause : Icons.play_arrow,
                  tooltip: playing ? '暂停 (空格)' : '播放 (空格)',
                  onTap: onTogglePlay,
                  size: 24,
                ),
                _BarIcon(
                  icon: Icons.picture_in_picture_alt_outlined,
                  tooltip: '画中画',
                  onTap: onPip,
                ),
                _BarIcon(
                  icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  tooltip: '全屏 (F)',
                  onTap: onToggleFullscreen,
                ),
                _BarIcon(
                  icon: Icons.settings_outlined,
                  tooltip: '设置 / 调试面板',
                  onTap: onSettings,
                ),
              ],
            ),
          ],
        );
      }),
    );
  }
}

/// 进度条：拖动调整进度，悬停/拖动时在上方显示时间气泡。
class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.positionMs,
    required this.durationMs,
    required this.onSeekStart,
    required this.onSeekChanged,
    required this.onSeekEnd,
  });

  final double positionMs;
  final double durationMs;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _hoverFraction;
  bool _dragging = false;

  String _fmt(double ms) {
    final total = (ms / 1000).round();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final max = widget.durationMs <= 0 ? 1.0 : widget.durationMs;
    final safe = widget.positionMs.clamp(0.0, max);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final bubbleFraction =
          _hoverFraction ?? (safe / max).clamp(0.0, 1.0);
      final showBubble = _hoverFraction != null && width > 0;
      final bubbleMs = bubbleFraction * max;
      return MouseRegion(
        onHover: (event) {
          if (width <= 0) return;
          setState(() =>
              _hoverFraction = (event.localPosition.dx / width).clamp(0.0, 1.0));
        },
        onExit: (_) {
          if (_dragging) return;
          setState(() => _hoverFraction = null);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: const Color(0xFFFF2D55),
                inactiveTrackColor: const Color(0x4DFFFFFF),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: safe,
                max: max,
                onChangeStart: (v) {
                  setState(() => _dragging = true);
                  widget.onSeekStart(v);
                },
                onChanged: widget.onSeekChanged,
                onChangeEnd: (v) {
                  setState(() => _dragging = false);
                  widget.onSeekEnd(v);
                },
              ),
            ),
            if (showBubble)
              Positioned(
                left: (bubbleFraction * width - 28).clamp(0.0, (width - 56).clamp(0.0, double.infinity)),
                top: -20,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xE6000000),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0x33FFFFFF)),
                  ),
                  child: Text(
                    _fmt(bubbleMs),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11, height: 1.1),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}

class _BarIcon extends StatelessWidget {
  const _BarIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 20,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          child: Icon(icon, size: size, color: const Color(0xE6FFFFFF)),
        ),
      ),
    );
  }
}

class _TextChip extends StatelessWidget {
  const _TextChip({
    required this.text,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final String text;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: active ? const Color(0x33FF2D55) : const Color(0x22000000),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active ? const Color(0x66FF2D55) : const Color(0x26FFFFFF),
            ),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: active ? const Color(0xFFFF6B8B) : const Color(0xCCFFFFFF),
              fontSize: 11.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// 清晰度选择面板：档位完全来自当前作品接口实际返回的列表，
/// 不写死档位，所以不会出现"选了不存在的档"。
class _QualitySheet extends StatelessWidget {
  const _QualitySheet({
    required this.variants,
    required this.pref,
    required this.active,
  });

  final List<VideoVariant> variants;
  final String pref;

  /// 自动模式下实际命中的档位；未知时为空串。
  final String active;

  void _pick(BuildContext context, String value) {
    Navigator.of(context).pop(value);
  }

  Widget _tile(
      BuildContext context, String value, String title, String? subtitle) {
    final selected = pref == value;
    // 偏好档位在当前作品不可用时的回落档：标记为"当前生效"，但不打勾，
    // 因为用户的偏好并没有被改掉（下次遇到支持的档位还会用回去）。
    final fallback = !selected && value != 'auto' && active == value;
    return ListTile(
      dense: true,
      onTap: () => _pick(context, value),
      title: Text(title, style: const TextStyle(fontSize: 13.5)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: const TextStyle(fontSize: 11.5, color: Color(0x99FFFFFF)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
      trailing: selected
          ? const Icon(Icons.check, size: 18, color: Color(0xFFFF2C55))
          : fallback
              ? const Text('当前生效',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFFFFA726)))
              : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(children: [
                Text('清晰度',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ]),
            ),
            _tile(
              context,
              'auto',
              '自动',
              active.isEmpty ? '按播放区大小与流畅度自动选择' : '当前命中 $active',
            ),
            const Divider(height: 1, color: Color(0x26FFFFFF)),
            for (final v in variants.reversed)
              _tile(
                context,
                v.label,
                v.label,
                v.bitRate > 0
                    ? '码率 ${(v.bitRate / 1000000).toStringAsFixed(1)} Mbps'
                    : null,
              ),
            if (pref != 'auto' && !variants.any((v) => v.label == pref))
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text(
                  '当前作品没有 $pref 档，已按 $pref 上限选了 '
                  '${active.isEmpty ? "自动" : active}；后续作品会继续以上限挑档',
                  style: const TextStyle(
                      fontSize: 11.5, color: Color(0xFFFFA726), height: 1.4),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
