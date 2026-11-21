import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'actress_database.dart';
import 'actress_db_fields_page.dart';
import 'actress_db_mirror.dart';
import 'actress_detail_page.dart';
import 'actress_film_library.dart';
import 'actress_generic_db.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_mytv_bind.dart';
import 'actress_ranking_page.dart';
import 'actress_roster_sources.dart';
import 'actress_search.dart';
import 'actress_site_crawl.dart';
import 'actress_stacking.dart';
import 'actress_sync.dart';
import 'actress_widgets.dart';
import '../content_http.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import '../player_picker.dart';

/// 女优库浏览页：人物列表 + 搜索/性别筛选/排序 + 同步横幅。
///
/// 打开只读本地库 + 内置 json/m3u 兜底，不自动爬取网站、不后台
/// 自动续爬（2026-11-20 用户令：不自动爬取）；同步只在用户点了
/// 刷新/重试、或检测到新版内置 json 到达时跑一次，跑完不自动再续。
/// 例外只有库缺失/空库时自动生成一次（2026-11-20 MYTV 绑定令：
/// 内置 json 种子灌入 + 走现有同步，见 _autoGenerateLibrary），
/// 灌完库不再是空库，下次打开不再重复跑。排行榜入口在顶栏奖杯钮。
/// 全站叠加入口在同步横幅下方：手动开始/继续，按番号把各站作品
/// 叠加进库，断点续跑，不自动跑、不与名册同步抢着跑。
/// 同步/现爬进行中、列表还空时，每 8 秒节流刷新一次列表（有人
/// 出现即停），爬到的条目写盘后进库镜像，列表陆续出人。
/// 站点筛选下拉选项（纯函数，供测试直接验）：全部 + mjv + whos +
/// 片库全部可见视频站（与叠加搜索 actressSearchSiteIds 同一口径：
/// store.visibleSources 里 isVideoSection、非 cloud:、siteVisible
/// 的站；跳过 mjv/whos/chaoliu——chaoliu 即 mjv，已有 mjv 项代表
/// 它；yikm 这类游戏站不在视频区登记里，进不了选项）。
List<ActressSiteFilter> actressSiteFilterOptions(LocalStore store) {
  final options = <ActressSiteFilter>[
    ActressSiteFilter.all,
    ActressSiteFilter.mjv,
    ActressSiteFilter.whos,
  ];
  final seen = <String>{'all', 'mjv', 'whos', 'chaoliu'};
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
    this.syncService,
    this.stackingService,
    this.fallback,
    this.crawlService,
    this.showTitle = true,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 内嵌进区域/窗口/内层页签时宿主已有“女优库”标题，页内顶栏不再
  /// 重复标题字（只留人数），与 MiniAppHomePage 的做法同口径。
  final bool showTitle;

  /// 测试/预览注入：不传时用 sqflite 真库 + 默认三家名册源。
  @visibleForTesting
  final ActressDatabase? database;
  @visibleForTesting
  final ActressSyncService? syncService;

  /// 测试/预览注入：不传时用默认叠加服务（与详情页同一套补全）。
  @visibleForTesting
  final ActressStackingService? stackingService;

  /// 测试/预览注入：JSON 兜底与现爬服务；不传时现建。
  @visibleForTesting
  final ActressJsonFallback? fallback;
  @visibleForTesting
  final ActressSiteCrawlService? crawlService;

  @override
  State<ActressListPage> createState() => _ActressListPageState();
}

class _ActressListPageState extends State<ActressListPage> {
  static const _pageSize = 60;
  // 进行中刷新节流：同步/现爬跑着、列表还空时，最多每 8 秒刷新
  // 一次列表（有人出现即停）；总览（库里作品数）最多每 5 秒读
  // 一次，不拿 COUNT(*) 高频刷库。
  static const _progressListRefreshInterval = Duration(seconds: 8);
  static const _overviewRefreshInterval = Duration(seconds: 5);

  late final ActressDatabase _db;
  late final ActressSyncService _sync;
  late final ActressStackingService _stacking;
  late final ActressJsonFallback _fallback;
  late final ActressSiteCrawlService _crawl;
  ContentHttp? _http;
  StreamSubscription<ActressSyncProgress>? _progressSub;
  StreamSubscription<ActressStackingProgress>? _stackingSub;
  StreamSubscription<ActressSiteCrawlProgress>? _crawlSub;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  var _persons = <ActressPerson>[];
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = true;
  var _sex = ActressSexFilter.all;
  var _tagFilter = ActressTagFilter.all;
  var _sort = ActressSort.worksDesc;

  /// 数据库分类筛选：默认全部；选分类后列表只留该分类里有作品的
  /// 人。分类来自用户库 video_category 主分类（FilmLibraryService
  /// .categories，带作品数）；没接上库、没有分类时这行不显示。
  var _category = '';
  var _dbCategories = <(String, int)>[];
  var _query = '';
  var _generation = 0;

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

  ActressSyncProgress _progress = ActressSyncProgress.idle;
  ActressStackingProgress _stackingProgress = ActressStackingProgress.idle;
  ActressSiteCrawlProgress _crawlProgress =
      const ActressSiteCrawlProgress();
  ActressSyncOverview? _overview;
  var _lastSyncFailed = false;

  /// 本轮开始时库里作品数（同步/现爬跑起来时记一次）：横幅用它算
  /// “本轮 +N”，爬一页涨多少一眼能看到；跑完清掉。
  int? _worksAtRunStart;

  /// 进行中刷新节流的上次时间。
  DateTime _lastProgressListRefresh =
      DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastOverviewRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 导出合并 JSON 进行中（防重复点）。
  var _exportingJson = false;

  /// 2026-11-20 MYTV 绑定：绑定解析结果（库落点、是否已授权、
  /// 迁移情况）。bootstrap 第一件事就是解析它——在第一次读库
  /// 之前，库的落点（MYTV/db/女优库应用.db 或 documents/actress.db）
  /// 与 json/m3u 目录都由它定。
  MytvBindResult? _mytvBind;

  /// 绑定行被用户点了“继续用内部存储”后隐藏（本页内有效）。
  var _mytvRowDismissed = false;

  /// 空库自动生成进行中：内置 json 种子灌入 + 走现有同步。
  /// 只在库缺失/空库时跑一次（见 _autoGenerateLibrary）。
  var _mytvGenerating = false;

  /// 自动生成本页内只跑一次（防 bootstrap 重入重复爬）。
  var _mytvAutoSeeded = false;

  /// 种子已灌入的条目数（生成横幅显示进度用）。
  var _seededCount = 0;

  /// 兜底加载器与现爬服务是不是本页自己建的：是才按绑定结果
  /// 改它们的本地目录；测试注入的实例不动（注入的假目录优先）。
  var _ownsFallback = true;
  var _ownsCrawl = true;

  /// 2026-11-20 热换库：最近一次重读失败的原因（显示在绑定行上，
  /// 留旧库继续用）；成功重读后清掉。
  String? _mytvDbError;

  /// 手动“重新加载数据库”进行中（防重复点）。
  var _reloadingDb = false;

  /// 2026-11-20 用户令“全部使用数据库兜底”：开库时 MYTV 库
  /// 损坏/打不开回退内置库的原因（显示在绑定行上）。
  String? _mytvOpenNote;

  /// 2026-11-20 数据库镜像：主目录与补充目录里其他 .db 文件的追加
  /// 进行中、已追加数、总行数、正在追加的文件名、失败原因。
  var _mirrorRunning = false;
  var _mirrorAppended = 0;
  var _mirrorTotal = 0;
  var _mirrorFile = '';
  String? _mirrorError;

  /// 2026-11-20 通用读库：当前库不是女优库结构时为 true，列表
  /// 改走通用作品模式（作品列表 + 点按直播），不走女优库的总览/
  /// 同步/自动生成。[_genericReader] 为空时不是通用模式。
  var _genericMode = false;
  GenericDbReader? _genericReader;
  var _genericWorks = <GenericDbWork>[];
  var _genericTotal = 0;

  @override
  void initState() {
    super.initState();
    _db = widget.database ?? SqfliteActressDatabase.instance;
    // 先建兜底加载器与现爬服务：同步服务默认要接爬虫腿（潮流源
    // 作品阶段改走爬虫逻辑），构造顺序不能反。
    _ownsFallback = widget.fallback == null;
    _ownsCrawl = widget.crawlService == null;
    _fallback = widget.fallback ?? ActressJsonFallback();
    if (_ownsFallback) {
      // 2026-11-20 18:57 全部使用数据库兜底：兜底先查影视库 db
      // （MYTV/db/女优库应用.db），读不到回退 json/m3u。测试注入的
      // fallback 不接提供方，保持老行为。
      _fallback.filmDb = FilmLibraryService(database: _db);
    }
    _crawl =
        widget.crawlService ??
        ActressSiteCrawlService(repository: widget.repository, db: _db);
    _crawlSub = _crawl.progress.listen(_onCrawlProgress);
    if (widget.syncService != null) {
      _sync = widget.syncService!;
    } else {
      _http = ContentHttp();
      _sync = ActressSyncService(
        db: _db,
        sources: [
          ChaoliuRosterSource(),
          // 2026-11-21 用户令：MissAV 从同步移除，不再拉取
          // （视频站、jar、名册显示与枚举都不动）；排行主链改走
          // whos 日榜，enableRanking 开关已开。
          WhosRosterSource(enableRanking: true),
        ],
        fetch: actressDefaultFetch(_http!),
        crawlService: _crawl,
      );
    }
    _progressSub = _sync.progress.listen(_onProgress);
    if (widget.stackingService != null) {
      _stacking = widget.stackingService!;
    } else {
      _stacking = ActressStackingService(
        db: _db,
        enrichment: ActressEnrichment(
          repository: widget.repository,
          store: widget.store,
          db: _db,
        ),
      );
    }
    _stackingSub = _stacking.progress.listen(_onStackingProgress);
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
    // 站点筛选选项进页时按活的站源注册表读一次（不是启动快照）；
    // 之后站源注册表再变（新站导入/站点摘掉/隐藏）走监听重建。
    _siteOptionIds = _siteFilterOptions().map((o) => o.siteId).toSet();
    widget.store.addListener(_onStoreChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _progressSub?.cancel();
    _stackingSub?.cancel();
    _crawlSub?.cancel();
    _crawl.cancel();
    _crawl.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    _sync.cancel();
    _sync.dispose();
    _stacking.cancel();
    _stacking.dispose();
    _http?.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    // 2026-11-20 MYTV 绑定：先解析绑定，再读库。绑定里建
    // MYTV/db 与 MYTV/m3u、迁移老数据（开库前做，库开着拷
    // 不干净）；没权限/外部存储不可用时降级回 documents，
    // 下面流程不变，女优库照常能用。测试环境没有平台通道，
    // 解析内部全包 try/catch，拿不到就降级，不抛错。
    final bind = await ActressMytvBind.instance.ensureBound();
    if (!mounted || generation != _generation) return;
    setState(() => _mytvBind = bind);
    if (_ownsFallback) {
      _fallback.bindLocalDirs(
        jsonDir: bind.jsonDir,
        userM3uDir: bind.bound ? bind.m3uDir : null,
      );
    }
    if (_ownsCrawl) _crawl.bindLocalDir(bind.jsonDir);
    // 2026-11-20 热换库：进模块先看库文件变了没有——变了就关旧连接
    // 重开再读（用户用文件管理器换了 db 不用重装）；重读失败留旧库
    // 并把原因记下来显示在绑定行上，不崩。
    final reload = await _db.reloadIfChanged();
    if (!mounted || generation != _generation) return;
    if (reload.error != null) {
      setState(() => _mytvDbError = reload.error);
    }
    // 2026-11-20 通用读库：当前库不是女优库结构时走通用模式
    // （作品列表 + 点按直播），不走女优库的总览/同步/自动生成。
    final generic = await _db.genericReader();
    if (!mounted || generation != _generation) return;
    if (generic != null) {
      setState(() {
        _genericReader = generic;
        _genericMode = true;
      });
      await _loadPage(reset: true);
      return;
    }
    setState(() {
      _genericReader = null;
      _genericMode = false;
    });
    // 兜底后台读、不堵首屏：列表站点过滤与新版 json 检测都要用它，
    // 但不能在首屏等它——widget 测试里 rootBundle 异步读在
    // FakeAsync 下等不到返回（异步 dart:io 挂起是测试环境的老
    // 毛病，真机上不影响）；新版检测挂在读完的回调里。
    unawaited(
      _fallback.load().then((_) async {
        if (!mounted || generation != _generation) return;
        await _maybeSyncOnNewJson();
      }),
    );
    final overview = await _db.overview();
    if (!mounted || generation != _generation) return;
    setState(() => _overview = overview);
    // 2026-11-20 用户令“全部使用数据库兜底”：开库时 MYTV 库
    // 损坏回退内置库的原因，显示在绑定行上。
    final openNote = _db.openFallbackNote;
    if (openNote != null) {
      setState(() => _mytvOpenNote = openNote);
    }
    // 2026-11-20 MYTV 绑定：库缺失/空库时自动生成（只跑一次，
    // 正常打开不重复爬）：先把包里内置的 mjv011.json + whos.json
    // 当种子灌进库（m3u 分片本来就是兜底索引，不用灌库），
    // 再走现有的 actress_sync 从互联网同步（潮流 → whos，
    // 复用现有逻辑与并发上限）。手动同步与“随包新版
    // json 到达时跑一次”触发不变。
    if (overview.persons == 0 &&
        overview.works == 0 &&
        !_mytvAutoSeeded) {
      _mytvAutoSeeded = true;
      unawaited(_autoGenerateLibrary());
    }
    // 叠加只读一次断点作横幅状态，绝不自动跑。
    final stacking = await _stacking.snapshot();
    if (!mounted || generation != _generation) return;
    setState(() => _stackingProgress = stacking);
    // _loadPage(reset) 会推进代次，这里只判 mounted，不再比代次。
    await _loadPage(reset: true);
    if (!mounted) return;
    // 数据库里的分类读一次挂上行：同步跑完分类变了走
    // _refreshAfterSync 再刷。
    unawaited(_loadDbCategories());
    // 不自动爬取（2026-11-20 用户令）：打开只读本地 + 内置
    // json/m3u 兜底，不自动起爬、不后台自动续爬；只在检测到新版
    // 内置 json 到达时跑一次同步，其余时候等用户手动点刷新/重试。
    // 新版检测已挂在兜底读完的回调里，这里不再等。
    // 2026-11-20 数据库镜像：主目录与补充目录里其他 .db 文件有作品就
    // 递增追加进库（后台跑，列表数边涨边看）。
    unawaited(_maybeStartDbMirror());
  }

  /// 空库自动生成（2026-11-20 MYTV 绑定）：库不存在或 0 人
  /// 0 作品时才跑，本页内只跑一次。先把包里内置的 mjv011.json
  /// + whos.json 当种子灌进库（分 200 条一批灌，横幅显示进度；
  /// m3u 分片本来就是兜底索引，不用灌库），再走现有的 _runSync
  /// 从互联网同步（潮流 → whos，复用现有同步逻辑与
  /// 并发上限，不另写爬虫）。种子是本地文件，离线也能灌上人，
  /// 灌完库就不再是空库，下次打开不再重复跑；同步失败只记横幅，
  /// 不抛错、不影响列表打开。
  Future<void> _autoGenerateLibrary() async {
    if (_mytvGenerating) return;
    _mytvGenerating = true;
    if (mounted) setState(() {});
    try {
      await _fallback.load();
      final entries = _fallback.entries;
      const chunk = 200;
      for (var i = 0; i < entries.length; i += chunk) {
        final end = (i + chunk).clamp(0, entries.length);
        await mirrorActressJsonEntriesToDb(
          _db,
          entries.sublist(i, end),
        );
        if (!mounted) return;
        setState(() => _seededCount = end);
      }
    } catch (_) {
      // 种子灌失败也不崩：后面同步还会从互联网补。
    } finally {
      if (mounted) {
        setState(() => _mytvGenerating = false);
      } else {
        _mytvGenerating = false;
      }
    }
    if (!mounted) return;
    await _runSync();
    if (mounted) unawaited(_refreshAfterSync());
    // 自动生成跑完库安静了：主目录与补充目录里其他 .db 文件有作品就
    // 递增追加进库（见 _maybeStartDbMirror）。
    if (mounted) unawaited(_maybeStartDbMirror());
  }

  /// 没拿到“所有文件访问权限”时打开系统授权页（走平台通道，
  /// 照树里悬浮窗去设置的路子）。用户在设置里授权后回 App，
  /// 点绑定行上的“重新绑定”再切 MYTV；授权前女优库一直用
  /// 内部存储，照常能用。
  Future<void> _requestMytvPermission() async {
    await ActressMytvBind.instance.requestPermission();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已打开系统设置，授权后点“重新绑定”')),
    );
  }

  /// 授权后重新绑定：先关库（迁移要拷老库文件，开着库拷不干净；
  /// close 会清 _openFuture，下次开库重新走绑定路径），再重新
  /// 解析绑定、给 json/m3u 重新指目录、重读总览与列表。
  Future<void> _rebindMytv() async {
    await _db.close();
    final bind = await ActressMytvBind.instance.ensureBound(refresh: true);
    if (!mounted) return;
    setState(() {
      _mytvBind = bind;
      _mytvRowDismissed = false;
    });
    if (_ownsFallback) {
      _fallback.bindLocalDirs(
        jsonDir: bind.jsonDir,
        userM3uDir: bind.bound ? bind.m3uDir : null,
      );
    }
    if (_ownsCrawl) _crawl.bindLocalDir(bind.jsonDir);
    await _refreshAfterSync();
  }

  /// 手动“重新加载数据库”（2026-11-20 热换库）：不管文件指纹变
  /// 没变都重读一次当前文件。重读后重新探结构（不要沿用旧映射）：
  /// 模式可能变了（女优库 ↔ 外来库），按新模式重读列表。重读
  /// 失败留旧库并报原因，不崩、不丢数据。
  Future<void> _manualReloadDb() async {
    if (_reloadingDb) return;
    _reloadingDb = true;
    try {
      final result = await _db.reloadIfChanged(force: true);
      if (!mounted) return;
      if (result.error != null) {
        setState(() => _mytvDbError = result.error);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('数据库重读失败：${result.error}，仍用旧库'),
          ),
        );
        return;
      }
      setState(() => _mytvDbError = null);
      final generic = await _db.genericReader();
      if (!mounted) return;
      setState(() {
        _genericReader = generic;
        _genericMode = generic != null;
      });
      if (_genericMode) {
        await _loadPage(reset: true);
      } else {
        await _refreshAfterSync();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.reloaded ? '已重新加载数据库' : '数据库没有变化'),
        ),
      );
      // 重读后库安静了：主目录与补充目录里其他 .db 文件有作品就递增追加。
      unawaited(_maybeStartDbMirror());
    } finally {
      _reloadingDb = false;
    }
  }

  /// 数据库镜像（2026-11-20 用户令“读取数据库要把作品数量
  /// 递增追加上去”，2026-11-21 用户令按 py 的涩库引擎逻辑改路
  /// 径）：扫主目录 MYTV/db（只扫一层）与补充目录（纯福利/db、
  /// 女优库、私藏视频、lz/db，递归扫）下除当前库文件外的 *.db，
  /// 逐个只读打开、分批（200 条）按合并规则追加进当前库。
  /// 触发点：bootstrap 末尾、自动生成跑完、手动重读成功后。
  /// 护栏：通用模式（当前库本身是外来库）不跑；库正在生成/
  /// 同步时不跑（等下次安静时再试）；正在跑时不重复起；同一
  /// 文件指纹未变时跳过（镜像记录在 镜像记录.json 里）。
  /// 追加失败记错不崩，已有数据不受影响。
  Future<void> _maybeStartDbMirror() async {
    if (_genericMode) return;
    if (_mirrorRunning) return;
    if (_mytvGenerating || _sync.isRunning) return;
    final bind = _mytvBind;
    if (bind == null || !bind.bound) return;
    // 补充目录（py 的 SikuEngine.DB_DIRS 同款）从外部存储根
    // 目录拼；没根目录时只扫主目录。
    final externalRoot = bind.externalRoot;
    final extraDirs = externalRoot == null
        ? const <Directory>[]
        : [
            for (final rel in sikuDbScanDirs)
              Directory(path.join(externalRoot.path, rel)),
          ];
    final targets = collectDbMirrorTargets(
      dbDir: bind.dbDir,
      libraryPath: bind.dbPath,
      extraDirs: extraDirs,
    );
    if (targets.isEmpty) return;
    setState(() {
      _mirrorRunning = true;
      _mirrorFile = targets.map((f) => path.basename(f.path)).join('、');
      _mirrorAppended = 0;
      _mirrorTotal = 0;
      _mirrorError = null;
    });
    for (final target in targets) {
      if (!mounted) return;
      final result = await const ActressDbMirror().mirrorFile(
        sourcePath: target.path,
        library: _db,
        libraryPath: bind.dbPath,
        onProgress: (appended, total) {
          if (!mounted) return;
          setState(() {
            _mirrorAppended = appended;
            _mirrorTotal = total;
          });
          // 每批刷新一次可见列表与总览：追加过程列表能看到数在涨。
          unawaited(_refreshVisiblePersons());
          unawaited(
            _db.overview().then((overview) {
              if (mounted) setState(() => _overview = overview);
            }),
          );
        },
      );
      if (!mounted) return;
      if (result.error != null) {
        setState(
          () => _mirrorError = '${path.basename(target.path)}：${result.error}',
        );
      } else if (result.appended > 0 || result.updated > 0) {
        // 追加完刷新一次可见列表与总览（数涨上去），不重置滚动。
        unawaited(_refreshVisiblePersons());
        unawaited(
          _db.overview().then((overview) {
            if (mounted) setState(() => _overview = overview);
          }),
        );
      }
    }
    if (mounted) {
      setState(() => _mirrorRunning = false);
    }
  }

  /// 新版内置 json 检测：随包 json 的 last_update 变新了才跑一次
  /// 同步（新数据到了才更新）；本地影子文件的 last_update 不算
  /// （现爬每页都写新时间，算它会在每次现爬后都触发同步）。
  /// 首次打开只记版本戳，不触发（等用户手动点刷新）。
  Future<void> _maybeSyncOnNewJson() async {
    // 2026-11-20 通用读库：外来库不走女优库同步。
    if (_genericMode) return;
    // 2026-11-20 MYTV 绑定：本页已自动生成过（空库种子 + 同步）
    // 就不再重复触发——种子刚读的就是这份随包 json，自动生成的
    // 同步已覆盖“新版到了跑一次”。
    if (_mytvAutoSeeded) return;
    var current = '';
    for (final value in _fallback.bundledLastUpdate.values) {
      if (value.compareTo(current) > 0) current = value;
    }
    if (current.isEmpty) return;
    final stored = await _db.jsonVersionStamp();
    if (stored == null) {
      await _db.saveJsonVersionStamp(current);
      return;
    }
    if (current.compareTo(stored) <= 0) return;
    await _db.saveJsonVersionStamp(current);
    if (!_sync.isRunning) unawaited(_runSync());
  }

  void _onProgress(ActressSyncProgress progress) {
    if (!mounted) return;
    setState(() => _progress = progress);
    if (progress.running) {
      // 本轮起点：第一次跑起来时记一次库里作品数，横幅算“本轮 +N”。
      _worksAtRunStart ??= _overview?.works ?? 0;
      _maybeRefreshOverview();
      _maybeRefreshListWhileRunning();
      return;
    }
    _clearWorksStartIfIdle();
    if (progress.phase == 'done') {
      unawaited(_refreshAfterSync());
    }
  }

  /// 同步与现爬都停了才清本轮起点（两路可能同时跑，清早了横幅
  /// 的“本轮 +N”就断了）。
  void _clearWorksStartIfIdle() {
    if (!_progress.running && !_crawlProgress.running) {
      _worksAtRunStart = null;
    }
  }

  /// 进行中总览节流刷新（最多每 5 秒读一次库里作品数）：横幅的
  /// “库里作品 X 部（本轮 +N）”靠它长，跑完才刷一次看不见增长。
  void _maybeRefreshOverview() {
    final now = DateTime.now();
    if (now.difference(_lastOverviewRefresh) < _overviewRefreshInterval) {
      return;
    }
    _lastOverviewRefresh = now;
    unawaited(
      _db.overview().then((overview) {
        if (mounted) setState(() => _overview = overview);
      }),
    );
  }

  /// 进行中刷新（最多每 8 秒一次）：同步/现爬跑着时重读列表，
  /// 卡片数随入库增长陆续更新——列表空时整页重读（有人出现即
  /// 停），列表非空时只原地替换当前已加载页的卡片数据（不动
  /// 加载态、不动滚动位置）。旧版只在列表空时刷，非空列表在
  /// 同步进行中永远停在进页那一刻的数（2026-11-20 计数修复：
  /// 列表 54 部、详情 992 部就是这么来的）。
  void _maybeRefreshListWhileRunning() {
    final now = DateTime.now();
    if (now.difference(_lastProgressListRefresh) <
        _progressListRefreshInterval) {
      return;
    }
    _lastProgressListRefresh = now;
    if (_persons.isEmpty) {
      unawaited(_loadPage(reset: true));
      return;
    }
    unawaited(_refreshVisiblePersons());
  }

  /// 进行中轻量刷新：只重读当前已加载的原始页（offset 0、
  /// limit=_rawOffset），原地替换卡片数据；不碰 _loading、
  /// 不碰 _generation（不打断在途的整页加载）、不动滚动位置。
  Future<void> _refreshVisiblePersons() async {
    final generation = _generation;
    final limit = _rawOffset <= 0 ? _pageSize : _rawOffset;
    final raw = await _db.listPersons(
      sex: _sex,
      sort: _sort,
      query: _query,
      tag: _tagFilter.tagValue,
      offset: 0,
      limit: limit,
    );
    final persons = await _applySiteFilter(raw);
    if (!mounted || generation != _generation) return;
    setState(() {
      _persons = persons;
      _hasMore = raw.length >= _pageSize;
    });
  }

  /// 本轮入库增长文案（2026-11-20 用户令：增长要看得见，按
  /// “要入库才算”只算库里实际有的）：库里作品总数 + 本轮新增。
  String _worksGrowthText() {
    final overview = _overview;
    if (overview == null) return '';
    final start = _worksAtRunStart;
    if (start == null) return '库里作品 ${overview.works} 部';
    final delta = overview.works - start;
    return '库里作品 ${overview.works} 部（本轮 +$delta）';
  }

  void _onStackingProgress(ActressStackingProgress progress) {
    if (!mounted) return;
    setState(() => _stackingProgress = progress);
    if (progress.running) {
      // 叠加也在写库：进行中同样节流刷卡片数（与同步同一节流）。
      _maybeRefreshListWhileRunning();
      return;
    }
    // 叠加写库刷新了 works_count：总览与列表都要重读才显示真数。
    unawaited(_refreshAfterSync());
  }

  /// 手动开始/继续叠加：名册同步跑着时不启动（两路同时写库抢带宽，
  /// 等同步停了再点）；叠加服务内部断点续跑，本处只管触发一次。
  Future<void> _runStacking() async {
    if (_stacking.isRunning || _progress.running) return;
    await _stacking.run();
  }

  Future<void> _refreshAfterSync() async {
    final overview = await _db.overview();
    if (!mounted) return;
    setState(() => _overview = overview);
    await _loadPage(reset: true);
    if (!mounted) return;
    unawaited(_loadDbCategories());
  }

  /// 只断点续跑：永远不从头重拉（refresh 恒为 false）。手动点一次
  /// 跑一次，跑完不自动再续（2026-11-20 用户令：不自动爬取）；
  /// 没跑完下次手动点继续补。跑之前记一次库里作品数，横幅算
  /// “本轮 +N”。
  Future<void> _runSync() async {
    // 2026-11-20 通用读库：外来库不走女优库同步。
    if (_genericMode) return;
    if (_sync.isRunning) return;
    _worksAtRunStart = _overview?.works ?? 0;
    setState(() => _lastSyncFailed = false);
    final result = await _sync.run(refresh: false);
    if (!mounted) return;
    setState(() => _lastSyncFailed = result.hasFailures);
    final overview = await _db.overview();
    if (!mounted) return;
    setState(() => _overview = overview);
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      unawaited(_loadPage());
    }
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      final query = _searchController.text.trim();
      if (query == _query) return;
      setState(() => _query = query);
      unawaited(_loadPage(reset: true));
    });
  }

  void _onCrawlProgress(ActressSiteCrawlProgress progress) {
    if (!mounted) return;
    setState(() => _crawlProgress = progress);
    if (progress.running) {
      _worksAtRunStart ??= _overview?.works ?? 0;
      _maybeRefreshOverview();
      _maybeRefreshListWhileRunning();
      return;
    }
    _clearWorksStartIfIdle();
    if (!progress.done) return;
    // 现爬写了新的本地 JSON：重读兜底再刷新列表，爬到的条目立刻可见。
    unawaited(_fallback.load().then((_) {
      if (mounted) unawaited(_loadPage(reset: true));
    }));
  }

  /// 导出合并 JSON（写回内置用）：随包 + 本地全部行按更新规则合并
  /// 后的全文（内置格式），走系统保存对话框存成 mjv011.json，
  /// 拷进树里 assets/actress_json/mjv011.json，下次打包带走。
  Future<void> _exportMergedJson() async {
    if (_exportingJson) return;
    setState(() => _exportingJson = true);
    try {
      if (!_fallback.loaded) await _fallback.load();
      final doc = _fallback.mergedDocument();
      final text = const JsonEncoder.withIndent('  ').convert(doc);
      // 2026-11-20 MYTV 绑定：已绑定时直接写到 MYTV/mjv011.json
      // （根目录，不碰 MYTV/db 里正在用的影子文件），用户用文件
      // 管理器拷走即用；未绑定时走原来的选位置保存。
      final bind = _mytvBind;
      if (bind != null && bind.bound) {
        await File(bind.mergedJsonExportPath).writeAsString(text);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已导出到 MYTV/mjv011.json')),
        );
        return;
      }
      final bytes = Uint8List.fromList(utf8.encode(text));
      final savedUri = await FilePicker.saveFile(
        dialogTitle: '导出合并 JSON',
        fileName: ActressJsonFallback.localFileName,
        bytes: bytes,
        mimeType: 'application/json',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedUri == null
                ? '已取消导出'
                : '已导出合并 JSON，可拷进树里内置文件',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导出失败')),
        );
      }
    } finally {
      if (mounted) setState(() => _exportingJson = false);
    }
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
    if (_source != ActressSiteFilter.all &&
        !ids.contains(_source.siteId)) {
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

  /// 选站后触发该站分类现爬（mjv 现爬、whos 报缺口走兜底、
  /// 片库站走本站蜘蛛分类现爬）。
  Future<void> _runSiteCrawl() async {
    if (_crawl.running) return;
    await _crawl.start(site: _source.siteId);
  }

  void _setSiteFilter(ActressSiteFilter source) {
    if (source == _source) return;
    setState(() => _source = source);
    unawaited(_loadPage(reset: true));
    if (source != ActressSiteFilter.all) {
      unawaited(_runSiteCrawl());
    }
  }

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
    // 2026-11-20 通用读库：外来库走通用作品翻页（标题/番号 LIKE 搜）。
    if (_genericMode) {
      await _loadGenericPage(reset: reset);
      return;
    }
    if (reset) {
      final generation = ++_generation;
      setState(() {
        _loading = true;
        _persons = [];
        _hasMore = true;
      });
      _rawOffset = 0;
      final raw = await _db.listPersons(
        sex: _sex,
        sort: _sort,
        query: _query,
        tag: _tagFilter.tagValue,
        category: _category,
        offset: 0,
        limit: _pageSize,
      );
      _rawOffset = raw.length;
      final persons = await _applySiteFilter(raw);
      if (!mounted || generation != _generation) return;
      setState(() {
        _persons = persons;
        _hasMore = raw.length >= _pageSize;
        _loading = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final raw = await _db.listPersons(
      sex: _sex,
      sort: _sort,
      query: _query,
      tag: _tagFilter.tagValue,
      category: _category,
      offset: _rawOffset,
      limit: _pageSize,
    );
    _rawOffset += raw.length;
    final persons = await _applySiteFilter(raw);
    if (!mounted || generation != _generation) return;
    setState(() {
      _persons = [..._persons, ...persons];
      _hasMore = raw.length >= _pageSize;
      _loadingMore = false;
    });
  }

  /// 通用模式翻页：作品表按 rowid 顺序翻页，搜索走标题/番号 LIKE。
  Future<void> _loadGenericPage({bool reset = false}) async {
    final reader = _genericReader;
    if (reader == null) return;
    if (reset) {
      final generation = ++_generation;
      setState(() {
        _loading = true;
        _genericWorks = [];
        _hasMore = true;
      });
      final total = await reader.countWorks(query: _query);
      final works = await reader.works(
        offset: 0,
        limit: _pageSize,
        query: _query,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _genericWorks = works;
        _genericTotal = total;
        _hasMore = works.length >= _pageSize;
        _loading = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final works = await reader.works(
      offset: _genericWorks.length,
      limit: _pageSize,
      query: _query,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _genericWorks = [..._genericWorks, ...works];
      _hasMore = works.length >= _pageSize;
      _loadingMore = false;
    });
  }

  /// 通用作品点按直播：转成兜底条目走现有播放链（站走 chaoliu
  /// 原始地址直通，parse=0），地址是播之前刚从当前库里取出来的，
  /// 不播缓存的旧地址；没有可播地址就提示，不硬播。
  Future<void> _playGenericWork(GenericDbWork work) async {
    final entry = work.toJsonEntry();
    if (!entry.playable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条没有可播地址')));
      return;
    }
    await pushPlayer<void>(
      context,
      detail: entry.toDramaDetail(),
      initialIndex: 0,
      repository: widget.repository,
      store: widget.store,
    );
    if (mounted) setState(() {});
  }

  /// 打开“数据库字段”页：映射改了就按新映射重读列表。
  Future<void> _openFieldsPage() async {
    final reader = _genericReader;
    if (reader == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ActressDbFieldsPage(reader: reader),
      ),
    );
    if (changed != true || !mounted) return;
    await _loadPage(reset: true);
  }

  void _openPerson(ActressPerson person) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ActressDetailPage(
          localId: person.localId,
          repository: widget.repository,
          store: widget.store,
          database: _db,
          siteFilter: _source,
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

  /// 影视库入口（2026-11-20）：按影片浏览绑定库里的全部作品。
  void _openFilmLibrary() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FilmLibraryPage(
          database: _db,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final overview = _overview;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title:
            _genericMode
                ? const Text('演员库 · 外来数据库')
                : widget.showTitle
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
        actions: [
          if (!_genericMode)
            PopupMenuButton<ActressSiteFilter>(
            key: const ValueKey('actress-site-filter'),
            tooltip: '站点筛选',
            initialValue: _source,
            onSelected: _setSiteFilter,
            itemBuilder: (_) => [
              for (final filter in _siteFilterOptions())
                PopupMenuItem(
                  value: filter,
                  child: Text(filter.label),
                ),
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
          if (!_genericMode)
            IconButton(
              key: const ValueKey('open-actress-ranking'),
              tooltip: '演员排行榜',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.emoji_events_outlined),
              onPressed: _openRanking,
            ),
          IconButton(
            key: const ValueKey('refresh-actress-library'),
            // 2026-11-20 热换库：通用模式下刷新按钮就是手动重载数据库。
            tooltip: _genericMode ? '重新加载数据库' : '刷新同步',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh_rounded),
            onPressed:
                _genericMode
                    ? _manualReloadDb
                    : _progress.running
                    ? null
                    : () => _runSync(),
          ),
          // 2026-11-20 影视库：女优库模块新增的影片浏览入口（两模式都有）。
          IconButton(
            key: const ValueKey('open-film-library'),
            tooltip: '影视库',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.movie_outlined),
            onPressed: _openFilmLibrary,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSyncBanner(colors),
          _buildStackingBanner(colors),
          _buildCrawlBanner(colors),
          _buildMytvBindRow(colors),
          _buildGenericModeRow(colors),
          _buildMirrorBanner(colors),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
            child: TextField(
              key: const ValueKey('actress-search'),
              controller: _searchController,
              decoration: InputDecoration(
                hintText:
                    _genericMode
                        ? '搜标题或番号'
                        : '搜名字或番号：中文 / 日文 / SSIS-123 都行',
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
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _sex == ActressSexFilter.all,
                  onSelected: (_) => _setSex(ActressSexFilter.all),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('女优'),
                  selected: _sex == ActressSexFilter.female,
                  onSelected: (_) => _setSex(ActressSexFilter.female),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('男优'),
                  selected: _sex == ActressSexFilter.male,
                  onSelected: (_) => _setSex(ActressSexFilter.male),
                ),
                const Spacer(),
                PopupMenuButton<ActressSort>(
                  key: const ValueKey('actress-sort-menu'),
                  tooltip: '排序',
                  initialValue: _sort,
                  onSelected: (sort) {
                    if (sort == _sort) return;
                    setState(() => _sort = sort);
                    unawaited(_loadPage(reset: true));
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
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
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
          // 数据库里的分类（video_category 主分类）：横向滑，点分类
          // 只留该分类里有作品的人；无分类时不占地方。
          if (_dbCategories.isNotEmpty && !_genericMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ChoiceChip(
                      key: const ValueKey('actress-category-all'),
                      label: const Text('全部'),
                      selected: _category.isEmpty,
                      onSelected: (_) => _setCategory(''),
                    ),
                    const SizedBox(width: 8),
                    for (final category in _dbCategories) ...[
                      ChoiceChip(
                        key: ValueKey('actress-category-${category.$1}'),
                        label: Text('${category.$1}（${category.$2}）'),
                        selected: _category == category.$1,
                        onSelected: (_) => _setCategory(category.$1),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
          Expanded(child: _buildList(colors)),
        ],
      ),
    );
  }

  /// 读数据库里的分类（video_category 主分类 + 作品数）：影视库
  /// 没接上、没分类时返回空，这行不显示；读失败也不崩、不影响列表。
  Future<void> _loadDbCategories() async {
    final provider = _fallback.filmDb;
    if (provider is! FilmLibraryService) return;
    try {
      final categories = await provider.categories();
      if (!mounted) return;
      setState(() => _dbCategories = categories);
    } catch (_) {
      // 读不到分类就不显示这行，不影响列表。
    }
  }

  void _setCategory(String category) {
    if (category == _category) return;
    setState(() => _category = category);
    unawaited(_loadPage(reset: true));
  }

  void _setSex(ActressSexFilter sex) {
    if (sex == _sex) return;
    setState(() => _sex = sex);
    unawaited(_loadPage(reset: true));
  }

  void _setTagFilter(ActressTagFilter filter) {
    if (filter == _tagFilter) return;
    setState(() => _tagFilter = filter);
    unawaited(_loadPage(reset: true));
  }

  /// 手机现爬横幅：跑着时显示分类/页码与取消；失败/缺口时显示原因；
  /// 跑完显示条数与已补流数。无现爬时不显示。
  Widget _buildCrawlBanner(ColorScheme colors) {
    final crawl = _crawlProgress;
    if (!crawl.running && crawl.error.isEmpty && !crawl.done) {
      return const SizedBox.shrink();
    }
    const bannerPadding = EdgeInsetsDirectional.only(
      start: 16,
      top: 2,
      end: 4,
      bottom: 2,
    );
    if (crawl.running) {
      return MaterialBanner(
        key: const ValueKey('actress-crawl-banner'),
        backgroundColor: colors.surfaceContainerHigh,
        padding: bannerPadding,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(crawl.label)),
              ],
            ),
            // 入库增长看得见（2026-11-20 用户令）：只显示“第几页 ·
            // 多少条”不知道进没进库，库里作品总数与本轮新增摆出来。
            Text(
              _worksGrowthText(),
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('cancel-actress-crawl'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _crawl.cancel,
            child: const Text('取消'),
          ),
        ],
      );
    }
    return MaterialBanner(
      key: const ValueKey('actress-crawl-banner'),
      backgroundColor: colors.surfaceContainerHigh,
      padding: bannerPadding,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(crawl.label),
          Text(
            _worksGrowthText(),
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        // 跑完才能导出合并 JSON：随包 + 本地全部行合并后的全文，
        // 拷进树里内置文件，下次打包带走。
        if (crawl.done)
          TextButton(
            key: const ValueKey('export-actress-merged-json'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _exportingJson ? null : _exportMergedJson,
            child: const Text('导出合并 JSON'),
          ),
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () {
            setState(
              () => _crawlProgress = const ActressSiteCrawlProgress(),
            );
          },
          child: const Text('知道了'),
        ),
      ],
    );
  }

  /// 2026-11-20 MYTV 绑定：绑定路径行（用户一眼看到库落在哪）。
  /// 已绑定：显示 `数据库：MYTV/db/女优库应用.db`，迁移成功时第二行
  /// 显示迁移行数。没绑定：显示内部存储落点；没权限时给“去设置
  /// 授权”与“重新绑定”两个按钮，用户点了“继续用内部存储”后
  /// 本页内隐藏（绑定失败/降级时女优库照常能用，绝不挡路）。
  Widget _buildMytvBindRow(ColorScheme colors) {
    final bind = _mytvBind;
    if (bind == null || _mytvRowDismissed) {
      return const SizedBox.shrink();
    }
    final noteLines = <String>[];
    if (bind.bound && bind.migrated) {
      noteLines.add(
        '老数据已迁移：${bind.migratedPersons} 人 / ${bind.migratedWorks} 部（旧库留着当备份）',
      );
    }
    if (!bind.bound && bind.note != null) {
      noteLines.add(bind.note!);
    }
    // 2026-11-20 热换库：最近一次重读失败的原因（留旧库继续用）。
    if (_mytvDbError != null) {
      noteLines.add('数据库重读失败：$_mytvDbError（仍用旧库）');
    }
    // 2026-11-20 用户令“全部使用数据库兜底”：开库时 MYTV 库
    // 损坏回退内置库的原因。
    if (_mytvOpenNote != null) {
      noteLines.add(_mytvOpenNote!);
    }
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.folder_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '数据库：${bind.displayPath}',
                  style: const TextStyle(fontSize: 12),
                ),
                for (final line in noteLines)
                  Text(
                    line,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          // 2026-11-20 热换库：手动“重新加载数据库”入口（两种模式都有）。
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _manualReloadDb,
            child: const Text('重新加载数据库'),
          ),
          if (bind.needsPermission)
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _requestMytvPermission,
              child: const Text('去设置授权'),
            ),
          if (!bind.bound)
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _rebindMytv,
              child: const Text('重新绑定'),
            ),
          if (!bind.bound)
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _mytvRowDismissed = true),
              child: const Text('继续用内部存储'),
            ),
        ],
      ),
    );
  }

  /// 2026-11-20 通用读库：外来数据库模式行（表名 + 条数 + 字段入口）。
  /// 数据库镜像横幅（2026-11-20 用户令）：追加进行中显示
  /// “正在追加数据库…已追加 N / 共 M 条”，失败显示原因（已有
  /// 数据不受影响）；跑完/没文件时不显示。
  Widget _buildMirrorBanner(ColorScheme colors) {
    if (!_mirrorRunning && _mirrorError == null) {
      return const SizedBox.shrink();
    }
    final text = _mirrorRunning
        ? '正在追加数据库 $_mirrorFile…已追加 $_mirrorAppended'
            ' / 共 ${_mirrorTotal > 0 ? _mirrorTotal : '…'} 条'
        : '追加数据库失败：$_mirrorError（已有数据不受影响）';
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (_mirrorRunning)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.warning_amber_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildGenericModeRow(ColorScheme colors) {
    if (!_genericMode) return const SizedBox.shrink();
    final reader = _genericReader;
    final table = reader?.schema.worksTable?.table ?? '';
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.storage_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '外来数据库 · 表 $table · $_genericTotal 条',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _openFieldsPage,
            child: const Text('数据库字段'),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncBanner(ColorScheme colors) {
    final overview = _overview;
    // 2026-11-20 MYTV 绑定：空库自动生成进行中（种子灌入或同步
    // 中）：种子灌入时显示已灌入条数，同步跑起来后走下面的
    // _progress.running 分支（同一时间只会有一个在跑）。
    if (_mytvGenerating) {
      // 生成中横幅不用 MaterialBanner：它要求 actions 非空，
      // 这里没有可点的操作，用普通容器（2026-11-20 修：空 actions
      // 会在 build 时断言报错）。
      return Container(
        width: double.infinity,
        color: colors.surfaceContainerHigh,
        padding: const EdgeInsetsDirectional.only(
          start: 16,
          top: 2,
          end: 4,
          bottom: 2,
        ),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _seededCount > 0
                    ? '正在生成女优库…已灌入 $_seededCount 条'
                    : '正在生成女优库…',
              ),
            ),
          ],
        ),
      );
    }
    if (_progress.running) {
      // 爬虫腿的真实进度（detail）优先显示；没有时回落到
      // done/total 或页数。失败数摆出来（旧版只显示 done/total，
      // 失败在涨也看不见，看起来像卡住——12:45 截图 4612/5403
      // 冻住的另一半原因）；入库增长第二行显示。
      final detail = _progress.detail.isNotEmpty
          ? _progress.detail
          : _progress.total > 0
              ? '${_progress.done}/${_progress.total}'
              : '第 ${_progress.done} 页';
      final failed = _progress.failed > 0
          ? ' · 失败 ${_progress.failed}'
          : '';
      return MaterialBanner(
        backgroundColor: colors.surfaceContainerHigh,
        padding: const EdgeInsetsDirectional.only(start: 16, top: 2, end: 4, bottom: 2),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${_progress.phaseLabel}（${_progress.sourceIndex}/${_progress.sourceCount}）· $detail$failed',
                  ),
                ),
              ],
            ),
            Text(
              _worksGrowthText(),
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _sync.cancel,
            child: const Text('取消'),
          ),
        ],
      );
    }
    if (overview == null) return const SizedBox.shrink();
    if (overview.persons == 0) {
      return MaterialBanner(
        backgroundColor: colors.surfaceContainerHigh,
        padding: const EdgeInsetsDirectional.only(start: 16, top: 2, end: 4, bottom: 2),
        content: const Text('还没有数据，点刷新开始同步演员库。'),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _runSync(),
            child: const Text('开始同步'),
          ),
        ],
      );
    }
    final unfinished = !overview.allDone;
    if (_lastSyncFailed || unfinished) {
      return MaterialBanner(
        backgroundColor: colors.surfaceContainerHigh,
        padding: const EdgeInsetsDirectional.only(start: 16, top: 2, end: 4, bottom: 2),
        content: Text(
          '已同步 ${overview.persons} 人 · ${overview.works} 部作品，'
          '部分内容还没同步完，点刷新继续补。',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _runSync(),
            child: const Text('继续同步'),
          ),
        ],
      );
    }
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text('已同步 ${overview.persons} 人 · ${overview.works} 部作品。'),
    );
  }

  /// 全站叠加横幅：与同步横幅同一样式，只显示人数与进度，不显示
  /// 任何来源信息。库空时不显示（无可叠加）；叠加跑着时显示进度
  /// 与取消；跑完一轮显示断点进度与继续按钮；全库跑完显示完成态。
  Widget _buildStackingBanner(ColorScheme colors) {
    final overview = _overview;
    if (overview == null || overview.persons == 0) {
      return const SizedBox.shrink();
    }
    final stacking = _stackingProgress;
    const bannerPadding = EdgeInsetsDirectional.only(
      start: 16,
      top: 2,
      end: 4,
      bottom: 2,
    );
    ButtonStyle compactButton() => TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    if (stacking.running) {
      return MaterialBanner(
        key: const ValueKey('actress-stacking-banner'),
        backgroundColor: colors.surfaceContainerHigh,
        padding: bannerPadding,
        content: Row(
          children: [
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '全站叠加中 · 已叠加 ${stacking.done}/${stacking.total} 人'
                ' · 本轮新增 ${stacking.worksAdded} 部作品',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('cancel-actress-stacking'),
            style: compactButton(),
            onPressed: _stacking.cancel,
            child: const Text('取消'),
          ),
        ],
      );
    }
    if (stacking.finished) {
      return Container(
        key: const ValueKey('actress-stacking-banner'),
        width: double.infinity,
        color: colors.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          '全站叠加已完成：${stacking.done} 人作品已按番号叠加。',
        ),
      );
    }
    final started = stacking.done > 0;
    return MaterialBanner(
      key: const ValueKey('actress-stacking-banner'),
      backgroundColor: colors.surfaceContainerHigh,
      padding: bannerPadding,
      content: Text(
        started
            ? '全站叠加：已叠加 ${stacking.done}/${stacking.total} 人，'
                  '继续按番号补全各站作品。'
            : '全站叠加：按番号把各站作品叠加到每个人名下，断点续跑，'
                  '不用一次跑完。',
      ),
      actions: [
        TextButton(
          key: const ValueKey('start-actress-stacking'),
          style: compactButton(),
          onPressed: _progress.running ? null : () => _runStacking(),
          child: Text(started ? '继续叠加' : '开始叠加'),
        ),
      ],
    );
  }

  /// 人物宫格布局：普通列表与姓名分组共用同一套格子尺寸。
  static const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 3,
    mainAxisSpacing: 16,
    crossAxisSpacing: 8,
    childAspectRatio: 0.88,
  );

  Widget _buildList(ColorScheme colors) {
    // 2026-11-20 通用读库：外来库是作品列表，不是人物宫格。
    if (_genericMode) return _buildGenericList(colors);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_persons.isEmpty) {
      // 空态分流：搜不到就是搜不到；选了站、该站没匹配上的人就说
      // 该站没有；确实一个人才是“暂无人物”——三种情况不混着说。
      final emptyText = _query.isNotEmpty
          ? '没有找到“$_query”'
          : _source != ActressSiteFilter.all
              ? '该站暂无匹配人物'
              : '暂无人物';
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

  /// 通用模式作品列表：封面 + 标题 + 副标题（日期/番号/分类），
  /// 点卡直接播（parse=0），没有详情页。
  Widget _buildGenericList(ColorScheme colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_genericWorks.isEmpty) {
      final emptyText =
          _query.isNotEmpty ? '没有找到“$_query”' : '这个库里没有作品';
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('actress-generic-list'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: _genericWorks.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _genericWorks.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final work = _genericWorks[index];
        return _GenericWorkRow(
          key: ValueKey('generic-work-${work.id ?? work.title}'),
          work: work,
          onTap: () => _playGenericWork(work),
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
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
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
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            '约 ${person.displayWorks} 部',
            maxLines: 1,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 通用模式作品行：封面缩略图 + 标题 + 副标题（日期/番号/分类），
/// 点按直接播；没有可播地址的行不显示播放钮。
class _GenericWorkRow extends StatelessWidget {
  const _GenericWorkRow({super.key, required this.work, required this.onTap});

  final GenericDbWork work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subtitle = [
      if (work.displaySubtitle.isNotEmpty) work.displaySubtitle,
      if (work.actress.isNotEmpty) work.actress,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 72,
              height: 96,
              child:
                  work.coverUrl.isEmpty
                      ? Container(
                        color: colors.surfaceContainerHighest,
                        child: const Icon(Icons.movie_outlined),
                      )
                      : Image.network(
                        work.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder:
                            (_, _, _) => Container(
                              color: colors.surfaceContainerHighest,
                              child: const Icon(Icons.movie_outlined),
                            ),
                      ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      work.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (work.playable)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Icon(Icons.play_circle_outline),
              ),
          ],
        ),
      ),
    );
  }
}
