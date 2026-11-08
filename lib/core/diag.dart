import 'dart:io';

/// 冷启动计时器：由 main() 的第一行启动，用于统计「main 开始 → 首屏就绪」。
Stopwatch? kStartupWatch;

/// 轻量诊断日志：只在设置了 DOUYIN_LOG 环境变量时写文件。
/// release 构建没有控制台，自测时用它把关键事件落盘。
void diag(String tag, String message) {
  final path = Platform.environment['DOUYIN_LOG'];
  if (path == null || path.isEmpty) return;
  try {
    File(path).writeAsStringSync(
      '${DateTime.now().toIso8601String()} [$tag] $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // 诊断失败不影响主流程
  }
}
