// 风控验证协调器：接口层判定为「需要验证」后，打开一个**正常可见**的
// 浏览器窗口让用户自己过滑块 / 登录，本进程用 CDP 做只读轮询，
// 通过后把浏览器 Cookie 回写并让调用方重试一次原操作。
//
// 设计约束（来自实际风控经验）：
//   - 写接口不能反复重试，所以这里只负责"等待 + 确认"，重试与幂等检查由页面做；
//   - 确认以 CDP 读页面 / Cookie 为主（每 2.5 秒），只读接口探测最多 15 秒一次；
//   - 全程可取消，最长 5 分钟，超时给明确提示，不让界面一直转圈。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../data/douyin_api.dart';
import 'browser_login.dart';
import 'diag.dart';
import 'error_text.dart';

enum VerifyPhase { idle, running, passed, timedOut, cancelled, failed }

class VerifyGate extends ChangeNotifier {
  VerifyGate._();

  /// 全局唯一实例：同一时刻只允许一个验证流程，避免弹多个浏览器窗口。
  static final VerifyGate instance = VerifyGate._();

  VerifyPhase _phase = VerifyPhase.idle;
  String _message = '';
  String? _actionLabel;
  int _waitedSeconds = 0;
  Timer? _ticker;
  QrLoginSession? _session;
  Future<bool>? _inFlight;
  bool _cancelled = false;

  VerifyPhase get phase => _phase;
  String get message => _message;

  /// 触发验证的操作名（例如"发表评论""点赞"），显示在横幅上。
  String? get actionLabel => _actionLabel;
  int get waitedSeconds => _waitedSeconds;
  bool get isWaiting => _phase == VerifyPhase.running;

  /// 自测开关：DOUYIN_NO_VERIFY_UI=1 时不打开浏览器窗口，
  /// 直接返回"未通过"，用于离屏回归测试（避免弹窗打扰用户）。
  static final bool _noUiForTest =
      Platform.environment['DOUYIN_NO_VERIFY_UI'] == '1';

  /// 等待用户在浏览器里完成验证；返回 true 表示已确认通过，可以重试原操作。
  ///
  /// 已有验证流程在跑时直接复用，不会重复打开浏览器。
  Future<bool> waitForUser(DouyinApi api, DouyinException e, {String? label}) {
    if (_noUiForTest) {
      diag('risk', 'DOUYIN_NO_VERIFY_UI=1，跳过浏览器验证（${e.message}）');
      _set(VerifyPhase.failed, '自测模式：已跳过浏览器验证（${ErrorText.from(e)}）');
      return Future<bool>.value(false);
    }
    final running = _inFlight;
    if (running != null) {
      diag('risk', '已有验证流程在进行，复用当前等待');
      return running;
    }
    final future = _run(api, e, label);
    _inFlight = future;
    unawaited(future.whenComplete(() {
      if (_inFlight == future) _inFlight = null;
    }));
    return future;
  }

  /// 用户点「取消」：停掉等待并关闭由本应用启动的浏览器窗口。
  void cancel() {
    if (_phase != VerifyPhase.running) return;
    _cancelled = true;
    _set(VerifyPhase.cancelled, '已取消验证等待，界面恢复可用。');
    final session = _session;
    if (session != null) unawaited(session.close());
  }

  /// 横幅自动收起后回到空闲态（进行中的验证不允许被重置）。
  void reset() {
    if (_phase == VerifyPhase.running) return;
    _phase = VerifyPhase.idle;
    _message = '';
    _actionLabel = null;
    notifyListeners();
  }

  Future<bool> _run(DouyinApi api, DouyinException e, String? label) async {
    _cancelled = false;
    _actionLabel = label;
    _waitedSeconds = 0;
    _startTicker();
    _set(VerifyPhase.running, '检测到需要验证：${ErrorText.from(e)}。正在打开浏览器…');

    final verifyUrl = e.verifyUrl;
    final url = (verifyUrl != null && verifyUrl.startsWith('http'))
        ? verifyUrl
        : 'https://www.douyin.com/';
    diag('risk', '启动验证浏览器 url=$url 操作=${label ?? "未知"}');

    QrLoginSession? session;
    try {
      session =
          await QrLoginSession.startAt(url, onLog: (m) => diag('risk', m));
    } catch (err) {
      diag('risk', '启动验证浏览器异常: $err');
    }
    if (session == null) {
      _set(
          VerifyPhase.failed,
          '没找到可用的浏览器（Edge / Chrome / Chromium），无法自动打开验证页面。'
          '请手动完成验证后重试。');
      return false;
    }
    _session = session;
    _set(VerifyPhase.running,
        '已在浏览器打开验证页面，请完成滑块 / 登录。本应用会自动继续（最长 5 分钟）。');
    final passed = await _poll(api, session);
    _session = null;
    await session.close();
    return passed;
  }

  Future<bool> _poll(DouyinApi api, QrLoginSession session) async {
    const interval = Duration(milliseconds: 2500);
    const limit = Duration(minutes: 5);
    final startedAt = DateTime.now();
    var lastProbe = DateTime.fromMillisecondsSinceEpoch(0);
    var sawVerifyPage = false;
    var deadRounds = 0;
    var round = 0;
    var lastCookieSignature = _cookieSignature(api.cookies);

    while (!_cancelled) {
      await Future<void>.delayed(interval);
      if (_cancelled) break;

      final elapsed = DateTime.now().difference(startedAt);
      if (elapsed > limit) {
        _set(VerifyPhase.timedOut,
            '等待验证超时（5 分钟），已停止。可稍后重试，或重新导入 Cookie。');
        return false;
      }

      round++;
      if (!session.isAlive) {
        _set(VerifyPhase.cancelled, '浏览器已关闭，验证等待已取消。');
        return false;
      }

      var urls = const <String>[];
      try {
        urls = await session.pageUrls();
        deadRounds = urls.isEmpty ? deadRounds + 1 : 0;
        if (urls.any(_looksLikeVerifyPage)) sawVerifyPage = true;
      } catch (err) {
        deadRounds++;
        diag('risk', '读取浏览器页面失败: $err');
      }
      // 连续几轮读不到任何页面，说明用户把窗口关掉了。
      if (deadRounds >= 4) {
        _set(VerifyPhase.cancelled, '浏览器窗口已关闭，验证等待已取消。');
        return false;
      }

      // Cookie 有变化（验证过程常会刷新 ttwid / msToken）就值得确认一次。
      String? cookieChange;
      if (round % 2 == 0) {
        try {
          final cookies = await session.readCookies();
          final map = _cookieMap(cookies);
          final signature = _cookieSignature(map);
          if (signature != lastCookieSignature) {
            cookieChange = 'cookie 有更新';
            lastCookieSignature = signature;
          }
        } catch (err) {
          diag('risk', '读取浏览器 Cookie 失败: $err');
        }
      }

      final probeDue =
          DateTime.now().difference(lastProbe) >= const Duration(seconds: 15);
      final leftVerifyPage =
          sawVerifyPage && urls.isNotEmpty && !urls.any(_looksLikeVerifyPage);
      if (probeDue || cookieChange != null || leftVerifyPage) {
        lastProbe = DateTime.now();
        _set(VerifyPhase.running, '正在确认是否已通过验证…');
        if (await api.probeReadOnly()) {
          await _adoptCookies(api, session);
          _set(VerifyPhase.passed, '验证已通过，正在重试刚才的操作…');
          return true;
        }
        _set(VerifyPhase.running,
            '仍在等待验证…（已等待 ${elapsed.inSeconds}s）');
      }
    }
    return false;
  }

  /// 验证通过后把浏览器里的 Cookie 合并回当前会话并落盘，
  /// 这样后续写接口用的是验证过的新会话，而不是旧的失效 Cookie。
  Future<void> _adoptCookies(DouyinApi api, QrLoginSession session) async {
    try {
      final cookies = await session.readCookies();
      final map = _cookieMap(cookies);
      if (map.isEmpty) return;
      api.applyCookies(map);
      final path = api.saveCookieList(cookies);
      diag('risk', '验证后已导入 ${map.length} 项 Cookie，写盘=${path ?? "失败"}');
    } catch (err) {
      diag('risk', '验证后导入 Cookie 失败: $err');
    }
  }

  static Map<String, String> _cookieMap(List<Map<String, dynamic>> cookies) {
    final out = <String, String>{};
    for (final c in cookies) {
      final domain = (c['domain'] ?? '').toString();
      final name = (c['name'] ?? '').toString();
      final value = (c['value'] ?? '').toString();
      if (domain.contains('douyin.com') && name.isNotEmpty && value.isNotEmpty) {
        out[name] = value;
      }
    }
    return out;
  }

  /// 只比较数量与几个关键项的哈希，不落日志、不打印 Cookie 值。
  static String _cookieSignature(Map<String, String> cookies) {
    return '${cookies.length}:'
        '${Object.hash(cookies['ttwid'], cookies['sessionid'], cookies['msToken'], cookies['Udid'])}';
  }

  static bool _looksLikeVerifyPage(String url) {
    final lower = url.toLowerCase();
    return lower.contains('verify') ||
        lower.contains('captcha') ||
        lower.contains('bdturing') ||
        lower.contains('challenge') ||
        lower.contains('secsdk');
  }

  void _startTicker() {
    _waitedSeconds = 0;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_phase != VerifyPhase.running) return;
      _waitedSeconds++;
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _set(VerifyPhase phase, String message) {
    _phase = phase;
    _message = message;
    if (phase != VerifyPhase.running) _stopTicker();
    diag('risk', '阶段=$phase $message');
    notifyListeners();
  }
}
