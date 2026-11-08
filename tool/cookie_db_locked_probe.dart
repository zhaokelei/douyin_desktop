// 验证"浏览器正在运行、Cookie 库被独占"时，离线兜底是否仍能读出来。
// 用法：dart run tool/cookie_db_locked_probe.dart [profileDir]
import 'dart:async';
import 'dart:io';

import 'package:douyin_desktop/core/cookie_db.dart';
import 'package:douyin_desktop/core/platform_adapter.dart';

Future<void> main(List<String> args) async {
  final profilePath =
      args.isEmpty ? PlatformAdapter.browserProfileDir : args.first;
  final browserRunning = args.length > 1 && args[1] == 'running';

  var process = null as Process?;
  if (!browserRunning) {
    final exe = PlatformAdapter.findChromiumBrowser();
    if (exe == null) return;
    process = await Process.start(exe, [
      '--remote-debugging-port=9341',
      '--user-data-dir=$profilePath',
      '--no-first-run',
      '--no-default-browser-check',
      'about:blank',
    ], mode: ProcessStartMode.detached);
    // 等浏览器把 Cookie 库打开并持有锁
    await Future<void>.delayed(const Duration(seconds: 5));
  }

  final read = await readCookiesFromProfile(profilePath);
  stdout.writeln('profile  = ${read.profileDir}');
  stdout.writeln('db       = ${read.dbPath}');
  stdout.writeln('summary  = ${read.summary()}');
  stdout.writeln('error    = ${read.error}');

  process?.kill();
}
