// 扫码登录：用系统自带 Chromium 内核（Windows/macOS 是 Edge/Chrome，
// Linux 是 chrome/chromium）以「独立临时用户目录 + 远程调试端口」启动，
// 用户在浏览器里用抖音 App 扫码；本进程通过 CDP（Chrome DevTools Protocol）
// 轮询 cookie，拿到包含 httpOnly 的 sessionid 后导入。
//
// 为什么不用 WebView：webview_windows 只暴露 clearCookies，读不到 httpOnly
// cookie（sessionid 正是 httpOnly），扫码后拿不到登录态。CDP 能拿到全部
// cookie，而且三端一致，不新增原生依赖。
//
// 2026-11-07 修复：原来在 **browser 级** WebSocket 上直接发
// `Network.getAllCookies`（那是 page domain 的命令），CDP 返回
// "'Network.getAllCookies' wasn't found"，异常被吞掉，于是"浏览器里登录成功、
// App 一直没反应"。现在优先发 browser 级可用的 `Storage.getCookies`，
// 失败再回退到 douyin 页面 target 上的 `Network.getAllCookies`。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cookie_db.dart';
import 'diag.dart';
import 'error_text.dart';
import 'platform_adapter.dart';
import 'ws_client.dart';

/// 登录阶段：界面据此显示"等待扫码 / 已扫码 / 已登录"。
enum QrLoginPhase { launching, waiting, loggedIn, failed, cancelled }

/// 轮询结束原因。界面据此决定"要不要关掉浏览器、能不能点重新读取"。
enum QrLoginResult {
  /// 已读到会话 Cookie，且导入成功。
  loggedIn,

  /// 已读到会话 Cookie，但导入/落盘出错（浏览器保持打开，可手动重读）。
  importFailed,

  /// 3 分钟内没读到会话 Cookie（浏览器保持打开，可手动重读）。
  timeout,

  /// 会话被主动关闭。
  cancelled,
}

/// 能代表"已登录"的会话 Cookie。真实扫码后 `sessionid` 一定有，
/// 但不同端/不同版本可能只给 `sid_tt`/`uid_tt`，所以放宽判定。
const Set<String> kSessionCookieNames = {
  'sessionid',
  'sessionid_ss',
  'sid_tt',
  'uid_tt',
};

/// Cookie 列表里是否存在非空的会话 Cookie。
bool hasSessionCookie(List<Map<String, dynamic>> cookies) {
  for (final c in cookies) {
    final name = (c['name'] ?? '').toString();
    final value = (c['value'] ?? '').toString();
    if (value.isEmpty) continue;
    if (kSessionCookieNames.contains(name)) return true;
  }
  return false;
}

/// 关键 Cookie 存在性摘要（只输出名字与有无，不输出值）。
String describeCookieKeys(List<Map<String, dynamic>> cookies) {
  final names = {for (final c in cookies) (c['name'] ?? '').toString()};
  final keys = ['sessionid', 'sessionid_ss', 'sid_tt', 'uid_tt', 'ttwid'];
  return keys.map((k) => '$k=${names.contains(k) ? "有" : "无"}').join(' ');
}

/// 把异常压成一行**中文**短提示，避免长栈/长 URI 把界面撑爆。
///
/// 这里输出会直接显示给用户，所以先过 [ErrorText] 翻译；认不出来的原文
/// 不再甩给用户，而是换成通用中文说明（原始异常由调用方写进 loginLog）。
String briefError(Object e, {int max = 180}) {
  final s = ErrorText.from(e).replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length <= max ? s : '${s.substring(0, max)}…';
}

/// 登录关键事件的诊断日志：既走 diag（DOUYIN_LOG），也固定写一份到
/// `<数据目录>/logs/browser_login.log`，用户反馈问题时可直接取证。
/// 只记录路径、数量、关键 key 是否存在，绝不打印 Cookie 值。
void loginLog(String message) {
  diag('login', message);
  try {
    final dataDir = Directory(PlatformAdapter.browserProfileDir).parent;
    final file = File('${dataDir.path}${Platform.pathSeparator}logs'
        '${Platform.pathSeparator}browser_login.log');
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    if (file.existsSync() && file.lengthSync() > 2 * 1024 * 1024) {
      file.writeAsStringSync('', flush: true);
    }
    file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: true);
  } catch (_) {}
}

class QrLoginSession {
  QrLoginSession._(this._process, this._port, this._profileDir);

  final Process? _process;
  final int _port;
  final Directory _profileDir;
  bool _closed = false;

  static Future<QrLoginSession?> start(
      {void Function(String message)? onLog}) async {
    return _launch('https://www.douyin.com/', onLog: onLog);
  }

  /// 打开一个**正常可见**的浏览器窗口并导航到指定地址（风控验证用）。
  ///
  /// 与扫码登录共用同一套「固定 user-data-dir + CDP」机制：
  /// 用户在窗口里自己过滑块/验证，本进程只做只读轮询。
  static Future<QrLoginSession?> startAt(String url,
          {void Function(String message)? onLog}) async =>
      _launch(url, onLog: onLog);

  static Future<QrLoginSession?> _launch(String url,
      {void Function(String message)? onLog}) async {
    final exe = PlatformAdapter.findChromiumBrowser();
    if (exe == null) {
      onLog?.call('没有找到可用的 Chromium 浏览器（Edge/Chrome/Chromium）');
      return null;
    }
    // 固定、持久、跨次复用的 profile：
    // 登录与风控验证共用同一份，浏览器里已有的登录态下次能直接读出来。
    final profile = Directory(PlatformAdapter.browserProfileDir);
    try {
      if (!profile.existsSync()) profile.createSync(recursive: true);
    } catch (e) {
      onLog?.call('创建 profile 目录失败：${ErrorText.from(e)}');
    }
    loginLog('浏览器 profile（持久复用）：${profile.path}');

    // 用户上次没关窗口时，这个 profile 已有实例在跑，直接连上去读，
    // 避免"再开一个实例却因为 profile 被锁而失败"。
    final running = await _reuseRunning(profile, onLog: onLog);
    if (running != null) return running;

    // 先试 9222，被占用就换端口（端口只用于本机 CDP，不对外）。
    // 必须跳过已被监听的端口，否则会连到别人的浏览器实例，读到完全无关的 Cookie。
    for (final port in [9222, 9223, 9224, 9225]) {
      if (!await _isPortFree(port)) {
        onLog?.call('端口 $port 已被占用，跳过（避免连到非本应用启动的浏览器）');
        continue;
      }
      try {
        final process = await Process.start(exe, [
          '--remote-debugging-port=$port',
          '--user-data-dir=${profile.path}',
          '--no-first-run',
          '--no-default-browser-check',
          '--disable-features=Translate',
          '--remote-allow-origins=*',
          url,
        ], mode: ProcessStartMode.detached);
        final session = QrLoginSession._(process, port, profile);
        final ok = await session._waitForCdp();
        if (ok) {
          loginLog('浏览器已启动（$exe，端口 $port，地址 $url）');
          return session;
        }
        onLog?.call('端口 $port 上的 CDP 未就绪（10s）');
        await session.close();
      } catch (e) {
        onLog?.call('启动浏览器失败（端口 $port）：${ErrorText.from(e)}');
      }
    }
    return null;
  }

  /// 复用该 profile 上已在运行的浏览器实例（读 DevToolsActivePort 里的端口）。
  static Future<QrLoginSession?> _reuseRunning(Directory profile,
      {void Function(String message)? onLog}) async {
    final port = await _activePort(profile);
    if (port == null) return null;
    if (!await _portHasCdp(port)) return null;
    loginLog('该 profile 已有浏览器实例在运行（端口 $port），直接复用');
    return QrLoginSession._(null, port, profile);
  }

  /// Chromium 会把**实际**调试端口写进 `<profile>/DevToolsActivePort`。
  static Future<int?> _activePort(Directory profile) async {
    try {
      final f = File('${profile.path}${Platform.pathSeparator}DevToolsActivePort');
      if (!f.existsSync()) return null;
      final lines = await f.readAsLines();
      if (lines.isEmpty) return null;
      return int.tryParse(lines.first.trim());
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _portHasCdp(int port) async {
    try {
      final json = await _getJson('http://127.0.0.1:$port/json/version');
      return (json?['webSocketDebuggerUrl'] ?? '').toString().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 浏览器是否仍在运行（用户手动关掉窗口后轮询要能停下来）。
  bool get isAlive => !_closed;

  /// CDP 端口：仅用于自测脚本注入/读取，业务代码不需要关心。
  int get debugPort => _port;

  /// 当前浏览器使用的 profile 目录（持久复用，自测时用来断言"同一目录"）。
  Directory get profileDir => _profileDir;

  /// 当前所有 page target 的 URL，用于判断验证页是否已经跳回正常抖音页。
  Future<List<String>> pageUrls() async {
    if (_closed) return const [];
    final list = await _getJsonList('http://127.0.0.1:$_port/json/list');
    if (list == null) return const [];
    return [
      for (final raw in list)
        if (raw is Map && (raw['type'] ?? '') == 'page')
          (raw['url'] ?? '').toString(),
    ];
  }

  /// 读当前浏览器里的 douyin.com Cookie（含 httpOnly）。
  /// 与 poll 走同一条逻辑：CDP 优先，拿不到会话时自动改读本地 Cookie 库。
  Future<List<Map<String, dynamic>>> readCookies() => _readCookiesWithRetry();


  /// 轮询登录态：读到会话 Cookie 就交给 [onCookies] 导入。
  ///
  /// 返回结束原因：[QrLoginResult]。
  ///
  /// 关键约定（2026-11-07 修复）：
  ///   - 读取失败与"导入失败"分开上报，两者都不会静默转圈；
  ///   - [onCookies] 出错时立即结束轮询并返回 [QrLoginResult.importFailed]，
  ///     浏览器保持打开，界面可以点"重新读取登录状态"再抓一次；
  ///   - 每轮把两路读取的数量与关键 key 写进诊断日志（不打印值）。
  Future<QrLoginResult> poll({
    required void Function(QrLoginPhase phase, String message) onPhase,
    required Future<void> Function(List<Map<String, dynamic>> cookies) onCookies,
    Duration interval = const Duration(milliseconds: 1500),
  }) async {
    onPhase(QrLoginPhase.launching, '已打开浏览器，正在检查这个配置里是否已有登录态…');
    // 第 0 轮：profile 是持久复用的，如果里面已经登录过，直接读出来用，
    // 不要求用户重新扫码（Python 版就是这个行为）。
    try {
      final cached = await _readCookiesWithRetry();
      diag('login',
          '打开后首读：count=${cached.length} ${describeCookieKeys(cached)}');
      if (hasSessionCookie(cached)) {
        onPhase(QrLoginPhase.loggedIn, '已从浏览器配置读到登录态，正在导入 Cookie…');
        try {
          await onCookies(cached);
          return QrLoginResult.loggedIn;
        } catch (e) {
          loginLog('首读导入失败: $e');
          onPhase(QrLoginPhase.failed,
              '已从浏览器配置读到 ${cached.length} 项 Cookie，但导入/保存失败：${briefError(e)}');
          return QrLoginResult.importFailed;
        }
      }
      onPhase(QrLoginPhase.waiting, '这个浏览器配置里还没有登录态，请在窗口里扫码…\n$diagnostics');
    } catch (e) {
      loginLog('打开后首读失败: $e');
      loginLog('首读诊断：$diagnostics');
      // 只做一次原始取证，避免每 1.5 秒都去连一次 ws。
      await probeWsOnce();
      onPhase(QrLoginPhase.waiting,
          '读取登录态失败：${briefError(e)}\n$diagnostics');
    }
    var waitedMs = 0;
    var round = 0;
    var lastReadError = '';
    const limitMs = 180000;
    while (!_closed && waitedMs < limitMs) {
      await Future<void>.delayed(interval);
      if (_closed) return QrLoginResult.cancelled;
      waitedMs += interval.inMilliseconds;
      round++;
      List<Map<String, dynamic>> cookies;
      try {
        cookies = await _readCookiesWithRetry();
      } catch (e) {
        lastReadError = briefError(e);
        loginLog('第 $round 轮读取失败: $e');
        onPhase(QrLoginPhase.waiting,
            '读取失败（第 $round 轮，将自动重试）：$lastReadError\n$diagnostics');
        continue;
      }
      lastReadError = '';
      loginLog('第 $round 轮：count=${cookies.length} '
          '${describeCookieKeys(cookies)}');
      if (cookies.isEmpty) {
        onPhase(QrLoginPhase.waiting, '等待扫码…（已等待 ${waitedMs ~/ 1000}s，暂未读到 Cookie）');
        continue;
      }
      if (!hasSessionCookie(cookies)) {
        onPhase(QrLoginPhase.waiting,
            '等待扫码…（已等待 ${waitedMs ~/ 1000}s，读到 ${cookies.length} 项 Cookie，但还没有会话）');
        continue;
      }
      onPhase(QrLoginPhase.loggedIn, '登录成功，正在导入 Cookie…');
      try {
        await onCookies(cookies);
        return QrLoginResult.loggedIn;
      } catch (e) {
        // 已经读到了会话 Cookie，失败的是"保存/导入"这一段，不能笼统说成读取失败。
        loginLog('CDP 第 $round 轮导入失败: $e');
        onPhase(QrLoginPhase.failed,
            '已从浏览器读到 ${cookies.length} 项 Cookie，但导入/保存失败：${briefError(e)}');
        return QrLoginResult.importFailed;
      }
    }
    if (_closed) return QrLoginResult.cancelled;
    onPhase(
        QrLoginPhase.failed,
        '3 分钟内没有读到登录会话'
        '${lastReadError.isEmpty ? "。" : "（最近一次读取失败：$lastReadError）。"}'
        '请确认扫码的浏览器是由本应用打开的那个窗口，或点「重新读取登录状态」再试一次，'
        '也可以改用粘贴 Cookie。\n$diagnostics');
    return QrLoginResult.timeout;
  }

  /// 读一次 Cookie：先走 CDP（browser 级 + 页面级并集），CDP 拿不到会话时
  /// 自动改读**本地 Cookie 库**（完全不走网络，见 `cookie_db.dart`）。
  /// 两条路径各自的原因都记在 [diagnostics] 里，界面直接展示。
  Future<List<Map<String, dynamic>>> _readCookiesWithRetry() async {
    final cdpProblems = <String>[];
    var cdp = const <Map<String, dynamic>>[];
    // 自测开关：模拟"CDP 完全不可用"，用来验证离线兜底真的能顶上来。
    final offlineOnly = Platform.environment['DOUYIN_FORCE_OFFLINE'] == '1';
    for (var attempt = 1; !offlineOnly && attempt <= 2; attempt++) {
      try {
        cdp = await readCookiesFromPort(_port);
        break;
      } catch (e) {
        cdpProblems.add('第$attempt次 ${briefError(e)}');
        if (attempt == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
    if (offlineOnly) cdpProblems.add('DOUYIN_FORCE_OFFLINE=1，跳过 CDP');
    if (hasSessionCookie(cdp)) {
      diagnostics = 'CDP 读到 ${cdp.length} 项（${describeCookieKeys(cdp)}）';
      return cdp;
    }

    // CDP 失败、或读到了但没有会话 → 兜底读 profile 里的 Cookie 数据库。
    final db = await readCookiesFromProfile(_profileDir.path);
    diagnostics = 'profile=${_profileDir.path}\n'
        'CDP：${cdpProblems.isEmpty ? "读到 ${cdp.length} 项但没有会话 Cookie（${describeCookieKeys(cdp)}）" : cdpProblems.join('；')}\n'
        '本地 Cookie 库：${db.summary()}';
    if (db.ok && db.cookies.isNotEmpty) {
      loginLog('CDP 不可用或缺会话，改读本地 Cookie 库：${db.summary()}');
      final merged = <String, Map<String, dynamic>>{};
      _mergeCookies(merged, cdp);
      _mergeCookies(merged, db.cookies);
      return merged.values.toList();
    }
    if (cdpProblems.isEmpty && cdp.isNotEmpty) {
      // CDP 通、也有 Cookie，只是没有会话 Cookie（还在等扫码）——不算失败。
      return cdp;
    }
    throw StateError('两条路径都读取失败：CDP（${cdpProblems.join('；')}）；'
        '本地 Cookie 库（${db.summary()}）');
  }

  /// 最近一次读取的完整诊断（profile 路径 / 两条路径各自原因 / 条数 / 关键 key）。
  String diagnostics = '';

  /// CDP 握手失败时做一次原始取证：把服务器返回的**原始状态行**写进日志。
  /// 这样"200 到底是谁返回的、是不是把请求当普通 GET"有据可查，不再靠推测。
  Future<void> probeWsOnce() async {
    try {
      final browser = await _browserWsUrl(_port);
      if (browser == null) {
        loginLog('ws 取证：/json/version 里没有 webSocketDebuggerUrl');
        return;
      }
      try {
        final ws = await RawWebSocket.connect(browser);
        await ws.close();
        loginLog('ws 取证：用原始 socket 手工升级成功（101）→ 问题在 Dart ws 那一层');
      } on WsHandshakeException catch (e) {
        loginLog('ws 取证：用原始 socket 手工升级也失败 → ${e.brief()}');
      }
    } catch (e) {
      loginLog('ws 取证本身出错：${briefError(e)}');
    }
  }

  Future<bool> _waitForCdp() async {
    for (var i = 0; i < 40; i++) {
      try {
        final version = await _browserWsUrl(_port);
        // 同时确认页面 target 存在且是抖音页，避免连到别的浏览器实例。
        final page = await _pageWsUrl(_port);
        if (version != null && page != null) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  static Future<bool> _isPortFree(int port) async {
    try {
      final socket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _browserWsUrl(int port) async {
    final json = await _getJson('http://127.0.0.1:$port/json/version');
    final ws = (json?['webSocketDebuggerUrl'] ?? '').toString();
    return ws.isEmpty ? null : ws;
  }

  /// douyin.com 的页面 target（`Network.getAllCookies` 只能在页面上下文跑）。
  static Future<String?> _pageWsUrl(int port) async {
    final list = await _getJsonList('http://127.0.0.1:$port/json/list');
    if (list == null) return null;
    Map<String, dynamic>? fallback;
    for (final raw in list) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      if (map['type'] != 'page') continue;
      fallback ??= map;
      final url = (map['url'] ?? '').toString();
      if (url.contains('douyin.com')) {
        final ws = (map['webSocketDebuggerUrl'] ?? '').toString();
        if (ws.isNotEmpty) return ws;
      }
    }
    final ws = (fallback?['webSocketDebuggerUrl'] ?? '').toString();
    return ws.isEmpty ? null : ws;
  }

  static Future<Map<String, dynamic>?> _getJson(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
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

  static Future<List<dynamic>?> _getJsonList(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
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

  /// 读当前浏览器里的 douyin.com Cookie（含 httpOnly）。
  ///
  /// 2026-11-07 修复：browser 级 `Storage.getCookies` 与页面级
  /// `Network.getAllCookies` **两路都读、取并集**。原来只要 browser 级这轮
  /// 返回空就整轮回退页面级，而扫码后页面 target 会被替换/关闭，页面级 ws
  /// 握手直接返回 HTTP 200，于是界面卡在"CDP 读取失败"继续转圈。
  /// 现在任一路成功就返回结果，两路都失败才抛异常（异常里带两路原因）。
  static Future<List<Map<String, dynamic>>> readCookiesFromPort(
      int port) async {
    final problems = <String>[];
    final merged = <String, Map<String, dynamic>>{};
    var okPaths = 0;

    // 1) browser 级：不依赖具体页面，扫码后页面跳转也不影响。
    try {
      final browser = await _browserWsUrl(port);
      if (browser == null) {
        problems.add('browser 级 ws 不可用（/json/version 无 webSocketDebuggerUrl）');
      } else {
        final list = await _sendCommand(browser, 'Storage.getCookies', const {});
        if (list == null) {
          problems.add('Storage.getCookies 无返回');
        } else {
          okPaths++;
          final filtered = _onlyDouyin(list);
          diag('login',
              'Storage.getCookies：原始 ${list.length} 条，douyin.com ${filtered.length} 条');
          _mergeCookies(merged, filtered);
        }
      }
    } catch (e) {
      problems.add('Storage.getCookies: ${briefError(e)}');
    }

    // 2) 页面级：补齐 browser 级拿不到的项；每轮重新取 target（页面会跳转）。
    try {
      final page = await _pageWsUrl(port);
      if (page == null) {
        problems.add('页面级 ws 不可用（/json/list 里没有 type=page 的 target）');
      } else {
        final list = await _sendCommand(page, 'Network.getAllCookies', const {});
        if (list == null) {
          problems.add('Network.getAllCookies 无返回');
        } else {
          okPaths++;
          final filtered = _onlyDouyin(list);
          diag('login',
              'Network.getAllCookies：原始 ${list.length} 条，douyin.com ${filtered.length} 条');
          _mergeCookies(merged, filtered);
        }
      }
    } catch (e) {
      problems.add('Network.getAllCookies: ${briefError(e)}');
    }

    if (okPaths == 0) {
      throw StateError('CDP 两路都读取失败：${problems.join('；')}');
    }
    return merged.values.toList();
  }

  /// 按 name+domain 合并两路结果（同名同域只留一条有值的）。
  static void _mergeCookies(
      Map<String, Map<String, dynamic>> sink, List<Map<String, dynamic>> list) {
    for (final c in list) {
      final name = (c['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final domain = (c['domain'] ?? '').toString();
      final key = '$name@$domain';
      final existing = sink[key];
      if (existing == null || (existing['value'] ?? '').toString().isEmpty) {
        sink[key] = c;
      }
    }
  }

  static List<Map<String, dynamic>> _onlyDouyin(
      List<Map<String, dynamic>> cookies) {
    return cookies
        .where((c) => (c['domain'] ?? '').toString().contains('douyin.com'))
        .toList();
  }

  static Future<List<Map<String, dynamic>>?> _sendCommand(
      String wsUrl, String method, Map<String, dynamic> params) async {
    // 用自实现的 ws 客户端：握手请求由我们逐字节发出，失败时能带回原始响应。
    final socket =
        await RawWebSocket.connect(wsUrl, timeout: const Duration(seconds: 3));
    final completer = Completer<List<Map<String, dynamic>>?>();
    const id = 1; // 每条连接只发一个命令，固定 id 即可。
    late StreamSubscription sub;
    sub = socket.messages.listen((event) {
      try {
        final msg = jsonDecode(event) as Map<String, dynamic>;
        if (msg['id'] != id) return;
        final result = msg['result'];
        if (result is Map && result['cookies'] is List) {
          final list = (result['cookies'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          if (!completer.isCompleted) completer.complete(list);
        } else if (msg['error'] != null) {
          if (!completer.isCompleted) completer.completeError(msg['error']);
        }
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      }
    }, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    }, onDone: () {
      // 连接在回包前被对方关掉：明确报错，不要静默返回空列表
      // （否则会表现为"读到 0 条"，掩盖真实的连接问题）。
      if (!completer.isCompleted) {
        completer.completeError(
            StateError('CDP 连接在返回结果前被关闭（$method）'));
      }
    });
    try {
      socket.sendText(jsonEncode({
        'id': id,
        'method': method,
        'params': params,
      }));
      return await completer.future.timeout(const Duration(seconds: 3));
    } finally {
      await sub.cancel();
      await socket.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    loginLog('关闭浏览器（profile 保留，下次继续复用）：${_profileDir.path}');
    // 先让浏览器自己退出：强杀会让 Cookie 数据库来不及写盘，
    // 下次用同一个 profile 启动就会丢掉登录态（表现为"每次都要重扫"）。
    final replied = await _requestBrowserClose();
    if (replied) {
      // 等 CDP 端口真正释放（最多 5 秒），确保 Cookie 已经落盘。
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!await _portHasCdp(_port)) {
          loginLog('浏览器已正常退出（耗时 ${(i + 1) * 250}ms）');
          return;
        }
      }
    }
    // 优雅关闭没成功再强杀；profile 目录必须保留，绝不删除。
    loginLog('优雅关闭未生效，强制结束进程');
    try {
      _process?.kill();
    } catch (_) {}
  }

  /// 通过 CDP 的 `Browser.close` 让浏览器正常退出（会 flush Cookie 到磁盘）。
  Future<bool> _requestBrowserClose() async {
    try {
      final browser = await _browserWsUrl(_port);
      if (browser == null) return false;
      final socket = await RawWebSocket.connect(browser,
          timeout: const Duration(seconds: 2));
      socket.sendText(jsonEncode({'id': 1, 'method': 'Browser.close'}));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
