/// 播放器后端选择（编译期常量，fvp 灰度迁移用）。
///
/// 构建时通过 `--dart-define=PLAYER_BACKEND=fvp` 切到 libmdk 灰度版；
/// 不传或传 `mpv` 时走原来的 libmpv 版（默认，行为完全不变）。
///
/// 为什么是编译期而非运行时开关：
///   - 需求是「两个版本」= 两个独立安装包，各自固定一套后端；
///   - 编译期常量让 Dart 编译器摇掉未选中分支对应的播放页代码，
///     灰度结果可直接对比，也不会出现两套播放器同时抢音频 / 纹理。
///
/// 注意：Flutter 插件注册由 pubspec 依赖决定，不受 Dart tree-shaking 影响，
/// 所以两个包仍会同时包含 Mpv.framework 与 mdk SDK（各约 +10MB）。
/// 灰度结束确定后端后，再把不需要的那套从 pubspec 移除即可。
enum PlayerBackendKind { mpv, fvp }

/// 来自 `--dart-define=PLAYER_BACKEND=...` 的原始值。
const String kPlayerBackendName =
    String.fromEnvironment('PLAYER_BACKEND', defaultValue: 'mpv');

PlayerBackendKind get playerBackendKind =>
    kPlayerBackendName.toLowerCase() == 'fvp'
        ? PlayerBackendKind.fvp
        : PlayerBackendKind.mpv;

bool get isFvpBackend => playerBackendKind == PlayerBackendKind.fvp;

/// 产物名 / 诊断日志里显示的后端名，便于一眼区分两个版本。
String get playerBackendLabel =>
    isFvpBackend ? 'fvp(libmdk)' : 'mpv(libmpv)';
