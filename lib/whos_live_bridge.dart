import 'live_models.dart';
import 'whos_local_library.dart';

/// 内置片库在直播里的形态：库里一条作品 = 直播列表里的一个频道，
/// 地址就是已落库的 m3u8 直链，不用订阅、不用现抓。
const whosLibSourceId = 'whos_lib';

/// 直播源地址前缀：走本地库，不联网拉清单。
const whosLibScheme = 'whoslib://';

/// 一页频道数。直播列表是滚动续载，一页太多会把首屏拖慢。
const whosLibPageSize = 120;

const whosLibUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/131.0.0.0 Safari/537.36';

const whosLibHeaders = <String, String>{
  'User-Agent': whosLibUserAgent,
  'Referer': 'https://whos.tv/',
};

/// 频道名：番号在前、标题在后，太长截断（直播列表一行放不下）。
String whosLibChannelName(WhosLocalWork work) {
  final code = work.code.trim();
  final title = work.displayTitle.trim();
  final head = code.isEmpty ? title : (title.isEmpty ? code : '$code $title');
  if (head.length <= 64) return head;
  return '${head.substring(0, 63)}…';
}

/// 取一页频道。category 支持库里的分类 id：`new` / `rank` / `brand:<前缀>`。
List<LiveChannel> whosLibChannels(
  WhosLocalLibrary library, {
  required String category,
  int page = 1,
  String source = whosLibSourceId,
}) {
  final rows = library.page(
    category: category,
    page: page,
    pageSize: whosLibPageSize,
  );
  return [
    for (final work in rows)
      if (work.playUrl.startsWith('http'))
        _whosLibChannel(work, source)!,
  ];
}

/// 取一页频道（异步版，2026-11-23）：数据库模式按页查库，JSON 模式
/// 走内存。直播仓储用这个；同步版只留给测试与 JSON 模式调用方。
Future<List<LiveChannel>> whosLibChannelsAsync(
  WhosLocalLibrary library, {
  required String category,
  int page = 1,
  String source = whosLibSourceId,
}) async {
  final rows = await library.pageAsync(
    category: category,
    page: page,
    pageSize: whosLibPageSize,
  );
  return [
    for (final work in rows)
      if (work.playUrl.startsWith('http'))
        _whosLibChannel(work, source)!,
  ];
}

LiveChannel? _whosLibChannel(WhosLocalWork work, String source) {
  if (!work.playUrl.startsWith('http')) return null;
  return LiveChannel(
    key: '$source:${work.id}',
    name: whosLibChannelName(work),
    urls: [work.playUrl],
    number: work.code,
    logo: work.cover,
    group: work.brand.isEmpty ? '其它' : whosBrandLabel(work.brand),
    source: source,
    headers: whosLibHeaders,
  );
}

/// 直播里的分类：最新 / 排行榜 + 条目最多的厂牌。
List<LivePlatform> whosLibPlatforms(
  WhosLocalLibrary library, {
  int brandLimit = 30,
}) => [
  for (final row in library.categories(brandLimit: brandLimit))
    LivePlatform(id: row.id, name: '${row.name} · ${row.count}'),
];

/// 直播里的分类（异步版，2026-11-23）：数据库模式走库里聚合。
Future<List<LivePlatform>> whosLibPlatformsAsync(
  WhosLocalLibrary library, {
  int brandLimit = 30,
}) async => [
  for (final row in await library.categoriesAsync(brandLimit: brandLimit))
    LivePlatform(id: row.id, name: '${row.name} · ${row.count}'),
];
