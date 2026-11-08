# Cerberus / 抖音 Flutter 桌面端 — 项目约定

## 构建与交付（重要，每次改动必须执行）

- 构建命令：`flutter build windows --release`（Flutter 3.47.9 / Dart 3.13.7，MSVC 14.44，Windows SDK 10.0.22621.0）。
- 构建产物目录：`build\windows\x64\runner\Release`（24 文件 / 约 77 MB）。
- **每次改动编译完成后，必须同步一份到桌面供用户实机测试**：
  - 目标目录：`C:\Users\Administrator\Desktop\抖音客户端\Flutter版\`
  - 一键同步：`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy_to_desktop.ps1`
  - 脚本使用 robocopy /MIR 镜像同步，退出码 < 8 视为成功。
- Flutter 的 exe 不能单独运行，必须连同同目录 `*.dll` 与 `data\`（app.so / flutter_assets / icudtl.dat）一起复制，因此交付的是整个文件夹而非单个 exe。
- 桌面平行目录参考：`桌面\抖音客户端\DouyinDesktop-Python.exe`（Python 版单文件）、`桌面\抖音客户端\Rust版\`（Rust 版全套 dll + douyin_rust.exe）。

## 构建环境坑位（已解决，注意别回退）

- `pubspec.lock` 要求 Flutter >= 3.47.0；国内镜像用 `storage.flutter-io.cn`。
- Flutter SDK 在 `C:\Users\Administrator\dev\flutter`（不在 PATH，用绝对路径调 `bin\flutter.bat`）。
- 境外访问/下载统一走本地代理 `127.0.0.1:10999`（mixed）。代理变量只保留一套，`http_proxy` 与 `HTTP_PROXY` 重复会让 VS 安装器 .NET 字典异常退出 138。
- **产物曾经跑到 `C:\Program Files\douyin_desktop`**：根因是 `build/windows/x64/CMakeCache.txt` 里
  `CMAKE_INSTALL_PREFIX` 被缓存成 Program Files。已改回 `build/windows/x64/runner/Release`；
  `scripts/deploy_to_desktop.ps1` 仍保留兜底：Program Files 里 app.so 更新时先拷回 build。
- `native_toolchain_c` 的 `env_from_bat.dart` 已打补丁（vcvars64 查询注册表被安全策略拦截）；改动后需清除 `hook.dill` 缓存。
- 检查构建结果时，PowerShell 管道会掩盖失败：命令后紧跟读取 `$LASTEXITCODE` 并 grep 日志。

## 设置与缓存（2026-11-08 新增）

- `AppSettings`（`lib/core/app_settings.dart`）是唯一配置源，播放页监听同一单例，改设置即时生效。
  键：`douyin_decode_mode`(auto/software)、`douyin_cache_mode`(memory/disk/off)、
  `douyin_mem_cache_mb`(默认 1024)、`douyin_quality_pref`。
- 默认缓存 = **内存**（不写硬盘）。`MemoryVideoCache` 在 127.0.0.1 随机端口起只读 HTTP，
  按 Range 提供内存字节，mpv 因此可 seek；超 1GB 先淘汰 played=true 的条目再按 LRU，
  正在播放的 pinned 永不淘汰；淘汰后调 `MemoryTrim`（EmptyWorkingSet / malloc_trim）真正还内存。
- 在线抖音地址必须 `stream-lavf-o=seekable=0`（带 Range 会 404），内存回环地址必须 `seekable=1`，
  所以每次 open 前按来源切一次。
- 硬解失败自动降级见 `_handleHardwareErrorEvent` / `_fallbackToSoftware`：
  本机 mpv 会报 AVHWDeviceContext / dxva2_vld 失败后**自行**软解，
  这类错误不能再弹红色浮层，只能固化 `hwdec=no` 并提示一次。

## 自测钩子（离屏、静音、不抢焦点）

`DOUYIN_MUTE=1` · `DOUYIN_AUTOPLAY=1` · `DOUYIN_SWITCH_EVERY=n` · `DOUYIN_SHOT=<png>` + `DOUYIN_SHOT_DELAY`
· `DOUYIN_LOG=<path>` · `DOUYIN_OPEN_SETTINGS=1` · `DOUYIN_CACHE_MODE=disk|off` · `DOUYIN_MEM_CACHE_MB=n`
· `DOUYIN_SHOW_DEBUG=1`。
纯 Dart 自测：`dart run tool/mem_cache_check.dart`（回环 HTTP/Range/淘汰，19 项）。


## 功能与交互约定

- 用户要求：**所有软件提示与错误信息一律中文**，统一走 `lib/core/error_text.dart` 的 `ErrorText.from/translate`。
- 解码策略：硬件解码可用时必须硬解（`hwdec=auto-safe`，macOS `videotoolbox`）；不可用时自动回落软解并中文提示；调试浮层三态显示「硬件加速中 / 软件解码（硬件不可用）/ 软件解码（手动关闭）」。每次打开视频前重新下发 `hwdec`。
- 快捷键：评论 `X`、点赞 `Z`、收藏 `S`、帮助 `F1` 或 `Shift+?`。逻辑键与物理键双匹配；中文输入法组字/输入框聚焦时必须让位，不得吞字。
- 输入法：`windows/runner/flutter_window.cpp` 递归摘除并保存子 HWND 的 IME 上下文，子类化 Flutter view，IME 关闭时吞 `WM_IME_*`；`VK_PROCESSKEY` 用扫描码还原真实按键。
- 评论区「TA 的作品」进入即拉取作者作品（3 列网格、分页、加载/失败/重试/空态）；「播放 TA 的全部作品」作为独立队列播放。避免 `GlobalKey` 与 `ValueKey(item.id)` 冲突，使用 `CommentPanelController`。

## 测试约束（来自 HANDOVER.md）

- 未经用户明确同意，不要启动 GUI 实机跑视频：离屏、静音、不抢焦点。
- 快捷键手感、第三方输入法行为、真实硬解回落需用户实机验证。
