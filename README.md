# 抖音桌面版（Flutter / Windows · Linux · macOS）

纯 HTTP 实现的抖音桌面客户端：不内嵌 WebView，全部数据走抖音 Web 接口，
播放由 media_kit（libmpv）负责硬解。

---

## 1. 怎么运行

### 直接跑现成产物

```
douyin_desktop\build\windows\x64\runner\Release\douyin_desktop.exe
```

想带登录态：把浏览器导出的 Cookie 文件命名为 `douyin_cookies.json`，
放在 **exe 同目录**（或设置环境变量 `DOUYIN_COOKIES=<绝对路径>`）。
没有这个文件时程序用匿名态运行（推荐流可用，评论会返回空响应）。

### 从源码构建

```powershell
C:\flutter\bin\flutter.bat build windows --release
```

`flutter` 不在 PATH 上，所以用绝对路径调用。

Linux / macOS 的依赖安装、构建命令、libmpv 放置与签名要求见 [BUILD.md](./BUILD.md)。

---

## 2. 依赖

| 依赖 | 用途 |
| --- | --- |
| Flutter SDK（Windows 桌面） | UI |
| `media_kit` + `media_kit_video` | libmpv 播放与硬解 |
| `window_manager` | 窗口位置/全屏/离屏自测 |
| `cached_network_image` | 封面与头像缓存（含内存上限） |
| 内置 `lib/data/abogus.dart` | 纯 Dart 生成 `a_bogus` 签名，无 JS 引擎 |

Windows / macOS 不需要单独装：libmpv 由 `media_kit_libs_*` 在构建时自动下载 / 打包；
Linux 需要系统安装 libmpv（各发行版包名见 [BUILD.md](./BUILD.md)）。
所有平台差异（libmpv 候选名、硬解名、UA / 指纹、等宽字体、窗口参数）都收敛在
`lib/core/platform_adapter.dart`。

---

## 3. 已实现

### 推荐流
- 真实接口 `/aweme/v1/web/tab/feed/`，`a_bogus` 本地签名，实测 HTTP 200
- 滚动到底自动加载更多（去重、连续请求补齐）
- 首屏自动补齐到「可滚动」，避免只有 2 条时滑不动
- 顶部刷新按钮；下拉刷新 `RefreshIndicator`
- 封面/头像走 `CachedNetworkImage`，磁盘+内存缓存
- 加载中、空、失败三态；失败有「重试」入口

### 播放页（对齐网页版布局）
- 主区视频等比铺满，黑底留边，双击暂停
- 右侧竖排互动栏：头像（带 + 角标）→ 点赞 → 评论 → 收藏 → 分享 → 听抖音 → 更多，
  数字按 `10.9万 / 3.2万` 缩写
- 左下信息区：`@作者 · 相对时间`、标题两行 +「展开」、合集/音乐/播放量/识别画面小标签
- 底部控制条：时间 → 进度条（可拖动 seek，悬停显示时间气泡）→ 音量 → 弹幕 →
  评论输入框（`发一条友好的弹幕吧`）→ 发送 → 连播 → 清屏 → 清晰度 → 倍速 →
  播放/暂停 → 画中画 → 全屏 → 设置（窗口窄于 760 时自动收起连播/清屏，避免溢出）
- 鼠标静止 3 秒控制条淡出，移动即恢复
- 键盘：空格播放/暂停、←→ ±5 秒、↑↓ 音量、N/P 切换、F 全屏、
  Esc 依次关调试面板/评论抽屉/退出全屏/返回；滚轮上下切换
- 设置齿轮打开调试面板：`hwdec-current`、`video-codec`、分辨率、帧率、mpv 日志

### 评论抽屉
- 从右侧滑出，宽 440，视频区让位但继续播放
- 顶部 6 个 tab：详情 / TA的作品 / 评论 / 合集 / AI 抖音 / 相关推荐
  （详情、评论为真实数据；其余为占位，明确标注「未接入」）
- 全部评论(total) + 按热度入口
- 每条：头像、昵称、正文（可展开）、时间 · 地区、回复 · 分享 · 赞、展开 N 条回复
- 评论图片九宫格，点击全屏查看
- 底部输入框（视觉骨架，未接入写入接口）

### 异常处理
- 网络失败 / HTTP 非 200 / `status_code != 0` / 空响应 都会转成中文提示
- 评论空响应时明确指出「游客态风控 → 放 Cookie 文件后重启」
- 播放失败弹出可重试的浮层；`playUrl` 为空的图文作品给出说明
- 切视频前先 `player.stop()`，释放上一个媒体的解码器

---

## 4. 已知限制

1. **写操作全部未接入**：点赞、收藏、关注、发评论都需要登录态写入接口，
   本版只做只读展示，点击会提示「只做只读展示」。
2. **画中画**在 Flutter Windows 桌面没有可用实现，按钮保留，点击给出提示。
3. **弹幕**没有渲染管线（抖音弹幕走 WebSocket 私有协议），开关只记录状态并提示，不渲染弹幕。
4. **清晰度**没有切换入口：接口返回的 `bit_rate` 多码率地址里，
   只有 `www.douyin.com/aweme/v1/play/` 这条在游客态可用，
   `*-prime.douyinvod.com` 一律 403。所以清晰度标签是按作品原始分辨率推导的展示值。
5. **TA的作品 / 合集 / AI 抖音 / 相关推荐** 只有骨架。
6. **图文作品**只显示封面，没有做图集轮播。
7. **评论区子回复**只显示「展开 N 条回复」文案，没有接 `comment/list/reply`。
8. **推荐流单次只返回 2 条**（登录态与游客态都一样），所以「加载更多」是
   连续多次请求拼出来的，滚动 200 条意味着约 100 次请求。
9. **离屏自测的帧率数据不可信**：窗口移到屏幕外后 Flutter 会降频渲染，
   帧数统计不能代表前台表现（详见自测表说明）。
10. **连续切换视频的内存是「有上限驻留」，不是泄漏**：133 次切换实测 RSS 302 MB →
    568 MB，前 30 次约 3.3 MB/次，之后降到约 0.45 MB/次，50 次后稳定在 530–578 MB
    并出现回落，句柄数全程 801–809 不变。已排除「每次新建 mpv」「缓存无限保留」
    「纹理重建」「Player 对象泄漏」四种可能（含整只 Player 重建的对照实验），
    属于 libmpv/FFmpeg 原生分配器的常驻内存，详见 `SELFTEST.md` 4.1。

---

## 5. 自测结果

所有测试都在屏幕外完成（窗口 `-3000,-3000`，不激活、不进任务栏），
没有弹出可见窗口。详见 [SELFTEST.md](./SELFTEST.md)。

复现用的环境变量（仅测试用，不设就不生效）：`DOUYIN_LOG`、`DOUYIN_SHOT`、
`DOUYIN_SHOT_DELAY`、`DOUYIN_AUTOPLAY`、`DOUYIN_SWITCH_EVERY`、`DOUYIN_FORCE_CONTROLS`、
`DOUYIN_OPEN_COMMENTS`、`DOUYIN_TOGGLE_DRAWER`、`DOUYIN_MEMLOG`、`DOUYIN_COOKIES`、
`DOUYIN_API_BASE`、`DOUYIN_NO_AUTONEXT`、`DOUYIN_HWDEC=no`（软解对照）、
`DOUYIN_RECYCLE_EVERY`（每 N 次切换重建播放器，默认 0 关闭）、`DOUYIN_AUTOSCROLL`、
`DOUYIN_SCROLL_MS`。

---

## 6. 目录一览

```
lib/
  data/         douyin_api.dart（会话/签名/接口）、abogus.dart（纯算法签名）、models.dart
  features/
    shell/      推荐流列表
    feed/       作品卡片
    player/     播放页 + 解码探针
    comments/   评论抽屉 + 图片查看
  core/         diag（日志）、platform_style（格式化）、platform_adapter（三端差异）
tool/           自测探针与离屏运行脚本（不参与打包）
```

---

## 7. 安全说明

- `douyin_cookies.json` 已在 `.gitignore` 里，不要提交。
- 日志只打印 Cookie 的**字段名和长度**，从不打印值。
- 二维码登录（扫码）本期未做，直接读本地导出的 Cookie 文件。

---

## 8. 变更记录

- 2026-11-09 性能优化（GPU / 内存，三端通用）：
  - **播放页重建粒度**：播放位置/时长/播放状态原先每 150ms 触发一次整页
    `setState`，视频纹理层、封面、信息区、右侧互动栏全部跟着重建。现在这些
    高频量只驱动底部控制条那一个子树（`ListenableBuilder` + `_uiTick`），
    外层 build 在播放期间不再重跑；控制条淡出后连这个局部刷新也跳过，
    播放稳定期 Flutter 侧完全不提交 UI 绘制，GPU 只做视频纹理合成。
  - **GPU 回读**：`_awaitFirstFrameThenUnmute` 的亮度探测从每 70ms 一次
    改为 140ms，采样比例 0.08 → 0.06，并加"连续两帧纯黑即停止"的短路；
    切歌快照 `toImage` 的 pixelRatio 0.7 → 0.5；`sampleScreenBrightness`
    的逐像素循环改为 3 像素步长跳采。三者都是 GPU→CPU 整块回读，在核显上
    单次就要数毫秒并打断渲染管线。
  - **封面模糊占位**：`_CoverBlur` 外套 `RepaintBoundary`（模糊结果缓存成
    一层位图，不再每帧重算），sigma 16 → 8。
  - **设置页**：运行状态卡片改为局部刷新，整页不再每秒重建。
  - **内存回收**：`MemoryTrim` 补齐 macOS（`malloc_zone_pressure_relief`），
    三端齐全；退出播放页后自动裁剪一次，首页滚动停止后按 20 秒节流回收。
  - **目录布局跨平台**：视频缓存改由 `PlatformAdapter.videoCacheDir` 决定，
    Linux 落在 `$XDG_CACHE_HOME`、macOS 落在 `~/Library/Caches`（原来
    Linux 会误落到 `~/.config` 下堆视频文件）；应用数据目录同样收敛到
    `PlatformAdapter.appDataDir`。
  - **平台分支收敛**：播放页里残留的 `Platform.isMacOS` / `Platform.isWindows`
    判断改为 `PlatformAdapter.mustDisableMpvDiskCache` / `openUrlCommand`，
    业务代码不再直接判断操作系统。
- 2026-11-07 跨平台改造：新增 `lib/core/platform_adapter.dart` 收敛三端差异，补齐
  Linux 分支与 macOS 联网 entitlements，编写 `BUILD.md`；删除已无引用的 WebView
  遗留代码 `lib/data/web_engine.dart`、`lib/data/feed_controller.dart`、
  `lib/features/feed/feed_page.dart`，并从 `pubspec.yaml` 移除 Linux 无实现的
  `flutter_inappwebview` 依赖（确认过：无 lib 引用、`test/` 为空、`tool/` 脚本未引用）。
