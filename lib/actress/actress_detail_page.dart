import 'dart:async';

import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_film_library.dart';
import 'actress_multi_db_fallback.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_play.dart';
import 'actress_search.dart';
import 'actress_widgets.dart';
import '../app_page_route.dart';
import '../core_bridge.dart';
import '../detail_screen.dart';
import '../feed_playability.dart';
import '../global_search_page.dart';
import '../local_store.dart';
import '../models.dart';
import '../widgets.dart';

/// 人物详情页：头像、名、标签、作品数 + 作品卡片网格。
///
/// - 作品一律视频卡片（DramaTile，与站内卡片同一形态）：有封面显示
///   封面 + 标题/番号，无封面用占位卡片 + 番号，点卡片才播；
/// - 打开即后台跑双键合流补封面（缓存优先：已补过且全部作品已有
///   封面时下次不再跑；仍有无封面作品时重新补），退出页即停，
///   不挡列表显示；
/// - 点卡一律先走三档取流（2026-11-20 19:01 用户令顺序写死，
///   2026-11-21 用户令全部改成数据库播放链接：封面站快路径已删，
///   不再先向封面站取详情）：第一档本地 db
///   （MYTV/db/女优库.db 里存的地址），第二档内置（包内 json/m3u
///   兜底数据），第三档跨站探活；每档逐条 resolve + 验活，首条活
///   的直接进详情页播（来源就是条目自己的站，不标别的站），上一
///   档全死才往下一档走；探活命中也要验活才进播放器；全部候选
///   失败才报“这条播不了，已试过 X 个站”（X = 实际试过的站数）。
class ActressDetailPage extends StatefulWidget {
  const ActressDetailPage({
    super.key,
    required this.localId,
    required this.repository,
    required this.store,
    required this.database,
    this.enrichment,
    this.playChainFactory,
    this.siteFilter = ActressSiteFilter.all,
    this.fallback,
    this.filmDb,
    this.verifyFetch,
  });

  final int localId;
  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase database;

  /// 列表页传来的站点筛选：兜底区只显示该站的条目（默认全部）。
  final ActressSiteFilter siteFilter;

  /// 测试注入：JSON 兜底加载器；不传时现建。
  @visibleForTesting
  final ActressJsonFallback? fallback;

  /// 测试注入：影视库 db 兜底提供方（第一档）；不传时按列表页同一
  /// 接法现建 FilmLibraryService（测试注入的 fallback 不接提供方，
  /// 保持老行为）。
  @visibleForTesting
  final FilmDbFallbackProvider? filmDb;

  /// 测试注入：不传时按 repository/store/database 现建。
  @visibleForTesting
  final ActressEnrichment? enrichment;

  /// 测试注入：按番号/标题建播放链；不传时用默认链。
  @visibleForTesting
  final ActressPlayChain Function({
    required String avId,
    required String titleQuery,
  })?
  playChainFactory;

  /// 测试注入：存的地址验活探针；不传时用 [probeStreamHead]。
  @visibleForTesting
  final FeedProbeFetch? verifyFetch;

  @override
  State<ActressDetailPage> createState() => _ActressDetailPageState();
}

class _ActressDetailPageState extends State<ActressDetailPage> {
  static const _pageSize = 60;

  final _scrollController = ScrollController();
  ActressPerson? _person;
  var _works = <ActressWork>[];
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = true;
  var _generation = 0;
  var _enrichmentStarted = false;
  var _playGeneration = 0;
  var _findingSource = false;
  Completer<void>? _playCancel;

  /// 分类筛选：null = 全部；其余为该女优作品里实际存在的分类名。
  /// 头顶“作品 N 部”总数不受筛选影响；进出详情页即重置（状态只
  /// 活在本页实例里）。与头顶“无码”“推荐”人物标签无关，另起一行。
  String? _selectedCategory;
  var _categories = <({String name, int count})>[];

  /// 当前筛选下的作品数（翻页用）；头顶总数由人物行的 displayWorks
  /// 显示（只算入库总数，不受筛选影响），不在这里另记。
  var _filteredTotal = 0;

  /// JSON 兜底区：本地库没有的作品才补（同番号已有卡的不重复占位）。
  /// 顺序：打头是本地 db 行，其后是内置 json/m3u 行；点播按这个顺序
  /// 逐条试（见 _playWork），库里先命中的直链先播。
  var _fallbackEntries = <ActressJsonEntry>[];

  /// 第一档服务：只建一次，复用同一条 DB 连接（进详情页多次不重开）。
  /// 三库合并内置兜底（主库 + 其它 .db）：本页自己建的时候持有。
  MultiDbFilmFallback? _multiDb;

  ActressEnrichment get _enrichment =>
      widget.enrichment ??
      ActressEnrichment(
        repository: widget.repository,
        store: widget.store,
        db: widget.database,
      );

  FeedProbeFetch get _verifyFetch => widget.verifyFetch ?? probeStreamHead;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _generation++;
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    // 2026-11-20 热换库：进详情页先看库文件变了没有——变了就关旧
    // 连接重开再读；重读失败留旧库并报原因，不崩。
    final reload = await widget.database.reloadIfChanged();
    if (!mounted || generation != _generation) return;
    if (reload.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('数据库重读失败：${reload.error}，仍用旧库')));
    }
    final person = await widget.database.personById(widget.localId);
    if (!mounted || generation != _generation) return;
    if (person == null) {
      setState(() {
        _person = null;
        _loading = false;
      });
      return;
    }
    setState(() => _person = person);
    await _loadCategories();
    if (!mounted || generation != _generation) return;
    await _loadPage(reset: true);
    if (!mounted || generation != _generation) return;
    await _loadFallback();
    if (!mounted || generation != _generation) return;
    _startEnrichment();
  }

  /// 该女优作品里实际存在的分类（只含非空分类，按作品数排）：
  /// 空分类的作品不产生标签；分类随同步/镜像补记而变，刷新作品
  /// 时重取。
  Future<void> _loadCategories() async {
    final person = _person;
    if (person == null) return;
    final generation = _generation;
    final categories = await widget.database.workCategories(person.localId);
    if (!mounted || generation != _generation) return;
    setState(() => _categories = categories);
  }

  /// 兜底池（只供点播用，从不渲染）：按女优名 + 已加载作品番号对条目。
  /// 同番号的条目必须留在池里——_playWork 按番号匹配存的地址播，
  /// 滤掉同番号行等于把第一/二档播不了（2026-11-20 兜底播放修）。
  /// 两阶段上屏：JSON 行是同步的，先画出来；m3u 行要解 manifest
  /// 与分片，随后补上，不让 JSON 行等 m3u。
  Future<void> _loadFallback({bool forceReload = false}) async {
    final person = _person;
    if (person == null) return;
    final fallback = widget.fallback ?? ActressJsonFallback();
    // 第一档口子（2026-11-20 19:01 三档令）：兜底加载器没接 DB 提供方
    // 时接上影视库服务（与列表页同一接法）；测试注入的 filmDb 优先；
    // 测试注入的 fallback 不接提供方，保持老行为。列表页传来的
    // fallback 自带 filmDb，这里不动它。
    final injectedFilmDb = widget.filmDb;
    if (injectedFilmDb != null) {
      fallback.filmDb = injectedFilmDb;
    } else if (widget.fallback == null) {
      fallback.filmDb ??=
          _multiDb ??= MultiDbFilmFallback(database: widget.database);
    }
    if (!fallback.loaded || forceReload) await fallback.load();
    final site = widget.siteFilter == ActressSiteFilter.all
        ? null
        : widget.siteFilter.siteId;
    final localCodes = {
      for (final work in _works)
        if (work.codeKey.isNotEmpty) work.codeKey,
    };
    final seen = <String>{};
    final merged = <ActressJsonEntry>[];
    void addAll(List<ActressJsonEntry> rows) {
      for (final entry in rows) {
        final dedup = '${entry.site}|${entry.mergeKey}';
        if (seen.contains(dedup)) continue;
        seen.add(dedup);
        merged.add(entry);
      }
    }

    for (final name in [person.displayName, ...person.aliases]) {
      addAll(fallback.entriesForActress(name, site: site));
    }
    for (final codeKey in localCodes) {
      addAll(fallback.entriesForCode(codeKey, site: site));
    }
    if (!mounted) return;
    setState(() => _fallbackEntries = merged);
    // 2026-11-20 18:57 全部使用数据库兜底：兜底先查 MYTV/db/女优库.db，
    // 数据库行排在 json 行之前、m3u 行之前；库读不到（没接提供方、
    // 文件不存在）时 dbEntries 回空，本段什么都不做，继续走 m3u。
    // 去重口径与上面一致（站|番号），本地已有的番号不补。
    // 第一档：库里这个人的作品行，排在 json/m3u 行之前。
    final dbRows = <ActressJsonEntry>[];
    for (final name in [person.displayName, ...person.aliases]) {
      dbRows.addAll(await fallback.dbEntriesForActress(name, site: site));
    }
    for (final codeKey in localCodes) {
      dbRows.addAll(await fallback.dbEntriesForCode(codeKey, site: site));
    }
    if (dbRows.isNotEmpty) {
      final reordered = <ActressJsonEntry>[];
      final seenDb = <String>{};
      for (final entry in [...dbRows, ...merged]) {
        final dedup = '${entry.site}|${entry.mergeKey}';
        if (seenDb.contains(dedup)) continue;
        seenDb.add(dedup);
        reordered.add(entry);
      }
      merged
        ..clear()
        ..addAll(reordered);
      seen
        ..clear()
        ..addAll(seenDb);
      if (!mounted) return;
      setState(() => _fallbackEntries = merged);
    }
    // m3u 只有 whos 一路；只有全部/whos 才查，选片库站时不查
    // （否则 whos 的 m3u 行会混进该站的兜底）。
    if (site != null && site != 'whos') return;
    var changed = false;
    for (final name in [person.displayName, ...person.aliases]) {
      final before = merged.length;
      addAll(await fallback.m3uEntriesForActress(name));
      if (merged.length != before) changed = true;
    }
    for (final codeKey in localCodes) {
      final before = merged.length;
      addAll(await fallback.m3uEntriesForCode(codeKey));
      if (merged.length != before) changed = true;
    }
    if (!mounted) return;
    if (changed) setState(() => _fallbackEntries = merged);
    // m3u hash 图兜底：已加载的无封面作品，用 m3u 行的 hash 图贴封面。
    await _attachM3uCovers(fallback);
    await _attachDbCovers(fallback);
  }

  /// 数据库封面兜底（2026-11-21）：m3u hash 图查不到番号时，再按
  /// 番号去库里（主库 + 其它 .db）要一次封面——用户库里本来就存着
  /// 这张剧照，没必要留灰块。只贴本页已加载的作品，来源记 'db'。
  Future<void> _attachDbCovers(ActressJsonFallback fallback) async {
    final person = _person;
    final provider = fallback.filmDb;
    if (person == null || provider == null) return;
    var attached = false;
    for (final work in _works) {
      if (work.hasCover || work.codeKey.isEmpty) continue;
      List<ActressJsonEntry> rows;
      try {
        rows = await provider.entriesForCode(work.codeKey);
      } catch (_) {
        continue;
      }
      String? pic;
      for (final entry in rows) {
        if (entry.vodPic.isNotEmpty) {
          pic = entry.vodPic;
          break;
        }
      }
      if (pic == null) continue;
      await widget.database.attachCover(
        personId: person.localId,
        codeKey: work.codeKey,
        titleKey: work.titleKey,
        coverSource: 'db',
        coverDramaId: '',
        coverUrl: pic,
        insertIfMissing: false,
        site: 'db',
      );
      attached = true;
    }
    if (attached && mounted) await _reloadWorks();
  }

  /// m3u hash 图兜底：条目自己没图时，用 whos m3u 的 hash 图
  /// （https://v.hersav.me/images/av/<hash>.jpg）给已加载的无封面
  /// 作品贴封面；再没有才留占位图。只贴已加载页的作品（翻页后
  /// 不重跑，补封面走 enrichPerson）。封面来源记 'whos'（图就
  /// 是 whos m3u 给的），快路径不认 whos 站、不会拿它取详情。
  Future<void> _attachM3uCovers(ActressJsonFallback fallback) async {
    final person = _person;
    if (person == null) return;
    var attached = false;
    for (final work in _works) {
      if (work.hasCover || work.codeKey.isEmpty) continue;
      final rows = await fallback.m3uEntriesForCode(work.codeKey);
      String? pic;
      String? dramaId;
      for (final entry in rows) {
        if (entry.vodPic.isNotEmpty) {
          pic = entry.vodPic;
          dramaId = entry.vodId;
          break;
        }
      }
      if (pic == null) continue;
      await widget.database.attachCover(
        personId: person.localId,
        codeKey: work.codeKey,
        titleKey: work.titleKey,
        coverSource: 'whos',
        coverDramaId: dramaId ?? '',
        coverUrl: pic,
        insertIfMissing: false,
        site: 'whos',
      );
      attached = true;
    }
    if (attached && mounted) await _reloadWorks();
  }

  void _startEnrichment() {
    final person = _person;
    if (_enrichmentStarted || person == null) return;
    _enrichmentStarted = true;
    final generation = _generation;
    unawaited(
      _enrichment
          .enrichPerson(
            person,
            isCancelled: () => !mounted || generation != _generation,
            // 当前页正在看的作品先补封面（cap 120 按 id ASC 取，
            // 翻页看到的新作品本来排不到 cap 里）。
            prioritizeWorkIds: [for (final work in _works) work.id],
            onChanged: () {
              if (mounted && generation == _generation) {
                unawaited(_reloadWorks());
              }
            },
          )
          .then((completed) async {
            if (!mounted || generation != _generation) return;
            if (completed) {
              await widget.database.markEnriched(person.localId);
            }
            if (mounted && generation == _generation) {
              await _reloadWorks();
            }
          }),
    );
  }

  /// 原地刷新已加载的作品（封面补上后网格实时更新，不动滚动位置）。
  Future<void> _reloadWorks() async {
    final person = _person;
    if (person == null) return;
    final generation = _generation;
    final count = _works.length;
    if (count == 0) return;
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: 0,
      limit: count,
      category: _selectedCategory,
    );
    final filteredTotal = await widget.database.countWorks(
      person.localId,
      category: _selectedCategory,
    );
    final freshPerson = await widget.database.personById(person.localId);
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = works;
      _filteredTotal = filteredTotal;
      _hasMore = works.length < filteredTotal;
      if (freshPerson != null) _person = freshPerson;
    });
    await _loadCategories();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      unawaited(_loadPage());
    }
  }

  Future<void> _loadPage({bool reset = false}) async {
    final person = _person;
    if (person == null) return;
    if (reset) {
      final generation = _generation;
      // 首次进页显示全屏转圈；切换分类时保留旧网格，等新数据到了
      // 再换，不闪“暂无作品”。
      final firstLoad = _works.isEmpty && _loading;
      if (firstLoad) {
        setState(() {
          _loading = true;
          _works = [];
          _hasMore = true;
        });
      }
      final works = await widget.database.worksForPerson(
        person.localId,
        offset: 0,
        limit: _pageSize,
        category: _selectedCategory,
      );
      final filteredTotal = await widget.database.countWorks(
        person.localId,
        category: _selectedCategory,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _works = works;
        _filteredTotal = filteredTotal;
        _hasMore = works.length < filteredTotal;
        _loading = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: _works.length,
      limit: _pageSize,
      category: _selectedCategory,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = [..._works, ...works];
      _hasMore = _works.length < _filteredTotal;
      _loadingMore = false;
    });
  }

  /// 按 id 在当前库里重取一部作品（热换库后用）：新库里没有了返回 null。
  Future<ActressWork?> _refetchWork(ActressWork work) async {
    final person = _person;
    if (person == null) return null;
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: 0,
      limit: _works.length + 60,
      category: _selectedCategory,
    );
    for (final candidate in works) {
      if (work.id != 0 && candidate.id == work.id) return candidate;
      if (work.id == 0 &&
          candidate.codeKey == work.codeKey &&
          candidate.titleKey == work.titleKey) {
        return candidate;
      }
    }
    return null;
  }

  Future<void> _playWork(ActressWork work) async {
    if (_findingSource) return;
    // 2026-11-20 热换库：播之前先看库文件变了没有——变了就关旧连接
    // 重开，再按当前库重取这部作品与兜底条目，不播缓存的旧地址。
    // 重读失败留旧库并报原因，不崩；作品在新库里没有了就提示并
    // 刷新列表，不硬播。
    var currentWork = work;
    final reload = await widget.database.reloadIfChanged();
    if (reload.error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('数据库重读失败：${reload.error}，仍用旧库')));
    }
    if (reload.reloaded && mounted) {
      final fresh = await _refetchWork(work);
      if (!mounted) return;
      if (fresh == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这部作品在新库里没有了')));
        await _loadPage(reset: true);
        return;
      }
      currentWork = fresh;
      await _loadFallback(forceReload: true);
      if (!mounted) return;
    }
    // 2026-11-21 用户令（数据库兜底定版）：库里有这个番号的地址就直接
    // 播本地库那条（第一档 db 行），不再往下探内置 json/m3u、也不再跨站
    // 静默探活；库里没有这个番号、或库里那条地址已经播不了，就提示
    // “去站点列表搜索影片”，并给一键跳转——不硬播、不空转。
    final playGeneration = ++_playGeneration;
    final cancel = Completer<void>();
    setState(() {
      _findingSource = true;
      _playCancel = cancel;
    });
    final avId = actressPlayAvId(currentWork);
    final queryKey = avId.isNotEmpty ? avId : currentWork.displayTitle;
    final chain =
        widget.playChainFactory?.call(avId: avId, titleQuery: queryKey) ??
        ActressPlayChain(
          repository: widget.repository,
          store: widget.store,
          avId: avId,
          titleQuery: queryKey,
          // 作品自己记的站先探（见 actress_play.dart）。库里的站名是
          // vod_play_from 原样（如 whos.tv），计划侧的站 id 是归一形
          // （whos），先过一次 filmSiteId，否则永远先探不到自家的站。
          preferSiteId: currentWork.site.isNotEmpty
              ? filmSiteId(currentWork.site)
              : null,
          verifyFetch: _verifyFetch,
        );
    // 库里这个人名下、番号相同的地址行（DB 行在池子最前，先试它）。
    // 2026-11-22 修复：作品侧 codeKey 是库里的 vod_id 原样（rki-6042），
    // 兜底条目的 codeKey 是归一化番号（RKI6042）——直接比字符串永远
    // 不相等，导致库里 32 万条直链一条都取不到、点播放只能去跨站爬。
    // 统一归一化比较，见 jsonEntriesForWorkCode。
    final dbRows = jsonEntriesForWorkCode(
      _fallbackEntries,
      currentWork.codeKey,
    );
    DramaDetail? storedDetail;
    try {
      // 只认本地库这一档：逐条 resolve + 验活，首条活的直接进详情页播
      //（来源就是条目自己的站，parse=0 直链 + 该站的头）；最多试 3 条，
      // 点取消立即停。
      for (final entry in dbRows.take(3)) {
        if (cancel.isCompleted || playGeneration != _playGeneration) break;
        final detail = entry.toDramaDetail();
        try {
          final plan = await widget.repository
              .resolve(detail.drama, detail.episodes.first)
              .timeout(const Duration(seconds: 8));
          if (cancel.isCompleted || playGeneration != _playGeneration) break;
          // 解析型计划验不了活：不冒进，算这条库里地址不可直播。
          if (plan.needsParse) continue;
          final uri = Uri.tryParse(plan.url.trim());
          if (uri == null ||
              !(uri.scheme == 'http' || uri.scheme == 'https') ||
              uri.host.isEmpty) {
            continue;
          }
          final response = await _verifyFetch(
            plan.url,
            plan.headers,
            const Duration(seconds: 5),
          );
          if (!feedProbePlayable(uri, response)) continue;
          storedDetail = detail;
          break;
        } catch (_) {
          // 这条死了：换库里下一条地址。
          continue;
        }
      }
    } finally {
      if (mounted && playGeneration == _playGeneration) {
        setState(() {
          _findingSource = false;
          _playCancel = null;
        });
      }
    }
    if (!mounted || cancel.isCompleted || playGeneration != _playGeneration) {
      return;
    }
    // 2026-11-22 用户令（点播放要能进播放页）：库里明明有这个番号的地址，
    // 只是我们这台机器探活没过（不少流媒体站只认播放器的头，探活一律 403/405），
    // 就不能卡在列表上只弹一句“播不了”。直接带库里的地址进播放页，
    // 让播放器自己去取；真的取不到，播放页里有换线/重试。
    if (storedDetail == null && dbRows.isNotEmpty) {
      storedDetail = dbRows.first.toDramaDetail();
    }
    if (storedDetail == null) {
      // 库里没有该番号 / 库里连地址都没有：按番号现爬补齐（2026-11-22
      // 用户令「没有的作品自动爬取补齐」）——跨站按番号搜一轮，首个能
      // 解的线路直接进详情页开播；全站都没爬到时才提示去搜索。
      if (queryKey.isEmpty) {
        _showDbMissHint(hasDbRow: dbRows.isNotEmpty, query: queryKey);
        return;
      }
      ActressPlayCandidate? crawled;
      if (mounted) {
        setState(() {
          _findingSource = true;
          _playCancel = cancel;
        });
      }
      try {
        crawled = await chain.nextPlayable(
          profileEpoch: widget.store.profileEpoch,
        );
      } catch (_) {
        crawled = null;
      } finally {
        if (mounted && playGeneration == _playGeneration) {
          setState(() {
            _findingSource = false;
            _playCancel = null;
          });
        }
      }
      if (!mounted ||
          cancel.isCompleted ||
          playGeneration != _playGeneration) {
        return;
      }
      if (crawled == null) {
        _showDbMissHint(hasDbRow: dbRows.isNotEmpty, query: queryKey);
        return;
      }
      await _openDetailWithChain(chain, crawled);
      return;
    }
    await _openDetailWithChain(
      chain,
      ActressPlayCandidate(detail: storedDetail, episodeIndex: 0),
    );
  }

  /// 库里没有这个番号（或库里那条地址播不了）时的提示（2026-11-21
  /// 用户令）：明说去站点列表搜索影片，给一键跳到全局搜索，不静默
  /// 跨站探活、不硬播。
  void _showDbMissHint({required bool hasDbRow, required String query}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          hasDbRow ? '本地库里这条地址播不了，去站点列表搜索影片吧' : '数据库里没有这个番号，去站点列表搜索影片',
        ),
        action: SnackBarAction(
          label: '去搜索',
          onPressed: () => _openSiteSearch(query),
        ),
      ),
    );
  }

  /// 带番号/标题跳全局搜索（片库站点列表的搜索）。
  Future<void> _openSiteSearch(String query) async {
    await Navigator.of(context).push(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'search'),
        builder: (_) => GlobalSearchPage(
          repository: widget.repository,
          store: widget.store,
          initialQuery: query,
        ),
      ),
    );
  }

  /// 兜底命中直进详情页：首选线路进页即播；详情页跨站线路区继续
  /// 挂其余站的线路；播耗尽时详情页向同一条链要下一条线路；
  /// 播放器报错屏点“重试播放”时链先 resetForRetry 再重探一遍，
  /// 不原地重播同一个死地址（见 DetailScreen.onRetryProbe）。
  Future<void> _openDetailWithChain(
    ActressPlayChain chain,
    ActressPlayCandidate candidate,
  ) async {
    await Navigator.of(context).push(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'detail'),
        builder: (_) => DetailScreen(
          drama: candidate.detail.drama,
          repository: widget.repository,
          store: widget.store,
          autoPlayOnOpen: true,
          autoPlayEpisodeIndex: candidate.episodeIndex,
          // 候选那条的集数（数据库里存的直链）带进去：站点详情取回
          // 是空的时就用它播，不显示“该站未返回详情”就没得播。
          initialDetail: candidate.detail,
          nextLineOnExhausted: () async {
            final next = await chain.nextPlayable(
              profileEpoch: widget.store.profileEpoch,
            );
            if (next == null) return null;
            return (detail: next.detail, episodeIndex: next.episodeIndex);
          },
          onRetryProbe: () async {
            chain.resetForRetry();
            final next = await chain.nextPlayable(
              profileEpoch: widget.store.profileEpoch,
            );
            if (next == null) return null;
            return (detail: next.detail, episodeIndex: next.episodeIndex);
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(person?.displayName ?? '女优详情')),
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator())
              : person == null
              ? const Center(child: Text('人物不存在'))
              : CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverToBoxAdapter(child: _buildHeader(person, colors)),
                    // 分类标签筛选（2026-11-20 用户令新增）：另起一行，
                    // 与头顶“无码”“推荐”人物标签无关。只显示该女优
                    // 作品里实际存在的分类；无分类的作品只在“全部”
                    // 里，不产生标签。
                    if (_works.isNotEmpty && _categories.isNotEmpty)
                      SliverToBoxAdapter(child: _buildCategoryFilter()),
                    // 兜底一直不显示（2026-11-20 用户定：内置播放源
                    // 不能让别人看出来），兜底区永远不渲染；兜底数据
                    // 只做后台播放兜底（三档：本地 db → 内置 json/m3u
                    // → 跨站探活，见 _playWork）。本地零作品时只显示
                    // “暂无作品”，不再为兜底区留位置。
                    if (_works.isEmpty)
                      const SliverFillRemaining(
                        child: Center(child: Text('暂无作品')),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        sliver: SliverGrid(
                          gridDelegate: dramaGridDelegate(
                            context,
                            MediaQuery.sizeOf(context).width - 24,
                          ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            if (index >= _works.length) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            final work = _works[index];
                            return DramaTile(
                              key: ValueKey('actress-work-${work.id}'),
                              drama: actressWorkDrama(work),
                              repository: widget.repository,
                              subtitle: actressWorkSubtitle(work),
                              onTap: () => _playWork(work),
                            );
                          }, childCount: _works.length + (_hasMore ? 1 : 0)),
                        ),
                      ),
                  ],
                ),
          if (_findingSource) ...[
            const ModalBarrier(dismissible: false, color: Colors.black54),
            Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      const Text('正在找可播片源…'),
                      const SizedBox(height: 8),
                      TextButton(
                        key: const ValueKey('cancel-find-source'),
                        onPressed: () {
                          final cancel = _playCancel;
                          if (cancel != null && !cancel.isCompleted) {
                            cancel.complete();
                          }
                        },
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(ActressPerson person, ColorScheme colors) {
    final sexLabel = actressSexLabel(person.sex);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ActressAvatar(
            avatarUrl: person.avatarUrl,
            name: person.displayName,
            radius: 36,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.displayName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '作品 ${person.displayWorks} 部'
                  '${sexLabel.isEmpty ? '' : ' · $sexLabel'}',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                if (person.aliases.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '别名：${person.aliases.join(' / ')}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
                if (person.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in person.tags)
                        Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分类标签筛选行：横向滑动；第一个是“全部”，后面是该女优作品里
  /// 实际存在的分类（带部数，0 部的分类不出现）。点中只筛当前这个
  /// 女优的作品列表，头顶总数不动。
  Widget _buildCategoryFilter() {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _categoryChip(
              label: '全部',
              selected: _selectedCategory == null,
              colors: colors,
              onTap: () => _selectCategory(null),
            ),
            for (final category in _categories)
              _categoryChip(
                label: '${category.name}（${category.count}）',
                selected: _selectedCategory == category.name,
                colors: colors,
                onTap: () => _selectCategory(category.name),
              ),
          ],
        ),
      ),
    );
  }

  Widget _categoryChip({
    required String label,
    required bool selected,
    required ColorScheme colors,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        key: ValueKey('actress-category-$label'),
        label: Text(label),
        selected: selected,
        selectedColor: colors.primaryContainer,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Future<void> _selectCategory(String? category) async {
    if (_selectedCategory == category) return;
    setState(() => _selectedCategory = category);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _loadPage(reset: true);
  }
}
