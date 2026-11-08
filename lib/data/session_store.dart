import 'package:shared_preferences/shared_preferences.dart';

/// Cookie 持久化。WebView 自身也会持久化 cookie（Windows 用 WebView2 的用户数据目录），
/// 这里再存一份，用于启动时判断登录态，以及后续原生签名接口预留使用。
class SessionStore {
  static const _keyCookie = 'douyin_cookie_header';
  static const _keyLoginAt = 'douyin_login_at';

  Future<String?> readCookie() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCookie);
  }

  Future<void> saveCookie(String cookieHeader) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCookie, cookieHeader);
    await prefs.setInt(_keyLoginAt, DateTime.now().millisecondsSinceEpoch);
  }

  Future<bool> hasSavedSession() async {
    final cookie = await readCookie();
    return cookie != null && cookie.contains('sessionid=');
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCookie);
    await prefs.remove(_keyLoginAt);
  }
}
