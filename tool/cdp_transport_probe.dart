// 验证自实现的 ws 客户端（RawWebSocket）能跑通 CDP 读取：
// 真实启动 Edge（临时 profile）→ readCookiesFromPort 连续读两轮 → 打印条数与关键 key。
// 用法：dart run tool/cdp_transport_probe.dart [port]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/core/browser_login.dart';
import 'package:douyin_desktop/core/platform_adapter.dart';

Future<bool> _waitCdp(int port) async {
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      final resp = await (await client.getUrl(
              Uri.parse('http://127.0.0.1:$port/json/version')))
          .close();
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (text.contains('webSocketDebuggerUrl')) return true;
    } catch (_) {}
  }
  return false;
}

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9335 : int.parse(args.first);
  final exe = PlatformAdapter.findChromiumBrowser();
  if (exe == null) {
    stdout.writeln('没有浏览器');
    return;
  }
  final profile = await Directory.systemTemp.createTemp('ws_client_probe_');
  final process = await Process.start(exe, [
    '--remote-debugging-port=$port',
    '--user-data-dir=${profile.path}',
    '--no-first-run',
    '--no-default-browser-check',
    '--remote-allow-origins=*',
    'https://www.douyin.com/',
  ], mode: ProcessStartMode.detached);

  final ready = await _waitCdp(port);
  stdout.writeln('CDP 就绪：$ready');
  for (var round = 1; round <= 2; round++) {
    try {
      final cookies = await QrLoginSession.readCookiesFromPort(port);
      stdout.writeln('第 $round 轮：count=${cookies.length} '
          '${describeCookieKeys(cookies)}');
    } catch (e) {
      stdout.writeln('第 $round 轮失败：$e');
    }
  }

  process.kill();
  try {
    await profile.delete(recursive: true);
  } catch (_) {}
}
