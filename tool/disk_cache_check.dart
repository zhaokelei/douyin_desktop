// 磁盘预缓存自测：不建窗口、不连抖音，用本地 HTTP 服务模拟 CDN。
//
//   dart run tool/disk_cache_check.dart
//
// 覆盖三件事：
//   1. 预取速度 —— 模拟"用户每 2.4 秒切一条"时，切过去能不能命中（秒开）；
//   2. FIFO 淘汰 —— 超上限时删的必须是**最早缓存**的那条，循环往复；
//   3. 约束 —— 正在播放的文件不淘汰、重启后索引能从目录重建。
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:douyin_desktop/data/video_cache.dart';

const int videoBytes = 3 * 1024 * 1024; // 每个假视频 3MB
const int chunkBytes = 64 * 1024;
const int perChunkDelayMs = 40; // ≈1.6MB/s，接近真实手机网络下的 CDN 表现

int _requests = 0;
int _failures = 0;

void main() async {
  final root = Directory.systemTemp.createTempSync('vctest_');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _serve(server);
  final base = 'http://127.0.0.1:${server.port}';

  stdout.writeln('== 磁盘预缓存自测（本地模拟 CDN，每个视频 3.0MB）==');

  await _testHitRate(base, Directory('${root.path}/hit'));
  await _testFifo(base, Directory('${root.path}/fifo'));
  await _testActiveKeep(base, Directory('${root.path}/active'));
  await _testRestartIndex(Directory('${root.path}/hit'));

  await server.close(force: true);
  try {
    root.deleteSync(recursive: true);
  } catch (_) {}

  stdout.writeln('');
  if (_failures == 0) {
    stdout.writeln('结果：全部通过（服务端共处理 $_requests 个请求）');
  } else {
    stdout.writeln('结果：$_failures 项失败');
    exitCode = 1;
  }
}

/// ① 命中率：模拟用户停留 2.4 秒后划到下一条。
Future<void> _testHitRate(String base, Directory dir) async {
  stdout.writeln('\n[1] 预取命中率（并发 3、不限速）');
  final cache = VideoCache(dirPath: dir.path, concurrency: 3);
  await cache.init();

  // 打开第 0 条（在线播放），立刻按播放页的顺序排预取：
  // 1..6 依次入队，当前条不排（它已经在线在播）。
  final started = DateTime.now();
  final futures = <Future<File?>>[];
  for (var i = 1; i <= 6; i++) {
    futures.add(cache.ensure('v$i', 720, '$base/v$i'));
  }
  final firstDone = await futures.first;
  final firstMs = DateTime.now().difference(started).inMilliseconds;
  _check(firstDone != null, '第 1 条预取完成', '用时 ${firstMs}ms');
  stdout.writeln('    第 1 条（下一条）就绪耗时 ${firstMs}ms');

  var hits = 0;
  for (var i = 1; i <= 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2400));
    final sw = Stopwatch()..start();
    final f = cache.lookup('v$i', 720);
    sw.stop();
    if (f != null) hits++;
    stdout.writeln('    第 ${i} 次切换：${f != null ? "命中本地" : "未命中（在线）"}'
        ' 查询 ${sw.elapsedMicroseconds}µs');
  }
  _check(hits == 6, '6 次切换全部命中', '实际命中 $hits/6');
  await Future.wait(futures);
  diagStats(cache, '命中率测试');
}

/// ② FIFO：上限只够 3 条时，应删最早缓存的，且继续缓存的仍然成功。
Future<void> _testFifo(String base, Directory dir) async {
  stdout.writeln('\n[2] 超上限按「最早缓存」淘汰');
  const maxBytes = videoBytes * 7 ~/ 2; // 3.5 条
  final cache = VideoCache(dirPath: dir.path, maxBytes: maxBytes, concurrency: 1);
  await cache.init();

  for (var i = 0; i < 5; i++) {
    final f = await cache.ensure('f$i', 720, '$base/v$i');
    _check(f != null, '缓存 f$i 成功', '返回 null');
    await _waitIdle(cache);
    stdout.writeln('    写入 f$i 后占用 '
        '${(cache.usedBytes / 1024 / 1024).toStringAsFixed(1)}MB / '
        '${cache.itemCount} 条');
  }

  _check(cache.usedBytes <= maxBytes, '占用不超过上限',
      '实际 ${(cache.usedBytes / 1024 / 1024).toStringAsFixed(1)}MB > '
      '${(maxBytes / 1024 / 1024).toStringAsFixed(1)}MB');
  _check(cache.lookup('f0', 720) == null, 'f0（最早）已被淘汰', 'f0 还在');
  _check(cache.lookup('f4', 720) != null, 'f4（最新）仍在', 'f4 被误删');
  await cache.clear();
  _check(cache.itemCount == 0, 'clear 后条目归零', '剩 ${cache.itemCount} 条');
}

/// ③ 正在播放的那条不能被淘汰，哪怕它是最早缓存的。
Future<void> _testActiveKeep(String base, Directory dir) async {
  stdout.writeln('\n[3] 正在播放的文件不被淘汰');
  final cache = VideoCache(
      dirPath: dir.path, maxBytes: videoBytes * 3 ~/ 2, concurrency: 1);
  await cache.init();

  final keep = await cache.ensure('k0', 720, '$base/v0');
  _check(keep != null, '缓存 k0 成功', '返回 null');
  cache.markActive(keep!.path);
  await _waitIdle(cache);

  for (var i = 1; i <= 2; i++) {
    await cache.ensure('k$i', 720, '$base/v$i');
    await _waitIdle(cache);
  }
  _check(await File(keep.path).exists(), 'k0（播放中）未被删除', 'k0 文件消失');
  _check(cache.lookup('k1', 720) == null, '更早的静态条目已被淘汰', 'k1 还在');
  cache.markActive(null, previous: keep.path);
}

/// ④ 重启：新实例从目录重建索引，占用与条数一致。
Future<void> _testRestartIndex(Directory dir) async {
  stdout.writeln('\n[4] 重启后重建索引');
  final before = Directory(dir.path)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.mp4'))
      .toList();
  final cache = VideoCache(dirPath: dir.path);
  await cache.init();
  _check(cache.itemCount == before.length, '索引条数与目录一致',
      '索引 ${cache.itemCount} / 目录 ${before.length}');
  final actual = before.fold<int>(0, (a, f) => a + f.lengthSync());
  _check(cache.usedBytes == actual, '占用字节与目录一致',
      '索引 ${cache.usedBytes} / 目录 $actual');
  _check(cache.lookup('v1', 720) != null, '重建后可命中 v1', 'v1 未命中');
}

void _serve(HttpServer server) {
  server.listen((req) async {
    _requests++;
    final id = int.tryParse(req.uri.pathSegments.last.replaceAll('v', '')) ?? 0;
    final res = req.response;
    res.headers.contentType = ContentType('video', 'mp4');
    res.contentLength = videoBytes;
    final rnd = Random(id + 1);
    var sent = 0;
    try {
      while (sent < videoBytes) {
        final n = min(chunkBytes, videoBytes - sent);
        final buf = Uint8List(n);
        for (var i = 0; i < n; i++) {
          buf[i] = rnd.nextInt(256);
        }
        res.add(buf);
        await res.flush();
        sent += n;
        await Future<void>.delayed(const Duration(milliseconds: perChunkDelayMs));
      }
      await res.close();
    } catch (_) {
      // 客户端取消（预取被 cancelExcept 打断）时写会失败，属正常现象。
      try {
        await res.close();
      } catch (_) {}
    }
  });
}

/// 等淘汰跑完（sweep 是异步的，写入完成后稍等几十毫秒）。
Future<void> _waitIdle(VideoCache cache) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!cache.ready) continue;
    if (cache.usedBytes <= cache.maxBytes) return;
  }
}

void diagStats(VideoCache cache, String tag) {
  stdout.writeln('    [$tag] 占用 '
      '${(cache.usedBytes / 1024 / 1024).toStringAsFixed(1)}MB / '
      '${(cache.maxBytes / 1024 / 1024).toStringAsFixed(0)}MB，'
      '${cache.itemCount} 条，命中 ${cache.hitCount} / 未命中 ${cache.missCount}');
}

void _check(bool ok, String what, String detail) {
  if (ok) {
    stdout.writeln('    OK   $what');
  } else {
    _failures++;
    stdout.writeln('    FAIL $what —— $detail');
  }
}
