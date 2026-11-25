import 'dart:async';

import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_film_library.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_neon.dart';
import 'actress_tag_sheet.dart';
import 'actress_widgets.dart';
import 'whos_json_index.dart';
import '../app_page_route.dart';
import '../core_bridge.dart';
import '../detail_screen.dart';
import '../feed_playability.dart';
import '../local_store.dart';
import '../models.dart';
import '../widgets.dart';

/// 人物详情页：头像、名、标签、作品数 + 作品卡片网格。
///
/// - 作品一律视频卡片（DramaTile，与站内卡片同一形态）：有封面显示
///   封面 + 标题/番号，无封面用占位卡片 + 番号，点卡片才播；
/// - 作品与首选地址以数据库里为准（2026-11-22 用户令：女优库
///   全部播放只走数据库里的数据）：只读库，不走跨站现取、不走
///   json/m3u 兜底做展示——m3u hash 图贴封面与跨站搜索补封面
///   （双键合流）都已停掉，库里没有封面就如实显示占位卡片，不编
///   地址；点卡先试库里存的地址（按番号匹配、同番号多条逐条
///   resolve + 验活，最多 3 条）与 MissAV 按番号现查并行竞速
///   （2026-11-23 18:00 改令：潮流 jpcode 兜底换成 MissAV+数据库
///   竞速，哪边先出可播地址就先播哪边）；两边都查不到才报
///   “库里暂无播放地址”，不落回内置兜底、不弹去搜索；
/// - 分类 chips 与顶栏走霓虹样式（见 actress_neon.dart）。
class ActressDetailPage extends StatefulWidget {
  const ActressDetailPage({
    super.key,
    required this.localId,
    required this.repository,
    required this.store,
    required this.database,
    this.siteFilter = ActressSiteFilter.all,
    this.initialTag = '',
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

  /// 列表页传来的作品标签筛选（2026-11-24 标签筛选）：进页时作品
  /// 列表只留带该标签的作品；页内可点“标签”换标签、点“清除”取消。
  /// 只活在本页实例里，返回列表页后列表页自己的筛选不受影响。
  final String initialTag;

  /// 测试注入：DB 行加载器；不传时现建。
  @visibleForTesting
  final ActressJsonFallback? fallback;

  /// 测试注入：影视库 db 兜底提供方（唯一一档）；不传时按列表页同一
  /// 接法现建 FilmLibraryService（测试注入的 fallback 不接提供方，
  /// 保持老行为）。
  @visibleForTesting
  final FilmDbFallbackProvider? filmDb;

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
  var _playGeneration = 0;

  /// 详情页正在打开（点卡已推 DetailScreen、还没弹回）：防双击
  /// 连点推两个详情页。_playWork 推页前置 true，弹回后置 false。
  var _openingDetail = false;

  /// 会话级已验活地址缓存：番号（归一化）→ 竞速赢过的详情。
  /// 某番号竞速赢过一次后，下次点同一番号直接用缓存的已验活
  /// 地址开页，不再等竞速。只活在 App 本次运行里，重启即清空。
  static final Map<String, DramaDetail> _verifiedDetailCache = {};

  /// 已加载的数据库作品数（翻页 offset 用它，不用 _works.length——
  /// _works 里还混着 json 补的作品，用它当 offset 会跳过数据库作品）。
  var _dbWorksCount = 0;

  /// json 补的作品数（只在无分类筛选时补，见 _supplementJsonWorks）。
  var _jsonWorksCount = 0;

  /// 头顶“作品 N 部”显示的总数：数据库入库数 + json 补的数（无筛选时）。
  /// 选了分类也不变（只算入库总数，不受筛选影响）；json 没补上之前
  /// 先显示数据库数，补上后再加。0 表示还没算出来，用人物行的数兜底。
  var _headerTotal = 0;

  /// 分类筛选：null = 全部；其余为该女优作品里实际存在的分类名。
  /// 头顶“作品 N 部”总数不受筛选影响；进出详情页即重置（状态只
  /// 活在本页实例里）。与头顶“无码”“推荐”人物标签无关，另起一行。
  String? _selectedCategory;
  var _categories = <({String name, int count})>[];

  /// 作品标签筛选（2026-11-24 标签筛选）：'' = 全部；其余只留带该
  /// 标签的作品，与分类是 AND 关系。初始值来自列表页传来的
  /// initialTag；页内点“标签”可换、点“清除”取消。选了标签时不补
  /// json 作品（json 作品没有标签，补进来就不是“只留带标签的作品”了）。
  var _selectedTag = '';

  /// 传给 worksForPerson/countWorks 的标签参数：'' 转 null（= 全部）。
  String? get _worksVideoTag =>
      _selectedTag.isEmpty ? null : _selectedTag;

  /// 当前筛选下的作品数（翻页用）；头顶总数由人物行的 displayWorks
  /// 显示（只算入库总数，不受筛选影响），不在这里另记。
  var _filteredTotal = 0;

  /// 库里存的播放地址（2026-11-22 用户令：女优库全部播放只走数据
  /// 库里的数据）：只含本地 db 行（多 .db 合并，按女优名 / 番号从
  /// 影视库 db 取回），不含内置 json/m3u 行；点播只试这些
  /// （见 _playWork）。兜底区不渲染，只供点播用。
  var _fallbackEntries = <ActressJsonEntry>[];

  /// 地址池正在建的 Future（_bootstrap 末尾起，不堵首屏）：
  /// 点卡时池子没建好最多等 2 秒（2026-11-24 秒进改法；原来等
  /// 15 秒），等不到按当前池子走，不在点播里卡住。
  Future<void>? _fallbackLoad;

  /// 没有外置数据库：详情页显示空态提示，不显示“人物不存在”。
  var _noDatabase = false;

  /// DB 服务：只建一次，复用同一条 DB 连接（进详情页多次不重开）。
  /// 内部工作库的影视库服务：本页自己建的时候持有，退出时关掉。
  FilmLibraryService? _filmDbService;

  FeedProbeFetch get _verifyFetch => widget.verifyFetch ?? probeStreamHead;

  @override
  void initState() {
    super.initState();
    _selectedTag = widget.initialTag;
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
    // 连接重开再读；重读失败留旧库并报原因，不崩。没有外置库时
    // 显示空态提示，不说“仍用旧库”（没有旧库可留）。
    final reload = await widget.database.reloadIfChanged();
    if (!mounted || generation != _generation) return;
    if (reload.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(actressReloadErrorText(reload.error!))),
      );
    }
    ActressPerson? person;
    try {
      person = await widget.database.personById(widget.localId);
    } on ActressNoExternalDbException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _person = null;
        _loading = false;
        _noDatabase = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted || generation != _generation) return;
    if (person == null) {
      setState(() {
        _person = null;
        _loading = false;
      });
      return;
    }
    setState(() => _person = person);
    // 2026-11-22 加载优化：分类与首屏作品并行取——分类查询原来
    // 0.9~6.3 秒，串行等它完了才取作品，首屏一直转圈；并行后
    // 作品到了就撤转圈出网格，分类 chips 到了再补。
    await Future.wait([_loadCategories(), _loadPage(reset: true)]);
    if (!mounted || generation != _generation) return;
    // 地址池后台建、不堵首屏；点卡时 _playWork 会等它建好。
    _fallbackLoad = _loadFallback();
    await _fallbackLoad;
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

  /// 批量按番号取库里条目（2026-11-22 女优库加载优化）：
  /// 真实提供方（FilmLibraryService）一次主键 IN 取回全部番号，
  /// 不再逐条 LIKE 扫表；其它实现（含测试替身）逐条回落。批量方法
  /// 没放进 FilmDbFallbackProvider 接口（测试替身都是 implements，
  /// 接口多方法就编不过），所以这里按运行时类型分发。
  Future<List<ActressJsonEntry>> _dbEntriesForCodes(
    ActressJsonFallback fallback,
    List<String> codeKeys, {
    String? site,
  }) async {
    if (codeKeys.isEmpty) return const [];
    final provider = fallback.filmDb;
    if (provider == null) return const [];
    try {
      if (provider is FilmLibraryService) {
        return await provider.entriesForCodes(codeKeys, site: site);
      }
      final out = <ActressJsonEntry>[];
      for (final codeKey in codeKeys) {
        out.addAll(await fallback.dbEntriesForCode(codeKey, site: site));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 库里存的播放地址池（只供点播用，从不渲染）：按女优名 + 已加载
  /// 作品番号，只从内部工作库（FilmLibraryService）取行；同番号
  /// 的条目必须留在池里——
  /// _playWork 按番号匹配存的地址播（2026-11-22 用户令：女优库
  /// 全部播放只走数据库里的数据，不读内置 json/m3u、不跨站现取）。
  /// 不调 fallback.load()：那是读本地 json 文件的，DB 行不
  /// 依赖它（活树留了这行调用，这里是死负担，去掉）。
  Future<void> _loadFallback() async {
    final person = _person;
    if (person == null) return;
    final fallback = widget.fallback ?? ActressJsonFallback();
    // DB 提供方接法（与列表页同一接法）：测试注入的 filmDb 优先；
    // 测试注入的 fallback 不接提供方，保持老行为。列表页传来的
    // fallback 自带 filmDb，这里不动它。
    final injectedFilmDb = widget.filmDb;
    if (injectedFilmDb != null) {
      fallback.filmDb = injectedFilmDb;
    } else if (widget.fallback == null) {
      fallback.filmDb ??= _filmDbService ??= FilmLibraryService(
        database: widget.database,
      );
    }
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

    // 2026-11-23 v58 验机修复：地址池分两段上屏——第一段只走主库
    // （FilmLibraryService，IN 主键取，毫秒级），建好立刻 setState，
    // 点卡不再干等；第二段再走主库重查一遍（去重后基本无新增），
    // 补进来再 setState 一次。原来两段串行完才一次 setState，
    // 池子建得慢时 _playWork 的 15 秒超时一到就按空池子报
    // “库里暂无播放地址”，其实地址都在库里。
    final provider = fallback.filmDb;
    final FilmLibraryService? primary = provider is FilmLibraryService
        ? provider
        : null;
    if (primary != null) {
      try {
        for (final name in [person.displayName, ...person.aliases]) {
          addAll(await primary.entriesForActress(name, site: site));
        }
        final codes = localCodes.toList();
        if (codes.isNotEmpty) {
          addAll(await primary.entriesForCodes(codes, site: site));
        }
      } catch (_) {
        // 主库这段失败不堵第二段（第二段还会再试主库一次）。
      }
      if (mounted && merged.isNotEmpty) {
        setState(() => _fallbackEntries = merged);
      }
    }

    // 第二段：主库重查（去重后基本无新增），补进来再上屏。
    try {
      for (final name in [person.displayName, ...person.aliases]) {
        addAll(await fallback.dbEntriesForActress(name, site: site));
      }
      final codes = localCodes.toList();
      if (codes.isNotEmpty) {
        addAll(await _dbEntriesForCodes(fallback, codes, site: site));
      }
    } catch (_) {
      // 第二段失败不丢第一段的池子。
    }

    // 第三段：who's.json 内置索引（用户 2026-11-23 21:50 令：女优用 json+db，
    // db 数据库兜底播放）——库里没有的番号补一条 who's 直链（不过期）。
    // 放在数据库两段之后：同一番号库里已有地址时去重保留数据库那条，
    // json 只补库里没有的。失败（索引没建好）不堵池子。
    try {
      final index = await WhosJsonIndex.instance;
      if (!index.isEmpty) {
        final codes = <String>{};
        for (final name in [person.displayName, ...person.aliases]) {
          codes.addAll(index.codesForActor(name));
        }
        for (final code in codes) {
          final video = index.videoForCode(code);
          if (video == null) continue;
          addAll([
            ActressJsonEntry(
              site: 'whos',
              vodId: video.code,
              vodName: video.title,
              vodPic: video.pic,
              vodActor: person.displayName,
              vodDirector: '',
              vodRemarks: '高清',
              vodPubdate: '',
              vodArea: '日本',
              vodYear: '',
              vodContent: '',
              vodPlayFrom: 'whos',
              vodPlayUrl: '正片\$${video.m3u8}',
              typeName: '日本AV',
              vodCode: video.code,
              vodActressPic: '',
            ),
          ]);
        }
      }
    } catch (_) {
      // json 索引失败不丢数据库池子。
    }
    if (!mounted) return;
    setState(() => _fallbackEntries = merged);
    // 数据库封面兜底（2026-11-21，DB 行不是 json/m3u）：无封面作品
    // 按番号去库里（主库 + 其它 .db）要一次封面——用户库里本来就
    // 存着这张剧照，没必要留灰块。只贴本页已加载的作品，来源记 'db'。
    await _attachDbCovers(fallback);
  }

  /// 数据库封面兜底（2026-11-21）：按番号去库里（主库 + 其它 .db）
  /// 要一次封面——用户库里本来就存着这张剧照，没必要留灰块。只贴
  /// 本页已加载的作品，来源记 'db'。
  Future<void> _attachDbCovers(ActressJsonFallback fallback) async {
    final person = _person;
    final provider = fallback.filmDb;
    if (person == null || provider == null) return;
    // 2026-11-22 加载优化：无封面作品的番号一次批量取封面，
    // 不再逐部调 entriesForCode 全表扫（见 _loadFallback）。
    final uncovered = <ActressWork>[
      for (final work in _works)
        if (!work.hasCover && work.codeKey.isNotEmpty) work,
    ];
    if (uncovered.isEmpty) return;
    List<ActressJsonEntry> rows;
    try {
      rows = await _dbEntriesForCodes(fallback, [
        for (final work in uncovered) work.codeKey,
      ]);
    } catch (_) {
      return;
    }
    final picByCode = <String, String>{};
    for (final entry in rows) {
      if (entry.vodPic.isEmpty) continue;
      picByCode.putIfAbsent(entry.codeKey, () => entry.vodPic);
    }
    var attached = false;
    for (final work in uncovered) {
      final pic = picByCode[normalizeAvCode(work.codeKey)];
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

  /// 原地刷新已加载的作品（封面补上后网格实时更新，不动滚动位置）。
  Future<void> _reloadWorks() async {
    final person = _person;
    if (person == null) return;
    final generation = _generation;
    final count = _dbWorksCount;
    if (count == 0 && _works.isEmpty) return;
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: 0,
      limit: count,
      category: _selectedCategory,
      videoTag: _worksVideoTag,
    );
    final filteredTotal = await widget.database.countWorks(
      person.localId,
      category: _selectedCategory,
      videoTag: _worksVideoTag,
    );
    final freshPerson = await widget.database.personById(person.localId);
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = works;
      _dbWorksCount = works.length;
      _jsonWorksCount = 0;
      _filteredTotal = filteredTotal;
      _hasMore = works.length < filteredTotal;
      if (freshPerson != null) _person = freshPerson;
    });
    await _loadCategories();
    // json 补的作品重新补（封面刷新不丢 json 行）。
    unawaited(_supplementJsonWorks());
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
        videoTag: _worksVideoTag,
      );
      final filteredTotal = await widget.database.countWorks(
        person.localId,
        category: _selectedCategory,
        videoTag: _worksVideoTag,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _works = works;
        _dbWorksCount = works.length;
        _jsonWorksCount = 0;
        _filteredTotal = filteredTotal;
        // 无筛选时头顶总数就是数据库总数（json 补上后在 _supplementJsonWorks
        // 里再加）；选了分类/标签不改头顶总数。
        if (_selectedCategory == null && _selectedTag.isEmpty) {
          _headerTotal = filteredTotal;
        }
        _hasMore = works.length < filteredTotal;
        _loading = false;
      });
      // 首屏先出数据库作品，json 补的作品后台接上（不 await，不堵首屏）。
      unawaited(_supplementJsonWorks());
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: _dbWorksCount,
      limit: _pageSize,
      category: _selectedCategory,
      videoTag: _worksVideoTag,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = [..._works, ...works];
      _dbWorksCount += works.length;
      _hasMore = _works.length < _filteredTotal;
      _loadingMore = false;
    });
  }

  /// who's.json 内置索引补作品（用户 2026-11-23 21:50 令：女优用 json+db）：
  /// 首屏先显示数据库作品，索引在后台建好后把 json 里有、库里没有的
  /// 作品补到列表末尾（json 没有日期，排在数据库作品后面）。
  /// 只在无分类筛选时补——json 视频没有分类（type_name 全是日本AV），
  /// 选了分类时只显示数据库里有真实分类的作品，不硬凑。
  /// 不堵首屏：调用方先 setState 显示数据库作品，再调这里（不 await），
  /// 索引建好后补进来再 setState 一次。
  Future<void> _supplementJsonWorks() async {
    final person = _person;
    if (person == null) return;
    // 选了分类/标签不补；已补过不再补（翻页不重复）。
    if (_selectedCategory != null ||
        _selectedTag.isNotEmpty ||
        _jsonWorksCount > 0) {
      return;
    }
    final generation = _generation;
    WhosJsonIndex index;
    try {
      index = await WhosJsonIndex.instance;
    } catch (_) {
      return;
    }
    if (!mounted || generation != _generation) return;
    if (index.isEmpty) return;
    // 该演员在索引里的全部番号（人名 + 别名都查，合并去重）。
    final codes = <String>{};
    for (final name in [person.displayName, ...person.aliases]) {
      codes.addAll(index.codesForActor(name));
    }
    if (codes.isEmpty) return;
    // 库里已有的番号不重复补（按归一化番号比）。
    final inDb = <String>{
      for (final work in _works)
        if (work.codeKey.isNotEmpty) normalizeAvCode(work.codeKey),
    };
    final missing = <String>[
      for (final code in codes)
        if (!inDb.contains(normalizeAvCode(code))) code,
    ];
    if (missing.isEmpty) return;
    // 先按 JSON 番号查本地库（2026-11-24 用户令：内置 JSON 索引本地库，
    // 不同步也能出片播放）：库里有行就按本地库行出片（本地封面/分类/
    // 播放地址），库里没有才落到 who's 在线目录。素人标签下有番号的
    // 作品已按番号归到真女优名下（合并映射），这里按番号取库行时只认
    // 番号、不认 video_actress 的素人标签。分批查（每批 100 个番号），
    // 避免一次 IN 太大撞上 SQLite 变量上限。
    final extra = <ActressWork>[];
    final resolved = <String>{};
    try {
      final fallback = widget.fallback ?? ActressJsonFallback();
      final injectedFilmDb = widget.filmDb;
      if (injectedFilmDb != null) {
        fallback.filmDb = injectedFilmDb;
      } else if (widget.fallback == null) {
        fallback.filmDb ??=
            _filmDbService ??= FilmLibraryService(database: widget.database);
      }
      final site = widget.siteFilter == ActressSiteFilter.all
          ? null
          : widget.siteFilter.siteId;
      final entries = <ActressJsonEntry>[];
      for (var i = 0; i < missing.length; i += 100) {
        final end = (i + 100).clamp(0, missing.length);
        entries.addAll(
          await _dbEntriesForCodes(
            fallback,
            missing.sublist(i, end),
            site: site,
          ),
        );
      }
      final seenKeys = <String>{};
      for (final entry in entries) {
        final key = normalizeAvCode(entry.vodId);
        if (key.isEmpty) continue;
        // 同番号两站各留一条（与列表去重口径一致）；同一站内只留一条。
        if (!seenKeys.add('${entry.site}|$key')) continue;
        resolved.add(key);
        extra.add(_dbEntryToWork(entry, person.localId));
      }
    } catch (_) {
      // 本地库查不到不堵 who's 兜底。
    }
    // 库里没有的行才走 who's 在线目录。
    for (final code in missing) {
      if (resolved.contains(normalizeAvCode(code))) continue;
      final video = index.videoForCode(code);
      if (video == null) continue;
      extra.add(_whosVideoToWork(video, person.localId));
    }
    if (extra.isEmpty) return;
    if (!mounted || generation != _generation) return;
    // 再确认一次筛选没变（用户可能在索引加载时切了分类/标签）。
    if (_selectedCategory != null || _selectedTag.isNotEmpty) return;
    setState(() {
      _works = [..._works, ...extra];
      _jsonWorksCount = extra.length;
      _filteredTotal += extra.length;
      _headerTotal = _filteredTotal;
      _hasMore = _works.length < _filteredTotal;
    });
  }

  /// 本地库行（按 JSON 番号查到）转作品卡片（对照 videoLibraryWorkFromRow）：
  /// id 留 0（不是人物关联表的行，热换库时 _refetchWork 直接留原样）；
  /// 封面/分类/日期都取本地库行，不走 who's 目录。
  ActressWork _dbEntryToWork(ActressJsonEntry entry, int personId) {
    final code = entry.vodId;
    return ActressWork(
      id: 0,
      personId: personId,
      codeKey: code,
      titleKey: code,
      site: entry.site,
      codeDisplay: code,
      title: entry.vodName,
      date: entry.vodPubdate,
      coverSource: entry.site,
      coverDramaId: code,
      coverUrl: entry.vodPic,
      category: entry.typeName,
    );
  }

  /// who's 视频行转 ActressWork（对照 videoLibraryWorkFromRow）：
  /// id 为 0（不在库里），site/coverSource 记 'whos'，分类为空
  /// （json 没有分类），日期为空（json 没有日期）。
  ActressWork _whosVideoToWork(WhosVideo video, int personId) {
    return ActressWork(
      id: 0,
      personId: personId,
      codeKey: video.code,
      titleKey: video.code,
      site: 'whos',
      codeDisplay: video.code,
      title: video.title,
      date: '',
      coverSource: 'whos',
      coverDramaId: video.code,
      coverUrl: video.pic,
      category: '',
    );
  }

  /// 按 id 在当前库里重取一部作品（热换库后用）：新库里没有了返回 null。
  /// id 为 0 的作品都来自 JSON 补充（who's 在线目录，或按 JSON 番号
  /// 查到的本地库行），直接返回原作品，不按“新库里没有了”处理。
  Future<ActressWork?> _refetchWork(ActressWork work) async {
    // id 为 0 的作品都来自 JSON 补充（who's 在线目录，或按 JSON 番号
    // 查到的本地库行）：它们不在人物关联表里，按人重取查不到，留原样；
    // 播放地址由重建的地址池按番号兜底，不在这里丢掉。
    if (work.id == 0) return work;
    final person = _person;
    if (person == null) return null;
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: 0,
      limit: _works.length + 60,
      category: _selectedCategory,
      videoTag: _worksVideoTag,
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

  /// 点卡秒进详情页播放（2026-11-24 用户令）：
  /// 点卡即推 DetailScreen、首条库地址立即播，不等竞速；
  /// 库里地址与 MissAV 的竞速放后台跑，赢家进会话缓存
  /// （下次点同一番号直接用已验活地址开页）。
  /// 首条地址死了不用重进：DetailScreen 的换线回调
  /// （nextLineOnExhausted）按“库里下一条 → 竞速赢家”顺序
  /// 自动换线；报错屏点“重试”走 onRetryProbe 重探。
  /// 以前是等竞速赢了才开页（A 路 3 条 × 13 秒 + B 路 43 秒，
  /// 最坏开页要 40 多秒），现在开页不等竞速。
  Future<void> _playWork(ActressWork work) async {
    if (_openingDetail) return;
    // 2026-11-20 热换库：播之前先看库文件变了没有——变了就关旧连接
    // 重开，再按当前库重取这部作品与兜底条目，不播缓存的旧地址。
    // 重读失败留旧库并报原因，不崩；作品在新库里没有了就提示并
    // 刷新列表，不硬播。
    var currentWork = work;
    final reload = await widget.database.reloadIfChanged();
    if (reload.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(actressReloadErrorText(reload.error!))),
      );
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
      _fallbackLoad = _loadFallback();
      await _fallbackLoad;
      if (!mounted) return;
    }
    // 取地址：池子第一段（主库 IN 主键取，毫秒级）建好就立刻
    // setState 进 _fallbackEntries，进页后点卡时基本已在。
    // 池子还没建好（刚进页就点卡）最多等 2 秒，不再等整个池子
    // （第二段多库 LIKE 扫要几分钟；原来等 15 秒）。
    // 2026-11-22 用户令（只走数据库）：点卡只试库里存的地址，不再
    // 往下探内置 json/m3u、也不再跨站探活；库里没有这个番号、或库里
    // 的地址全都验不活，就报“库里暂无播放地址”。
    // 库里这个人名下、番号相同的地址行（_fallbackEntries 现在只有 DB 行）。
    // 2026-11-22 修复：作品侧 codeKey 是库里的 vod_id 原样（rki-6042），
    // 兜底条目的 codeKey 是归一化番号（RKI6042）——直接比字符串永远
    // 不相等，导致库里 32 万条直链一条都取不到、点播放只能去跨站爬。
    // 统一归一化比较，见 jsonEntriesForWorkCode。
    List<ActressJsonEntry> dbRows = jsonEntriesForWorkCode(
      _fallbackEntries,
      currentWork.codeKey,
    );
    // 通用库作品没有番号（codeKey 为空、标题里才有番号）时按标题
    // 匹配池子条目：池子里的同一条作品就是从通用库读出来的，
    // 标题相同；标题归一化后为空时不匹配（见 jsonEntriesForWorkTitle）。
    if (dbRows.isEmpty && currentWork.codeKey.trim().isEmpty) {
      dbRows = jsonEntriesForWorkTitle(
        _fallbackEntries,
        currentWork.displayTitle,
      );
    }
    if (dbRows.isEmpty) {
      final poolLoad = _fallbackLoad;
      if (poolLoad != null) {
        try {
          await poolLoad.timeout(const Duration(seconds: 2));
        } catch (_) {
          // 超时：按当前池子走，不在点播里卡住。
        }
        if (!mounted) return;
        dbRows = jsonEntriesForWorkCode(
          _fallbackEntries,
          currentWork.codeKey,
        );
        if (dbRows.isEmpty && currentWork.codeKey.trim().isEmpty) {
          dbRows = jsonEntriesForWorkTitle(
            _fallbackEntries,
            currentWork.displayTitle,
          );
        }
      }
    }
    if (dbRows.isEmpty) {
      // 库里没有可播地址（没有这部、没有直链）：只报这一句，
      // 不落回内置、不探活、不弹去搜索。不进详情页。
      // 2026-11-23：但视频库模式下本页明明有作品（_works 非空）却一条
      // 地址都没取到时，不是“库里没地址”，是影视库那路没打开/没查到
      // ——报实情，别让用户以为库是空的。
      if (!mounted) return;
      final noAddressMessage =
          widget.database.isVideoLibrary && _works.isNotEmpty
          ? '库里没读出这部作品的地址，MissAV 现查也没找到（先检查 MYTV/db/ 下的库文件）'
          : '库里暂无播放地址';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(noAddressMessage)));
      return;
    }
    final playGeneration = ++_playGeneration;
    final cancel = Completer<void>();
    // 后台竞速（不堵开页）：库里地址与 MissAV 按番号现查并行跑，
    // 哪边先出可播地址就先赢，赢家进会话缓存；输的那路丢弃。
    // 开页不等它——首播地址直接播，竞速只用来换线与下次加速。
    final raceFuture = _racePlayableDetail(
      dbRows: dbRows,
      code: currentWork.codeKey,
      title: currentWork.displayTitle,
      cancel: cancel,
      playGeneration: playGeneration,
    );
    final cacheKey = normalizeAvCode(currentWork.codeKey);
    unawaited(
      raceFuture.then((winner) {
        if (winner != null && cacheKey.isNotEmpty) {
          _verifiedDetailCache[cacheKey] = winner;
        }
      }, onError: (_) {}),
    );
    // 首播地址：这番号竞速赢过就用缓存的已验活地址，否则库里第一条
    // （不验活，直接播；库里 99% 以上的地址是活的）。
    // 2026-11-22 主树修法（保留）：探活全失败也拿库里第一条进播放页。
    // 不少流媒体站只认播放器头、探针拿 403/405，但播放器能播；
    // 探活不过不等于播不了。
    final cached = cacheKey.isEmpty ? null : _verifiedDetailCache[cacheKey];
    final firstDetail = cached ?? dbRows.first.toDramaDetail();
    // 换线链：已试过的播放地址（首播那条已在播，换线时跳过）。
    // DetailScreen 在首播地址耗尽时调 nextLineOnExhausted，
    // 在报错屏点“重试”时调 onRetryProbe。
    final triedUrls = <String>{_detailPlayUrl(firstDetail)};
    var raceWinnerUsed = false;
    Future<DetailNextLine?> nextLine() async {
      // 1. 库里下一条没试过的地址（立即有，不用等）。
      for (final row in dbRows) {
        final url = row.playUrl;
        if (url.isEmpty || triedUrls.contains(url)) continue;
        triedUrls.add(url);
        return (detail: row.toDramaDetail(), episodeIndex: 0);
      }
      // 2. 库里地址都试过了，等后台竞速的赢家（MissAV 或已验活的库地址）。
      if (!raceWinnerUsed) {
        raceWinnerUsed = true;
        final winner = await raceFuture.timeout(
          const Duration(seconds: 10),
          onTimeout: () => null,
        );
        if (winner != null) {
          final url = _detailPlayUrl(winner);
          if (url.isNotEmpty && !triedUrls.contains(url)) {
            triedUrls.add(url);
            return (detail: winner, episodeIndex: 0);
          }
        }
      }
      // 链耗尽：返回 null，播放器保留原错误界面。
      return null;
    }

    Future<DetailNextLine?> retryProbe() async {
      // 重试：把已试集合清空（允许重播库里地址），再等一次竞速赢家。
      triedUrls.clear();
      final winner = await raceFuture.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
      if (winner != null) {
        final url = _detailPlayUrl(winner);
        if (url.isNotEmpty) triedUrls.add(url);
        return (detail: winner, episodeIndex: 0);
      }
      // 竞速无赢家：回库里第一条再试一次（播放器原地重播同一集
      // 是兜底，这里给第一条让它换线再试）。
      if (dbRows.isNotEmpty) {
        final first = dbRows.first.toDramaDetail();
        final url = _detailPlayUrl(first);
        if (url.isNotEmpty) triedUrls.add(url);
        return (detail: first, episodeIndex: 0);
      }
      return null;
    }

    _openingDetail = true;
    try {
      await _openDetail(
        firstDetail,
        nextLineOnExhausted: nextLine,
        onRetryProbe: retryProbe,
      );
    } finally {
      _openingDetail = false;
      if (!cancel.isCompleted) cancel.complete();
    }
  }

  /// 取详情首集的播放地址（Episode.id 即直链，见 toDramaDetail）。
  String _detailPlayUrl(DramaDetail detail) {
    if (detail.episodes.isEmpty) return '';
    return detail.episodes.first.id;
  }

  /// MissAV+数据库竞速：两路并行，哪边先出可播地址就先播哪边。
  /// A 路是库里地址逐条 resolve + 验活（最多 3 条）；B 路是 MissAV
  /// 按番号现查（detail 取 m3u8 → resolve → 验活）。先出非空结果的
  /// 胜出，另一路丢弃；两边都失败返回 null。点取消或换了代次时两路
  /// 都尽快收手（返回 null），由 _playWork 按取消处理。
  Future<DramaDetail?> _racePlayableDetail({
    required List<ActressJsonEntry> dbRows,
    required String code,
    required String title,
    required Completer<void> cancel,
    required int playGeneration,
  }) async {
    final winner = Completer<DramaDetail?>();
    var pending = 2;
    void offer(DramaDetail? d) {
      if (d != null && !winner.isCompleted) {
        winner.complete(d);
        return;
      }
      pending--;
      if (pending == 0 && !winner.isCompleted) winner.complete(null);
    }

    unawaited(
      _raceDbAddresses(
        dbRows: dbRows,
        cancel: cancel,
        playGeneration: playGeneration,
      ).then(offer, onError: (_) => offer(null)),
    );
    unawaited(
      _raceMissav(
        code: code,
        title: title,
        cancel: cancel,
        playGeneration: playGeneration,
      ).then(offer, onError: (_) => offer(null)),
    );
    return winner.future;
  }

  /// A 路：库里地址逐条 resolve + 验活，首条活的返回它的详情。
  ///（来源就是条目自己的站，parse=0 直链 + 该站的头）；最多试 3 条，
  /// 点取消立即停。
  Future<DramaDetail?> _raceDbAddresses({
    required List<ActressJsonEntry> dbRows,
    required Completer<void> cancel,
    required int playGeneration,
  }) async {
    for (final entry in dbRows.take(3)) {
      if (cancel.isCompleted || playGeneration != _playGeneration) {
        return null;
      }
      final detail = entry.toDramaDetail();
      try {
        final plan = await widget.repository
            .resolve(detail.drama, detail.episodes.first)
            .timeout(const Duration(seconds: 8));
        if (cancel.isCompleted || playGeneration != _playGeneration) {
          return null;
        }
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
        return detail;
      } catch (_) {
        // 这条死了：换库里下一条地址。
        continue;
      }
    }
    return null;
  }

  /// B 路：MissAV 按番号现查。detailContent('/cn/<番号小写>') 取回
  /// 详情（首集就是 m3u8 直链），resolve 拿播放计划（parse=0 直链
  /// + MissAV 头），验活通过返回该详情；查不到、解析型、验不活
  /// 都返回 null。番号为空时不查（MissAV 按番号取流，没番号没法查）。
  Future<DramaDetail?> _raceMissav({
    required String code,
    required String title,
    required Completer<void> cancel,
    required int playGeneration,
  }) async {
    final normalized = code.trim();
    if (normalized.isEmpty) return null;
    try {
      final drama = Drama(id: normalized, source: 'missav', title: title);
      final detail = await widget.repository
          .detail(drama)
          .timeout(const Duration(seconds: 30));
      if (cancel.isCompleted || playGeneration != _playGeneration) {
        return null;
      }
      if (detail.episodes.isEmpty) return null;
      final plan = await widget.repository
          .resolve(drama, detail.episodes.first)
          .timeout(const Duration(seconds: 8));
      if (cancel.isCompleted || playGeneration != _playGeneration) {
        return null;
      }
      if (plan.needsParse) return null;
      final uri = Uri.tryParse(plan.url.trim());
      if (uri == null ||
          !(uri.scheme == 'http' || uri.scheme == 'https') ||
          uri.host.isEmpty) {
        return null;
      }
      final response = await _verifyFetch(
        plan.url,
        plan.headers,
        const Duration(seconds: 5),
      );
      if (!feedProbePlayable(uri, response)) return null;
      return detail;
    } catch (_) {
      return null;
    }
  }

  /// 库里地址直进详情页：首选线路进页即播（initialDetail 带进去：
  /// 站点详情取回是空的时就用它播）。不接探活链——无链可续，
  /// 播耗尽时详情页只按自身线路走。
  /// 推详情页并立即播首集。换线回调由点卡流程注入：
  /// 首播地址耗尽时 DetailScreen 调 nextLineOnExhausted 要下一条，
  /// 报错屏点“重试”时调 onRetryProbe 重探。不传时行为与此前一字不差。
  Future<void> _openDetail(
    DramaDetail detail, {
    Future<DetailNextLine?> Function()? nextLineOnExhausted,
    Future<DetailNextLine?> Function()? onRetryProbe,
  }) async {
    await Navigator.of(context).push(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'detail'),
        builder: (_) => DetailScreen(
          drama: detail.drama,
          repository: widget.repository,
          store: widget.store,
          autoPlayOnOpen: true,
          autoPlayEpisodeIndex: 0,
          // 候选那条的集数（数据库里存的直链）带进去：站点详情取回
          // 是空的时就用它播，不显示“该站未返回详情”就没得播。
          initialDetail: detail,
          nextLineOnExhausted: nextLineOnExhausted,
          onRetryProbe: onRetryProbe,
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
      appBar: actressNeonAppBar(title: Text(person?.displayName ?? '女优详情')),
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator())
              : person == null
              ? Center(
                  child: Text(
                    _noDatabase
                        ? '未找到外置数据库：请把 女优库.db 放进 MYTV/db/，再点“重新加载数据库”'
                        : '人物不存在',
                  ),
                )
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
                    // 播放地址池一直不显示（2026-11-20 用户定：内置
                    // 播放源不能让别人看出来），只做后台点播用（只读
                    // 女优库.db，见 _playWork）。本地零作品时只显示
                    // “暂无作品”，不再为地址池留位置。
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
                            // 海报中央透明播放键（2026-11-25）：DramaTile
                            // 是全站共用卡片，不动它；只在本页叠一层纯
                            // 装饰键（IgnorePointer，点按仍由卡片接管，
                            // 走 _playWork 秒进详情页播，行为一字不差）。
                            // 键只盖海报区（DramaTile 海报 2/3，高 =
                            // 宽 × 1.5），不盖下面的标题/副标题。
                            return LayoutBuilder(
                              builder: (context, constraints) {
                                return Stack(
                                  children: [
                                    DramaTile(
                                      key: ValueKey('actress-work-${work.id}'),
                                      drama: actressWorkDrama(work),
                                      repository: widget.repository,
                                      subtitle: actressWorkSubtitle(work),
                                      onTap: () => _playWork(work),
                                    ),
                                    Positioned(
                                      top: 0,
                                      left: 0,
                                      right: 0,
                                      height: constraints.maxWidth * 1.5,
                                      child: const IgnorePointer(
                                        child: Center(
                                          child: ActressPosterPlayKey(),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            );
                          }, childCount: _works.length + (_hasMore ? 1 : 0)),
                        ),
                      ),
                  ],
                ),
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
                  '作品 ${_headerTotal > 0 ? _headerTotal : person.displayWorks} 部'
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
  /// 2026-11-24 标签筛选：最前面同样放“标签”入口（点开底部弹窗
  /// 换标签）；选了标签时显示“标签：<名>”+“清除”。
  Widget _buildCategoryFilter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _categoryChip(
              label: _selectedTag.isEmpty
                  ? '标签'
                  : '标签：$_selectedTag',
              selected: _selectedTag.isNotEmpty,
              onTap: _openTagSheet,
            ),
            if (_selectedTag.isNotEmpty)
              _categoryChip(
                label: '清除',
                selected: false,
                onTap: () => _setTag(''),
              ),
            _categoryChip(
              label: '全部',
              selected: _selectedCategory == null,
              onTap: () => _selectCategory(null),
            ),
            for (final category in _categories)
              _categoryChip(
                label: '${category.name}（${category.count}）',
                selected: _selectedCategory == category.name,
                onTap: () => _selectCategory(category.name),
              ),
          ],
        ),
      ),
    );
  }

  /// 打开标签筛选底部弹窗（与列表页同一份 ActressTagSheet）：
  /// 列出数据库里的全部标签，点标签即筛本页作品，点“全部”即清空。
  /// 没有标签也照常打开，如实显示“暂无标签”。
  Future<void> _openTagSheet() async {
    List<(String, int)> tags;
    try {
      tags = await widget.database.dbTags();
    } catch (_) {
      tags = const [];
    }
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: ActressTagSheet(
          tags: tags,
          selected: _selectedTag,
          onSelected: (tag) => Navigator.of(sheetContext).pop(tag),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await _setTag(selected);
  }

  Future<void> _setTag(String tag) async {
    if (_selectedTag == tag) return;
    setState(() => _selectedTag = tag);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _loadPage(reset: true);
  }

  Widget _categoryChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActressNeonPill(
        key: ValueKey('actress-category-$label'),
        label: label,
        selected: selected,
        onTap: onTap,
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
