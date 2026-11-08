// 一次性的"登录态下功能验证"探针（离屏、无窗口，全程不发任何界面）。
//
// 目的：用最新 Cookie 一次性验证：登录态 / 发表评论（含可见性复核）/ 子回复 /
// 点赞 / 收藏 / 作者作品。每个写接口最多调用一次，任何风控迹象立即停止。
// 用法：DOUYIN_COOKIES=<cookie.json> dart run tool/verify_all.dart [awemeId]
import 'dart:io';

import 'package:douyin_desktop/data/douyin_api.dart';
import 'package:douyin_desktop/data/models.dart';

bool riskStopped = false;

void main2(String tag, String msg) => print('[$tag] $msg');

bool looksRisky(Object? json, {int? httpStatus, String? body}) {
  if (httpStatus != null && httpStatus != 200) return true;
  if (body == null) return false;
  if (body.isNotEmpty && !body.trimLeft().startsWith('{')) return true;
  final code = asMap(json)['status_code'];
  return code is int && code != 0;
}

class RiskStop implements Exception {
  RiskStop(this.reason);
  final String reason;
}

void check(bool risky, String where) {
  if (!risky) return;
  riskStopped = true;
  throw RiskStop(where);
}

Future<void> main(List<String> args) async {
  final api = DouyinApi();
  final path = DouyinApi.resolveCookiePath();
  if (path == null) {
    main2('cookie', '未找到 Cookie 文件');
    exit(1);
  }
  final fields = api.loadCookieFile(path);
  main2('cookie', 'fields=${fields.length} '
      'hasSessionid=${fields.containsKey('sessionid')} loggedIn=${api.isLoggedIn}');

  // 1) 登录态：只查一次自我资料
  try {
    final self = await api.fetchSelfProfile();
    final user = asMap(self['user']);
    main2('login', 'OK uid=${user['uid']} nickname=${user['nickname']} '
        'following=${user['following_count']}');
    check(looksRisky(self), 'self profile 返回 status_code=${self['status_code']}');
  } on DouyinException catch (e) {
    main2('login', 'FAIL ${_detail(e)}');
    if (e.body != null && e.body!.isEmpty) main2('login', '=> 空响应，判定为风控，停止');
    exit(0);
  }

  // 2) 取一条作品（一次），后续写接口都用它
  String awemeId = args.isNotEmpty ? args[0] : '';
  String secUid = '';
  try {
    final feed = await api.fetchFeed(count: 6);
    for (final json in feed) {
      final item = AwemeItem.fromJson(json);
      if (item == null) continue;
      awemeId = item.id;
      secUid = item.author.secUid;
      main2('feed', 'aweme=$awemeId desc=${_short(item.desc)}');
      break;
    }
    check(false, 'feed');
  } catch (e) {
    main2('feed', 'FAIL ${_detail2(e)}');
  }
  if (awemeId.isEmpty) {
    main2('feed', '拿不到 aweme_id，结束');
    exit(0);
  }

  // 3) 评论列表（读一次）：拿一级评论与"有子回复"的评论
  String commentCid = '';
  String commentWithReplies = '';
  int replyTotal = 0;
  try {
    final page = await api.fetchComments(awemeId, count: 20);
    final list = page['comments'];
    final count = list is List ? list.length : 0;
    main2('comments', 'pageCount=$count total=${page['total']} '
        'status=${page['status_code']}');
    if (list is List) {
      for (final node in list) {
        final c = asMap(node);
        final rt = c['reply_comment_total'];
        final rtInt = rt is int ? rt : int.tryParse('$rt') ?? 0;
        if (rtInt > 0) {
          commentWithReplies = (c['cid'] ?? '').toString();
          replyTotal = rtInt;
          break;
        }
      }
      if (commentCid.isEmpty && list.isNotEmpty) {
        commentCid = (asMap(list.first)['cid'] ?? '').toString();
      }
    }
  } catch (e) {
    main2('comments', 'FAIL ${_detail2(e)}');
  }

  // 4) 子回复展开（读一次）：仅当确实存在有回复的评论
  if (commentWithReplies.isNotEmpty) {
    try {
      final reply = await api.fetchCommentReplies(awemeId, commentWithReplies,
          cursor: 0, count: 5);
      final list = reply['comments'];
      main2('replies',
          'target=$commentWithReplies 预期回复数=$replyTotal '
          'pageCount=${list is List ? list.length : 0} '
          'has_more=${reply['has_more']} total=${reply['total']} '
          'status=${reply['status_code']}');
      final first = list is List && list.isNotEmpty ? asMap(list.first) : const {};
      main2('replies', 'first cid=${first['cid']} '
          'user=${asMap(first['user'])['nickname']} text=${_short(first['text'])}');
    } catch (e) {
      main2('replies', 'FAIL ${_detail2(e)}');
    }
  } else {
    main2('replies', '本页评论没有 reply_comment_total>0，跳过');
  }

  // 5) 发表评论（写一次）
  String publishedCid = '';
  try {
    final res = await api.publishComment(awemeId, '支持一下👍');
    final comment = asMap(res['comment']);
    publishedCid = (comment['cid'] ?? '').toString();
    main2('publish', 'status=${res['status_code']} cid=$publishedCid '
        'text=${comment['text']} create_time=${comment['create_time']}');
    check(looksRisky(res), 'comment/publish status_code=${res['status_code']}');
  } catch (e) {
    main2('publish', 'FAIL ${_detail2(e)}');
    if (e is RiskStop) _reportStop();
  }

  // 6) 可见性复核（读一次，必须做，否则无法区分"仅自己可见"）
  if (publishedCid.isNotEmpty) {
    await Future<void>.delayed(const Duration(seconds: 2));
    try {
      final page = await api.fetchComments(awemeId, count: 20);
      final list = page['comments'];
      var found = false;
      if (list is List) {
        for (final node in list) {
          if ((asMap(node)['cid'] ?? '').toString() == publishedCid) {
            found = true;
            break;
          }
        }
      }
      main2('visible', 'cid=$publishedCid 在公开列表=$found '
          '（false 表示可能仅自己可见/审核中）');
    } catch (e) {
      main2('visible', 'FAIL ${_detail2(e)}');
    }
  }

  if (riskStopped) _reportStop();

  // 7) 点赞（写一次）
  try {
    final ok = await api.commitDigg(awemeId, like: true);
    main2('digg', 'status_code=0? $ok');
  } catch (e) {
    main2('digg', 'FAIL ${_detail2(e)}');
    if (e is RiskStop) _reportStop();
  }

  // 8) 收藏（写一次）
  try {
    final ok = await api.commitCollect(awemeId, collect: true);
    main2('collect', 'status_code=0? $ok');
  } catch (e) {
    main2('collect', 'FAIL ${_detail2(e)}');
    if (e is RiskStop) _reportStop();
  }

  // 9) 作者主页作品（读一次）
  if (secUid.isNotEmpty) {
    try {
      final page = await api.fetchUserPosts(secUid, count: 18);
      final list = page['aweme_list'];
      main2('author', 'secUid=${_short(secUid)} posts=${list is List ? list.length : 0} '
          'has_more=${page['has_more']} status=${page['status_code']}');
    } catch (e) {
      main2('author', 'FAIL ${_detail2(e)}');
    }
  } else {
    main2('author', '未取到 sec_uid，跳过');
  }

  main2('done', '验证结束 riskStopped=$riskStopped');
  exit(0);
}

void _reportStop() {
  main2('risk', '检测到风控/异常响应，按约定立即停止后续验证');
  exit(0);
}

String _short(String? s) {
  if (s == null || s.isEmpty) return '';
  final flat = s.replaceAll('\n', ' ');
  return flat.length <= 28 ? flat : '${flat.substring(0, 28)}…';
}

String _detail(DouyinException e) {
  final body = e.body ?? '';
  final head = body.length > 200 ? body.substring(0, 200) : body;
  return '${e.message} http=${e.statusCode} body=$head';
}

String _detail2(Object e) {
  if (e is DouyinException) return _detail(e);
  return '$e';
}
