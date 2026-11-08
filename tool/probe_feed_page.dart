// 探针：找出推荐的翻页方式，看一次能返回多少条、连续请求是否给新内容。
// 运行：C:\flutter\bin\dart.bat run tool\probe_feed_page.dart
import 'dart:io';

import '../lib/data/douyin_api.dart';
import '../lib/data/models.dart';

Future<void> main() async {
  final api = DouyinApi();
  final loaded = api.loadCookieFileIfPresent();
  stdout.writeln('cookie: ${loaded?.length ?? 0} 项, 登录=${api.isLoggedIn}');

  final combos = <String, Map<String, String>>{
    'count=20': {'count': '20'},
    'count=30': {'count': '30'},
    'count=20 nonp=1': {'count': '20', 'is_non_personalized': '1'},
  };

  for (final entry in combos.entries) {
    final seen = <String>{};
    final sizes = <String>[];
    for (var i = 0; i < 3; i++) {
      try {
        final body = await api.fetchFeedRaw(entry.value);
        final list = (body['aweme_list'] as List?) ?? const [];
        var fresh = 0;
        for (final raw in list) {
          final id = (asMap(raw)['aweme_id'] ?? '').toString();
          if (seen.add(id)) fresh++;
        }
        sizes.add('${list.length}(去重新增$fresh)');
      } catch (e) {
        sizes.add('失败:$e');
      }
    }
    stdout.writeln('${entry.key} -> ${sizes.join(" | ")}');
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  exit(0);
}
