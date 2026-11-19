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
/// - 只接 mjv：走潮流蜘蛛（chaoliu.py，MJV 全站蜘蛛）分类目录，
///   repository.catalog('chaoliu', category, page) 现取；
/// - whos 暂无手机现爬：没有 whos 分类蜘蛛（名册源只有按人名查
///   roster/films/search，没有分类列表），直连又常被 CF 挡；
///   选 whos 时直接报缺口，不编假蜘蛛，whos 仍走已同步 JSON 兜底；
/// - 有界：每分类默认只取前 3 页（每页 24 条，10 分类最多 720 条），
///   补流每分类只做前 5 条（详情 + 取流各一次），全站条目上限 1000；
///   MJV 全站约 51 万条目，手机上全量现爬不现实，不承诺全量；
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

  /// 每分类默认页数（保守值：流量与耗时都可控）。
  static const defaultMaxPagesPerCategory = 3;

  /// 每分类补流条数（详情 + 取流，补上女优名/番号/直链）。
  static const defaultEnrichPerCategory = 5;

  /// 全站条目上限（防失控）。
  static const maxTotalItems = 1000;

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

  /// 开始现爬。site 只认 mjv；whos 直接报缺口（见类注释）。
  Future<void> start({
    String site = 'mjv',
    int maxPagesPerCategory = defaultMaxPagesPerCategory,
    int enrichPerCategory = defaultEnrichPerCategory,
  }) async {
    if (_running) return;
    if (site != 'mjv') {
      _emit(
        const ActressSiteCrawlProgress(
          error: 'whos 暂无手机现爬：没有 whos 分类蜘蛛，仍走已同步 JSON 兜底',
        ),
      );
      return;
    }
    _running = true;
    _cancelled = false;
    final categories = actressMjvVideoCategories;
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
        if (_cancelled || items >= maxTotalItems) break;
        final category = categories[ci];
        final fromPage = ci == startCat ? startPage : 1;
        var enrichLeft = enrichPerCategory;
        for (var page = fromPage; page <= maxPagesPerCategory; page++) {
          if (_cancelled || items >= maxTotalItems) break;
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
            'chaoliu',
            category: category.id,
            page: page,
          );
          final rows = pageResult.items;
          if (rows.isEmpty) break;
          final entries = <ActressJsonEntry>[];
          for (final drama in rows) {
            if (items + entries.length >= maxTotalItems) break;
            entries.add(_entryFromCatalog(drama, category));
          }
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
          // 跨页累计，不按页重置）。
          for (final entry in entries) {
            if (enrichLeft <= 0 || _cancelled) break;
            if (entry.playable) continue;
            final filled = await _enrichEntry(entry);
            if (filled != null) {
              await _appendEntries(site, [filled]);
              enriched++;
              enrichLeft--;
            }
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
      _running = false;
    }
  }

  ActressJsonEntry _entryFromCatalog(
    Drama drama,
    ({String id, String name}) category,
  ) {
    // 潮流分类行只有 id/标题/封面/日期：番号从 id 的 slug 段或标题里
    // 抠（抠不到就空着，等详情补）；女优名与直链一律空着，等补流。
    final code = _extractCode(drama.id) ?? _extractCode(drama.title) ?? '';
    return ActressJsonEntry(
      site: 'mjv',
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
      vodPlayFrom: 'mjv011',
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
  /// 番号从标题/集 id 抠，直链取 resolve 回的地址。
  Future<ActressJsonEntry?> _enrichEntry(ActressJsonEntry entry) async {
    try {
      final detail = await repository.detail(
        Drama(
          id: entry.vodId,
          source: 'chaoliu',
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
  Future<void> _appendEntries(
    String site,
    List<ActressJsonEntry> fresh,
  ) async {
    if (fresh.isEmpty) return;
    final dir = await _localDir();
    await dir.create(recursive: true);
    final file = File(path.join(dir.path, '$site.json'));
    final byKey = <String, ActressJsonEntry>{};
    if (await file.exists()) {
      try {
        final doc = jsonDecode(await file.readAsString());
        if (doc is Map<String, dynamic>) {
          validateActressJsonDocument(doc, file.path);
          for (final row in (doc['list'] as List)) {
            if (row is Map<String, dynamic>) {
              final entry = ActressJsonEntry.fromRow(row, site);
              byKey[entry.mergeKey] = entry;
            }
          }
        }
      } catch (_) {
        // 本地文件坏了就重建，不让一次坏文件卡住整轮现爬。
      }
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
