// 统一的"技术错误 → 中文提示"翻译层。
//
// 规则：**界面上不出现英文原文**。mpv / libavformat / socket 抛出的原文
// 一律先经过这里翻成中文再展示；原始文本仍由调用方写进 diag() 日志，
// 排障时不丢信息。
//
// 为什么不各页面自己写：播放、评论、作者页、首页、登录页原来各有一套
// `'$e'` 兜底，结果微软拼音以外的场景下用户会看到
// “Failed to open https://...” 这种英文。集中到一处才能保证一致。

import 'dart:async';
import 'dart:io';

import '../data/douyin_api.dart';

/// 中文错误文案生成器。
class ErrorText {
  const ErrorText._();

  /// 认不出具体原因时的兜底文案。
  static const String unknown = '操作失败，请稍后重试（详细信息已记录到运行日志）';

  /// 把任意异常转成中文提示。
  static String from(Object error) {
    final typed = _fromTyped(error);
    if (typed != null) return typed;
    final raw = _stripWrapper(error.toString());
    return translate(raw) ?? unknown;
  }

  /// 去掉 `Exception: ` / `Bad state: ` 这类包装前缀，避免出现在界面上。
  static String _stripWrapper(String raw) {
    var text = raw.trim();
    for (final prefix in const [
      'Unhandled exception: ',
      'Exception: ',
      'Bad state: ',
      'Error: ',
    ]) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trim();
        break;
      }
    }
    return text;
  }

  /// 播放链路的错误：统一带「播放失败：」前缀。
  ///
  /// 播放失败的来源有两类——网络（打开地址失败）和解码（解不出来）。
  /// 两者都以 mpv 的英文文本形式抛出，[_translate] 会分别翻译。
  static String play(Object error) {
    final detail = from(error);
    return detail.startsWith('播放失败') ? detail : '播放失败：$detail';
  }

  /// 把一段可能是英文的技术文案翻成中文；认不出来返回 null。
  static String? translate(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final v = text.toLowerCase();

    // ---- 打开 / 识别媒体 ----
    if (v.contains('failed to recognize file format') ||
        v.contains('unrecognized file format')) {
      return '无法识别视频格式：作品可能已下架，或地址需要登录后才能访问';
    }
    if (v.contains('failed to open') ||
        v.contains('cannot open') ||
        v.contains('could not open') ||
        v.contains('failed to initialize') ||
        v.contains('could not load')) {
      // 同一句里常带 HTTP 状态码，优先给更具体的中文。
      final status = _httpStatus(v);
      if (status != null) return status;
      return '无法打开视频源：地址可能已失效，或当前网络无法访问';
    }

    // ---- 解码 ----
    if (v.contains('could not create device') ||
        v.contains('failed to create device') ||
        v.contains('d3d11') ||
        v.contains('vaapi') ||
        v.contains('videotoolbox') ||
        v.contains('vdpau')) {
      return '无法初始化显卡解码设备：显卡或驱动不支持，已改用软件解码';
    }
    if (v.contains('error while decoding') ||
        v.contains('decoding failed') ||
        v.contains('could not decode') ||
        v.contains('failed to decode')) {
      return '视频解码失败：码流异常或当前解码器不支持';
    }
    if (v.contains('no video') || v.contains('doesn\'t have any video')) {
      return '该作品没有视频画面（可能是图文作品）';
    }

    // ---- HTTP 状态码 ----
    final status = _httpStatus(v);
    if (status != null) return status;

    // ---- 网络 ----
    if (v.contains('timed out') ||
        v.contains('timeout') ||
        v.contains('operation timed out')) {
      return '连接超时：网络不稳定或服务器长时间无响应';
    }
    if (v.contains('connection refused')) {
      return '服务器拒绝连接：端口未开放或被网络策略拦截';
    }
    if (v.contains('connection reset') ||
        v.contains('connection aborted') ||
        v.contains('broken pipe') ||
        v.contains('connection closed') ||
        v.contains('network is unreachable')) {
      return '网络连接被中断：请检查网络或代理后重试';
    }
    if (v.contains('failed host lookup') ||
        v.contains('name or service not known') ||
        v.contains('getaddrinfo') ||
        v.contains('no address associated')) {
      return '域名解析失败：请检查 DNS 或网络连接';
    }
    if (v.contains('certificate') ||
        v.contains('handshake') ||
        v.contains('tls') ||
        v.contains('ssl')) {
      return '安全连接失败：证书校验或加密握手异常';
    }
    if (v.contains('end of file') || v.contains('unexpected eof')) {
      return '视频数据不完整：下载可能被中断';
    }

    // ---- 本机资源 ----
    if (v.contains('no space left')) return '磁盘空间不足，无法写入缓存文件';
    if (v.contains('permission denied') || v.contains('access is denied')) {
      return '没有访问权限：请检查文件或目录权限';
    }
    if (v.contains('out of memory') || v.contains('not enough memory')) {
      return '内存不足，请关闭其他程序后重试';
    }
    if (v.contains('the system cannot find the path') ||
        v.contains('no such file or directory')) {
      return '文件不存在：路径可能已被移动或删除';
    }

    // 已经是中文的文案原样返回（很多上层已经把原因写清楚了）。
    if (_hasCjk(text)) return text;
    return null;
  }

  // ------------------------------------------------------------------ 内部

  static String? _fromTyped(Object error) {
    if (error is DouyinException) return _douyin(error);
    if (error is SocketException) {
      return '网络连接失败：请检查网络或代理设置后重试';
    }
    if (error is TimeoutException) {
      return '操作超时：网络不稳定或服务器长时间无响应';
    }
    if (error is HandshakeException) {
      return '安全连接失败：证书校验或加密握手异常';
    }
    if (error is HttpException) {
      return '网络请求失败：连接被中断或响应异常';
    }
    if (error is FormatException) {
      return '数据格式异常：返回内容不是预期的 JSON';
    }
    if (error is FileSystemException) {
      final path = error.path;
      final base = path == null || path.isEmpty
          ? '文件读写失败'
          : '文件读写失败：$path';
      final detail = translate(error.osError?.message ?? '');
      return detail == null ? base : '$base（$detail）';
    }
    return null;
  }

  /// 抖音接口异常：优先给出「登录态 / 风控 / 服务端错误码」这类可操作的中文。
  static String _douyin(DouyinException e) {
    final message = e.message.trim();
    final body = e.body ?? '';

    final code = RegExp(r'status_code\s*=\s*(\d+)').firstMatch(message)?.group(1);
    if (code != null) {
      return switch (code) {
        '8' => '登录态已失效，请重新登录后再试',
        '5' => '请求参数被服务端拒绝，请稍后重试',
        '2154' => '该操作被风控拦截，请先在浏览器里完成验证',
        _ => '服务端返回错误码 $code',
      };
    }

    final translated = translate(message);
    if (translated != null && !translated.startsWith('无法打开视频源')) {
      return e.statusCode == null ? translated : '$translated（HTTP ${e.statusCode}）';
    }
    if (body.isEmpty) {
      return '服务端返回空响应（通常是未登录或被风控拦截），请重新登录后再试';
    }
    if (_hasCjk(message)) {
      return e.statusCode == null ? message : '$message（HTTP ${e.statusCode}）';
    }
    return e.statusCode == null
        ? '请求失败：服务端返回异常响应'
        : '请求失败：服务端返回异常响应（HTTP ${e.statusCode}）';
  }

  /// 从文本里识别 HTTP 状态码并给出中文解释。
  static String? _httpStatus(String lower) {
    final match = RegExp(r'(?:http(?: error)?\s*|status(?: code)?\s*[:=]?\s*)(\d{3})\b')
        .firstMatch(lower);
    final code = match?.group(1) ?? _plainCode(lower);
    if (code == null) return null;
    return switch (code) {
      '400' => '请求被服务器拒绝（400），请稍后重试',
      '401' => '需要登录后才能访问（401），请先登录',
      '403' => '服务器拒绝访问（403）：可能需要登录，或视频地址已过期',
      '404' => '视频地址不存在（404）：作品可能已删除或下架',
      '408' => '服务器等待超时（408），请重试',
      '429' => '请求过于频繁（429），请稍后再试',
      '500' || '502' || '503' || '504' => '服务器暂时不可用（$code），请稍后重试',
      _ => null,
    };
  }

  /// `HTTP 403` 这种写法以外，还有裸的 `403 Forbidden`。
  static String? _plainCode(String lower) {
    final match = RegExp(r'\b(4\d{2}|5\d{2})\b(?=\s*(forbidden|not found|error)?)')
        .firstMatch(lower);
    if (match == null) return null;
    final code = match.group(1)!;
    const known = {'400', '401', '403', '404', '408', '429', '500', '502', '503', '504'};
    return known.contains(code) ? code : null;
  }

  static bool _hasCjk(String text) => RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
}
