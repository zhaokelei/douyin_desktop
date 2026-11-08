// 写接口可用性探针：用真实 Cookie 验证
//   1) 子回复 comment/list/reply
//   2) 点赞 commit/item/digg（点完立刻取消）
//   3) 收藏 aweme/collect（收藏后立刻取消）
// 用法：dart run tool/probe_write.dart
import 'dart:io';

import 'package:douyin_desktop/data/douyin_api.dart';
import 'package:douyin_desktop/data/models.dart';

Future<void> main() async {
  final api = DouyinApi();
  final path = DouyinApi.resolveCookiePath();
  if (path != null) {
    final fields = api.loadCookieFile(path);
    print('cookiePath=$path fields=${fields.length} hasSessionid=${fields.containsKey('sessionid')}');
  } else {
    print('未找到 Cookie 文件');
  }
  print('loggedIn=${api.isLoggedIn}');

  Map<String, dynamic>? first;
  try {
    final feed = await api.fetchFeed(count: 8);
    for (final json in feed) {
      final item = AwemeItem.fromJson(json);
      if (item == null) continue;
      first ??= json;
      print('feed aweme=${item.id} desc=${item.desc}');
    }
  } catch (e) {
    print('ERR feed: ${_detail(e)}');
  }
  if (first == null) {
    print('没有可用作品，结束');
    exit(0);
  }
  final awemeId = (first['aweme_id'] ?? '').toString();
  final statistics = asMap(first['statistics']);
  print('digg_count=${statistics['digg_count']} '
      'collect_count=${statistics['collect_count']}');
  try {
    final self = await api.fetchSelfProfile();
    final user = asMap(self['user']);
    print('SELF uid=${user['uid']} nickname=${user['nickname']} '
        'uidHash=${await api.debugUidHash()}');
  } catch (e) {
    print('ERR self: ${_detail(e)}');
  }

  // ---- 子回复 ----
  try {
    final comments = await api.fetchComments(awemeId, count: 20);
    final list = comments['comments'];
    final cids = <String>[];
    if (list is List) {
      for (final raw in list) {
        final m = asMap(raw);
        final cid = (m['cid'] ?? '').toString();
        final total = asInt(m['reply_comment_total']);
        if (cid.isNotEmpty && total > 0) cids.add('$cid(total=$total)');
      }
    }
    print('可展开的评论: ${cids.take(3).join(", ")}');
    if (cids.isNotEmpty) {
      final cid = cids.first.split('(').first;
      final page1 = await api.fetchCommentReplies(awemeId, cid, count: 5);
      final replies = page1['comments'];
      print('REPLY PAGE1 status=0 count=${(replies is List) ? replies.length : 'null'} '
          'has_more=${page1['has_more']} total=${page1['total']}');
      if (replies is List && replies.isNotEmpty) {
        final r = asMap(replies.first);
        print('  第一条回复: ${r['text']}');
      }
      if (page1['has_more'] == 1) {
        final cursor = asInt(page1['cursor']);
        final page2 = await api.fetchCommentReplies(awemeId, cid,
            cursor: cursor, count: 5);
        final l2 = page2['comments'];
        print('REPLY PAGE2 count=${(l2 is List) ? l2.length : 'null'} '
            'has_more=${page2['has_more']}');
      }
    }
  } catch (e) {
    print('ERR reply: ${_detail(e)}');
  }

  // ---- 点赞（点后取消）----
  try {
    final like = await api.commitDigg(awemeId, like: true);
    print('DIGG on -> $like');
    final unlike = await api.commitDigg(awemeId, like: false);
    print('DIGG off -> $unlike');
  } catch (e) {
    print('ERR digg: ${_detail(e)}');
  }

  // ---- 收藏（藏后取消）----
  try {
    final on = await api.commitCollect(awemeId, collect: true);
    print('COLLECT on -> $on');
    final off = await api.commitCollect(awemeId, collect: false);
    print('COLLECT off -> $off');
  } catch (e) {
    print('ERR collect: ${_detail(e)}');
  }

  // 再看一次详情，确认 statistics 是否变化（服务端是否真的记下了）。
  try {
    final detail = await api.fetchDetail(awemeId);
    if (detail != null) {
      final s = asMap(detail['statistics']);
      print('detail after: digg=${s['digg_count']} collect=${s['collect_count']} '
          'user_digged=${detail['user_digged']}');
    }
  } catch (e) {
    print('ERR detail: ${_detail(e)}');
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
