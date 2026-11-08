// 验证「清晰度按上限挑档」规则（直接调用生产函数 pickVariantUnderCap）。
//
// 用法：dart run tool/quality_probe.dart
import 'dart:io';

import 'package:douyin_desktop/data/models.dart';

VideoVariant _v(String label) => VideoVariant(
      label: label,
      url: 'u://$label',
      bitRate: 0,
      height: heightOfQualityLabel(label) ?? 0,
    );

void main() {
  var failed = 0;
  void check(String name, List<String> labels, String pref, String? expect) {
    final variants = labels.map(_v).toList();
    final got = pickVariantUnderCap(variants, pref);
    final ok = got?.label == expect;
    if (!ok) failed++;
    print('${ok ? "[PASS]" : "[FAIL]"} $name  档位=[${labels.join("/")}] '
        '选=$pref 期望=${expect ?? "null"} 实际=${got?.label ?? "null"}');
  }

  check('选 4K，作品有 4K', ['4K', '1080P', '720P'], '4K', '4K');
  check('选 4K，作品最高 1080P', ['1080P', '720P'], '4K', '1080P');
  check('选 4K，作品最高 720P', ['720P'], '4K', '720P');
  check('选 1080P，作品有 1080P', ['4K', '1080P', '720P'], '1080P', '1080P');
  check('选 1080P，作品最高 720P', ['720P'], '1080P', '720P');
  check('选 1440P（不存在），取 ≤1440 最高', ['4K', '1080P', '720P'], '1440P', '1080P');
  check('选 720P，精确命中', ['4K', '1080P', '720P'], '720P', '720P');
  check('选 540P，作品全高于上限→取最低', ['1080P', '720P'], '540P', '720P');
  check('选 4K，作品档位无高度信息', ['标准'], '4K', null);

  // 额外校验：高度换算与 4K 别名。
  final h1 = heightOfQualityLabel('4K');
  final h2 = heightOfQualityLabel('1080P');
  print('${h1 == 2160 && h2 == 1080 ? "[PASS]" : "[FAIL]"} 高度换算 4K=$h1 1080P=$h2');
  if (h1 != 2160 || h2 != 1080) failed++;

  print(failed == 0 ? '[ALL PASS] 清晰度上限规则全部通过' : '[FAIL] 共 $failed 项未通过');
  exit(failed == 0 ? 0 : 1);
}
