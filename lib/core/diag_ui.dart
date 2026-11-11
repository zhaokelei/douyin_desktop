// 诊断能力的 Flutter 侧：安装、复制到剪贴板、导出文件、打开日志目录。
//
// 拆成两个文件的原因见 core/diag.dart 顶部注释（纯 Dart 探针不能被
// Flutter 依赖污染）。这里负责所有"需要引擎"的部分：
//   - 找日志目录（应用数据目录 / logs，失败降级到临时目录）
//   - 采集屏幕、语言、后端、用户设置这些只能从 Flutter 侧拿到的信息
//   - 未捕获异常钩子（FlutterError / PlatformDispatcher）
//   - 剪贴板 / 文件导出 / 打开目录

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show FlutterError, kDebugMode, kReleaseMode;
import 'package:flutter/services.dart';

import 'app_settings.dart';
import 'diag.dart';
import 'platform_adapter.dart';
import 'player_backend_config.dart';

/// 应用版本，与 pubspec.yaml 的 `version:` 保持一致。
///
/// 诊断报告里带上它，才能判断用户装的是哪一次构建。改版本号时同步这里。
const String kAppVersion = '1.0.0+1';

/// 用户点「复制诊断信息」时，除日志外还会附上这些实时状态。
class DiagUi {
  DiagUi._();

  static bool _installed = false;

  /// 日志目录：应用数据目录下的 logs。
  ///
  /// macOS 沙盒里 `~/Library/Application Support/douyin_desktop` 可写
  /// （浏览器登录、会话存储本来就落在这里），沿用同一位置最稳。
  static String get logDir {
    final base = PlatformAdapter.appDataDir;
    final sep = Platform.pathSeparator;
    if (base == null || base.isEmpty) {
      return '${Directory.systemTemp.path}${sep}douyin_logs';
    }
    return '$base${sep}logs';
  }

  static String get logFilePath => '$logDir${Platform.pathSeparator}diag.log';

  /// `DOUYIN_LOG` 显式指定时优先用它（自测/探针模式）。
  static String? get _envLogOverride {
    final v = Platform.environment['DOUYIN_LOG'];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 在 main() 里调用一次。
  static void install() {
    if (_installed) return;
    _installed = true;

    Diag.install(
      // 自测时可以用 DOUYIN_LOG 指定落盘位置（离屏探针就靠它抓日志）。
      logPath: _envLogOverride ?? logFilePath,
      appVersion: kAppVersion,
    );
    Diag.registerRuntime(_describeApp);
    Diag.registerRuntime(_describeDisplay);
    Diag.registerRuntime(_describeSettings);

    // 未捕获的 Flutter 异常：进日志，同时保持原有上报行为（链式调用）。
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      Diag.log(
        'flutter-error',
        '${details.exceptionAsString()}'
        '${details.library == null ? "" : " @ ${details.library}"}',
      );
      if (details.stack != null) {
        Diag.log('flutter-stack', '${details.stack}');
      }
      previous?.call(details);
    };

    ui.PlatformDispatcher.instance.onError = (error, stack) {
      Diag.recordCrash(error, stack);
      // 保持 false：与安装本钩子之前一致，不吞掉异常。
      return false;
    };

    Diag.log('startup',
        'DIAG 就绪：日志=$logFilePath 版本=$kAppVersion 后端=$playerBackendLabel');
  }

  /// 复制诊断报告到剪贴板，返回字符数（用于提示"已复制"）。
  static Future<int> copyReport({String? note}) async {
    final text = await Diag.buildReport(note: note);
    await Clipboard.setData(ClipboardData(text: text));
    Diag.log('diag', '已复制诊断信息（${text.length} 字符，来源=${note ?? "手动"}）');
    return text.length;
  }

  /// 把诊断报告另存为文件，返回路径。
  static Future<String> exportReport({String? note}) async {
    final text = await Diag.buildReport(note: note);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'diag-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.txt';
    final sep = Platform.pathSeparator;
    final file = File('$logDir$sep$name');
    await file.parent.create(recursive: true);
    await file.writeAsString(text, flush: true);
    Diag.log('diag', '已导出诊断文件 $name');
    return file.path;
  }

  /// 在系统文件管理器里打开日志目录。
  static Future<bool> openLogDir() async {
    try {
      final dir = Directory(logDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      if (Platform.isMacOS) {
        await Process.run('open', [dir.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dir.path]);
      } else {
        await Process.run('xdg-open', [dir.path]);
      }
      return true;
    } catch (e) {
      Diag.log('diag', '打开日志目录失败：$e');
      return false;
    }
  }

  // ------------------------------------------------------------- 快照采集

  static String _describeApp() {
    final mode = kReleaseMode
        ? 'release'
        : (kDebugMode ? 'debug' : 'profile');
    return '-------- 应用 --------\n'
        '播放后端: $playerBackendLabel\n'
        '构建模式: $mode\n'
        '日志文件: ${Diag.logPath}';
  }

  static String _describeDisplay() {
    final b = StringBuffer('-------- 显示 --------\n');
    try {
      final view = ui.PlatformDispatcher.instance.implicitView;
      if (view == null) {
        b.writeln('当前没有可用视图（可能处于后台或探针模式）');
      } else {
        final size = view.physicalSize;
        final dpr = view.devicePixelRatio;
        b.writeln('屏幕: ${size.width.toInt()}x${size.height.toInt()} 物理像素'
            ' · 缩放 ${dpr.toStringAsFixed(2)}x'
            ' · 逻辑 ${(size.width / dpr).round()}x${(size.height / dpr).round()}');
        b.writeln('刷新率: ${view.display.refreshRate.toStringAsFixed(0)} Hz');
      }
      final locale = ui.PlatformDispatcher.instance.locale;
      b.writeln('系统语言: ${locale.toLanguageTag()}');
    } catch (e) {
      b.writeln('采集显示信息失败: $e');
    }
    return b.toString();
  }

  static String _describeSettings() {
    final s = AppSettings.instance;
    final decode = s.decodeMode == DecodeMode.auto
        ? '自动（优先硬件解码）'
        : '仅软件解码';
    final cache = s.cacheMode == CacheMode.disk ? '磁盘缓存' : '不使用缓存';
    return '-------- 用户设置 --------\n'
        '解码方式: $decode\n'
        '缓存策略: $cache\n'
        '缓存上限: ${s.cacheLimitMB} MB\n'
        '默认清晰度: ${s.qualityPref}\n'
        '音量: ${s.volume.round()}';
  }
}
