// Dart 侧 a_bogus 对拍 + 真实接口验证。
// 用与 Python 完全相同的参数（probes/feed_query.json）和同一份匿名 Cookie，
// 只把签名和 HTTP 换成 Dart 实现，看服务端是否接受。
import 'dart:convert';
import 'dart:io';

import '../lib/data/abogus.dart';

const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36';
const probes = r'C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03\probes';

String quote(String s) {
  final allowed = RegExp(r'[A-Za-z0-9_.\-~]');
  final out = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (allowed.hasMatch(ch)) {
      out.write(ch);
    } else {
      for (final b in utf8Bytes(ch)) {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
  }
  return out.toString();
}

String splice(Map<String, dynamic> params) {
  return params.entries
      .map((e) => '${e.key}=${quote(e.value?.toString() ?? '')}')
      .join('&');
}

Future<void> main() async {
  final raw = File('$probes/feed_query.json').readAsStringSync();
  final params = jsonDecode(raw) as Map<String, dynamic>;
  params.remove('a_bogus');

  final cookieMap = jsonDecode(File('$probes/cookies_anon.json').readAsStringSync())
      as Map<String, dynamic>;
  final cookieHeader = Platform.environment['DART_PROBE_NOCOOKIE'] == '1'
      ? ''
      : cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
  print('[dart] cookie 字节数 = ${cookieHeader.length}');

  final query = splice(params);
  final signer = AbogusSigner();
  final sw = Stopwatch()..start();
  final ab = signer.signQuery(query, host: 'www.douyin.com');
  sw.stop();
  print('[dart] a_bogus = $ab');
  print('[dart] 长度 = ${ab.length} | 耗时 = ${sw.elapsedMicroseconds}us');

  final uri = Uri.parse(
      'https://www.douyin.com/aweme/v1/web/tab/feed/?$query&a_bogus=${quote(ab)}');
  final client = HttpClient();
  final req = await client.getUrl(uri);
  req.headers.set('user-agent', ua);
  req.headers.set('referer', 'https://www.douyin.com/');
  req.headers.set('accept', 'application/json, text/plain, */*');
  req.headers.set('cookie', cookieHeader);
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  print('[dart] HTTP ${resp.statusCode} | len ${body.length}');
  print('[dart] body[0:150]=${body.substring(0, body.length > 150 ? 150 : body.length).replaceAll('\n', ' ')}');

  try {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final list = (j['aweme_list'] as List?) ?? const [];
    print('[dart] status_code=${j['status_code']} | aweme_list=${list.length}');
    for (final a in list.take(3)) {
      final m = a as Map<String, dynamic>;
      final author = (m['author'] as Map<String, dynamic>?) ?? const {};
      print('  - ${m['aweme_id']} | ${author['nickname']} | ${(m['desc'] ?? '').toString().substring(0, (m['desc'] ?? '').toString().length > 35 ? 35 : (m['desc'] ?? '').toString().length)}');
    }
  } catch (e) {
    print('[dart] 解析失败: $e');
  }
  client.close();
}
