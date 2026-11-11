import 'dart:ffi';
import 'dart:io';

/// 主动把进程工作集还给操作系统。
///
/// 为什么需要：Dart / Flutter 的内存回收是"先还给堆、再慢慢还给系统"，
/// 连续播放大量视频后，任务管理器里的占用往往还停在高位，用户会觉得
/// "明明已经不看这些视频了，怎么内存没降"。这里用系统级裁剪一次性压回去：
///  - Windows：`psapi!EmptyWorkingSet(GetCurrentProcess())`
///  - Linux：`libc!malloc_trim(0)`（glibc ≥ 2.8；musl 无此符号，自动跳过）
///  - macOS：`libsystem_malloc!malloc_zone_pressure_relief(NULL, 0)`
/// 三端都包在 try/catch 里：符号取不到就当没做，绝不影响播放。
class MemoryTrim {
  MemoryTrim._();

  static bool _resolved = false;
  static int Function()? _windowsTrim;
  static int Function(int)? _linuxTrim;
  static int Function(Pointer<Void>, int)? _macTrim;

  /// 裁剪工作集。`force=true` 时忽略 200ms 的节流。
  ///
  /// 节流的意义：短时间内反复裁剪会让系统反复缺页，反而拖慢解码，
  /// 所以默认 200ms 内只做一次。
  static void trim({bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastAt < 200) return;
    _lastAt = now;
    _ensureResolved();
    try {
      _windowsTrim?.call();
      _linuxTrim?.call(0);
      // 第一个参数传 NULL 表示"所有 zone"，第二个参数 0 表示"尽量全部回收"。
      _macTrim?.call(nullptr, 0);
    } catch (_) {
      // 忽略：裁剪失败不影响功能
    }
  }

  static int _lastAt = 0;
  static int _lastIdleAt = 0;

  /// 空闲期回收：距上次至少 [minGap] 才做一次。
  ///
  /// 与 [trim] 的区别在于触发时机——只在用户不在播放页、也没有输入交互
  /// 的"闲下来"时刻调用。播放中裁剪工作集会让 mpv 的帧缓冲重新缺页，
  /// 反而造成卡顿，所以播放期间一律不调用。
  static void trimWhenIdle({
    Duration minGap = const Duration(seconds: 20),
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastIdleAt < minGap.inMilliseconds) return;
    _lastIdleAt = now;
    trim(force: true);
  }

  static void _ensureResolved() {
    if (_resolved) return;
    _resolved = true;
    try {
      if (Platform.isWindows) {
        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final psapi = DynamicLibrary.open('psapi.dll');
        final getCurrentProcess = kernel32.lookupFunction<IntPtr Function(),
            int Function()>('GetCurrentProcess');
        final emptyWorkingSet = psapi.lookupFunction<Int32 Function(IntPtr),
            int Function(int)>('EmptyWorkingSet');
        _windowsTrim = () => emptyWorkingSet(getCurrentProcess());
      } else if (Platform.isLinux) {
        final libc = DynamicLibrary.process();
        final mallocTrim = libc.lookupFunction<Int32 Function(IntPtr),
            int Function(int)>('malloc_trim');
        _linuxTrim = (int pad) => mallocTrim(pad);
      } else if (Platform.isMacOS) {
        // 系统 malloc 的实现所在：/usr/lib/system/libsystem_malloc.dylib。
        // 用它提供的 malloc_zone_pressure_relief 让 malloc 把空闲页还给内核。
        final lib = DynamicLibrary.open(
            '/usr/lib/system/libsystem_malloc.dylib');
        // malloc_zone_pressure_relief(malloc_zone_t *zone, size_t goal)
        // 返回实际释放的字节数；两个参数在 64 位上都是 8 字节。
        final relief = lib.lookupFunction<Size Function(Pointer<Void>, Size),
            int Function(Pointer<Void>, int)>('malloc_zone_pressure_relief');
        _macTrim = (Pointer<Void> zone, int goal) => relief(zone, goal);
      }
    } catch (_) {
      // 动态库或符号不存在：保持 null，后续调用变成空操作
    }
  }
}
