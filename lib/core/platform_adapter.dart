import 'dart:io' show Directory, File, Platform;

import 'platform_style.dart';

/// 桌面三端的平台差异**唯一**收敛点。
///
/// 规则：任何"按操作系统取值"的东西都写在这里，业务代码只引用本类，
/// 不允许在页面 / 接口 / 播放器里再出现 `Platform.isWindows` 这类判断。
/// 目前覆盖 Windows / Linux / macOS，移动端不在现阶段范围。
class PlatformAdapter {
  const PlatformAdapter._();

  // ---------------------------------------------------------------- libmpv

  /// libmpv 动态库的候选名，顺序与 media_kit 内部的探测逻辑一致。
  ///
  /// - Windows：`media_kit_libs_windows_video` 构建时会把 `libmpv-2.dll`
  ///   自动下载并拷到 exe 同目录；
  /// - Linux：需系统安装，或把 `libmpv.so.2` 放进 `LD_LIBRARY_PATH`；
  /// - macOS：`media_kit_libs_macos_video` 会把 `Mpv.framework` 打进
  ///   `Runner.app/Contents/Frameworks`，命中 `Mpv.framework/Mpv`；
  ///   若换成独立 `libmpv.dylib`，放到同一 Frameworks 目录即可。
  static List<String> get libmpvCandidateNames => switch (desktopFlavor) {
        DesktopFlavor.windows => const ['libmpv-2.dll', 'mpv-2.dll', 'mpv-1.dll'],
        DesktopFlavor.macOS => const ['Mpv.framework/Mpv', 'libmpv.dylib'],
        DesktopFlavor.linux => const ['libmpv.so.2', 'libmpv.so.1', 'libmpv.so'],
      };

  /// 显式指定的 libmpv 路径；为 null 时交给 media_kit 按候选名逐个探测。
  ///
  /// 优先级：`DOUYIN_LIBMPV`（本项目约定） → `LIBMPV_LIBRARY_PATH`（media_kit 约定）。
  /// 默认返回 null 比写死路径安全：写死的路径不存在会直接抛，逐个探测还能兜底。
  static String? get libmpvOverride {
    for (final key in const ['DOUYIN_LIBMPV', 'LIBMPV_LIBRARY_PATH']) {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// libmpv 加载失败时的中文提示（含三端放置方式），用于启动期兜底。
  static String libmpvFailureHint(Object error) {
    final candidates = libmpvCandidateNames.join(' / ');
    final placement = switch (desktopFlavor) {
      DesktopFlavor.windows =>
        '把 libmpv-2.dll 放到 douyin_desktop.exe 同目录，'
            '或设置 DOUYIN_LIBMPV=<dll 绝对路径>。',
      DesktopFlavor.macOS =>
        '确认 Runner.app/Contents/Frameworks 下有 Mpv.framework（或 libmpv.dylib），'
            '或设置 DOUYIN_LIBMPV=<动态库绝对路径>。',
      DesktopFlavor.linux =>
        '按发行版安装（Ubuntu/Debian: sudo apt install libmpv-dev mpv；'
            'Fedora: sudo dnf install mpv-libs-devel；Arch: sudo pacman -S mpv），'
            '或设置 DOUYIN_LIBMPV=/usr/lib/x86_64-linux-gnu/libmpv.so.2。',
    };
    return 'libmpv 加载失败：$error\n'
        '候选名：$candidates\n'
        '处理方式：$placement';
  }

  // ------------------------------------------------------- 浏览器身份 / UA

  /// 请求抖音 Web 接口时声明的浏览器 UA，每端与自身系统匹配。
  static String get userAgent => switch (desktopFlavor) {
        DesktopFlavor.windows =>
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36',
        DesktopFlavor.macOS =>
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36',
        DesktopFlavor.linux =>
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36',
      };

  /// Web 接口里的浏览器环境字段。
  ///
  /// 这些值只用于让浏览器指纹自洽，不读取本机真实硬件：
  /// screen_* 与 os_version 都是固定常量，和 UA 声明保持一致。
  static Map<String, String> get webFingerprint => switch (desktopFlavor) {
        DesktopFlavor.windows => const {
            'screen_width': '2560',
            'screen_height': '1440',
            'pc_libra_divert': 'Windows',
            'browser_platform': 'Win32',
            'os_name': 'Windows',
            'os_version': '10',
          },
        DesktopFlavor.macOS => const {
            'screen_width': '1920',
            'screen_height': '1080',
            'pc_libra_divert': 'Mac',
            'browser_platform': 'MacIntel',
            'os_name': 'Mac OS',
            'os_version': '10.15.7',
          },
        DesktopFlavor.linux => const {
            'screen_width': '1920',
            'screen_height': '1080',
            'pc_libra_divert': 'Linux',
            'browser_platform': 'Linux x86_64',
            'os_name': 'Linux',
            'os_version': '6.5',
          },
      };

  // -------------------------------------------------------------- 视频解码

  /// mpv 的 `hwdec` 取值。
  ///
  /// - Windows：`auto-safe`。不要写死 `d3d11va`：零拷贝 d3d11va 需要创建带
  ///   VIDEO_SUPPORT 的 D3D11 设备，在部分驱动 / 多显卡（含虚拟显示器）环境下
  ///   会直接失败（mpv 日志 `Looking at hwdec h264-d3d11va... Could not create
  ///   device.`），随后 mpv 静默回落软解，表现为 `hwdec-current=no`。
  ///   `auto-safe` 会依次尝试 d3d11va → nvdec → **d3d11va-copy**，实测本机
  ///   最终落在 `d3d11va-copy`（仍是 GPU 解码，只是回拷帧）。
  /// - macOS：`videotoolbox`（VideoToolbox）；
  /// - Linux：`auto-safe`。**Linux 不保证硬解**，只有同时满足：
  ///   ① `ls /dev/dri` 能看到 render 节点（如 `renderD128`）；
  ///   ② 驱动与 libva 支持对应编码（`vainfo` 能列出 H.264/HEVC 解码 profile）；
  ///   才会启用 vaapi，否则 mpv 自动回落软解。确认满足后想强制 vaapi，
  ///   可把这里改成 `'vaapi'`；条件不满足时强制会导致解码失败（黑屏 / 报错）。
  static String get preferredHwdec => switch (desktopFlavor) {
        DesktopFlavor.windows => 'auto-safe',
        DesktopFlavor.macOS => 'videotoolbox',
        DesktopFlavor.linux => 'auto-safe',
      };

  /// `hwdec-current` 的取值是否代表"真的在用 GPU 解码"。
  ///
  /// mpv 在硬解建不起来时会静默回落，`hwdec-current` 变成 `no`；
  /// 反过来 `d3d11va-copy`、`nvdec-copy` 这类"回拷帧"的实现仍然是硬件解码，
  /// 不能因为带 `-copy` 就当成软解。只有 `no` / 空 / `failed` 才是软解。
  static bool isHardwareDecoder(String name) {
    final v = name.trim().toLowerCase();
    if (v.isEmpty || v == 'no' || v == 'failed' || v == '—') return false;
    const markers = [
      'd3d11',
      'dxva',
      'nvdec',
      'cuda',
      'videotoolbox',
      'vaapi',
      'vdpau',
      'mediacodec',
      'amf',
      'qsv',
      'vulkan',
    ];
    return markers.any(v.contains);
  }

  /// 把 `hwdec-current` 翻成用户能看懂的中文。
  static String describeDecoder(String name) {
    final v = name.trim();
    if (v.isEmpty || v == '—') return '未知';
    if (v.toLowerCase() == 'no') return '软件解码';
    return isHardwareDecoder(v) ? '硬件解码（$v）' : '软件解码（$v）';
  }

  // ------------------------------------------------------------------ 字体

  /// 调试面板用的等宽字体，三端都用系统自带字体，不引入字体文件。
  static String get monospaceFontFamily => switch (desktopFlavor) {
        DesktopFlavor.windows => 'Consolas',
        DesktopFlavor.macOS => 'Menlo',
        DesktopFlavor.linux => 'DejaVu Sans Mono',
      };

  // --------------------------------------------------------- 浏览器（CDP）

  /// 可用的 Chromium 内核浏览器候选路径（按平台，Windows/macOS/Linux）。
  ///
  /// 扫码登录与"风控验证"都复用它：不写死任何一端路径，也不在业务文件里
  /// 出现 `Platform.isWindows` 判断。
  static List<String> get chromiumCandidates {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final roots = <String?>[
        env['ProgramFiles'],
        env['ProgramFiles(x86)'],
        env['LOCALAPPDATA'],
      ].whereType<String>();
      return [
        for (final root in roots) ...[
          '$root\\Microsoft\\Edge\\Application\\msedge.exe',
          '$root\\Google\\Chrome\\Application\\chrome.exe',
        ],
      ];
    }
    if (Platform.isMacOS) {
      return const [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
      ];
    }
    return const [
      '/usr/bin/google-chrome',
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
      '/usr/bin/microsoft-edge',
    ];
  }

  /// 第一个真实存在的浏览器可执行文件；都没找到返回 null。
  static String? findChromiumBrowser() {
    for (final path in chromiumCandidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 扫码登录与风控验证**共用**的持久浏览器 profile 目录。
  ///
  /// 2026-11-07 修复：这里必须固定且跨次复用——
  /// 原来每次都用 `Directory.systemTemp.createTemp('douyin_login_')`，
  /// 关闭时还把目录删掉，于是"每次点浏览器登录都是全新空窗口、必须重扫"，
  /// 且验证流程与登录流程各自一套空 profile。现在三端固定位置，不清空。
  static String get browserProfileDir {
    final override = Platform.environment['DOUYIN_PROFILE_DIR'];
    if (override != null && override.isNotEmpty) return override;
    final env = Platform.environment;
    final sep = Platform.pathSeparator;
    if (Platform.isWindows) {
      final base = env['APPDATA'] ?? env['LOCALAPPDATA'] ?? env['USERPROFILE'] ?? '.';
      return '$base${sep}douyin_desktop${sep}browser_profile';
    }
    if (Platform.isMacOS) {
      final home = env['HOME'] ?? '';
      return '$home/Library/Application Support/douyin_desktop/browser_profile';
    }
    final xdg = env['XDG_CONFIG_HOME'];
    final home = env['HOME'] ?? '';
    final base = (xdg == null || xdg.isEmpty) ? '$home/.config' : xdg;
    return '$base${sep}douyin_desktop${sep}browser_profile';
  }

  static List<String> get monospaceFallback => const [
        'Consolas',
        'Menlo',
        'DejaVu Sans Mono',
        'Noto Sans Mono',
      ];

  // -------------------------------------------------------------- 目录布局

  /// 应用数据目录（放 Cookie、浏览器 profile 等需要持久化的文件）。
  ///
  /// 各平台遵循系统惯例：
  /// - Windows：`%APPDATA%\douyin_desktop`
  /// - macOS：`~/Library/Application Support/douyin_desktop`
  /// - Linux：`$XDG_CONFIG_HOME/douyin_desktop`（默认 `~/.config/...`）
  ///
  /// 返回 null 表示环境变量缺失，调用方应降级到临时目录。
  static String? get appDataDir {
    final env = Platform.environment;
    final sep = Platform.pathSeparator;
    if (Platform.isWindows) {
      final base = env['APPDATA'] ?? env['LOCALAPPDATA'] ?? env['USERPROFILE'];
      return (base == null || base.isEmpty)
          ? null
          : '$base${sep}douyin_desktop';
    }
    final home = env['HOME'];
    if (home == null || home.isEmpty) return null;
    if (Platform.isMacOS) {
      return '$home/Library/Application Support/douyin_desktop';
    }
    final xdg = env['XDG_CONFIG_HOME'];
    final base = (xdg == null || xdg.isEmpty) ? '$home/.config' : xdg;
    return '$base${sep}douyin_desktop';
  }

  /// 视频预缓存目录。
  ///
  /// 用「缓存」而非「配置」目录：这些 mp4 随时可以删，系统清理缓存时
  /// 丢掉也不会影响功能。Linux 上如果误用配置目录，会在 `~/.config` 下
  /// 堆几个 GB 的视频。
  ///
  /// - Windows：`%LOCALAPPDATA%\DouyinDesktopFlutter\video_cache`
  /// - macOS：`~/Library/Caches/DouyinDesktopFlutter/video_cache`
  /// - Linux：`$XDG_CACHE_HOME/DouyinDesktopFlutter/video_cache`
  ///   （默认 `~/.cache/...`）
  static String get videoCacheDir {
    final env = Platform.environment;
    final sep = Platform.pathSeparator;
    if (Platform.isWindows) {
      final local = env['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) {
        return '$local${sep}DouyinDesktopFlutter${sep}video_cache';
      }
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      if (Platform.isMacOS) {
        return '$home/Library/Caches/DouyinDesktopFlutter/video_cache';
      }
      final xdg = env['XDG_CACHE_HOME'];
      final base = (xdg == null || xdg.isEmpty) ? '$home/.cache' : xdg;
      return '$base${sep}DouyinDesktopFlutter${sep}video_cache';
    }
    return '${Directory.systemTemp.path}${sep}douyin_video_cache';
  }

  // ------------------------------------------------------------ 平台能力

  /// 是否需要关闭 mpv 的磁盘缓存。
  ///
  /// macOS 沙盒里 media_kit 默认的 `cache-on-disk` 路径不可写，mpv 会
  /// 每帧重试并刷错误日志；Linux / Windows 没有这个问题，保持开启。
  static bool get mustDisableMpvDiskCache => Platform.isMacOS;

  /// media_kit 的视频纹理是否走硬件加速路径（`TextureHW`）。
  ///
  /// **macOS 必须默认关闭。** `TextureHW` 会创建一个独立的
  /// `CGLContextObj` + `CVOpenGLTextureCache`，并在每帧渲染前后调用
  /// `CGLSetCurrentContext(context)` / `CGLSetCurrentContext(nil)`。
  /// Flutter 引擎自己的文字字形图集（glyph atlas）同样是 GL 纹理，
  /// 两者共享 GPU 状态时，在 Intel 核显（UHD 620 一类）上会互相污染：
  ///   - 视频画面周期性闪屏 / 错帧；
  ///   - 评论区、顶栏这些**与视频无关**的纯 Flutter 文字碎裂成散乱字形，
  ///     严重时整张文字图集被错误贴到视频区域，形成斜向碎片带。
  /// 上游 `TextureHW.deinit` 自己也注明销毁 CGL 上下文"可能造成
  /// RAM / VRAM 泄漏"，切换视频时反复创建销毁会进一步放大该问题。
  ///
  /// 关掉后走 `TextureSW`（mpv SW render API → CVPixelBuffer →
  /// 由 Flutter 引擎自己上传），全程不碰 GL 状态。
  /// **mpv 的 `hwdec=videotoolbox` 硬解仍然保留**：这里切换的是
  /// "解码后的帧怎么交给 Flutter"，不是"用不用 GPU 解码"。
  ///
  /// 需要对比验证时可用 `DOUYIN_RENDER_HW=1` 强制开回硬件纹理路径。
  static bool get defaultRenderHardwareAcceleration {
    if (Platform.isMacOS) {
      return Platform.environment['DOUYIN_RENDER_HW'] == '1';
    }
    return true;
  }

  /// 是否必须避免 `RenderRepaintBoundary.toImage()` 这类**整屏 GPU 回读**。
  ///
  /// macOS 上 `toImage()` 会把外部视频纹理（TextureHW 是 CVOpenGLTexture，
  /// 属于 mpv 自建的 CGL 上下文）连同全屏文字一起重绘进 Skia 的离屏
  /// 渲染目标，属于跨 GL 上下文采样，结果未定义；同时每次回读都会打断
  /// 渲染管线。播放页原来在首帧后的 2.5 秒内每 140ms 抓一次全屏
  /// （最多 18 次），切视频时还会再抓一次旧画面，正好落在闪屏的时间窗口。
  ///
  /// 关掉后首帧可见性改用固定延时放行（mpv 已在出帧，剩下的只是
  /// 纹理上传延迟），切换动画退化为「仅新画面滑入」。
  static bool get mustAvoidGpuReadback => Platform.isMacOS;

  /// 用系统默认程序打开 URL 的命令行（[exe] 与 [args]）。
  static (String, List<String>) openUrlCommand(String url) =>
      switch (desktopFlavor) {
        DesktopFlavor.windows => ('cmd', ['/c', 'start', '', url]),
        DesktopFlavor.macOS => ('open', [url]),
        DesktopFlavor.linux => ('xdg-open', [url]),
      };

  // ------------------------------------------------------------------ 窗口

  /// 这里只用 double 而不是 Flutter 的 Size：本文件要保持"纯 dart:io"，
  /// 才能被 `dart run` 的 tool 脚本（如 a_bogus 离线对拍）间接引用。
  static const String windowTitle = '抖音桌面版';
  static const double defaultWindowWidth = 1280;
  static const double defaultWindowHeight = 800;
  static const double minimumWindowWidth = 1020;
  static const double minimumWindowHeight = 640;
}
