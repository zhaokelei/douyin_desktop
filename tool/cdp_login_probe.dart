// 实测「浏览器 Cookie 读回」链路：真实启动 Chromium + CDP，
// 分别用 browser 级 Storage.getCookies 与 page 级 Network.getAllCookies 读取，
// 注入本地已导出的 Cookie 后再读一遍，确认生产读取函数能否拿到 sessionid。
//
// 用法：dart run tool/cdp_login_probe.dart
// 日志：_shots/cdp_login.log（不打印任何 Cookie 值）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/core/browser_login.dart';
import 'package:douyin_desktop/core/platform_adapter.dart';

final File logFile =
    File(r'C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03\_shots\cdp_login.log');
final String cookieFile =
    r'C:\Users\Administrator\AppData\Roaming\douyin_desktop\douyin_cookies.json';

void log(String message) {
  final line = '${DateTime.now().toIso8601String()} $message';
  stdout.writeln(line);
  logFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// 打出关键 cookie 是否存在，以及 domain/httpOnly 等结构；不打印 value。
void dump(String tag, List<Map<String, dynamic>> list) {
  log('$tag count=${list.length}');
  final names = <String>[];
  for (final c in list) {
    final n = (c['name'] ?? '').toString();
    if (n.isNotEmpty) names.add(n);
  }
  log('$tag keys=${names.toSet().toList()}');
  for (final name in const [
    'sessionid',
    'sessionid_ss',
    'sid_tt',
    'uid_tt',
    'ttwid',
    'passport_csrf_token',
    'passport_auth_status',
  ]) {
    final hits = list.where((c) => (c['name'] ?? '').toString() == name);
    if (hits.isEmpty) {
      log('$tag TOPIC $name -> 不存在');
      continue;
    }
    for (final c in hits) {
      log('$tag TOPIC $name -> domain=${c['domain']} httpOnly=${c['httpOnly']} '
          'secure=${c['secure']} expires=${c['expires']} path=${c['path']}');
    }
  }
}

Future<Map<String, dynamic>?> cdp(
    String wsUrl, String method, Map<String, dynamic> params) async {
  final socket =
      await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 4));
  final completer = Completer<Map<String, dynamic>?>();
  late StreamSubscription sub;
  sub = socket.listen((event) {
    final msg = jsonDecode(event as String) as Map<String, dynamic>;
    if (msg['id'] != 1) return;
    if (msg['error'] != null) {
      if (!completer.isCompleted) completer.completeError(msg['error']);
    } else {
      if (!completer.isCompleted) {
        completer.complete(msg['result'] as Map<String, dynamic>?);
      }
    }
  }, onError: (Object e) {
    if (!completer.isCompleted) completer.completeError(e);
  }, onDone: () {
    if (!completer.isCompleted) completer.complete(null);
  });
  socket.add(jsonEncode({'id': 1, 'method': method, 'params': params}));
  try {
    return await completer.future.timeout(const Duration(seconds: 4));
  } finally {
    await sub.cancel();
    await socket.close();
  }
}

Future<Map<String, dynamic>?> httpJson(String url) async {
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

Future<List<dynamic>?> httpList(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    final decoded = jsonDecode(text);
    return decoded is List ? decoded : null;
  } finally {
    client.close(force: true);
  }
}

List<Map<String, dynamic>> cookiesOf(Map<String, dynamic>? result) {
  final raw = result?['cookies'];
  if (raw is! List) return const [];
  return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
}

Future<void> main() async {
  logFile.writeAsStringSync('');
  final exe = PlatformAdapter.findChromiumBrowser();
  log('browser=$exe');
  if (exe == null) return;

  const port = 9333;
  final profile = await Directory.systemTemp.createTemp('cdp_probe_');
  final process = await Process.start(exe, [
    '--remote-debugging-port=$port',
    '--user-data-dir=${profile.path}',
    '--no-first-run',
    '--no-default-browser-check',
    '--remote-allow-origins=*',
    'https://www.douyin.com/',
  ], mode: ProcessStartMode.detached);
  log('started pid=${process.pid} port=$port');

  String? browserWs;
  String? pageWs;
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      final version = await httpJson('http://127.0.0.1:$port/json/version');
      browserWs = (version?['webSocketDebuggerUrl'] ?? '').toString();
      final list = await httpList('http://127.0.0.1:$port/json/list');
      if (list != null) {
        final pages = <String>[];
        for (final raw in list) {
          if (raw is! Map) continue;
          pages.add('${raw['type']}:${raw['url']}');
          if ((raw['type'] ?? '') == 'page') {
            final ws = (raw['webSocketDebuggerUrl'] ?? '').toString();
            if (ws.isNotEmpty && pageWs == null) pageWs = ws;
          }
        }
        log('targets=${pages.join(" | ")}');
      }
      if (browserWs.isNotEmpty && pageWs != null) break;
    } catch (_) {}
  }
  if (browserWs == null || browserWs.isEmpty || pageWs == null) {
    log('CDP 未就绪 browserWs=$browserWs pageWs=$pageWs');
    process.kill();
    return;
  }
  log('browserWs=$browserWs');
  log('pageWs=$pageWs');

  // 1) 扫码前基线
  dump('基线/browser', cookiesOf(await cdp(browserWs, 'Storage.getCookies', const {})));
  dump('基线/page', cookiesOf(await cdp(pageWs, 'Network.getAllCookies', const {})));

  // 2) 注入本地已导出的 Cookie（模拟"浏览器里已登录"的状态）
  final payload = jsonDecode(File(cookieFile).readAsStringSync()) as List;
  final inject = <Map<String, dynamic>>[];
  for (final raw in payload) {
    final map = Map<String, dynamic>.from(raw as Map);
    final name = (map['name'] ?? '').toString();
    final value = (map['value'] ?? '').toString();
    if (name.isEmpty || value.isEmpty) continue;
    final expires = (map['expirationDate'] as num?)?.toDouble();
    inject.add({
      'name': name,
      'value': value,
      'domain': (map['domain'] ?? 'www.douyin.com').toString(),
      'path': '/',
      'expires': (expires == null || expires <= 0) ? -1 : expires,
      'httpOnly': map['httpOnly'] == true,
      'secure': map['secure'] == true,
    });
  }
  log('注入 ${inject.length} 项（来自本地导出）');
  try {
    await cdp(browserWs, 'Storage.setCookies', {'cookies': inject});
    log('Storage.setCookies 成功');
  } catch (e) {
    log('Storage.setCookies 失败: $e');
    try {
      await cdp(pageWs, 'Network.setCookies', {'cookies': inject});
      log('Network.setCookies 成功');
    } catch (e2) {
      log('Network.setCookies 失败: $e2');
    }
  }

  // 3) 注入后再读
  final afterBrowser = cookiesOf(await cdp(browserWs, 'Storage.getCookies', const {}));
  dump('注入后/browser', afterBrowser);
  final afterPage = cookiesOf(await cdp(pageWs, 'Network.getAllCookies', const {}));
  dump('注入后/page', afterPage);

  // 4) 直接调用生产读取函数
  try {
    final production = await QrLoginSession.readCookiesFromPort(port);
    dump('生产readCookies', production);
  } catch (e) {
    log('生产 readCookies 抛异常: $e');
  }

  // 5) 等页面真正加载完再看一次（登录页跳转场景）
  await Future<void>.delayed(const Duration(seconds: 4));
  dump('加载完成后/browser',
      cookiesOf(await cdp(browserWs, 'Storage.getCookies', const {})));
  try {
    final production = await QrLoginSession.readCookiesFromPort(port);
    dump('加载完成后/生产', production);
  } catch (e) {
    log('加载完成后生产读取抛异常: $e');
  }

  process.kill();
  try {
    await profile.delete(recursive: true);
  } catch (_) {}
  log('结束');
}
