// 直接测 RawWebSocket：连上 browser target 后发一条 Storage.getCookies，
// 打印收到的每一帧/错误/关闭，定位"连上但回包前被关闭"的原因。
// 用法：dart run tool/raw_ws_probe.dart [port]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/core/platform_adapter.dart';
import 'package:douyin_desktop/core/ws_client.dart';

Future<Map<String, dynamic>?> _json(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  try {
    final resp = await (await client.getUrl(Uri.parse(url))).close();
    final text = await resp.transform(utf8.decoder).join();
    final d = jsonDecode(text);
    return d is Map<String, dynamic> ? d : null;
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9336 : int.parse(args.first);
  final exe = PlatformAdapter.findChromiumBrowser();
  if (exe == null) return;
  final profile = await Directory.systemTemp.createTemp('raw_ws_probe_');
  final process = await Process.start(exe, [
    '--remote-debugging-port=$port',
    '--user-data-dir=${profile.path}',
    '--no-first-run',
    '--no-default-browser-check',
    '--remote-allow-origins=*',
    'about:blank',
  ], mode: ProcessStartMode.detached);

  Map<String, dynamic>? version;
  for (var i = 0; i < 60 && version == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      version = await _json('http://127.0.0.1:$port/json/version');
    } catch (_) {}
  }
  final browserWs = (version?['webSocketDebuggerUrl'] ?? '').toString();
  stdout.writeln('browserWs=$browserWs');
  if (browserWs.isEmpty) {
    process.kill();
    return;
  }

  final ws = await RawWebSocket.connect(browserWs);
  stdout.writeln('handshake ok');
  ws.messages.listen((msg) {
    stdout.writeln('recv ${msg.length} 字：${msg.substring(0, msg.length > 120 ? 120 : msg.length)}');
  }, onError: (Object e) {
    stdout.writeln('recv error: $e');
  }, onDone: () {
    stdout.writeln('stream done');
  });
  ws.sendText(jsonEncode({'id': 1, 'method': 'Storage.getCookies', 'params': {}}));
  stdout.writeln('sent');
  await Future<void>.delayed(const Duration(seconds: 3));
  await ws.close();
  process.kill();
  try {
    await profile.delete(recursive: true);
  } catch (_) {}
}
