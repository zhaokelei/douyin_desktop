// 复现「扫码后页面 target 变化 → CDP 页面级 websocket 连不上（HTTP 200）」
// 以及 browser 级 Storage.getCookies 是否仍可用。
//
// 用法：dart run tool/cdp_target_probe.dart
// 日志：_shots/cdp_target.log（不打印 Cookie 值）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/core/browser_login.dart';

final String _logPath = '${Directory.current.path}\\_shots\\cdp_target.log';

void log(String s) {
  final line = '${DateTime.now().toIso8601String()} $s';
  stdout.writeln(line);
  try {
    File(_logPath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

Future<dynamic> _http(String url, {String method = 'GET'}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    return {'status': resp.statusCode, 'text': text};
  } finally {
    client.close(force: true);
  }
}

Future<String> _wsTry(String wsUrl, String method, Map<String, dynamic> params) async {
  try {
    final socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 3));
    final c = Completer<String>();
    late StreamSubscription sub;
    sub = socket.listen((e) {
      try {
        final m = jsonDecode(e as String) as Map<String, dynamic>;
        if (m['id'] == 1) {
          if (!c.isCompleted) {
            c.complete(m['error'] != null ? 'CDP error: ${m['error']}' : 'OK');
          }
        }
      } catch (err) {
        if (!c.isCompleted) c.complete('decode error: $err');
      }
    });
    socket.add(jsonEncode({'id': 1, 'method': method, 'params': params}));
    try {
      final r = await c.future.timeout(const Duration(seconds: 5));
      return r;
    } finally {
      await sub.cancel();
      await socket.close();
    }
  } catch (e) {
    return 'EXCEPTION: $e';
  }
}

void _dump(String tag, List<Map<String, dynamic>> cookies) {
  final names = cookies.map((c) => (c['name'] ?? '').toString()).toList();
  final keys = ['sessionid', 'sessionid_ss', 'sid_tt', 'uid_tt', 'ttwid'];
  log('[$tag] count=${cookies.length} '
      '${[for (final k in keys) '$k=${names.contains(k) ? "有" : "无"}'].join(' ')}');
}

Future<void> main() async {
  log('=== cdp_target_probe 开始 ===');
  final session = await QrLoginSession.start(onLog: (m) => log('[session] $m'));
  if (session == null) {
    log('启动失败');
    exit(2);
  }
  final port = session.debugPort;
  log('port=$port');

  // A. 原始 target 情况
  final ver = await _http('http://127.0.0.1:$port/json/version');
  final vjson = jsonDecode((ver as Map)['text'] as String) as Map<String, dynamic>;
  log('[/json/version] status=${ver['status']} browser=${vjson['Browser']} '
      'ws=${vjson['webSocketDebuggerUrl']}');

  final list0 = await _http('http://127.0.0.1:$port/json/list');
  final arr0 = jsonDecode((list0 as Map)['text'] as String) as List;
  for (final raw in arr0) {
    final m = raw as Map;
    log('[/json/list] type=${m['type']} id=${m['id']} url=${m['url']} ws=${m['webSocketDebuggerUrl']}');
  }

  _dump('初始读取', await QrLoginSession.readCookiesFromPort(port));

  // B. 关掉一个新建的空 target，再用它的旧 ws 连接，确认是不是 HTTP 200。
  final created = await _http('http://127.0.0.1:$port/json/new?about:blank', method: 'PUT');
  final ctext = ((created as Map)['text'] as String);
  Map<String, dynamic>? cjson;
  try {
    cjson = jsonDecode(ctext) as Map<String, dynamic>;
  } catch (_) {
    log('/json/new 非 JSON: status=${created['status']} text=${ctext.substring(0, ctext.length > 80 ? 80 : ctext.length)}');
  }
  if (cjson != null) {
    final id = (cjson['id'] ?? '').toString();
    final ws = (cjson['webSocketDebuggerUrl'] ?? '').toString();
    log('新建 target id=$id ws=$ws');
    final closed = await _http('http://127.0.0.1:$port/json/close/$id');
    log('/json/close 返回 status=${(closed as Map)['status']} text=${closed['text']}');
    final r = await _wsTry(ws, 'Runtime.evaluate', {'expression': '1'});
    log('关闭后的 target 再连 ws → $r');
  }

  // C. 模拟"扫码成功后的页面跳转"：原 douyin 页 navigate 到另一个 URL。
  // 从最新 list 里找 douyin 页。
  final list1 = await _http('http://127.0.0.1:$port/json/list');
  String? douyinWs;
  String? douyinId;
  final arr1 = jsonDecode((list1 as Map)['text'] as String) as List;
  for (final raw in arr1) {
    final m = raw as Map;
    final url = (m['url'] ?? '').toString();
    if ((m['type'] ?? '') == 'page' && url.contains('douyin.com')) {
      douyinWs = (m['webSocketDebuggerUrl'] ?? '').toString();
      douyinId = (m['id'] ?? '').toString();
    }
  }
  log('douyin target id=$douyinId');
  if (douyinWs != null) {
    log('navigate 前 ws 可用性 → ${await _wsTry(douyinWs, 'Runtime.evaluate', {'expression': 'location.href'})}');
  }

  // 用 /json/new 打开一个新 douyin 页，然后关掉原 douyin 页（更贴近"页面被替换"）。
  final newPage = await _http('http://127.0.0.1:$port/json/new?https://www.douyin.com/', method: 'PUT');
  log('/json/new douyin → status=${(newPage as Map)['status']}');
  if (douyinId != null) {
    final closed = await _http('http://127.0.0.1:$port/json/close/$douyinId');
    log('关闭原 douyin target status=${(closed as Map)['status']}');
  }
  await Future<void>.delayed(const Duration(seconds: 4));

  final list2 = await _http('http://127.0.0.1:$port/json/list');
  final arr2 = jsonDecode((list2 as Map)['text'] as String) as List;
  for (final raw in arr2) {
    final m = raw as Map;
    log('[/json/list 替换后] type=${m['type']} id=${m['id']} url=${m['url']} ws=${m['webSocketDebuggerUrl']}');
  }

  // 生产读取函数在 target 变化后是否仍然可用？
  try {
    _dump('target 替换后读取', await QrLoginSession.readCookiesFromPort(port));
  } catch (e) {
    log('[target 替换后读取] 抛异常: $e');
  }

  // 页面级命令直接连新 douyin 页
  final list3 = await _http('http://127.0.0.1:$port/json/list');
  final arr3 = jsonDecode((list3 as Map)['text'] as String) as List;
  for (final raw in arr3) {
    final m = raw as Map;
    if ((m['type'] ?? '') == 'page' && (m['url'] ?? '').toString().contains('douyin.com')) {
      final r = await _wsTry((m['webSocketDebuggerUrl'] ?? '').toString(),
          'Network.getAllCookies', {});
      log('新 douyin 页 Network.getAllCookies → $r');
    }
  }

  await session.close();
  log('=== cdp_target_probe 结束 ===');
  exit(0);
}
