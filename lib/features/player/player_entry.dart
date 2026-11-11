import 'package:flutter/widgets.dart';

import '../../core/player_backend_config.dart';
import '../../data/douyin_api.dart';
import '../../data/models.dart';
import 'player_page.dart' as mpv;
import 'player_page_fvp.dart' as fvp;

/// 播放页统一入口：按编译期后端开关路由到对应实现。
///
/// 两个页面各自保留完整功能（评论 / 缓存预取 / 清晰度 / 全屏 / 快捷键 /
/// 硬解降级），UI 代码同源。灰度期间 mpv 版**一个字都不改**，
/// 保证已修复的问题不回归；fvp 版在 `player_page_fvp.dart` 里独立演进。
///
/// 用别名 import 而不是条件导出：Dart 的条件导入只支持 `dart.library.*`
/// 这类内置条件，无法基于自定义 dart-define 切文件。
Widget buildPlayerPage({
  required DouyinApi api,
  required List<AwemeItem> items,
  required int initialIndex,
  Future<int> Function()? onLoadMore,
}) {
  if (isFvpBackend) {
    return fvp.PlayerPage(
      api: api,
      items: items,
      initialIndex: initialIndex,
      onLoadMore: onLoadMore,
    );
  }
  return mpv.PlayerPage(
    api: api,
    items: items,
    initialIndex: initialIndex,
    onLoadMore: onLoadMore,
  );
}
