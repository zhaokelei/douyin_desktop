// lib/features/player/fvp_media_kit_shim.dart
//
// media_kit (libmpv) API 兼容层 —— 用 fvp / libmdk 实现同名、同签名的类。
//
// 为什么需要它：播放页有 4469 行，UI、评论、缓存预取、清晰度、全屏、
// 快捷键、硬解降级等逻辑全部与播放器交织在一起。灰度期如果直接重写，
// 既容易让 mpv 版回归，也没法保证「完整对齐」。
//
// 这里提供 Player / VideoController / Video / Media / NativePlayer 的
// 同名实现，`player_page_fvp.dart` 只需要把两行 media_kit import 换成
// 本文件，其余代码**一个字不改**即可跑在 libmdk 上。
//
// 注意：这是有意的「接口兼容」而非完整复刻——mpv 专有属性
// （osc / osd / demuxer-* / cache-on-disk / video-sync ...）在 libmdk 里
// 没有对应概念，NativePlayer.setProperty 对它们安全忽略；少数真正影响
// 行为的（hwdec / hwdec-current / width / height）做了语义映射。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fvp/mdk.dart' as mdk;

import '../../core/platform_adapter.dart';
import '../../core/platform_style.dart';

// ------------------------------------------------------------------ 数据模型

class Media {
  const Media(this.uri, {this.httpHeaders = const <String, String>{}});
  final String uri;
  final Map<String, String> httpHeaders;
}

class VideoControllerConfiguration {
  const VideoControllerConfiguration({
    this.enableHardwareAcceleration = true,
    this.width,
    this.height,
  });
  final bool enableHardwareAcceleration;

  /// libmdk 的纹理尺寸由视频自身 dw/dh 决定，不接受强制尺寸。
  /// 保留字段只为兼容调用方；传了也不生效（这正是修复黑边的做法）。
  final int? width;
  final int? height;
}

// -------------------------------------------------------------- 流 / 状态容器

/// 对应 media_kit 的日志事件：播放页读 `level` / `text` 两个字段。
class LogEvent {
  const LogEvent(this.level, this.text);
  final String level;
  final String text;
}

class PlayerStream {
  PlayerStream({
    required this.log,
    required this.error,
    required this.position,
    required this.duration,
    required this.buffering,
    required this.playing,
    required this.completed,
  });

  final Stream<LogEvent> log;
  final Stream<String> error;
  final Stream<Duration> position;
  final Stream<Duration> duration;
  final Stream<bool> buffering;
  final Stream<bool> playing;
  final Stream<bool> completed;
}

class PlayerState {
  PlayerState(this._owner);
  final Player _owner;

  Duration get position => Duration(milliseconds: _owner._mdk.position);
  Duration get duration => Duration(milliseconds: _owner._durationMs);
  bool get playing => _owner._mdk.state == mdk.PlaybackState.playing;
  bool get completed => _owner._completed;
  double get volume => _owner._volume;
  double get rate => _owner._mdk.playbackRate;
}

// ------------------------------------------------------- mpv 属性兼容层

/// 对应 media_kit 的 `NativePlayer`。播放页用
/// `if (_player.platform is NativePlayer)` 判断后读写 mpv 属性。
class NativePlayer {
  NativePlayer(this._owner);
  final Player _owner;

  Future<String> getProperty(String name) async {
    switch (name) {
      case 'width':
        return _owner._videoSize == null
            ? ''
            : '${_owner._videoSize!.width.toInt()}';
      case 'height':
        return _owner._videoSize == null
            ? ''
            : '${_owner._videoSize!.height.toInt()}';
      case 'hwdec':
        return _owner._requestedHwdec;
      case 'hwdec-current':
        // libmdk 没有这个属性，用 onEvent 里记录的实际解码器名代替。
        // 返回的名字要能被 PlatformAdapter.isHardwareDecoder 识别。
        return _owner._currentDecoder;
      case 'stream-lavf-o':
        return _owner._streamLavfOpt;
      case 'audio-wait-for-video':
      case 'options/audio-wait-for-video':
        return 'yes';
      case 'video-sync':
        return 'audio';
      case 'force-window':
        return 'no';
      default:
        return '';
    }
  }

  Future<void> setProperty(String name, String value) async {
    switch (name) {
      case 'hwdec':
        _owner._requestedHwdec = value;
        _owner._applyDecoders(value != 'no');
        break;
      case 'stream-lavf-o':
        _owner._streamLavfOpt = value;
        // libmdk 的 FFmpeg demuxer 自己处理 Range，抖音 CDN 上的
        // seekable=0 不需要（也不应该）透传，避免又关掉任意拖动。
        break;
      case 'user-agent':
      case 'referrer':
        // 播放页已经把 UA / Referer 放进 Media.httpHeaders，open() 会
        // 转成 avio.headers，这里不重复设置。
        break;
      case 'log-file':
      case 'msg-level':
      case 'osc':
      case 'osd-level':
      case 'osd-bar':
      case 'keep-open':
      case 'cache':
      case 'cache-on-disk':
      case 'demuxer-max-bytes':
      case 'demuxer-max-back-bytes':
      case 'demuxer-readahead-secs':
      case 'vd-lavc-threads':
      case 'force-seekable':
      case 'force-window':
      case 'video-sync':
      case 'options/audio-wait-for-video':
      case 'd3d11-adapter':
        // libmdk 无对应概念：安全忽略。硬解/缓冲/低延迟由
        // videoDecoders 与 avformat.* 属性在 open() 里统一配置。
        break;
      default:
        // 未识别的属性交给 libmdk 自己判断，避免悄悄丢掉有用设置。
        try {
          _owner._mdk.setProperty(name, value);
        } catch (_) {
          // 某些 mpv 专属属性在 libmdk 里会抛，忽略即可。
        }
    }
  }
}

// ------------------------------------------------------------ VideoController

class VideoController {
  VideoController(
    this.player, {
    this.configuration = const VideoControllerConfiguration(),
  });

  final Player player;
  final VideoControllerConfiguration configuration;

  /// media_kit 的 `VideoController.id` 是 `ValueNotifier<int?>`；
  /// libmdk 的 `Player.textureId` 恰好也是同一个类型，直接透传。
  ValueNotifier<int?> get id => player._mdk.textureId;
}

// -------------------------------------------------------------------- Player

class Player {
  Player() {
    _mdk = mdk.Player();
    _native = NativePlayer(this);
    _streams = PlayerStream(
      log: _logCtl.stream,
      error: _errorCtl.stream,
      position: _positionCtl.stream,
      duration: _durationCtl.stream,
      buffering: _bufferingCtl.stream,
      playing: _playingCtl.stream,
      completed: _completedCtl.stream,
    );
    _state = PlayerState(this);

    // 网络流稳健性：与 fvp 官方 video_player 实现一致。
    _mdk.setProperty('avformat.safe', '0');
    _mdk.setProperty('avio.reconnect', '1');
    _mdk.setProperty('avio.reconnect_delay_max', '7');
    _mdk.setProperty('avformat.extension_picky', '0');
    _mdk.setProperty('avformat.allowed_segment_extensions', 'ALL');

    _subscriptions.add(_mdk.onStateChanged.listen((e) {
      final playing = e.newValue == mdk.PlaybackState.playing ||
          e.newValue == mdk.PlaybackState.running;
      if (!_playingCtl.isClosed) _playingCtl.add(playing);
    }));
    _subscriptions.add(_mdk.onMediaStatus.listen((e) {
      final buffering = e.newValue.test(mdk.MediaStatus.buffering);
      if (!_bufferingCtl.isClosed) _bufferingCtl.add(buffering);
    }));
    _subscriptions.add(_mdk.onEvent.listen((e) {
      if (e.category == 'decoder.video' && e.detail.isNotEmpty) {
        _currentDecoder = e.detail;
      }

      // 关键：mdk 的 `MediaEvent.error` **不是**统一的错误码。
      //
      // 官方类型注释写得很清楚：
      //   `int error; // progress value [0, 100] if category is
      //               // "reader.buffering"`
      // 也就是说：
      //   - `reader.buffering` → error 是**缓冲进度百分比**（78/80/88/…/100）；
      //   - `thread.audio` / `thread.video` → 线程状态码（1 = 正常退出）；
      //   - 真正的错误码是**负数**（mdk 的 MEDIA_ERR_* 全部 < 0）。
      //
      // 旧实现写的是 `if (e.error != 0) → 抛播放错误`，于是抖音这种
      // 边下边播的流每推进一点缓冲进度就报一次“播放失败”，用户明明
      // 看着画面在正常播放，屏幕中央却一直挂着红色错误浮层 + 重试按钮。
      if (e.error < 0) {
        if (!_errorCtl.isClosed) {
          _errorCtl.add('${e.category}: ${e.detail} (${e.error})');
        }
        return;
      }
      // `reader.buffering` 不是事件而是**进度**：每个百分点都写一条日志，
      // 一条视频就是几十行，把环形缓冲和报告全占满。缓冲状态已经通过
      // onMediaStatus → buffering 流送到播放页了，这里直接丢掉。
      if (e.category == 'reader.buffering') return;
      if (!_logCtl.isClosed) {
        // detail 为空（thread.audio / thread.video 这类）时不要把状态码
        // 拼进去——`thread.audio: (1)` 只会让人误以为是错误。
        _logCtl.add(LogEvent(
            e.category, e.detail.isEmpty ? '' : e.detail));
      }
    }));

    // libmdk 没有 position 流，按 150ms 轮询产生——与播放页对
    // mpv position 流的节流节奏一致，进度条手感不变。
    _positionTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (_disposed) return;
      final pos = _mdk.position;
      if (!_positionCtl.isClosed) {
        _positionCtl.add(Duration(milliseconds: pos));
      }
      // 播放到结尾：模拟 media_kit 的 completed 流。
      if (!_completed && _durationMs > 0 && pos >= _durationMs - 120) {
        _completed = true;
        if (!_completedCtl.isClosed) _completedCtl.add(true);
      }
    });

    // libmdk 的日志是全局回调，灰度期同时只存在一个 Player。
    mdk.setLogHandler((level, text) {
      if (_disposed || _logCtl.isClosed) return;
      if (_noisyLog.hasMatch(text)) return;
      _logCtl.add(LogEvent(level.name, text));
    });
  }

  late final mdk.Player _mdk;
  late final NativePlayer _native;
  late final PlayerStream _streams;
  late final PlayerState _state;

  // 三条流的事件类型各不相同（PlaybackState / MediaStatus / MediaEvent），
  // 用 dynamic 收集订阅，dispose 时统一 cancel。
  final List<dynamic> _subscriptions = [];
  final _logCtl = StreamController<LogEvent>.broadcast();
  final _errorCtl = StreamController<String>.broadcast();
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration>.broadcast();
  final _bufferingCtl = StreamController<bool>.broadcast();
  final _playingCtl = StreamController<bool>.broadcast();
  final _completedCtl = StreamController<bool>.broadcast();

  Timer? _positionTimer;
  bool _disposed = false;
  bool _completed = false;

  /// 打开世代：后台补纹理时用来判断"这是不是当前这条媒体"。
  int _openSeq = 0;

  /// 我们自己的超时哨兵值。mdk 的真实错误码都是负数，但不保证没有
  /// 恰好等于某个值的可能，用一个远离它们的大负数最安全。
  static const int _timeoutCode = -9999;

  /// 刷屏日志：边下边播时 mdk 会按缓冲百分比逐行打印（4%/9%/13%…），
  /// 一条视频几十行，两分钟就能把 2000 条内存缓冲占满，真正有用的行
  /// （错误、解码器切换、EOF）全被挤出去——用户复制出来的诊断报告里
  /// 只剩这类噪音，反而看不出问题。
  static final RegExp _noisyLog = RegExp(
    r'buffering progress|BUFFERING (START|END)|update MediaStatus|'
    r'check loop range|range loop end|before changed\(\)',
  );

  int _durationMs = 0;
  double _volume = 100;
  Size? _videoSize;
  String _requestedHwdec = PlatformAdapter.preferredHwdec;
  String _currentDecoder = '';
  String _streamLavfOpt = '';

  NativePlayer get platform => _native;
  PlayerStream get stream => _streams;
  PlayerState get state => _state;

  /// 供 Video widget 取纹理实际尺寸（按视频自身 dw/dh，不强制 16:9）。
  Size? get videoSize => _videoSize;

  void _applyDecoders(bool hardware) {
    if (!hardware) {
      _mdk.videoDecoders = const ['FFmpeg'];
      _currentDecoder = 'FFmpeg';
      return;
    }
    // libmdk 的解码器名按平台取；末尾 FFmpeg 保证 GPU 不可用时自动回落。
    _mdk.videoDecoders = switch (desktopFlavor) {
      DesktopFlavor.macOS => const ['VideoToolbox', 'FFmpeg'],
      DesktopFlavor.windows => const ['D3D11', 'NVDEC', 'FFmpeg'],
      DesktopFlavor.linux => const ['VAAPI', 'FFmpeg'],
    };
  }

  Future<void> open(Media media, {bool play = true}) async {
    _completed = false;
    final seq = ++_openSeq;
    if (!_completedCtl.isClosed) _completedCtl.add(false);
    _applyDecoders(_requestedHwdec != 'no');

    if (media.httpHeaders.isNotEmpty) {
      final headers = media.httpHeaders.entries
          .map((e) => '${e.key}: ${e.value}\r\n')
          .join();
      _mdk.setProperty('avio.headers', headers);
    }
    _mdk.media = media.uri;

    // prepare 必须有上限。
    //
    // 抖音 CDN 偶发"连上了但一直不回数据"，此时 mdk 的 prepared 回调
    // 永远不来，`_prepared` 这个 Completer 也就永远不完成——旧实现
    // `await _mdk.prepare()` 会把整个 open() 挂在半空，播放页的
    // `_switching` 锁再也放不开（用户看到的现象：一直转「加载中…」，
    // 上下键切条全部失效，只能杀进程）。
    final ret = await _mdk
        .prepare()
        .timeout(const Duration(seconds: 12), onTimeout: () => _timeoutCode);
    if (ret < 0) {
      if (!_errorCtl.isClosed) {
        _errorCtl.add(ret == _timeoutCode
            ? '打开超时：12 秒内没有完成媒体解析'
            : '媒体打开失败或格式不支持');
      }
      return;
    }
    _durationMs = _mdk.mediaInfo.duration;
    if (!_durationCtl.isClosed) {
      _durationCtl.add(Duration(milliseconds: _durationMs));
    }

    // 纹理尺寸同理，而且这是**最容易永久挂住**的一处：
    // fvp 只在收到 `loaded` 状态或 `decoder.video` 事件时才完成
    // `_videoSize`；进入 `loading` 时它还会被换成一个新的 Completer。
    // 源码注释原话是 "that future may never complete"。旧实现直接
    // `await _mdk.textureSize`，坏源/EOF 后的重开场景就会永久卡死。
    // 现在最多等 1.8 秒，等不到就放行 open，后台补上、补到再建纹理。
    final size = await _mdk.textureSize
        .timeout(const Duration(milliseconds: 1800), onTimeout: () => null);
    if (size != null) {
      _videoSize = size;
      // 每条视频重建纹理：libmdk 会先释放旧的，不会像 mpv 那样累积内存。
      try {
        await _mdk.updateTexture().timeout(
            const Duration(milliseconds: 2500),
            onTimeout: () => _timeoutCode);
      } catch (_) {
        // 建纹理失败不该阻断播放：Video 先显示纯黑底，下次 open 会重建。
      }
    } else {
      // 尺寸还没到：不阻塞 open。
      // `textureId` 是 ValueNotifier，`Video` 监听它；后台补齐尺寸并建好
      // 纹理后，界面会自动重绘，不需要播放页额外刷新。
      unawaited(_mdk.textureSize.then((s) async {
        // 期间用户可能已经切到别的视频：世代不匹配就直接放弃，
        // 否则会把旧媒体的纹理建到新媒体的会话上。
        if (_disposed || s == null || seq != _openSeq) return;
        _videoSize = s;
        try {
          await _mdk.updateTexture();
        } catch (_) {
          // 同上：失败就留黑底。
        }
      }));
    }
    if (play) await this.play();
  }

  Future<void> play() async {
    _mdk.state = mdk.PlaybackState.playing;
  }

  Future<void> pause() async {
    _mdk.state = mdk.PlaybackState.paused;
  }

  Future<void> stop() async {
    _mdk.state = mdk.PlaybackState.stopped;
  }

  Future<void> playOrPause() async {
    if (_mdk.state == mdk.PlaybackState.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration position) async {
    await _mdk.seek(position: position.inMilliseconds);
  }

  Future<void> setVolume(double volume) async {
    // media_kit 用 0~100，libmdk 用 0~1。
    _volume = volume.clamp(0.0, 100.0);
    _mdk.volume = _volume / 100.0;
  }

  Future<void> setRate(double rate) async {
    _mdk.playbackRate = rate;
  }

  /// media_kit 的 dispose() 是异步的，播放页会 `await` / `unawaited` 它。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _positionTimer?.cancel();
    for (final s in _subscriptions) {
      // ignore: discarded_futures
      s.cancel();
    }
    _mdk.dispose();
    for (final c in <StreamController<dynamic>>[
      _logCtl,
      _errorCtl,
      _positionCtl,
      _durationCtl,
      _bufferingCtl,
      _playingCtl,
      _completedCtl,
    ]) {
      // ignore: discarded_futures
      c.close();
    }
  }
}

// ----------------------------------------------------------------- Video widget

/// 对应 media_kit_video 的 `Video`。libmdk 直接给出 Flutter textureId，
/// 用 `Texture` 渲染即可；外层 FittedBox 负责 BoxFit.contain 自适应，
/// macOS 上整条链路走 Metal，不再有 mpv TextureHW 的 CGL 上下文。
class Video extends StatelessWidget {
  const Video({
    super.key,
    required this.controller,
    this.fit = BoxFit.contain,
    this.fill = Colors.black,
    this.controls = _noControls,
  });

  final VideoController controller;
  final BoxFit fit;
  final Color fill;

  /// 播放页只传 `(state) => SizedBox.shrink()`；保留参数以兼容调用签名。
  final Widget Function(dynamic state) controls;

  static Widget _noControls(dynamic _) => const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: controller.id,
      builder: (context, textureId, _) {
        final size = controller.player.videoSize;
        if (textureId == null || textureId < 0 || size == null) {
          return Container(color: fill);
        }
        return FittedBox(
          fit: fit,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Texture(textureId: textureId),
          ),
        );
      },
    );
  }
}
