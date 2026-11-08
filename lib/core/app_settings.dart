import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 视频解码方式。
enum DecodeMode {
  /// 优先硬件解码；硬件不可用时**自动**回落到 CPU 软件解码（并给出中文提示）。
  auto,

  /// 只用 CPU 软件解码（省电、兼容性最好，占用 CPU 高）。
  software,
}

/// 视频缓存策略。
///
/// 只保留磁盘缓存：预取后续作品落盘，命中时直接本地播放——开播不用等网络、
/// 进度条也能随意拖。旧版本的「内存缓存」模式已移除，读到旧的 `memory`
/// 值会按磁盘缓存处理（见 [_parseCache]）。
enum CacheMode {
  /// 缓存在磁盘：预取后续作品，命中即本地播放。
  disk,

  /// 不缓存：全部直连播放（在线流不可拖动进度）。
  off,
}

/// 全局设置（单例）。
///
/// 用 [ChangeNotifier] 暴露给界面：设置页改了值，播放页与首页都能立刻响应，
/// 不需要重启。所有键名前缀 `douyin_`，避免与登录态（session_store）冲突。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  // 存储键
  static const String keyDecodeMode = 'douyin_decode_mode';
  static const String keyCacheMode = 'douyin_cache_mode';
  static const String keyCacheLimitMB = 'douyin_cache_limit_mb';
  static const String keyQualityPref = 'douyin_quality_pref';

  /// 磁盘缓存上限可选项（MB）。
  static const List<int> cacheLimitOptions = [512, 1024, 2048, 4096, 8192];

  /// 默认缓存上限：2GB。按 1080P 短视频约 3~8MB 估算，能存几百条。
  static const int defaultCacheLimitMB = 2048;

  DecodeMode _decodeMode = DecodeMode.auto;
  CacheMode _cacheMode = CacheMode.disk;
  int _cacheLimitMB = defaultCacheLimitMB;
  String _qualityPref = 'auto';

  DecodeMode get decodeMode => _decodeMode;
  CacheMode get cacheMode => _cacheMode;
  int get cacheLimitMB => _cacheLimitMB;
  int get cacheLimitBytes => _cacheLimitMB * 1024 * 1024;
  String get qualityPref => _qualityPref;

  /// 是否请求硬件解码。`auto` 模式即"硬解优先"。
  bool get hardwareEnabled => _decodeMode == DecodeMode.auto;

  /// 首次读取：必须在 runApp 之前 await 一次，避免首帧用默认值闪一下。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _decodeMode = _parseDecode(prefs.getString(keyDecodeMode));
      _cacheMode = _parseCache(prefs.getString(keyCacheMode));
      final mb = prefs.getInt(keyCacheLimitMB);
      if (mb != null && mb > 0) _cacheLimitMB = mb;
      _qualityPref = prefs.getString(keyQualityPref) ?? 'auto';
    } catch (e) {
      debugPrint('[settings] 读取设置失败，使用默认值: $e');
    }
  }

  Future<void> setDecodeMode(DecodeMode mode) async {
    if (_decodeMode == mode) return;
    _decodeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          keyDecodeMode, mode == DecodeMode.auto ? 'auto' : 'software');
    } catch (e) {
      debugPrint('[settings] 保存解码方式失败: $e');
    }
  }

  Future<void> setCacheMode(CacheMode mode) async {
    if (_cacheMode == mode) return;
    _cacheMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyCacheMode, mode.name);
    } catch (e) {
      debugPrint('[settings] 保存缓存方式失败: $e');
    }
  }

  /// 修改缓存上限：立即通知（播放页会把新上限下发给缓存实例并当场清理超限部分）。
  Future<void> setCacheLimitMB(int mb) async {
    if (_cacheLimitMB == mb) return;
    _cacheLimitMB = mb;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(keyCacheLimitMB, mb);
    } catch (e) {
      debugPrint('[settings] 保存缓存上限失败: $e');
    }
  }

  /// 与播放页共用同一个键：设置页改默认清晰度，播放页下次打开即生效。
  Future<void> setQualityPref(String value) async {
    if (_qualityPref == value) return;
    _qualityPref = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyQualityPref, value);
    } catch (e) {
      debugPrint('[settings] 保存清晰度偏好失败: $e');
    }
  }

  static DecodeMode _parseDecode(String? raw) =>
      raw == 'software' ? DecodeMode.software : DecodeMode.auto;

  static CacheMode _parseCache(String? raw) {
    // 旧版本的 'memory' 已移除：迁移成磁盘缓存，不会让老用户掉进"无缓存"。
    return raw == 'off' ? CacheMode.off : CacheMode.disk;
  }
}
