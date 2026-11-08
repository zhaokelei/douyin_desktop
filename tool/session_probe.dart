// 验证「粘贴 Cookie 导入 → 落盘 → 重启读回」这条链路（纯本地，不发任何抖音请求）。
//
// 用法：DOUYIN_LOG=<log> dart run tool/session_probe.dart
// 说明：写入的是明显的假 Cookie，跑完会删掉，不会影响真实登录态。
import 'dart:io';

import 'package:douyin_desktop/data/douyin_api.dart';

void main() {
  const header =
      'sessionid=probe_fake_value_for_path_check; ttwid=probe_ttwid; UIFID=probe_uifid';

  final api = DouyinApi();
  final written = api.saveCookieHeader(header);
  print('[write] path=$written');
  if (written == null) {
    print('[fail] 落盘失败');
    exit(2);
  }
  final file = File(written);
  final stat = file.statSync();
  print('[stat] exists=${file.existsSync()} size=${stat.size} mtime=${stat.modified}');

  // 模拟重启：全新实例只走 resolveCookiePath（不看内存状态）。
  final hit = DouyinApi.resolveCookiePath();
  print('[resolve] hit=$hit');
  if (hit == null) {
    print('[fail] 重启后找不到 Cookie 文件');
    exit(3);
  }
  final fresh = DouyinApi();
  final loaded = fresh.loadCookieFile(hit);
  print('[load] entries=${loaded.length} keys=${loaded.keys.join(",")}');
  print('[state] isLoggedIn=${fresh.isLoggedIn} hitEqualsWritten=${hit == written}');

  // 清理假 Cookie，避免影响下一次真实启动。
  try {
    file.deleteSync();
    print('[cleanup] deleted=$written');
  } catch (e) {
    print('[cleanup] 删除失败: $e');
  }
  if (fresh.isLoggedIn && hit == written) {
    print('[PASS] 导入落盘与重启读回一致');
  } else {
    print('[FAIL] 落盘或读回不一致');
    exit(4);
  }
}
