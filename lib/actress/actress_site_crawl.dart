import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../core_bridge.dart';
import '../crosssite_probe.dart';
import '../models.dart';
import 'actress_database.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';

/// MJV 视频分类（与潮流蜘蛛 chaoliu.py 的 MJV_CATS 同表，只取视频类；
/// 18H 漫画/同人/写真/小说四类不是视频，不爬）。
const actressMjvVideoCategories = <({String id, String name})>[
  (id: 'chinese', name: '中文字幕'),
  (id: 'censored', name: '有码'),
  (id: 'uncensored', name: '无码'),
  (id: 'amateurjav', name: '素人'),
  (id: 'reducing-mosaic', name: '无码破解'),
  (id: 'animation', name: 'H动画'),
  (id: 'CensoredAnimation', name: 'H有码动画'),
  (id: 'UncensoredAnimation', name: 'H无码动画'),
  (id: 'tdAnimation', name: 'H_3D动画'),
  (id: 'dt', name: '国产自拍'),
];

/// 手机现爬进度（列表页横幅显示、可取消）。
class ActressSiteCrawlProgress {
  const ActressSiteCrawlProgress({
    this.running = false,
    this.site = 'mjv',
    this.categoryIndex = 0,
    this.categoryCount = 0,
    this.categoryName = '',
    this.page = 0,
    this.items = 0,
    this.enriched = 0,
    this.done = false,
    this.error = '',
  });

  final bool running;
  final String site;
  final int categoryIndex;
  final int categoryCount;
  final String categoryName;
  final int page;
  final int items;
  final int enriched;
  final bool done;
  final String error;

  String get label {
    if (error.isNotEmpty) return error;
    if (done) return '现爬完成：$items 条，已补流 $enriched 条';
    if (!running) return '未开始';
    return '现爬 $categoryName（$categoryIndex/$categoryCount）第 $page 页 · $items 条';
  }
}

/// 女优库手机现爬：选站后按分类逐页爬，存 hsck 同格式 JSON 到本地。
///
/// - mjv：走潮流蜘蛛（chaoliu.py，MJV 全站蜘蛛）分类目录，
///   repository.catalog('chaoliu', category, page) 现取；
/// - whos 暂无手机现爬：没有 whos 分类蜘蛛（名册源只有按人名查
///   roster/films/search，没有分类列表），直连又常被 CF 挡；
///   选 whos 时直接报缺口，不编假蜘蛛，whos 仍走已同步 JSON 兜底；
/// - 片库站：走本站蜘蛛自己的分类（repository.categories(站 id)
///   现取，空 id 的“全部”伪分类跳过；取回为空回落到单个“全部”）
///   与本站蜘蛛的 catalog 现取；条目 site 记本站 id，取流走本站
///   蜘蛛；文件夹分类直接按 drillId 取目录，空页即停，不另下钻；
/// - 有界：每分类默认取前 50 页（每页 24 条），补流每分类做前 50
///   条（详情 + 取流各一次）；全站条目不设死上限（2026-11-20
///   用户令：内置 json 的本地存储随爬取增长，库的容量与文件体积
///   不设条数与体积死上限）；MJV 全站约 51 万条目，手机上全量现爬
///   不现实，不承诺全量；
/// - 存储：App 资源包里的 assets 文件只读，长在可写的那份本地副本
///   里——documents/actress_json/$site.json（普通文件，不是
///   SharedPreferences 单键，不重蹈 m3u 单键超 16MB 的覆辙）；
///   每爬完一页立刻写盘；一轮内合并表常驻内存（只读一次文件），
///   每页只写不重读；读时兜底加载器把本地新增与内置快照合并着算；
/// - 断点续跑：检查点存在 sync_state（source=site_crawl，phase=站，
///   cursor=分类下标/页码），每爬完一页即存点，失败停在当前页；
/// - 每爬完一页立刻写盘（同格式，indent=2、顶层四键、13 字段 +
///   vod_code/vod_actress_pic），不用等全站爬完；写完即进兜底。
class ActressSiteCrawlService {
  ActressSiteCrawlService({
    required this.repository,
    required this.db,
    this._documentsDir,
  });

  /// 每分类默认页数（2026-11-20 用户令：最少 50 页）。
  static const defaultMaxPagesPerCategory = 50;

  /// 每分类补流条数（详情 + 取流，补上女优名/番号/直链；与页数
  /// 同比例放宽：旧 5 条/3 页约 1.7 条/页，取 1 条/页即 50 条/
  /// 分类、全站 500 次详情+取流；严格按比例是 83 条/分类太重）。
  static const defaultEnrichPerCategory = 50;

  /// 断点存在 sync_state：source 借潮流名册源（现爬走潮流蜘蛛），
  /// phase 用 site_crawl_站名，与名册 roster/films/ranking 各记各的。
  static const _checkpointSource = ActressRosterSourceId.chaoliu;
  static String _checkpointPhase(String site) => 'site_crawl_$site';

  final AppRepository repository;
  final ActressDatabase db;
  final Directory? _documentsDir;

  final _progressController =
      StreamController<ActressSiteCrawlProgress>.broadcast();

  Stream<ActressSiteCrawlProgress> get progress =>
      _progressController.stream;

  var _running = false;
  var _cancelled = false;
  var _current = const ActressSiteCrawlProgress();

  bool get running => _running;

  ActressSiteCrawlProgress get current => _current;

  void _emit(ActressSiteCrawlProgress progress) {
    _current = progress;
    if (!_progressController.isClosed) _progressController.add(progress);
  }

  void cancel() {
    _cancelled = true;
  }

  void dispose() {
    _progressController.close();
  }

  /// 开始现爬。whos 直接报缺口（见类注释）；mjv 与片库站都跑。
  Future<void> start({
    String site = 'mjv',
    int maxPagesPerCategory = defaultMaxPagesPerCategory,
    int enrichPerCategory = defaultEnrichPerCategory,
  }) async {
    if (_running) return;
    if (site == 'whos') {
      _emit(
        const ActressSiteCrawlProgress(
          error: 'whos 暂无手机现爬：没有 whos 分类蜘蛛，仍走已同步 JSON 兜底',
        ),
      );
      return;
    }
    _running = true;
    _cancelled = false;
    // 蜘蛛 id：mjv 走潮流蜘蛛，其余站走本站蜘蛛。
    final spiderId = site == 'mjv' ? 'chaoliu' : site;
    final playFrom = site == 'mjv' ? 'mjv011' : spiderId;
    // 分类：mjv 用硬编码表；其余站取本站自己的分类（空 id 的“全部”
    // 伪分类跳过；取回为空或取分类失败，回落到单个“全部”）。
    final List<({String id, String name})> categories;
    if (site == 'mjv') {
      categories = actressMjvVideoCategories;
    } else {
      final usable = <({String id, String name})>[];
      try {
        for (final c in await repository.categories(site)) {
          if (c.drillId.isNotEmpty) {
            usable.add((id: c.drillId, name: c.name));
          }
        }
      } catch (_) {
        // 取分类失败：回落到“全部”单分类，不让一次取分类失败
        // 卡住整轮现爬。
      }
      categories = usable.isEmpty
          ? const [(id: '', name: '全部')]
          : usable;
    }
    // 一轮内合并表常驻内存：只读一次本地文件，每页只写不重读；
    // 取消/跑完后丢弃，下轮重读（文件是唯一真相）。
    _localByKey = await _loadLocalEntries(site);
    _localSite = site;
    var items = 0;
    var enriched = 0;
    try {
      final saved = await db.checkpoint(
        _checkpointSource,
        _checkpointPhase(site),
      );
      var startCat = 0;
      var startPage = 1;
      if (saved != null && !saved.finished && saved.cursor.isNotEmpty) {
        final parts = saved.cursor.split('/');
        startCat = int.tryParse(parts.firstOrNull ?? '') ?? 0;
        startPage = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1;
        items = saved.total;
      }
      for (var ci = startCat; ci < categories.length; ci++) {
        if (_cancelled) break;
        final category = categories[ci];
        final fromPage = ci == startCat ? startPage : 1;
        var enrichLeft = enrichPerCategory;
        for (var page = fromPage; page <= maxPagesPerCategory; page++) {
          if (_cancelled) break;
          _emit(
            ActressSiteCrawlProgress(
              running: true,
              site: site,
              categoryIndex: ci + 1,
              categoryCount: categories.length,
              categoryName: category.name,
              page: page,
              items: items,
              enriched: enriched,
            ),
          );
          final pageResult = await repository.catalog(
            spiderId,
            category: category.id,
            page: page,
          );
          final rows = pageResult.items;
          if (rows.isEmpty) break;
          final entries = <ActressJsonEntry>[
            for (final drama in rows)
              _entryFromCatalog(drama, category, site, playFrom),
          ];
          items += entries.length;
          await _appendEntries(site, entries);
          await db.saveCheckpoint(
            ActressSyncCheckpoint(
              source: _checkpointSource.name,
              phase: _checkpointPhase(site),
              cursor: '$ci/$page',
              total: items,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          // 补流：本分类前 K 条没直链的，详情 + 取流补齐（K 按分类计，
          // 跨页累计，不按页重置）；补好的攒一页一次写盘。
          final filledEntries = <ActressJsonEntry>[];
          for (final entry in entries) {
            if (enrichLeft <= 0 || _cancelled) break;
            if (entry.playable) continue;
            final filled = await _enrichEntry(entry, spiderId);
            if (filled != null) {
              filledEntries.add(filled);
              enriched++;
              enrichLeft--;
            }
          }
          if (filledEntries.isNotEmpty) {
            await _appendEntries(site, filledEntries);
          }
          if (rows.length < 24) break;
        }
      }
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: _checkpointSource.name,
          phase: _checkpointPhase(site),
          cursor: '',
          total: items,
          finished: !_cancelled,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _emit(
        ActressSiteCrawlProgress(
          site: site,
          categoryIndex: categories.length,
          categoryCount: categories.length,
          items: items,
          enriched: enriched,
          done: !_cancelled,
          error: _cancelled ? '已取消' : '',
        ),
      );
    } catch (error) {
      _emit(
        ActressSiteCrawlProgress(
          site: site,
          items: items,
          enriched: enriched,
          error: '现爬失败：$error',
        ),
      );
    } finally {
      _localByKey = null;
      _localSite = null;
      _running = false;
    }
  }

  /// 一轮内常驻内存的本地合并表（站 + 按 mergeKey 索引的条目）：
  /// 只读一次文件，写盘只写不重读；取消/跑完后丢弃。
  Map<String, ActressJsonEntry>? _localByKey;
  String? _localSite;

  /// 读本地文件进合并表：文件不存在或坏了即空表（坏文件不卡整轮，
  /// 下次写盘重建）。
  Future<Map<String, ActressJsonEntry>> _loadLocalEntries(
    String site,
  ) async {
    final byKey = <String, ActressJsonEntry>{};
    try {
      final dir = await _localDir();
      final file = File(path.join(dir.path, '$site.json'));
      if (!await file.exists()) return byKey;
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map<String, dynamic>) return byKey;
      validateActressJsonDocument(doc, file.path);
      for (final row in (doc['list'] as List)) {
        if (row is Map<String, dynamic>) {
          final entry = ActressJsonEntry.fromRow(row, site);
          byKey[entry.mergeKey] = entry;
        }
      }
    } catch (_) {
      // 本地文件坏了就按空表重建，不让一次坏文件卡住整轮现爬。
    }
    return byKey;
  }

  ActressJsonEntry _entryFromCatalog(
    Drama drama,
    ({String id, String name}) category,
    String site,
    String playFrom,
  ) {
    // 潮流分类行只有 id/标题/封面/日期：番号从 id 的 slug 段或标题里
    // 抠（抠不到就空着，等详情补）；女优名与直链一律空着，等补流。
    final code = _extractCode(drama.id) ?? _extractCode(drama.title) ?? '';
    return ActressJsonEntry(
      site: site,
      vodId: drama.id,
      vodName: drama.title,
      vodPic: drama.cover,
      vodActor: '',
      vodDirector: '',
      vodRemarks: '高清',
      vodPubdate: drama.onlineDate,
      vodArea: '',
      vodYear: '',
      vodContent: '<p>${drama.title}</p>',
      vodPlayFrom: playFrom,
      vodPlayUrl: '',
      typeName: category.name,
      vodCode: code,
      vodActressPic: '',
    );
  }

  String? _extractCode(String text) {
    if (text.isEmpty) return null;
    final slug = text.split('#').last;
    final fromSlug = extractAvId(title: slug);
    if (fromSlug != null && fromSlug.isNotEmpty) return fromSlug;
    return extractAvId(title: text);
  }

  /// 详情 + 取流补一条：女优名从详情描述的“演员：”行取，
  /// 番号从标题/集 id 抠，直链取 resolve 回的地址；详情与取流都走
  /// 本站蜘蛛（mjv 走潮流蜘蛛）。
  Future<ActressJsonEntry?> _enrichEntry(
    ActressJsonEntry entry,
    String spiderId,
  ) async {
    try {
      final detail = await repository.detail(
        Drama(
          id: entry.vodId,
          source: spiderId,
          title: entry.vodName,
          cover: entry.vodPic,
        ),
      );
      if (detail.episodes.isEmpty) return null;
      final actor = _actorFromDescription(detail.drama.description);
      final first = detail.episodes.first;
      final plan = await repository.resolve(detail.drama, first);
      if (plan.url.isEmpty) return null;
      final code = entry.vodCode.isNotEmpty
          ? entry.vodCode
          : (_extractCode(first.id) ??
              _extractCode(detail.drama.title) ??
              '');
      return ActressJsonEntry(
        site: entry.site,
        vodId: entry.vodId,
        vodName: detail.drama.title.isNotEmpty
            ? detail.drama.title
            : entry.vodName,
        vodPic: detail.drama.cover.isNotEmpty
            ? detail.drama.cover
            : entry.vodPic,
        vodActor: actor,
        vodDirector: entry.vodDirector,
        vodRemarks: '高清',
        vodPubdate: detail.drama.onlineDate.isNotEmpty
            ? detail.drama.onlineDate
            : entry.vodPubdate,
        vodArea: entry.vodArea,
        vodYear: entry.vodYear,
        vodContent: entry.vodContent,
        vodPlayFrom: entry.vodPlayFrom,
        vodPlayUrl: '正片\$${plan.url}',
        typeName: entry.typeName,
        vodCode: code,
        vodActressPic: entry.vodActressPic,
      );
    } catch (_) {
      return null;
    }
  }

  /// 详情映射把 vod_actor 拼进描述末尾“演员：XXX”行（见 PyContract）。
  String _actorFromDescription(String description) {
    final match = RegExp(r'演员：([^\n]+)').firstMatch(description);
    return match?.group(1)?.trim() ?? '';
  }

  /// 按更新规则合并写盘：同（分类，番号）且播放链接相同跳过，
  /// 任一字段不同就替换；全新即追加。顶层四键、indent=2。
  /// 不设条数上限：本地文件随爬取增长（2026-11-20 用户令）。
  /// 合并表是一轮内常驻内存的那份（_localByKey），写盘只写不重读。
  Future<void> _appendEntries(
    String site,
    List<ActressJsonEntry> fresh,
  ) async {
    if (fresh.isEmpty) return;
    final dir = await _localDir();
    await dir.create(recursive: true);
    final file = File(path.join(dir.path, '$site.json'));
    var byKey = _localByKey;
    if (_localSite != site || byKey == null) {
      byKey = await _loadLocalEntries(site);
      _localByKey = byKey;
      _localSite = site;
    }
    for (final entry in fresh) {
      final key = entry.mergeKey;
      final old = byKey[key];
      if (old != null && old.vodPlayUrl == entry.vodPlayUrl) continue;
      byKey[key] = entry;
    }
    final doc = <String, dynamic>{
      'list': [for (final e in byKey.values) e.toRow()],
      'parse': 0,
      'jx': 0,
      'last_update': DateTime.now().toIso8601String(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(doc),
    );
  }

  Future<Directory> _localDir() async {
    if (_documentsDir != null) {
      return Directory(
        path.join(_documentsDir.path, ActressJsonFallback.localDirName),
      );
    }
    final docs = await getApplicationDocumentsDirectory();
    return Directory(path.join(docs.path, ActressJsonFallback.localDirName));
  }
}
