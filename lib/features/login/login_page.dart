// 登录页：扫码登录（系统浏览器 + CDP 轮询） + 粘贴 Cookie 导入。
// 两种方式都直接作用于当前 DouyinApi 会话，成功后无需重启应用。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/browser_login.dart';
import '../../core/cookie_db.dart';
import '../../core/error_text.dart';
import '../../data/douyin_api.dart';
import '../../data/session_store.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.api, this.onLoggedIn});

  final DouyinApi api;
  final VoidCallback? onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _cookieController = TextEditingController();
  final SessionStore _store = SessionStore();

  QrLoginSession? _session;
  QrLoginPhase _phase = QrLoginPhase.cancelled;
  String _message = '';

  /// 读取诊断：profile 路径 + CDP 与本地 Cookie 库两条路径各自的原因 + 条数/关键 key。
  String _diagnostics = '';
  bool _importing = false;
  String? _importError;
  String? _importSuccess;

  /// 已经成功导入过一次：防止"手动重读 + 后台轮询"同时命中导致重复导入/重复跳转。
  bool _imported = false;

  /// 轮询是否在进行中（区别于点"重新读取"这类一次性操作）。
  bool _polling = false;

  @override
  void dispose() {
    _cookieController.dispose();
    _session?.close();
    super.dispose();
  }

  Future<void> _startQrLogin() async {
    if (_polling) return;
    // 上一个浏览器实例（超时/失败后仍开着）先关掉，避免端口与窗口混乱。
    final old = _session;
    if (old != null) {
      await old.close();
      _session = null;
    }
    setState(() {
      _polling = true;
      _phase = QrLoginPhase.launching;
      _message = '正在打开浏览器…';
      _diagnostics = '';
      _importError = null;
      _importSuccess = null;
      _imported = false;
    });
    final session = await QrLoginSession.start(onLog: loginLog);
    if (session == null) {
      setState(() {
        _polling = false;
        _phase = QrLoginPhase.failed;
        _message = '没有找到可用的浏览器（Edge / Chrome / Chromium），请改用粘贴 Cookie';
      });
      return;
    }
    _session = session;
    try {
      final result = await session.poll(
        onPhase: (phase, message) {
          if (!mounted) return;
          setState(() {
            _phase = phase;
            _message = message;
            _diagnostics = session.diagnostics;
          });
        },
        onCookies: _importBrowserCookies,
      );
      // 只有"已登录/已取消"才关掉浏览器；导入失败或超时保持打开，
      // 用户还能点「重新读取登录状态」再抓一次。
      if (result == QrLoginResult.loggedIn ||
          result == QrLoginResult.cancelled) {
        await session.close();
        _session = null;
      } else if (!_imported) {
        // CDP 一直读不到（例如 ws 握手被中间层改写）时，浏览器开着会把
        // Cookie 库独占锁住，离线也读不了。所以超时后先关浏览器，
        // 再从磁盘读一次：只要用户确实登录了，这一步就能拿到。
        await _readOfflineAfterClose(session);
      }
    } finally {
      _polling = false;
      if (mounted) setState(() {});
    }
  }

  /// 关掉浏览器后从磁盘读一次 Cookie。
  ///
  /// 为什么必须先关：Windows 下 Chromium 是**独占**打开
  /// `<profile>/Default/Network/Cookies` 的，浏览器运行期间任何进程都打不开，
  /// 所以"CDP 不可用"时唯一的离线通道就是先把浏览器关掉（Cookie 已经落盘）。
  Future<bool> _readOfflineAfterClose(QrLoginSession session) async {
    final profile = session.profileDir.path;
    await session.close();
    if (mounted) {
      setState(() {
        _session = null;
        _message = 'CDP 不可用，已关闭浏览器并从磁盘读取登录态…';
      });
    }
    final read = await readCookiesFromProfile(profile);
    if (!mounted) return false;
    setState(() => _diagnostics = '关闭浏览器后离线读取：${read.summary()}');
    if (read.ok && hasSessionCookie(read.cookies)) {
      try {
        await _importBrowserCookies(read.cookies);
        return true;
      } catch (e) {
        if (!mounted) return false;
        setState(() {
          _phase = QrLoginPhase.failed;
          _importError = '从磁盘读到 ${read.cookies.length} 项 Cookie，但导入失败：'
              '${briefError(e)}';
        });
        return false;
      }
    }
    if (mounted) {
      setState(() {
        _phase = QrLoginPhase.failed;
        _message = '没有读到登录态：${read.summary()}';
      });
    }
    return false;
  }

  Future<void> _importBrowserCookies(
      List<Map<String, dynamic>> cookies) async {
    if (_imported) return;
    final headers = <String, String>{};
    for (final c in cookies) {
      final name = (c['name'] ?? '').toString();
      final value = (c['value'] ?? '').toString();
      if (name.isEmpty || value.isEmpty) continue;
      // 同名 Cookie 优先 www.douyin.com（比 .douyin.com 更具体）。
      final domain = (c['domain'] ?? '').toString();
      if (headers.containsKey(name) && !domain.startsWith('www.')) continue;
      headers[name] = value;
    }
    if (headers.isEmpty) {
      throw StateError('CDP 返回的 ${cookies.length} 项 Cookie 里没有可用的 name=value');
    }
    if (!hasSessionCookie(cookies)) {
      throw StateError(
          'Cookie 里没有会话字段（sessionid/sessionid_ss/sid_tt/uid_tt），这不是登录态');
    }
    final path = widget.api.saveCookieList(cookies);
    widget.api.applyCookies(headers);
    await _store.saveCookie(
        headers.entries.map((e) => '${e.key}=${e.value}').join('; '));
    if (!mounted) return;
    _imported = true;
    setState(() {
      _phase = QrLoginPhase.loggedIn;
      _message = '登录成功';
      _importError = null;
      _importSuccess = path == null
          ? '登录态已写入内存与本地会话，但 douyin_cookies.json 写盘失败（重启后可能丢失）'
          : '登录成功，Cookie 已保存到 $path';
    });
    widget.onLoggedIn?.call();
    // 落盘成功后异步校验一次账号（只读接口，失败只提示不回滚登录态）。
    unawaited(_verifyAccountAfterImport());
  }

  Future<void> _verifyAccountAfterImport() async {
    try {
      final self = await widget.api.fetchSelfProfile();
      final user = self['user'];
      final nickname = user is Map ? (user['nickname'] ?? '').toString() : '';
      if (!mounted || nickname.isEmpty) return;
      setState(() {
        _importSuccess = '${_importSuccess ?? '登录成功'}，当前账号：$nickname';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importError = 'Cookie 已保存，但账号校验失败：${briefError(e)}'
            '（若反复失败请重新扫码）';
      });
    }
  }

  /// 手动兜底：立刻再抓一次 Cookie。
  ///
  /// 浏览器还开着就直接读；已经关了就**重新用同一个持久 profile 打开**，
  /// 打开后 poll 的第 0 轮首读会自动命中并导入，不需要重新扫码。
  Future<void> _rereadCookies() async {
    final session = _session;
    if (session == null) {
      if (_polling) return;
      setState(() {
        _message = '正在用同一个浏览器配置重新读取登录状态…';
        _importError = null;
      });
      await _startQrLogin();
      return;
    }
    setState(() {
      _message = '正在从浏览器重新读取登录状态…';
      _importError = null;
    });
    try {
      final cookies = await session.readCookies();
      if (!mounted) return;
      if (cookies.isEmpty) {
        setState(() {
          _phase = QrLoginPhase.failed;
          _diagnostics = session.diagnostics;
          _message = '浏览器里没有读到任何 douyin.com Cookie：'
              '请确认是在本应用打开的窗口里完成扫码';
        });
        return;
      }
      if (!hasSessionCookie(cookies)) {
        setState(() {
          _phase = QrLoginPhase.waiting;
          _diagnostics = session.diagnostics;
          _message = '读到 ${cookies.length} 项 Cookie，但还没有会话字段'
              '（${describeCookieKeys(cookies)}）：扫码可能还没完成，'
              '或扫码的窗口不是本应用打开的那个';
        });
        return;
      }
      await _importBrowserCookies(cookies);
      await session.close();
      if (mounted) {
        setState(() {
          _session = null;
          _diagnostics = session.diagnostics;
        });
      }
    } catch (e) {
      if (!mounted) return;
      // CDP 读不到时（浏览器开着还会把 Cookie 库独占锁住），退一步：
      // 关掉浏览器 → 从磁盘读 → 有会话就直接导入。
      final ok = await _readOfflineAfterClose(session);
      if (ok || !mounted) return;
      setState(() {
        _phase = QrLoginPhase.failed;
        _diagnostics = session.diagnostics;
        _message = '重新读取失败：${briefError(e)}';
      });
    }
  }

  Future<void> _importCookieText() async {
    final text = _cookieController.text.trim();
    if (text.isEmpty) {
      setState(() => _importError = '请先粘贴 Cookie');
      return;
    }
    setState(() {
      _importing = true;
      _importError = null;
      _importSuccess = null;
    });
    try {
      final cookies = DouyinApi.parseCookieInput(text);
      if (cookies.isEmpty) {
        throw Exception('没解析出任何 Cookie（需要 name=value 形式）');
      }
      if (cookies['sessionid'] == null || cookies['sessionid']!.isEmpty) {
        throw Exception('粘贴内容里没有 sessionid，不是登录态 Cookie');
      }
      widget.api.applyCookies(cookies);
      // 关键：粘贴导入必须落盘，否则重启后（启动只查文件）就变回游客态。
      final path = widget.api.saveCookieHeader(text);
      await _store.saveCookie(
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
      // 立刻验证一次登录态，避免"看起来导入了其实已过期"。
      String nickname = '';
      try {
        final self = await widget.api.fetchSelfProfile();
        final user = self['user'];
        if (user is Map) nickname = (user['nickname'] ?? '').toString();
      } catch (e) {
        throw Exception('${path == null ? "Cookie 写盘失败（仅存于本地会话）" : "已保存到 $path"}'
            '，但账号校验失败：${_shortError(e)}');
      }
      if (!mounted) return;
      setState(() {
        _importSuccess =
            '导入成功${nickname.isEmpty ? '' : '，当前账号：$nickname'}';
        _phase = QrLoginPhase.loggedIn;
      });
      widget.onLoggedIn?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _importError = _shortError(e));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = widget.api.isLoggedIn;
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        title: const Text('抖音账号登录', style: TextStyle(fontSize: 16)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _statusCard(loggedIn),
                const SizedBox(height: 22),
                _qrSection(),
                const SizedBox(height: 22),
                _cookieSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusCard(bool loggedIn) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1D),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(loggedIn ? Icons.verified_user : Icons.person_outline,
              color: loggedIn ? const Color(0xFF4CD38A) : const Color(0xFF9A9A9A)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              loggedIn ? '当前已登录（Cookie 里有 sessionid）' : '当前是游客态，登录后才能点赞/收藏/分享',
              style: const TextStyle(color: Color(0xFFDDDDDD), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _qrSection() {
    final busy = _polling ||
        _phase == QrLoginPhase.launching ||
        _phase == QrLoginPhase.waiting;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1D),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('扫码登录',
              style: TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            '会打开系统浏览器，使用固定持久的独立配置目录（不会碰你日常浏览器的配置）：'
            '如果这个配置里已经登录过，会直接读回登录态，不用重新扫码；'
            '没登录时才需要点右上角「登录」用抖音 App 扫码。'
            '如果扫码成功但界面没反应，点「重新读取登录状态」直接再抓一次。',
            style: TextStyle(color: Color(0xFF9A9A9A), fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : _startQrLogin,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFE2C55),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.qr_code_2, size: 18),
                label: Text(busy ? '等待扫码…' : '开始扫码登录'),
              ),
              OutlinedButton.icon(
                onPressed: _rereadCookies,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDDDDDD),
                  side: const BorderSide(color: Color(0xFF3A3A3A)),
                ),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新读取登录状态'),
              ),
            ],
          ),
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _message,
              style: TextStyle(
                color: _phase == QrLoginPhase.failed
                    ? const Color(0xFFFF6B6B)
                    : const Color(0xFF9A9A9A),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          if (_diagnostics.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF141414),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2C2C2C)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('读取诊断',
                      style: TextStyle(
                          color: Color(0xFF7E7E7E),
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(
                    _diagnostics,
                    style: const TextStyle(
                      color: Color(0xFFB8B8B8),
                      fontSize: 11.5,
                      height: 1.45,
                      fontFamily: 'Consolas',
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_importError != null) ...[
            const SizedBox(height: 8),
            Text(_importError!,
                style: const TextStyle(
                    color: Color(0xFFFF6B6B), fontSize: 12, height: 1.4)),
          ],
          if (_importSuccess != null) ...[
            const SizedBox(height: 8),
            Text(_importSuccess!,
                style: const TextStyle(
                    color: Color(0xFF4CD38A), fontSize: 12, height: 1.4)),
          ],
        ],
      ),
    );
  }

  Widget _cookieSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1D),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('粘贴 Cookie 导入',
              style: TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            '支持两种格式：浏览器请求头 `a=1; b=2`，或 Cookie 导出扩展的 JSON。'
            '必须含 sessionid，导入后会立刻调用一次账号接口校验是否有效。',
            style: TextStyle(color: Color(0xFF9A9A9A), fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cookieController,
            maxLines: 6,
            style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 12.5),
            decoration: InputDecoration(
              hintText: 'sessionid=...; ttwid=...; passport_csrf_token=...',
              hintStyle: const TextStyle(color: Color(0xFF5A5A5A), fontSize: 12),
              filled: true,
              fillColor: const Color(0xFF141414),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF2C2C2C)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(
                onPressed: _importing ? null : _importCookieText,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2F80ED),
                  foregroundColor: Colors.white,
                ),
                child: Text(_importing ? '导入中…' : '导入'),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () async {
                  final text = _cookieController.text.trim();
                  if (text.isEmpty) return;
                  await Clipboard.setData(ClipboardData(text: text));
                },
                child: const Text('复制输入内容', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (_importError != null) ...[
            const SizedBox(height: 8),
            Text(_importError!,
                style:
                    const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12)),
          ],
          if (_importSuccess != null) ...[
            const SizedBox(height: 8),
            Text(_importSuccess!,
                style:
                    const TextStyle(color: Color(0xFF4CD38A), fontSize: 12)),
          ],
        ],
      ),
    );
  }

  static String _shortError(Object e) {
    if (e is DouyinException && (e.body ?? '').isEmpty) {
      return '服务端空响应（多为风控/未登录）';
    }
    // 界面只显示中文，原始英文由 loginLog 记录。
    return ErrorText.from(e);
  }
}
