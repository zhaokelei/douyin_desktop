// 发表评论探针（离屏、无窗口）：
//   1) 校验当前 Cookie 登录态（user/profile/self）
//   2) 取一条推荐作品，调用 comment/publish 发一条带表情的评论
//   3) 再用 comment/list 复核这条评论是否公开可见
// 用法：dart run tool/probe_publish.dart [awemeId] ["评论内容"]
import 'dart:io';

import 'package:douyin_desktop/data/douyin_api.dart';
import 'package:douyin_desktop/data/models.dart';

Future<void> main(List<String> args) async {
  final api = DouyinApi();
  final path = DouyinApi.resolveCookiePath();
  print('cookiePath=$path loggedIn=${api.isLoggedIn}');
  if (path != null) api.loadCookieFile(path);

  final skipSelfCheck = args.contains('--skip-self');
  final ids = args.where((a) => !a.startsWith('--')).toList();
  try {
    final self = await api.fetchSelfProfile();
    final user = asMap(self['user']);
    print('SELF ok uid=${user['uid']} nickname=${user['nickname']}');
  } catch (e) {
    print('SELF FAIL: ${_detail(e)}');
    if (!skipSelfCheck) exit(0);
  }

  var awemeId = ids.isNotEmpty ? ids[0] : '';
  if (awemeId.isEmpty) {
    try {
      final feed = await api.fetchFeed(count: 6);
      for (final json in feed) {
        final item = AwemeItem.fromJson(json);
        if (item == null) continue;
        awemeId = item.id;
        print('TARGET aweme=$awemeId desc=${item.desc}');
        break;
      }
    } catch (e) {
      print('FEED FAIL: ${_detail(e)}');
      exit(0);
    }
  }
  final text = args.length > 1 ? args[1] : '支持一下👍';

  Map<String, dynamic>? res;
  try {
    res = await api.publishComment(awemeId, text);
    final comment = asMap(res['comment']);
    print('PUBLISH status=${res['status_code']} cid=${comment['cid']} '
        'text=${comment['text']} create_time=${comment['create_time']}');
  } catch (e) {
    print('PUBLISH FAIL: ${_detail(e)}');
    exit(0);
  }

  final cid = (asMap(res['comment'])['cid'] ?? '').toString();
  if (cid.isEmpty) {
    print('PUBLISH 无 cid，无法复核可见性');
    exit(0);
  }
  // 稍等服务端落库，再查一级评论列表前 20 条。
  await Future<void>.delayed(const Duration(seconds: 2));
  try {
    final list = await api.fetchComments(awemeId, count: 20);
    final raw = list['comments'];
    var found = false;
    var idx = -1;
    if (raw is List) {
      for (var i = 0; i < raw.length; i++) {
        if ((asMap(raw[i])['cid'] ?? '').toString() == cid) {
          found = true;
          idx = i;
          break;
        }
      }
    }
    final firstRaw = raw is List && raw.isNotEmpty ? asMap(raw.first) : const {};
    print('LIST total=${list['total']} pageCount=${raw is List ? raw.length : 'null'} '
        'found=$found index=$idx');
    print('LIST 首条 cid=${firstRaw['cid']} user=${asMap(firstRaw['user'])['nickname']} '
        'text=${firstRaw['text']}');
  } catch (e) {
    print('LIST FAIL: ${_detail(e)}');
  }
  exit(0);
}

String _detail(Object e) {
  if (e is DouyinException) {
    final body = e.body ?? '';
    final short = body.length > 300 ? body.substring(0, 300) : body;
    return '${e.message} status=${e.statusCode} body=$short';
  }
  return '$e';
}
