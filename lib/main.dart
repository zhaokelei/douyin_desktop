import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/legacy.dart';

import 'app.dart';
import 'core/app_settings.dart';
import 'core/diag.dart';
import 'core/login_probe.dart';
import 'core/platform_adapter.dart';
import 'core/screen_probe.dart';
import 'features/player/decode_probe.dart';

/// 调试截图模式：设置 DOUYIN_SHOT=<png 路径> 后，窗口会移到屏幕外、不抢焦点，
/// 渲染稳定后由应用自己用 RepaintBoundary 截图并退出。
/// 这样自测时不会弹窗打扰，且截图是真实渲染结果（不依赖 DWM 合成）。
Future<void> main() async {
  kStartupWatch = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  // 长列表会缓存大量封面图，把 Flutter 图片缓存上限压到 16MB / 120 项，
  // 避免连续滚动后内存一路涨（封面本身已按 memCacheWidth 限宽解码）。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 16 << 20;
  PaintingBinding.instance.imageCache.maximumSize = 120;

  // media_kit 的桌面内核是 libmpv，三端共用；硬解由 mpv 的 hwdec 决定。
  // 未显式指定路径时交给 media_kit 按平台候选名逐个探测；缺库时给出中文提示。
  try {
    MediaKit.ensureInitialized(libmpv: PlatformAdapter.libmpvOverride);
  } catch (e) {
    stderr.writeln(PlatformAdapter.libmpvFailureHint(e));
    diag('startup', 'libmpv 加载失败: $e');
    exit(1);
  }

  // 用户设置（解码方式 / 缓存策略 / 默认清晰度）：启动前读一次，
  // 避免首帧先按默认值渲染再跳变。
  await AppSettings.instance.load();

  // 解码探针：不建窗口、不建渲染表面，只验证解码器与 CPU 占用。
  if (Platform.environment['DOUYIN_DECODE_PROBE'] == '1') {
    await runDecodeProbe();
    return;
  }

  // 登录探针：不建窗口，直接在真实进程里跑「已登录 profile → 读到登录态 → 落盘」。
  // 用于自测浏览器登录链路（CDP 与离线兜底两条路径），结果写在 logs/browser_login.log。
  if (Platform.environment['DOUYIN_LOGIN_PROBE'] == '1') {
    await runLoginProbe();
    // 探针不建窗口，必须显式退出：Flutter Windows 引擎的线程会保持进程存活。
    exit(0);
  }

  final shotPath = Platform.environment['DOUYIN_SHOT'];
  final shotMode = shotPath != null && shotPath.isNotEmpty;

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(PlatformAdapter.defaultWindowWidth,
        PlatformAdapter.defaultWindowHeight),
    minimumSize: Size(PlatformAdapter.minimumWindowWidth,
        PlatformAdapter.minimumWindowHeight),
    center: true,
    title: PlatformAdapter.windowTitle,
    backgroundColor: Colors.transparent,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    if (shotMode) {
      // 离屏：不激活、不进任务栏，用户看不到也抢不到焦点。
      await windowManager.setSkipTaskbar(true);
      await windowManager.setPosition(const Offset(-3000, -3000));
      await windowManager.show(inactive: true);
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  runApp(RepaintBoundary(key: kRootBoundaryKey, child: const DouyinApp()));

  if (!shotMode) return;
  final target = shotPath;

  final seconds =
      int.tryParse(Platform.environment['DOUYIN_SHOT_DELAY'] ?? '15') ?? 15;
  // 逐帧取证：DOUYIN_SHOT_COUNT>1 时按 DOUYIN_SHOT_INTERVAL_MS 连拍，
  // 文件名追加 _000/_001…；窗口始终在屏幕外，不抢焦点、不进任务栏。
  final count =
      int.tryParse(Platform.environment['DOUYIN_SHOT_COUNT'] ?? '') ?? 1;
  final intervalMs =
      int.tryParse(Platform.environment['DOUYIN_SHOT_INTERVAL_MS'] ?? '') ?? 60;
  final base = target.toLowerCase().endsWith('.png')
      ? target.substring(0, target.length - 4)
      : target;
  Timer(Duration(seconds: seconds), () async {
    try {
      final boundary = kRootBoundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        stderr.writeln('[shot] RepaintBoundary 未就绪');
        exit(2);
      }
      for (var i = 0; i < count; i++) {
        final image = await boundary.toImage(pixelRatio: 1.0);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final path =
            count == 1 ? target : '${base}_${i.toString().padLeft(3, '0')}.png';
        File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
        diag('shot',
            '第 ${i + 1}/$count 帧已保存 t=${kStartupWatch?.elapsedMilliseconds ?? -1}ms $path');
        stdout.writeln('[shot] $path (${image.width}x${image.height})');
        if (i + 1 < count) {
          await Future<void>.delayed(Duration(milliseconds: intervalMs));
        }
      }
    } catch (e) {
      stderr.writeln('[shot] 失败: $e');
      exit(3);
    }
    exit(0);
  });
}
