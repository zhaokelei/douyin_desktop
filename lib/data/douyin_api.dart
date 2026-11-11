// 抖音 Web 接口的纯 Dart 实现。
//
// 不依赖 WebView、不依赖 JS 引擎、不依赖 curl_cffi：
//   - 匿名引导：GET 首页拿 __ac_nonce，POST ttwid 注册接口拿 ttwid
//   - 签名：本地纯算 a_bogus（见 abogus.dart）
//   - 传输：dart:io HttpClient（三端一致）
//
// 接口常量与参数模板参考用户已授权的 DouYin_Spider（MIT）。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/diag.dart';
import '../core/platform_adapter.dart';
import 'abogus.dart';
import 'dtrait.dart';
import 'md5.dart';
import 'models.dart';

/// 请求头 UA：按平台匹配（取值见 [PlatformAdapter.userAgent]）。
/// 保留顶层变量名，调用点无需改动。
final String kDouyinUa = PlatformAdapter.userAgent;

class DouyinException implements Exception {
  DouyinException(this.message,
      {this.statusCode, this.body, this.needsVerify = false, this.verifyUrl});
  final String message;
  final int? statusCode;
  final String? body;

  /// true 表示服务端要求「人机验证 / 重新登录」这类需要用户介入的动作，
  /// 界面据此弹可见浏览器并把原操作重试一次。
  final bool needsVerify;

  /// 服务端给出的验证页面地址；为空时由调用方打开抖音网页。
  final String? verifyUrl;

  @override
  String toString() => 'DouyinException($message, status=$statusCode)';
}

/// 风控 / 验证类响应的统一判定结果。
class RiskSignal {
  const RiskSignal(this.needsVerify, this.reason, {this.verifyUrl});
  final bool needsVerify;
  final String reason;
  final String? verifyUrl;

  static const RiskSignal none = RiskSignal(false, '');
}

/// 需要用户介入的关键词（服务端有时只在 status_msg / body 里给中文提示）。
const List<String> _kVerifyKeywords = [
  '验证',
  '滑块',
  '人机',
  '安全校验',
  'captcha',
  'verify',
  'bdturing',
];

/// **唯一**的风控判定点：推荐流、详情、评论、点赞、收藏、发表评论、
/// 作者作品等所有响应最终都经过 [_decodeJson]，再落到这里。
///
/// 只在「失败响应」上判定，避免正常响应里的 `verifyFp` 等字段被误判：
///   - HTTP 403 / 412：风控网关直接拦截；
///   - `status_code=8`：会话未登录 / 已失效；
///   - `verify_*` / `captcha` / URL 字段、`status_msg` 含验证关键词；
///   - `x-vc-bdturing-parameters` / `x-tt-verify-passport-decision` 响应头。
RiskSignal classifyRiskResponse({
  required int httpStatus,
  required String body,
  required Map<String, String> headers,
}) {
  final bdturing = headers['x-vc-bdturing-parameters'] ?? '';
  final passport = headers['x-tt-verify-passport-decision'] ?? '';
  final bodyLower = body.toLowerCase();
  final bdturingUrl = _extractUrlFromParams(bdturing);

  Map<String, dynamic>? json;
  if (body.trimLeft().startsWith('{')) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // 非 JSON（例如 HTML 验证页）走关键词判定。
    }
  }
  final statusCode = json?['status_code'];
  final businessFailed = statusCode is int && statusCode != 0;
  final httpFailed = httpStatus != 200;
  final msg = '${json?['status_msg'] ?? ''} ${json?['message'] ?? ''}';
  final keyword = _kVerifyKeywords.firstWhere(
      (k) => bodyLower.contains(k) || msg.toLowerCase().contains(k),
      orElse: () => '');
  // 服务端偶尔直接返回 HTML 验证页（HTTP 200、非 JSON），也必须识别出来。
  final htmlVerifyPage = bodyLower.contains('<html') && keyword.isNotEmpty;
  if (!httpFailed && !businessFailed && !htmlVerifyPage) {
    return RiskSignal.none;
  }

  final url = _findVerifyUrl(json) ?? bdturingUrl;

  if (httpStatus == 403 || httpStatus == 412) {
    return RiskSignal(true, 'HTTP $httpStatus 风控拦截，需要完成人机验证',
        verifyUrl: url);
  }
  if (statusCode == 8) {
    return RiskSignal(true, '会话未登录或已失效（status_code=8）', verifyUrl: url);
  }
  if (json != null && url != null) {
    return RiskSignal(true, '服务端返回验证地址，需要完成验证', verifyUrl: url);
  }
  if (keyword.isNotEmpty) {
    return RiskSignal(true, '服务端要求完成验证（命中「$keyword」）', verifyUrl: url);
  }
  if (bdturing.isNotEmpty || passport.toLowerCase().contains('verify')) {
    return RiskSignal(true, '服务端要求人机验证（bdturing）', verifyUrl: url);
  }
  return RiskSignal.none;
}

/// 从响应 JSON 里找验证地址（顶层或一层 data 内，键名含 url/link）。
String? _findVerifyUrl(Object? node, [int depth = 0]) {
  if (depth > 4) return null;
  if (node is Map) {
    for (final entry in node.entries) {
      final key = entry.key.toString().toLowerCase();
      final value = entry.value;
      if (value is String &&
          value.startsWith('http') &&
          (key.contains('url') || key.contains('link'))) {
        return value;
      }
      final nested = _findVerifyUrl(value, depth + 1);
      if (nested != null) return nested;
    }
  } else if (node is List) {
    for (final item in node) {
      final nested = _findVerifyUrl(item, depth + 1);
      if (nested != null) return nested;
    }
  }
  return null;
}

/// bdturing 参数可能是 URL 编码的 JSON，也可能整段是 base64 的 JSON。
String? _extractUrlFromParams(String raw) {
  if (raw.isEmpty) return null;
  final candidates = <String>[raw];
  try {
    final decoded = Uri.decodeComponent(raw);
    if (decoded != raw) candidates.add(decoded);
  } catch (_) {}
  for (final text in candidates) {
    final direct = _findVerifyUrlInText(text);
    if (direct != null) return direct;
    try {
      final b64 = utf8.decode(base64Decode(text));
      final found = _findVerifyUrlInText(b64);
      if (found != null) return found;
    } catch (_) {}
  }
  final match = RegExp(r'https?://[^\s"\\]+').firstMatch(raw);
  return match?.group(0);
}

String? _findVerifyUrlInText(String text) {
  if (!text.trimLeft().startsWith('{') && !text.trimLeft().startsWith('[')) {
    return null;
  }
  try {
    return _findVerifyUrl(jsonDecode(text));
  } catch (_) {
    return null;
  }
}

/// 一个保持 Cookie 的抖音 Web 会话。
class DouyinApi {
  DouyinApi() {
    dtraitLogger = (message) => diag('dtrait', message);
  }

  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final AbogusSigner _signer = AbogusSigner();
  final Map<String, String> _cookies = <String, String>{};
  final Random _random = Random();

  bool _ready = false;
  String _webId = '';
  String _msToken = '';
  String _verifyFp = '';

  /// 接口基地址。自测时可用 DOUYIN_API_BASE 指向一个不存在的域名，
  /// 用来复现"网络断开 / 接口不可用"的异常路径。
  String get _base =>
      Platform.environment['DOUYIN_API_BASE'] ?? 'https://www.douyin.com';

  /// 供外部持久化用（不含敏感值日志）。
  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  /// 诊断用：能否从 Cookie 里解出 bd-ticket-guard 公钥。
  String? get debugReePublicKey => _reePublicKey();

  void restoreCookies(Map<String, String> saved) {
    _cookies
      ..clear()
      ..addAll(saved);
    _ready = false;
  }

  /// 存在才加载，返回 null 表示没找到文件（继续用匿名态）。
  Map<String, int>? loadCookieFileIfPresent() {
    final path = resolveCookiePath();
    if (path == null) return null;
    return loadCookieFile(path);
  }

  /// 所有会被查找的 cookie 路径（按优先级，含不存在的），用于界面提示。
  ///
  /// 双击启动时当前工作目录往往不是 exe 所在目录，所以这里单独列了 CWD，
  /// 并且从 exe 目录向上找 6 层（开发态 exe 在 build\windows\x64\runner\Release，
  /// cookie 却放在工程根，不向上找就永远读不到）。
  static List<String> cookieCandidatePaths() {
    final out = <String>[];
    final sep = Platform.pathSeparator;
    void add(String path) {
      if (path.isEmpty || out.contains(path)) return;
      out.add(path);
    }

    final env = Platform.environment['DOUYIN_COOKIES'];
    if (env != null && env.isNotEmpty) add(env);

    // 自己保存的会话放在稳定的用户数据目录，且优先级高于 exe 目录：
    // exe 目录在构建/升级时会被清掉，曾经就因此"重启后登录态消失"。
    final stable = stableCookiePath();
    if (stable != null) add(stable);

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    add('$exeDir${sep}douyin_cookies.json');
    add('${Directory.current.path}${sep}douyin_cookies.json');

    var dir = Directory(exeDir);
    for (var i = 0; i < 6; i++) {
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
      add('${dir.path}${sep}douyin_cookies.json');
    }

    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      add('$home${sep}douyin_cookies.json');
    }
    return out;
  }

  /// 稳定的用户数据目录（可写、不随构建产物被清理）。
  ///
  /// 具体路径由 [PlatformAdapter.appDataDir] 决定，三端各自遵循系统惯例。
  static String? stableDataDir() => PlatformAdapter.appDataDir;

  /// 自己保存 Cookie 的首选路径（与 [cookieCandidatePaths] 的第一项一致）。
  static String? stableCookiePath() {
    final dir = stableDataDir();
    return dir == null
        ? null
        : '$dir${Platform.pathSeparator}douyin_cookies.json';
  }

  static String? resolveCookiePath() {
    for (final path in cookieCandidatePaths()) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 当前是否带登录态（有 sessionid 即可认为已登录）。
  bool get isLoggedIn => (_cookies['sessionid'] ?? '').isNotEmpty;

  /// 从浏览器导出的 JSON 数组加载登录态 Cookie。
  ///
  /// 文件形如 [{domain, name, value, expirationDate(秒)}, ...]：
  ///   - 只保留 domain 含 douyin.com 的项
  ///   - 跳过空 name / 空 value / 已过期（expirationDate 为 -1 或缺失视为会话 Cookie，保留）
  ///   - 同名 Cookie 优先取 www.douyin.com（比 .douyin.com 更具体）
  ///
  /// 返回值只含字段名和长度，绝不返回值本身，便于安全打印。
  Map<String, int> loadCookieFile(String path) {
    final raw = File(path).readAsStringSync();
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final loaded = <String, int>{};
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // 不是 JSON：文件里存的可能就是 Cookie 请求头（`a=1; b=2`，可能带换行）。
      // 这种格式没有 domain/过期信息，按"用户主动导入"整串接收。
      final parsed = parseCookieInput(raw);
      if (parsed.isEmpty) {
        throw const FormatException('文件既不是 JSON，也没有 name=value 形式的 Cookie');
      }
      _cookies.addAll(parsed);
      for (final entry in parsed.entries) {
        loaded[entry.key] = entry.value.length;
      }
      _ready = false;
      return loaded;
    }
    // 兼容四种导出格式：
    //   1) 纯数组 [{domain,name,value,...}]（Chrome 扩展 / 浏览器导出）；
    //   2) {cookies:[...]}（Playwright 等）；
    //   3) 单条对象 {name,value,...}；
    //   4) 扁平 {name: value} 映射——桌面版（Python/Qt）导出的就是这个格式，
    //      两版共用 %APPDATA%\douyin_desktop\douyin_cookies.json 时必须认它，
    //      否则跨版本切换会显示"读到 0 项、未登录"。
    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map && decoded['cookies'] is List) {
      list = decoded['cookies'] as List;
    } else if (decoded is Map &&
        decoded['name'] != null &&
        decoded['value'] != null) {
      list = <dynamic>[decoded];
    } else if (decoded is Map) {
      list = <dynamic>[
        for (final e in decoded.entries)
          if (e.value is String && (e.value as String).isNotEmpty)
            <String, dynamic>{'name': '${e.key}', 'value': e.value}
      ];
    } else {
      list = const <dynamic>[];
    }

    for (final entry in list) {
      if (entry is! Map) continue;
      final domain = (entry['domain'] ?? '').toString();
      final name = (entry['name'] ?? '').toString().trim();
      final value = (entry['value'] ?? '').toString();
      // domain 为空说明导出工具没写域（例如只导 name/value），视为用户主动提供。
      if (domain.isNotEmpty && !domain.contains('douyin.com')) continue;
      if (name.isEmpty || value.isEmpty) continue;

      // Chrome/Edge 扩展导出用 expirationDate；Playwright 等导出用 expires（秒）。
      final exp = entry['expirationDate'] ?? entry['expires'] ?? entry['expiry'];
      if (exp is num && exp > 0 && exp.toInt() < nowSeconds) continue;

      // 同名项：www.douyin.com 覆盖 .douyin.com
      if (_cookies.containsKey(name) && !domain.startsWith('www.')) continue;
      _cookies[name] = value;
      loaded[name] = value.length;
    }
    _ready = false;
    return loaded;
  }

  /// 登录成功后直接热替换当前会话的 Cookie，不需要重启应用。
  void applyCookies(Map<String, String> cookies) {
    _cookies
      ..clear()
      ..addAll(cookies);
    _ready = false;
    _uidHash = null;
    _csrf = null;
    _dtraitSession = null;
  }

  /// 把 CDP 拿到的 cookie 列表写回磁盘（浏览器导出格式），返回写入路径。
  ///
  /// 首选 [stableDataDir]（用户数据目录，重启/重建都不会被清掉），
  /// 写不进去（例如只读挂载）才退到 exe 同目录。写入后立刻 stat 确认，
  /// 结果写进诊断日志，便于确认"到底有没有写成功"。
  String? saveCookieList(List<Map<String, dynamic>> cookies) {
    final entries = <Map<String, dynamic>>[];
    for (final c in cookies) {
      final domain = (c['domain'] ?? '').toString();
      final name = (c['name'] ?? '').toString();
      final value = (c['value'] ?? '').toString();
      if (!domain.contains('douyin.com') || name.isEmpty || value.isEmpty) {
        continue;
      }
      entries.add({
        'domain': domain,
        'name': name,
        'value': value,
        'expirationDate':
            (c['expires'] as num?)?.toDouble() ?? 0,
        'httpOnly': c['httpOnly'] == true,
        'secure': c['secure'] == true,
      });
    }
    if (entries.isEmpty) {
      diag('cookie', '保存失败：CDP 返回的列表里没有可用的 douyin.com Cookie');
      return null;
    }
    return _writeCookieJson(entries);
  }

  /// 把用户粘贴的 Cookie 请求头写回磁盘（转成 JSON 导出格式）。
  ///
  /// 粘贴导入原来只写 SharedPreferences，导致"重启后登录态消失"；
  /// 这里补上与扫码登录一致的落盘路径。
  String? saveCookieHeader(String header) {
    final parsed = parseCookieInput(header);
    if (parsed.isEmpty) {
      diag('cookie', '保存失败：粘贴内容解析不出 name=value');
      return null;
    }
    final entries = <Map<String, dynamic>>[];
    for (final entry in parsed.entries) {
      entries.add({
        'domain': 'www.douyin.com',
        'name': entry.key,
        'value': entry.value,
        'expirationDate': 0,
        'httpOnly': false,
        'secure': true,
      });
    }
    return _writeCookieJson(entries);
  }

  String? _writeCookieJson(List<Map<String, dynamic>> entries) {
    final json = const JsonEncoder.withIndent('  ').convert(entries);
    final sep = Platform.pathSeparator;
    final targets = <String>[
      if (stableCookiePath() != null) stableCookiePath()!,
      '${File(Platform.resolvedExecutable).parent.path}${sep}douyin_cookies.json',
    ];
    for (final path in targets) {
      try {
        final file = File(path);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(json);
        final stat = file.statSync();
        diag('cookie',
            '已写入 $path（${stat.size} 字节，exists=${file.existsSync()}，项数=${entries.length}）');
        return path;
      } catch (e) {
        diag('cookie', '写入 $path 失败：$e');
      }
    }
    diag('cookie', '所有候选路径都写入失败');
    return null;
  }

  /// 解析用户粘贴的 Cookie：支持
  ///   - 浏览器 Cookie 请求头：`a=1; b=2`
  ///   - JSON 数组/对象（扩展导出格式）
  static Map<String, String> parseCookieInput(String input) {
    final text = input.trim();
    final out = <String, String>{};
    if (text.isEmpty) return out;
    if (text.startsWith('[') || text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map && decoded['cookies'] is List) {
          for (final raw in decoded['cookies'] as List) {
            if (raw is! Map) continue;
            final name = (raw['name'] ?? '').toString().trim();
            final value = (raw['value'] ?? '').toString();
            if (name.isNotEmpty && value.isNotEmpty) out[name] = value;
          }
          return out;
        }
        if (decoded is Map && decoded['name'] == null) {
          // 扁平 {name: value} 映射（桌面版导出格式）。
          for (final e in decoded.entries) {
            final value = e.value;
            if (value is String && value.isNotEmpty) out['${e.key}'] = value;
          }
          return out;
        }
        final list = decoded is List ? decoded : <dynamic>[decoded];
        for (final raw in list) {
          if (raw is! Map) continue;
          final name = (raw['name'] ?? '').toString().trim();
          final value = (raw['value'] ?? '').toString();
          if (name.isNotEmpty && value.isNotEmpty) out[name] = value;
        }
        return out;
      } catch (_) {
        // 不是合法 JSON，按 header 继续解析。
      }
    }
    // 粘贴的请求头可能被换行拆开，先统一成 `;` 分隔。
    final headerText = text.replaceAll(RegExp(r'[\r\n]+'), ';');
    for (final part in headerText.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final name = part.substring(0, idx).trim();
      final value = part.substring(idx + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) out[name] = value;
    }
    return out;
  }

  /// 首次使用前调用：拿匿名 Cookie + 生成会话参数。
  Future<void> ensureReady() async {
    if (_ready) return;
    await _bootstrapCookies();
    _webId = _generateWebId();
    _msToken = _generateMsToken();
    _verifyFp = _generateVerifyFp();
    _ready = true;
  }

  Future<List<Map<String, dynamic>>> fetchFeed({int count = 10}) async {
    final body = await fetchFeedRaw({'count': '$count'});
    return _asList(body['aweme_list']);
  }

  /// 原始推荐流请求，便于探针尝试不同参数组合。
  Future<Map<String, dynamic>> fetchFeedRaw(Map<String, String> overrides) async {
    return _getJson('/aweme/v1/web/tab/feed/', {
      'refresh_index': '1',
      'is_non_personalized': '0',
      'publish_video_strategy_type': '2',
      ...overrides,
    });
  }

  Future<Map<String, dynamic>?> fetchDetail(String awemeId) async {
    final body = await _getJson('/aweme/v1/web/aweme/detail/', {
      'aweme_id': awemeId,
      'aid': '6383',
    });
    final detail = body['aweme_detail'];
    return detail is Map<String, dynamic> ? detail : null;
  }

  /// 必须登录态的接口：用来验证 Cookie 是否真的有效。
  Future<Map<String, dynamic>> fetchSelfProfile() async {
    return _getJson('/aweme/v1/web/user/profile/self/', const {},
        referer: 'https://www.douyin.com/user/self');
  }

  /// 验证后的**轻量只读确认**：只打一次推荐流（count=1），不碰写接口。
  ///
  /// 刻意不复用 [fetchFeed]，避免调用方把它当"加载更多"计数；
  /// 也刻意只请求一次，不做重试，避免加重风控。
  Future<bool> probeReadOnly() async {
    try {
      final body = await _getJson('/aweme/v1/web/tab/feed/', {
        'count': '1',
        'refresh_index': '1',
        'is_non_personalized': '0',
        'publish_video_strategy_type': '2',
      });
      final list = body['aweme_list'];
      final ok = list is List && list.isNotEmpty;
      diag('risk', '只读探测${ok ? "通过" : "未拿到数据"}');
      return ok;
    } catch (e) {
      diag('risk', '只读探测未通过: $e');
      return false;
    }
  }


  /// 作者主页作品列表。`max_cursor` 由上一次响应的 `max_cursor` 传入，
  /// `has_more=1` 表示还有下一页。
  ///
  /// 参数按真实抓包对齐（该接口有两条特殊约定）：
  ///   - `version_code=290100 / 29.1.0` 是这个接口自己的前端版本号，
  ///     用主站通用的 170400 会被风控拦下；
  ///   - `from_user_page=1` 表示"他人主页"，0 是本人主页。
  Future<Map<String, dynamic>> fetchUserPosts(String secUserId,
      {int maxCursor = 0, int count = 18}) async {
    return _getJson('/aweme/v1/web/aweme/post/', {
      'sec_user_id': secUserId,
      'max_cursor': '$maxCursor',
      'count': '$count',
      'locate_query': 'false',
      'show_live_replay_strategy': '1',
      'need_time_list': maxCursor == 0 ? '1' : '0',
      'time_list_query': '0',
      'whale_cut_token': '',
      'cut_version': '1',
      'publish_video_strategy_type': '2',
      'from_user_page': '1',
      'version_code': '290100',
      'version_name': '29.1.0',
    }, referer: 'https://www.douyin.com/user/$secUserId');
  }

  Future<Map<String, dynamic>> fetchComments(String awemeId,
      {int cursor = 0, int count = 20}) async {
    return _getJson('/aweme/v1/web/comment/list/', {
      // 这几个必须带，且空值字段也要发（浏览器实录如此）
      'aweme_id': awemeId,
      'cursor': '$cursor',
      'count': '$count',
      'item_type': '0',
      'whale_cut_token': '',
      'cut_version': '1',
      'rcFT': '',
      'publish_video_strategy_type': '2',
    }, referer: 'https://www.douyin.com/video/$awemeId');
  }

  /// 一级评论下的子回复（"展开 N 条回复"）。
  ///
  /// 该端点对 a_bogus 的校验最严，签名输入必须和浏览器逐字节一致：
  ///   - **不带 uifid**（签名里也不能有）；
  ///   - `verifyFp / fp` 放在 a_bogus **之后**，不参与签名；
  ///   - 公共参数用带平台指纹的那一组。
  Future<Map<String, dynamic>> fetchCommentReplies(
    String awemeId,
    String commentId, {
    int cursor = 0,
    int count = 5,
  }) async {
    await ensureReady();
    final params = <String, String>{
      'device_platform': 'webapp',
      'aid': '6383',
      'channel': 'channel_pc_web',
      'item_id': awemeId,
      'comment_id': commentId,
      'cut_version': '1',
      'cursor': '$cursor',
      'count': '$count',
      'item_type': '0',
      ..._baseParams(),
      'webid': _webId,
      'msToken': _msToken,
    };
    final query = _splice(params);
    final aBogus = _signer.signQuery(query, host: 'www.douyin.com');
    final url = '$_base/aweme/v1/web/comment/list/reply/?$query'
        '&a_bogus=${_quote(aBogus)}&verifyFp=$_verifyFp&fp=$_verifyFp';
    final resp = await _rawGet(url,
        referer: 'https://www.douyin.com/video/$awemeId');
    final text = await resp.transform(utf8.decoder).join();
    return _decodeJson(resp, text,
        path: '/aweme/v1/web/comment/list/reply/');
  }

  // ------------------------------------------------ 写接口（点赞 / 收藏）

  /// 点赞 / 取消点赞。返回是否真的成功（以 status_code=0 为准）。
  Future<bool> commitDigg(String awemeId, {required bool like}) async {
    final body = 'aweme_id=$awemeId&item_type=0&type=${like ? 1 : 0}';
    final json = await _postForm(
      '/aweme/v1/web/commit/item/digg/',
      body,
      referer: 'https://www.douyin.com/discover?modal_id=$awemeId',
      withUid: true,
    );
    return json['status_code'] == 0;
  }

  /// 收藏 / 取消收藏。
  Future<bool> commitCollect(String awemeId, {required bool collect}) async {
    final body =
        'action=${collect ? 1 : 0}&aweme_id=$awemeId&aweme_type=0';
    final json = await _postForm(
      '/aweme/v1/web/aweme/collect/',
      body,
      referer: 'https://www.douyin.com/?recommend=1',
      withUid: true,
    );
    return json['status_code'] == 0;
  }

  // ------------------------------------------------ 写接口（发表评论）

  /// 发表评论，或回复某条一级评论 / 某条子回复。
  ///
  /// 参数顺序照浏览器实录（该接口对 a_bogus 强校验）：
  ///   - 业务参数在最前面（app_name / enter_from / previous_page）；
  ///   - `round_trip_time=50`（不是其它接口通用的 0）；
  ///   - `verifyFp / fp` 在 `msToken` 之前，一起参与签名；
  ///   - `a_bogus` 之后只追加 `uid`（不参与签名）。
  /// body 的字段顺序同样照实录，签名用到的 body 与实际发送逐字节一致。
  Future<Map<String, dynamic>> publishComment(
    String awemeId,
    String text, {
    String? replyId,
    String? replyToReplyId,
    String textExtra = '[]',
  }) async {
    await ensureReady();
    final fp = PlatformAdapter.webFingerprint;
    final uifid = _cookies['UIFID'] ?? '';
    final query = _splice(<String, String>{
      'app_name': 'aweme',
      'enter_from': 'video_detail',
      'previous_page': 'video_detail',
      'device_platform': 'webapp',
      'aid': '6383',
      'channel': 'channel_pc_web',
      'pc_client_type': '1',
      'pc_libra_divert': fp['pc_libra_divert'] ?? 'Windows',
      'update_version_code': '170400',
      'support_h265': '1',
      'support_dash': '1',
      'version_code': '170400',
      'version_name': '17.4.0',
      'cookie_enabled': 'true',
      'screen_width': fp['screen_width'] ?? '1920',
      'screen_height': fp['screen_height'] ?? '1080',
      'browser_language': 'zh-CN',
      'browser_platform': fp['browser_platform'] ?? 'Win32',
      'browser_name': 'Chrome',
      'browser_version': '155.0.0.0',
      'browser_online': 'true',
      'engine_name': 'Blink',
      'engine_version': '155.0.0.0',
      'os_name': fp['os_name'] ?? 'Windows',
      'os_version': fp['os_version'] ?? '10',
      'cpu_core_num': '${Platform.numberOfProcessors}',
      'device_memory': '32',
      'platform': 'PC',
      'downlink': '10',
      'effective_type': '4g',
      'round_trip_time': '50',
      'webid': _webId,
      if (uifid.isNotEmpty) 'uifid': uifid,
      'verifyFp': _verifyFp,
      'fp': _verifyFp,
      'msToken': _msToken,
    });
    final body = _splice(<String, String>{
      'aweme_id': awemeId,
      if (replyId != null && replyId.isNotEmpty) 'reply_id': replyId,
      if (replyToReplyId != null && replyToReplyId.isNotEmpty)
        'reply_to_reply_id': replyToReplyId,
      'comment_send_celltime': '0',
      'comment_video_celltime': '0',
      'one_level_comment_rank': '-1',
      'paste_edit_method': 'non_paste',
      'text': text,
      'text_extra': textExtra,
    });
    final json = await _postForm(
      '/aweme/v1/web/comment/publish',
      body,
      referer: 'https://www.douyin.com/video/$awemeId',
      withUid: true,
      queryOverride: query,
    );
    diag(
        'publish',
        'status_code=${json['status_code']} cid=${asMap(json['comment'])['cid']} '
        'reply_id=${replyId ?? ""} textLen=${text.length}');
    return json;
  }

  /// 登录用户数字 ID 的 md5，写接口 query 末尾要带 `uid`（不参与签名）。
  String? _uidHash;

  Future<String> _resolveUidHash() async {
    if (_uidHash != null) return _uidHash!;
    try {
      final self = await fetchSelfProfile();
      final user = asMap(self['user']);
      final uid = (user['uid'] ?? '').toString();
      if (uid.isNotEmpty) _uidHash = md5Hex(uid);
    } catch (_) {
      // 拿不到就留空，接口会按无 uid 处理（可能被风控，日志里能看出来）。
    }
    return _uidHash ?? '';
  }

  /// `x-secsdk-csrf-token`：用 HEAD 请求向站点换取（与 csrf_session_id 绑定）。
  String? _csrf;
  Future<String?> _csrfToken() async {
    if (_csrf != null && _csrf!.isNotEmpty) return _csrf;
    try {
      final req = await _client
          .headUrl(Uri.parse('$_base/service/2/abtest_config/'));
      req.headers.set('x-secsdk-csrf-request', '1');
      req.headers.set('x-secsdk-csrf-version', '1.2.22');
      req.headers.set('referer', 'https://www.douyin.com/');
      req.headers.set('user-agent', kDouyinUa);
      req.headers.set('accept', '*/*');
      req.headers.set('accept-language', 'zh-CN,zh;q=0.9');
      if (_cookies.isNotEmpty) {
        req.headers.set('cookie',
            _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
      }
      final resp = await req.close();
      final raw = resp.headers.value('x-ware-csrf-token') ?? '';
      await resp.drain<void>();
      final parts = raw.split(',');
      if (parts.length > 1 && parts[1].isNotEmpty) _csrf = parts[1];
    } catch (e) {
      diag('api', '获取 csrf token 失败: $e');
    }
    return _csrf;
  }

  /// `x-tt-session-dtrait` 会话材料（同一次会话内复用，第二段按 path 重算）。
  DtraitSession? _dtraitSession;

  String? _dtraitHeader(String path) {
    try {
      _dtraitSession ??= DtraitSession.create();
      return _dtraitSession!.headerFor(path);
    } catch (e) {
      diag('dtrait', '生成 x-tt-session-dtrait 失败: $e');
      return null;
    }
  }

  /// 以表单方式 POST 写接口：签名里带 body，query 末尾追加 uid（不参与签名）。
  Future<Map<String, dynamic>> _postForm(
    String path,
    String body, {
    String? referer,
    bool withUid = false,
    String? queryOverride,
  }) async {
    await ensureReady();
    final params = <String, String>{
      ..._baseParams(),
      ...PlatformAdapter.webFingerprint,
      'pc_client_type': '1',
      'webid': _webId,
      if (_cookies['UIFID'] != null && _cookies['UIFID']!.isNotEmpty)
        'uifid': _cookies['UIFID']!,
      'verifyFp': _verifyFp,
      'fp': _verifyFp,
      'msToken': _msToken,
    };
    final query = queryOverride ?? _splice(params);
    final aBogus = _signer.signQuery(query, body: body, host: 'www.douyin.com');
    var url = '$_base$path?$query&a_bogus=${_quote(aBogus)}';
    if (withUid) {
      final uid = await _resolveUidHash();
      if (uid.isNotEmpty) url = '$url&uid=$uid';
    }
    final req = await _client.postUrl(Uri.parse(url));
    req.headers.set('user-agent', kDouyinUa);
    req.headers.set('referer', referer ?? 'https://www.douyin.com/');
    req.headers.set('origin', 'https://www.douyin.com');
    req.headers.set('accept', 'application/json, text/plain, */*');
    req.headers.set('accept-language', 'zh-CN,zh;q=0.9');
    req.headers.set('content-type',
        'application/x-www-form-urlencoded; charset=UTF-8');
    if (_cookies.isNotEmpty) {
      req.headers.set('cookie',
          _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    final csrf = await _csrfToken();
    if (csrf != null && csrf.isNotEmpty) {
      req.headers.set('x-secsdk-csrf-token', csrf);
    }
    final uifid = _cookies['UIFID'];
    if (uifid != null && uifid.isNotEmpty) req.headers.set('uifid', uifid);
    req.headers.set('bd-ticket-guard-version', '2');
    req.headers.set('bd-ticket-guard-web-version', '2');
    req.headers.set('bd-ticket-guard-web-sign-type', '0');
    final reeKey = _reePublicKey();
    if (reeKey != null) {
      req.headers.set('bd-ticket-guard-ree-public-key', reeKey);
    }
    // 写接口的风控头：缺它点赞等接口会直接 403（已用真实账号复现）。
    final dtrait = _dtraitHeader(path);
    if (dtrait != null) {
      req.headers.set('x-tt-session-dtrait', dtrait);
    }
    req.write(body);
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      // 风控拒绝时原因只在响应头里，body 往往是空的；这里把关键头记进日志，
      // 便于如实区分"人机验证 / 二次身份验证 / 纯签名失败"。
      String? header(String name) => resp.headers.value(name);
      diag('api',
          'POST $path HTTP ${resp.statusCode} '
          'logid=${header('x-tt-logid')} '
          'bdturing=${header('x-vc-bdturing-parameters')} '
          'passport=${header('x-tt-verify-passport-decision')}');
    }
    return _decodeJson(resp, text, path: path);
  }

  // ---------------- 内部 --------------

  Future<void> _bootstrapCookies() async {
    if (!_cookies.containsKey('ttwid')) {
      final home = await _rawGet('$_base/',
          accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
      _absorbSetCookie(home);
      home.drain<void>();
      if (!_cookies.containsKey('ttwid')) {
        await _registerTtwid();
      }
    }
  }

  // ------------------------------------------- x-secsdk-web-signature 签名

  /// SDK 里写死的参与签名的常量。
  static const String _secsdkConst = 'A96D855A08C0A9707F8BEF0D9A527E4E';

  /// 需要额外 x-secsdk-web-signature 的接口。
  /// 这里只放实测被 Argus 强校验的（其它接口保持原样，避免无谓改动）。
  static const Set<String> _secsdkPaths = {
    '/aweme/v1/web/aweme/post/',
  };

  bool _needsSecsdkSign(String path) => _secsdkPaths.contains(path);

  /// 生成 `timestamp` + `x-secsdk-web-signature` 的请求 URL。
  ///
  /// 算法（与 SDK 的 webSign 一致）：
  ///   md5(`${uifid}_${timestamp}_${常量}_${canonicalQuery}`)
  /// canonicalQuery 里 value 先 decode 再按 encodeURIComponent 重新编码，
  /// 并在末尾追加 `&timestamp=<秒级时间戳>`。
  String _secsdkSignedUrl(String path, String query) {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var signedQuery = _canonicalQuery(query);
    final hasUifid = signedQuery
        .split('&')
        .where((p) => p.isNotEmpty)
        .any((p) => p.split('=').first == 'uifid');
    final uifid = _cookies['UIFID'] ?? '';
    if (!hasUifid && uifid.isNotEmpty) {
      signedQuery = signedQuery.isEmpty
          ? 'uifid=${_encodeComponent(uifid)}'
          : '$signedQuery&uifid=${_encodeComponent(uifid)}';
    }
    signedQuery =
        signedQuery.isEmpty ? 'timestamp=$ts' : '$signedQuery&timestamp=$ts';
    var uifidValue = uifid;
    for (final pair in signedQuery.split('&')) {
      if (pair.startsWith('uifid=')) {
        uifidValue = Uri.decodeQueryComponent(pair.substring(6));
        break;
      }
    }
    final plain = '${uifidValue}_${ts}_${_secsdkConst}_$signedQuery';
    final sig = md5Hex(plain);
    return '$_base$path?$signedQuery&x-secsdk-web-signature=$sig';
  }

  /// key 只 decode；value decode 后按 encodeURIComponent 重编码。
  String _canonicalQuery(String query) {
    final parts = <String>[];
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final idx = pair.indexOf('=');
      final key = idx >= 0 ? pair.substring(0, idx) : pair;
      final value = idx >= 0 ? pair.substring(idx + 1) : '';
      parts.add('${Uri.decodeQueryComponent(key)}'
          '=${_encodeComponent(Uri.decodeQueryComponent(value))}');
    }
    return parts.join('&');
  }

  /// 等价 JS 的 `encodeURIComponent`（不编码 `A-Za-z0-9-_.!~*'()`）。
  static String _encodeComponent(String value) {
    const safe = "-_.!~*'()";
    final out = StringBuffer();
    for (final rune in value.runes) {
      final ch = String.fromCharCode(rune);
      final isAlnum = (rune >= 0x30 && rune <= 0x39) ||
          (rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A);
      if (isAlnum || safe.contains(ch)) {
        out.write(ch);
        continue;
      }
      for (final byte in utf8.encode(ch)) {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  Future<void> _registerTtwid() async {
    final req = await _client.postUrl(
        Uri.parse('https://ttwid.bytedance.com/ttwid/union/register/'));
    req.headers.set('user-agent', kDouyinUa);
    req.headers.set('content-type', 'application/json');
    req.write(jsonEncode({
      'region': 'cn',
      'aid': 1768,
      'needFid': false,
      'service': 'www.douyin.com',
      'migrate_info': {'ticket': '', 'source': 'node'},
      'cbUrlProtocol': 'https',
      'union': true,
    }));
    final resp = await req.close();
    _absorbSetCookie(resp);
    await resp.drain<void>();
  }

  Future<Map<String, dynamic>> _getJson(
      String path, Map<String, String> extra,
      {String? referer}) async {
    await ensureReady();
    final params = <String, String>{
      ..._baseParams(),
      ...extra,
      'webid': _webId,
      if (_cookies['UIFID'] != null && _cookies['UIFID']!.isNotEmpty)
        'uifid': _cookies['UIFID']!,
      'msToken': _msToken,
      'verifyFp': _verifyFp,
      'fp': _verifyFp,
    };
    final query = _splice(params);
    final aBogus = _signer.signQuery(query, host: 'www.douyin.com');
    final withBogus = '$query&a_bogus=${_quote(aBogus)}';
    // 作者作品等接口在 Argus 风控网关上有更严的策略（只带 a_bogus 会返回
    // 403 "Signature Not Found"），需要额外的 x-secsdk-web-signature。
    final uri = Uri.parse(_needsSecsdkSign(path)
        ? _secsdkSignedUrl(path, withBogus)
        : '$_base$path?$withBogus');

    final resp = await _rawGet(uri.toString(), referer: referer);
    final text = await resp.transform(utf8.decoder).join();
    return _decodeJson(resp, text, path: path);
  }

  /// 统一解析 JSON 响应：HTTP 非 200 / 空响应 / status_code≠0 都抛
  /// [DouyinException]，把服务端原话带给界面（风控拦截也能如实显示）。
  ///
  /// 这里也是**唯一**的风控判定入口：先跑 [classifyRiskResponse]，
  /// 命中就把异常标记成 [DouyinException.needsVerify] 并带上验证地址。
  Map<String, dynamic> _decodeJson(HttpClientResponse resp, String text,
      {String? path}) {
    final signal = classifyRiskResponse(
      httpStatus: resp.statusCode,
      body: text,
      headers: _lowercaseHeaders(resp.headers),
    );
    if (signal.needsVerify) {
      diag('risk',
          '${path ?? "?"} 命中风控: ${signal.reason} 验证地址=${signal.verifyUrl ?? "无"}');
      throw DouyinException(signal.reason,
          statusCode: resp.statusCode,
          body: text,
          needsVerify: true,
          verifyUrl: signal.verifyUrl);
    }
    if (resp.statusCode != 200) {
      throw DouyinException('HTTP ${resp.statusCode}',
          statusCode: resp.statusCode, body: text);
    }
    if (text.isEmpty) {
      throw DouyinException('服务端返回空响应（通常是游客态风控）', statusCode: 200);
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw DouyinException('响应不是 JSON 对象', statusCode: 200, body: text);
    }
    final code = decoded['status_code'];
    if (code is int && code != 0) {
      throw DouyinException('status_code=$code', statusCode: 200, body: text);
    }
    return decoded;
  }

  /// 响应头转小写 map（同名多条用逗号合并），供风控判定读取。
  static Map<String, String> _lowercaseHeaders(HttpHeaders headers) {
    final out = <String, String>{};
    headers.forEach((name, values) {
      out[name.toLowerCase()] = values.join(', ');
    });
    return out;
  }


  Future<HttpClientResponse> _rawGet(String url,
      {String accept = 'application/json, text/plain, */*',
      String? referer}) async {
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set('user-agent', kDouyinUa);
    req.headers.set('referer', referer ?? 'https://www.douyin.com/');
    req.headers.set('accept', accept);
    req.headers.set('accept-language', 'zh-CN,zh;q=0.9');
    if (_cookies.isNotEmpty) {
      req.headers.set('cookie',
          _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    final uifid = _cookies['UIFID'];
    if (uifid != null && uifid.isNotEmpty) {
      req.headers.set('uifid', uifid);
    }
    // 只读接口的 bd-ticket-guard 头（评论/收藏/关注列表要求）
    req.headers.set('bd-ticket-guard-version', '2');
    req.headers.set('bd-ticket-guard-web-version', '2');
    req.headers.set('bd-ticket-guard-web-sign-type', '0');
    final reeKey = _reePublicKey();
    if (reeKey != null) {
      req.headers.set('bd-ticket-guard-ree-public-key', reeKey);
    }
    return req.close();
  }

  /// bd_ticket_guard_client_data 里已经带着我们自己的 P-256 公钥，直接复用。
  String? _reePublicKey() {
    final raw = _cookies['bd_ticket_guard_client_data'];
    if (raw == null || raw.isEmpty) return null;
    try {
      final text = utf8.decode(base64Decode(Uri.decodeComponent(raw)));
      final map = jsonDecode(text) as Map<String, dynamic>;
      final key = map['bd-ticket-guard-ree-public-key'];
      return key is String && key.isNotEmpty ? key : null;
    } catch (_) {
      return null;
    }
  }

  void _absorbSetCookie(HttpClientResponse resp) {
    resp.headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final line in values) {
        final pair = line.split(';').first;
        final idx = pair.indexOf('=');
        if (idx <= 0) continue;
        final key = pair.substring(0, idx).trim();
        final value = pair.substring(idx + 1).trim();
        if (key.isNotEmpty && value.isNotEmpty) _cookies[key] = value;
      }
    });
  }

  Map<String, String> _baseParams() {
    return {
      'device_platform': 'webapp',
      'aid': '6383',
      'channel': 'channel_pc_web',
      'update_version_code': '170400',
      'pc_client_type': '1',
      // 平台相关：分辨率 / 系统标识 / 浏览器平台统一走适配层，保证三端自洽。
      ...PlatformAdapter.webFingerprint,
      'support_h265': '1',
      'support_dash': '1',
      'cpu_core_num': '${Platform.numberOfProcessors}',
      'version_code': '170400',
      'version_name': '17.4.0',
      'cookie_enabled': 'true',
      'browser_language': 'zh-CN',
      'browser_name': 'Chrome',
      'browser_version': '155.0.0.0',
      'browser_online': 'true',
      'engine_name': 'Blink',
      'engine_version': '155.0.0.0',
      'device_memory': '32',
      'platform': 'PC',
      'downlink': '10',
      'effective_type': '4g',
      'round_trip_time': '0',
    };
  }

  /// 诊断用：直接打任意 web 接口，便于定位风控/签名问题（不参与正式流程）。
  Future<Map<String, dynamic>> debugGet(String path, Map<String, String> extra,
          {String? referer}) =>
      _getJson(path, extra, referer: referer);

  /// 诊断用：写接口 query 里要带的 uid=md5(数字用户ID)。
  Future<String> debugUidHash() => _resolveUidHash();

  /// 与 Python 的 quote(safe='') 完全一致：空格 %20、斜杠 %2F、加号 %2B。
  static String _quote(String s) {
    final allowed = RegExp(r'[A-Za-z0-9_.\-~]');
    final out = StringBuffer();
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      if (allowed.hasMatch(ch)) {
        out.write(ch);
      } else {
        for (final b in utf8Bytes(ch)) {
          out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        }
      }
    }
    return out.toString();
  }

  static String _splice(Map<String, String> params) => params.entries
      .map((e) => '${e.key}=${_quote(e.value)}')
      .join('&');

  String _generateWebId() {
    // 19 位、以 7 开头，与真实 user_unique_id 形态一致。
    final buf = StringBuffer('7');
    for (var i = 0; i < 18; i++) {
      buf.write(_random.nextInt(10));
    }
    return buf.toString();
  }

  String _generateMsToken() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final buf = StringBuffer();
    for (var i = 0; i < 107; i++) {
      buf.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return '${buf.toString()}==';
  }

  String _generateVerifyFp() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    String seg(int n) => List<String>.generate(
        n, (_) => chars[_random.nextInt(chars.length)]).join();
    return 'verify_${seg(8)}_${seg(8)}_${seg(4)}_${seg(4)}_${seg(8)}_${seg(12)}';
  }

  static List<Map<String, dynamic>> _asList(dynamic v) {
    if (v is! List) return const [];
    return [
      for (final item in v)
        if (item is Map<String, dynamic>) item,
    ];
  }
}
