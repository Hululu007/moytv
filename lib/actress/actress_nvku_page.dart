import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../models.dart';
import '../player_picker.dart';
import 'actress_av_style.dart';
import 'actress_database.dart';
import 'actress_db_manage_page.dart';
import 'actress_working_db.dart';
import 'actress_film_library.dart';
import 'actress_list_page.dart';
import 'actress_nvku_cache.dart';
import 'actress_online_sources.dart';
import 'actress_online_view.dart';
import 'javdb_view.dart';
import 'actress_ranking_page.dart';
import 'actress_tag_sheet.dart';
import '../whos_fallback.dart';
import '../whos_local_library.dart';

/// 女优库（2026-11-21 用户令：模块区域 UI 改用 nvku 那套网页的样式，
/// 在线站与本地数据库同一套分类与标签索引）。
///
/// 版式照 nvku-8m2c 的网页来：深色底 + 顶栏品牌/条数徽标 + 搜索框 +
/// 底部四个页签（首页 / 分类 / 女优 / 收藏）。数据两条腿：
/// - 在线：nvku 内置源（32 万条、有码/无码/4K/其它），分类与条数取自
///   站点自己的 meta；
/// - 本地：用户本地 whos 库 + 用户视频库（MYTV/db），分类/厂牌标签与
///   数据库同一口径，在线取不到内容时自动降级到本地，不留白屏。
/// 「女优」页签就是原来的女优库列表页（本地库名册 + 站点筛选 +
/// 同步/现爬都在那边），这里只换外壳，不重做数据层。
///
/// 2026-11-26 用户令收口：演员库就用这套原生界面（合并网页
/// 路线作废、入口改回本页）；底部导航删掉「分类」一项（原分类
/// 页签打开的是类型文件夹视图，随该项一并撤下，见本批报告）；
/// 顶部加一条源切换条，123AV 与 PH 两个在线源只进源切换
/// （Dart 直连，见 actress_online_view.dart），不动底部导航
/// 结构。在线 who's 仍走 py 版 who's 源链，不走网页抓取。
class ActressNvkuPage extends StatefulWidget {
  const ActressNvkuPage({
    super.key,
    required this.repository,
    required this.store,
    this.database,
    this.showTitle = true,
    this.filmService,
  });

  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase? database;
  final bool showTitle;

  /// 影视库服务（标签读库用）：不传时页内自己建一个
  /// （绑 MYTV/db 的库）；测试可注入假服务，不碰真库。
  final FilmLibraryService? filmService;

  @override
  State<ActressNvkuPage> createState() => _ActressNvkuPageState();
}

const _favKey = 'actress_nvku_fav';

/// 分类名去尾数：“有码 · 251867”→“有码”；没尾数原样返回。
/// 尾数不是数字时也原样返回（名字里本来就带“ · ”的不误伤）。
String cleanNvkuCategoryName(String name) {
  final index = name.lastIndexOf(' · ');
  if (index <= 0) return name.trim();
  final tail = name.substring(index + 3).trim();
  if (tail.isEmpty || int.tryParse(tail) == null) return name.trim();
  return name.substring(0, index).trim();
}

/// 选中分类 → 视频主分类名（供本地兜底按主分类筛库）：
/// 站点分类 c0/c1… 的名字就是主分类名（去尾数后），主分类标签
/// main:xxx 直接取冒号后的名字；最新/排行/厂牌不过滤（回空）。
String nvkuVideoCategoryFor(
  String category,
  List<CatalogCategory> siteCategories,
) {
  if (category.startsWith('main:')) {
    return category.substring('main:'.length).trim();
  }
  if (category == 'new' ||
      category == 'rank' ||
      category.startsWith('brand:')) {
    return '';
  }
  for (final site in siteCategories) {
    if (site.id != category) continue;
    return cleanNvkuCategoryName(site.name);
  }
  return '';
}

/// 全部可点标签：站点分类打头，本地分类（最新/排行/厂牌）随后，
/// 库里主分类补在最后——站点已有的主分类（同名）不重复摆，
/// 站被挡时主分类标签照样全在。
List<CatalogCategory> nvkuAllCategories(
  List<CatalogCategory> siteCategories,
  List<CatalogCategory> localCategories,
  List<CatalogCategory> mainCategories,
) {
  final covered = <String>{
    for (final site in siteCategories) cleanNvkuCategoryName(site.name),
  };
  return [
    ...siteCategories,
    ...localCategories.where(
      (row) => !siteCategories.any((site) => site.id == row.id),
    ),
    ...mainCategories.where(
      (row) => !covered.contains(cleanNvkuCategoryName(row.name)),
    ),
  ];
}

class _ActressNvkuPageState extends State<ActressNvkuPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  var _tab = 0;
  // 在线源（2026-11-26）：顶部源切换条的状态——_onlineId 非空
  // = 123AV / PH 在线源激活（'' 是女优库本体）；在线搜索词与
  // 刷新计数单独记，不与女优库的作品搜索互相污染。
  var _onlineId = '';
  var _onlineQuery = '';
  var _onlineRefreshTick = 0;

  /// 库代次：管理页导入/换库回来后 +1，女优列表页换 key 重
  /// 建重读（见 _actressTab 的 key 与 _openDbManagePage）。
  var _dbEpoch = 0;
  var _query = '';

  var _siteCategories = <CatalogCategory>[];
  var _localCategories = <CatalogCategory>[];
  var _mainCategories = <CatalogCategory>[];
  var _category = 'new';
  var _works = <Drama>[];
  var _page = 1;
  var _hasMore = true;
  var _loading = false;
  var _loadingMore = false;
  var _offline = false;
  var _favorites = <_FavItem>[];
  var _generation = 0;

  /// 影视库服务（标签读库）：注入的直接用，没注入的页内建
  /// 一个（绑 MYTV/db 的库）；[_ownsFilmService] 为真时退出关掉。
  FilmLibraryService? _filmService;
  var _ownsFilmService = false;

  /// 顶部库名标题（2026-11-24 文件夹视图）：当前读的是哪个库的
  /// 文件名（例如“女优库.db”），只当标题/标识，不做分类；没绑上
  /// 库、或库打不开时为空，顶栏回落显示“女优库”。
  var _dbTitle = '';

  /// 当前库文件指纹（路径 + mtime + 大小，见 [NvkuEntryCache.dbStamp]）：
  /// 文件夹/标签/分类缓存的 key 成分，库文件一变就自然失效、重查。
  /// [_loadFilmLibrary] 开库后记下；开库失败时为空，缓存只按路径分。
  var _dbStamp = '';

  /// 女优 tab 是不是已经打开过（2026-11-24 进库不重载）：页签
  /// 用 IndexedStack 常驻，列表页状态才不会在切走时被释放；但
  /// 列表页首次构建就会跑它的 _bootstrap（开库、读分类、读第一页），
  /// 不能在进库首页时就替用户提前跑——第一次点到女优 tab 时才建，
  /// 建好后常驻、再切回来不再重跑。
  var _actressTabVisited = false;
  /// 标签筛选（2026-11-24，与列表页同一套）：[_videoTag] 是当前
  /// 选中的标签（空 = 全部）；[_tags] 是弹窗里列的全部标签
  /// （带作品数）。原先随标签一起传给文件夹查询的 filters 键
  /// （tags() 回的 key）随分类页签撤下后无人再用，一并去掉。
  var _videoTag = '';
  var _tags = <(String, int)>[];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _filmService = widget.filmService;
    _ownsFilmService = _filmService == null;
    if (_filmService == null) {
      _filmService = FilmLibraryService(
        database: widget.database ?? SqfliteActressDatabase.instance,
      );
    }
    unawaited(_boot());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    final service = _filmService;
    _filmService = null;
    if (_ownsFilmService && service != null) {
      unawaited(service.close());
    }
    super.dispose();
  }

  Future<void> _boot({bool refresh = false}) async {
    // 手动刷新（下拉刷新、顶栏刷新钮）才清会话缓存、重查全部；
    // 平常进库走缓存（见 [NvkuEntryCache]），第二次进不再全量重查。
    if (refresh) NvkuEntryCache.clear();
    await _loadFavorites();
    // 影视库先开（库名标题/标签随后要用）；库打不开时这里直接
    // 回空，不挡后面的作品加载。
    await _loadFilmLibrary();
    await _loadCategories();
    await _loadWorks(reset: true);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      unawaited(_loadWorks());
    }
  }

  Future<void> _loadCategories() async {
    // 进库不重载：三份分类都在会话缓存里（站点按站 id、本地/主分类
    // 按库文件指纹），命中直接用，不走网络、不跑 GROUP BY。
    final siteCached = NvkuEntryCache.siteCategories(nvkuSourceId);
    final localCached = NvkuEntryCache.localCategories(_dbStamp);
    final mainCached = NvkuEntryCache.mainCategories(_dbStamp);
    if (siteCached != null && localCached != null && mainCached != null) {
      if (!mounted) return;
      _applyCategories(
        site: siteCached.items,
        local: localCached,
        mains: mainCached,
        offline: siteCached.offline,
      );
      return;
    }
    var online = const <CatalogCategory>[];
    var offline = false;
    try {
      online = await widget.repository.categories(nvkuSourceId);
    } catch (_) {
      offline = true;
    }
    final library = WhosLocalLibrary.shared;
    final loaded = await library.ensureLoaded();
    final local = loaded
        ? await whosLocalCategoriesAsync(library)
        : const <CatalogCategory>[];
    // 库里视频主分类（有码/无码/国产/4K…）：站点分类取不到时（站被挡）
    // 也能摆出全部主分类标签；站点已有的主分类不重复摆。
    final mains = loaded
        ? await library.mainCategoriesAsync()
        : const <({String name, int count})>[];
    final mainCats = [
      for (final row in mains)
        CatalogCategory('main:${row.name}', '${row.name} · ${row.count}'),
    ];
    NvkuEntryCache.putSiteCategories(
      nvkuSourceId,
      online,
      offline: offline || online.isEmpty,
    );
    NvkuEntryCache.putLocalCategories(_dbStamp, local);
    NvkuEntryCache.putMainCategories(_dbStamp, mainCats);
    if (!mounted) return;
    _applyCategories(
      site: online,
      local: local,
      mains: mainCats,
      offline: offline || online.isEmpty,
    );
  }

  /// 三份分类落到状态里（取数与缓存共用同一份落点，别各写一份）：
  /// 选中分类不在新分类里时回落到“最新”，不留一个指不到的分类。
  void _applyCategories({
    required List<CatalogCategory> site,
    required List<CatalogCategory> local,
    required List<CatalogCategory> mains,
    required bool offline,
  }) {
    setState(() {
      _siteCategories = site;
      _localCategories = local;
      _mainCategories = mains;
      _offline = offline;
      if (_category.isEmpty ||
          ![
            'new',
            ...site.map((c) => c.id),
            ...local.map((c) => c.id),
            ...mains.map((c) => c.id),
          ].contains(_category)) {
        _category = 'new';
      }
    });
  }

  /// 打开影视库服务并取库名标题、标签列表：库打不开（没绑库/
  /// 文件不存在）时标题留空、标签留空，不抛错、不挡后面的
  /// 作品加载。（类型文件夹视图已随底部「分类」页签撤下，
  /// 2026-11-26 用户令，本方法不再加载文件夹。）
  Future<void> _loadFilmLibrary() async {
    final service = _filmService;
    if (service == null) return;
    final result = await service.open();
    // 开库后记下库文件指纹：文件夹/标签/分类缓存的 key 成分，库文件
    // 一变（同步写库、用户换文件）缓存就自然失效、重查。
    _dbStamp = NvkuEntryCache.dbStamp(result.dbPath);
    if (!mounted) return;
    if (result.error == null && result.displayPath.isNotEmpty) {
      final name = result.displayPath.split('/').last.trim();
      if (name.isNotEmpty) setState(() => _dbTitle = name);
    }
    await _loadTags();
  }

  /// 标签列表：服务 open 之后调；严格结构读 video_tag 表，通用
  /// 结构走 tagFacet。进库不重载：命中会话缓存直接用，不再跑
  /// video_tag 全表聚合。
  Future<void> _loadTags() async {
    final service = _filmService;
    if (service == null) return;
    final cached = NvkuEntryCache.tags(_dbStamp, strict: service.isStrict);
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _tags = cached.values;
      });
      return;
    }
    // 2026-11-25 转圈死锁修复：tags() 原来无 try/catch，抛错会变
    // 未处理的异步错误；标签只是筛选入口，失败就留空、不挡页面。
    try {
      final tags = await service.tags().timeout(const Duration(seconds: 15));
      NvkuEntryCache.putTags(
        _dbStamp,
        strict: service.isStrict,
        value: tags,
      );
      if (!mounted) return;
      setState(() {
        _tags = tags.values;
      });
    } catch (_) {
      return;
    }
  }

  /// 标签底部弹窗（2026-11-24，与列表页同一只弹窗）：标签列表由
  /// 服务查好；没标签时弹窗如实显示“暂无标签”。点标签后记下
  /// 选中态（见 [_setVideoTag]）。
  Future<void> _openTagSheet() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: ActressTagSheet(
          tags: _tags,
          selected: _videoTag,
          onSelected: (name) => Navigator.pop(context, name),
        ),
      ),
    );
    if (picked == null) return;
    await _setVideoTag(picked);
  }

  /// 选标签（2026-11-26 起只记选择态）：原先选标签是给已撤下的
  /// 类型文件夹视图筛选计数用的；分类页签撤下后，标签行与弹窗
  /// 照原 UI 保留，选中态仍如实显示在标签行上。
  Future<void> _setVideoTag(String tag) async {
    if (_videoTag == tag) return;
    setState(() => _videoTag = tag);
  }

  /// 标签入口行：没选时只显示“标签”，选了显示“标签：<名>”高亮 +
  /// “清除”一键清掉；与列表页同一套样式（霓虹药丸钮）。
  Widget _buildTagRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          AvPill(
            key: const ValueKey('nvku-tag-open'),
            label: _videoTag.isEmpty ? '标签' : '标签：$_videoTag',
            selected: _videoTag.isNotEmpty,
            onTap: _openTagSheet,
          ),
          if (_videoTag.isNotEmpty) ...[
            const SizedBox(width: 8),
            AvPill(
              key: const ValueKey('nvku-tag-clear'),
              label: '清除',
              selected: false,
              compact: true,
              onTap: () => unawaited(_setVideoTag('')),
            ),
          ],
        ],
      ),
    );
  }

  /// 作品分页：在线优先，站挂了/取不到就换本地库（分类 id 在两边的
  /// 命名一致：new / rank / brand:xxx，站点分类是 c0/c1/c2/c7）。
  Future<void> _loadWorks({bool reset = false}) async {
    if (reset) {
      final generation = ++_generation;
      // 进库不重载：5 分钟内的第一页缓存直接上、不取网络；过期了
      // 先上旧页、后台悄悄刷一遍再换新页（不转圈、不清列表）。
      final cached = NvkuEntryCache.worksFirstPage(_category, _query);
      if (cached != null) {
        setState(() {
          _works = cached.rows;
          _page = 2;
          _hasMore = cached.hasMore;
          _loading = false;
          // 2026-11-25 防卡死：翻页进行中切分类，旧翻页回来代际
          // 已顶掉直接 return，_loadingMore 会停在 true，之后新
          // 分类滑到底全被守卫挡掉（只出第一页、再往下翻不动）。
          // reset 是代际的唯一入口，在这里清标志才是根因修。
          _loadingMore = false;
        });
        if (cached.isFresh) return;
        final rows = await _fetchPage(1);
        if (!mounted || generation != _generation) return;
        NvkuEntryCache.putWorksFirstPage(
          _category,
          _query,
          rows: rows,
          hasMore: rows.length >= _pageSize,
        );
        setState(() {
          _works = rows;
          _hasMore = rows.length >= _pageSize;
        });
        return;
      }
      setState(() {
        _loading = true;
        _works = [];
        _page = 1;
        _hasMore = true;
        _loadingMore = false;
      });
      final rows = await _fetchPage(1);
      if (!mounted || generation != _generation) return;
      NvkuEntryCache.putWorksFirstPage(
        _category,
        _query,
        rows: rows,
        hasMore: rows.length >= _pageSize,
      );
      setState(() {
        _works = rows;
        _page = 2;
        _hasMore = rows.length >= _pageSize;
        _loading = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore || _loading) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    // 2026-11-25 防卡死：_fetchPage 抛错（本地库取数失败）会直接
    // 穿出本方法，_loadingMore 停在 true、之后滑到底再也翻不了页。
    // 抛错只复位本代际的标志，不碰已切走的新代际。
    late final List<Drama> rows;
    try {
      rows = await _fetchPage(_page);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
      return;
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = [..._works, ...rows];
      _page += 1;
      _hasMore = rows.length >= _pageSize;
      _loadingMore = false;
    });
  }

  static const _pageSize = 30;

  Future<List<Drama>> _fetchPage(int page) async {
    // 2026-11-25 排行榜是本地榜单：站源没有 rank 段，问蜘蛛会被
    // nvku.py 的 _cat_index 静默回落到最新（点排行榜和点最新上架
    // 出同一份列表），所以 rank 不走在线、直接走本地库；搜的时候
    // 不受影响（搜词优先）。
    final isRank = _category == whosLocalRankCategory && _query.isEmpty;
    if (!isRank) {
      try {
        final result = await widget.repository.catalog(
          nvkuSourceId,
          page: page,
          query: _query,
          category: _category,
        );
        if (result.items.isNotEmpty) return result.items;
        if (_query.isNotEmpty || page > 1) return result.items;
      } catch (_) {
        if (mounted && !_offline) setState(() => _offline = true);
      }
    }
    // 本地兜底：站被挡/取不到时用本地 whos 库与视频库顶上，分类照旧可用。
    // 2026-11-25 防卡死：本地取数抛错（库文件坏/表缺失）不能穿出
    // _fetchPage——reset 支路会留 _loading 永久真、整页无限转圈；
    // 这里吞掉记离线、回空列表，让界面出空态/重试而不是转圈。
    try {
      final library = WhosLocalLibrary.shared;
      if (!await library.ensureLoaded()) return const [];
      final rows = await library.pageAsync(
        category: _localCategoryFor(_category),
        videoCategory: _videoCategoryFor(_category),
        query: _query,
        page: page,
        pageSize: _pageSize,
      );
      return [
        for (final work in rows) whosLocalToDrama(work, source: nvkuSourceId),
      ];
    } catch (_) {
      if (mounted && !_offline) setState(() => _offline = true);
      return const [];
    }
  }

  /// 站点分类 → 本地库分类：站点分类（c0/c1/c2/c7）库里没有对应
  /// 维度，落回「最新」；其余 new/rank/brand: 两边同名直接用。
  String _localCategoryFor(String category) {
    if (category.startsWith('brand:') ||
        category == 'rank' ||
        category == 'new') {
      return category;
    }
    return 'new';
  }

  /// 选中分类 → 视频主分类名（供本地兜底按主分类筛库）：
  /// 站点分类 c0/c1… 的名字就是主分类名（“有码 · 251867”去尾数），
  /// 主分类标签 main:xxx 直接取冒号后的名字；最新/排行/厂牌不过滤。
  String _videoCategoryFor(String category) =>
      nvkuVideoCategoryFor(category, _siteCategories);

  /// 分类名去尾数：“有码 · 251867”→“有码”；没尾数原样返回。
  static String _cleanCategoryName(String name) =>
      cleanNvkuCategoryName(name);

  /// 全部可点标签（首页与分类页共用）：站点分类打头，本地分类
  /// （最新/排行/厂牌）随后，库里主分类补在最后——站点已有的
  /// 主分类（同名）不重复摆，站被挡时主分类标签照样全在。
  List<CatalogCategory> _allCategories() => nvkuAllCategories(
    _siteCategories,
    _localCategories,
    _mainCategories,
  );

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_favKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((row) => _FavItem.fromJson(Map<String, dynamic>.from(row)))
          .toList();
      if (!mounted) return;
      setState(() => _favorites = list);
    } catch (_) {
      // 坏数据不影响页面。
    }
  }

  Future<void> _toggleFavorite(Drama drama) async {
    final hit = _favorites.indexWhere((row) => row.id == drama.id);
    final next = List<_FavItem>.of(_favorites);
    if (hit >= 0) {
      next.removeAt(hit);
    } else {
      next.insert(
        0,
        _FavItem(
          id: drama.id,
          source: drama.source,
          title: drama.title,
          cover: drama.cover,
          code: drama.tags.isNotEmpty ? drama.tags.first : '',
        ),
      );
    }
    setState(() => _favorites = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _favKey,
      jsonEncode([for (final row in next) row.toJson()]),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(hit >= 0 ? '已取消收藏' : '已收藏')));
  }

  bool _isFavorite(String id) => _favorites.any((row) => row.id == id);

  Future<void> _play(Drama drama) async {
    try {
      final detail = await widget.repository.detail(drama);
      if (!mounted) return;
      if (detail.episodes.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这条暂时没有可播地址')));
        return;
      }
      await pushPlayer<void>(
        context,
        detail: detail,
        initialIndex: 0,
        repository: widget.repository,
        store: widget.store,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条暂时取不到播放地址')));
    }
  }

  void _submitSearch(String value) {
    final next = value.trim();
    // 在线源激活（2026-11-26）：统一搜索框切到哪源搜哪源——词
    // 下传给在线视图按该源重搜，不碰女优库的作品列表。
    if (_onlineId.isNotEmpty) {
      setState(() => _onlineQuery = next);
      return;
    }
    // 女优页签（2026-11-21）：这条搜索框由演员列表页接管（同一个
    // controller，列表自己 debounce 搜索），这里不再拿它搜作品，
    // 免得把「首页」那套作品列表也一起刷一遍。
    if (_tab == 1) {
      setState(() {});
      return;
    }
    if (next == _query) return;
    setState(() => _query = next);
    unawaited(_loadWorks(reset: true));
  }

  void _pickCategory(String id) {
    if (_category == id) return;
    setState(() => _category = id);
    unawaited(_loadWorks(reset: true));
  }

  /// 影片库入口（2026-11-22：主树此前没有通往 FilmLibraryPage 的
  /// 入口——列表页右上角的按钮 2026-11-21 按用户令删掉了；活树是靠
  /// 底部五页签胶囊栏进，本页保留四页签不接五页签，入口改放在
  /// 顶栏搜索框旁的霓虹药丸钮上，独立/内嵌两种模式都看得见。
  /// 排行榜入口不动：女优页签内嵌工具栏里的奖杯钮（列表页
  /// _toolbarActions 的 open-actress-ranking）。
  void _openFilmLibrary() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FilmLibraryPage(
          database: widget.database ?? SqfliteActressDatabase.instance,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  /// 管理弹层（2026-11-26 16:55 用户令「设置不能少」）：顶栏
  /// 管理钮打开，挂齐数据库管理整套入口——数据库管理页（导
  /// 入 .sql / 表格更新 / 导出 / 备份恢复 / 删除数据库都在
  /// 里面）、影片库、重新加载数据库。女优列表页齿轮里的设
  /// 置弹窗照旧保留，两处入口并行不冲突。管理页回来后 bump
  /// 库代次重建女优列表页，导入/换库结果立刻可见。
  Future<void> _openManageSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AvStyle.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                '管理',
                style: TextStyle(
                  color: AvStyle.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _manageRow(
              icon: Icons.storage_rounded,
              title: '数据库管理',
              subtitle: '导入 .sql、表格更新、导出、备份恢复、删除数据库',
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_openDbManagePage());
              },
            ),
            _manageRow(
              icon: Icons.video_library_rounded,
              title: '影片库',
              subtitle: '浏览绑定的库文件、把作品追加进女优库',
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openFilmLibrary();
              },
            ),
            _manageRow(
              icon: Icons.refresh_rounded,
              title: '重新加载数据库',
              subtitle: '库文件换了或刚导入完，点这里重读',
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_reloadDatabase());
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _manageRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: AvStyle.accent),
      title: Text(
        title,
        style: const TextStyle(
          color: AvStyle.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AvStyle.dim, fontSize: 12),
      ),
      onTap: onTap,
    );
  }

  /// 数据库管理页（与女优列表页齿轮里同一个页、同一套回调
  /// 口径）：导完/恢复/删库后页面自己会调 reloadDatabase，
  /// 回到本页再 bump 代次让女优列表重读。
  Future<void> _openDbManagePage() async {
    final db = widget.database ?? SqfliteActressDatabase.instance;
    final dbPath = await actressWorkingDbPath();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ActressDbManagePage(
          dbPath: dbPath,
          closeDatabase: db.close,
          reloadDatabase: () async {
            await db.reloadIfChanged();
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _dbEpoch++);
  }

  /// 重新加载数据库（顶栏管理弹层直达）：库文件戳变了才真
  /// 重读，结果用提示条如实报（已重载/没变化/失败原因）。
  Future<void> _reloadDatabase() async {
    final db = widget.database ?? SqfliteActressDatabase.instance;
    final result = await db.reloadIfChanged();
    if (!mounted) return;
    if (result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(actressReloadErrorText(result.error!))),
      );
      return;
    }
    setState(() => _dbEpoch++);
    unawaited(_boot(refresh: true));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.reloaded ? '已重新加载数据库' : '数据库没有变化'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final online = _onlineId.isNotEmpty;
    return Scaffold(
      // 2026-11-26 照 AvPlay 截图改浅色：白底（本模块三屏统一）。
      backgroundColor: AvStyle.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            _sourceBar(),
            Expanded(
              // 进库不重载（内层）：三个页签用 IndexedStack 常驻，切走
              // 再回来状态还在——女优列表页不再每次重跑 _bootstrap，
              // 首页的滚动位置也保住。女优 tab 第一次点到时才建
              // （_actressTabVisited），不提前跑它的开库流程。
              // 切到在线源时换成在线视图（女优库页签状态在页面
              // State 里，切回来不重查）。
              child: _onlineId == 'javdb'
                  ? JavdbSourceView(
                      key: const ValueKey('actress-online-javdb'),
                      initialQuery: _onlineQuery,
                      repository: widget.repository,
                      store: widget.store,
                    )
                  : online
                  ? ActressOnlineSourceView(
                      key: ValueKey('actress-online-$_onlineId'),
                      source: actressOnlineSourceById(_onlineId)!,
                      repository: widget.repository,
                      store: widget.store,
                      query: _onlineQuery,
                      refreshTick: _onlineRefreshTick,
                    )
                  : IndexedStack(
                      index: _tab,
                      children: [
                        _homeTab(),
                        _actressTabVisited
                            ? _actressTab()
                            : const SizedBox.shrink(),
                        _favoriteTab(),
                      ],
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _bottomTabs(),
    );
  }

  /// 底部三页签切换：点到女优 tab 时记下已访问（下次起常驻）。
  void _selectTab(int index) {
    setState(() {
      if (index == 1) _actressTabVisited = true;
      _tab = index;
    });
  }

  /// 源切换条（2026-11-26 用户令）：女优库为首段默认，其后是
  /// JavDB 接口演员库（17:18 令挨着 who's 加）、123AV、PH；
  /// 只进源切换，不动底部导航结构。
  /// 数据库管理/导入入口：女优列表页齿轮弹窗里照旧保留，
  /// 顶栏另加管理钮弹层直达（2026-11-26 16:55「设置不能
  /// 少」），两处并行。
  Widget _sourceBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Row(
        children: [
          AvPill(
            key: const ValueKey('actress-source-nvku'),
            label: '女优库',
            selected: _onlineId.isEmpty,
            onTap: () => _selectSource(''),
          ),
          const SizedBox(width: 8),
          AvPill(
            key: const ValueKey('actress-source-javdb'),
            label: 'JavDB',
            selected: _onlineId == 'javdb',
            onTap: () => _selectSource('javdb'),
          ),
          for (final source in kActressOnlineSources) ...[
            const SizedBox(width: 8),
            AvPill(
              key: ValueKey('actress-source-${source.id}'),
              label: source.label,
              selected: _onlineId == source.id,
              onTap: () => _selectSource(source.id),
            ),
          ],
        ],
      ),
    );
  }

  /// 源切换：女优库（本地库直读 + py 版 who's 链）与两个在线
  /// 源之间切；切源不清搜索框，在线源的词单独记在 [_onlineQuery]。
  void _selectSource(String id) {
    if (_onlineId == id) return;
    setState(() => _onlineId = id);
  }

  /// 顶栏（2026-11-26 照 AvPlay 截图改浅色：白底 + 浅灰底边，
  /// 搜索框浅灰填充；结构不变——搜索框本来就嵌在顶栏里、
  /// showTitle=false 内嵌时宿主已有自己的顶栏，再套一层
  /// AppBar 会叠两条栏）。
  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
      decoration: const BoxDecoration(
        color: AvStyle.bg,
        border: Border(bottom: BorderSide(color: AvStyle.border)),
      ),
      child: Column(
        children: [
          // 2026-11-22 用户令（顶栏合并全部在顶部）：这一页嵌在片库顶栏
          // 里时（showTitle=false），外层已经有品牌条了，这里不能再出
          // 一条“女优库 + 本地库 + 刷新”，只留搜索框，避免两条顶栏。
          if (widget.showTitle) ...[
            Row(
            children: [
              Flexible(
                child: Text(
                  // 2026-11-24 文件夹视图：顶栏标题显示当前数据库名
                  // （例如“女优库.db”），只当标题/标识、说明现在读
                  // 的是哪个库；库名不做分类（老令不变）。没绑上库时
                  // 回落显示“女优库”。
                  _dbTitle.isEmpty ? '女优库' : _dbTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AvStyle.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AvStyle.accentSoft,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _onlineId.isNotEmpty
                      ? actressOnlineSourceById(_onlineId)!.label
                      : _offline
                      ? '本地库'
                      : '在线 + 本地',
                  style: const TextStyle(
                    color: AvStyle.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, color: AvStyle.dim, size: 20),
                onPressed: () {
                  // 在线源激活时刷新只重拉在线列表；女优库模式
                  // 照旧整页刷新（清会话缓存重查）。
                  if (_onlineId.isNotEmpty) {
                    setState(() => _onlineRefreshTick++);
                  } else {
                    unawaited(_boot(refresh: true));
                  }
                },
              ),
              IconButton(
                key: const ValueKey('nvku-manage-open'),
                tooltip: '管理',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.settings_outlined,
                  color: AvStyle.dim,
                  size: 20,
                ),
                onPressed: () => unawaited(_openManageSheet()),
              ),
            ],
          ),
            const SizedBox(height: 8),
          ],
          // 2026-11-24 文件夹视图：内嵌进片库顶栏时（showTitle=false）
          // 宿主已有自己的顶栏，这里不另出标题行；但当前库名还是要让
          // 用户在顶部一眼看到（说明现在读的是哪个库），只给一行小字
          // 标识，不恢复被禁的那条“女优库 + 本地库 + 刷新”标题行。
          if (!widget.showTitle && _dbTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_rounded,
                    size: 13,
                    color: AvStyle.dim,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '当前库：$_dbTitle',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AvStyle.dim,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('nvku-search'),
                  controller: _search,
                  onSubmitted: _submitSearch,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(color: AvStyle.text, fontSize: 15),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: _onlineId.isNotEmpty
                        ? '在本源搜片名 / 番号'
                        : _tab == 1
                        ? '搜女优名 / 番号'
                        : '搜索 番号、影片、演员',
                    hintStyle: const TextStyle(color: AvStyle.dim, fontSize: 14),
                    prefixIcon: const Icon(Icons.search, color: AvStyle.dim, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, color: AvStyle.dim, size: 18),
                            onPressed: () {
                              _search.clear();
                              if (_onlineId.isNotEmpty) {
                                setState(() => _onlineQuery = '');
                              } else if (_tab == 1) {
                                setState(() {});
                              } else {
                                _submitSearch('');
                              }
                            },
                          ),
                    filled: true,
                    fillColor: AvStyle.fieldFill,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: AvStyle.fieldFill,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AvStyle.accent),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AvPill(
                key: const ValueKey('nvku-open-film-library'),
                label: '影片库',
                selected: false,
                compact: true,
                onTap: _openFilmLibrary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 底部三页签（2026-11-26 用户令删「分类」：原四页签里的
  /// 分类项打开的是类型文件夹视图，随该项一并撤下；其余三项
  /// 顺移补齐、不留空位。同日照 AvPlay 截图改浅色：白底 +
  /// 浅灰顶边，选中态酒红、未选中灰）。
  Widget _bottomTabs() {
    const items = [
      (Icons.grid_view_rounded, '首页'),
      (Icons.face_retouching_natural, '女优'),
      (Icons.star_border_rounded, '收藏'),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: AvStyle.bg,
        border: Border(top: BorderSide(color: AvStyle.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: InkWell(
                  key: ValueKey('nvku-tab-$i'),
                  onTap: () => _selectTab(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          items[i].$1,
                          size: 21,
                          color: _tab == i ? AvStyle.accent : AvStyle.dim,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items[i].$2,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: _tab == i
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: _tab == i ? AvStyle.accent : AvStyle.dim,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, String note) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AvStyle.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(note, style: const TextStyle(color: AvStyle.dim, fontSize: 12)),
        ],
      ),
    );
  }

  /// 快捷入口行（2026-11-26 照 AvPlay 首页入口排的摆法）：
  /// 白色圆角方块（浅边）里图标在上、文字在下，一排四个：
  /// 全部 / 女优 / 排行榜 / 收藏。AvPlay 那排第四个是「磁力」，
  /// 我们没有磁力功能，不编——换成排行榜（与女优页签内工具栏
  /// 奖杯钮打开的是同一个页）；「全部」回首页最新上架。
  Widget _entranceRow() {
    Widget item({
      required String keyName,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: InkWell(
          key: ValueKey(keyName),
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AvStyle.bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AvStyle.border),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0D000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: AvStyle.text, size: 23),
                const SizedBox(height: 5),
                Text(
                  label,
                  style: const TextStyle(color: AvStyle.text, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
      child: Row(
        children: [
          item(
            keyName: 'nvku-entrance-all',
            icon: Icons.grid_view_rounded,
            label: '全部',
            onTap: () {
              _selectTab(0);
              if (_category != 'new') _pickCategory('new');
            },
          ),
          const SizedBox(width: 10),
          item(
            keyName: 'nvku-entrance-actress',
            icon: Icons.face_retouching_natural_outlined,
            label: '女优',
            onTap: () => _selectTab(1),
          ),
          const SizedBox(width: 10),
          item(
            keyName: 'nvku-entrance-ranking',
            icon: Icons.emoji_events_outlined,
            label: '排行榜',
            onTap: _openRanking,
          ),
          const SizedBox(width: 10),
          item(
            keyName: 'nvku-entrance-fav',
            icon: Icons.star_border_rounded,
            label: '收藏',
            onTap: () => _selectTab(2),
          ),
        ],
      ),
    );
  }

  /// 排行榜页（演员排行）：与女优列表页工具栏的奖杯钮同一个页、
  /// 同一套构造参数。
  void _openRanking() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ActressRankingPage(
          repository: widget.repository,
          store: widget.store,
          database: widget.database ?? SqfliteActressDatabase.instance,
        ),
      ),
    );
  }

  Widget _homeTab() {
    final cats = _allCategories();
    return RefreshIndicator(
      color: AvStyle.accent,
      backgroundColor: AvStyle.bg,
      onRefresh: () => _boot(refresh: true),
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          // 快捷入口行（2026-11-26 照 AvPlay 首页入口排的摆法）：
          // 女优 / 排行榜 / 收藏，图标在上、文字在下。
          if (_query.isEmpty) _entranceRow(),
          // 首页只有分类胶囊 + 作品；标签筛选行留首页（原分类
          // 页签已于 2026-11-26 随底部导航删项一并撤下）。
          if (_query.isEmpty) _buildTagRow(),
          // 2026-11-22 用户令「分类不是卡片」：分类改成一条横向胶囊
          // 标签，置顶放在作品前面（原来是排在作品下面的两列卡片
          // 网格，既占地方又不像分类）。
          if (cats.isNotEmpty && _query.isEmpty)
            _categoryChips(
              cats,
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
            ),
          _sectionTitle(
            _query.isEmpty ? _currentCategoryLabel() : '“$_query”的搜索结果',
            _query.isEmpty ? _worksSubtitle : '',
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: CircularProgressIndicator(color: AvStyle.accent),
              ),
            )
          else if (_works.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  _query.isEmpty ? '暂时取不到作品' : '没有找到“$_query”',
                  style: const TextStyle(color: AvStyle.dim),
                ),
              ),
            )
          else
            _workGrid(_works, height: null),
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: CircularProgressIndicator(color: AvStyle.accent),
              ),
            ),
        ],
      ),
    );
  }

  /// 当前选中分类的展示名：最新上架是“最新上架”，其余取标签的干净名
  /// （站点分类去尾数、主分类标签取冒号后、厂牌取展示名）。
  String _currentCategoryLabel() {
    if (_category == 'new') return '最新上架';
    if (_category.startsWith('main:')) {
      return _category.substring('main:'.length).trim();
    }
    for (final cat in _allCategories()) {
      if (cat.id == _category) return _cleanCategoryName(cat.name);
    }
    return '最新上架';
  }

  /// 作品区副标题：排行榜按榜单顺序，其余按发行日期。
  String get _worksSubtitle =>
      _category == whosLocalRankCategory ? '榜单顺序' : '按发行日期';

  /// 分类胶囊条（首页共用）：横向滚动的一排浅色胶囊
  /// （2026-11-26 照 AvPlay 截图：选中浅粉底 + 酒红字），
  /// 横向 ListView 里胶囊会被拉满 46 高，外面套 Center 定高。
  Widget _categoryChips(
    List<CatalogCategory> cats, {
    EdgeInsets padding = const EdgeInsets.fromLTRB(12, 8, 12, 6),
  }) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: cats.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final cat = cats[index];
          final on = _category == cat.id;
          return Center(
            child: AvPill(
              key: ValueKey('nvku-chip-${cat.id}'),
              label: cat.name,
              selected: on,
              onTap: () => _pickCategory(cat.id),
            ),
          );
        },
      ),
    );
  }

  /// 作品网格（2026-11-26 照 AvPlay 截图改三列竖版卡，
  /// 卡片结构见 [AvWorkCard]）。
  Widget _workGrid(List<Drama> works, {double? height}) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: works.length,
      gridDelegate: avWorkGridDelegate,
      itemBuilder: (context, index) => _workCard(works[index]),
    );
  }

  /// 作品卡（2026-11-26 照 AvPlay 列表项摆法）：竖版封面 +
  /// 标题一行 + 番号酒红（本地库兜底来的带绿字「有资源」、
  /// 分类带字幕的带橙字「字幕」）+ 日期灰字。列表卡照截图
  /// 不放中央播放键（详情页海报播放键不动）；收藏星保留在
  /// 封面右上角（原有功能）。点卡行为不变（走 _play）。
  Widget _workCard(Drama drama) {
    final code = drama.tags.isNotEmpty ? drama.tags.first : '';
    final fav = _isFavorite(drama.id);
    return AvWorkCard(
      key: ValueKey('nvku-work-${drama.id}'),
      cover: drama.cover,
      title: drama.title,
      code: code,
      date: drama.onlineDate,
      hasResource: isWhosLocalDrama(drama),
      hasSubtitle:
          drama.category.contains('字幕') ||
          drama.tags.any((tag) => tag.contains('字幕')),
      hasHd:
          drama.category.contains('高清') ||
          drama.tags.any((tag) => tag.contains('高清')),
      onTap: () => unawaited(_play(drama)),
      topRight: GestureDetector(
        onTap: () => unawaited(_toggleFavorite(drama)),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(
            color: Color(0x66000000),
            shape: BoxShape.circle,
          ),
          child: Icon(
            fav ? Icons.star : Icons.star_border,
            size: 15,
            color: fav ? AvStyle.accentSoft : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _actressTab() {
    // 2026-11-26 照 AvPlay 截图改浅色：女优列表页本体走
    // colorScheme，把浅色主题只套在这一页签子树上，本模块
    // 三屏观感统一（它自带的深色霓虹小部件不在内嵌路径上）。
    return Theme(
      data: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AvStyle.accent,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: AvStyle.bg,
      ),
      child: ActressListPage(
        key: ValueKey('nvku-actress-list-$_dbEpoch'),
        repository: widget.repository,
        store: widget.store,
        database: widget.database,
        showTitle: false,
        // 2026-11-21 用户令：女优页签里不许再冒第二个搜索框——搜索只用
        // 顶栏那一条，本页监听同一个输入框（搜索框置顶、不随列表滚）。
        externalSearch: _search,
      ),
    );
  }

  Widget _favoriteTab() {
    if (_favorites.isEmpty) {
      return const Center(
        child: Text(
          '还没有收藏，点卡片右上角的星',
          style: TextStyle(color: AvStyle.dim),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: _favorites.length,
      gridDelegate: avWorkGridDelegate,
      itemBuilder: (context, index) {
        final row = _favorites[index];
        return _workCard(
          Drama(
            id: row.id,
            source: row.source,
            sourceId: row.id,
            title: row.title,
            cover: row.cover,
            tags: [if (row.code.isNotEmpty) row.code],
          ),
        );
      },
    );
  }
}

/// 收藏项：只留卡片和播放要用的字段（不存整条 Drama）。
class _FavItem {
  const _FavItem({
    required this.id,
    required this.source,
    required this.title,
    this.cover = '',
    this.code = '',
  });

  final String id;
  final String source;
  final String title;
  final String cover;
  final String code;

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'cover': cover,
    'code': code,
  };

  factory _FavItem.fromJson(Map<String, dynamic> json) => _FavItem(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? '',
    title: json['title'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    code: json['code'] as String? ?? '',
  );
}
