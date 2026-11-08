import 'dart:convert';
import 'dart:io';

import '../lib/data/douyin_api.dart';
import '../lib/data/models.dart';

/// 逐个测试 feed 返回的所有播放地址候选，只报状态码与主机名，不输出签名值。
/// 运行：dart run tool/probe_play.dart
Future<void> main() async {
  final api = DouyinApi();
  await api.ensureReady();
  final raw = await api.fetchFeed(count: 10);
  stdout.writeln('feed 条目=${raw.length} 本次会话cookie字段数=${api.cookies.length}');

  final ua = kDouyinUa;
  final referer = 'https://www.douyin.com/';
  final cookie = api.cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  var shown = 0;
  for (final json in raw) {
    if (shown >= 3) break;
    final item = AwemeItem.fromJson(json);
    if (item == null) continue;
    final video = asMap(json['video']);
    final urls = <String>[];
    for (final holder in ['play_addr', 'play_addr_h264', 'play_addr_265', 'download_addr']) {
      for (final u in asList(asMap(video[holder])['url_list'])) {
        if (u is String && u.isNotEmpty) urls.add(u);
      }
    }
    if (urls.isEmpty) {
      stdout.writeln('--- aweme=${item.id} 无播放地址');
      continue;
    }
    shown++;
    stdout.writeln('--- aweme=${item.id} 候选=${urls.length}');
    for (var i = 0; i < urls.length && i < 4; i++) {
      final uri = Uri.tryParse(urls[i]);
      final host = uri?.host ?? '?';
      final policy = uri?.queryParameters['policy'] ?? '-';
      final ply = uri?.queryParameters['ply_type'] ?? '-';
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(urls[i]));
        req.headers.set('user-agent', ua);
        req.headers.set('referer', referer);
        req.headers.set('cookie', cookie);
        req.headers.set('range', 'bytes=0-1023');
        final res = await req.close();
        final bytes =
            await res.fold<List<int>>(<int>[], (a, c) => a..addAll(c));
        stdout.writeln('  [$i] $host policy=$policy ply=$ply → ${res.statusCode} bytes=${bytes.length}');
      } catch (e) {
        stdout.writeln('  [$i] $host policy=$policy ply=$ply → 异常 $e');
      } finally {
        client.close(force: true);
      }
    }
  }
  stdout.writeln(jsonEncode({'done': true}));
}
