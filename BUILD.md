# 构建指南（Windows / Linux / macOS）

本工程的平台差异已全部收敛到 `lib/core/platform_adapter.dart`，业务代码里不再有
`Platform.isWindows` / `Platform.isMacOS` 之类的分支。三端共用同一份 Dart 代码，
差异只体现在 libmpv 动态库、硬解名、浏览器 UA / 指纹、等宽字体与窗口参数。

> 验证状态：Windows 端已实际构建并离屏冒烟通过；Linux / macOS 为代码层面补齐，
> **未在本机跑通**（本机只有 Windows 工具链）。

---

## 0. 通用前置

| 项 | 要求 |
| --- | --- |
| Flutter SDK | 3.13.7+（`environment: sdk: ^3.13.7`） |
| 平台目录 | `windows/`、`linux/`、`macos/` 均已生成，**不需要**再 `flutter create` |
| 第一次拉依赖 | `flutter pub get` |
| 静态检查 | `flutter analyze`（当前为 0 error） |

开启桌面端（只需一次，配置写入 Flutter 全局配置）：

```bash
flutter config --enable-windows-desktop --enable-linux-desktop --enable-macos-desktop
```

`flutter` 不在 PATH 时，Windows 本机用绝对路径 `C:\flutter\bin\flutter.bat`。

---

## 1. Windows

### 依赖

- Visual Studio 2022 Build Tools，勾选 **Desktop development with C++**
  （MSVC v143 + Windows 10/11 SDK；CMake 与 Ninja 随工作负载安装）
- 不需要手动安装 mpv / ffmpeg

### libmpv 从哪来

`media_kit_libs_windows_video` 在 CMake 配置阶段从 GitHub 下载
`mpv-dev-x86_64-20230924-git-652a1dd.7z`，解压后把 `libmpv-2.dll` 以及 ANGLE 相关
dll（`libEGL.dll`、`libGLESv2.dll`、`d3dcompiler_47.dll` 等）自动拷到 exe 同目录。

- **首次构建需要联网**；下载缓存在 `build\windows\x64\`（`mpv-dev-*.7z`、`libmpv\`）。
- 离线或下载失败时，把 `libmpv-2.dll` 手动放到产物目录
  `build\windows\x64\runner\Release\` 即可。
- 想用别处的 dll：`set DOUYIN_LIBMPV=D:\path\libmpv-2.dll`（或 media_kit 约定的
  `LIBMPV_LIBRARY_PATH`），程序会优先加载它。

### 构建

```powershell
C:\flutter\bin\flutter.bat build windows --release
```

产物：

```
build\windows\x64\runner\Release\douyin_desktop.exe
```

### 硬解

`PlatformAdapter.preferredHwdec` 在 Windows 返回 `auto-safe`（依次尝试
d3d11va → nvdec → d3d11va-copy，最终至少落在 GPU 解码上）。不写死 `d3d11va`
是因为零拷贝 d3d11va 在部分驱动 / 多显卡（含虚拟显示器）环境下会建不起
D3D11 设备，随后静默回落软解。
对比软解可加环境变量 `DOUYIN_HWDEC=no`，播放页调试层会显示
`hwdec-current` 的实际值。

---

## 2. Linux

### 系统依赖（按发行版）

Ubuntu / Debian（含麒麟、统信等衍生版）：

```bash
sudo apt update
sudo apt install -y libmpv-dev mpv clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
```

Fedora：

```bash
sudo dnf install -y mpv-libs-devel clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel
```

Arch：

```bash
sudo pacman -S --needed mpv clang cmake ninja pkgconf gtk3 xz
```

openSUSE：

```bash
sudo zypper install mpv-devel clang cmake ninja pkg-config gtk3-devel xz-devel
```

说明：
- `libmpv-dev` 提供 `libmpv.so` 软链与头文件，运行时库通常由 `libmpv2` 提供。
- `media_kit_libs_linux` 构建时会下载 mimalloc 源码并在本地编译，需要 `make` 与 C 编译器
  （上面的 `clang` 包已包含工具链）。

### 构建

```bash
flutter config --enable-linux-desktop
flutter build linux --release
```

产物：

```
build/linux/x64/release/bundle/douyin_desktop
```

运行时要保持 `bundle/` 与 `bundle/lib/` 的相对结构（CMake 已设置
`INSTALL_RPATH=$ORIGIN/lib`）。

### libmpv 放置方式（三选一）

1. **推荐**：系统包安装（`libmpv2` / `mpv`），loader 直接找到 `libmpv.so.2`；
2. 便携式：把 `libmpv.so.2` 放进 `bundle/lib/`，或设置 `LD_LIBRARY_PATH`；
3. 指定绝对路径：`DOUYIN_LIBMPV=/usr/lib/x86_64-linux-gnu/libmpv.so.2`。

程序启动时按 `libmpv.so.2 → libmpv.so.1 → libmpv.so` 顺序探测；全部失败会在
stderr 打印候选名与安装命令（见 `PlatformAdapter.libmpvFailureHint`）。

### 硬解（重要）

Linux 分支返回 `auto-safe`，**不保证一定硬解**。要确认条件：

```bash
ls /dev/dri                 # 需要存在 render 节点，例如 renderD128
vainfo                      # 需要列出 H.264/HEVC 的解码 profile
```

两条都满足、且确实想强制 VA-API 时，把
`lib/core/platform_adapter.dart` 里 Linux 分支的 `'auto-safe'` 改成 `'vaapi'`
后重新构建；条件不满足时强制会导致解码失败（黑屏 / mpv 报错）。

Wayland 环境下若窗口异常，可临时用 X11 后端启动：`GDK_BACKEND=x11 ./douyin_desktop`。

---

## 3. macOS

### 依赖

- Xcode 15+（含 Command Line Tools）：`sudo xcodebuild -license accept`
- CocoaPods：`brew install cocoapods`（或 `sudo gem install cocoapods`）
- Homebrew（可选）：`brew install mpv` 只用于命令行验证，**打包不依赖它**

### libmpv 从哪来

默认由 `media_kit_libs_macos_video` 的 podspec 把 `Mpv.xcframework` 的产物打进
`Runner.app/Contents/Frameworks/`，无需手动安装。程序按
`Mpv.framework/Mpv → libmpv.dylib` 顺序探测。

如果改用独立的 `libmpv.dylib`：

```bash
cp libmpv.dylib build/macos/Build/Products/Release/douyin_desktop.app/Contents/Frameworks/
install_name_tool -id @rpath/libmpv.dylib \
  build/macos/Build/Products/Release/douyin_desktop.app/Contents/Frameworks/libmpv.dylib
lipo -info libmpv.dylib        # Apple Silicon 需要含 arm64
codesign --force --sign "Developer ID Application: <你的证书>" \
  build/macos/Build/Products/Release/douyin_desktop.app/Contents/Frameworks/libmpv.dylib
```

### 构建

```bash
flutter config --enable-macos-desktop
flutter build macos --release
```

产物：

```
build/macos/Build/Products/Release/douyin_desktop.app
```

### 签名

- 本地自用：Xcode → Runner target → Signing & Capabilities 选 *Sign to Run Locally*，
  或直接 `codesign --force --deep --sign - <app>`（ad-hoc 签名）。
- 对外分发：Developer ID Application 证书，必须开启 Hardened Runtime：

```bash
codesign --force --deep --options runtime \
  --entitlements macos/Runner/Release.entitlements \
  --sign "Developer ID Application: <你的证书>" \
  build/macos/Build/Products/Release/douyin_desktop.app

xcrun notarytool submit douyin_desktop.app --wait
xcrun stapler staple douyin_desktop.app
```

### entitlements（已写入 `macos/Runner/`）

| 键 | 位置 | 原因 |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | Debug + Release | Flutter 模板默认，保持开启 |
| `com.apple.security.network.client` | Debug + Release | **必需**：拉抖音接口与视频流都是出站请求；没有它沙盒内的 .app 直接不能联网 |
| `com.apple.security.cs.allow-jit` | Debug | Flutter 调试引擎需要 |
| `com.apple.security.network.server` | Debug | 调试服务（hot reload）需要 |
| `com.apple.security.cs.disable-library-validation` | **仅 Release** | 允许加载不是本应用签名的 `Mpv.framework` / `libmpv.dylib` |

`disable-library-validation` 的安全含义：它关闭 dyld 对第三方动态库的签名一致性校验，
让应用能加载不同开发者签名的库。代价是：如果 `.app/Contents/Frameworks` 或 dylib 所在
目录可被低权限写入，攻击者可以替换同名 dylib 实现代码注入。因此：
- 该开关只放在 Release entitlements，没有加进 Debug；
- dylib 固定放在应用包内的 `Contents/Frameworks`，不要放到用户可写目录；
- 分发时对库先单独签名、再对 .app 整体签名（上面的命令顺序）。

检查签名里的 entitlements 是否生效：

```bash
codesign -d --entitlements :- build/macos/Build/Products/Release/douyin_desktop.app
```

---

## 4. 平台差异速查（只改 `lib/core/platform_adapter.dart`）

| 成员 | Windows | Linux | macOS |
| --- | --- | --- | --- |
| `libmpvCandidateNames` | `libmpv-2.dll` / `mpv-2.dll` / `mpv-1.dll` | `libmpv.so.2` / `.so.1` / `.so` | `Mpv.framework/Mpv` / `libmpv.dylib` |
| `libmpvOverride` | `DOUYIN_LIBMPV` → `LIBMPV_LIBRARY_PATH` → null | 同左 | 同左 |
| `userAgent` | Windows NT 10.0 | X11; Linux x86_64 | Macintosh Intel Mac OS X 10_15_7 |
| `webFingerprint` | 2560×1440 / Windows / Win32 | 1920×1080 / Linux / `Linux x86_64` | 1920×1080 / Mac / MacIntel |
| `preferredHwdec` | `auto-safe` | `auto-safe` | `videotoolbox` |
| `mustDisableMpvDiskCache` | false | false | **true**（沙盒内 disk cache 不可写） |
| `openUrlCommand` | `cmd /c start` | `xdg-open` | `open` |
| `appDataDir` | `%APPDATA%\douyin_desktop` | `$XDG_CONFIG_HOME/douyin_desktop` | `~/Library/Application Support/douyin_desktop` |
| `videoCacheDir` | `%LOCALAPPDATA%\DouyinDesktopFlutter\video_cache` | `$XDG_CACHE_HOME/DouyinDesktopFlutter/video_cache` | `~/Library/Caches/DouyinDesktopFlutter/video_cache` |
| `monospaceFontFamily` | Consolas | DejaVu Sans Mono | Menlo |
| 窗口默认 / 最小 | 1280×800 / 1020×640 | 同左 | 同左 |

字体方面，UI 字体由 `lib/core/app_theme.dart` 的 `AppTheme.build(flavor)` 负责：
`Segoe UI` / `Noto Sans CJK SC` / `PingFang SC`，含跨平台 fallback。

---

## 5. 运行时环境变量（与平台相关的前三个）

| 变量 | 作用 |
| --- | --- |
| `DOUYIN_LIBMPV` / `LIBMPV_LIBRARY_PATH` | 指定 libmpv 绝对路径，覆盖候选名探测 |
| `DOUYIN_HWDEC=no` | 强制软解，用于对比硬解 |
| `DOUYIN_COOKIES` | Cookie 文件绝对路径（默认找 exe 同目录的 `douyin_cookies.json`） |
| `DOUYIN_LOG` | diag 日志路径 |
| `DOUYIN_API_BASE` | 覆盖接口域名（异常路径自测） |
| `DOUYIN_SHOT` / `DOUYIN_SHOT_DELAY` | 离屏自截图（窗口移到 -3000,-3000，不弹窗） |

完整列表见 `README.md` 第 5 节。

---

## 6. 排障

| 现象 | 处理 |
| --- | --- |
| 启动即退出、stderr 打印「libmpv 加载失败」 | 按提示放置 dll / 安装 libmpv，或设 `DOUYIN_LIBMPV` |
| Linux `pkg-config: gtk+-3.0 not found` | 装 `libgtk-3-dev` / `gtk3-devel` / `gtk3` |
| Linux 黑屏但有声音 | 检查 `/dev/dri` 与 `vainfo`，或先 `DOUYIN_HWDEC=no` 验证软解 |
| macOS 打开后一直转圈、接口全失败 | `codesign -d --entitlements :-` 确认 `network.client` 在签名里 |
| macOS 报 `code signature invalid`（加载 dylib） | Release 签名是否带 `disable-library-validation`，dylib 是否已单独签名 |
| Windows 首次构建卡在 Downloading | 需要联网；或按第 1 节手动放 `libmpv-2.dll` |
