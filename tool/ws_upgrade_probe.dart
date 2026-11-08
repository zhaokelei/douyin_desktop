// 复现「ws 升级被拒、HTTP 200」：真实启动 Edge + CDP，用**原始 socket**
// 手工发 WebSocket 升级请求，把服务器返回的原始响应（状态行/头/体）打印出来，
// 再对比 Dart 的 WebSocket.connect，判断 200 到底是谁返回的、缺了什么。
//
// 用法：dart run tool/ws_upgrade_probe.dart [port]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:douyin_desktop/core/platform_adapter.dart';

void log(String message) => stdout.writeln(message);

Future<Map<String, dynamic>?> httpJson(String url, {String? headerOrigin}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (headerOrigin != null) req.headers.set('Origin', headerOrigin);
    final resp = await req.close();
    log('GET $url -> ${resp.statusCode}');
    final text = await resp.transform(utf8.decoder).join();
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } finally {
    client.close(force: true);
  }
}

/// 用原始 socket 发升级请求，返回服务器原始应答（截断到 2000 字节）。
Future<String> rawUpgrade(int port, String path,
    {String? origin, String? host, bool plainGet = false}) async {
  final socket = await Socket.connect('127.0.0.1', port,
      timeout: const Duration(seconds: 3));
  final key = base64Encode(List<int>.generate(16, (i) => (i * 7 + 3) % 256));
  final buf = StringBuffer()
    ..write('GET $path HTTP/1.1\r\n')
    ..write('Host: ${host ?? '127.0.0.1:$port'}\r\n');
  if (!plainGet) {
    buf
      ..write('Connection: Upgrade\r\n')
      ..write('Upgrade: websocket\r\n')
      ..write('Sec-WebSocket-Version: 13\r\n')
      ..write('Sec-WebSocket-Key: $key\r\n');
  }
  if (origin != null) buf.write('Origin: $origin\r\n');
  buf.write('\r\n');
  socket.add(utf8.encode(buf.toString()));

  final bytes = <int>[];
  try {
    await for (final chunk in socket.timeout(const Duration(seconds: 3))) {
      bytes.addAll(chunk);
      if (bytes.length > 2000) break;
      // 收到头结束即可（\r\n\r\n）；101 时也先拿一段。
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.contains('\r\n\r\n') && !text.startsWith('HTTP/1.1 101')) {
        break;
      }
      if (text.startsWith('HTTP/1.1 101') && bytes.length > 200) break;
    }
  } catch (e) {
    log('  读取响应出错（可能是升级成功后保持连接）：$e');
  } finally {
    socket.destroy();
  }
  final Uint8List raw = Uint8List.fromList(bytes);
  return utf8.decode(raw, allowMalformed: true);
}

void printResponse(String tag, String raw) {
  log('--- $tag 原始响应（${raw.length} 字节） ---');
  final lines = raw.split('\r\n');
  for (var i = 0; i < lines.length && i < 14; i++) {
    if (lines[i].isEmpty) break;
    log('  $lines[i]');
  }
  final headEnd = raw.indexOf('\r\n\r\n');
  if (headEnd > 0 && headEnd + 4 < raw.length) {
    final body = raw.substring(headEnd + 4);
    final cut = body.length > 400 ? '${body.substring(0, 400)}…' : body;
    log('  body: ${cut.replaceAll('\n', ' ').replaceAll('\r', '')}');
  } else if (raw.startsWith('HTTP/1.1 101')) {
    log('  （101 已建立，无响应体）');
  }
  log('---');
}

Future<void> dartWs(String tag, String wsUrl, {Map<String, dynamic>? headers}) async {
  try {
    final socket = await WebSocket.connect(wsUrl, headers: headers)
        .timeout(const Duration(seconds: 3));
    log('--- $tag Dart WebSocket.connect 成功 -> 发一条命令');
    socket.add(jsonEncode({'id': 1, 'method': 'Storage.getCookies', 'params': {}}));
    final first = await socket.first.timeout(const Duration(seconds: 3),
        onTimeout: () => '');
    log('  回包前 200 字: ${first.toString().substring(0, first.toString().length > 200 ? 200 : first.toString().length)}');
    await socket.close();
  } catch (e) {
    log('--- $tag Dart WebSocket.connect 失败: $e');
  }
}

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9333 : int.parse(args.first);
  final exe = PlatformAdapter.findChromiumBrowser();
  log('browser=$exe port=$port');
  if (exe == null) return;

  // 第二个参数可指定 profile 目录（默认临时目录），用来复现"持久 profile"下的行为。
  final profileDir = args.length > 1
      ? Directory(args[1])
      : await Directory.systemTemp.createTemp('ws_probe_');
  if (!profileDir.existsSync()) profileDir.createSync(recursive: true);
  final profile = profileDir;
  final process = await Process.start(exe, [
    '--remote-debugging-port=$port',
    '--user-data-dir=${profile.path}',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-features=Translate',
    '--remote-allow-origins=*',
    'about:blank',
  ], mode: ProcessStartMode.detached);
  log('started pid=${process.pid}');

  String? browserWs;
  String? pageWs;
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      final version = await httpJson('http://127.0.0.1:$port/json/version');
      browserWs = (version?['webSocketDebuggerUrl'] ?? '').toString();
      final listRaw = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:$port/json/list'))
          .then((r) => r.close());
      final text = await listRaw.transform(utf8.decoder).join();
      final list = jsonDecode(text);
      if (list is List) {
        for (final raw in list) {
          if (raw is! Map) continue;
          log('target: type=${raw['type']} url=${raw['url']} ws=${raw['webSocketDebuggerUrl']}');
          if ((raw['type'] ?? '') == 'page' && pageWs == null) {
            pageWs = (raw['webSocketDebuggerUrl'] ?? '').toString();
          }
        }
      }
      if (browserWs.isNotEmpty && pageWs != null) break;
    } catch (e) {
      log('等待 CDP: $e');
    }
  }
  log('browserWs=$browserWs');
  log('pageWs=$pageWs');
  if (browserWs == null || browserWs.isEmpty) {
    process.kill();
    return;
  }

  final browserPath = Uri.parse(browserWs).path;
  final pagePath = pageWs == null ? '' : Uri.parse(pageWs).path;

  // 1) 原始升级，Host 用 127.0.0.1:<port>（与 Dart 一致）
  printResponse('raw/browser 无 Origin',
      await rawUpgrade(port, browserPath));

  // 2) 原始升级，带 Origin
  printResponse('raw/browser 带 Origin',
      await rawUpgrade(port, browserPath, origin: 'http://127.0.0.1:$port'));

  // 3) Host 换成 localhost
  printResponse('raw/browser Host=localhost',
      await rawUpgrade(port, browserPath, host: 'localhost:$port'));

  // 4) 页面 target（若存在）
  if (pagePath.isNotEmpty) {
    printResponse('raw/page 无 Origin', await rawUpgrade(port, pagePath));
  }

  // 4.1) 普通 GET（不带 Upgrade 头）：看 devtools 对"非升级请求"返回什么状态
  printResponse('raw/browser 普通 GET（无 Upgrade）',
      await rawUpgrade(port, browserPath, plainGet: true));

  // 4.2) 升级到不存在的 target id：看未知路径返回什么状态
  printResponse(
      'raw/browser 升级到无效 GUID',
      await rawUpgrade(port, '/devtools/browser/00000000-0000-0000-0000-000000000000'));

  // 5) Dart 的 WebSocket.connect（生产代码用的就是它）
  await dartWs('dart/browser 无 Origin', browserWs);
  await dartWs('dart/browser 带 Origin', browserWs,
      headers: {'Origin': 'http://127.0.0.1:$port'});
  if (pageWs != null) {
    await dartWs('dart/page 无 Origin', pageWs);
  }

  // 6) Dart 用 localhost 替代 127.0.0.1
  final localhostWs = browserWs.replaceFirst('127.0.0.1', 'localhost');
  await dartWs('dart/browser Host=localhost', localhostWs);

  // 7) 127.0.0.1:9222 的直连是否被中间层改写（对照：随机闭端口）
  try {
    await Socket.connect('127.0.0.1', 65530, timeout: const Duration(seconds: 1));
    log('随机端口 65530 意外可连');
  } catch (e) {
    log('随机闭端口 65530 连接失败（正常）: ${e.runtimeType}');
  }

  process.kill();
  // 只有临时目录才删；指定持久 profile 时绝不能删（那是用户的登录态）。
  if (args.length <= 1) {
    try {
      await profile.delete(recursive: true);
    } catch (_) {}
  }  log('结束');
}
