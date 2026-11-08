// 登录态验证脚本（无窗口、纯 Dart）。
//
// 用途：
//   1. 加载 douyin_cookies.json
//   2. 打必须登录态的 /aweme/v1/web/user/profile/self/ 验证身份
//   3. 用登录态重测 comment/list（判断空响应是否消失）
//   4. 复测推荐流与播放直链
//
// 运行：C:\flutter\bin\dart.bat run tool\probe_login_cookie.dart
//
// 安全约定：只打印字段名和长度，绝不打印 Cookie 值。

import 'dart:io';

import '../lib/data/douyin_api.dart';
import '../lib/data/models.dart';

const _defaultCookiePath =
    r'C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03\douyin_desktop\douyin_cookies.json';

String get _cookiePath {
  final env = Platform.environment['DOUYIN_COOKIES'];
  return (env != null && env.isNotEmpty) ? env : _defaultCookiePath;
}

const _mustHave = <String>[
  'sessionid',
  'sessionid_ss',
  'sid_tt',
  'uid_tt',
  'ttwid',
  'UIFID',
  'passport_csrf_token',
  'odin_tt',
  'web_sign_token',
];

void _line(String s) => stdout.writeln(s);

String _short(Object? o, [int max = 240]) {
  final s = (o ?? '').toString().replaceAll('\n', ' ');
  return s.length > max ? '${s.substring(0, max)}…' : s;
}

Future<void> main() async {
  final api = DouyinApi();

  _line('=== 1. 加载 Cookie 文件 ===');
  if (!File(_cookiePath).existsSync()) {
    _line('[失败] 文件不存在: $_cookiePath');
    exit(2);
  }
  final loaded = api.loadCookieFile(_cookiePath);
  _line('已加载 ${loaded.length} 个 douyin.com Cookie');
  for (final k in _mustHave) {
    final len = loaded[k];
    _line('  $k: ${len == null ? "缺失" : "已拿到（长度 $len）"}');
  }

  _line('');
  _line('=== 2. 必须登录态接口 /aweme/v1/web/user/profile/self/ ===');
  try {
    final self = await api.fetchSelfProfile();
    final user = (self['user'] ?? self['user_info'] ?? self) as Object?;
    _line('HTTP 200 / status_code=${self['status_code']}');
    _line('返回顶层字段: ${self.keys.join(", ")}');
    if (user is Map) {
      _line('user 字段: ${user.keys.join(", ")}');
      _line('nickname=${user['nickname']} | uid=${user['uid']} | '
          'sec_uid=${_short(user['sec_uid'], 40)} | '
          'follower=${user['follower_count']} | '
          'following=${user['following_count']}');
    } else {
      _line('返回体: ${_short(self, 400)}');
    }
  } on DouyinException catch (e) {
    _line('[失败] ${e.message}');
    _line('  状态=${e.statusCode} 返回体=${_short(e.body, 400)}');
  } catch (e) {
    _line('[异常] $e');
  }

  _line('');
  _line('=== 3. 拉推荐流，拿一条作品用于评论测试 ===');
  AwemeItem? target;
  try {
    final raw = await api.fetchFeed(count: 12);
    final items = <AwemeItem>[];
    for (final j in raw) {
      final it = AwemeItem.fromJson(j);
      if (it != null) items.add(it);
    }
    _line('HTTP 200 | aweme_list=${items.length}');
    for (final it in items.take(3)) {
      _line('  ${it.id} | @${it.author.nickname} | 评论数=${it.commentCount} '
          '| like=${it.diggCount} | ${_short(it.desc, 40)}');
    }
    target = items.firstWhere(
      (e) => e.commentCount > 0,
      orElse: () => items.isEmpty ? throw StateError('列表为空') : items.first,
    );
    _line('评论测试目标: aweme=${target.id} '
        '服务端声称评论数=${target.commentCount}');
  } on DouyinException catch (e) {
    _line('[失败] ${e.message} 返回体=${_short(e.body, 400)}');
  } catch (e) {
    _line('[异常] $e');
  }

  if (target != null) {
    _line('');
    _line('=== 4. 登录态 comment/list ===');
    try {
      final body = await api.fetchComments(target.id, count: 20);
      final list = (body['comments'] as List?) ?? const [];
      _line('HTTP 200 | status_code=${body['status_code']} | 条数=${list.length} '
          '| has_more=${body['has_more']} | total=${body['total']} | '
          'cursor=${body['cursor']}');
      for (final c in list.take(5)) {
        final m = c as Map<String, dynamic>;
        final u = (m['user'] as Map<String, dynamic>?) ?? const {};
        _line('  - @${u['nickname']} 赞=${m['digg_count']} '
            '回复=${m['reply_comment_total'] ?? 0} '
            '图=${((m['image_list'] as List?) ?? const []).length} '
            '| ${_short(m['text'], 60)}');
      }
    } on DouyinException catch (e) {
      _line('[失败] ${e.message} 状态=${e.statusCode}');
      _line('  返回体=${_short(e.body, 400)}');
    } catch (e) {
      _line('[异常] $e');
    }

    _line('');
    _line('=== 5. 播放直链复测（aweme/v1/play/） ===');
    final playable = target.playUrl;
    _line('选用地址主机: ${Uri.tryParse(playable)?.host}');
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(playable));
      req.headers.set('user-agent', kDouyinUa);
      req.headers.set('referer', 'https://www.douyin.com/');
      req.headers.set('range', 'bytes=0-1023');
      final resp = await req.close();
      var bytes = 0;
      await for (final chunk in resp) {
        bytes += chunk.length;
      }
      _line('HTTP ${resp.statusCode} | content-type=${resp.headers.contentType} '
          '| 读到 $bytes 字节');
      client.close();
    } catch (e) {
      _line('[失败] $e');
    }
  }

  _line('');
  _line('=== 完成 ===');
  exit(0);
}
