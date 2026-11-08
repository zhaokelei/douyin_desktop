// 纯 Dart MD5（RFC 1321），只用于 x-secsdk-web-signature 的 32 位小写 hex。
//
// 不引入 crypto 依赖，保持三端零额外依赖：算法是固定实现，结果在单测/探针里
// 与 Python 的 hashlib.md5 对齐过（同一明文签名逐字节一致）。
import 'dart:convert';

const List<int> _s = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

const List<int> _k = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
  0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
  0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
  0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
  0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

String md5Hex(String input) {
  final bytes = <int>[...utf8.encode(input)];
  final bitLen = bytes.length * 8;
  bytes.add(0x80);
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  for (var i = 0; i < 8; i++) {
    bytes.add((bitLen >> (8 * i)) & 0xFF);
  }

  var a = 0x67452301;
  var b = 0xefcdab89;
  var c = 0x98badcfe;
  var d = 0x10325476;

  for (var chunk = 0; chunk < bytes.length; chunk += 64) {
    final m = List<int>.filled(16, 0);
    for (var i = 0; i < 16; i++) {
      final o = chunk + i * 4;
      m[i] = bytes[o] |
          (bytes[o + 1] << 8) |
          (bytes[o + 2] << 16) |
          (bytes[o + 3] << 24);
    }
    var aa = a;
    var bb = b;
    var cc = c;
    var dd = d;
    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (bb & cc) | (~bb & dd);
        g = i;
      } else if (i < 32) {
        f = (dd & bb) | (~dd & cc);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = bb ^ cc ^ dd;
        g = (3 * i + 5) % 16;
      } else {
        f = cc ^ (bb | ~dd);
        g = (7 * i) % 16;
      }
      final tmp = dd;
      dd = cc;
      cc = bb;
      final sum = (aa + f + _k[i] + m[g]) & 0xFFFFFFFF;
      final rotated = ((sum << _s[i]) & 0xFFFFFFFF) | (sum >> (32 - _s[i]));
      bb = (bb + rotated) & 0xFFFFFFFF;
      aa = tmp;
    }
    a = (a + aa) & 0xFFFFFFFF;
    b = (b + bb) & 0xFFFFFFFF;
    c = (c + cc) & 0xFFFFFFFF;
    d = (d + dd) & 0xFFFFFFFF;
  }

  String word(int w) {
    final b = StringBuffer();
    for (var i = 0; i < 4; i++) {
      b.write(((w >> (8 * i)) & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  return '${word(a)}${word(b)}${word(c)}${word(d)}';
}
