import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import '../../data/douyin_api.dart';
import '../../data/models.dart';
import '../../core/diag.dart';
import '../../core/platform_adapter.dart';

/// 无渲染表面的解码探针：不创建 VideoController（避免 EGL 依赖），
/// 用 mpv 的 vo=null 只做解码，读取 hwdec-current 并统计进程 CPU 时间。
/// 由 DOUYIN_DECODE_PROBE=1 触发；参数 DOUYIN_PROBE_HWDEC=硬解名 或 no，
/// 未指定时取平台默认值（Windows d3d11va / macOS videotoolbox / Linux auto-safe）。
Future<void> runDecodeProbe() async {
  final hwdec = Platform.environment['DOUYIN_PROBE_HWDEC'] ??
      PlatformAdapter.preferredHwdec;
  final seconds =
      int.tryParse(Platform.environment['DOUYIN_PROBE_SECONDS'] ?? '10') ?? 10;

  try {
    final api = DouyinApi();
    await api.ensureReady();
    final raw = await api.fetchFeed(count: 6);
    final items = <AwemeItem>[];
    for (final json in raw) {
      final item = AwemeItem.fromJson(json);
      if (item != null && item.playUrl.isNotEmpty) items.add(item);
    }
    if (items.isEmpty) {
      diag('probe', '没有可播放条目，终止');
      exit(4);
    }
    final item = items.first;
    diag('probe', '目标 aweme=${item.id} 数量=${items.length} 播放地址长度=${item.playUrl.length}');

    final player = Player();
    final subs = <StreamSubscription<dynamic>>[];
    subs.add(player.stream.log.listen((e) => diag('mpv', '${e.level}: ${e.text}')));
    subs.add(player.stream.error.listen((e) => diag('mpv-error', '$e')));
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('vo', 'null');
      await platform.setProperty('hwdec', hwdec);
      await platform.setProperty('user-agent', kDouyinUa);
      await platform.setProperty('referrer', 'https://www.douyin.com/');
      await platform.setProperty('cache', 'no');
      await platform.setProperty('msg-level', 'all=v');
    }
    // 完整播放地址单独落盘，便于用 curl 复现 403 问题（不进日志正文）。
    final urlFile = Platform.environment['DOUYIN_LOG'];
    if (urlFile != null && urlFile.isNotEmpty) {
      File('$urlFile.url').writeAsStringSync(item.playUrl);
    }
    await player.open(Media(item.playUrl, httpHeaders: {
      'Referer': 'https://www.douyin.com/',
      'User-Agent': kDouyinUa,
    }));
    diag('probe', 'open 返回');

    for (var i = 0; i < seconds; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (platform is NativePlayer) {
        final cur = await platform.getProperty('hwdec-current');
        final codec = await platform.getProperty('video-codec');
        final w = await platform.getProperty('width');
        final h = await platform.getProperty('height');
        final fps = await platform.getProperty('estimated-vf-fps');
        final dropped = await platform.getProperty('frame-drop-count');
        final pos = await platform.getProperty('time-pos');
        final idle = await platform.getProperty('idle-active');
        final dur = await platform.getProperty('duration');
        final vformat = await platform.getProperty('video-format');
        final vo = await platform.getProperty('current-vo');
        final tracks = await platform.getProperty('track-list/count');
        final avhw = await platform.getProperty('avcodec-hw');
        diag('probe',
            't=${i + 1}s hwdec=$hwdec current=$cur avcodec-hw=$avhw codec=$codec '
            'vformat=$vformat vo=$vo tracks=$tracks ${w}x$h fps=$fps pos=$pos dur=$dur idle=$idle drop=$dropped');
      }
    }
    await player.dispose();
    for (final s in subs) {
      await s.cancel();
    }
    diag('probe', '完成');
    exit(0);
  } catch (e, st) {
    diag('probe', '异常: $e\n$st');
    exit(5);
  }
}
