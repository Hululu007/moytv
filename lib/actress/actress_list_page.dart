import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_detail_page.dart';
import 'actress_film_library.dart';
import 'actress_generic_db.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_mytv_bind.dart';
import 'actress_working_db.dart';
import 'actress_neon.dart';
import 'actress_nvku_cache.dart';
import 'actress_ranking_page.dart';
import 'actress_sql_import.dart';
import 'actress_sql_import_controller.dart';
import 'actress_sql_import_section.dart';
import 'actress_db_manage_page.dart';
import 'actress_whos_topup.dart';
import 'whos_json_index.dart';
import 'actress_tag_sheet.dart';
import 'actress_widgets.dart';
import '../models.dart';
import '../whos_fallback.dart';
import '../whos_local_library.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import '../player_picker.dart';

/// 女优库浏览页：人物列表 + 搜索/性别筛选/排序 + 同步横幅。
///
/// 打开只读导入进来的内部工作库（应用私有目录下的 女优库.db，
/// 只由 .sql 导入建/换，见 actress_sql_import.dart）+ 本地
/// json/m3u 兜底，不自动爬取网站、不后台自动续爬、不自动生成
/// （2026-11-20 用户令：不自动爬取；2026-11-22 用户令最终口径：
/// 没有导入的库就是空库，不灌内置 json 种子、不走互联网同步；
/// 2026-11-25 用户令：读本地 .db 的老路全删，只留 .sql 导入）；
/// 同步只在用户点了刷新/重试时跑一次，跑完不自动再续。排行榜入口
/// 在顶栏奖杯钮。全站叠加入口在同步横幅下方：手动开始/继续，按番号
/// 把各站作品叠加进库，断点续跑，不自动跑、不与名册同步抢着跑。
/// 同步/现爬进行中、列表还空时，每 8 秒节流刷新一次列表（有人
/// 出现即停），爬到的条目写盘后进库，列表陆续出人。
/// 站点筛选下拉选项（纯函数，供测试直接验）：全部 + mjv + whos +
/// 片库全部可见视频站（与叠加搜索 actressSearchSiteIds 同一口径：
/// store.visibleSources 里 isVideoSection、非 cloud:、siteVisible
/// 的站；跳过 mjv/whos/chaoliu——chaoliu 即 mjv，已有 mjv 项代表
/// 它；跳过 ZakaJavrate（鉴黄师，用户 2026-11-21 令：女优库里
/// 播不了，站点列表里不留它）；yikm 这类游戏站不在视频区登记里，
/// 进不了选项）。
List<ActressSiteFilter> actressSiteFilterOptions(LocalStore store) {
  final options = <ActressSiteFilter>[
    ActressSiteFilter.all,
    ActressSiteFilter.mjv,
    ActressSiteFilter.whos,
  ];
  final seen = <String>{'all', 'mjv', 'whos', 'chaoliu', 'ZakaJavrate'};
  for (final site in store.visibleSources) {
    if (!site.isVideoSection) continue;
    if (site.id.startsWith('cloud:')) continue;
    if (!store.siteVisible(site.id)) continue;
    if (!seen.add(site.id)) continue;
    options.add(ActressSiteFilter(site.id, site.name));
  }
  return options;
}

class ActressListPage extends StatefulWidget {
  const ActressListPage({
    super.key,
    required this.repository,
    required this.store,
    this.database,
    this.fallback,
    this.showTitle = true,
    this.externalSearch,
    this.topupPagerFuture,
    this.topupIndexFuture,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 内嵌进区域/窗口/内层页签时宿主已有“女优库”标题，页内顶栏不再
  /// 重复标题字（只留人数），与 MiniAppHomePage 的做法同口径。
  final bool showTitle;

  /// 宿主已经有一条置顶搜索框时传进来（2026-11-21 用户令：搜索框
  /// 不许叠两个、顶栏不许叠两条）。传了就用宿主的输入框做搜索源，
  /// 本页不再画自己的搜索框，只留人数与右侧动作按钮。
  final TextEditingController? externalSearch;

  /// 测试/预览注入：不传时用 sqflite 真库。
  @visibleForTesting
  final ActressDatabase? database;

  /// 测试/预览注入：JSON 兜底；不传时现建。
  @visibleForTesting
  final ActressJsonFallback? fallback;

  /// 测试注入：无库顶上的目录分页器/女优索引；不传时走单例。
  @visibleForTesting
  final Future<WhosCatalogPager>? topupPagerFuture;

  /// 测试注入：无库顶上的女优索引；不传时走单例。
  @visibleForTesting
  final Future<WhosJsonIndex>? topupIndexFuture;

  @override
  State<ActressListPage> createState() => _ActressListPageState();
}

/// 列表第一页缓存项（2026-11-24 切换不重载）：第一页人物 + hasMore
/// + 查库时的原始偏移（翻页用）+ 滚动偏移（切换回来恢复位置用）。
class _CachedListPage {
  _CachedListPage(this.persons, this.hasMore, this.rawOffset);

  final List<ActressPerson> persons;
  final bool hasMore;
  final int rawOffset;

  /// 切换前存的滚动偏移；恢复时等网格布局完再跳，越界时钳制。
  double scrollOffset = 0;
}

class _ActressListPageState extends State<ActressListPage> {
  static const _pageSize = 60;

  late final ActressDatabase _db;
  late final ActressJsonFallback _fallback;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  var _persons = <ActressPerson>[];
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = true;

  /// 名单加载失败态（2026-11-26 加载优化）：非空且名单为空时
  /// _buildList 显示「加载失败 + 原因 + 重试钮」。此前 _loadPage
  /// 全程无 try/catch、无超时：名单查询只要抛一次错（最现成的
  /// 触发源是开库后台重建汇总表的写锁），清标志的 setState 永远
  /// 执行不到，名单永久转圈且无声。现在两分支统一包守卫 +
  /// 超时，标志在失败路径必清。
  String? _loadError;

  /// 名单查询超时（照 nvku 文件夹路口径）：首屏 20 秒、翻页 15 秒。
  static const _firstPageTimeout = Duration(seconds: 20);
  static const _loadMoreTimeout = Duration(seconds: 15);


  /// 刷新中（筛选切换时）：旧列表留着当底，只在列表顶露一条细进度条，
  /// 不清列表、不转大圈，滚动位置天然保住。首屏第一次加载仍走
  /// _loading 大转圈（2026-11-24 切换不重载）。
  var _refreshing = false;

  /// 第一页缓存（2026-11-24 切换不重载）：key = 筛选条件全维度，
  /// 值 = 第一页人物 + hasMore + 查库时的原始偏移 + 滚动偏移。
  /// 只缓存第一页（60 条），上限 8 个 key（LRU）。失效：热换库、
  /// 同步/现爬/叠加完成、手动刷新时全清（见 _clearListCaches）。
  final _pageCache = <String, _CachedListPage>{};
  static const _pageCacheMaxKeys = 8;

  var _sex = ActressSexFilter.all;
  var _tagFilter = ActressTagFilter.all;
  var _sort = ActressSort.worksDesc;

  var _query = '';
  var _generation = 0;

  /// 作品标签筛选（2026-11-24 用户令：who's.json 分类是日本AV，
  /// 标签在数据库里，底部弹窗显示里面的标签）：默认全部；选标签
  /// 后列表只留有该标签作品的人（人物列表页的诚实语义：标签是按
  /// 作品的，人只按“有没有该标签的作品”留，不把人本身算成有标签）。
  /// 与分类是 AND 关系（既是该分类、又有该标签的作品才留人）。
  /// 标签列表只在打开弹窗时才查库（GROUP BY 一次），之后走缓存；
  /// 换库时清空（标签是旧库的数据），切分类/搜词/换排序时保留。
  var _videoTag = '';
  String? _dbTagsCacheKey;
  List<(String, int)>? _dbTagsCache;

  /// 顶栏站点筛选：默认全部；选站后列表只留该站有 JSON 兜底条目的
  /// 人（按女优名或本地作品番号对），详情页兜底与现爬也只走该站。
  var _source = ActressSiteFilter.all;

  /// 站点筛选选项快照（只记 id 集合，进页时按活的站源注册表读
  /// 一次；选项本身不缓存，每次打开菜单时现算——
  /// actressSiteFilterOptions 读的就是活的 visibleSources）。
  /// 站源注册表再变时与它比对：有变才动（顶栏只重建、不在每次
  /// store 通知时都白刷一遍）。
  var _siteOptionIds = <String>{};

  /// 站点过滤时的原始偏移（过滤后页内人数会少于 60，翻页必须按
  /// 原始偏移走，不能按过滤后的人数走）。
  var _rawOffset = 0;

  /// 每人本地作品番号集合缓存（站点过滤用，按需取一次）。
  final _siteCodeKeys = <int, Set<String>>{};

  /// 库总览（人数/作品数）：进页与重读后从库里现读，顶栏人数与
  /// 设置弹窗的库信息行都用它。只读展示，不带任何同步状态。
  ActressSyncOverview? _overview;

  /// 没有导入的数据库：内部工作库还没建，列表显示空态提示
  /// （导入 .sql 数据库），不回落任何内置库。
  var _noLibraryDb = false;

  /// 兜底加载器是不是本页自己建的：是才按绑定结果改它的本地
  /// 目录；测试注入的实例不动（注入的假目录优先）。
  var _ownsFallback = true;

  /// 手动“重新加载数据库”进行中（防重复点）。
  var _reloadingDb = false;

  /// 2026-11-25 .sql 导入：设置里选 .sql / .sql.gz 文件导回主库。
  /// 进度由设置弹窗的 600ms 轮询取走重画，这里只写字段、不逐批
  /// setState；开始/结束/失败时才 setState。取消只改标志位，
  /// 导入器在批与批之间检查，停在换库之前、原库不动。
  // .sql 导入状态在应用级控制器里（2026-11-25 用户令：离开页面
  // 也能在后台继续导）：本页只转发读，设置弹窗与顶栏横幅都读它；
  // 导完由控制器监听统一清缓存重读 + 弹一次提示。
  final ActressDbTaskController _taskController =
      ActressDbTaskController.instance;
  bool get _sqlImportRunning => _taskController.sqlImportRunning;
  ActressSqlImportProgress? get _sqlImportProgress =>
      _taskController.sqlImportProgress;
  String? get _sqlImportError {
    final result = _taskController.sqlImportResult;
    return (result != null && !result.ok) ? result.error : null;
  }

  ActressSqlImportResult? get _sqlImportResult {
    final result = _taskController.sqlImportResult;
    return (result != null && result.ok) ? result : null;
  }

  /// 已处理过的换库代次：控制器代次涨了 = 有新库顶替成功。
  var _seenSwapGeneration = 0;

  /// 已处理过的数据代次：控制器代次涨了 = 库被改过（表格更新/
  /// 恢复/删除），同样清缓存重读。
  var _seenDataGeneration = 0;


  /// 影视库 db 兜底（内部工作库），本页自己建的时候持有，
  /// 退出时关掉连接。
  FilmLibraryService? _filmDbService;
  /// 只出作品的站源（nvku）：站上只有作品没有人物名册，选了它就切
  /// 到作品网格按站点分类翻页，不再按人物过滤（否则永远是「该站
  /// 暂无匹配人物」）。
  var _siteWorks = <Drama>[];
  var _siteWorksPage = 1;
  var _siteWorksCategory = '';
  var _siteCategories = <CatalogCategory>[];

  bool get _siteWorksMode => _source.siteId == nvkuSourceId;

  @override
  void initState() {
    super.initState();
    _db = widget.database ?? SqfliteActressDatabase.instance;
    _ownsFallback = widget.fallback == null;
    _fallback = widget.fallback ?? ActressJsonFallback();
    if (_ownsFallback) {
      // 2026-11-20 18:57 全部使用数据库兜底：兜底先查影视库 db
      // （内部工作库），读不到回退 json/m3u。测试注入的
      // fallback 不接提供方，保持老行为。
      _fallback.filmDb = _filmDbService = FilmLibraryService(database: _db);
    }
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
    // 后台导入控制器：本页活着时导完立刻清缓存重读 + 弹提示；
    // 本页不在时结果留着，下次进来补弹（见 _consumeImportNotice）。
    _seenSwapGeneration = _taskController.swapGeneration;
    _seenDataGeneration = _taskController.dataGeneration;
    _taskController.addListener(_onTaskControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumeImportNotice();
    });
    // 宿主搜索框（内嵌进女优库区域时）：同一个输入框驱动本页搜索，
    // 本页不再画第二个搜索框。
    widget.externalSearch?.addListener(_onSearchChanged);
    final initialSearch = widget.externalSearch?.text.trim() ?? '';
    if (initialSearch.isNotEmpty) _query = initialSearch;
    // 站点筛选选项进页时按活的站源注册表读一次（不是启动快照）；
    // 之后站源注册表再变（新站导入/站点摘掉/隐藏）走监听重建。
    _siteOptionIds = _siteFilterOptions().map((o) => o.siteId).toSet();
    widget.store.addListener(_onStoreChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    unawaited(_filmDbService?.close());
    _taskController.removeListener(_onTaskControllerChanged);
    widget.store.removeListener(_onStoreChanged);
    _scrollController.dispose();
    widget.externalSearch?.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    // 2026-11-20 MYTV 绑定：先解析绑定，再读库。绑定里建
    // MYTV/db 与 MYTV/m3u、迁移老数据（开库前做）；没权限/外部存储
    // 不可用时降级回 documents，下面流程不变，女优库照常能用。
    // 测试环境没有平台通道，解析内部全包 try/catch，拿不到就降级，
    // 不抛错。绑定只定 json/m3u 目录（2026-11-25：内部工作库落点
    // 不再由绑定定，见 actress_working_db.dart）。
    final bind = await ActressMytvBind.instance.ensureBound();
    if (!mounted || generation != _generation) return;
    if (_ownsFallback) {
      _fallback.bindLocalDirs(
        jsonDir: bind.jsonDir,
        userM3uDir: bind.bound ? bind.m3uDir : null,
      );
    }
    // 2026-11-25 只留 .sql 导入：内部工作库还没建时开库报
    // “还没有导入数据库”，接住显示空态提示（导入 .sql 数据库），
    // 不崩、不回落；其它开库错误弹一次提示，同样不崩。
    final reload = await _db.reloadIfChanged();
    if (!mounted || generation != _generation) return;
    if (reload.error != null) {
      final noDb = reload.error!.startsWith('还没有导入数据库');
      setState(() {
        _noLibraryDb = noDb;
        _loading = false;
      });
      if (!noDb) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(actressReloadErrorText(reload.error!))),
        );
      }
      return;
    }
    // 兜底后台读、不堵首屏：列表站点过滤要用它，但不能在首屏等它。
    unawaited(_fallback.load());
    // 2026-11-26 加载优化：总览与名单并行——原来串行等三条 COUNT
    // （含 COUNT(DISTINCT cate_id) 扫 60.9 万行）跑完才查名单，
    // 首屏白等一轮。总览只管头顶人数，带守卫自己读（见
    // _loadOverviewGuarded），读不到不堵名单。
    unawaited(_loadOverviewGuarded());
    // 名单进程级缓存（2026-11-26 加载优化）：State 被宿主切区
    // 销毁后重建时，先查缓存 key（库实例 + 换库/数据代次 +
    // 筛选，见 _personsCacheStamp），命中直接上屏、免查库。此前名单第一页只活
    // 在 State 里，切区回来全量重查、还要再等一轮总览。
    if (!mounted || generation != _generation) return;
    if (_restorePersonsFromEntryCache()) return;
    // 2026-11-22 用户令最终口径：库缺失/空库不再自动生成（不灌
    // 内置 json 种子、不走互联网同步），空态如实提示导入 .sql
    // 数据库。
    // _loadPage(reset) 会推进代次，这里只判 mounted，不再比代次。
    await _loadPage(reset: true);
    if (!mounted) return;
    // 数据库里的分类读一次挂上行：同步跑完分类变了走
    // _refreshAfterSync 再刷。
    // 不自动爬取（2026-11-20 用户令）：打开只读本地，不自动起爬、
    // 不后台自动续爬、不自动生成；只等用户手动点刷新/重试/同步。
  }
  /// 总览（头顶人数）带守卫地读（2026-11-26 加载优化）：包
  /// try/catch + 首屏超时。原来 _bootstrap 里裸 await：总览抛错
  /// 会把整个 bootstrap 打断（名单跟着不加载），慢查会把名单
  /// 串行堵在后面。现在总览只管头顶计数，读不到就留空，名单
  /// 照常；名单自己失败有自己的失败态（_loadError）。
  Future<void> _loadOverviewGuarded() async {
    try {
      final overview = await _db.overview().timeout(_firstPageTimeout);
      if (!mounted) return;
      setState(() => _overview = overview);
    } catch (_) {
      // 总览读不到：头顶人数留空，不堵名单、不弹错。
    }
  }

  /// 名单进程级缓存的 key 前缀：库实例身份 + 换库/数据代次。
  /// 代次任一变了 key 就不同，旧名单串不到新库——应用内一切换库/
  /// 改数据路径（.sql 导入换库、表格更新、管理页恢复/删除）都经
  /// 任务控制器抬代次，没有绕过控制器的改库路径；实例身份让测试
  /// 注入的内存库彼此隔离（生产是单例，身份恒定）。
  /// 不把库文件指纹放进 key：解析文件路径要走平台通道，不许它
  /// 堵名单首屏；带 -wal 分量的文件指纹在连接侧
  /// （SqfliteActressDatabase.reloadIfChanged）守着，管的是连接
  /// 新旧，与这里的名单缓存是两回事。
  String get _personsCacheStamp =>
      '${identityHashCode(_db)}'
      '|${_taskController.swapGeneration}'
      '|${_taskController.dataGeneration}';

  String _entryPersonsKey() => '$_personsCacheStamp|${_pageCacheKey()}';

  /// 切区回来/State 重建时先查进程级名单缓存：命中直接上屏
  /// （人物 + hasMore + 翻页偏移 + 滚动偏移），返回 true 表示已
  /// 恢复、不用再查库。只用于主模式（站源模式不走名单缓存）。
  bool _restorePersonsFromEntryCache() {
    if (_siteWorksMode) return false;
    final entry = NvkuEntryCache.personsFirstPage(_entryPersonsKey());
    if (entry == null) return false;
    final generation = ++_generation;
    setState(() {
      _persons = entry.persons;
      _hasMore = entry.hasMore;
      _rawOffset = entry.rawOffset;
      _loading = false;
      _refreshing = false;
      _loadingMore = false;
      _loadError = null;
    });
    // 实例级第一页缓存也补一份：页内切筛选再切回来走快路。
    _pageCache[_pageCacheKey()] = _CachedListPage(
      entry.persons,
      entry.hasMore,
      entry.rawOffset,
    )..scrollOffset = entry.scrollOffset;
    // 恢复滚动偏移：等网格布局完再跳（post-frame），偏移越界时钳制。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final target = entry.scrollOffset.clamp(0.0, max).toDouble();
      if (target > 0) _scrollController.jumpTo(target);
    });
    return true;
  }

  /// 加载失败原因的短文案（失败态与 SnackBar 用）：超时说清是
  /// 超时，其余取错误第一行截断，不把整段堆栈糊到界面上。
  static String _shortLoadError(Object error) {
    if (error is TimeoutException) return '加载超时，请重试';
    final first = error.toString().split('\n').first.trim();
    return first.length > 80 ? '${first.substring(0, 80)}…' : first;
  }

  /// 手动重读内部工作库（2026-11-25 只留 .sql 导入）：只给
  /// _startSqlImport 内部调用，导完刷新列表；不再对外提供“热换库”
  /// 入口（设置里的重新加载按钮与绑定行已删）。重读失败留旧库并
  /// 报原因，不崩、不丢数据；还没导入过库时报“还没有导入数据库”。
  Future<void> _manualReloadDb() async {
    if (_reloadingDb) return;
    _reloadingDb = true;
    try {
      final result = await _db.reloadIfChanged(force: true);
      if (!mounted) return;
      if (result.error != null) {
        final noDb = result.error!.startsWith('还没有导入数据库');
        setState(() {
          _noLibraryDb = noDb;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(content: Text(actressReloadErrorText(result.error!))),
        );
        return;
      }
      // 重读成功：之前没库、现在导进来了，空态也清掉。库文件可能
      // 换了，旧缓存作废（下面 _refreshAfterSync 也会清）。
      _clearListCaches();
      setState(() {
        _noLibraryDb = false;
        // 2026-11-24 标签筛选：重读可能换了库文件，旧标签作废。
        _videoTag = '';
      });
      await _refreshAfterSync();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.reloaded ? '已重新加载数据库' : '数据库没有变化')),
      );
    } finally {
      _reloadingDb = false;
    }
  }
  /// .sql 导入（2026-11-25 用户令）：设置里选 .sql / .sql.gz 文件，
  /// 导进临时库、校验四项（作品/人数/播放地址/封面/头像）通过后才
  /// 换掉内部工作库（先备份 .bak）。导完清缓存、重读列表。
  /// 失败/取消：原库不动，只报原因；换过库连接才重读恢复连接。
  /// 不再要求先绑定 MYTV：导入直接落到内部工作库。
  Future<void> _startSqlImport() async {
    if (_sqlImportRunning) return;
    List<PlatformFile> files;
    try {
      // file_picker 13.1.0：pickFiles 直接回 List<PlatformFile>。
      // 选文件调用包进 try/catch：卓易通容器里选择器一抛错就地报，
      // 不静默（2026-11-25 统一导入入口同款修法）。
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['sql', 'gz'],
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打不开文件选择器：${e.toString().split('\n').first}')),
      );
      return;
    }
    if (files.isEmpty) return; // 用户取消选择。
    final pickedPath = files.first.path;
    if (pickedPath == null || pickedPath.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('选不到文件路径，请重选一次')));
      return;
    }
    final lower = pickedPath.toLowerCase();
    if (!lower.endsWith('.sql') && !lower.endsWith('.sql.gz')) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('只认 .sql 或 .sql.gz 文件')));
      return;
    }
    // 交给应用级控制器跑：离开本页、关掉设置弹窗，导入都在后台
    // 继续；导完由 _onTaskControllerChanged 统一清缓存重读并弹
    // 一次提示，这里只管选文件。
    await _taskController.startSqlImport(
      sqlPath: pickedPath,
      dbPath: await actressWorkingDbPath(),
      closeDatabase: _db.close,
    );
  }

  void _cancelSqlImport() => _taskController.cancelSqlImport();

  /// 顶上模式点作品播放：目录行 → 本地作品 → 一条直链集的详情，
  /// 直接推播放器（who's 直链，不经站点解析、不查数据库）。
  Future<void> _playTopupVideo(WhosVideo video) async {
    final work = WhosLocalWork(
      id: video.code,
      title: video.title,
      cover: video.pic,
      playUrl: video.m3u8,
      code: video.code,
      brand: WhosLocalWork.brandOfCode(video.code),
    );
    final drama = whosLocalToDrama(work);
    final detail = whosLocalDetail(drama, work);
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
  }

  /// 打开数据库管理页（设置区与空态共用入口）。
  Future<void> _openDbManagePage() async {
    final dbPath = await actressWorkingDbPath();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ActressDbManagePage(
          dbPath: dbPath,
          closeDatabase: _db.close,
          reloadDatabase: _manualReloadDb,
        ),
      ),
    );
  }

  /// 后台任务状态变了（进度/导完）：重画本页；换库代次或数据代次
  /// 涨了说明库被换掉/改过（导入、表格更新、管理页恢复/删除），
  /// 清缓存重读——导完不重启、不手动重进就看到新数据（自动刷新）。
  void _onTaskControllerChanged() {
    if (!mounted) return;
    setState(() {});
    final swapped =
        _taskController.swapGeneration != _seenSwapGeneration;
    final mutated =
        _taskController.dataGeneration != _seenDataGeneration;
    if (swapped || mutated) {
      _seenSwapGeneration = _taskController.swapGeneration;
      _seenDataGeneration = _taskController.dataGeneration;
      _clearListCaches();
      NvkuEntryCache.clear();
      unawaited(_manualReloadDb());
    }
    _consumeImportNotice();
  }

  /// 导入完成提示只弹一次：活着的页面导完立刻弹；导入期间页面
  /// 不在的，下次进来补弹。失败且动过库连接的先重读恢复连接。
  void _consumeImportNotice() {
    if (!mounted) return;
    final notice = _taskController.consumeImportNotice();
    if (notice == null) return;
    if (!notice.ok && notice.needsReload) {
      unawaited(_manualReloadDb());
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          notice.ok
              ? '已导入：${notice.videos} 部作品 · ${notice.actresses} 人'
                    ' · 封面 ${notice.covers} · 头像 ${notice.avatars}'
              : '导入失败：${notice.error ?? '未知原因'}',
        ),
      ),
    );
  }

  /// 库内容被外部变更后（导入换库、表格更新、管理页删/恢复）
  /// 的统一重读：旧缓存作废，先清再重读总览与列表。
  Future<void> _refreshAfterSync() async {
    _clearListCaches();
    // 名单缓存 key 前缀含换库/数据代次（见 _personsCacheStamp），
    // 代次刚被任务控制器抬过，新名单自然挂新 key，不用重算。
    // 总览走带守卫的读法（抛错/超时不打断重读）。
    await _loadOverviewGuarded();
    await _loadPage(reset: true);
    if (!mounted) return;
  }

  void _onScroll() {
    // 2026-11-24：刷新中也不触底加载（_refreshing 时 _loading 为假，
    // 不加这道会在切换时误起翻页，代次守卫把它丢掉后 _loadingMore
    // 还可能卡住）。
    if (_loadingMore || !_hasMore || _loading || _refreshing) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      unawaited(_loadPage());
    }
  }

  /// 当前生效的搜索输入框：宿主给了就用宿主的（只有一条搜索框，
  /// 不会出现两个输入框各搜各的）。
  TextEditingController get _activeSearchController =>
      widget.externalSearch ?? _searchController;

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      final query = _activeSearchController.text.trim();
      if (query == _query) return;
      _saveScrollOffsetForCache();
      setState(() => _query = query);
      _reloadAfterFilterChange();
    });
  }

  /// 站源注册表变了（新站导入/站点摘掉/隐藏/显隐切换）：
  /// 选项集合没变就不动（store 的其他通知不触发重建）；选项
  /// 变了才重建顶栏——当前选中的站已不在选项里时回“全部”并
  /// 重读列表（否则列表会一直按一个已不存在的站过滤，只显示
  /// “该站暂无匹配人物”）；新站进来时菜单下次打开即有它
  /// （itemBuilder 每次打开都现算，不用等重建）。
  void _onStoreChanged() {
    if (!mounted) return;
    final options = _siteFilterOptions();
    final ids = options.map((o) => o.siteId).toSet();
    if (ids.length == _siteOptionIds.length &&
        ids.containsAll(_siteOptionIds)) {
      return;
    }
    _siteOptionIds = ids;
    if (_source != ActressSiteFilter.all && !ids.contains(_source.siteId)) {
      setState(() => _source = ActressSiteFilter.all);
      unawaited(_loadPage(reset: true));
      return;
    }
    setState(() {});
  }

  /// 站点筛选下拉选项：全部 + mjv + whos + 片库全部可见视频站
  /// （与叠加搜索 actressSearchSiteIds 同一口径：store.visibleSources
  /// 里 isVideoSection、非 cloud:、siteVisible 的站；跳过 mjv/whos/
  /// chaoliu——chaoliu 即 mjv，已有 mjv 项代表它；yikm 这类游戏站
  /// 不在视频区登记里，进不了选项）。
  List<ActressSiteFilter> _siteFilterOptions() =>
      actressSiteFilterOptions(widget.store);

  /// 切换站点筛选：只重读列表与分类。2026-11-23 用户令：女优库不要
  /// 全自动同步检查——切站不再自动现爬，想爬去设置页“任意站点爬取”
  /// 粘地址手动爬（2026-11-24 选站现爬已删）。
  void _setSiteFilter(ActressSiteFilter source) {
    if (source == _source) return;
    _saveScrollOffsetForCache();
    setState(() {
      _source = source;
      _siteWorks = [];
      _siteWorksPage = 1;
      _siteWorksCategory = '';
    });
    if (source.siteId == nvkuSourceId) {
      unawaited(_loadSiteCategories(source.siteId));
    }
    _reloadAfterFilterChange();
  }

  /// 站点自己的分类（nvku：最新/有码/无码/4K/其它，条数在名字里）。
  Future<void> _loadSiteCategories(String sourceId) async {
    try {
      final rows = await widget.repository.categories(sourceId);
      if (!mounted || _source.siteId != sourceId) return;
      setState(() {
        _siteCategories = rows;
        if (_siteWorksCategory.isEmpty && rows.isNotEmpty) {
          _siteWorksCategory = rows.first.id;
        }
      });
      if (_siteWorks.isEmpty) unawaited(_loadPage(reset: true));
    } catch (_) {
      // 站点暂时连不上：不阻塞页面，作品列表自己会走兜底/提示。
    }
  }

  /// 只出作品的站点分页：走站点蜘蛛的分类目录（封面/番号/播放地址
  /// 都是站点给的），失败时退到本地库兜底，不留白屏。
  Future<void> _loadSiteWorks({bool reset = false}) async {
    if (reset) {
      final generation = ++_generation;
      // 2026-11-24 切换不重载：同主列表，旧作品留着当底、只置细进度条。
      final keepOld = _siteWorks.isNotEmpty;
      setState(() {
        if (keepOld) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _loadingMore = false;
        _hasMore = true;
        _loadError = null;
      });
      // 2026-11-26 加载优化：与主名单同一套守卫（try/catch + 超时
      // + 失败必清标志），不再裸 await 站点目录——站点抛错时原来
      // 同样会把 _loading 卡死成永久转圈。
      try {
        final page = await widget.repository
            .catalog(
              nvkuSourceId,
              page: 1,
              query: _query,
              category: _siteWorksCategory,
            )
            .timeout(_firstPageTimeout);
        if (!mounted || generation != _generation) return;
        setState(() {
          _siteWorks = page.items;
          _siteWorksPage = 2;
          _hasMore = page.hasMore;
          _loading = false;
          _refreshing = false;
        });
      } catch (e) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _refreshing = false;
          if (_siteWorks.isEmpty) _loadError = _shortLoadError(e);
        });
        if (_siteWorks.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('作品刷新失败：${_shortLoadError(e)}')),
          );
        }
      }
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.repository
          .catalog(
            nvkuSourceId,
            page: _siteWorksPage,
            query: _query,
            category: _siteWorksCategory,
          )
          .timeout(_loadMoreTimeout);
      if (!mounted || generation != _generation) return;
      setState(() {
        _siteWorks = [..._siteWorks, ...page.items];
        _siteWorksPage += 1;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载更多失败：${_shortLoadError(e)}')),
      );
    }
  }

  void _setSiteWorksCategory(String id) {
    if (_siteWorksCategory == id) return;
    setState(() => _siteWorksCategory = id);
    unawaited(_loadPage(reset: true));
  }

  /// 站点作品点卡：取一次详情（一集正片）直接进播放器。
  Future<void> _playSiteWork(Drama drama) async {
    try {
      final detail = await widget.repository.detail(drama);
      if (!mounted) return;
      if (detail.episodes.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这条没有可播地址')));
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
    if (mounted) setState(() {});
  }

  GenericDbWork _siteWorkCard(Drama drama) => GenericDbWork(
    id: drama.id,
    title: drama.title,
    coverUrl: drama.cover,
    playUrl: 'nvku://${drama.id}',
    code: drama.tags.isNotEmpty ? drama.tags.first : '',
    actress: '',
    date: drama.onlineDate,
  );

  Future<Set<String>> _codeKeysFor(ActressPerson person) async {
    final cached = _siteCodeKeys[person.localId];
    if (cached != null) return cached;
    final works = await _db.worksForPerson(
      person.localId,
      offset: 0,
      limit: 500,
    );
    final keys = {
      for (final work in works)
        if (work.codeKey.isNotEmpty) work.codeKey,
    };
    _siteCodeKeys[person.localId] = keys;
    return keys;
  }

  /// 站点过滤：只留该站有 JSON 兜底条目的人（按女优名或本地作品番号对）。
  /// 全部时不过滤。过滤后页内人数可能少于 60，翻页偏移另用 _rawOffset。
  Future<List<ActressPerson>> _applySiteFilter(
    List<ActressPerson> persons,
  ) async {
    if (_source == ActressSiteFilter.all) return persons;
    if (!_fallback.loaded) await _fallback.load();
    final kept = <ActressPerson>[];
    for (final person in persons) {
      final codeKeys = await _codeKeysFor(person);
      if (await _fallback.hasSiteEntriesForPersonAsync(
        names: [person.displayName, ...person.aliases],
        codeKeys: codeKeys,
        site: _source.siteId,
      )) {
        kept.add(person);
      }
    }
    return kept;
  }

  Future<void> _loadPage({bool reset = false}) async {
    // 只有作品的站源（nvku）：作品网格 + 站点分类翻页。
    if (_siteWorksMode) {
      await _loadSiteWorks(reset: reset);
      return;
    }
    if (reset) {
      final generation = ++_generation;
      // 2026-11-24 切换不重载：列表非空时是筛选切换，旧列表留着当底，
      // 只置细进度条（_refreshing），不清列表、不转大圈，滚动位置
      // 天然保住；首屏第一次加载（列表空）才走大转圈。_hasMore 在
      // 结果回来后再按新结果置；_loadingMore 一并清掉（重置使在途
      // 的翻页失效，不清会卡住触底加载）。
      final keepOld = _persons.isNotEmpty;
      setState(() {
        if (keepOld) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _loadingMore = false;
        _hasMore = true;
        _loadError = null;
      });
      _rawOffset = 0;
      // 2026-11-26 加载优化：名单查询包 try/catch + 首屏超时。
      // 此前裸 await：抛一次错，清标志的 setState 永远执行不到，
      // 名单永久转圈且无声（修仙版已实报同构故障）。现在失败必
      // 清标志：名单为空进整页失败态（原因 + 重试钮），有旧名单
      // 时旧数据留着、只弹一句。
      try {
        final raw = await _db
            .listPersons(
              sex: _sex,
              sort: _sort,
              query: _query,
              tag: _tagFilter.tagValue,
              videoTag: _videoTag,
              offset: 0,
              limit: _pageSize,
            )
            .timeout(_firstPageTimeout);
        _rawOffset = raw.length;
        final persons = await _applySiteFilter(raw);
        if (!mounted || generation != _generation) return;
        setState(() {
          _persons = persons;
          _hasMore = raw.length >= _pageSize;
          _loading = false;
          _refreshing = false;
        });
        _storePageCache(persons, raw.length >= _pageSize, _rawOffset);
      } catch (e) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _refreshing = false;
          if (_persons.isEmpty) _loadError = _shortLoadError(e);
        });
        if (_persons.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('名单刷新失败：${_shortLoadError(e)}')),
          );
        }
      }
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final raw = await _db
          .listPersons(
            sex: _sex,
            sort: _sort,
            query: _query,
            tag: _tagFilter.tagValue,
            videoTag: _videoTag,
            offset: _rawOffset,
            limit: _pageSize,
          )
          .timeout(_loadMoreTimeout);
      _rawOffset += raw.length;
      final persons = await _applySiteFilter(raw);
      if (!mounted || generation != _generation) return;
      setState(() {
        _persons = [..._persons, ...persons];
        _hasMore = raw.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载更多失败：${_shortLoadError(e)}')),
      );
    }
  }

  /// 第一页缓存的 key：筛选条件的全部维度。任一维度变了就是另一个
  /// key。只用于主模式（站源模式有自己的列表，不走这份缓存）。
  String _pageCacheKey() {
    return [
      _sex.name,
      _videoTag,
      _tagFilter.name,
      _sort.name,
      _query,
      _source.siteId,
    ].join('|');
  }

  /// 把刚查回的第一页写进缓存（key 是当前筛选条件）。超过上限时
  /// 淘汰最久没用的 key（LinkedHashMap 按插入顺序，keys.first 是
  /// 最旧的）。只在 reset 分支的结果回来后调；代次守卫已保证
  /// 结果与当前筛选一致，key 不会写错。rawOffset 是缓存这页对
  /// 应的原始偏移（翻页用）：只存第一页时就是第一页的人数，
  /// 不能拿已加载的总页数来存，否则恢复后翻页会跳页。
  void _storePageCache(
    List<ActressPerson> persons,
    bool hasMore,
    int rawOffset,
  ) {
    final key = _pageCacheKey();
    _pageCache.remove(key);
    _pageCache[key] = _CachedListPage(persons, hasMore, rawOffset);
    while (_pageCache.length > _pageCacheMaxKeys) {
      _pageCache.remove(_pageCache.keys.first);
    }
    // 进程级缓存同步写一份（2026-11-26 加载优化）：State 被宿主
    // 切区销毁后，新 State 靠它免查库（key 含库实例/指纹/代次，
    // 见 _entryPersonsKey）。滚动偏移由 _saveScrollOffsetForCache
    // 切走前回写进这份缓存项。
    NvkuEntryCache.putPersonsFirstPage(
      _entryPersonsKey(),
      persons: persons,
      hasMore: hasMore,
      rawOffset: rawOffset,
    );
  }

  /// 切换前把当前滚动偏移存进当前 key 的缓存项（有缓存项才存）。
  /// 只用于主模式（站源模式不走这份缓存）。
  void _saveScrollOffsetForCache() {
    if (_siteWorksMode) return;
    if (!_scrollController.hasClients) return;
    final cached = _pageCache[_pageCacheKey()];
    if (cached != null) {
      cached.scrollOffset = _scrollController.offset;
    }
    // 进程级缓存项同步回写：切区回来恢复的是这份（见
    // _restorePersonsFromEntryCache）。
    final entry = NvkuEntryCache.personsFirstPage(_entryPersonsKey());
    if (entry != null) {
      entry.scrollOffset = _scrollController.offset;
    }
  }

  /// 筛选值已变后的统一收尾（主模式）：先查缓存，命中直接恢复，
  /// 未命中走 _loadPage(reset: true) 查库。站源模式不走缓存，
  /// 直接查库。
  void _reloadAfterFilterChange() {
    if (!_siteWorksMode && _restorePageFromCache()) return;
    unawaited(_loadPage(reset: true));
  }

  /// 筛选切换时先查缓存：命中就直接恢复列表 + 滚动偏移，不碰数据库；
  /// 返回 true 表示已恢复、调用方不用再调 _loadPage。只用于主模式。
  bool _restorePageFromCache() {
    final key = _pageCacheKey();
    final cached = _pageCache[key];
    if (cached == null) return false;
    final generation = ++_generation;
    setState(() {
      _persons = cached.persons;
      _hasMore = cached.hasMore;
      _rawOffset = cached.rawOffset;
      _loading = false;
      _refreshing = false;
      _loadingMore = false;
      _loadError = null;
    });
    // 恢复滚动偏移：等网格布局完再跳（post-frame），偏移越界时钳制。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final target = cached.scrollOffset.clamp(0.0, max).toDouble();
      if (target > 0) _scrollController.jumpTo(target);
    });
    return true;
  }

  /// 清掉全部易变缓存（列表第一页 + 分类 + 标签）：库内容变了就调——热换库、
  /// 同步/现爬/叠加完成、手动刷新。漏清会显示旧数据。只清缓存，不清
  /// 已选的标签（同库内容更新，标签筛选本身还有效）。
  void _clearListCaches() {
    _pageCache.clear();
    _dbTagsCacheKey = null;
    _dbTagsCache = null;
    // 库内容变了（同步/现爬/叠加完成、手动重读）：女优库首页
    // 的进库会话缓存（文件夹/标签/分类/作品第一页）也作废，下次
    // 进库重查，不显示旧数据（2026-11-24 进库不重载）。
    NvkuEntryCache.clear();
  }

  void _openPerson(ActressPerson person) {
    // 2026-11-24 标签筛选：列表页选了标签时，详情页的作品列表也只
    // 留带该标签的作品（initialTag 传进去）。
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ActressDetailPage(
          localId: person.localId,
          repository: widget.repository,
          store: widget.store,
          database: _db,
          siteFilter: _source,
          initialTag: _videoTag,
          fallback: _fallback,
        ),
      ),
    );
  }
  void _openRanking() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ActressRankingPage(
          repository: widget.repository,
          store: widget.store,
          database: _db,
        ),
      ),
    );
  }

  /// 有数据库任务在跑（后台导入/表格更新/导出）：
  /// 齿轮图标换成小转圈，顶栏不占位也能看出在动。
  bool get _anyRunning => _taskController.busy;

  /// 设置弹窗（2026-11-21 用户令）：把原来排在顶栏的同步横幅、全站
  /// 叠加横幅、现爬横幅全收进这一个 ⚙️ 弹窗；
  /// 弹窗里的“同步爬取”小窗点标题即可收起（收回），只留一行摘要。
  Future<void> _openSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (_) => _ActressSettingsSheet(host: this),
    );
  }

  /// 演员筛选条（全部 / 女优 / 男优 + 排序）。
  /// 2026-11-22 用户令：这一排放页面最顶部，紧跟工具栏，演员列表
  /// 直接接在它下面。三枚 chips 照活树改版换成霓虹药丸钮。
  Widget _buildSexFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          ActressNeonPill(
            key: const ValueKey('actress-sex-all'),
            label: '全部',
            selected: _sex == ActressSexFilter.all,
            onTap: () => _setSex(ActressSexFilter.all),
          ),
          const SizedBox(width: 8),
          ActressNeonPill(
            key: const ValueKey('actress-sex-female'),
            label: '女优',
            selected: _sex == ActressSexFilter.female,
            onTap: () => _setSex(ActressSexFilter.female),
          ),
          const SizedBox(width: 8),
          ActressNeonPill(
            key: const ValueKey('actress-sex-male'),
            label: '男优',
            selected: _sex == ActressSexFilter.male,
            onTap: () => _setSex(ActressSexFilter.male),
          ),
          const Spacer(),
          PopupMenuButton<ActressSort>(
            key: const ValueKey('actress-sort-menu'),
            tooltip: '排序',
            initialValue: _sort,
            onSelected: (sort) {
              if (sort == _sort) return;
              _saveScrollOffsetForCache();
              setState(() => _sort = sort);
              _reloadAfterFilterChange();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: ActressSort.worksDesc,
                child: Text('按作品数'),
              ),
              PopupMenuItem(
                value: ActressSort.nameAsc,
                child: Text('按名字'),
              ),
              PopupMenuItem(
                value: ActressSort.recentDesc,
                child: Text('最近更新'),
              ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort_rounded, size: 18),
                const SizedBox(width: 4),
                Text(_sort.label),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final overview = _overview;
    return Scaffold(
      // 2026-11-21 用户令：内嵌进女优库区域时宿主已有自己的顶栏，
      // 这里再渲染一个 AppBar 就是两条栏叠在一起（搜索框看着像压住了顶栏）。
      // 内嵌时改由 _buildEmbeddedToolbar 提供一条置顶工具栏。
      // 顶栏照活树改版走霓虹 AppBar（actressNeonAppBar）。
      appBar: !widget.showTitle
          ? null
          : actressNeonAppBar(
        toolbarHeight: 40,
        title: widget.showTitle
            ? Text(
                overview == null
                    ? '演员库'
                    // 头顶人数只算有入库作品的人（2026-11-20 用户令：
                    // 要入库才算），只有名册、还没入库作品的人不算。
                    : '演员库 ${overview.personsWithWorks} 位演员',
              )
            : overview == null
            ? null
            : Text('${overview.personsWithWorks} 位演员'),
        actions: _toolbarActions(),
      ),
      body: Column(
        children: [
          if (!widget.showTitle) _buildEmbeddedToolbar(colors),
          // 2026-11-22 用户令「把演员那一栏所有全部放最顶部」：全部/
          // 女优/男优 + 排序这一排提到最顶，紧跟工具栏；原先它压在
          // 绑定行、库瓦片、搜索框下面，要往下翻才够得着。
          _buildSexFilterRow(),
          // 2026-11-21 用户令：同步/叠加/现爬不再在顶栏排一排横幅，
          // 全部收进右上角 ⚙️ 设置弹窗（弹窗里的“同步爬取”小窗可
          // 随手收回，见 _openSettingsSheet）。
          if (widget.showTitle)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
              child: _buildSearchField(),
            ),
          // 2026-11-24 第二排就是视频分类：三册全部/有码/无码/欧美/
          // 国产/4K/动漫/三级/其他，值取自数据库 video_category
          // 主分类（见 ActressTagFilter），接在欧美后面同一排平铺；
          // 9 个胶囊排不下就横向滑，不另起一排。
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final filter in ActressTagFilter.values) ...[
                    ChoiceChip(
                      label: Text(filter.label),
                      selected: _tagFilter == filter,
                      onSelected: (_) => _setTagFilter(filter),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
          // 2026-11-24 标签筛选：分类行下面独立一行放“标签”入口，
          // 不依赖分类行——库没有分类时入口也在；没选时只显示“标签”，
          // 选了显示“标签：<名>”高亮 + “清除”一键清掉。站源作品
          // 模式（nvku 作品网格）不走数据库筛选，不显示。
          if (!_siteWorksMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Row(
                children: _buildTagPills(
                  selected: _videoTag,
                  onOpen: _openTagSheet,
                  onClear: () => _setVideoTag(''),
                ),
              ),
            ),
          if (_siteWorksMode && _siteCategories.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final category in _siteCategories) ...[
                      ActressNeonPill(
                        key: ValueKey('site-category-${category.id}'),
                        label: category.name,
                        selected: _siteWorksCategory == category.id,
                        onTap: () =>
                            _setSiteWorksCategory(category.id),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
          // 后台导入中（2026-11-25）：离开设置弹窗也看得见进度，
          // 旧库照常能看能播；点取消就停（旧库不动）。
          if (_sqlImportRunning)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _sqlImportProgress == null
                          ? '正在后台导入数据库…（旧库照常能看能播）'
                          : '正在后台导入数据库…已导入 '
                                '${_sqlImportProgress!.statements} 条'
                                '（${(_sqlImportProgress!.fraction * 100).toStringAsFixed(0)}%）',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _cancelSqlImport,
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                _buildList(colors),
                // 2026-11-24 切换不重载：筛选切换时旧列表留着当底，
                // 只在列表顶露一条细进度条（_refreshing）。
                if (_refreshing)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  /// 顶栏动作：站点筛选 / 排行榜 / 刷新 / 设置。
  /// 抽出来是为了外层 AppBar 和内嵌时的置顶工具栏共用一份，
  /// 不出现「内嵌进女优库区域后这几个按钮消失」的问题。
  List<Widget> _toolbarActions() {
    return [
              PopupMenuButton<ActressSiteFilter>(
                key: const ValueKey('actress-site-filter'),
                tooltip: '站点筛选',
                initialValue: _source,
                onSelected: _setSiteFilter,
                itemBuilder: (_) => [
                  for (final filter in _siteFilterOptions())
                    PopupMenuItem(value: filter, child: Text(filter.label)),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.public_outlined, size: 18),
                    const SizedBox(width: 2),
                    Text(_source.label),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('open-actress-ranking'),
                tooltip: '演员排行榜',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.emoji_events_outlined),
                onPressed: _openRanking,
              ),
            // 2026-11-21 用户令：右上角“影视库”按钮没用，删掉。
            // 设置齿轮：数据库导入/管理全部收进这个弹窗，
            // 顶栏不再排一列横幅。
            IconButton(
              key: const ValueKey('open-actress-settings'),
              tooltip: '设置',
              visualDensity: VisualDensity.compact,
              icon: _anyRunning
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.settings_outlined),
              onPressed: _openSettingsSheet,
            ),
    ];
  }

  /// 搜索框本体（外层顶栏下方和内嵌工具栏里共用同一份）。
  Widget _buildSearchField() {
    return TextField(
      key: const ValueKey('actress-search'),
      controller: _searchController,
      decoration: InputDecoration(
        hintText: '搜名字或番号：中文 / 日文 / SSIS-123 都行',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: '清除搜索',
                icon: const Icon(Icons.clear_rounded),
                onPressed: () => _searchController.clear(),
              ),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  /// 内嵌进女优库区域时的置顶工具栏：人数 + 动作按钮同一行，
  /// 固定在列表上方不随滚动移动（2026-11-21 用户令）。
  /// 宿主传了外部搜索框时（女优库 nvku 外壳），搜索框只在宿主顶栏
  /// 留一个，这里不再重复画——原来两个搜索框看着就是叠在一起。
  Widget _buildEmbeddedToolbar(ColorScheme colors) {
    final external = widget.externalSearch != null;
    return Container(
      key: const ValueKey('actress-embedded-toolbar'),
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: EdgeInsets.fromLTRB(external ? 12 : 10, 6, 2, 0),
      child: Row(
        children: [
          if (!external) Expanded(child: _buildSearchField()),
          Text(
            _overview == null ? '演员库' : '${_overview!.personsWithWorks} 位演员',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          ..._toolbarActions(),
        ],
      ),
    );
  }

  /// 读数据库里的标签（video_tag.tag_name + 作品数，按作品数倒序）：
  /// 只在打开标签弹窗时调（懒加载），之后走缓存；读不到
  /// （没有 video_tag 表的库）回空，弹窗如实显示“暂无标签”。
  /// 缓存键只认内部工作库文件指纹（换库/重导后作废）。
  Future<List<(String, int)>> _loadDbTags() async {
    final cacheKey = _workingDbCacheKey(await actressWorkingDbPath());
    if (_dbTagsCacheKey == cacheKey && _dbTagsCache != null) {
      return _dbTagsCache!;
    }
    var tags = <(String, int)>[];
    try {
      tags = await _db.dbTags();
    } catch (_) {
      tags = const [];
    }
    _dbTagsCacheKey = cacheKey;
    _dbTagsCache = tags;
    return tags;
  }

  /// 内部工作库文件指纹（路径 + mtime + 大小）：标签缓存键用，
  /// 换库/重导后作废；读不到文件时回落到路径本身。
  String _workingDbCacheKey(String dbPath) {
    try {
      final stat = File(dbPath).statSync();
      return '$dbPath|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
    } catch (_) {
      return dbPath;
    }
  }
  /// 打开标签筛选底部弹窗（2026-11-24 用户令）：列出数据库里的
  /// 全部标签（带作品数），点标签即筛，点“全部”即清空。弹窗打开
  /// 前先查好标签（首次查库，之后走缓存）；没有标签也照常打开，
  /// 如实显示“暂无标签”，不拦。
  Future<void> _openTagSheet() async {
    final tags = await _loadDbTags();
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
          selected: _videoTag,
          onSelected: (tag) => Navigator.of(sheetContext).pop(tag),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    _setVideoTag(selected);
  }

  void _setVideoTag(String tag) {
    if (tag == _videoTag) return;
    _saveScrollOffsetForCache();
    setState(() => _videoTag = tag);
    _reloadAfterFilterChange();
  }

  void _setSex(ActressSexFilter sex) {
    if (sex == _sex) return;
    _saveScrollOffsetForCache();
    setState(() => _sex = sex);
    _reloadAfterFilterChange();
  }

  void _setTagFilter(ActressTagFilter filter) {
    if (filter == _tagFilter) return;
    _saveScrollOffsetForCache();
    setState(() => _tagFilter = filter);
    _reloadAfterFilterChange();
  }

  /// 标签入口药丸（2026-11-24 标签筛选）：分类行下面独立一行；
  /// 没选时只显示“标签”，点了开底部弹窗；选了显示“标签：<名>”高亮，
  /// 旁边再给一个“清除”一键清掉（页内可见、可一键清除）。
  List<Widget> _buildTagPills({
    required String selected,
    required VoidCallback onOpen,
    required VoidCallback onClear,
  }) {
    return [
      ActressNeonPill(
        key: const ValueKey('actress-tag-open'),
        label: selected.isEmpty ? '标签' : '标签：$selected',
        selected: selected.isNotEmpty,
        onTap: onOpen,
      ),
      const SizedBox(width: 8),
      if (selected.isNotEmpty) ...[
        ActressNeonPill(
          key: const ValueKey('actress-tag-clear'),
          label: '清除',
          selected: false,
          onTap: onClear,
        ),
        const SizedBox(width: 8),
      ],
    ];
  }

  /// 人物宫格布局：普通列表与姓名分组共用同一套格子尺寸。
  static const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 3,
    mainAxisSpacing: 16,
    crossAxisSpacing: 8,
    // 人物卡内容高约 142（上下 padding 12 + 头像 84 + 间距 10 +
    // 两行字约 36）：0.88 时格高约 132，底部“约 N 部”一行溢出，
    // 预览图上能看到黄黑溢出条（真机 release 不画条但字会被裁）；
    // 0.78 时格高约 150，刚好装下。
    childAspectRatio: 0.78,
  );

  /// 加载失败态（2026-11-26 加载优化）：原因 + 重试钮，替代原来
  /// 抛错后无声的永久转圈。主名单与站源作品网格共用。
  Widget _buildLoadError(ColorScheme colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '加载失败：$_loadError',
            key: const ValueKey('actress-list-load-error'),
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('actress-list-retry'),
            onPressed: () => unawaited(_loadPage(reset: true)),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ColorScheme colors) {
    // 只出作品的站源（nvku）：作品网格，点卡直发播放器。
    if (_siteWorksMode) return _buildSiteWorkList(colors);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _persons.isEmpty) {
      return _buildLoadError(colors);
    }
    if (_persons.isEmpty) {
      // 空态分流：没有导入库就是没有库（导入 .sql 数据库）；搜不到
      // 就是搜不到；选了站、该站没匹配上的人就说该站没有；确实
      // 一个人没有才是“暂无人物”——四种情况不混着说。
      final emptyText = _noLibraryDb
          ? '还没有导入数据库：请在设置里导入 .sql 数据库'
          : _query.isNotEmpty
          ? '没有找到“$_query”'
          : _source != ActressSiteFilter.all
          ? '该站暂无匹配人物'
          : '暂无人物';
      if (_noLibraryDb) {
        // 没导过库：内置 who's 数据顶上首页（2026-11-25 用户令）：
        // 作品流 + 按女优看，导入成功后自动刷新切回数据库口径
        // （本分支不再命中）。目录读不出来时视图内部回落纯空态。
        return ActressWhosTopupView(
          onPlay: _playTopupVideo,
          onImport: _startSqlImport,
          onManage: _openDbManagePage,
          pagerFuture: widget.topupPagerFuture,
          indexFuture: widget.topupIndexFuture,
        );
      }
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    // 按名字排序时按姓名首字母分组显示（通讯录式）；按作品数时不变。
    if (_sort == ActressSort.nameAsc) return _buildGroupedList(colors);
    return GridView.builder(
      key: const ValueKey('actress-person-list'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: _gridDelegate,
      itemCount: _persons.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _persons.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final person = _persons[index];
        return _ActressGridCard(
          key: ValueKey('actress-person-${person.localId}'),
          person: person,
          onTap: () => _openPerson(person),
        );
      },
    );
  }

  /// 站点作品网格（nvku）：封面 + 标题 + 番号/年份，点卡直接播。
  Widget _buildSiteWorkList(ColorScheme colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _siteWorks.isEmpty) {
      return _buildLoadError(colors);
    }
    if (_siteWorks.isEmpty) {
      final emptyText = _query.isNotEmpty ? '没有找到“$_query”' : '这个站暂时取不到作品';
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return GridView.builder(
      key: const ValueKey('actress-site-work-grid'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.58,
      ),
      itemCount: _siteWorks.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _siteWorks.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final drama = _siteWorks[index];
        return _GenericWorkCard(
          key: ValueKey('site-work-${drama.id}'),
          work: _siteWorkCard(drama),
          onTap: () => _playSiteWork(drama),
        );
      },
    );
  }

  /// 姓名分组列表：已加载的人按分组键顺序成段，每段一个字母头 +
  /// 一张宫格；翻页追加的人并入末段重算，不会把同一组拆成两段。
  Widget _buildGroupedList(ColorScheme colors) {
    final groups = <String, List<ActressPerson>>{};
    for (final person in _persons) {
      final key = actressGroupKey(person.displayName, person.aliases);
      (groups[key] ??= []).add(person);
    }
    return CustomScrollView(
      key: const ValueKey('actress-person-list'),
      controller: _scrollController,
      slivers: [
        for (final entry in groups.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Text(
                entry.key,
                key: ValueKey('actress-group-${entry.key}'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            sliver: SliverGrid.builder(
              gridDelegate: _gridDelegate,
              itemCount: entry.value.length,
              itemBuilder: (context, index) {
                final person = entry.value[index];
                return _ActressGridCard(
                  key: ValueKey('actress-person-${person.localId}'),
                  person: person,
                  onTap: () => _openPerson(person),
                );
              },
            ),
          ),
        ],
        if (_hasMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

/// 人物卡片：圆形大头像 + 名字 + “约 N 部”，照潮流女优库的样子。
class _ActressGridCard extends StatelessWidget {
  const _ActressGridCard({
    super.key,
    required this.person,
    required this.onTap,
  });

  final ActressPerson person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: actressNeonCardDecoration(),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              ActressAvatar(
                avatarUrl: person.avatarUrl,
                name: person.displayName,
                radius: 42,
              ),
              const SizedBox(height: 8),
              Text(
                person.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: Neon.text),
              ),
              const SizedBox(height: 2),
              Text(
                '约 ${person.displayWorks} 部',
                maxLines: 1,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Neon.textDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 通用模式作品行：封面缩略图 + 标题 + 副标题（日期/番号/分类），
/// 点按直接播；没有可播地址的行不显示播放钮。
/// 外来库作品卡（2026-11-21 用户令：作品一律网格卡片）：封面 + 标题
/// + 副标题（番号/日期 · 女优），点卡直播。
class _GenericWorkCard extends StatelessWidget {
  const _GenericWorkCard({super.key, required this.work, required this.onTap});

  final GenericDbWork work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (work.displaySubtitle.isNotEmpty) work.displaySubtitle,
      if (work.actress.isNotEmpty) work.actress,
    ].join(' · ');
    return Container(
      decoration: actressNeonCardDecoration(radius: 10),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ColoredBox(
                    color: Neon.surfaceHigh,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (work.coverUrl.isEmpty)
                          const Center(
                            child: Icon(
                              Icons.movie_outlined,
                              color: Neon.textDim,
                            ),
                          )
                        else
                          Image.network(
                            work.coverUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Center(
                              child: Icon(
                                Icons.movie_outlined,
                                color: Neon.textDim,
                              ),
                            ),
                          ),
                        if (work.playable)
                          const Positioned(
                            right: 4,
                            bottom: 4,
                            child: Icon(
                              Icons.play_circle_fill,
                              size: 18,
                              color: Neon.cyan,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                work.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.25,
                  color: Neon.text,
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Neon.textDim),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 女优库设置弹窗（2026-11-21 用户令）：原来排在顶栏的同步、全站叠加、
/// 现爬三块状态与操作全收进这里；弹窗内的“同步爬取”
/// 小窗点标题即可收起（收回），只留一行摘要，随时再展开。
class _ActressSettingsSheet extends StatefulWidget {
  const _ActressSettingsSheet({required this.host});

  final _ActressListPageState host;

  @override
  State<_ActressSettingsSheet> createState() => _ActressSettingsSheetState();
}

class _ActressSettingsSheetState extends State<_ActressSettingsSheet> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 进度都在页面 State 里：弹窗每 600ms 取一次最新值，跑起来时
    // 数字会走；不额外订阅进度流，关掉弹窗就停，不留监听。
    _ticker = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  _ActressListPageState get _host => widget.host;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final host = _host;
    final busy = host._anyRunning;
    final textStyle = Theme.of(context).textTheme;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题行（2026-11-25 同步功能删除后，弹窗只剩数据库
            // 相关操作：导入 + 管理入口）。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.storage_rounded, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('数据库', style: textStyle.titleMedium),
                  ),
                ],
              ),
            ),
              // 2026-11-25 .sql 导入：选 .sql / .sql.gz 文件导回主库
              //（临时库校验通过才换，失败原库不动）。不再要求先绑定
              // MYTV：导入直接落到内部工作库。
              ActressSqlImportSection(
                bound: true,
                running: host._sqlImportRunning,
                progress: host._sqlImportProgress,
                error: host._sqlImportError,
                lastResult: host._sqlImportResult,
                onImport: host._sqlImportRunning
                    ? null
                    : host._startSqlImport,
                onCancel: host._sqlImportRunning
                    ? host._cancelSqlImport
                    : null,
              ),
              // 2026-11-25 数据库管理入口（与导入同区）：库信息、
              // 表格导入更新、导出、备份恢复、删除数据库都在里面。
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.circle, size: 8),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('数据库管理', style: textStyle.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            '看库信息、用表格更新、导出、恢复备份、删除数据库。',
                            style: textStyle.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: host._openDbManagePage,
                      child: const Text('打开'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  busy ? '有任务在跑，关掉这个窗也会继续跑；随时点齿轮看进度。' : '全部任务都没在跑。',
                  style: textStyle.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
