// 诊断脚本：验证作者作品接口（x-secsdk-web-signature）是否可用。
// 用法：dart run tool/author_probe.dart <sec_uid>
import 'dart:io';

import 'package:douyin_desktop/data/douyin_api.dart';

Future<void> main(List<String> args) async {
  final secUid = args.isNotEmpty
      ? args.first
      : 'MS4wLjABAAAAKM-KWyyMDLoWI92TKvJLw4GPaKxAi6hkV0GuLlPEbHamaQmddL196qwDfTxJ2E0N';
  final api = DouyinApi();
  api.loadCookieFile('douyin_cookies.json');
  print('loggedIn=${api.isLoggedIn} sec_uid=$secUid');

  try {
    final body = await api.fetchUserPosts(secUid, count: 18);
    final list = body['aweme_list'];
    print('PAGE1 OK count=${(list is List) ? list.length : 'null'} '
        'has_more=${body['has_more']} max_cursor=${body['max_cursor']}');
    if (list is List && list.isNotEmpty) {
      final first = list.first as Map;
      final author = first['author'] as Map?;
      print('first aweme=${first['aweme_id']} desc=${first['desc']} '
          'author=${author?['nickname']} sec_uid=${author?['sec_uid']}');
    }
    final cursor = body['max_cursor'];
    if (body['has_more'] == 1 && cursor is int) {
      final page2 = await api.fetchUserPosts(secUid, maxCursor: cursor);
      final l2 = page2['aweme_list'];
      print('PAGE2 OK count=${(l2 is List) ? l2.length : 'null'} '
          'has_more=${page2['has_more']} max_cursor=${page2['max_cursor']}');
    }
  } catch (e) {
    final msg = e is DouyinException ? '${e.statusCode} ${e.message} ${e.body}' : '$e';
    print('ERR $msg');
  }
  exit(0);
}
