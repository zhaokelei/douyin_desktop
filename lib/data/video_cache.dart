import 'dart:async';
import 'dart:io';

import '../core/diag.dart';
import '../core/platform_adapter.dart';

/// 磁盘视频预缓存：把接下来的作品提前落盘，播放优先走本地文件。
///
/// 为什么需要它：
///  抖音 `aweme/v1/play` 地址**带 Range 就返回 404**，所以在线播放只能给
///  mpv 设 `stream-lavf-o=seekable=0` 才打得开；代价是流被标成不可 seek，
///  用户拖到未缓冲区间时 mpv 直接报
///  “You can force it with '--force-seekable=yes'”。
///  本地文件天然可 seek，拖动、跳末尾都不会再报错。
///
/// 「秒命中」的三条保证：
///  1. 目录索引常驻内存（[lookup] 直接返回 File，不做任何磁盘 IO/stat）；
///  2. 预取不限速、默认串行——`index+1` 独占带宽先下完，用户停留几秒就能
///     切过去本地播放（并发多路会把带宽摊薄，反而谁都下不完）；
///  3. 实例全局共享（[shared]），进出播放页不重建索引、已完成条目跨页复用。
///
/// 淘汰（FIFO，按需求）：占用超过上限时，**先删最早缓存的那条**，删到不超限为止，
/// 循环往复。正在播放的文件永不淘汰。
class VideoCache {
  VideoCache({
    String? dirPath,
    this.maxBytes = 2048 * 1024 * 1024,
    this.maxItems = 800,
    this.rateKbps = 0,
    this.concurrency = 1,
  }) : dirPath = dirPath ?? _defaultDir();

  /// 全局共享实例：播放页与设置页看的是同一份索引，进出页面不重置。
  static VideoCache? _shared;

  static VideoCache get shared => _shared ??= VideoCache();

  final String dirPath;

  /// 条目数上限（安全阀，避免几万个小文件拖慢目录扫描）。
  final int maxItems;

  /// 单个任务的下载限速（kB/s）；**0 表示不限速**——预取追求"切换前下完"。
  final int rateKbps;

  /// 预取并发数。默认 1：串行才能让"下一条"独占带宽尽快下完；
  /// 拖动进度时用 urgent 插队，不受这个限制。
  final int concurrency;

  /// 容量上限：运行中可改（设置页调完立刻按 FIFO 清到上限内）。
  int maxBytes;

  /// 已缓存条目与占用字节（来自内存索引，同步可读，不碰磁盘）。
  final Map<String, _Entry> _index = {};
  int _usedBytes = 0;
  int _seq = 0;

  int get usedBytes => _usedBytes;
  int get itemCount => _index.length;
  bool get ready => _ready;
  bool _ready = false;

  Directory get _dir => Directory(dirPath);

  Future<void>? _initFuture;
  bool _sweeping = false;
  bool _sweepAgain = false;

  /// 正在被播放器使用的本地文件：淘汰时跳过，避免删掉正在读的文件。
  final Set<String> _activePaths = {};

  final Map<String, _Job> _jobs = {};
  final List<_Job> _queue = [];
  int _running = 0;

  int hitCount = 0;
  int missCount = 0;
  int failureCount = 0;

  static String _defaultDir() {
    // 自测钩子：把缓存目录指到临时目录，不污染用户真实缓存。
    final override = Platform.environment['DOUYIN_CACHE_DIR'];
    if (override != null && override.isNotEmpty) return override;
    // 三端路径统一由 PlatformAdapter 决定：Linux 落在 $XDG_CACHE_HOME，
    // macOS 落在 ~/Library/Caches，Windows 落在 %LOCALAPPDATA%。
    // 不能统一用系统临时目录——会被系统定期清空，缓存等于白下。
    return PlatformAdapter.videoCacheDir;
  }

  static String keyOf(String awemeId, int height) => '${awemeId}_$height';

  /// 文件命名：`<aweme_id>_<高度>.mp4`（高度 0 表示接口未给，按 720 归类）。
  File fileOf(String awemeId, int height) =>
      File('${_dir.path}${Platform.pathSeparator}$awemeId'
          '_${height <= 0 ? 720 : height}.mp4');

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      await _dir.create(recursive: true);
      await _cleanupPartFiles();
      await _rebuildIndex();
      _ready = true;
      diag('cache', '缓存目录就绪：$dirPath，${_index.length} 条 / '
          '${_mb(_usedBytes)}，上限 ${_mb(maxBytes)} / $maxItems 条，'
          '并发 $concurrency，${rateKbps == 0 ? "不限速" : "$rateKbps kB/s"}');
      await _sweep();
    } catch (e) {
      diag('cache', '缓存目录初始化失败（预缓存不可用，回退在线播放）：$e');
      _initFuture = null; // 允许下次重试
    }
  }

  /// 修改上限：设置页改动后立刻生效，当场把超限部分按 FIFO 清掉。
  void setMaxBytes(int bytes) {
    if (bytes <= 0 || bytes == maxBytes) return;
    maxBytes = bytes;
    unawaited(_sweep());
  }

  /// 查询已缓存文件：**纯内存查表**，命中直接返回 File（不再 stat / 改时间戳）。
  ///
  /// 淘汰顺序按"缓存写入时间"（FIFO），所以命中时绝不能刷新 mtime，
  /// 否则最早缓存的条目会一直被顶到队尾，永远删不掉。
  File? lookup(String awemeId, int height) {
    final key = keyOf(awemeId, height);
    final entry = _index[key];
    if (entry != null) return File(entry.path);
    // 索引还在构建（刚进播放页的第一条）：退回同步 exists 判断，
    // 代价只有一次 stat，但避免了"明明缓存过却先在线播"的假未命中。
    if (!_ready) {
      final f = fileOf(awemeId, height);
      try {
        if (f.existsSync() && f.lengthSync() > 0) return f;
      } catch (_) {}
    }
    return null;
  }

  /// 标记为"正在播放"，淘汰时不会删它。
  void markActive(String? path, {String? previous}) {
    if (previous != null) _activePaths.remove(previous);
    if (path != null) _activePaths.add(path);
  }

  /// 确保某条作品已缓存；已存在直接返回，未存在则入队。
  /// [urgent] 表示用户正在等（拖动进度），插队且并发不设限。
  Future<File?> ensure(String awemeId, int height, String url,
      {bool urgent = false}) async {
    final cached = lookup(awemeId, height);
    if (cached != null) return cached;
    final key = keyOf(awemeId, height);
    final existing = _jobs[key];
    if (existing != null) {
      if (urgent && !existing.urgent) {
        existing.urgent = true;
        _queue.remove(existing);
        _queue.insert(0, existing);
      }
      return existing.done.future;
    }
    final job = _Job(key: key, awemeId: awemeId, height: height, url: url);
    job.urgent = urgent;
    _jobs[key] = job;
    if (urgent) {
      _queue.insert(0, job);
    } else {
      _queue.add(job);
    }
    _pump();
    return job.done.future;
  }

  /// 取消不在 [keepKeys] 里的任务（用户快速划走时清掉过期预取）。
  void cancelExcept(Set<String> keepKeys) {
    for (final job in _jobs.values.toList()) {
      if (keepKeys.contains(job.key)) continue;
      job.cancelled = true;
      _queue.remove(job);
      diag('cache', '取消过期预取 ${job.key}');
      if (!job.done.isCompleted) job.done.complete(null);
    }
  }

  /// 清空缓存（保留正在播放的那条，否则画面会断）。
  Future<void> clear() async {
    cancelExcept(const {});
    final keys = _index.keys.toList();
    var removed = 0;
    var bytes = 0;
    for (final k in keys) {
      final e = _index[k];
      if (e == null) continue;
      if (_activePaths.contains(e.path)) continue;
      _index.remove(k);
      _usedBytes -= e.bytes;
      removed++;
      bytes += e.bytes;
      await _tryDelete(File(e.path));
    }
    diag('cache', '手动清空 $removed 条 / ${_mb(bytes)}，'
        '剩余 ${_index.length} 条 / ${_mb(_usedBytes)}');
  }

  void _pump() {
    while (_queue.isNotEmpty) {
      // 普通预取限并发；urgent（用户拖动在等）额外放宽几个槽位，
      // 保证它不会因为后台预取占满而排在后面干等。
      final head = _queue.first;
      final limit = head.urgent ? concurrency + 2 : concurrency;
      if (_running >= limit) break;
      final job = _queue.removeAt(0);
      if (job.cancelled) {
        _jobs.remove(job.key);
        if (!job.done.isCompleted) job.done.complete(null);
        continue;
      }
      _running++;
      unawaited(_run(job).whenComplete(() {
        _running--;
        _jobs.remove(job.key);
        _pump();
      }));
    }
  }

  Future<void> _run(_Job job) async {
    final target = fileOf(job.awemeId, job.height);
    final part = File('${target.path}.part');
    HttpClient? client;
    IOSink? sink;
    var written = 0;
    final watch = Stopwatch()..start();
    diag('cache', '开始缓存 ${job.key}${job.urgent ? "（拖动插队）" : ""}');
    try {
      await _dir.create(recursive: true);
      client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
      // 关键：不要设 Range。抖音地址带 Range 会 404。
      final req = await client.getUrl(Uri.parse(job.url));
      req.headers.set('Referer', 'https://www.douyin.com/');
      req.headers.set('User-Agent', PlatformAdapter.userAgent);
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      // 单条就超过总上限：存进去也会被立刻淘汰，干脆别下，省流量也省磁盘写入。
      final declared = res.contentLength;
      if (declared > 0 && declared > maxBytes) {
        diag('cache', '跳过 ${job.key}：单条 ${_mb(declared)} 超过缓存上限 '
            '${_mb(maxBytes)}，不值得缓存');
        if (!job.done.isCompleted) job.done.complete(null);
        return;
      }
      sink = part.openWrite();
      var lastFlush = 0;
      final kbps = job.urgent ? 0 : rateKbps;
      await for (final chunk in res) {
        if (job.cancelled) break;
        sink.add(chunk);
        written += chunk.length;
        // 每 512KB 刷一次盘：IOSink 缓冲不会越积越大；需要限速时在这里补等。
        if (written - lastFlush >= 512 * 1024) {
          lastFlush = written;
          await sink.flush();
          if (kbps > 0) {
            final expectedMs = written / (kbps * 1024) * 1000;
            final actualMs = watch.elapsedMilliseconds;
            if (expectedMs > actualMs) {
              await Future<void>.delayed(
                  Duration(milliseconds: (expectedMs - actualMs).round()));
            }
          }
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (job.cancelled) {
        await _tryDelete(part);
        return;
      }
      if (written <= 0) throw HttpException('空响应');
      await _tryDelete(target);
      await part.rename(target.path);
      await target.setLastModified(DateTime.now());
      _putIndex(job.key, target, written);
      diag('cache',
          '缓存完成 ${job.key} ${_mb(written)} 用时 ${watch.elapsed.inMilliseconds}ms');
      if (!job.done.isCompleted) job.done.complete(target);
      unawaited(_sweep());
    } catch (e) {
      failureCount++;
      diag('cache', '缓存失败 ${job.key}：$e（该条回退在线播放）');
      try {
        await sink?.close();
      } catch (_) {}
      await _tryDelete(part);
      if (!job.done.isCompleted) job.done.complete(null);
    } finally {
      client?.close(force: true);
    }
  }

  void _putIndex(String key, File f, int bytes) {
    final old = _index[key];
    if (old != null) _usedBytes -= old.bytes;
    _index[key] = _Entry(f.path, bytes, DateTime.now(), ++_seq);
    _usedBytes += bytes;
  }

  Future<void> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 重建内存索引（启动时扫一次目录，之后所有命中查询都不再碰磁盘）。
  Future<void> _rebuildIndex() async {
    _index.clear();
    _usedBytes = 0;
    if (!await _dir.exists()) return;
    final found = <MapEntry<String, _Entry>>[];
    await for (final e in _dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (!name.endsWith('.mp4')) continue;
      try {
        final stat = e.statSync();
        if (stat.size <= 0) {
          await _tryDelete(e);
          continue;
        }
        final key = name.substring(0, name.length - 4);
        found.add(MapEntry(key, _Entry(e.path, stat.size, stat.modified, 0)));
      } catch (_) {}
    }
    // 按写入时间排序后再编号：同一毫秒内写入的多条也有稳定先后，FIFO 不会乱。
    found.sort((a, b) => a.value.savedAt.compareTo(b.value.savedAt));
    for (final e in found) {
      _index[e.key] = _Entry(e.value.path, e.value.bytes, e.value.savedAt, ++_seq);
      _usedBytes += e.value.bytes;
    }
  }

  /// 清理上次异常退出（进程被杀 / 自测脚本直接 exit）留下的半成品。
  /// `.part` 不参与容量统计，不清掉会一直占磁盘。
  Future<void> _cleanupPartFiles() async {
    try {
      if (!await _dir.exists()) return;
      await for (final e in _dir.list(followLinks: false)) {
        if (e is File && e.path.endsWith('.part')) {
          final len = e.lengthSync();
          await e.delete();
          diag('cache', '清理残留半成品 ${e.uri.pathSegments.last} (${_mb(len)})');
        }
      }
    } catch (e) {
      diag('cache', '清理半成品失败（忽略）：$e');
    }
  }

  /// FIFO 淘汰：按"缓存写入时间"从最早开始删，删到占用不超上限为止。
  /// 正在播放的文件永远跳过；如果剩下的全是正在播放的，就停止（不会死循环）。
  Future<void> _sweep() async {
    if (_sweeping) {
      _sweepAgain = true;
      return;
    }
    _sweeping = true;
    try {
      do {
        _sweepAgain = false;
        while (_overLimit()) {
          final victim = _oldestEvictable();
          if (victim == null) break;
          final entry = _index.remove(victim);
          if (entry == null) break;
          _usedBytes -= entry.bytes;
          await _tryDelete(File(entry.path));
          final mb = _mb(entry.bytes);
          diag('cache', '超出上限，删除最早缓存 $victim ($mb)，'
              '现占用 ${_mb(_usedBytes)} / ${_mb(maxBytes)}');
        }
      } while (_sweepAgain);
    } catch (e) {
      diag('cache', '淘汰异常（不影响播放）：$e');
    } finally {
      _sweeping = false;
    }
  }

  bool _overLimit() => _usedBytes > maxBytes || _index.length > maxItems;

  /// 最早缓存且不在播放中的条目 key。
  String? _oldestEvictable() {
    String? bestKey;
    _Entry? best;
    for (final e in _index.entries) {
      if (_activePaths.contains(e.value.path)) continue;
      if (best == null ||
          e.value.savedAt.isBefore(best.savedAt) ||
          (e.value.savedAt == best.savedAt && e.value.seq < best.seq)) {
        best = e.value;
        bestKey = e.key;
      }
    }
    return bestKey;
  }

  Future<String> statsLine() async =>
      '占用 ${_mb(_usedBytes)} / ${_mb(maxBytes)}，${_index.length} 条，'
      '命中 $hitCount 次 / 未命中 $missCount 次 / 失败 $failureCount 次';

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

class _Entry {
  _Entry(this.path, this.bytes, this.savedAt, this.seq);

  final String path;
  final int bytes;
  final DateTime savedAt;
  final int seq;
}

class _Job {
  _Job({
    required this.key,
    required this.awemeId,
    required this.height,
    required this.url,
  });

  final String key;
  final String awemeId;
  final int height;
  final String url;
  bool urgent = false;
  bool cancelled = false;
  final Completer<File?> done = Completer<File?>();
}
