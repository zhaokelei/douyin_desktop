// 验证扫码登录的 CDP 读取链路（无窗口：headless Edge，不会弹窗打扰）。
//
// 用 headless Chromium 起一个临时实例，注入假 cookie，再调用生产代码
// QrLoginSession.readCookiesFromPort 读取，确认 browser 级 Storage.getCookies
// 这条路径真的能拿到 cookie（上一版发的是页面级 Network.getAllCookies，
// 在 browser ws 上必然报 "command not found"）。
//
// 用法：dart run tool/cdp_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/core/browser_login.dart';

const _port = 9333;

Future<void> main() async {
  final exe = _findChromium();
  if (exe == null) {
    print('[fail] 没有找到 Edge/Chrome/Chromium');
    exit(2);
  }
  final profile = await Directory.systemTemp.createTemp('cdp_probe_');
  final proc = await Process.start(exe, [
    '--headless=new',
    '--remote-debugging-port=$_port',
    '--user-data-dir=${profile.path}',
    '--no-first-run',
    '--no-default-browser-check',
    'about:blank',
  ], mode: ProcessStartMode.detached);
  print('[launch] $exe port=$_port');

  String? browserWs;
  for (var i = 0; i < 40; i++) {
    try {
      final json = await _getJson('http://127.0.0.1:$_port/json/version');
      final ws = (json?['webSocketDebuggerUrl'] ?? '').toString();
      if (ws.isNotEmpty) {
        browserWs = ws;
        break;
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (browserWs == null) {
    print('[fail] CDP 未就绪');
    proc.kill();
    exit(3);
  }
  print('[cdp] browser ws ready');

  final injected = await _send(browserWs, 'Storage.setCookies', {
    'cookies': [
      {
        'name': 'sessionid',
        'value': 'probe_fake_session',
        'domain': 'www.douyin.com',
        'path': '/',
        'secure': true,
        'httpOnly': true,
      },
      {
        'name': 'ttwid',
        'value': 'probe_ttwid',
        'domain': '.douyin.com',
        'path': '/',
        'secure': true,
      },
    ],
  });
  print('[inject] ok=${injected != null}');

  // 复现上一版的错误用法：在 browser 级 ws 上直接发页面级命令。
  // 这里应该报错，正是"浏览器登录成功、App 没反应"的根因证据。
  try {
    final legacy = await _send(browserWs, 'Network.getAllCookies', const {});
    print('[legacy] Network.getAllCookies@browser 返回=${legacy == null ? "null" : legacy.keys.join(",")}');
  } catch (e) {
    print('[legacy] 旧写法失败（根因证据）: $e');
  }

  // 关键：调用生产代码读取，而不是复刻一份逻辑。
  final cookies = await QrLoginSession.readCookiesFromPort(_port);
  final names = cookies.map((c) => (c['name'] ?? '').toString()).toList();
  final hasSession = cookies.any((c) => (c['name'] ?? '') == 'sessionid');
  print('[read] count=${cookies.length} hasSessionid=$hasSession names=${names.join(",")}');

  try {
    proc.kill();
  } catch (_) {}
  try {
    profile.deleteSync(recursive: true);
  } catch (_) {}

  if (hasSession) {
    print('[PASS] CDP 能读到 httpOnly sessionid');
  } else {
    print('[FAIL] CDP 没读到 sessionid');
    exit(4);
  }
}

Future<Map<String, dynamic>?> _getJson(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>?> _send(
    String wsUrl, String method, Map<String, dynamic> params) async {
  final socket = await WebSocket.connect(wsUrl)
      .timeout(const Duration(seconds: 3));
  final completer = Completer<Map<String, dynamic>?>();
  const id = 1;
  late StreamSubscription sub;
  sub = socket.listen((event) {
    final msg = jsonDecode(event as String) as Map<String, dynamic>;
    if (msg['id'] != id) return;
    if (!completer.isCompleted) {
      if (msg['error'] != null) {
        completer.completeError(msg['error']!);
        return;
      }
      completer.complete(msg['result'] is Map
          ? Map<String, dynamic>.from(msg['result'] as Map)
          : null);
    }
  }, onError: (Object e) {
    if (!completer.isCompleted) completer.completeError(e);
  });
  socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
  try {
    return await completer.future.timeout(const Duration(seconds: 4));
  } finally {
    await sub.cancel();
    await socket.close();
  }
}

String? _findChromium() {
  final env = Platform.environment;
  for (final root in [
    env['ProgramFiles'],
    env['ProgramFiles(x86)'],
    env['LOCALAPPDATA'],
  ]) {
    if (root == null) continue;
    for (final name in ['Microsoft\\Edge\\Application\\msedge.exe',
      'Google\\Chrome\\Application\\chrome.exe']) {
      final path = '$root\\$name';
      if (File(path).existsSync()) return path;
    }
  }
  return null;
}
