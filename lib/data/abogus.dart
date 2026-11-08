// a_bogus 纯 Dart 实现。
//
// 算法来源于用户已授权的 DouYin_Spider（MIT）的 utils/ab_pure.py + utils/sm3.py，
// 这里逐行移植，保持与 Python 版行为一致（随机字段不影响服务端校验）。
// 不依赖 JS 引擎 / WebView，Windows / macOS / Linux 行为一致。

import 'dart:math';

import '../core/platform_adapter.dart';

/// SM3 杂凑（GB/T 32905-2016）。
class Sm3 {
  static const List<int> _iv = [
    0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
    0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
  ];

  static int _rotl(int x, int n) {
    n &= 31;
    x &= 0xFFFFFFFF;
    if (n == 0) return x;
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
  }

  static int _tj(int j) => j < 16 ? 0x79CC4519 : 0x7A879D8A;

  static int _ff(int x, int y, int z, int j) =>
      j < 16 ? (x ^ y ^ z) : ((x & y) | (x & z) | (y & z)) & 0xFFFFFFFF;

  static int _gg(int x, int y, int z, int j) =>
      j < 16 ? (x ^ y ^ z) : ((x & y) | ((~x & 0xFFFFFFFF) & z)) & 0xFFFFFFFF;

  static int _p0(int x) => (x ^ _rotl(x, 9) ^ _rotl(x, 17)) & 0xFFFFFFFF;

  static int _p1(int x) => (x ^ _rotl(x, 15) ^ _rotl(x, 23)) & 0xFFFFFFFF;

  static List<int> _cf(List<int> v, List<int> block) {
    final w = List<int>.filled(68, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (block[i * 4] << 24) |
          (block[i * 4 + 1] << 16) |
          (block[i * 4 + 2] << 8) |
          block[i * 4 + 3];
    }
    for (var j = 16; j < 68; j++) {
      w[j] = (_p1(w[j - 16] ^ w[j - 9] ^ _rotl(w[j - 3], 15)) ^
              _rotl(w[j - 13], 7) ^
              w[j - 6]) &
          0xFFFFFFFF;
    }
    final w1 = List<int>.generate(64, (j) => (w[j] ^ w[j + 4]) & 0xFFFFFFFF);

    var a = v[0], b = v[1], c = v[2], d = v[3];
    var e = v[4], f = v[5], g = v[6], h = v[7];
    for (var j = 0; j < 64; j++) {
      final ss1 = _rotl((_rotl(a, 12) + e + _rotl(_tj(j), j)) & 0xFFFFFFFF, 7);
      final ss2 = ss1 ^ _rotl(a, 12);
      final tt1 = (_ff(a, b, c, j) + d + ss2 + w1[j]) & 0xFFFFFFFF;
      final tt2 = (_gg(e, f, g, j) + h + ss1 + w[j]) & 0xFFFFFFFF;
      d = c;
      c = _rotl(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = _rotl(f, 19);
      f = e;
      e = _p0(tt2);
    }
    return [
      (a ^ v[0]) & 0xFFFFFFFF,
      (b ^ v[1]) & 0xFFFFFFFF,
      (c ^ v[2]) & 0xFFFFFFFF,
      (d ^ v[3]) & 0xFFFFFFFF,
      (e ^ v[4]) & 0xFFFFFFFF,
      (f ^ v[5]) & 0xFFFFFFFF,
      (g ^ v[6]) & 0xFFFFFFFF,
      (h ^ v[7]) & 0xFFFFFFFF,
    ];
  }

  static List<int> hash(List<int> message) {
    final msg = List<int>.from(message);
    final bitLen = msg.length * 8;
    msg.add(0x80);
    while (msg.length % 64 != 56) {
      msg.add(0x00);
    }
    // 64 位长度，按大端
    final hi = (bitLen >> 32) & 0xFFFFFFFF;
    final lo = bitLen & 0xFFFFFFFF;
    msg
      ..add((hi >> 24) & 0xFF)
      ..add((hi >> 16) & 0xFF)
      ..add((hi >> 8) & 0xFF)
      ..add(hi & 0xFF)
      ..add((lo >> 24) & 0xFF)
      ..add((lo >> 16) & 0xFF)
      ..add((lo >> 8) & 0xFF)
      ..add(lo & 0xFF);

    var v = List<int>.from(_iv);
    for (var i = 0; i < msg.length; i += 64) {
      v = _cf(v, msg.sublist(i, i + 64));
    }
    return [
      for (final x in v) ...[
        (x >> 24) & 0xFF,
        (x >> 16) & 0xFF,
        (x >> 8) & 0xFF,
        x & 0xFF,
      ],
    ];
  }

  static List<int> hashUtf8(String text) => hash(<int>[
        for (final unit in text.runes) ...[
          if (unit > 0xFFFF) ...[
            (unit >> 8) & 0xFF,
            unit & 0xFF,
          ] else
            unit,
        ],
      ]);
}

/// a_bogus 签名器。
class AbogusSigner {
  AbogusSigner({this.fixed = false});

  /// fixed=true 时使用抓包常量（离线对拍用）；线上必须 false。
  final bool fixed;

  static const String _salt = 'dhzx';
  static const int _sdkVersionCode = 1;
  static const int _sdkMinorCode = 12;
  static const int _rc4KeyByte = 211;
  /// 参与签名运算的 UA 必须与请求头里的 UA 完全一致，否则服务端重算会不匹配。
  /// 因此这里取平台适配层的值，而不是写死 Windows；Windows 上取值与原来逐字符相同。
  static final String _ua = PlatformAdapter.userAgent;
  static const List<int> _geo = <int>[
    2560, 1215, 2560, 1392, 2560, 1392, 2560, 1440
  ];
  static const String _alphabetS3 =
      'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe';
  static const String _alphabetS4 =
      'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe';
  static const List<int> _a98Perm = <int>[
    34, 44, 56, 61, 73, 29, 70, 45, 35, 49, 38, 66, 51, 68, 28, 48, 64, 47,
    30, 71, 26, 55, 31, 69, 59, 40, 62, 63, 27, 72, 41, 74, 57, 52, 42, 39,
    33, 67, 53, 43, 65, 46, 36, 24, 60, 32, 79, 80, 84, 85,
  ];
  static const Map<String, Map<String, int>> _hostConfigs = <String, Map<String, int>>{
    'www.douyin.com': <String, int>{'sdk_minor': 8, 'l40': 132, 'l41': 1, 'l42': 1},
    'login.douyin.com': <String, int>{'sdk_minor': 14, 'l40': 0, 'l41': 0, 'l42': 0},
  };
  static const Map<String, List<int>> _hostAppIds = <String, List<int>>{
    'www.douyin.com': <int>[6383, 11881],
    'live.douyin.com': <int>[6383, 7571],
    'creator.douyin.com': <int>[2906, 33638],
    'login.douyin.com': <int>[6383, 6241],
  };

  final Random _random = Random();
  int _counter = 2;

  /// 对已拼好的 query 签名。
  String signQuery(String query, {String body = '', String host = 'www.douyin.com'}) {
    final hostCfg = _hostConfigs[host] ?? const <String, int>{};
    final ids = _hostAppIds[host] ?? _hostAppIds['www.douyin.com']!;
    final aid = ids[0];
    final pageId = ids[1];

    final l = <int, dynamic>{};
    _counter += 1;
    final now = fixed ? 1720000000000 : DateTime.now().millisecondsSinceEpoch;

    l[12] = 3;
    l[14] = now;
    final v129 = hostCfg['sdk_version'] ?? _sdkVersionCode;
    final v14 = hostCfg['sdk_minor'] ?? _sdkMinorCode;

    final h1 = Sm3.hash(Sm3.hash(utf8Bytes('$query$_salt')));
    final h2 = Sm3.hash(Sm3.hash(utf8Bytes('$body$_salt')));
    final uaKey = <int>[(v129 ~/ 256) & 0xFF, v129 % 256, v14 % 256];
    final uaCipher = _rc4(uaKey, <int>[for (final c in _ua.trim().codeUnits) c]);
    final hUa = Sm3.hash(utf8Bytes(_b64(uaCipher, _alphabetS3)));

    final ink = now - 1;
    l[23] = <int>[3, 82];
    l[24] = 41;
    l[25] = <int>[1, 0, 1, 0, 1];
    l[26] = ((now - 1721836800000) ~/ 1000 ~/ 60 ~/ 60 ~/ 24 ~/ 14) & 0xFFFFFFFF;
    l[27] = _counterBucket(_counter);
    final closureT = fixed ? 1720000000000 : now;
    l[28] = closureT > 0 ? (now - closureT + 3) & 0xFF : 2;
    final tBytes = _le(now, 6);
    for (var i = 0; i < 6; i++) {
      l[29 + i] = tBytes[i];
    }
    final v129Bytes = _le(v129, 2);
    l[35] = v129Bytes[0];
    l[36] = v129Bytes[1];

    final flags = _envFlags();
    l[37] = <int>[0, 0, 0, 0, flags];
    final flagsBytes = _le(flags, 2);
    l[38] = flagsBytes[0];
    l[39] = flagsBytes[1];
    l[40] = hostCfg['l40'] ?? 0;
    l[41] = hostCfg['l41'] ?? 0;
    l[42] = hostCfg['l42'] ?? 0;
    l[43] = 0;
    final v14Bytes = _le(v14, 4);
    for (var i = 0; i < 4; i++) {
      l[44 + i] = v14Bytes[i];
    }
    l[48] = h1[9];
    l[49] = h1[18];
    l[51] = _escapeDigest(h1, 3, 11, 12, (flags & 2) != 0);
    l[52] = h2[10];
    l[53] = h2[19];
    l[55] = _escapeDigest(h2, 4, 8, 9, (flags & 4) != 0);
    l[56] = hUa[11];
    l[57] = hUa[21];
    l[59] = _escapeDigest(hUa, 5, 12, 13, (flags & 8) != 0);
    final inkBytes = _le(ink, 6);
    for (var i = 0; i < 6; i++) {
      l[60 + i] = inkBytes[i];
    }
    l[66] = l[12];
    final pageBytes = _le(pageId, 4);
    for (var i = 0; i < 4; i++) {
      l[67 + i] = pageBytes[i];
    }
    final aidBytes = _le(aid, 4);
    for (var i = 0; i < 4; i++) {
      l[71 + i] = aidBytes[i];
    }
    // 平台标签同样与浏览器指纹保持一致（Windows=Win32 / macOS=MacIntel / Linux=Linux x86_64）。
    final geoStr = '${_geo.join('|')}|'
        '${PlatformAdapter.webFingerprint['browser_platform']}';
    l[77] = _strToBytes(geoStr);
    l[78] = (l[77] as List<int>).length;
    final lenBytes = _le(l[78] as int, 2);
    l[79] = lenBytes[0];
    l[80] = lenBytes[1];
    l[81] = '${(now + 3) & 0xFF},';
    l[82] = _strToBytes(l[81] as String);
    l[83] = (l[82] as List<int>).length;
    final lenBytes2 = _le(l[83] as int, 2);
    l[84] = lenBytes2[0];
    l[85] = lenBytes2[1];

    final v6 = (_rand() * 65535).toInt();
    final a8 = <int>[
      ..._blend(l[25][0] as int, l[25][1] as int, v6 & 0xFF, (v6 >> 8) & 0xFF),
    ];
    _rand();
    a8.addAll(_blend(
      (l[25] as List<int>)[2],
      (l[25] as List<int>)[3],
      _z144Check(_rand(), flags),
      _z145Permissions(_rand()),
    ));
    l[86] = a8;

    var chk = 0;
    final checkIdx = <int>[
      24, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 38, 39, 40, 41, 42, 43,
      44, 45, 46, 47, 48, 49, 51, 52, 53, 55, 56, 57, 59, 60, 61, 62, 63, 64,
      65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 79, 80, 84, 85,
    ];
    for (final b in a8) {
      chk ^= b;
    }
    for (final idx in checkIdx) {
      chk ^= l[idx] as int;
    }
    l[87] = _toInt32(chk);

    final a98 = <int>[
      for (final idx in _a98Perm) l[idx] as int,
      ...(l[77] as List<int>),
      ...(l[82] as List<int>),
      l[87] as int,
    ];
    l[88] = a98;

    final hr0 = (_rand() * 65535).toInt() & 0xFF;
    l[89] = _blend(3, 82, hr0, _z143Offset(_rand()));

    final plain = <int>[...a8, ..._z148Expand(a98, _rand)];
    final cipher = _rc4(<int>[_rc4KeyByte], <int>[for (final x in plain) x & 0xFFFF]);
    return _b64(<int>[...(l[89] as List<int>), for (final c in cipher) c & 0xFF],
        _alphabetS4);
  }

  // ---------- 内部工具 ----------

  double _rand() => fixed ? 0.4142135623730951 : _random.nextDouble();

  static int _envFlags() {
    // bit0=1；bit2=是否 Node；bit5=是否 Firefox。桌面 Chrome 恒为 1。
    return 1;
  }

  static int _counterBucket(int counter) {
    if (counter > 10745) return 3;
    if (counter > 1283) return 4;
    if (counter > 139) return 5;
    return 6;
  }

  static int _z143Offset(double r) => (r * 40).toInt() + 0; // Chrome offset = 0

  static int _z144Check(double r, int flagsByte) {
    if (flagsByte & 64 != 0) {
      final n = (r * 109).toInt();
      return n + 110 + (n % 2);
    }
    final n = (r * 240).toInt();
    return n > 109 ? n + (n % 2) + 1 : n;
  }

  static int _z145Permissions(double r) {
    final base = (r * 255).toInt() & 77;
    return base | 2 | 16 | 32 | 128;
  }

  static List<int> _blend(int c0, int c1, int r0, int r1) => <int>[
        (r0 & 170) | (c0 & 85),
        (r0 & 85) | (c0 & 170),
        (r1 & 170) | (c1 & 85),
        (r1 & 85) | (c1 & 170),
      ];

  static List<int> _z148Expand(List<int> arr, double Function() rand) {
    final out = <int>[];
    var i = 0;
    final n = arr.length;
    while (i < n) {
      if (i + 2 < n) {
        final r = (rand() * 1000).toInt() & 255;
        out.addAll(<int>[
          (r & 145) | (arr[i] & 110),
          (r & 66) | (arr[i + 1] & 189),
          (r & 44) | (arr[i + 2] & 211),
          (arr[i] & 145) | (arr[i + 1] & 66) | (arr[i + 2] & 44),
        ]);
      } else {
        out.add(arr[i]);
        if (i + 1 < n && arr[i + 1] != 0) {
          out.add(arr[i + 1]);
        }
      }
      i += 3;
    }
    return out;
  }

  static int _escapeDigest(List<int> digest, int idx, int reserved, int fallback, bool force) {
    var v = idx < digest.length ? digest[idx] : fallback;
    while (v == reserved) {
      idx += 1;
      v = idx < digest.length ? digest[idx] : fallback;
    }
    return force ? reserved : v;
  }

  static List<int> _rc4(List<int> key, List<int> data) {
    final sbox = List<int>.generate(256, (i) => 255 - i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j * sbox[i] + j + key[i % key.length]) % 256;
      final tmp = sbox[i];
      sbox[i] = sbox[j];
      sbox[j] = tmp;
    }
    final out = <int>[];
    var i = 0;
    j = 0;
    for (final b in data) {
      i = (i + 1) % 256;
      j = (j + sbox[i]) % 256;
      final tmp = sbox[i];
      sbox[i] = sbox[j];
      sbox[j] = tmp;
      out.add(b ^ sbox[(sbox[i] + sbox[j]) % 256]);
    }
    return out;
  }

  static String _b64(List<int> data, String alphabet) {
    final out = <String>[];
    for (var i = 0; i < data.length; i += 3) {
      final chunk = data.sublist(i, min(i + 3, data.length));
      final b = <int>[...chunk, ...List<int>.filled(3 - chunk.length, 0)];
      final v = (b[0] << 16) | (b[1] << 8) | b[2];
      final idx = <int>[(v >> 18) & 63, (v >> 12) & 63, (v >> 6) & 63, v & 63];
      if (chunk.length == 1) {
        out.addAll(<String>[alphabet[idx[0]], alphabet[idx[1]], '=', '=']);
      } else if (chunk.length == 2) {
        out.addAll(<String>[
          alphabet[idx[0]], alphabet[idx[1]], alphabet[idx[2]], '='
        ]);
      } else {
        out.addAll(<String>[for (final k in idx) alphabet[k]]);
      }
    }
    return out.join();
  }

  static List<int> _le(int value, int count) =>
      <int>[for (var i = 0; i < count; i++) (value >> (8 * i)) & 255];

  static int _toInt32(int x) {
    x &= 0xFFFFFFFF;
    return x >= 0x80000000 ? x - 0x100000000 : x;
  }

  /// Python 的 str_to_bytes：>255 的码位拆成高低两个字节。
  static List<int> _strToBytes(String s) {
    final out = <int>[];
    for (final c in s.codeUnits) {
      if (c & 0xFF00 != 0) {
        out
          ..add((c >> 8) & 0xFF)
          ..add(c & 0xFF);
      } else {
        out.add(c);
      }
    }
    return out;
  }
}

/// UTF-8 字节（仅用于签名输入，保持与 Python encode('utf-8') 一致）。
List<int> utf8Bytes(String text) => <int>[
      for (final unit in text.runes) ...[
        if (unit < 0x80)
          unit
        else if (unit < 0x800) ...[
          0xC0 | (unit >> 6),
          0x80 | (unit & 0x3F),
        ] else if (unit < 0x10000) ...[
          0xE0 | (unit >> 12),
          0x80 | ((unit >> 6) & 0x3F),
          0x80 | (unit & 0x3F),
        ] else ...[
          0xF0 | (unit >> 18),
          0x80 | ((unit >> 12) & 0x3F),
          0x80 | ((unit >> 6) & 0x3F),
          0x80 | (unit & 0x3F),
        ],
      ],
    ];
