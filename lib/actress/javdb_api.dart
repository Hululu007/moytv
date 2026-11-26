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
  });

  final List<JavdbActor> actors;

  /// 预览图（preview_images 的 large_url）——详情页剧照真数据。
  final List<String> stills;

  /// (标签, 值)：导演/制作商/发行商/系列，只带接口真返回的。
  final List<(String, String)> extraInfo;
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
    final ok =
        success == true ||
        success == 1 ||
        success?.toString().toLowerCase() == 'true';
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
    return JavdbMovieExtra(actors: actors, stills: stills, extraInfo: extra);
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
