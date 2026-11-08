// 实测「固定持久 profile」：同一 profile 连续启动两次，第二次能否直接读到登录态。
//
// 用法：
//   $env:DOUYIN_PROFILE_DIR='C:\...\tmp_probe_profile'; dart run tool/profile_persist_probe.dart
// 日志：_shots/profile_persist.log（不打印 Cookie 值）
//
// 第一次：启动浏览器 -> 通过 CDP 注入带 sessionid 的 Cookie（模拟扫码成功）
//         -> 优雅关闭（Browser.close，让 Cookie 落盘）。
// 第二次：用同一 profile 启动 -> 直接读 Cookie（并跑一次 poll 的首读逻辑）
//         -> 断言 sessionid 仍存在 -> 关闭并清理测试目录。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/core/browser_login.dart';
import 'package:douyin_desktop/core/platform_adapter.dart';

final String _logPath = '${Directory.current.path}\\_shots\\profile_persist.log';

void log(String s) {
  final line = '${DateTime.now().toIso8601String()} $s';
  stdout.writeln(line);
  try {
    File(_logPath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

Future<Map<String, dynamic>> _httpJson(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<void> _injectSession(int port) async {
  final v = await _httpJson('http://127.0.0.1:$port/json/version');
  final ws = (v['webSocketDebuggerUrl'] ?? '').toString();
  if (ws.isEmpty) throw StateError('拿不到 browser ws');
  final socket =
      await WebSocket.connect(ws).timeout(const Duration(seconds: 3));
  final done = Completer<void>();
  late StreamSubscription sub;
  sub = socket.listen((e) {
    try {
      final m = jsonDecode(e as String) as Map<String, dynamic>;
      if (m['id'] == 1) {
        if (!done.isCompleted) {
          m['error'] != null
              ? done.completeError(StateError('CDP error: ${m['error']}'))
              : done.complete();
        }
      }
    } catch (err) {
      if (!done.isCompleted) done.completeError(err);
    }
  });
  try {
    socket.add(jsonEncode({
      'id': 1,
      'method': 'Storage.setCookies',
      'params': {
        'cookies': [
          for (final n in ['sessionid', 'sessionid_ss', 'sid_tt', 'uid_tt'])
            {
              'name': n,
              'value': 'probe_$n',
              'domain': '.douyin.com',
              'path': '/',
              'secure': true,
              'httpOnly': true,
              'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
            },
        ],
      },
    }));
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    await sub.cancel();
    await socket.close();
  }
}

String _cookieDbPath(Directory profile) {
  final sep = Platform.pathSeparator;
  final candidates = [
    '${profile.path}${sep}Default${sep}Network${sep}Cookies',
    '${profile.path}${sep}Default${sep}Cookies',
  ];
  for (final p in candidates) {
    if (File(p).existsSync()) {
      final len = File(p).lengthSync();
      return '$p（存在，${len ~/ 1024} KB）';
    }
  }
  return '未找到 Cookies 数据库';
}

void _dump(String tag, List<Map<String, dynamic>> cookies) {
  final names = cookies.map((c) => (c['name'] ?? '').toString()).toList();
  log('[$tag] count=${cookies.length} ${describeCookieKeys(cookies)} '
      'sessionid值长度=${names.contains('sessionid') ? cookies.firstWhere((c) => (c['name'] ?? '') == 'sessionid')['value'].toString().length : 0}');
}

Future<void> main() async {
  final expectedDir = PlatformAdapter.browserProfileDir;
  log('=== profile_persist_probe 开始 ===');
  log('固定 profile 路径（PlatformAdapter）= $expectedDir');

  // ---------------- 第一次启动（模拟扫码登录）----------------
  final s1 = await QrLoginSession.start(onLog: (m) => log('[1st] $m'));
  if (s1 == null) {
    log('第一次启动失败');
    exit(2);
  }
  log('第一次 profile=${s1.profileDir.path} port=${s1.debugPort}');
  log('第一次 profile 与平台固定路径一致=${s1.profileDir.path == expectedDir}');
  _dump('第一次注入前', await s1.readCookies());
  await _injectSession(s1.debugPort);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  _dump('第一次注入后', await s1.readCookies());

  final sw = Stopwatch()..start();
  await s1.close();
  sw.stop();
  log('第一次优雅关闭耗时=${sw.elapsedMilliseconds}ms');
  await Future<void>.delayed(const Duration(seconds: 1));
  log('第一次关闭后 Cookies 数据库：${_cookieDbPath(Directory(expectedDir))}');
  log('第一次关闭后 profile 目录仍存在=${Directory(expectedDir).existsSync()}');

  // ---------------- 第二次启动（应直接读到登录态）----------------
  final s2 = await QrLoginSession.start(onLog: (m) => log('[2nd] $m'));
  if (s2 == null) {
    log('第二次启动失败');
    exit(2);
  }
  log('第二次 profile=${s2.profileDir.path} port=${s2.debugPort}');
  log('两次 profile 相同=${s2.profileDir.path == expectedDir}');

  var secondOk = false;
  try {
    final cookies = await s2.readCookies();
    _dump('第二次读取', cookies);
    secondOk = hasSessionCookie(cookies);
    log('第二次直接读到会话=${secondOk ? "是（无需重新扫码）" : "否"}');
  } catch (e) {
    log('第二次读取异常：${briefError(e)}');
  }

  // 跑一次 poll 的"首读"路径，确认 App 的自动逻辑也会直接登录。
  QrLoginResult? pollResult;
  try {
    final r = await s2
        .poll(
          onPhase: (p, m) => log('[2nd poll] ${p.name} $m'),
          onCookies: (c) async => _dump('2nd poll onCookies', c),
        )
        .timeout(const Duration(seconds: 20));
    pollResult = r;
    log('第二次 poll 返回=${r.name}');
  } catch (e) {
    log('第二次 poll 异常：${briefError(e)}');
  }

  await s2.close();
  await Future<void>.delayed(const Duration(milliseconds: 800));

  log('结果：第二次读回登录态=${secondOk ? "PASS" : "FAIL"} '
      'poll=${pollResult?.name ?? "无"}');
  // 清理自测目录（不影响真实 profile）。
  try {
    Directory(expectedDir).delete(recursive: true);
    log('已清理自测 profile 目录');
  } catch (e) {
    log('清理自测目录失败（浏览器可能还没完全退出）：$e');
  }
  log('=== profile_persist_probe 结束 ${secondOk ? "PASS" : "FAIL"} ===');
  exit(secondOk ? 0 : 1);
}
