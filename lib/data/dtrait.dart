// x-tt-session-dtrait 的高风控头纯 Dart 实现。
//
// 抖音的写接口（点赞 / 收藏 / 评论 / 私信）在 2026 年的风控里要求这个头，
// 缺失时响应为空或 HTTP 403。头部结构：
//
//   <pk1_version>_<base64(RSA_PKCS1v15(pk1, aes_key_hex))>_<base64(iv + AES128_CBC(payload))>
//
// - aes_key_hex：16 字节随机数的 32 位十六进制字符串，RSA 加密的就是这个字符串
// - AES-128-CBC + PKCS7，IV 随机 16 字节并前置
// - payload = {"dtrait":<设备特征blob>,"timestamp":<秒>,"sdkVersion":"1.0.0.16","path":<path>}
//
// 设备特征 blob 由参考实现按同一份设备档案纯算得出（canvas/WebGL/audio
// 这类必须真实渲染的特征用档案里抓到的 murmur3 值），这里作为常量复用；
// 外层 AES/IV/RSA 每次会话重新生成。算法与参考实现逐字节对齐，含大整数
// RSA 与自写 AES，不引入任何第三方依赖，三端一致。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 设备特征 blob（与参考实现同一份 Chrome 设备档案生成，236 字符）。
const String kDtraitBlob =
    'IAAAAADQIC0FVqIh4kBm/yLQO48ZI0f7Q3wkUnQhRSUtc6pZJoXtgvcnqvUbwih5/ufyKR3SnsMqMtFjyisa3jq/LEbrp0It3oooWy6x8OwMLzYf+ukwKpioVDEAAAAAMg10HEszi/GgODQpsnJ0NRJqRnA2hZHFNjcbzZ0NOFhf5lQ5ucywezqnDTbrO0LJZ588JQFrBT3os+69Pnc1cw4/6hH+lkBcuWKWRwEp4hc=';

/// 浏览器登录包里内置的 d0 公钥（PEM）。
const String _kPk1Pem = '''-----BEGIN RSA PUBLIC KEY-----
MIIBCgKCAQEA4+dvvY7uM+opc+nLG/DumSeFo7aVcIm1LO+mUIrWprRzP0a1GpEQ
4qtO9MRf/lwEIx38+4BZ4XOHzevVtuUvfIOUE7ATtQW7FKJf5PnSLCI6/k0vl1FC
LUSVmEP6qPJrIjZ4zXoqi3yuNZ+1odbRA//GHgcgSyyyaLqzwjkpWGXouMYmvYsc
ppk/fv2EWABstPNxWa4EOBCadTUPkXNM76NBEP9xzTJ2S0wiDv1oS/vKvrSUpWcJ
nazkkBvqQbbAqVbQFTF/DPikppu6ZT6lGIXvJKCrreFiHA2qK6tS18SWVHW9ARz1
+cjB1eqIIYdohWpT2B40OC4O8tVeBAnbiQIDAQAB
-----END RSA PUBLIC KEY-----''';

/// 浏览器里写死的 dtrait SDK 版本。
const String kDtraitSdkVersion = '1.0.0.16';

/// 一个会话内的 dtrait 材料：RSA 加密后的 AES key 可复用，
/// 第二段（IV + AES 密文）每个请求按 path 重新生成。
class DtraitSession {
  DtraitSession._(this._keyHex, this._encKey) {
    _key = _hexToBytes(_keyHex);
  }

  final String _keyHex;
  final List<int> _encKey;
  late final List<int> _key;
  final Random _random = Random.secure();

  static DtraitSession create({String blob = kDtraitBlob}) {
    final random = Random.secure();
    // 与浏览器随机消耗顺序一致：先 key，再 IV，再 RSA padding。
    final keyBytes = List<int>.generate(16, (_) => random.nextInt(256));
    final keyHex = keyBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final (n, e) = _parseRsaPublicKey(_kPk1Pem);
    final encKey = _rsaEncryptPkcs1v15(n, e, utf8.encode(keyHex), random);
    diagTrait('dtrait 会话材料已生成');
    return DtraitSession._(keyHex, encKey);
  }

  /// 生成绑定 [path] 的完整头。
  String headerFor(String path, {String blob = kDtraitBlob}) {
    final iv = List<int>.generate(16, (_) => _random.nextInt(256));
    final payload = '{"dtrait":${jsonEncode(blob)},'
        '"timestamp":${DateTime.now().millisecondsSinceEpoch ~/ 1000},'
        '"sdkVersion":${jsonEncode(kDtraitSdkVersion)},'
        '"path":${jsonEncode(path)}}';
    final cipher = _aes128CbcEncrypt(
        _key, iv, Uint8List.fromList(utf8.encode(payload)));
    final part1 = base64.encode(_encKey);
    final part2 = base64.encode([...iv, ...cipher]);
    return 'd0_${part1}_$part2';
  }

  static List<int> _hexToBytes(String hex) => [
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16)
      ];
}

// 诊断钩子：避免这个纯数据文件反向依赖 douyin_api，用回调注入。
void Function(String message)? dtraitLogger;
void diagTrait(String message) => dtraitLogger?.call(message);

// ---------------------------------------------------------------- RSA

/// DER 元素头长度（tag + length 字段）。
int _derHeaderSize(List<int> der, int tagIndex) {
  final first = der[tagIndex + 1];
  return first < 0x80 ? 2 : 2 + (first & 0x7F);
}

/// DER 元素的内容长度。
int _derElementLength(List<int> der, int tagIndex) {
  final first = der[tagIndex + 1];
  if (first < 0x80) return first;
  final n = first & 0x7F;
  var value = 0;
  for (var j = 0; j < n; j++) {
    value = (value << 8) | der[tagIndex + 2 + j];
  }
  return value;
}

(BigInt, BigInt) _parseRsaPublicKey(String pem) {
  final body =
      pem.split('\n').where((line) => !line.contains('-----')).join();
  final der = base64.decode(body.trim());
  if (der[0] != 0x30) throw StateError('dtrait 公钥不是 DER SEQUENCE');
  var i = _derHeaderSize(der, 0);
  if (der[i] != 0x02) throw StateError('dtrait 公钥缺少 modulus');
  final nLen = _derElementLength(der, i);
  final nStart = i + _derHeaderSize(der, i);
  final n = _bigIntFromBytes(der.sublist(nStart, nStart + nLen));
  i = nStart + nLen;
  if (der[i] != 0x02) throw StateError('dtrait 公钥缺少 exponent');
  final eLen = _derElementLength(der, i);
  final eStart = i + _derHeaderSize(der, i);
  final e = _bigIntFromBytes(der.sublist(eStart, eStart + eLen));
  return (n, e);
}

BigInt _bigIntFromBytes(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

List<int> _rsaEncryptPkcs1v15(
    BigInt n, BigInt e, List<int> message, Random random) {
  final k = (n.bitLength + 7) ~/ 8;
  final psLen = k - message.length - 3;
  final ps = <int>[];
  while (ps.length < psLen) {
    final b = random.nextInt(256);
    if (b != 0) ps.add(b);
  }
  final em = [0x00, 0x02, ...ps, 0x00, ...message];
  final m = _bigIntFromBytes(em);
  final c = m.modPow(e, n);
  final out = Uint8List(k);
  var v = c;
  for (var i = k - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xFF)).toInt();
    v = v >> 8;
  }
  return out;
}

// ---------------------------------------------------------------- AES-128

final List<int> _sbox = _buildSbox();

List<int> _buildSbox() {
  int gmul(int a, int b) {
    var p = 0;
    for (var i = 0; i < 8; i++) {
      if (b & 1 != 0) p ^= a;
      final hi = a & 0x80;
      a = (a << 1) & 0xFF;
      if (hi != 0) a ^= 0x1B;
      b >>= 1;
    }
    return p;
  }

  final box = List<int>.filled(256, 0);
  for (var x = 0; x < 256; x++) {
    var inv = 0;
    if (x != 0) {
      for (var y = 1; y < 256; y++) {
        if (gmul(x, y) == 1) {
          inv = y;
          break;
        }
      }
    }
    int rotl(int v, int n) => ((v << n) | (v >> (8 - n))) & 0xFF;
    box[x] = inv ^ rotl(inv, 1) ^ rotl(inv, 2) ^ rotl(inv, 3) ^ rotl(inv, 4) ^ 0x63;
  }
  return box;
}

int _xtime(int x) => ((x << 1) & 0xFF) ^ ((x & 0x80) != 0 ? 0x1B : 0);

List<int> _expandKey(List<int> key) {
  final w = Uint8List(44 * 4);
  w.setRange(0, 16, key);
  var rcon = 1;
  for (var i = 4; i < 44; i++) {
    var t0 = w[4 * i - 4];
    var t1 = w[4 * i - 3];
    var t2 = w[4 * i - 2];
    var t3 = w[4 * i - 1];
    if (i % 4 == 0) {
      final tmp = t0;
      t0 = _sbox[t1] ^ rcon;
      t1 = _sbox[t2];
      t2 = _sbox[t3];
      t3 = _sbox[tmp];
      rcon = _xtime(rcon);
    }
    w[4 * i] = w[4 * (i - 4)] ^ t0;
    w[4 * i + 1] = w[4 * (i - 4) + 1] ^ t1;
    w[4 * i + 2] = w[4 * (i - 4) + 2] ^ t2;
    w[4 * i + 3] = w[4 * (i - 4) + 3] ^ t3;
  }
  return w;
}

void _encryptBlock(Uint8List state, List<int> roundKeys) {
  void addRoundKey(int round) {
    final off = round * 16;
    for (var i = 0; i < 16; i++) {
      state[i] ^= roundKeys[off + i];
    }
  }

  addRoundKey(0);
  for (var round = 1; round <= 10; round++) {
    for (var i = 0; i < 16; i++) {
      state[i] = _sbox[state[i]];
    }
    // ShiftRows：第 r 行左移 r 个位置（状态按列存放：s[r][c] = state[4c+r]）
    final t = List<int>.from(state);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        state[4 * c + r] = t[4 * ((c + r) % 4) + r];
      }
    }
    if (round != 10) {
      for (var c = 0; c < 4; c++) {
        final a0 = state[4 * c];
        final a1 = state[4 * c + 1];
        final a2 = state[4 * c + 2];
        final a3 = state[4 * c + 3];
        state[4 * c] = _xtime(a0) ^ (_xtime(a1) ^ a1) ^ a2 ^ a3;
        state[4 * c + 1] = a0 ^ _xtime(a1) ^ (_xtime(a2) ^ a2) ^ a3;
        state[4 * c + 2] = a0 ^ a1 ^ _xtime(a2) ^ (_xtime(a3) ^ a3);
        state[4 * c + 3] = (_xtime(a0) ^ a0) ^ a1 ^ a2 ^ _xtime(a3);
      }
    }
    addRoundKey(round);
  }
}

Uint8List _aes128CbcEncrypt(List<int> key, List<int> iv, Uint8List plain) {
  final roundKeys = _expandKey(key);
  final pad = 16 - plain.length % 16;
  final data = Uint8List(plain.length + pad)
    ..setRange(0, plain.length, plain);
  for (var i = plain.length; i < data.length; i++) {
    data[i] = pad;
  }
  final out = Uint8List(data.length);
  var prev = iv;
  for (var off = 0; off < data.length; off += 16) {
    final block = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      block[i] = data[off + i] ^ prev[i];
    }
    _encryptBlock(block, roundKeys);
    out.setRange(off, off + 16, block);
    prev = block;
  }
  return out;
}
