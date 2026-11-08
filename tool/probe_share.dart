// 分享/好友接口探测：确认抖音 web 端是否存在可用的好友列表与分享端点。
// 用法：dart run tool/probe_share.dart
import 'dart:io';

import 'package:douyin_desktop/data/douyin_api.dart';

Future<void> main() async {
  final api = DouyinApi();
  final path = DouyinApi.resolveCookiePath();
  if (path != null) api.loadCookieFile(path);
  print('loggedIn=${api.isLoggedIn}');

  final cases = <(String, Map<String, String>)>[
    ('/aweme/v1/web/im/conversation/list/', {'cursor': '0', 'count': '20'}),
    ('/aweme/v1/web/im/friend/list/', {'cursor': '0', 'count': '20'}),
    ('/aweme/v1/web/im/user/info/', {'sec_uid': ''}),
    ('/aweme/v1/web/im/msg/send/', {'aweme_id': ''}),
    ('/aweme/v1/web/im/share/', {'aweme_id': ''}),
    ('/aweme/v1/web/notice/list/', {'count': '20'}),
    ('/aweme/v1/web/aweme/share/', {'aweme_id': '', 'share_type': 'im'}),
    ('/aweme/v1/web/aweme/share/confirm/',
        {'aweme_id': '', 'share_type': 'im'}),
    ('/aweme/v1/web/share/aweme/', {'aweme_id': ''}),
    ('/aweme/v1/web/aweme/share/list/', {'aweme_id': ''}),
  ];
  for (final (path, extra) in cases) {
    try {
      final json = await api.debugGet(path, extra,
          referer: 'https://www.douyin.com/?recommend=1');
      final keys = json.keys.take(8).join(',');
      print('OK   $path -> $keys');
    } catch (e) {
      final detail = e is DouyinException
          ? '${e.message} http=${e.statusCode} body=${(e.body ?? '').length > 160 ? e.body!.substring(0, 160) : e.body}'
          : '$e';
      print('FAIL $path -> $detail');
    }
  }
  exit(0);
}
