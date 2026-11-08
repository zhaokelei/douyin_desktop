import 'dart:convert';

Map<String, dynamic> asMap(dynamic v) =>
    v is Map<String, dynamic> ? v : const <String, dynamic>{};

List<dynamic> asList(dynamic v) => v is List ? v : const <dynamic>[];

int asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String firstUrl(dynamic urlHolder) {
  final holder = asMap(urlHolder);
  for (final key in ['url_list', 'urlList']) {
    final list = asList(holder[key]);
    for (final item in list) {
      if (item is String && item.isNotEmpty) return item;
    }
  }
  return '';
}

/// 抖音的播放地址给的是多 CDN 候选：
/// `*-prime.douyinvod.com`（policy=4 / ply_type=4）在游客态会被 CDN 直接 403，
/// 而 `www.douyin.com/aweme/v1/play/` 这个入口实测可播（206 有真实字节）。
String playableUrl(dynamic urlHolder) {
  final holder = asMap(urlHolder);
  final candidates = <String>[];
  for (final key in ['url_list', 'urlList']) {
    for (final item in asList(holder[key])) {
      if (item is String && item.isNotEmpty) candidates.add(item);
    }
  }
  for (final candidate in candidates) {
    final host = Uri.tryParse(candidate)?.host ?? '';
    if (host == 'www.douyin.com' || host.endsWith('.douyin.com')) return candidate;
  }
  return candidates.isEmpty ? '' : candidates.first;
}

/// 一个可选清晰度档位，来自作品里的 `video.bit_rate` 数组。
///
/// 不同作品的档位数量/名称并不一致（有的只有 720P，有的有 1080P），
/// 因此界面必须按接口实际返回的列表生成，不能写死档位。
class VideoVariant {
  const VideoVariant({
    required this.label,
    required this.url,
    required this.bitRate,
    required this.height,
    this.qualityType = 0,
  });

  /// 展示标签，如 `1080P` / `720P`；识别不出高度时退回 gear 原始名。
  final String label;
  final String url;

  /// 码率（bps），用于"高度未知时取中位档"以及同高度去重。
  final int bitRate;

  /// 档位视频高度（像素）；0 表示接口没给。
  final int height;

  /// 抖音内部清晰度枚举（不同版本取值不同，仅用于诊断）。
  final int qualityType;
}

/// 从 `video.bit_rate` 解析全部可选档位。
///
/// 同一高度可能出现多条（不同编码/码率），保留码率最高的那条；
/// 主地址 `play_addr` 不在数组里时，用作品自身分辨率补一个兜底档。
List<VideoVariant> variantsFromVideo(Map<String, dynamic> video) {
  final out = <VideoVariant>[];
  for (final raw in asList(video['bit_rate'])) {
    final m = asMap(raw);
    final url = playableUrl(m['play_addr']);
    if (url.isEmpty) continue;
    final gear = (m['gear_name'] ?? '').toString();
    final height = _heightFromGear(gear) ?? asInt(m['height']);
    final label = height > 0
        ? '${height}P'
        : (gear.toLowerCase().contains('adapt')
            ? '自适应'
            : (gear.isEmpty ? '标准' : gear));
    out.add(VideoVariant(
      label: label,
      url: url,
      bitRate: asInt(m['bit_rate']),
      height: height,
      qualityType: asInt(m['quality_type']),
    ));
  }
  final dedup = <String, VideoVariant>{};
  for (final v in out) {
    final old = dedup[v.label];
    if (old == null || v.bitRate > old.bitRate) dedup[v.label] = v;
  }

  final result = dedup.values.toList()
    ..sort((a, b) => a.height.compareTo(b.height));
  if (result.isEmpty) {
    final url = playableUrl(video['play_addr']);
    if (url.isNotEmpty) {
      final h = asInt(video['height']);
      result.add(VideoVariant(
        label: h > 0 ? '${h}P' : '标准',
        url: url,
        bitRate: 0,
        height: h,
      ));
    }
  }
  return result;
}

int? _heightFromGear(String gear) {
  final m = RegExp(r'(2160|1440|1080|960|720|540|480|360)').firstMatch(gear);
  return m == null ? null : int.parse(m.group(1)!);
}

/// 档位标签换算成像素高度（4K→2160、1080P→1080）；识别不出来返回 null。
int? heightOfQualityLabel(String label) {
  if (label.toUpperCase().contains('4K')) return 2160;
  final m = RegExp(r'(2160|1440|1080|960|720|540|480|360)').firstMatch(label);
  return m == null ? null : int.parse(m.group(1)!);
}

/// 把用户选中的档位当「上限」挑档（用于切换视频后重新选档）。
///
/// - 当前作品存在同名档：直接用；
/// - 否则取 ≤ 上限高度的最高一档（4K 上限遇到 1080P 作品 → 1080P）；
/// - 所有档都高于上限：取最低档（尽量接近上限）；
/// - 标签换算不出高度（如"标准"）：返回 null，由调用方回退到自动档逻辑。
VideoVariant? pickVariantUnderCap(List<VideoVariant> variants, String pref) {
  for (final v in variants) {
    if (v.label == pref) return v;
  }
  final cap = heightOfQualityLabel(pref);
  if (cap == null) return null;
  final byHeight = variants.where((v) => v.height > 0).toList()
    ..sort((a, b) => a.height.compareTo(b.height));
  final below = byHeight.where((v) => v.height <= cap).toList();
  if (below.isNotEmpty) return below.last;
  if (byHeight.isNotEmpty) return byHeight.first;
  return null;
}

/// 首页推荐流的单条作品。
class AwemeItem {
  const AwemeItem({
    required this.id,
    required this.desc,
    required this.author,
    required this.coverUrl,
    required this.playUrl,
    required this.diggCount,
    required this.commentCount,
    required this.shareCount,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.isImage,
    this.collectCount = 0,
    this.createTime = 0,
    this.musicTitle = '',
    this.mixName = '',
    this.mixIsLast = false,
    this.playCount = 0,
    this.variants = const [],
    this.userDigged = false,
    this.isCollected = false,
  });

  final String id;
  final String desc;
  final Author author;
  final String coverUrl;
  final String playUrl;
  final int diggCount;
  final int commentCount;
  final int shareCount;
  final int durationMs;
  final int width;
  final int height;
  final bool isImage;

  /// 收藏数（网页版右侧竖栏的"收藏"）。
  final int collectCount;

  /// 发布时间（Unix 秒），用于左下角"1天前"。
  final int createTime;

  /// 背景音乐名。
  final String musicTitle;

  /// 合集名（有合集时才非空）。
  final String mixName;

  /// 是否合集的最后一集（"已是最新集"）。
  final bool mixIsLast;

  /// 播放量。
  final int playCount;

  /// 可选清晰度档位（按接口实际返回生成，可能只有一档）。
  final List<VideoVariant> variants;

  /// 当前登录用户是否已点赞 / 已收藏（接口会带，游客态为 false）。
  final bool userDigged;
  final bool isCollected;

  static AwemeItem? fromJson(Map<String, dynamic> json) {
    final id = (json['aweme_id'] ?? '').toString();
    if (id.isEmpty) return null;

    final video = asMap(json['video']);
    final author = Author.fromJson(asMap(json['author']));
    final statistics = asMap(json['statistics']);

    final cover = firstUrl(video['cover']).isNotEmpty
        ? firstUrl(video['cover'])
        : firstUrl(video['origin_cover']);

    final play = playableUrl(video['play_addr']);
    final images = asList(json['images']);
    final isImage = images.isNotEmpty;

    if (play.isEmpty && !isImage) return null;

    final mixInfo = asMap(json['mix_info']);
    final music = asMap(json['music']);

    return AwemeItem(
      id: id,
      desc: (json['desc'] ?? '').toString(),
      author: author,
      coverUrl: cover,
      playUrl: play,
      diggCount: asInt(statistics['digg_count']),
      commentCount: asInt(statistics['comment_count']),
      shareCount: asInt(statistics['share_count']),
      durationMs: asInt(video['duration']),
      width: asInt(video['width']),
      height: asInt(video['height']),
      isImage: isImage,
      collectCount: asInt(statistics['collect_count']),
      createTime: asInt(json['create_time']),
      musicTitle: (music['title'] ?? '').toString(),
      mixName: (mixInfo['mix_name'] ?? '').toString(),
      mixIsLast: asInt(mixInfo['statis']) > 0 && asInt(mixInfo['statis']) == 1,
      playCount: asInt(statistics['play_count']),
      variants: variantsFromVideo(video),
      userDigged: asInt(json['user_digged']) == 1,
      isCollected: asInt(json['is_collected'] ?? json['is_collect']) == 1,
    );
  }

  /// 从推荐流响应中抽出作品。响应里可能混有直播、广告、挑战等非作品条目。
  static List<AwemeItem> listFromFeedResponse(String body) {
    final decoded = jsonDecode(body);
    final root = asMap(decoded);
    final data = asList(root['data'] ?? root['aweme_list']);
    final out = <AwemeItem>[];
    for (final raw in data) {
      final item = fromJson(asMap(raw));
      if (item != null) out.add(item);
    }
    return out;
  }
}

class Author {
  const Author({
    required this.nickname,
    required this.avatarUrl,
    this.secUid = '',
  });

  final String nickname;
  final String avatarUrl;

  /// 作者唯一 ID（`sec_uid`），作者主页接口必须带；为空说明接口没返回，
  /// 此时界面上的"TA的作品"入口会给出明确提示而不是空列表。
  final String secUid;

  static Author fromJson(Map<String, dynamic> json) {
    final avatar = firstUrl(json['avatar_thumb']);
    return Author(
      nickname: (json['nickname'] ?? '抖音用户').toString(),
      avatarUrl: avatar.isNotEmpty
          ? avatar
          : firstUrl(json['avatar_larger']).isNotEmpty
              ? firstUrl(json['avatar_larger'])
              : firstUrl(json['avatar_medium']),
      secUid: (json['sec_uid'] ?? '').toString(),
    );
  }
}

class CommentImage {
  const CommentImage({required this.url, required this.thumb, this.width = 0, this.height = 0});

  final String url;
  final String thumb;
  final int width;
  final int height;

  static CommentImage? fromJson(Map<String, dynamic> json) {
    final origin = firstUrl(json['origin_url']);
    final thumb = firstUrl(json['thumb_url']);
    final url = origin.isNotEmpty ? origin : thumb;
    if (url.isEmpty) return null;
    return CommentImage(
      url: url,
      thumb: thumb.isNotEmpty ? thumb : url,
      width: asInt(json['width']),
      height: asInt(json['height']),
    );
  }
}

/// 只读评论。demo 不做回复、点赞、发表。
class CommentItem {
  const CommentItem({
    required this.cid,
    required this.text,
    required this.userName,
    required this.avatarUrl,
    required this.diggCount,
    required this.images,
    this.createTime = 0,
    this.ipLabel = '',
    this.replyTotal = 0,
    this.isAuthor = false,
  });

  final String cid;
  final String text;
  final String userName;
  final String avatarUrl;
  final int diggCount;
  final List<CommentImage> images;

  /// 评论时间（Unix 秒），用于"3天前"。
  final int createTime;

  /// IP 归属地，网页版显示为"· 广东"。
  final String ipLabel;

  /// 子评论条数（"展开 N 条回复"）。
  final int replyTotal;

  /// 是否为视频作者本人评论。
  final bool isAuthor;

  static CommentItem? fromJson(Map<String, dynamic> json) {
    final cid = (json['cid'] ?? '').toString();
    if (cid.isEmpty) return null;

    final user = asMap(json['user']);

    final images = <CommentImage>[];
    for (final raw in asList(json['image_list'])) {
      final img = CommentImage.fromJson(asMap(raw));
      if (img != null) images.add(img);
    }
    if (images.isEmpty) {
      // 部分版本把评论图放在 comment_image / sticker 里，做一次兜底。
      final single = CommentImage.fromJson(asMap(json['comment_image']));
      if (single != null) images.add(single);
    }

    return CommentItem(
      cid: cid,
      text: (json['text'] ?? '').toString(),
      userName: (user['nickname'] ?? '用户').toString(),
      avatarUrl: firstUrl(user['avatar_thumb']),
      diggCount: asInt(json['digg_count']),
      images: images,
      createTime: asInt(json['create_time']),
      ipLabel: (json['ip_label'] ?? '').toString(),
      replyTotal: asInt(json['reply_comment_total']),
      isAuthor: json['is_author'] == true || asInt(json['is_author']) == 1,
    );
  }

  static List<CommentItem> listFromResponse(String body) {
    final decoded = jsonDecode(body);
    final root = asMap(decoded);
    final data = asList(root['comments']);
    final out = <CommentItem>[];
    for (final raw in data) {
      final item = fromJson(asMap(raw));
      if (item != null) out.add(item);
    }
    return out;
  }
}
