// 实测扫码登录的「轮询检测」链路（真实启动浏览器 + 真实 poll）。
//
// 目的：确认 QrLoginSession.poll() 在浏览器里出现 sessionid 之后，
// 是否会在下一轮读到并触发 onCookies；以及触发时 cookies 数量、关键 key。
//
// 做法：真实调用生产 QrLoginSession.start()，然后 unawaited 跑 poll()，
// 3 秒后通过 CDP（browser 级 Storage.setCookies）注入一组含 sessionid
// 的假 Cookie，观察 onCookies 是否被调用。
//
// 用法：dart run tool/login_poll_probe.dart
// 日志：_shots/login_poll.log（不打印 Cookie 值）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:douyin_desktop/core/browser_login.dart';

final List<String> _lines = [];
final String _logPath = _absLogPath();

String _absLogPath() {
  final dir = Directory.current.path;
  final shots = Directory('$dir\\_shots');
  if (!shots.existsSync()) shots.createSync(recursive: true);
  return '${shots.path}\\login_poll.log';
}

void log(String s) {
  final line = '${DateTime.now().toIso8601String()} $s';
  _lines.add(line);
  stdout.writeln(line);
  try {
    File(_logPath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

/// browser 级 WebSocket，发一条命令，等 id 对应的回包。
Future<Map<String, dynamic>?> _ws(String wsUrl, String method,
    Map<String, dynamic> params) async {
  final socket =
      await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 3));
  final completer = Completer<Map<String, dynamic>?>();
  late StreamSubscription sub;
  sub = socket.listen((event) {
    try {
      final msg = jsonDecode(event as String) as Map<String, dynamic>;
      if (msg['id'] != 1) return;
      if (!completer.isCompleted) completer.complete(msg);
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(e);
    }
  });
  socket.add(jsonEncode({'id': 1, 'method': method, 'params': params}));
  Map<String, dynamic>? resp;
  try {
    resp = await completer.future.timeout(const Duration(seconds: 5));
  } finally {
    await sub.cancel();
    await socket.close();
  }
  return resp;
}

Future<String?> _browserWs(int port) async {
  final client = HttpClient();
  try {
    final req =
        await client.getUrl(Uri.parse('http://127.0.0.1:$port/json/version'));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    final m = jsonDecode(text) as Map<String, dynamic>;
    final ws = (m['webSocketDebuggerUrl'] ?? '').toString();
    return ws.isEmpty ? null : ws;
  } finally {
    client.close(force: true);
  }
}

/// 注入一组假 Cookie（只用于验证"读回链路"，不请求任何接口）。
Future<int> _inject(int port, String sessionValue) async {
  final ws = await _browserWs(port);
  if (ws == null) {
    log('注入失败：拿不到 browser ws');
    return 0;
  }
  final cookies = <Map<String, dynamic>>[
    for (final n in ['sessionid', 'sessionid_ss', 'sid_tt', 'uid_tt', 'ttwid'])
      {
        'name': n,
        'value': n == 'sessionid' ? sessionValue : 'probe_$n',
        'domain': '.douyin.com',
        'path': '/',
        'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        'secure': true,
        'httpOnly': true,
      },
  ];
  final resp = await _ws(ws, 'Storage.setCookies', {'cookies': cookies});
  final err = resp?['error'];
  log('Storage.setCookies → ${err == null ? "OK" : "error: $err"}');
  return err == null ? cookies.length : 0;
}

void _dumpKeys(String tag, List<Map<String, dynamic>> cookies) {
  final names = cookies.map((c) => (c['name'] ?? '').toString()).toList();
  final keys = ['sessionid', 'sessionid_ss', 'sid_tt', 'uid_tt', 'ttwid'];
  final present = [
    for (final k in keys) '$k=${names.contains(k) ? "有" : "无"}'
  ].join(' ');
  final domains =
      cookies.map((c) => (c['domain'] ?? '').toString()).toSet().join(',');
  log('[$tag] count=${cookies.length} $present domains=[$domains]');
}

Future<void> main() async {
  // 安全护栏：这个探针会注入假的 sessionid。一旦跑在用户真实 profile 上，
  // 会把浏览器里已登录的 sessionid 覆盖掉（2026-11-07 已发生过一次，
  // 导致后续所有"已登录"实测都被污染）。所以必须显式指定临时 profile。
  final profileOverride = Platform.environment['DOUYIN_PROFILE_DIR'];
  if (profileOverride == null || profileOverride.isEmpty) {
    log('拒绝对主 profile 注入假 Cookie：请先设置 DOUYIN_PROFILE_DIR 到临时目录');
    exit(2);
  }
  log('=== login_poll_probe 开始（隔离 profile=$profileOverride）===');
  final session = await QrLoginSession.start(onLog: (m) => log('[session] $m'));
  if (session == null) {
    log('启动浏览器失败，退出');
    exit(2);
  }
  final port = session.debugPort;
  log('session 已启动，port=$port');

  var sawCookies = 0;
  var loggedInPhase = false;
  QrLoginResult? pollResult;
  var done = Completer<void>();

  final pollFuture = session.poll(
    onPhase: (phase, message) {
      log('[phase] ${phase.name} $message');
      if (phase == QrLoginPhase.loggedIn) loggedInPhase = true;
    },
    onCookies: (cookies) async {
      sawCookies = cookies.length;
      _dumpKeys('onCookies', cookies);
      log('onCookies 触发！count=${cookies.length}');
      if (!done.isCompleted) done.complete();
    },
  ).then((r) {
    pollResult = r;
    log('poll 返回结果: ${r.name}');
  });

  // 3 秒后注入（确保首轮读不到 -> 注入后应能读到）。
  await Future<void>.delayed(const Duration(seconds: 3));
  final before = await QrLoginSession.readCookiesFromPort(port);
  _dumpKeys('注入前', before);

  final injected = await _inject(port, 'probe_session_value');
  log('注入条数=$injected');

  await Future<void>.delayed(const Duration(milliseconds: 500));
  final after = await QrLoginSession.readCookiesFromPort(port);
  _dumpKeys('注入后（生产读取函数）', after);

  // 最多等 12 秒，看 poll 会不会触发 onCookies。
  try {
    await done.future.timeout(const Duration(seconds: 12));
  } catch (_) {}

  log('结果：onCookies ${done.isCompleted ? "已触发" : "未触发"} '
      'count=$sawCookies loggedInPhase=$loggedInPhase '
      'pollResult=${pollResult?.name ?? "未返回"}');
  await session.close();
  // poll 的 while 会因 _closed 退出，给它一点时间收尾。
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await pollFuture.timeout(const Duration(seconds: 3), onTimeout: () {});
  log('=== login_poll_probe 结束 ${done.isCompleted ? "PASS" : "FAIL"} ===');
  exit(done.isCompleted ? 0 : 1);
}
