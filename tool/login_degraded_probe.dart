// 验证修复效果：页面 target 失效（扫码后跳转/关闭）时，poll 仍能靠
// browser 级 Storage.getCookies 拿到会话 Cookie 并触发 onCookies。
//
// 场景：启动浏览器 -> 启动 poll -> 关闭唯一的 douyin 页面 target（让页面级
// 读取必然失败）-> 通过 browser ws 注入含 sessionid 的 Cookie -> 观察 poll。
//
// 用法：dart run tool/login_degraded_probe.dart
// 日志：_shots/login_degraded.log

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/core/browser_login.dart';

final String _logPath = '${Directory.current.path}\\_shots\\login_degraded.log';

void log(String s) {
  final line = '${DateTime.now().toIso8601String()} $s';
  stdout.writeln(line);
  try {
    File(_logPath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

Future<dynamic> _http(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    return {'status': resp.statusCode, 'text': text};
  } finally {
    client.close(force: true);
  }
}

Future<void> _wsCommand(
    String wsUrl, String method, Map<String, dynamic> params) async {
  final socket =
      await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 3));
  final c = Completer<void>();
  late StreamSubscription sub;
  sub = socket.listen((e) {
    try {
      final m = jsonDecode(e as String) as Map<String, dynamic>;
      if (m['id'] == 1) {
        if (!c.isCompleted) {
          if (m['error'] != null) {
            c.completeError(StateError('CDP error: ${m['error']}'));
          } else {
            c.complete();
          }
        }
      }
    } catch (err) {
      if (!c.isCompleted) c.completeError(err);
    }
  });
  try {
    socket.add(jsonEncode({'id': 1, 'method': method, 'params': params}));
    await c.future.timeout(const Duration(seconds: 5));
  } finally {
    await sub.cancel();
    await socket.close();
  }
}

Future<void> main() async {
  // 同 login_poll_probe：会注入假 sessionid，必须隔离 profile，
  // 否则会覆盖用户浏览器里真实的登录态。
  final profileOverride = Platform.environment['DOUYIN_PROFILE_DIR'];
  if (profileOverride == null || profileOverride.isEmpty) {
    log('拒绝对主 profile 注入假 Cookie：请先设置 DOUYIN_PROFILE_DIR 到临时目录');
    exit(2);
  }
  log('=== login_degraded_probe 开始（隔离 profile=$profileOverride）===');
  final session = await QrLoginSession.start(onLog: (m) => log('[session] $m'));
  if (session == null) {
    log('启动失败');
    exit(2);
  }
  final port = session.debugPort;
  final done = Completer<void>();
  QrLoginResult? result;

  final pollFuture = session.poll(
    onPhase: (phase, message) => log('[phase] ${phase.name} $message'),
    onCookies: (cookies) async {
      log('[onCookies] count=${cookies.length} ${describeCookieKeys(cookies)}');
      if (!done.isCompleted) done.complete();
    },
  ).then((r) {
    result = r;
    log('poll 返回: ${r.name}');
  });

  await Future<void>.delayed(const Duration(seconds: 3));

  // 1) 关掉唯一的 douyin 页面 target -> 页面级读取必失败。
  final list = await _http('http://127.0.0.1:$port/json/list');
  final arr = jsonDecode((list as Map)['text'] as String) as List;
  var closed = 0;
  for (final raw in arr) {
    final m = raw as Map;
    if ((m['type'] ?? '') == 'page') {
      final r = await _http('http://127.0.0.1:$port/json/close/${m['id']}');
      log('关闭 page ${m['id']} -> status=${(r as Map)['status']}');
      closed++;
    }
  }
  log('已关闭 page 数=$closed');

  // 2) 通过 browser ws 注入会话 Cookie（不依赖页面）。
  final ver = await _http('http://127.0.0.1:$port/json/version');
  final vjson = jsonDecode((ver as Map)['text'] as String) as Map<String, dynamic>;
  final browserWs = (vjson['webSocketDebuggerUrl'] ?? '').toString();
  log('browser ws=${browserWs.isEmpty ? "不可用" : "可用"}');
  try {
    await _wsCommand(browserWs, 'Storage.setCookies', {
      'cookies': [
        for (final n in ['sessionid', 'sessionid_ss', 'sid_tt', 'uid_tt'])
          {
            'name': n,
            'value': 'probe_$n',
            'domain': '.douyin.com',
            'path': '/',
            'secure': true,
            'httpOnly': true,
          },
      ],
    });
    log('注入会话 Cookie 成功');
  } catch (e) {
    log('注入失败: $e');
  }

  try {
    await done.future.timeout(const Duration(seconds: 10));
  } catch (_) {}

  // 直接验证生产读取函数在"没有页面 target"时是否仍能读到。
  try {
    final cookies = await QrLoginSession.readCookiesFromPort(port);
    log('无页面 target 时 readCookiesFromPort count=${cookies.length} '
        '${describeCookieKeys(cookies)}');
  } catch (e) {
    log('无页面 target 时读取异常: ${briefError(e)}');
  }

  log('结果：onCookies ${done.isCompleted ? "已触发" : "未触发"} '
      'pollResult=${result?.name ?? "未返回"}');
  await session.close();
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await pollFuture.timeout(const Duration(seconds: 3), onTimeout: () {});
  log('=== login_degraded_probe 结束 ${done.isCompleted ? "PASS" : "FAIL"} ===');
  exit(done.isCompleted ? 0 : 1);
}
