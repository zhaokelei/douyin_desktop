import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'core/ime_guard.dart';
import 'core/platform_style.dart';
import 'core/verify_banner.dart';
import 'features/shell/home_shell.dart';

class DouyinApp extends StatefulWidget {
  const DouyinApp({super.key});

  @override
  State<DouyinApp> createState() => _DouyinAppState();
}

class _DouyinAppState extends State<DouyinApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 全局输入法开关：焦点在输入框 → 恢复 IME（能打中文）；
    // 其余情况 → 摘掉 IME（播放页按 X/Z/S/空格 不会弹候选框）。
    FocusManager.instance.addListener(_syncIme);
    // 启动时先摘掉：应用一打开焦点通常不在任何输入框上。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncIme());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从其它程序切回来时，系统可能把 IME 上下文重新挂回窗口，
    // 状态位没变不会触发 _syncIme，所以强制重新下发一次。
    if (state == AppLifecycleState.resumed) {
      _syncIme();
      ImeGuard.resync();
    }
  }

  void _syncIme() {
    if (focusIsInEditableText()) {
      ImeGuard.allow();
    } else {
      ImeGuard.suppress();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_syncIme);
    // 进程退出前把输入法上下文还回去，避免影响同窗口的其他程序。
    ImeGuard.allow();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '抖音桌面版',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(desktopFlavor),
      // 风控验证横幅叠在最上层：任何页面命中风控都能看到进度与取消入口。
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const VerifyBanner(),
        ],
      ),
      home: const HomeShell(),
    );
  }
}
