// 验证「全新安装」路径：Dart 自己引导出匿名 Cookie，再请求推荐流。
// 不依赖任何预先存在的 Cookie 文件。
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

Map<String, String> parseSetCookie(List<String> raw) {
  final out = <String, String>{};
  for (final line in raw) {
    final pair = line.split(';').first;
    final idx = pair.indexOf('=');
    if (idx > 0) {
      out[pair.substring(0, idx).trim()] = pair.substring(idx + 1).trim();
    }
  }
  return out;
}

List<String> getSetCookie(HttpClientResponse resp) {
  final list = <String>[];
  resp.headers.forEach((name, values) {
    if (name.toLowerCase() == 'set-cookie') list.addAll(values);
  });
  return list;
}

Future<void> main() async {
  final client = HttpClient();
  final cookies = <String, String>{};

  // 1) 首页，看服务端主动下发哪些 cookie
  final homeReq = await client.getUrl(Uri.parse('https://www.douyin.com/'));
  homeReq.headers.set('user-agent', ua);
  homeReq.headers.set('accept',
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
  final homeResp = await homeReq.close();
  final homeBody = await homeResp.transform(utf8.decoder).join();
  final raw = getSetCookie(homeResp);
  cookies.addAll(parseSetCookie(raw));
  print('[home] HTTP ${homeResp.statusCode} | html len ${homeBody.length}');
  print('[home] 下发 cookie: ${cookies.entries.map((e) => '${e.key}(${e.value.length})').join(', ')}');

  // 2) 缺 ttwid 就走公开注册接口
  if (!cookies.containsKey('ttwid')) {
    final regReq = await client.postUrl(
        Uri.parse('https://ttwid.bytedance.com/ttwid/union/register/'));
    regReq.headers.set('user-agent', ua);
    regReq.headers.set('content-type', 'application/json');
    regReq.write(jsonEncode({
      'region': 'cn',
      'aid': 1768,
      'needFid': false,
      'service': 'www.douyin.com',
      'migrate_info': {'ticket': '', 'source': 'node'},
      'cbUrlProtocol': 'https',
      'union': true,
    }));
    final regResp = await regReq.close();
    final body = await regResp.transform(utf8.decoder).join();
    cookies.addAll(parseSetCookie(getSetCookie(regResp)));
    print('[ttwid] HTTP ${regResp.statusCode} | body[0:80]=${body.substring(0, body.length > 80 ? 80 : body.length)}');
    print('[ttwid] cookie: ${cookies.keys.join(', ')}');
  }

  // 3) 用这份全新 Cookie 请求推荐流
  final params = jsonDecode(File('$probes/feed_query.json').readAsStringSync())
      as Map<String, dynamic>;
  params.remove('a_bogus');
  final query = params.entries
      .map((e) => '${e.key}=${quote(e.value.toString())}')
      .join('&');
  final ab = AbogusSigner().signQuery(query, host: 'www.douyin.com');
  final cookieHeader = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  final uri = Uri.parse(
      'https://www.douyin.com/aweme/v1/web/tab/feed/?$query&a_bogus=${quote(ab)}');
  final req = await client.getUrl(uri);
  req.headers.set('user-agent', ua);
  req.headers.set('referer', 'https://www.douyin.com/');
  req.headers.set('cookie', cookieHeader);
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  print('[feed] cookie=${cookies.keys.length} | HTTP ${resp.statusCode} | len ${body.length}');
  try {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final list = (j['aweme_list'] as List?) ?? const [];
    print('[feed] status_code=${j['status_code']} | aweme_list=${list.length}');
    for (final a in list.take(2)) {
      final m = a as Map<String, dynamic>;
      print('  - ${m['aweme_id']} | ${(m['author'] as Map?)?['nickname']}');
    }
  } catch (e) {
    print('[feed] 空/非 JSON（服务端静默拒绝）');
  }
  client.close();
}
