import 'dart:ffi';
import 'dart:io';

/// 主动把进程工作集还给操作系统。
///
/// 为什么需要：Dart / Flutter 的内存回收是"先还给堆、再慢慢还给系统"，
/// 连续播放大量视频后，任务管理器里的占用往往还停在高位，用户会觉得
/// "明明已经不看这些视频了，怎么内存没降"。这里用系统级裁剪一次性压回去：
///  - Windows：`psapi!EmptyWorkingSet(GetCurrentProcess())`
///  - Linux：`libc!malloc_trim(0)`
///  - macOS：无等价安全接口，直接跳过
/// 全部包在 try/catch 里：调用不到就当作没做，绝不影响播放。
class MemoryTrim {
  MemoryTrim._();

  static bool _resolved = false;
  static int Function()? _windowsTrim;
  static int Function(int)? _linuxTrim;

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
    } catch (_) {
      // 忽略：裁剪失败不影响功能
    }
  }

  static int _lastAt = 0;

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
      }
    } catch (_) {
      // 动态库或符号不存在：保持 null，后续调用变成空操作
    }
  }
}
