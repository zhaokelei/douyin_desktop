// 诊断日志与排障快照（纯 Dart 核心）。
//
// 设计目标：用户遇到"看起来不对"的情况时，**一键**把定位所需的信息
// 全部拿到手，不需要教他开环境变量、找日志文件、开调试面板。
//
// 为什么是纯 Dart（不 import flutter）：
// `tool/` 下有一批 `dart run` 的纯 Dart 探针，会间接引用到这里
// （douyin_api / video_cache → diag）。一旦本文件依赖 Flutter，
// 这些探针就再也跑不起来。剪贴板、屏幕尺寸、未捕获异常钩子这些
// 需要 Flutter 的能力，全部放在 core/diag_ui.dart。
//
// 分工：
//   - 本文件：内存环形缓冲 + 落盘（自动轮转）+ 运行时快照拼装 + 报告文本
//   - diag_ui.dart：安装（路径/异常钩子）、复制到剪贴板、导出文件、打开目录

import 'dart:async';
import 'dart:io';

/// 冷启动计时器：由 main() 的第一行启动，用于统计「main 开始 → 首屏就绪」。
Stopwatch? kStartupWatch;

/// 一条日志。
class DiagEntry {
  const DiagEntry(this.at, this.tag, this.message);

  final DateTime at;
  final String tag;
  final String message;

  String get line => '${Diag.stamp(at)} [$tag] $message';
}

/// 诊断日志中心。
///
/// 行为约定（重要，关系到性能）：
///   1. **永远**保留最近 [maxEntries] 条在内存里，供一键复制使用；
///   2. 落盘是**批量异步**的（默认 2 秒一次），不会让每条 mpv 日志
///      都产生一次同步 IO——播放页的日志量峰值能到每秒几十条；
///   3. 日志文件超过 [maxFileBytes] 自动轮转成 `diag.1.log`，
///      上限 2 个文件，不会把用户磁盘写满；
///   4. 任何一步失败都静默降级（记日志不能影响播放）。
class Diag {
  Diag._();

  /// 内存缓冲上限。按平均每行 120 字符算，约 200 KB～1 MB，可接受。
  static const int maxEntries = 2000;

  /// 单个日志文件上限，超过就轮转。
  static const int maxFileBytes = 4 * 1024 * 1024;

  /// 报告里附带的日志行数上限：太长反而不方便粘贴到聊天窗口。
  /// 完整日志仍在内存缓冲 / 日志文件里，导出或打开目录就能拿到。
  static const int maxReportLines = 120;

  /// 报告前半段"关键事件"的条数上限（已滤掉播放器原始日志）。
  static const int maxKeyLines = 160;

  /// 播放器原始日志的 tag：libmpv / libmdk 的逐行输出量极大，
  /// 且几乎全是缓冲进度、属性轮询这类噪音。报告里只作为附录给尾部若干行。
  static const Set<String> rawLogTags = {'mpv', 'mpv-props', 'avtrace'};

  static final List<DiagEntry> _entries = <DiagEntry>[];
  static final List<String Function()> _providers = <String Function()>[];

  static final StringBuffer _pending = StringBuffer();
  static Timer? _flushTimer;
  static String? _logPath;
  static String _appVersion = '';
  static int _dropped = 0;
  static bool _fileBroken = false;
  static bool _flushing = false;
  static DateTime? _startedAt;
  static String? _lastCrash;

  /// 升序的日志副本（最近的排在最后）。
  static List<DiagEntry> get entries => List<DiagEntry>.unmodifiable(_entries);

  static String get appVersion => _appVersion;

  static DateTime? get startedAt => _startedAt;

  /// 日志文件完整路径；未安装时返回提示文本。
  static String get logPath => _logPath ?? '(未启用)';

  /// 日志文件被丢弃的条数（环形缓冲溢出），排障时能判断是否漏了开头。
  static int get droppedCount => _dropped;

  static String? get lastCrash => _lastCrash;

  /// 初始化：记录版本号、日志路径，并启动批量落盘定时器。
  ///
  /// [logPath] 为 null 时只保留内存缓冲（纯 Dart 探针就是这种模式）。
  static void install({String? logPath, String appVersion = ''}) {
    _appVersion = appVersion;
    _startedAt ??= DateTime.now();
    _logPath = logPath;
    if (logPath != null) {
      try {
        File(logPath).parent.createSync(recursive: true);
        _rotateIfNeeded(logPath);
      } catch (_) {
        _fileBroken = true;
      }
    }
    _flushTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(flush());
    });
  }

  /// 写一条日志。签名与旧实现一致，调用点无需改动。
  static void log(String tag, String message) {
    final entry = DiagEntry(DateTime.now(), tag, redact(message));
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      final remove = _entries.length - maxEntries;
      _entries.removeRange(0, remove);
      _dropped += remove;
    }
    final path = _logPath;
    if (path == null || _fileBroken) return;
    _pending.write('${stamp(entry.at)} [$tag] ${_oneLine(entry.message)}\n');
    // 量大时（比如 mpv 疯狂重试）不等定时器，尽快摊到磁盘上。
    if (_pending.length > 48 * 1024) unawaited(flush());
  }

  /// 注册一段"运行时快照"。复制诊断信息时按顺序调用，输出原文。
  static void registerRuntime(String Function() provider) {
    if (!_providers.contains(provider)) _providers.add(provider);
  }

  static void unregisterRuntime(String Function() provider) {
    _providers.remove(provider);
  }

  /// 把内存里的日志刷进文件。
  static Future<void> flush() async {
    if (_flushing) return;
    final path = _logPath;
    if (path == null || _fileBroken || _pending.isEmpty) return;
    _flushing = true;
    final text = _pending.toString();
    _pending.clear();
    try {
      final file = File(path);
      await file.writeAsString(text, mode: FileMode.append, flush: false);
      if (await file.length() > maxFileBytes) _rotateIfNeeded(path);
    } catch (_) {
      // 只降级一次：磁盘满 / 无权限时不要让每次写日志都抛异常。
      _fileBroken = true;
    } finally {
      _flushing = false;
    }
  }

  /// 生成完整诊断报告（纯文本，Markdown 友好）。
  static Future<String> buildReport({String? note}) async {
    await flush();
    final b = StringBuffer();
    final now = DateTime.now();
    b.writeln('========== 抖音桌面版 诊断信息 ==========');
    b.writeln('生成时间: ${stamp(now)}  ${_utcOffset(now)}');
    if (_appVersion.isNotEmpty) b.writeln('应用版本: $_appVersion');
    if (note != null && note.isNotEmpty) b.writeln('触发来源: $note');
    final watch = kStartupWatch;
    if (watch != null) {
      // 首屏就绪后 home_shell 会 stop；仍在跑说明首屏还没出来（或卡住了）。
      b.writeln(watch.isRunning
          ? '启动耗时: 仍在计时（首屏未就绪）· 已运行 ${watch.elapsedMilliseconds} ms'
          : '启动耗时: main→首屏 ${watch.elapsedMilliseconds} ms');
    }
    if (_startedAt != null) {
      b.writeln('本次运行: ${_elapsedSince(_startedAt!, now)}');
    }
    b.writeln();

    b.writeln('-------- 运行环境 --------');
    b.writeln('系统: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    b.writeln('架构: ${_arch()}  ·  CPU 核数: ${Platform.numberOfProcessors}');
    b.writeln('Dart: ${Platform.version}');
    b.writeln('进程内存: ${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(0)} MB'
        '  ·  峰值: ${(ProcessInfo.maxRss / (1024 * 1024)).toStringAsFixed(0)} MB');
    b.writeln('可执行文件: ${Platform.resolvedExecutable}');
    if (_lastCrash != null) {
      b.writeln('最近一次未捕获异常: $_lastCrash');
    }
    b.writeln();

    for (final provider in _providers) {
      try {
        final text = provider().trimRight();
        if (text.isEmpty) continue;
        b.writeln(text);
        b.writeln();
      } catch (e) {
        b.writeln('(某段状态采集失败: $e)');
        b.writeln();
      }
    }

    final errors = _recentErrors(8);
    b.writeln('-------- 最近错误（最多 8 条）--------');
    if (errors.isEmpty) {
      b.writeln('（本次运行没有错误级日志）');
    } else {
      for (final e in errors) {
        b.writeln('${stamp(e.at)} [${e.tag}] ${_oneLine(e.message)}');
      }
    }
    b.writeln();

    final keyLines = <DiagEntry>[];
    for (var i = _entries.length - 1;
        i >= 0 && keyLines.length < maxKeyLines;
        i--) {
      if (rawLogTags.contains(_entries[i].tag)) continue;
      keyLines.add(_entries[i]);
    }
    b.writeln('-------- 关键事件（业务日志，最近 ${keyLines.length} 条）--------');
    if (keyLines.isEmpty) {
      b.writeln('（无）');
    } else {
      for (final e in keyLines.reversed) {
        b.writeln('${stamp(e.at)} [${e.tag}] ${_oneLine(e.message)}');
      }
    }
    b.writeln();

    b.writeln('-------- 原始日志（最近 ${_entries.length} 条'
        '${_dropped > 0 ? "，已丢弃更早的 $_dropped 条" : ""}'
        '，仅尾部 $maxReportLines 行）--------');
    final start = _entries.length > maxReportLines
        ? _entries.length - maxReportLines
        : 0;
    for (var i = start; i < _entries.length; i++) {
      final e = _entries[i];
      b.writeln('${stamp(e.at)} [${e.tag}] ${_oneLine(e.message)}');
    }
    b.writeln('========== 诊断信息结束 ==========');
    return b.toString();
  }

  /// 记录未捕获异常，复制报告时会带上。
  static void recordCrash(Object error, StackTrace? stack) {
    _lastCrash = '${stamp(DateTime.now())} $error';
    log('crash', '$error\n${stack ?? StackTrace.empty}');
  }

  /// URL 脱敏。
  ///
  /// 播放器日志会把整条播放地址打出来，而抖音的地址带 `sign` /
  /// `biz_sign` 等签名参数：既能定位到具体账号看了什么，也有时效性。
  /// 诊断报告是要交给开发者看的，所以统一把 query 段抹掉——
  /// host + path 足够判断"是不是 CDN、走的哪个接口"，签名不需要。
  static final RegExp _urlPattern = RegExp(r'https?://[^\s"<>]+');

  static String redact(String text) {
    if (!text.contains('http')) return text;
    return text.replaceAllMapped(_urlPattern, (m) {
      final raw = m.group(0)!;
      final q = raw.indexOf('?');
      if (q < 0) return raw;
      return '${raw.substring(0, q)}?<已脱敏>';
    });
  }

  // ------------------------------------------------------------------ 内部

  static List<DiagEntry> _recentErrors(int limit) {
    final result = <DiagEntry>[];
    for (var i = _entries.length - 1; i >= 0 && result.length < limit; i--) {
      final e = _entries[i];
      final tag = e.tag.toLowerCase();
      final msg = e.message.toLowerCase();
      if (tag.contains('error') ||
          tag == 'crash' ||
          msg.startsWith('error') ||
          msg.contains('failed') ||
          e.message.contains('失败')) {
        result.add(e);
      }
    }
    return result.reversed.toList();
  }

  static void _rotateIfNeeded(String path) {
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() <= maxFileBytes) return;
      final backup = File('$path.1');
      if (backup.existsSync()) backup.deleteSync();
      file.renameSync(backup.path);
    } catch (_) {
      // 轮转失败就继续追加，不能因此丢掉日志能力。
    }
  }

  /// 日志行格式：只到毫秒，够排障用，又不会太长。
  static String stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }

  /// 多行消息（异常栈、mpv 原文）压成一行，避免把日志结构撑乱。
  static String _oneLine(String text) =>
      text.replaceAll('\r', '').replaceAll('\n', ' ⏎ ');

  static String _utcOffset(DateTime t) {
    final d = t.timeZoneOffset;
    final sign = d.isNegative ? '-' : '+';
    final abs = d.abs();
    final h = abs.inHours.toString().padLeft(2, '0');
    final m = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return 'UTC$sign$h:$m ${t.timeZoneName}';
  }

  static String _elapsedSince(DateTime from, DateTime to) {
    final d = to.difference(from);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '$h 小时 $m 分' : (m > 0 ? '$m 分 $s 秒' : '$s 秒');
  }

  static String _arch() {
    // Dart 没有直接的 CPU 架构查询，用环境变量 + 指针宽度兜底。
    final env = Platform.environment;
    final arm = env['PROCESSOR_ARCHITECTURE']?.toLowerCase().contains('arm') ??
        false;
    if (arm) return 'arm64';
    if (Platform.isMacOS) {
      // Rosetta / 原生 arm64 都能跑，PROCESSOR_ARCHITECTURE 在 macOS 上
      // 不总是存在，用 sysctl 结果更准；失败就按 x64 处理。
      try {
        final r = Process.runSync('sysctl', ['-n', 'hw.optional.arm64']);
        if (r.exitCode == 0 && '${r.stdout}'.trim() == '1') return 'arm64';
      } catch (_) {}
      return 'x64';
    }
    return Platform.version.contains('arm') ? 'arm64' : 'x64';
  }
}

/// 兼容旧调用点的自由函数。
void diag(String tag, String message) => Diag.log(tag, message);
