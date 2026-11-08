// 登录链路自测开关（对应 `DOUYIN_LOGIN_PROBE=1`）。
//
// 目的是在**真实应用进程**里跑一遍「已登录 profile → 读到登录态 → 落盘」，
// 不经过界面、不弹交互。结果写进 `<数据目录>/logs/browser_login.log`，
// 也可以配合 `DOUYIN_LOG=1` 看 diag 日志。与 `DOUYIN_DECODE_PROBE` 的用法一致。
import 'dart:io';

import '../data/douyin_api.dart';
import 'browser_login.dart';
import 'cookie_db.dart';
import 'platform_adapter.dart';

Future<void> runLoginProbe() async {
  loginLog('=== 登录自测开始（profile 冷读，不走界面）===');
  final api = DouyinApi();

  Future<void> importCookies(List<Map<String, dynamic>> cookies, String via) async {
    final headers = <String, String>{};
    for (final c in cookies) {
      final name = (c['name'] ?? '').toString();
      final value = (c['value'] ?? '').toString();
      if (name.isEmpty || value.isEmpty) continue;
      final domain = (c['domain'] ?? '').toString();
      if (headers.containsKey(name) && !domain.startsWith('www.')) continue;
      headers[name] = value;
    }
    final path = api.saveCookieList(cookies);
    api.applyCookies(headers);
    loginLog('[$via] 导入完成：${cookies.length} 项，会话字段 '
        '${hasSessionCookie(cookies)}，落盘=${path ?? "失败"}');
  }

  // 1) 纯离线路径：直接读固定 profile 的 Cookie 数据库（浏览器必须没在跑）。
  final offline = await readCookiesFromProfile(PlatformAdapter.browserProfileDir);
  loginLog('离线读取：${offline.summary()}');
  loginLog('离线读取 profile=${offline.profileDir}，db=${offline.dbPath}');

  // DOUYIN_FORCE_OFFLINE=1 只验离线这条路：不启动浏览器，直接导入。
  if (Platform.environment['DOUYIN_FORCE_OFFLINE'] == '1') {
    if (offline.ok && hasSessionCookie(offline.cookies)) {
      await importCookies(offline.cookies, '离线');
      loginLog('自测结果：离线路径 PASS');
    } else {
      loginLog('自测结果：离线路径 FAIL（${offline.summary()}）');
    }
    return;
  }

  // 2) 真实链路：起浏览器（复用同一 profile）→ poll 首读 → 导入落盘。
  final session = await QrLoginSession.start(onLog: loginLog);
  if (session == null) {
    loginLog('自测失败：没有找到可用的浏览器');
    return;
  }
  QrLoginResult? result;
  try {
    result = await session.poll(
      interval: const Duration(milliseconds: 500),
      onPhase: (phase, message) => loginLog('phase=$phase $message'),
      onCookies: (cookies) => importCookies(cookies, 'CDP'),
    );
  } finally {
    loginLog('自测结果：$result');
    loginLog('读取诊断：${session.diagnostics}');
    await session.close();
  }

  // 3) 浏览器关了以后再读一次磁盘，验证"关掉后离线可用"。
  final afterClose = await readCookiesFromProfile(PlatformAdapter.browserProfileDir);
  loginLog('关闭后离线读取：${afterClose.summary()}');
}
