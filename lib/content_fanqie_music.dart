import 'dart:convert';

import 'content_http.dart';
import 'content_models.dart';
import 'core_bridge.dart';

// 茄果音乐（番茄音乐 novelfm）：数据走 m.novelfm.com 网页版的服务端渲染页
// （首页榜单 + /music/{id} 详情页，页内嵌 _ROUTER_DATA JSON），公开可取、
// 不需要 App 签名。播放地址是详情页现给的 novelfmvod 直链（带时效签名），
// 每次播放现取。站方 App 搜索接口需签名且关键词参数未明，本源暂不支持
// 搜索（见 note）。

const fanqieMusicHost = 'https://m.novelfm.com';

const fanqieMusicUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

Map<String, String> get fanqieMusicHeaders => {
  'User-Agent': fanqieMusicUserAgent,
  'Referer': '$fanqieMusicHost/',
};

/// 从 SSR 页 HTML 里抽出 window._ROUTER_DATA 的 JSON 对象。
/// 用括号配平扫描截取（JSON 里含转义引号内的括号时以字符串状态跳过）。
Map<String, dynamic>? parseFanqieRouterData(String html) {
  const marker = 'window._ROUTER_DATA';
  final at = html.indexOf(marker);
  if (at < 0) return null;
  final start = html.indexOf('{', at);
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < html.length; i++) {
    final ch = html[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        try {
          final decoded = jsonDecode(html.substring(start, i + 1));
          return decoded is Map<String, dynamic> ? decoded : null;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}

Map<String, dynamic>? _fanqieMap(Object? value) =>
    value is Map<String, dynamic> ? value : null;

List<dynamic>? _fanqieList(Object? value) =>
    value is List<dynamic> ? value : null;

String _fanqieText(Object? value) => value == null ? '' : '$value'.trim();

/// 首页 homeData 里的榜单分组（当前实测只有「热门歌曲」一组；
/// 站方日后多给分组时自动多出分类）。
List<Map<String, dynamic>> fanqieMusicGroups(Map<String, dynamic> routerData) {
  final page = _fanqieMap(_fanqieMap(routerData['loaderData'])?['page']);
  final homeData = _fanqieMap(page?['homeData']);
  final data = _fanqieMap(homeData?['data']);
  final groups = _fanqieList(data?['hot_list_groups']);
  if (groups == null) return const [];
  return [
    for (final group in groups)
      if (_fanqieMap(group) != null) _fanqieMap(group)!,
  ];
}

List<ContentCategory> parseFanqieMusicCategories(
  Map<String, dynamic> routerData,
) {
  return [
    for (final group in fanqieMusicGroups(routerData))
      if (_fanqieText(group['tab_name']).isNotEmpty)
        ContentCategory(
          id: _fanqieText(group['id']),
          name: _fanqieText(group['tab_name']),
        ),
  ];
}

ContentBook _fanqieBookFromRow(Map<String, dynamic> row) {
  var cover = _fanqieText(row['audio_thumb_uri']);
  if (cover.startsWith('http://')) {
    cover = 'https://${cover.substring(7)}';
  }
  final album = _fanqieText(row['album_title']);
  final version = _fanqieText(row['singing_version_name']);
  return ContentBook(
    id: _fanqieText(row['book_id']),
    title: _fanqieText(row['book_name']),
    cover: cover,
    author: _fanqieText(row['author']),
    remarks: _fanqieText(row['play_num_text']),
    intro: [album, version].where((x) => x.isNotEmpty).join(' · '),
  );
}

ContentPage parseFanqieMusicCatalog(
  Map<String, dynamic> routerData,
  String categoryId,
) {
  final groups = fanqieMusicGroups(routerData);
  if (groups.isEmpty) return const ContentPage(items: []);
  var group = groups.first;
  if (categoryId.isNotEmpty) {
    for (final candidate in groups) {
      if (_fanqieText(candidate['id']) == categoryId) {
        group = candidate;
        break;
      }
    }
  }
  final rows = _fanqieList(group['hot_list']) ?? const [];
  final items = [
    for (final row in rows)
      if (_fanqieMap(row) != null &&
          _fanqieText(_fanqieMap(row)!['book_id']).isNotEmpty &&
          _fanqieText(_fanqieMap(row)!['book_name']).isNotEmpty)
        _fanqieBookFromRow(_fanqieMap(row)!),
  ];
  return ContentPage(items: items, hasMore: false, total: items.length);
}

Map<String, dynamic>? fanqieMusicPageData(Map<String, dynamic> routerData) {
  final loader = _fanqieMap(routerData['loaderData']);
  final page = _fanqieMap(loader?['music_(id)/page']);
  return _fanqieMap(page?['pageData']);
}

ContentBookDetail parseFanqieMusicDetail(
  Map<String, dynamic> routerData,
  String bookId,
) {
  final pageData = fanqieMusicPageData(routerData);
  final info = _fanqieMap(pageData?['api_book_info']);
  if (pageData == null || info == null) {
    throw AppFailure('茄果音乐歌曲页数据缺失');
  }
  var cover = _fanqieText(info['thumb_url']);
  if (cover.isEmpty) cover = _fanqieText(info['audio_thumb_uri']);
  if (cover.startsWith('http://')) {
    cover = 'https://${cover.substring(7)}';
  }
  final title = _fanqieText(info['book_name']);
  final author = _fanqieText(info['author']);
  final version = _fanqieText(info['singing_version_name']);
  final book = ContentBook(
    id: _fanqieText(info['book_id']).isEmpty
        ? bookId
        : _fanqieText(info['book_id']),
    title: title,
    cover: cover,
    author: author,
    remarks: [
      _fanqieText(info['play_num_text']),
      version,
    ].where((x) => x.isNotEmpty).join(' · '),
    intro: _fanqieText(info['abstract']),
  );
  return ContentBookDetail(
    book: book,
    chapters: [
      ContentChapter(
        id: book.id,
        title: title.isEmpty ? '播放' : title,
        meta: author,
      ),
    ],
  );
}

/// 详情页现给的播放直链：main_url 优先，空了用 back_url。
String parseFanqieMusicPlayUrl(Map<String, dynamic> routerData) {
  final pageData = fanqieMusicPageData(routerData);
  final videoInfo = _fanqieMap(pageData?['video_info']);
  final main = _fanqieText(videoInfo?['main_url']);
  if (main.isNotEmpty) return main;
  return _fanqieText(videoInfo?['back_url']);
}

class FanqieMusicSource extends ContentSource {
  FanqieMusicSource(this._http);

  final ContentHttp _http;

  @override
  String get id => 'fanqie_music';

  @override
  String get name => '茄果音乐';

  @override
  ContentSection get section => ContentSection.music;

  @override
  String get note =>
      '分类/详情/播放已实拉（网页版公开数据，无需签名）；播放为网页档音质，'
      '地址带时效签名、每次现取不缓存；站方搜索接口需 App 签名且参数未明，'
      '本源暂不支持搜索';

  @override
  Map<String, String> get pageHeaders => fanqieMusicHeaders;

  Future<Map<String, dynamic>> _routerData(String url) async {
    final html = await _http.get(url, headers: fanqieMusicHeaders);
    final data = parseFanqieRouterData(html);
    if (data == null) {
      throw AppFailure('茄果音乐页面数据异常，请稍后重试');
    }
    return data;
  }

  @override
  Future<List<ContentCategory>> categories() async {
    final data = await _routerData('$fanqieMusicHost/');
    final categories = parseFanqieMusicCategories(data);
    if (categories.isEmpty) {
      throw AppFailure('茄果音乐暂未返回分类');
    }
    return categories;
  }

  @override
  Future<ContentPage> catalog(String categoryId, int page) async {
    if (page > 1) return const ContentPage(items: []);
    final data = await _routerData('$fanqieMusicHost/');
    return parseFanqieMusicCatalog(data, categoryId);
  }

  @override
  Future<ContentPage> search(String keyword, int page) {
    throw AppFailure('茄果音乐暂不支持搜索（站方搜索接口需 App 签名）');
  }

  @override
  Future<ContentBookDetail> detail(String bookId) async {
    final data = await _routerData('$fanqieMusicHost/music/$bookId');
    return parseFanqieMusicDetail(data, bookId);
  }

  @override
  Future<ContentAudioTrack> audioTrack(
    String bookId,
    ContentChapter chapter,
  ) async {
    final data = await _routerData('$fanqieMusicHost/music/$bookId');
    final url = parseFanqieMusicPlayUrl(data);
    if (url.isEmpty) {
      throw AppFailure('茄果音乐暂未返回播放地址');
    }
    return ContentAudioTrack(url: url, headers: fanqieMusicHeaders);
  }
}
