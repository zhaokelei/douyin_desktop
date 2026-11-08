// 中文输入法守卫（Windows）。
//
// 问题：播放页没有文字焦点时，微软拼音仍然把窗口的输入法上下文保持为"中文"，
// 按 X / Z / S / 空格 / F 会先被输入法吃掉开始组字，弹出候选框，
// 用户还得再选字，快捷键也就失效了。
//
// 做法：原生侧（windows/runner/flutter_window.cpp）提供 douyin/ime 通道：
//   disable → ImmAssociateContext(hwnd, nullptr)，把该窗口的 HIMC 摘掉；
//   restore → 把原来保存的 HIMC 塞回去（没有就 IACE_DEFAULT 重建）。
//
// Dart 侧只维护"当前是否允许输入法"这一个愿望值，并用串行泵保证
// 焦点快速切换时 disable/restore 不会乱序。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'diag.dart';

class ImeGuard {
  ImeGuard._();

  static const MethodChannel _channel = MethodChannel('douyin/ime');

  /// 输入法是否正在组字（候选框已弹出、文字还没提交）。
  ///
  /// 由输入框的 TextEditingController 上报（见 [watchComposing]）：
  /// 焦点判断之外的第二个保险——组字没提交时，X/Z/S 一律让给输入法。
  static bool composing = false;

  /// 期望状态：true = 允许输入法（输入框聚焦），false = 摘掉（快捷键页面）。
  static bool _wantEnabled = false;
  static bool _appliedEnabled = false;
  static bool _busy = false;
  static bool _forceResync = false;

  /// 首帧前的原生 IME 默认是"启用"状态，而 [_appliedEnabled] 初值为 false，
  /// 若不强制同步一次，第一次 suppress() 会被当成"已经是目标状态"而漏发调用。
  static bool _syncedOnce = false;

  /// 当前是否已经摘掉了输入法（自测/日志用）。
  static bool get isSuppressed => !_appliedEnabled;

  /// 非输入框场景：摘掉输入法上下文。
  static void suppress() => _setEnabled(false);

  /// 输入框聚焦：恢复输入法上下文（否则评论框打不了中文）。
  static void allow() => _setEnabled(true);

  /// 应用切回前台 / 窗口重新获得焦点时强制再下发一次状态。
  ///
  /// 系统或第三方输入法可能在后台把 IME 上下文重新挂回窗口，此时
  /// [_wantEnabled] 与 [_appliedEnabled] 都没变，普通的 [suppress] 会
  /// 认为「已是目标状态」而什么都不做，快捷键又会开始组字。
  static void resync() {
    if (!Platform.isWindows) return;
    _forceResync = true;
    _pump();
  }

  static void _setEnabled(bool enabled) {
    if (!Platform.isWindows) return;
    _wantEnabled = enabled;
    _pump();
  }

  /// 串行执行：只有状态真的需要变化时才发一次平台调用。
  static Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_forceResync || _wantEnabled != _appliedEnabled || !_syncedOnce) {
        _forceResync = false;
        final target = _wantEnabled;
        try {
          await _channel.invokeMethod<void>(target ? 'restore' : 'disable');
        } catch (e) {
          // 原生侧还没注册（例如自测脚本直接跑 Dart）时静默降级。
          diag('ime', '原生通道调用失败（${target ? 'restore' : 'disable'}）：$e');
          break;
        }
        _appliedEnabled = target;
        _syncedOnce = true;
        diag('ime',
            target ? '已恢复输入法上下文（输入框可打中文）' : '已摘除输入法上下文（快捷键不再组字）');
      }
    } finally {
      _busy = false;
    }
  }

  /// 跟踪某个输入框的组字状态：IME 组合未提交时 [composing] 为 true。
  static void watchComposing(TextEditingController controller) {
    controller.addListener(() {
      final composingRange = controller.value.composing;
      composing = composingRange.isValid && !composingRange.isCollapsed;
    });
  }

  /// 输入框关闭/销毁时清掉组字标记，避免快捷键被永久当成"正在打字"。
  static void clearComposing() => composing = false;
}

/// 焦点是否落在文字输入框（EditableText）里。
///
/// 播放页的快捷键和 IME 开关都靠它判断"该不该让位给输入"。
bool focusIsInEditableText() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.findAncestorStateOfType<EditableTextState>() != null;
}
