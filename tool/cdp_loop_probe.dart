// 实测「长时间轮询」下 readCookiesFromPort 的稳定性：
// 每 1.5 秒读一次，连续 80 轮（约 2 分钟），记录每轮结果、耗时、异常。
// 目的：确认是否为连接老化/资源问题导致的"某轮起持续读取失败"。
//
// 用法：dart run tool/cdp_loop_probe.dart
// 日志：_shots/cdp_loop.log

import 'dart:io';

import 'package:douyin_desktop/core/browser_login.dart';

final String _logPath = '${Directory.current.path}\\_shots\\cdp_loop.log';

void log(String s) {
  final line = '${DateTime.now().toIso8601String()} $s';
  stdout.writeln(line);
  try {
    File(_logPath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

Future<void> main() async {
  log('=== cdp_loop_probe 开始 ===');
  final session = await QrLoginSession.start(onLog: (m) => log('[session] $m'));
  if (session == null) {
    log('启动失败');
    exit(2);
  }
  final port = session.debugPort;
  var fails = 0;
  var empties = 0;
  for (var i = 1; i <= 80; i++) {
    final sw = Stopwatch()..start();
    try {
      final cookies = await QrLoginSession.readCookiesFromPort(port);
      sw.stop();
      final names = cookies.map((c) => (c['name'] ?? '').toString()).toList();
      if (cookies.isEmpty) empties++;
      if (i % 5 == 0 || cookies.isEmpty || sw.elapsedMilliseconds > 1000) {
        log('第 $i 轮 count=${cookies.length} 耗时=${sw.elapsedMilliseconds}ms '
            'sessionid=${names.contains('sessionid') ? "有" : "无"}');
      }
    } catch (e) {
      sw.stop();
      fails++;
      log('第 $i 轮 异常（耗时=${sw.elapsedMilliseconds}ms）: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
  log('结果：80 轮，失败=$fails 空读=$empties');
  await session.close();
  log('=== cdp_loop_probe 结束 ===');
  exit(0);
}
