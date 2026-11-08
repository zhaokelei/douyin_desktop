// 手写握手 + 手写帧，确认 Edge 升级成功后到底需要什么（是否必须有 Origin），
// 以及发一条 Storage.getCookies 后会不会回包。
// 用法：dart run tool/raw_frame_probe.dart [port]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:douyin_desktop/core/platform_adapter.dart';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9338 : int.parse(args.first);
  final exe = PlatformAdapter.findChromiumBrowser();
  if (exe == null) return;
  final profile = await Directory.systemTemp.createTemp('raw_frame_probe_');
  final process = await Process.start(exe, [
    '--remote-debugging-port=$port',
    '--user-data-dir=${profile.path}',
    '--no-first-run',
    '--no-default-browser-check',
    '--remote-allow-origins=*',
    'about:blank',
  ], mode: ProcessStartMode.detached);

  String browserWs = '';
  for (var i = 0; i < 60 && browserWs.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      final client = HttpClient();
      final resp = await (await client.getUrl(
              Uri.parse('http://127.0.0.1:$port/json/version')))
          .close();
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      browserWs = (jsonDecode(text) as Map)['webSocketDebuggerUrl'].toString();
    } catch (_) {}
  }
  stdout.writeln('browserWs=$browserWs');
  if (browserWs.isEmpty) {
    process.kill();
    return;
  }
  final path = Uri.parse(browserWs).path;

  for (final withOrigin in [false, true]) {
    await _attempt(port, path, withOrigin);
  }

  process.kill();
  try {
    await profile.delete(recursive: true);
  } catch (_) {}
}

Future<void> _attempt(int port, String path, bool withOrigin) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final key = base64Encode(List<int>.generate(16, (_) => Random().nextInt(256)));
  socket.add(utf8.encode('GET $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Connection: Upgrade\r\n'
      'Upgrade: websocket\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      '${withOrigin ? "Origin: http://127.0.0.1:$port\r\n" : ""}'
      '\r\n'));

  final received = <int>[];
  var closed = false;
  final sub = socket.listen((chunk) {
    received.addAll(chunk);
  }, onDone: () {
    closed = true;
  }, onError: (Object e) {
    stdout.writeln('  错误：$e');
  });

  // 等 101 响应头
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final text = utf8.decode(received, allowMalformed: true);
    if (text.contains('\r\n\r\n')) break;
  }
  final headEnd = utf8
      .decode(received, allowMalformed: true)
      .indexOf('\r\n\r\n');
  final status = utf8
      .decode(received, allowMalformed: true)
      .split('\r\n')
      .first;
  stdout.writeln('Origin=$withOrigin 状态行: $status（收到 ${received.length} 字节）');
  if (!status.contains('101')) {
    await sub.cancel();
    socket.destroy();
    return;
  }
  final handshakeBytes = headEnd + 4;
  received.removeRange(0, handshakeBytes);

  // 发一条文本帧
  final payload = utf8.encode(jsonEncode(
      {'id': 1, 'method': 'Network.getAllCookies', 'params': {}}));
  final frame = BytesBuilder()..add([0x81]);
  if (payload.length < 126) {
    frame.add([payload.length]);
  } else {
    frame.add([126, (payload.length >> 8) & 0xff, payload.length & 0xff]);
  }
  frame.add(payload);
  socket.add(frame.toBytes());
  stdout.writeln('  已发送 ${payload.length} 字节命令，等待回包…');

  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (received.isNotEmpty || closed) break;
  }
  final tail = utf8.decode(received, allowMalformed: true);
  stdout.writeln('  收到 ${received.length} 字节，closed=$closed'
      '${tail.isEmpty ? "" : "，前 120 字：${tail.substring(0, tail.length > 120 ? 120 : tail.length)}"}');
  await sub.cancel();
  socket.destroy();
}
