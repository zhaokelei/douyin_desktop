// 端到端验证：全新会话 → 推荐流 → 播放地址 → 评论（含图片）。
import 'dart:convert';
import 'dart:io';

import '../lib/data/douyin_api.dart';
import '../lib/data/models.dart';

Future<void> main() async {
  final api = DouyinApi();
  if (Platform.environment['PROBE_FULL_COOKIE'] == '1') {
    final raw = jsonDecode(File(
            r'C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03\probes\cookies_anon.json')
        .readAsStringSync()) as Map<String, dynamic>;
    api.restoreCookies(raw.map((k, v) => MapEntry(k, v.toString())));
    print('[cookie] 注入 Python 匿名会话 ${raw.length} 个字段');
  }
  final sw = Stopwatch()..start();
  await api.ensureReady();
  print('[bootstrap] ${sw.elapsedMilliseconds}ms | cookie=${api.cookies.keys.join(",")}');
  print('[bootstrap] cookie 字段长度: '
      '${api.cookies.entries.map((e) => "${e.key}(${e.value.length})").join(", ")}');
  final ree = api.debugReePublicKey;
  print('[bootstrap] ree-public-key: ${ree == null ? "未解出" : "已解出长度 ${ree.length}"}');

  final rawItems = await api.fetchFeed(count: 10);
  final items = [
    for (final raw in rawItems)
      if (AwemeItem.fromJson(raw) != null) AwemeItem.fromJson(raw)!,
  ];
  print('\n[feed] 原始条目=${rawItems.length} | 可播放=${items.length}');
  for (final item in items.take(4)) {
    print('  - ${item.id} | ${item.author.nickname} | '
        '${item.desc.length > 30 ? item.desc.substring(0, 30) : item.desc} | '
        '播放=${item.playUrl.isNotEmpty} | 封面=${item.coverUrl.isNotEmpty} | '
        '赞=${item.diggCount} 评=${item.commentCount}');
  }
  if (items.isEmpty) {
    print('[feed] 没有可用条目，停止');
    return;
  }

  final first = items.first;
  if (first.playUrl.isEmpty) {
    final detail = await api.fetchDetail(first.id);
    final video = asMap(detail?['video']);
    final play = firstUrl(video['play_addr']);
    print('\n[detail] ${first.id} -> play=${play.substring(0, 60)}');
  } else {
    print('\n[detail] 列表已带播放地址: ${first.playUrl.substring(0, 60)}');
  }

  Map<String, dynamic> comments;
  try {
    comments = await api.fetchComments(first.id, count: 20);
  } catch (e) {
    print('\n[comments] 失败: $e');
    print('[done] 总耗时 ${sw.elapsedMilliseconds}ms');
    exit(0);
  }
  final list = [
    for (final raw in (comments['comments'] as List? ?? const []))
      if (CommentItem.fromJson(asMap(raw)) != null) CommentItem.fromJson(asMap(raw))!,
  ];
  print('\n[comments] aweme=${first.id} | has_more=${comments['has_more']} | '
      '条数=${list.length}');
  for (final c in list.take(5)) {
    print('  - ${c.userName}: ${c.text.length > 30 ? c.text.substring(0, 30) : c.text} '
        '| 图=${c.images.length}${c.images.isNotEmpty ? " (${c.images.first.url.length} 字符)" : ""}');
  }

  // 更深的评论分页
  if (list.isNotEmpty || (comments['has_more'] ?? 0) == 1) {
    final next = await api.fetchComments(first.id, cursor: 20, count: 20);
    final nextList = [
      for (final raw in (next['comments'] as List? ?? const []))
        if (CommentItem.fromJson(asMap(raw)) != null) 1,
    ];
    print('[comments] 第二页 cursor=20 -> 条数=${nextList.length} | '
        'has_more=${next['has_more']}');
  }

  print('\n[done] 总耗时 ${sw.elapsedMilliseconds}ms');
  exit(0);
}
