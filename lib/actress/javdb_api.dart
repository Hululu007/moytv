// JavDB 接口演员库（2026-11-26 用户令接入）：AvPlay 逆向扒清
// 的 JavDB 官方 API 通道（API_MAP.md 第 1 节），作演员库模块
// 的一个在线信息源，与本地库 / who's / 123AV / PH 并列。
//
// 定位（用户定）：演员与作品信息源——JavDB 本身不给播放入
// 口，点开作品后播放走既定番号竞速模型（DetailScreen 的跨站
// 探活 + 在线线路区），本文件不造播放链。
//
// 实证程度（照 API_MAP 如实分级）：
// - 签名算法与盐、信封结构、Movie/Actor/Detail 的 JSON 字段
//   名、图片 XOR 解密、latest 路径：反编译逐字实证。
// - 其余路径为拼接（API_MAP 注明仅 3 条路径逐字命中）：
//   search=api/v2/search、详情=api/v1/movies/{id}、演员=
//   api/v1/actors[/{id}]——演员详情/作品路径未逐字证实。
// - 登录令牌（api/v1/sessions）需要用户自己的 JavDB 账号，
//   本批不收集账号：请求只带签名头，接口是否放行未验。
// - 本机出口连不上 jdforrepam.com：整条源未验（界面照标）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../content_http.dart';
import '../core_bridge.dart';
import '../models.dart';

const javdbApiBase = 'https://jdforrepam.com';

/// 写死盐（JavDbApiSignature，API_MAP 逐字实证）。
const _javdbSalt =
    '71cf27bb3c0bcdf207b64abecddc970098c7421ee7203b9cdae54478478a199e7d5a6e1a57691123c1a931c057842fb73ba3b3c83bcd69c17ccf174081e3d8aa';

/// jdSignature = {秒}.{固定串}.{MD5(秒 + 盐)}。
String javdbSignature(int timestampSeconds) {
  final digest = md5
      .convert(utf8.encode('$timestampSeconds$_javdbSalt'))
      .toString();
  return '$timestampSeconds.lpw6vgqzsp.$digest';
}

/// 封面/头像 XOR 解密（JavDbImageDecryptor 逐字实证）：字节
/// 不以 JPEG/PNG/GIF/WEBP 魔数开头即判定加密——首字节是钥
/// 匙，其余每字节与它异或，输出丢弃首字节。
Uint8List javdbDecryptImageBytes(Uint8List bytes) {
  if (bytes.length < 2) return bytes;
  if (_hasImageMagic(bytes)) return bytes;
  final key = bytes[0];
  final out = Uint8List(bytes.length - 1);
  for (var i = 1; i < bytes.length; i++) {
    out[i - 1] = bytes[i] ^ key;
  }
  return out;
}

/// 是不是 JavDB 图床的图（API_MAP 实证图床域名
/// c0.jdbstatic.com）：封面/头像/剧照都走它，字节带 XOR
/// 加密，显示必须走 JavdbImage 的解密路径（见
/// javdb_image.dart），普通网络图组件解不出。
bool javdbIsImageUrl(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host == 'jdbstatic.com' || host.endsWith('.jdbstatic.com');
}

bool _hasImageMagic(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return true; // JPEG
  }
  if (b.length >= 4 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return true; // PNG
  }
  if (b.length >= 4 &&
      b[0] == 0x47 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x38) {
    return true; // GIF
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return true; // WEBP (RIFF....WEBP)
  }
  return false;
}

/// 一部作品（JavDbApiMovie 字段名逐字实证，解析宽容：数值/
/// 字符串混型都收）。
class JavdbMovie {
  const JavdbMovie({
    required this.id,
    required this.number,
    required this.title,
    this.thumbUrl = '',
    this.coverUrl = '',
    this.durationSeconds = 0,
    this.releaseDate = '',
    this.hasCnsub = false,
    this.magnetsCount = 0,
    this.score = '',
  });

  final String id;
  final String number;
  final String title;
  final String thumbUrl;
  final String coverUrl;
  final int durationSeconds;
  final String releaseDate;
  final bool hasCnsub;
  final int magnetsCount;
  final String score;

  String get poster => coverUrl.isNotEmpty ? coverUrl : thumbUrl;

  factory JavdbMovie.fromJson(Map<String, dynamic> json) {
    return JavdbMovie(
      id: _javdbStr(json['id']),
      number: _javdbStr(json['number']),
      title: _javdbStr(json['title']),
      thumbUrl: _javdbStr(json['thumb_url']),
      coverUrl: _javdbStr(json['cover_url']),
      durationSeconds: _javdbInt(json['duration']),
      releaseDate: _javdbStr(json['release_date']),
      hasCnsub: _javdbBool(json['has_cnsub']),
      magnetsCount: _javdbInt(json['magnets_count']),
      score: _javdbStr(json['score']),
    );
  }
}

/// 一名演员（JavDbApiActor：id / name / avatar_url / gender）。
class JavdbActor {
  const JavdbActor({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.gender = -1,
  });

  final String id;
  final String name;
  final String avatarUrl;

  /// 性别原值（映射口径未证实，只存不译）。
  final int gender;

  factory JavdbActor.fromJson(Map<String, dynamic> json) {
    return JavdbActor(
      id: _javdbStr(json['id']),
      name: _javdbStr(json['name']),
      avatarUrl: _javdbStr(json['avatar_url']),
      gender: _javdbInt(json['gender'], fallback: -1),
    );
  }
}

/// 作品详情里能给详情页用的部分（JavDbApiMovieDetail）。
class JavdbMovieExtra {
  const JavdbMovieExtra({
    this.actors = const [],
    this.stills = const [],
    this.extraInfo = const [],
    this.score = '',
    this.scoreCount = 0,
  });

  final List<JavdbActor> actors;

  /// 预览图（preview_images 的 large_url）——详情页剧照真数据。
  final List<String> stills;

  /// (标签, 值)：导演/制作商/发行商/系列，只带接口真返回的。
  final List<(String, String)> extraInfo;

  /// 评分原值（接口 score 字段，字符串/数字照原样转文本）；
  /// 接口没给就是空，详情页信息卡不显示、不编。
  final String score;

  /// 评分人数：接口 score_count 优先，其次 reviews_count
  /// （AvPlay 详情模型只有 reviews_count 一个计数字段，配对
  /// 关系属推定，见 REPORT_actress_javdb_extra.md）；0 = 没给。
  final int scoreCount;
}

/// 评论一条（api/v1/movies/{id}/reviews，路径拼接推定）。
/// 字段照 AvPlay 反编译模型 JavDbApiReview 实证：username /
/// content / created_at / likes_count / score；头像模型里没有，
/// 只从 user 子对象或 avatar 类键名宽容兜底，没有就空、界面
/// 用昵称首字占位。
class JavdbReview {
  const JavdbReview({
    this.username = '',
    this.avatarUrl = '',
    this.content = '',
    this.createdAt = '',
    this.likes = 0,
    this.score = '',
  });

  final String username;
  final String avatarUrl;
  final String content;
  final String createdAt;
  final int likes;
  final String score;

  factory JavdbReview.fromJson(Map<String, dynamic> json) {
    var username = _javdbStr(json['username']);
    var avatar = _javdbStr(json['avatar_url']);
    if (avatar.isEmpty) avatar = _javdbStr(json['avatar']);
    final user = json['user'];
    if (user is Map<String, dynamic>) {
      if (username.isEmpty) username = _javdbStr(user['username']);
      if (username.isEmpty) username = _javdbStr(user['nickname']);
      if (username.isEmpty) username = _javdbStr(user['name']);
      if (avatar.isEmpty) avatar = _javdbStr(user['avatar_url']);
      if (avatar.isEmpty) avatar = _javdbStr(user['avatar']);
    }
    if (username.isEmpty) username = _javdbStr(json['nickname']);
    if (username.isEmpty) username = _javdbStr(json['name']);
    return JavdbReview(
      username: username,
      avatarUrl: avatar,
      content: _javdbStr(json['content']),
      createdAt: _javdbStr(json['created_at']),
      likes: _javdbInt(json['likes_count'], fallback: _javdbInt(json['likes'])),
      score: _javdbStr(json['score']),
    );
  }
}

/// hash 归一（照 jar 版 normHash）：磁力链接里抽 btih，只认
/// 40 位十六进制、转小写；认不出回空（这类条目排序时丢弃）。
String javdbNormHashOf(String raw) {
  var text = raw.trim();
  if (text.toLowerCase().startsWith('magnet:')) {
    final match = RegExp(
      r'xt=urn:btih:([0-9a-fA-F]{40})',
      caseSensitive: false,
    ).firstMatch(text);
    text = match?.group(1) ?? '';
  }
  return RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(text) ? text.toLowerCase() : '';
}

double _javdbNumOf(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return 0;
}

/// 磁力打分（照 jar 版 score() 逐项对照）：做种数（seeders/
/// seeds/heat/popularity 首个有值）×1e9 主导；中文字幕
/// （cnsub 标记或名含 中文字幕/中字/中文/chinese/chs/cht）
/// +1e7；高清（hd 标记或名含 2160p/4k/1080p/高清/hd）+1e6；
/// 大小在 500–8000 MB 区间 +1e5；日期（created_at/
/// release_date 的年月日拼数）×0.001；最后减 |大小MB-2500|
/// ×1e-6 当近似平局的微调。size 数字按 MB 读（与 jar 的
/// num(size) 同口径）。
double javdbMagnetScoreOf(Map<String, dynamic> json) {
  final seeders = _javdbNumOf(json, const [
    'seeders',
    'seeds',
    'heat',
    'popularity',
  ]);
  final name = _javdbStr(json['name']).toLowerCase();
  final cnsub =
      _javdbBool(json['cnsub']) ||
      name.contains('中文字幕') ||
      name.contains('中字') ||
      name.contains('中文') ||
      name.contains('chinese') ||
      name.contains('chs') ||
      name.contains('cht');
  final hd =
      _javdbBool(json['hd']) ||
      name.contains('2160p') ||
      name.contains('4k') ||
      name.contains('1080p') ||
      name.contains('高清') ||
      name.contains('hd');
  final sizeMb = _javdbNumOf(json, const ['size']);
  final sizeInRange = sizeMb >= 500 && sizeMb <= 8000;
  var dateValue = 0.0;
  final dateText = _javdbStr(json['created_at']).isNotEmpty
      ? _javdbStr(json['created_at'])
      : _javdbStr(json['release_date']);
  final dateMatch = RegExp(
    r'(20\d{2})[-/]?(\d{2})?[-/]?(\d{2})?',
  ).firstMatch(dateText);
  if (dateMatch != null) {
    dateValue =
        (int.parse(dateMatch.group(1)!) * 10000 +
                int.parse(dateMatch.group(2) ?? '0') * 100 +
                int.parse(dateMatch.group(3) ?? '0'))
            .toDouble();
  }
  return seeders * 1e9 +
      (cnsub ? 1e7 : 0) +
      (hd ? 1e6 : 0) +
      (sizeInRange ? 1e5 : 0) +
      dateValue * 0.001 -
      (sizeMb - 2500).abs() * 1e-6;
}

/// 磁力排序（照 jar 版 rankMagnets）：按 normHash 去重（同
/// hash 只留分高的一条，hash 认不出的条目丢弃），按分降序。
List<Map<String, dynamic>> javdbRankMagnetJsons(
  List<Map<String, dynamic>> items,
) {
  final byHash = <String, (Map<String, dynamic>, double)>{};
  for (final item in items) {
    // hash 候选键与 javdbMagnetLinkOf 的链接来源键一致：
    // hash 本体优先，其次现成磁力链接字段（normHash 从链
    // 里抽 btih）。jar 版只读 hash/url 两键，我们多容磁力
    // 键名变体，认不出的照样丢弃。
    var candidate = '';
    for (final key in const ['hash', 'magnet', 'magnet_url', 'url', 'link']) {
      final value = _javdbStr(item[key]);
      if (value.isNotEmpty) {
        candidate = value;
        break;
      }
    }
    final hash = javdbNormHashOf(candidate);
    if (hash.isEmpty) continue;
    final score = javdbMagnetScoreOf(item);
    final existing = byHash[hash];
    if (existing == null || score > existing.$2) {
      byHash[hash] = (item, score);
    }
  }
  final ranked = byHash.values.toList()
    ..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final entry in ranked) entry.$1];
}

/// 磁力一条 → 通用 MagnetLink（字段照 jar 版 magnets 实证：
/// hash/name/size（MB）/created_at/hd/cnsub；链接拼法照
/// jar 版 magnetUri：magnet:?xt=urn:btih:{hash}，有名时带
/// &dn={编码后的「[javdb.com]」+名}；url 字段已是现成磁力
/// 链接时照原样）。hash 与现成链接都拿不到回 null（不编）。
MagnetLink? javdbMagnetLinkOf(Map<String, dynamic> json) {
  var url = '';
  for (final key in const ['magnet', 'magnet_url', 'url', 'link']) {
    final value = _javdbStr(json[key]);
    if (value.startsWith('magnet:')) {
      url = value;
      break;
    }
  }
  final hash = _javdbStr(json['hash']);
  if (url.isEmpty) {
    if (hash.isEmpty) return null;
    url = 'magnet:?xt=urn:btih:$hash';
    final rawName = _javdbStr(json['name']);
    if (rawName.isNotEmpty) {
      final dn = rawName.startsWith('[javdb.com]')
          ? rawName
          : '[javdb.com]$rawName';
      url = '$url&dn=${Uri.encodeComponent(dn)}';
    }
  }
  var name = _javdbStr(json['name']);
  if (name.isEmpty) name = _javdbStr(json['title']);
  if (name.isEmpty) name = hash;
  return MagnetLink(
    name: name,
    url: url,
    sizeLabel: javdbSizeLabelOf(json['size']),
    quality: _javdbBool(json['hd']) ? 'HD' : '',
    date: javdbDateDigitsOf(
      _javdbStr(json['created_at']).isNotEmpty
          ? _javdbStr(json['created_at'])
          : _javdbStr(json['date']),
    ),
    tags: [if (_javdbBool(json['cnsub'])) '字幕'],
  );
}

/// size 字段转显示文本：数字按 MB（>=1024 换 GB，两位小数
/// 去尾零）；字符串照原样；其余回空。
String javdbSizeLabelOf(Object? size) {
  if (size is num) {
    final mb = size.toDouble();
    if (mb <= 0) return '';
    if (mb >= 1024) {
      var text = (mb / 1024).toStringAsFixed(2);
      if (text.contains('.')) {
        text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(
          RegExp(r'\.$'),
          '',
        );
      }
      return '$text GB';
    }
    return mb == mb.roundToDouble() ? '${mb.toInt()} MB' : '$mb MB';
  }
  return _javdbStr(size);
}

/// 日期文本归一成 YYYYMMDD（MagnetLink.metaLabel 只认 8 位
/// 数字日期再拼回 YYYY-MM-DD）：取开头的年月日数字，不像
/// 日期（不以 19/20 开头或不足 8 位）回空，不硬凑。
String javdbDateDigitsOf(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 8) return '';
  final head = digits.substring(0, 8);
  if (!head.startsWith('19') && !head.startsWith('20')) return '';
  return head;
}

String _javdbStr(Object? value) {
  if (value == null) return '';
  return value.toString().trim();
}

int _javdbInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _javdbBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().toLowerCase() ?? '';
  return text == 'true' || text == '1';
}

/// 可注入取数（测试用）：给 URL 回响应文本。
typedef JavdbFetch = Future<String> Function(String url);

/// JavDB API 客户端：每请求现算签名头；不带令牌（无账号）。
class JavdbApiClient {
  JavdbApiClient({JavdbFetch? fetch, ContentHttp? http})
    : _fetch = fetch,
      _http = http ?? ContentHttp();

  final JavdbFetch? _fetch;
  final ContentHttp _http;

  Map<String, String> _headers() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return {
      'jdSignature': javdbSignature(ts),
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36',
      'Accept': 'application/json',
    };
  }

  Future<dynamic> _getJson(String path) async {
    final url = '$javdbApiBase/$path';
    final String text;
    if (_fetch != null) {
      text = await _fetch(url);
    } else {
      text = await _http
          .get(url, headers: _headers())
          .timeout(const Duration(seconds: 25));
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw AppFailure('JavDB 接口返回异常，请稍后再试');
    }
    final success = decoded['success'];
    // 成功门：success 明确为真最稳；没给 success 字段时以
    // data 在场为准（jar 版 ZakaJavdbAmns 的 api() 就是只认
    // data 对象在场）；success 明确为假照旧拒绝。
    final ok =
        success == true ||
        success == 1 ||
        success?.toString().toLowerCase() == 'true' ||
        (success == null && decoded.containsKey('data'));
    if (!ok) {
      final message = _javdbStr(decoded['message']);
      throw AppFailure(message.isNotEmpty ? message : 'JavDB 接口拒绝了请求');
    }
    return decoded['data'];
  }

  /// 最新作品（路径逐字实证：api/v1/movies/latest）。
  Future<List<JavdbMovie>> latestMovies({int page = 1}) async {
    final data = await _getJson('api/v1/movies/latest?page=$page');
    return _movieListOf(data);
  }

  /// 搜索作品（api/v2/search，路径拼接、参数名 keyword 有串
  /// 实证；响应结构宽容解析）。
  Future<List<JavdbMovie>> searchMovies(String keyword, {int page = 1}) async {
    final q = Uri.encodeQueryComponent(keyword.trim());
    final data = await _getJson('api/v2/search?keyword=$q&page=$page');
    return _movieListOf(data);
  }

  /// 演员列表（api/v1/actors，路径拼接推定、未逐字证实）。
  Future<List<JavdbActor>> actors({int page = 1}) async {
    final data = await _getJson('api/v1/actors?page=$page');
    final list = _listOf(data, const ['actors', 'list', 'items']);
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) JavdbActor.fromJson(item),
    ];
  }

  /// 演员作品（api/v1/actors/{id} 详情里的 movies，或
  /// /movies 子路径——均未逐字证实，宽容解析两处）。
  Future<List<JavdbMovie>> actorMovies(String actorId, {int page = 1}) async {
    final data = await _getJson('api/v1/actors/$actorId?page=$page');
    return _movieListOf(data);
  }

  /// 作品详情补充（api/v1/movies/{id}，路径实证）：演员、剧
  /// 照（预览图）、导演/制作商等——只取接口真返回的。
  Future<JavdbMovieExtra> movieExtra(String movieId) async {
    final data = await _getJson('api/v1/movies/$movieId');
    if (data is! Map<String, dynamic>) return const JavdbMovieExtra();
    final actors = <JavdbActor>[];
    final rawActors = data['actors'];
    if (rawActors is List) {
      for (final item in rawActors) {
        if (item is Map<String, dynamic>) {
          actors.add(JavdbActor.fromJson(item));
        }
      }
    }
    final stills = <String>[];
    final rawImages = data['preview_images'];
    if (rawImages is List) {
      for (final item in rawImages) {
        if (item is Map<String, dynamic>) {
          final url = _javdbStr(item['large_url']);
          if (url.isNotEmpty) stills.add(url);
        } else if (item is String && item.isNotEmpty) {
          stills.add(item);
        }
      }
    }
    final extra = <(String, String)>[
      if (_javdbStr(data['director_name']).isNotEmpty)
        ('导演', _javdbStr(data['director_name'])),
      if (_javdbStr(data['maker_name']).isNotEmpty)
        ('制作商', _javdbStr(data['maker_name'])),
      if (_javdbStr(data['publisher_name']).isNotEmpty)
        ('发行商', _javdbStr(data['publisher_name'])),
      if (_javdbStr(data['series_name']).isNotEmpty)
        ('系列', _javdbStr(data['series_name'])),
    ];
    var scoreCount = _javdbInt(data['score_count']);
    if (scoreCount <= 0) scoreCount = _javdbInt(data['score_users']);
    if (scoreCount <= 0) scoreCount = _javdbInt(data['reviews_count']);
    return JavdbMovieExtra(
      actors: actors,
      stills: stills,
      extraInfo: extra,
      score: _javdbStr(data['score']),
      scoreCount: scoreCount,
    );
  }

  /// 磁力列表（GET api/v1/movies/{id}/magnets，路径与信封
  /// data.magnets 由 jar 版 ZakaJavdbAmns 原文实证，不再是
  /// 拼接推定；另宽容 list / items / 列表本体）。返回前照
  /// jar 版 rankMagnets 排序去重：第一条即自动离线该提交的
  /// 第一名。坏行跳过、拿不到回空表。
  Future<List<MagnetLink>> movieMagnets(String movieId) async {
    final data = await _getJson('api/v1/movies/$movieId/magnets');
    final list = _listOf(data, const ['magnets', 'list', 'items']);
    final raw = [
      for (final item in list)
        if (item is Map<String, dynamic>) item,
    ];
    return [
      for (final item in javdbRankMagnetJsons(raw))
        ?javdbMagnetLinkOf(item),
    ];
  }

  /// 评论列表（api/v1/movies/{id}/reviews，路径拼接推定）。
  /// 信封照 AvPlay 模型 JavDbApiReviewsData 的 {reviews:[...]}，
  /// 另宽容 list / items / 列表本体。拿不到回空表。
  Future<List<JavdbReview>> movieReviews(String movieId) async {
    final data = await _getJson('api/v1/movies/$movieId/reviews');
    final list = _listOf(data, const ['reviews', 'list', 'items']);
    final reviews = <JavdbReview>[];
    for (final item in list) {
      if (item is Map<String, dynamic>) {
        final review = JavdbReview.fromJson(item);
        if (review.content.isNotEmpty) reviews.add(review);
      }
    }
    return reviews;
  }

  List<JavdbMovie> _movieListOf(dynamic data) {
    final list = _listOf(data, const ['movies', 'list', 'items']);
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) JavdbMovie.fromJson(item),
    ];
  }

  /// data 可能是列表本体，或 {movies:[...]} / {actors:[...]}
  /// 等信封——都认，取不到回空表（不编数据）。
  List<dynamic> _listOf(dynamic data, List<String> keys) {
    if (data is List) return data;
    if (data is Map<String, dynamic>) {
      for (final key in keys) {
        final value = data[key];
        if (value is List) return value;
      }
    }
    return const [];
  }
}
