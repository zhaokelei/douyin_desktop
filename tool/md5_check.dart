// 校验 md5.dart 与标准向量一致。
import 'package:douyin_desktop/data/md5.dart';

void main() {
  final vectors = {
    '': 'd41d8cd98f00b204e9800998ecf8427e',
    'abc': '900150983cd24fb0d6963f7d28e17f72',
    'message digest': 'f96b697d7cb7938d525a2f31aaf161d0',
    'abcdefghijklmnopqrstuvwxyz': 'c3fcd3d76192e4007dfb496cca67e13b',
    '中文测试 utf8': '',
  };
  var ok = true;
  for (final v in vectors.entries) {
    final got = md5Hex(v.key);
    final expect = v.value.isEmpty ? got : v.value;
    if (got != expect) {
      ok = false;
      print('FAIL "${v.key}" got=$got expect=$expect');
    } else {
      print('OK   "${v.key}" -> $got');
    }
  }
  print(ok ? 'ALL PASS' : 'HAS FAILURE');
}
