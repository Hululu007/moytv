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

/// 123AV（123av.com）：一级栏目页签；详情页里的 javplayer 嵌入
/// 地址换取流接口回包中的 m3u8。
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
    final text = await fetch(request.apiUrl, {
      'User-Agent': actressOnlineUserAgent,
      'Referer': '$site/',
    });
    final stream = extractAv123Stream(text);
    if (stream.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: stream,
      headers: {
        'User-Agent': actressOnlineUserAgent,
        'Referer': '${request.origin}/',
      },
      detail: detail,
    );
  }
}

/// 全部在线源（源切换条顺序：123AV 在前、PH 在后，与用户令
/// 「把123和ph加进去」的提及顺序一致）。
const kActressOnlineSources = <ActressOnlineSource>[
  Av123ActressSource(),
  PhActressSource(),
];

/// 按 id 取在线源；取不到回 null（'' 是女优库本体，不是在线源）。
ActressOnlineSource? actressOnlineSourceById(String id) {
  for (final source in kActressOnlineSources) {
    if (source.id == id) return source;
  }
  return null;
}
