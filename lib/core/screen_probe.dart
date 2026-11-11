import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 根 RepaintBoundary 的 key：由 main.dart 挂在整棵 widget 树外层。
/// 用途一：离屏自检时截图；用途二：判断"视频画面是否真的上屏"。
final GlobalKey kRootBoundaryKey = GlobalKey(debugLabel: 'root-boundary');

/// 采样当前**真实渲染出**的画面平均亮度（0~255）。
///
/// 只统计视频主区（左侧 70% 宽、纵向 20%~80%），避开右侧互动栏和底部控制条。
/// 返回 -1 表示拿不到图像（还没绘制或截图失败）。
///
/// 为什么要用它：实测本机 libmpv 的 `video-pts` 读不到，
/// `estimated-frame-number` 涨到 4 时屏幕上仍可能还是黑的
/// （mpv 已在出帧，但共享纹理上传到 Flutter 还要一小段时间）。
/// 只有采样真实渲染结果，才能确认"用户此刻确实看得见画面"。
Future<double> sampleScreenBrightness({double pixelRatio = 0.12}) async {
  final boundary = kRootBoundaryKey.currentContext?.findRenderObject()
      as RenderRepaintBoundary?;
  if (boundary == null) return -1;
  ui.Image? image;
  try {
    image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null || data.lengthInBytes < 4) return -1;
    final w = image.width;
    final h = image.height;
    final y0 = (h * 0.2).round();
    final y1 = (h * 0.8).round();
    final x1 = (w * 0.7).round();
    // 逐像素求和是纯 Dart 循环，大图上并不便宜。这里按步长跳采：
    // 判断"是不是黑屏"只需要一个粗略平均值，隔行隔列取 1/9 的像素
    // 结果几乎一样，CPU 时间却少一个数量级。
    const step = 3;
    var sum = 0.0;
    var count = 0;
    for (var y = y0; y < y1; y += step) {
      for (var x = 2; x < x1; x += step) {
        final i = (y * w + x) * 4;
        final r = data.getUint8(i);
        final g = data.getUint8(i + 1);
        final b = data.getUint8(i + 2);
        sum += 0.299 * r + 0.587 * g + 0.114 * b;
        count++;
      }
    }
    return count == 0 ? -1 : sum / count;
  } catch (_) {
    return -1;
  } finally {
    image?.dispose();
  }
}
