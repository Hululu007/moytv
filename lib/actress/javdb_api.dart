// JavDB 接口演员库（2026-11-26 用户令接入）：AvPlay 逆向扒清
// 的 JavDB 官方 API 通道（API_MAP.md 第 1 节），作演员库模块
// 的一个在线信息源，与本地库 / who's / 123AV / PH 并列。
//
// 定位（用户定）：演员与作品信息源——JavDB 本身不给播放入
// 口，点开作品后播放走既定番号竞速模型（DetailScreen 的跨站
// 探活 + 在线线路区），本文件不造播放链。
//
// 实证程度（照 API_MAP 与 jar 版 ZakaJavdbAmns 原文分级）：
// - 2026-11-27 对齐 jar 版已验证路线（用户手机实报三件后）：
//   ①API 域名以 jar 版的 apidd.spthgb.com 为主（AvPlay 的
//   jdforrepam.com 留作网络失败时的兜底）；②先 POST
//   api/v1/sessions 登录换令牌（字段照 jar 版常量，base85
//   编码存放、运行时解码），请求带 Authorization，信封
//   success≠1 就清令牌重登重试一次（jar 版 api() 原逻辑）；
//   ③签名头名全小写 jdsignature、UA 照 jar 版 Dart/3.5；
//   ④详情走 api/v4/movies/{id} 取 data.movie（旧 v1 详情本
//   机实测 404、v4 无令牌回 JWTVerificationError，两头都拿
//   不到——这是详情页海报/剧照/演员缺失的根因之一）；
//   ⑤女优作品没有 API：网页通道 /actors/{id} 镜像轮换 +
//   parseWebCards 正则（jar 版逐字移植，本机实测 javdb.pw
//   可通、解析出 40 卡）。jar 版还有过盾/中继两级兜底，壳内
//   没有等价接口，本客户端只做镜像轮换、报告里已注明。
// - 演员列表：GET api/v1/actors?type=0&page=N，type 必传
//   （漏传服务端回「参数不能为空: type」，即用户 22:43 实
//   报的报错）；信封 data.actors、字段 id/name/name_zht/
//   videos_count 照 jar 版原文。搜索参数名同样照 jar 版为 q。
// - duration 字段单位是分钟（本机实测 latest 列表 ADN-821
//   回 150、MGNL-199 回 63——按秒解则正片只有 2~3 分钟，
//   与用户实报详情页「长度 3 分钟」的错误形态互证）。
// - 图片：tp.spfcas.com 与 c0.jdbstatic.com 的字节同为 XOR
//   加密（2026-11-27 实测 spfcas 封面首字节异或后正是 JPEG
//   魔数）；拉图带 Referer（jar 版 picProxy 口径）。
// - 本机出口时通时断：latest/actors GET 与 javdb.pw 网页通
//   道实测通过；登录 POST 与 v4 详情在本机未跑通（整波超
//   时），按 jar 版实证实现、手机终验为准（界面照标未验）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../content_http.dart';
import '../core_bridge.dart';
import '../models.dart';

/// API 主域名：jar 版 ZakaJavdbAmns 的 BASE_URL（已验证能
/// 跑的路线，2026-11-27 对齐）。
const javdbApiBase = 'https://apidd.spthgb.com';

/// API 兜底域名：AvPlay 的接口域名。本机实测它对免登录的
/// latest/actors 也放行；主域名网络层失败（连不上/超时）时
/// 客户端自动切过来重试，登录令牌与域名绑定、切换即重登。
const javdbApiBaseFallback = 'https://jdforrepam.com';

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

/// base85 解码（jar 版 ZakaJavdbAmns 的 b85decode 逐字移植：
/// 字母表 0-9A-Za-z + 标点；不在表里的字符跳过；每 5 字符
/// 还原 4 字节，尾组 n 字符还原 n-1 字节、缺位按 84 补）。
const _javdbB85Alphabet =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    '!#\$%&()*+-;<=>?@^_`{|}~';

String javdbB85Decode(String encoded) {
  final values = <int>[];
  for (final unit in encoded.codeUnits) {
    if (unit >= 128) continue;
    final index = _javdbB85Alphabet.indexOf(String.fromCharCode(unit));
    if (index >= 0) values.add(index);
  }
  final bytes = <int>[];
  for (var i = 0; i < values.length; i += 5) {
    final take = values.length - i >= 5 ? 5 : values.length - i;
    var value = 0;
    for (var j = 0; j < 5; j++) {
      value = value * 85 + (j < take ? values[i + j] : 84);
    }
    final group = [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
    bytes.addAll(take == 5 ? group : group.sublist(0, take - 1));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// 登录字段（jar 版 LOGIN_FIELDS_B85 原文照抄，值是 base85
/// 编码、运行时才解码；明文不落任何文件/日志）。
const _javdbLoginFieldsB85 = <(String, String)>[
  ('username', 'Y;1XTW@T<?HZVCrXKi6=Y%XJOZ2'),
  ('password', 'ad%~MG&3?W'),
  ('device_uuid', 'H#lQuFgY<aEjKYRWi2&0GBhn=FfuePHDWn2VmLNsIWRJ2'),
  ('device_name', 'N;WVyMg'),
  ('device_model', 'Ol59wc5g3CWo~bFZy;1cElM^pHbw'),
];

/// 登录固定字段（jar 版 login() 原文）。
const _javdbLoginFixedFields = <(String, String)>[
  ('platform', 'android'),
  ('system_version', '11'),
  ('app_channel', 'official'),
  ('app_version', 'official'),
  ('app_version_number', '1.9.35'),
];

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

/// 是不是 JavDB 图床的图：封面/头像/剧照走 c0.jdbstatic.com
/// 与 tp.spfcas.com 两家（API 列表的 thumb_url/cover_url/
/// preview_images 都在 spfcas 上），字节同带 XOR 加密，显示
/// 必须走 JavdbImage 的解密路径（见 javdb_image.dart），普
/// 通网络图组件解不出。此前只认 jdbstatic，spfcas 的封面在
/// 详情页落到通用封面链解不出、只剩占位图（2026-11-27 用户
/// 实报详情页无海报的根因之一，本机实测 spfcas 封面字节首
/// 字节异或后正是 JPEG 魔数）。
bool javdbIsImageUrl(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host == 'jdbstatic.com' ||
      host.endsWith('.jdbstatic.com') ||
      host == 'spfcas.com' ||
      host.endsWith('.spfcas.com');
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
    this.durationMinutes = 0,
    this.releaseDate = '',
    this.hasCnsub = false,
    this.magnetsCount = 0,
    this.score = '',
    this.previewImages = const [],
  });

  final String id;
  final String number;
  final String title;
  final String thumbUrl;
  final String coverUrl;

  /// 时长（分钟）：接口 duration 字段就是分钟（2026-11-27
  /// 实测互证，见文件头）。旧实现误当秒再除以 60 显示，正
  /// 片只剩「3 分钟」——用户实报的错误形态。
  final int durationMinutes;
  final String releaseDate;
  final bool hasCnsub;
  final int magnetsCount;
  final String score;

  /// 剧照（列表/搜索信封自带的 preview_images，取 large_url、
  /// 没有落 thumb_url）：详情页剧照区的免登录真数据来源
  /// （详情接口 v4 要令牌、v1 直接 404，见文件头）。
  final List<String> previewImages;

  String get poster => coverUrl.isNotEmpty ? coverUrl : thumbUrl;

  factory JavdbMovie.fromJson(Map<String, dynamic> json) {
    return JavdbMovie(
      id: _javdbStr(json['id']),
      number: _javdbStr(json['number']),
      title: _javdbStr(json['title']),
      thumbUrl: _javdbStr(json['thumb_url']),
      coverUrl: _javdbStr(json['cover_url']),
      durationMinutes: _javdbInt(json['duration']),
      releaseDate: _javdbStr(json['release_date']),
      hasCnsub: _javdbBool(json['has_cnsub']),
      magnetsCount: _javdbInt(json['magnets_count']),
      score: _javdbStr(json['score']),
      previewImages: _javdbPreviewUrls(json['preview_images']),
    );
  }
}

/// preview_images 数组 → 剧照地址表（元素是 {large_url,
/// thumb_url} 对象或纯字符串，两种都认；large 优先）。
List<String> _javdbPreviewUrls(Object? raw) {
  if (raw is! List) return const [];
  final urls = <String>[];
  for (final item in raw) {
    if (item is Map) {
      var url = _javdbStr(item['large_url']);
      if (url.isEmpty) url = _javdbStr(item['thumb_url']);
      if (url.isNotEmpty) urls.add(url);
    } else if (item is String && item.isNotEmpty) {
      urls.add(item);
    }
  }
  return urls;
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
    // 名字取值顺序照 jar 版 actorOptions 实证：name 优先、
    // 空了落 name_zht（繁中名）。
    var name = _javdbStr(json['name']);
    if (name.isEmpty) name = _javdbStr(json['name_zht']);
    // 头像取值照 jar 版：avatar_url 优先、cover_url 兜底。
    var avatar = _javdbStr(json['avatar_url']);
    if (avatar.isEmpty) avatar = _javdbStr(json['cover_url']);
    return JavdbActor(
      id: _javdbStr(json['id']),
      name: name,
      avatarUrl: avatar,
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
    this.poster = '',
  });

  final List<JavdbActor> actors;

  /// 详情自带的封面（cover_url 优先、thumb_url 兜底）：点开
  /// 作品时列表卡封面缺失/是小图时用它把详情页海报补上。
  final String poster;

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

/// 网页通道镜像（jar 版 WEB_MIRRORS 原文顺序）。
const javdbWebMirrors = [
  'https://javdb580.com',
  'https://javdb.com',
  'https://javdb.pw',
];

/// 演员页有效性判定（jar 版 looksLikeActorPage 逐字移植）。
bool javdbLooksLikeActorPage(String html) =>
    html.length > 2000 && html.contains('movie-list') && html.contains('/v/');

/// 卡片正则（jar 版 parseWebCards 逐字移植：主式带番号
/// <strong>，解不出时落宽式、番号留空）。
final _javdbCardPattern = RegExp(
  r'href="/v/([^"]+)"[^>]*class="box"[^>]*title="([^"]*)"[\s\S]{0,700}?<img[^>]*src="([^"]+)"[\s\S]{0,400}?<strong>([^<]*)</strong>',
);
final _javdbCardPatternLoose = RegExp(
  r'href="/v/([^"]+)"[^>]*class="box"[^>]*title="([^"]*)"[\s\S]{0,700}?<img[^>]*src="([^"]+)"',
);

/// HTML 实体反转义（jar 版 htmlUnesc 逐字移植）。
String javdbHtmlUnescape(String raw) {
  if (!raw.contains('&')) return raw;
  return raw
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
}

/// 图片地址归一（jar 版 webAbs 逐字移植）：协议相对地址补 https。
String javdbWebAbs(String raw) {
  final text = javdbHtmlUnescape(raw).trim();
  return text.startsWith('//') ? 'https:$text' : text;
}

/// 演员页 HTML → 作品卡列表（jar 版 parseWebCards 逐字移植；
/// 网页卡没有日期字段，releaseDate 留空、界面按空日期处理）。
List<JavdbMovie> javdbParseActorWorksHtml(String html) {
  if (html.length < 100) return const [];
  final movies = <JavdbMovie>[];
  for (final match in _javdbCardPattern.allMatches(html)) {
    final pic = javdbWebAbs(match.group(3)!);
    movies.add(
      JavdbMovie(
        id: match.group(1)!,
        number: javdbHtmlUnescape(match.group(4)!),
        title: javdbHtmlUnescape(match.group(2)!),
        thumbUrl: pic,
        coverUrl: pic,
      ),
    );
  }
  if (movies.isEmpty) {
    for (final match in _javdbCardPatternLoose.allMatches(html)) {
      final pic = javdbWebAbs(match.group(3)!);
      movies.add(
        JavdbMovie(
          id: match.group(1)!,
          number: '',
          title: javdbHtmlUnescape(match.group(2)!),
          thumbUrl: pic,
          coverUrl: pic,
        ),
      );
    }
  }
  return movies;
}

/// 可注入取数（测试用）：给 URL 回响应文本。
typedef JavdbFetch = Future<String> Function(String url);

/// 可注入 POST（测试用）：URL + 正文 + Content-Type 回响应文本。
typedef JavdbPostFetch =
    Future<String> Function(String url, String body, String contentType);

/// JavDB API 客户端（2026-11-27 对齐 jar 版 ZakaJavdbAmns 已
/// 验证路线）：先登录换令牌、每请求现算签名头（全小写
/// jdsignature）、信封 success≠1 清令牌重登重试一次；主域名
/// 网络层失败自动切兜底域名。令牌只存内存、不落盘不打日志。
class JavdbApiClient {
  JavdbApiClient({JavdbFetch? fetch, JavdbPostFetch? post, ContentHttp? http})
    : _fetch = fetch,
      _postFetch = post,
      _http = http ?? ContentHttp();

  final JavdbFetch? _fetch;
  final JavdbPostFetch? _postFetch;
  final ContentHttp _http;

  String _base = javdbApiBase;
  String _token = '';

  Map<String, String> _headers() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return {
      // 头名照 jar 版 appHeaders 全小写 jdsignature（旧写
      // jdSignature 大小写混排，服务端可能不认）。
      'jdsignature': javdbSignature(ts),
      // UA 照 jar 版 APP_UA 原文。
      'User-Agent': 'Dart/3.5 (dart:io)',
      'Accept-Language': 'zh-TW',
      'Accept': 'application/json',
      if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
    };
  }

  /// 登录换令牌（jar 版 login() 逐字移植）：POST
  /// api/v1/sessions，multipart 表单 = base85 字段解码值 +
  /// 五个固定字段；success=1 且 data.token 长度 ≥8 才算成。
  /// 失败回 false、不抛错——免登录能放行的接口照旧裸跑。
  Future<bool> _login() async {
    // 测试只注入了 GET 取数时不假装登录（夹具按 URL 分发，
    // 也不该被登录请求消耗）。
    if (_fetch != null && _postFetch == null) return false;
    final boundary =
        '----javdb-tvbox-'
        '${md5.convert(utf8.encode('${DateTime.now().microsecondsSinceEpoch}')).toString().substring(0, 24)}';
    final body = StringBuffer();
    void field(String name, String value) {
      body.write(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="$name"\r\n\r\n'
        '$value\r\n',
      );
    }

    for (final (name, encoded) in _javdbLoginFieldsB85) {
      field(name, javdbB85Decode(encoded));
    }
    for (final (name, value) in _javdbLoginFixedFields) {
      field(name, value);
    }
    body.write('--$boundary--\r\n');
    final contentType = 'multipart/form-data; boundary=$boundary';
    try {
      final String text;
      if (_postFetch != null) {
        text = await _postFetch(
          '$_base/api/v1/sessions',
          body.toString(),
          contentType,
        );
      } else {
        text = await _http
            .postRaw(
              '$_base/api/v1/sessions',
              body.toString(),
              headers: {
                'User-Agent': 'Dart/3.5 (dart:io)',
                'Accept-Language': 'zh-TW',
                'Accept': 'application/json',
                'Content-Type': contentType,
                'jdsignature': javdbSignature(
                  DateTime.now().millisecondsSinceEpoch ~/ 1000,
                ),
              },
            )
            .timeout(const Duration(seconds: 25));
      }
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> &&
          (decoded['success'] == 1 || decoded['success'] == true)) {
        final data = decoded['data'];
        final token = data is Map ? _javdbStr(data['token']) : '';
        if (token.length >= 8) {
          _token = token;
          return true;
        }
      }
    } catch (_) {
      // 登录失败不挡免登录接口，调用方照旧裸跑。
    }
    return false;
  }

  bool _envelopeOk(Map<String, dynamic> envelope) {
    final success = envelope['success'];
    // 成功门：success 明确为真最稳；没给 success 字段时以
    // data 在场为准；success 明确为假就是假。
    return success == true ||
        success == 1 ||
        success?.toString().toLowerCase() == 'true' ||
        (success == null && envelope.containsKey('data'));
  }

  Future<Map<String, dynamic>> _requestEnvelopeOnce(String path) async {
    if (_token.isEmpty) await _login();
    final url = '$_base/$path';
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
    return decoded;
  }

  Future<Map<String, dynamic>> _requestEnvelope(String path) async {
    try {
      return await _requestEnvelopeOnce(path);
    } catch (_) {
      // 主域名网络层失败（连不上/超时）：切兜底域名、清令牌
      // 重登后重试一次。测试注入模式保持单域名语义、不重试。
      if (_fetch != null || _base == javdbApiBaseFallback) rethrow;
      _base = javdbApiBaseFallback;
      _token = '';
      return _requestEnvelopeOnce(path);
    }
  }

  Future<dynamic> _getJson(String path) async {
    var envelope = await _requestEnvelope(path);
    if (!_envelopeOk(envelope)) {
      // jar 版 api() 原逻辑：success 不是 1 就清 token 重登
      // 再重试一次（令牌过期/未登录时详情、磁力、搜索都靠它）。
      _token = '';
      await _login();
      envelope = await _requestEnvelope(path);
    }
    if (!_envelopeOk(envelope)) {
      final message = _javdbStr(envelope['message']);
      throw AppFailure(message.isNotEmpty ? message : 'JavDB 接口拒绝了请求');
    }
    return envelope['data'];
  }

  /// 最新作品（路径逐字实证：api/v1/movies/latest）。
  Future<List<JavdbMovie>> latestMovies({int page = 1}) async {
    final data = await _getJson('api/v1/movies/latest?page=$page');
    return _movieListOf(data);
  }

  /// 搜索作品（api/v2/search，路径拼接；参数名 q 照 jar 版
  /// ZakaJavdbAmns 的 searchMovies 原文实证——旧写 keyword
  /// 是推定、已改）。
  Future<List<JavdbMovie>> searchMovies(String keyword, {int page = 1}) async {
    final q = Uri.encodeQueryComponent(keyword.trim());
    final data = await _getJson('api/v2/search?q=$q&page=$page');
    return _movieListOf(data);
  }

  /// 演员列表（api/v1/actors?type=0&page=N，路径与必传参数
  /// type 由 jar 版 ZakaJavdbAmns 原文实证：其分类表「女优」
  /// 项与 actorOptions() 两处都是 type=0；漏传 type 服务端
  /// 回「参数不能为空: type」整页报错——2026-11-26 用户实
  /// 报。信封 data.actors 同其实证）。
  Future<List<JavdbActor>> actors({int page = 1}) async {
    final data = await _getJson('api/v1/actors?type=0&page=$page');
    final list = _listOf(data, const ['actors', 'list', 'items']);
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) JavdbActor.fromJson(item),
    ];
  }

  /// 女优作品（网页通道，jar 版 actorWorksHtml 逐字移植）：
  /// API 侧根本没有这个端点——旧实现打 api/v1/actors/{id}
  /// 解析 movies，本机实测该端点只回演员信息（share_info/
  /// tags 等）、没有作品列表，解析必然回空（2026-11-27 用户
  /// 实报「点女优头像没有作品」的根因）。正解是 GET 镜像站
  /// /actors/{id} 页 HTML、判定有效后正则解卡。jar 版还有
  /// 过盾抓取与中继代理两级兜底，壳内没有等价接口，这里只
  /// 做镜像直连轮换（本机实测 javdb.pw 可通、解出 40 卡）。
  Future<List<JavdbMovie>> actorMovies(String actorId, {int page = 1}) async {
    final path =
        '/actors/${Uri.encodeComponent(actorId)}'
        '${page > 1 ? '?page=$page' : ''}';
    for (final mirror in javdbWebMirrors) {
      final String html;
      try {
        html = await _fetchWebPage('$mirror$path', mirror);
      } catch (_) {
        continue;
      }
      if (!javdbLooksLikeActorPage(html)) continue;
      return javdbParseActorWorksHtml(html);
    }
    return const [];
  }

  /// 网页通道取页（jar 版 webHeaders：桌面 Chrome UA +
  /// zh-TW + Referer=镜像根）。
  Future<String> _fetchWebPage(String url, String mirror) {
    if (_fetch != null) return _fetch(url);
    return _http
        .get(
          url,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/126.0 Safari/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
            'Referer': '$mirror/',
          },
        )
        .timeout(const Duration(seconds: 25));
  }

  /// 作品详情补充（api/v4/movies/{id}，jar 版 detailContent
  /// 逐字实证：取 data.movie、没有就 data 本体）：演员、剧
  /// 照（预览图）、封面、导演/制作商等——只取接口真返回的。
  /// 旧走 v1 详情：本机实测 v1 回 404、v4 无令牌回
  /// JWTVerificationError，两头都拿不到，详情页补充全空
  /// （2026-11-27 用户实报无海报/剧照/演员的根因之一）。
  Future<JavdbMovieExtra> movieExtra(String movieId) async {
    final data = await _getJson('api/v4/movies/$movieId');
    if (data is! Map<String, dynamic>) return const JavdbMovieExtra();
    final rawMovie = data['movie'];
    final map = rawMovie is Map<String, dynamic> ? rawMovie : data;
    final actors = <JavdbActor>[];
    final rawActors = map['actors'];
    if (rawActors is List) {
      for (final item in rawActors) {
        if (item is Map<String, dynamic>) {
          actors.add(JavdbActor.fromJson(item));
        }
      }
    }
    final extra = <(String, String)>[
      if (_javdbStr(map['director_name']).isNotEmpty)
        ('导演', _javdbStr(map['director_name'])),
      if (_javdbStr(map['maker_name']).isNotEmpty)
        ('制作商', _javdbStr(map['maker_name'])),
      if (_javdbStr(map['publisher_name']).isNotEmpty)
        ('发行商', _javdbStr(map['publisher_name'])),
      if (_javdbStr(map['series_name']).isNotEmpty)
        ('系列', _javdbStr(map['series_name'])),
    ];
    var scoreCount = _javdbInt(map['score_count']);
    if (scoreCount <= 0) scoreCount = _javdbInt(map['score_users']);
    if (scoreCount <= 0) scoreCount = _javdbInt(map['reviews_count']);
    var poster = _javdbStr(map['cover_url']);
    if (poster.isEmpty) poster = _javdbStr(map['thumb_url']);
    return JavdbMovieExtra(
      actors: actors,
      stills: _javdbPreviewUrls(map['preview_images']),
      extraInfo: extra,
      score: _javdbStr(map['score']),
      scoreCount: scoreCount,
      poster: poster,
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
