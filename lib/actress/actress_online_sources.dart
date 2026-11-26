import 'dart:convert';

import '../content_http.dart';
import '../core_bridge.dart';
import 'actress_online_parse.dart';

/// 演员库在线源（123AV / PH）的取数服务：Dart 直连站点页面，
/// 解析在 actress_online_parse.dart（与原合并网页两站适配器
/// 同口径），播放走 App 既有播放器链——点卡时现取播放地址，
/// 组装成 direct 直链集交给 pushPlayer（见 actress_online_view）。
///
/// 取数函数可注入（[ActressOnlineFetch]），测试/预览用假取数，
/// 不碰真网络；生产默认走 [ContentHttp]（应用内既有内容取数
/// 客户端，带全局网络档案/DNS 设置）。

/// 在线源取数函数：给地址与请求头，回网页文本；失败抛
/// [AppFailure]（文案已是中文人话，界面直接用）。
typedef ActressOnlineFetch =
    Future<String> Function(String url, Map<String, String> headers);

/// 在线源统一 UA：与合并页取数口径一致的桌面 Chrome。
const actressOnlineUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/122.0.0.0 Safari/537.36';

/// 默认取数客户端：包一层 [ContentHttp]，超时放宽到 25 秒
/// （两站页面较大，机房/移动网络慢时 10 秒容易误杀）。
class ActressOnlineClient {
  ActressOnlineClient([ContentHttp? http]) : _http = http ?? ContentHttp();

  final ContentHttp _http;

  Future<String> get(String url, Map<String, String> headers) =>
      _http.get(url, headers: headers, timeout: const Duration(seconds: 25));
}

/// 一次取流的结果：最终播放地址 + 播放请求头 + 详情信息。
class ActressOnlinePlay {
  const ActressOnlinePlay({
    required this.streamUrl,
    required this.headers,
    required this.detail,
  });

  final String streamUrl;

  /// 播放请求头（UA + Referer），经播放器的 direct 集透传
  /// （见 playback_loader 的 direct 分支）。
  final Map<String, String> headers;

  final OnlineDetailInfo detail;
}

/// 在线源定义：界面只认这套接口（页签、列表、取流）。
abstract class ActressOnlineSource {
  const ActressOnlineSource();

  /// 源 id（同时作 Drama.source）。
  String get id;

  /// 源切换条上的名字。
  String get label;

  /// 站点根地址。
  String get site;

  /// 一级页签：PH 是排序，123AV 是栏目。
  List<OnlineTabOption> get primaryTabs;

  /// 二级页签：只有 PH 有（分类）；123AV 为空。
  List<OnlineTabOption> get secondaryTabs;

  String get defaultPrimaryId;
  String get defaultSecondaryId;

  /// 懒查询：true 的源在线路区里默认不自动查、点「点击查
  /// 询」才查（重源/有盾源用，AvPlay 同口径）。
  bool get lazySearch => false;

  /// 页面请求头（列表/详情共用）。
  Map<String, String> get pageHeaders => {
    'User-Agent': actressOnlineUserAgent,
    'Referer': '$site/',
  };

  OnlineTabOption _pick(List<OnlineTabOption> tabs, String id) => tabs
      .firstWhere((row) => row.id == id, orElse: () => tabs.first);

  /// 取一页卡片。[query] 非空时走搜索（页签不参与拼址，与站方
  /// 搜索口径一致）。取不到/解析为空回空列表，失败抛 AppFailure。
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  });

  /// 点卡取流：打开详情页解析出播放地址；取不到抛 AppFailure。
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  });
}

/// PH（cn.pornhub.com）：一级排序 + 二级分类，详情页 flashvars
/// 里带 mediaDefinitions 签名 m3u8。
class PhActressSource extends ActressOnlineSource {
  const PhActressSource();

  @override
  String get id => 'ph';

  @override
  String get label => 'PH';

  @override
  String get site => phSite;

  @override
  List<OnlineTabOption> get primaryTabs => kPhSortTabs;

  @override
  List<OnlineTabOption> get secondaryTabs => kPhGenreCats;

  @override
  String get defaultPrimaryId => 'hot';

  @override
  String get defaultSecondaryId => 'all';

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) async {
    final url = phListUrl(
      sortValue: _pick(primaryTabs, primaryId).value,
      catValue: _pick(secondaryTabs, secondaryId).value,
      query: query,
      page: page,
    );
    final html = await fetch(url, pageHeaders);
    return parsePhCards(html);
  }

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    final detail = parsePhDetail(html);
    final stream = extractPhStream(html);
    if (stream.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: stream,
      headers: {
        'User-Agent': actressOnlineUserAgent,
        'Referer': '$site/',
      },
      detail: detail,
    );
  }
}

/// 123AV（123av.com）：一级栏目页签；取址走详情页内联
/// player(JSON.parse(…)) 的集数 JSON（嵌入域名现读不写
/// 死），再走嵌入源 /stream 接口换 m3u8（2026-11-26 出口
/// 补验批全链实证）。
class Av123ActressSource extends ActressOnlineSource {
  const Av123ActressSource();

  @override
  String get id => 'av123';

  @override
  String get label => '123AV';

  @override
  String get site => av123Site;

  @override
  List<OnlineTabOption> get primaryTabs => kAv123Tabs;

  @override
  List<OnlineTabOption> get secondaryTabs => const [];

  @override
  String get defaultPrimaryId => 'recent';

  @override
  String get defaultSecondaryId => '';

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) async {
    final url = av123ListUrl(
      path: _pick(primaryTabs, primaryId).value,
      query: query,
      page: page,
    );
    final html = await fetch(url, pageHeaders);
    return parseAv123Cards(html);
  }

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    final detail = parseAv123Detail(html);
    final embed = av123EmbedOf(html);
    if (embed.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    final request = av123StreamRequest(embed);
    if (request == null) {
      // 嵌入地址不是 /e/ 形：本身就是媒体地址才直接用。
      if (embed.contains('.m3u8') || embed.contains('.mp4')) {
        return ActressOnlinePlay(
          streamUrl: embed,
          headers: {
            'User-Agent': actressOnlineUserAgent,
            'Referer': '$site/',
          },
          detail: detail,
        );
      }
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    // 取流请求头 Referer 用嵌入页地址（补验批实证口径）；
    // 播放地址的 Referer 同用嵌入页地址。
    final text = await fetch(request.apiUrl, {
      'User-Agent': actressOnlineUserAgent,
      'Referer': embed,
    });
    final stream = extractAv123Stream(text);
    if (stream.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: stream,
      headers: {
        'User-Agent': actressOnlineUserAgent,
        'Referer': embed,
      },
      detail: detail,
    );
  }
}

/// AV01（www.av01.media）：2026-11-26 六源扩线新写 Dart
/// 源，照 AvPlay 反编译的 Av01Parser/Av01UrlUtils 落——
/// 搜索页扫 /video/{id}/{slug} 候选（slug 命中番号才认）、
/// 详情页三关校验（canonical 的 id/slug 一致、h1 归一以
/// slug 开头）后取 <source src> 里的主清单
/// （/api/v1/videos/{id}/manifest/master.m3u8）。
/// 凭证流：取流前先走一遍地理接口 getGeoData（带 ttl 缓
/// 存，失败不挡取流）——AvPlay 的第二步 requestCdnAccess
/// 向服务端换 access_token、播放时只给 customers.iw01.xyz
/// 域名的请求加 access_token 查询参；详情页渲染出的主清
/// 单在 www.av01.media 域名上、不吃这个 token。换凭证的
/// 接口地址在反编译里没还原出来（jadx 对 Av01Service 该
/// 方法解码失败），不编造端点，卡点记在
/// REPORT_actress_online6.md。
class Av01ActressSource extends ActressOnlineSource {
  const Av01ActressSource();

  @override
  String get id => 'av01';

  @override
  String get label => 'AV01';

  @override
  String get site => av01Site;

  @override
  List<OnlineTabOption> get primaryTabs =>
      const [OnlineTabOption(id: 'search', name: '搜索', value: '')];

  @override
  List<OnlineTabOption> get secondaryTabs => const [];

  @override
  String get defaultPrimaryId => 'search';

  @override
  String get defaultSecondaryId => '';

  /// 地理缓存（getGeoData，照 Av01Service 的 cachedGeo +
  /// ttl 口径）：（拉取时刻、ttl 秒）。
  static (DateTime, int)? _geoCache;

  Future<void> _warmGeo(ActressOnlineFetch fetch) async {
    final cached = _geoCache;
    if (cached != null &&
        DateTime.now().difference(cached.$1).inSeconds < cached.$2) {
      return;
    }
    try {
      final text = await fetch(av01GeoUrl(), pageHeaders);
      final decoded = jsonDecode(text);
      var ttl = 300;
      if (decoded is Map && decoded['ttl'] is num) {
        ttl = (decoded['ttl'] as num).toInt();
      }
      _geoCache = (DateTime.now(), ttl);
    } catch (_) {
      // 地理只是凭证流的前置，拉不到不挡页面路径取流。
    }
  }

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) async {
    final code = query.trim();
    if (code.isEmpty) return const [];
    final html = await fetch(av01SearchUrl(code), pageHeaders);
    if (actressPageLooksChallenged(html)) {
      throw AppFailure('AV01 被站点人机校验拦住，请稍后重试');
    }
    return parseAv01SearchCards(html, code);
  }

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    await _warmGeo(fetch);
    final html = await fetch(card.pageUrl, pageHeaders);
    if (actressPageLooksChallenged(html)) {
      throw AppFailure('AV01 被站点人机校验拦住，请稍后重试');
    }
    final parsed = parseAv01DetailManifest(html, card.pageUrl);
    if (parsed == null) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: parsed.manifest,
      headers: {
        'User-Agent': actressOnlineUserAgent,
        'Referer': '$site/',
      },
      detail: OnlineDetailInfo(
        title: parsed.title.isNotEmpty ? parsed.title : card.title,
      ),
    );
  }
}

/// Jable（jable.tv）：2026-11-26 六源扩线新写 Dart 源，
/// 照 AvPlay 反编译的 JableParser 落——搜索页
/// /search/{番号大写}/ 扫 /videos/{slug}、slug 与番号相
/// 等才认；详情页正则取 hlsUrl 的 m3u8。站有盾：纯 HTTP
/// 撞挑战页时如实标查询失败（AvPlay 走 WebView 挑战，我
/// 们不网页内播，播放层另有壳级嗅探兜底）；默认懒查询。
class JableActressSource extends ActressOnlineSource {
  const JableActressSource();

  @override
  String get id => 'jable';

  @override
  String get label => 'Jable';

  @override
  String get site => jableSite;

  @override
  bool get lazySearch => true;

  @override
  List<OnlineTabOption> get primaryTabs =>
      const [OnlineTabOption(id: 'search', name: '搜索', value: '')];

  @override
  List<OnlineTabOption> get secondaryTabs => const [];

  @override
  String get defaultPrimaryId => 'search';

  @override
  String get defaultSecondaryId => '';

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) async {
    final code = query.trim();
    if (code.isEmpty) return const [];
    final html = await fetch(jableSearchUrl(code), pageHeaders);
    if (actressPageLooksChallenged(html)) {
      throw AppFailure('Jable 被站点人机校验拦住，请稍后重试');
    }
    return parseJableSearchCards(html, code);
  }

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    if (actressPageLooksChallenged(html)) {
      throw AppFailure('Jable 被站点人机校验拦住，请稍后重试');
    }
    final stream = extractJableHls(html);
    if (stream.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: stream,
      headers: {
        'User-Agent': actressOnlineUserAgent,
        'Referer': '$site/',
      },
      detail: OnlineDetailInfo(title: card.title),
    );
  }
}

/// 全部在线源（源切换条顺序：123AV 在前、PH 在后，与用户令
/// 「把123和ph加进去」的提及顺序一致）。这两个是可浏览的
/// 源（nvku 源切换条用）；线路/竞速用的全集见
/// [kActressLineSources]。
const kActressOnlineSources = <ActressOnlineSource>[
  Av123ActressSource(),
  PhActressSource(),
];

/// 线路/竞速全集（2026-11-26 六源扩线）：可浏览两源 +
/// AV01 + Jable（新写 Dart）；另外四个 py 复用源
/// （AVDB/JavMenu/MemoJav/MissAV）不在这张表里，走
/// actress_py_lines.dart 的 py 链线路表。
const kActressLineSources = <ActressOnlineSource>[
  Av123ActressSource(),
  PhActressSource(),
  Av01ActressSource(),
  JableActressSource(),
];

/// 按 id 取在线源；取不到回 null（'' 是女优库本体，不是在线源）。
ActressOnlineSource? actressOnlineSourceById(String id) {
  for (final source in kActressOnlineSources) {
    if (source.id == id) return source;
  }
  return null;
}
