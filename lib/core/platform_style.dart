import 'dart:io' show Platform;

/// 三端桌面风格档位。移动端不在此阶段范围内。
enum DesktopFlavor { windows, macOS, linux }

DesktopFlavor get desktopFlavor {
  if (Platform.isMacOS) return DesktopFlavor.macOS;
  if (Platform.isWindows) return DesktopFlavor.windows;
  return DesktopFlavor.linux;
}

/// 数字展示：1.2万 / 12.3万 / 1234
String formatCount(num value) {
  final n = value.toInt();
  if (n >= 100000000) {
    final v = n / 100000000;
    return '${_trim(v)}亿';
  }
  if (n >= 10000) {
    final v = n / 10000;
    return '${_trim(v)}万';
  }
  return n.toString();
}

String _trim(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

String formatDuration(int milliseconds) {
  if (milliseconds <= 0) return '00:00';
  final total = (milliseconds / 1000).round();
  final m = total ~/ 60;
  final s = total % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 毫秒时长格式化为 mm:ss（进度条用）。
String formatClock(double milliseconds) {
  if (milliseconds <= 0) return '00:00';
  final total = (milliseconds / 1000).round();
  final m = total ~/ 60;
  final s = total % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// "1天前 / 3小时前"式相对时间（传入 Unix 秒）。
String formatTimeAgo(int unixSeconds) {
  if (unixSeconds <= 0) return '刚刚';
  final now = DateTime.now();
  final t = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays < 1) return '${diff.inHours}小时前';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
  return '${(diff.inDays / 365).floor()}年前';
}
