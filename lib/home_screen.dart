import 'dart:async';

import 'app_page_route.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_layout.dart';
import 'back_history.dart';
import 'liquid_glass.dart';
import 'home_zone.dart';
import 'app_theme_config.dart';
import 'content_tier_filter.dart';
import 'neon/neon_ui.dart';
import 'ui_style.dart';
import 'content_zone_binding.dart';
import 'content_zone_screen.dart';
import 'content_models.dart';
import 'miniapp/mini_app_home_page.dart';
import 'mine_page.dart';
import 'core_bridge.dart';
import 'catalog_filters.dart';
import 'center_feed_loader.dart';
import 'listen_read_page.dart';
import 'compact_chip.dart';
import 'tv_filter_bar.dart';
import 'catalog_browser.dart';
import 'catalog_sort.dart';
import 'category_levels.dart';
import 'left_category_layout.dart';
import 'catalog_sort_sheet.dart';
import 'cloud_drive/cloud_drive_screen.dart';
import 'cloud_drive/cloud_drive_stations.dart';
import 'multimedia_screen.dart';
import 'recommendations_screen.dart';
import 'rankings_screen.dart';
import 'detail_screen.dart';
import 'folder_catalog_screen.dart';
import 'global_search_page.dart';
import 'web_scrape_page.dart';
import 'fullscreen_feed_screen.dart';
import 'hongguo_drama_home.dart';
import 'import_file_store.dart';

import 'imported_site_record.dart';
import 'py_bridge.dart';
import 'vod_detail_route.dart';
import 'settings_screen.dart';
import 'saved_library.dart';
import 'home_carousel.dart';
import 'playback_launch_screen.dart';
import 'playback_queue.dart';
import 'local_store.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'zone_settings_screen.dart';
import 'vip_icon.dart';
import 'search_input.dart';
import 'source_picker_sheet.dart';
import 'sources_screen.dart';
import 'drama_actions.dart';
import 'library_updater.dart';
import 'live_repository.dart';
import 'live_screen.dart';
import 'live_store.dart';
import 'live_sources.dart';
import 'content_registry.dart';
import 'miniapp/mini_app_store.dart';
import 'miniapp/mini_app_manifest.dart';
import 'win7_desktop.dart';

bool shouldSilentRefreshOnRestore(DateTime? fetchedAt, DateTime now) {
  if (fetchedAt == null) return true;
  return now.difference(fetchedAt) >= const Duration(minutes: 5);
}

/// 全局路由观察器：首页订阅它感知“上方路由弹出、首页重新成为当前页”
/// （didPopNext），用于识别返回过渡中的重复投递。MaterialApp 需把它
/// 放进 navigatorObservers；没放时首页收不到事件，退化为无保护的旧行为。
final RouteObserver<ModalRoute<dynamic>> homeRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

/// Win7 窗口描述：窗口位一种区，只记“开的是哪个区的哪一站”。
/// 直播窗口的界面实例 key 固定，换站靠 nonce 递进走 LiveScreen
/// 自身的 didUpdateWidget 切站（实例不重建）；听读窗口的 key 取
/// binding 当前选站，换站即 key 变、实例重建。片库/短剧窗口的
/// 描述只作恢复时的换站依据，界面状态在首页自身。
class _Win7Window {
  const _Win7Window({
    required this.kind,
    this.sourceId,
    this.allSources = false,
    this.nonce = 0,
  });

  final Win7WindowKind kind;
  final String? sourceId;
  final bool allSources;

  /// 换站递进号：只在显式换站（开始菜单点站）时 +1，桌面图标 /
  /// 任务栏切前台不递进，窗口内手动换站不受干扰。
  final int nonce;

  _Win7Window copyWith({String? sourceId, bool? allSources, int? nonce}) =>
      _Win7Window(
        kind: kind,
        sourceId: sourceId ?? this.sourceId,
        allSources: allSources ?? this.allSources,
        nonce: nonce ?? this.nonce,
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  static const _recommendationCategory = 'app:recommendations';
  // 返回保护期：上方路由弹出后 400ms 内到达的返回，视为同一手势的
  // 重复投递，不吞区历史（播放页弹出过渡 220ms，留足余量；人有意
  // 识的第二次按压一般在 400ms 之后，不受影响）。
  static const _returnGrace = Duration(milliseconds: 400);
  bool _justReturned = false;
  Timer? _returnGraceTimer;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool _resetScrollOnNextLoad = false;
  final _filtersKey = GlobalKey<RemoteRowState>();
  final _gridKey = GlobalKey<RemoteGridState>();
  final _navKey = GlobalKey<RemoteListState>();
  Timer? _debounce;

  /// 可取消的补拉等待：页面销毁时取消计时器，测试的假时钟里不留挂起的 Timer。
  Timer? _retryTimer;
  Completer<void>? _retryCompleter;

  Future<void> _cancellableRetryDelay() async {
    final completer = Completer<void>();
    _retryCompleter = completer;
    _retryTimer = Timer(const Duration(milliseconds: 1500), () {
      _retryTimer = null;
      _retryCompleter = null;
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    if (_retryCompleter == completer) {
      _retryTimer = null;
      _retryCompleter = null;
    }
  }

  void _cancelRetryDelay() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final completer = _retryCompleter;
    _retryCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
  late SourceSite _source;
  bool _allSources = false;
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  HomeZone _zone = HomeZone.library;

  /// 听读标签上次停的子区：点“听读”回到上次听/看的子区，默认听书。
  HomeZone _lastListenReadZone = HomeZone.audio;
  final _zoneHistory = BackHistory<HomeZone>();

  // ---- Win7 窗口管理器（仅 Win7 主题手机端生效）-----------------
  // 一个窗口位一种区：同种区只开一个窗口，再点只是切到前台。
  // 最小化的窗口留在树里（Offstage 包着），State 不销毁、状态保留；
  // 关闭的窗口从树里摘掉，State 销毁、重开即全新。片库/短剧两窗
  // 共用首页自身的目录状态（_source/_items 等），最小化时只记描述
  // （站点 id），恢复时按描述换回该站、内容重拉，分类选择沿用
  // _categorySelections 的既有持久化；其余窗口的界面状态完整保留。
  final Map<Win7WindowKind, _Win7Window> _win7Windows = {};
  Win7WindowKind? _win7Foreground;
  bool _win7MenuOpen = false;

  /// 开始菜单“小程序”组用的已安装清单缓存：菜单打开时刷新。
  List<MiniAppManifest> _win7MiniApps = [];

  /// 底部 Tab 点了“我的”后为真：短剧首页分支据此把短剧首页内层
  /// 页签驱到“我的”页；离开片库区或点其它 Tab 时清掉。
  bool _mineRequested = false;

  /// 底部 Tab 点了“多媒体”后为真：短剧首页分支据此把内层页签驱
  /// 到多媒体页，通用分支改渲染多媒体屏；离开片库区或点其它
  /// Tab 时清掉（与 _mineRequested 同一口径）。
  bool _multimediaRequested = false;

  /// 底部 Tab 点了“小程序”后为真：短剧首页分支据此把内层页签驱
  /// 到小程序页，通用分支改渲染小程序首页；离开片库区或点其它
  /// Tab 时清掉（与 _mineRequested 同一口径）。
  bool _miniAppRequested = false;

  /// 戏剧首页钉住标记：频道/戏剧首页内切站时为真，换站后仍渲染
  /// 戏剧首页分支（分组 id 随站源变化，单凭分组判断会跳到通用
  /// 分支）；离开片库区时清掉，切回片库后按分组重新判断。
  bool _dramaHomePinned = false;
  final _lastZoneSource = <String, String>{};
  late final ContentZoneBinding _contentBinding;
  List<Drama>? _visibleCache;
  String _visibleCacheKey = '';
  List<String>? _level2TagsCache;
  String _level2TagsCacheKey = '';
  List<String>? _level3TagsCache;
  String _level3TagsCacheKey = '';
  final _drillStack = <({String folderId, String name, String sourceId})>[];
  List<CatalogTag> _catalogTags = const [];
  List<CatalogFilterGroup> _catalogFilters = const [];
  final _selectedFilters = <String, String>{};
  String? _tagLevel2;
  String? _tagLevel3;
  String _submittedQuery = '';
  final _categorySelections = <String, String>{};
  late final CatalogBrowser _browser;
  bool _searchVisible = false;
  // 首装判定：从未成功拉到过视频时，首次打开直接现抓，不先读空缓存。
  bool _firstLaunch = false;
  // 勾选后并发搜索所有可见站源并归一去重，取消勾选只搜索当前站源。
  bool _crossSourceSearch = false;
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;
  late final LibraryUpdater _updater;
  late final LiveRepository _liveRepository = LiveRepository();
  late final LiveStore _liveStore = LiveStore(
    widget.store.preferences,
    widget.store.profile.id,
  )..load();

  /// 订阅双入口递进来的直播源：消费待办请求时记下并递给 LiveScreen，
  /// nonce 每递一次加一，已挂载的直播页靠它识别新请求。
  String _liveEntrySourceId = '';
  int _liveEntryNonce = 0;
  final _changedSources = <String>{};
  final _selectedDramas = <String, Drama>{};
  Timer? _cacheRefreshTimer;
  bool _refreshingUpdatedCache = false;
  bool _selectionMode = false;
  bool _showRecommendations = false;
  bool _catalogLoadScheduled = false;
  // 首屏自动补拉：站源晚于页面就绪时，等它就绪后自动请求一次，用户不用手动下拉。
  bool _autoLoadScheduled = false;
  bool _autoLoadedOnce = false;
  bool _openingPlayback = false;

  bool get _isCatalogZone => _zone == HomeZone.library;

  /// 片库目录顶栏（站源条 + 工具胶囊）是否显示：多媒体/小程序/
  /// 我的页虽在片库区内，但各有自己的顶栏，片库顶栏元素不该
  /// 出现在它们上面。
  bool get _showCatalogHeader =>
      _isCatalogZone &&
      !_multimediaRequested &&
      !_miniAppRequested &&
      !_mineRequested;

  String get _zoneTitle => switch (_zone) {
    HomeZone.library => '片库',
    HomeZone.live => '直播',
    // 听书/阅读已并为“听读”一个标签，顶栏标题同名，子区在页内切换。
    HomeZone.audio => '听读',
    HomeZone.novel => '听读',
  };

  /// 片库区容纳全部视频站源（短剧站与点播站），切站决定显示哪站内容，
  /// 不再按短剧/点播两个区过滤站源。
  List<SourceSite> get _librarySources => List.of(widget.store.visibleSources);

  List<SourceGroup> get _sourceGroups {
    // 首页只显示「源显示列表」中开启的站源，被隐藏的站源不出现在分组里。
    final visible = _librarySources;
    final groups = SourceGroup.fromSources(visible);
    return [
      if (groups.length > 1) SourceGroup('all', '全部站源', visible),
      ...groups,
    ];
  }

  SourceGroup get _group =>
      _sourceGroups
          .where((group) => group.id == (_allSources ? 'all' : _source.groupId))
          .firstOrNull ??
      (() {
        final visible = _librarySources;
        final site = visible.any((s) => s.id == _source.id)
            ? _source
            : (visible.firstOrNull ?? _source);
        return SourceGroup(site.groupId, site.groupName, [site]);
      })();

  /// 下钻时目录只请求文件夹所属的单个站源，层级不限。
  SourceGroup get _effectiveGroup {
    if (_drillStack.isEmpty) return _group;
    final site = SourceSite.byId(_drillStack.last.sourceId);
    return SourceGroup(site.groupId, site.groupName, [site]);
  }

  String get _effectiveCategory =>
      _drillStack.isEmpty ? _category : _drillStack.last.folderId;
  bool get _onlineSearch => _group.sources.any((source) => source.onlineSearch);

  /// 首页轮播只出现在单站源的目录首页（默认分类、非搜索/推荐/
  /// 下钻/多选态）；数据取当前 _visible 头部，天然随站源切换。
  bool get _showCarouselStrip =>
      !_allSources &&
      !_searchVisible &&
      !_showRecommendations &&
      _drillStack.isEmpty &&
      _category.isEmpty &&
      !_selectionMode;
  // 跨源聚合搜索打的是站源管理里勾选显示的可见源，被隐藏的源不参与。
  List<String> get _visibleSourceIds => [
    for (final source in _librarySources) source.id,
  ];
  // 勾选跨源后，即便当前分组本身不支持在线搜索，也按全部可见源发起在线搜索。
  // 自定义源在 Dart 侧 onlineSearch 恒为 false，但 Go 侧 searchAcross 能识别
  // custom:* 源并并发搜索，不支持搜索的源会被静默跳过；是否真有结果由 Go 判定，
  // 故这里只看「有没有可见源」，不再用 source.onlineSearch 过滤。
  bool get _canSearchOnline =>
      _onlineSearch || (_crossSourceSearch && _visibleSourceIds.isNotEmpty);
  bool get _searchSuggestions =>
      _group.sources.any((source) => source.searchSuggestions);
  String get _searchHint {
    final online = _group.sources
        .where((source) => source.onlineSearch)
        .toList();
    if (online.isEmpty) {
      return '筛选本机已更新剧库';
    }
    final names = online.map((source) => source.name).join('、');
    return online.length == _group.sources.length
        ? '搜索$names'
        : '搜索$names及本机剧库';
  }

  String _categoryKey(String groupId) => '$_zone:$groupId';

  String get _category => _categorySelections[_categoryKey(_group.id)] ?? '';
  List<CatalogCategory> get _categories => _browser.categories(_group);
  String get _displayCategory {
    // 内容档锁定时：命中分类即为显示分类；命中不到显示空（由空态接管）。
    if (_contentTier == ContentTier.manhua ||
        _contentTier == ContentTier.liveAction) {
      return _tierCategoryId ?? '';
    }
    return _showRecommendations ? _recommendationCategory : _category;
  }

  List<CatalogCategory> get _displayCategories {
    // 内容档锁定时只显示命中的那一个分类；命中不到显示空集合。
    if (_contentTier == ContentTier.manhua ||
        _contentTier == ContentTier.liveAction) {
      return tierCategories(_contentTier, _categories);
    }
    return [
      CatalogCategory.all,
      if (_group.id == 'hongguo')
        const CatalogCategory(_recommendationCategory, '推荐'),
      ..._categories.where((entry) => entry.id.isNotEmpty),
    ];
  }

  Future<void> _loadCategories({
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final group = _group;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    final error = await _browser.loadCategories(
      group,
      force: force,
      cacheOnly: cacheOnly,
      onMenu: () {
        if (mounted) setState(() {});
      },
    );
    if (!mounted ||
        generation != _categoryGeneration ||
        group.id != _group.id) {
      return;
    }
    setState(() {
      _categoriesLoading = false;
      _categoriesError = error;
    });
    if (!_showRecommendations &&
        _drillStack.isEmpty &&
        _category.isNotEmpty &&
        !_categories.any((entry) => entry.id == _category)) {
      _changeCategory('');
    }
  }

  Future<void> _refreshCatalog() async {
    // 实时口径：手动刷新（下拉/按钮）直接强制现抓当前分类与当前页，
    // 对全部站源类型（含 py/jar 导入站）一致生效；sourceJob 只保留在
    // 站源管理页作后台建库/计数/资料补齐，不再充当目录刷新路径，
    // 也不再因 job 忙碌而把刷新变成无操作。
    await _loadCategories(force: true);
    if (mounted) await _load(force: true);
  }

  /// 内容档锁定的分类在本站不存在时的诚实空态：只说明事实，
  /// 动作是真实的——切回全部内容档（写回当前主题的显示方案）。
  Widget _tierEmptyPanel() => StatusPanel(
    title: '暂无${_contentTier.label}',
    message: '当前站点没有「${_contentTier.label}」分类，切回全部内容或换个站点。',
    action: '切回全部内容',
    onRetry: () => saveUserChange(
      context,
      () => widget.store.setDisplayScheme(
        widget.store.appTheme,
        widget.store
            .displayScheme(widget.store.appTheme)
            .copyWith(contentTier: ContentTier.all),
      ),
    ),
  );

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  void _catalogUpdated(String source) {
    if (!mounted) return;
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_reloadUpdatedCache());
    });
  }

  Future<void> _reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    final epoch = widget.store.profileEpoch;
    try {
      while (mounted &&
          _changedSources.isNotEmpty &&
          epoch == widget.store.profileEpoch) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!widget.store.allowsSource(source)) continue;
          try {
            final cached = await widget.repository.cached(source);
            for (final drama in cached.items) {
              if (widget.store.allowsSource(drama.source)) {
                updates[drama.id] = drama;
              }
            }
          } catch (error) {
            if (mounted && epoch == widget.store.profileEpoch) {
              setState(() => _error = '更新后读取缓存失败：$error');
            }
          }
        }
        if (!mounted || epoch != widget.store.profileEpoch) return;
        _browser.updateDramas(updates.values);
        setState(() {
          _items = [
            for (final item in _items)
              updates[item.id] == null ? item : item.merge(updates[item.id]!),
          ];
          for (final id in _selectedDramas.keys.toList()) {
            if (updates[id] != null) {
              _selectedDramas[id] = _selectedDramas[id]!.merge(updates[id]!);
            }
          }
        });
        await saveUserChange(
          context,
          () => widget.store.refreshDramas(updates.values),
        );
        if (!mounted || epoch != widget.store.profileEpoch) return;
        if (_group.sources.any((source) => sources.contains(source.id))) {
          await _loadCategories(cacheOnly: true);
          if (mounted &&
              !_loading &&
              !_loadingMore &&
              (!_onlineSearch || _search.text.trim().isEmpty)) {
            await _load(cacheOnly: true);
          }
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  void _changeGroup(SourceGroup group) {
    if (_group.id != group.id) {
      _changeSource(group.sources.first, allSources: group.id == 'all');
    }
  }

  static const _allSourcesEntryId = '__all__';

  bool get _canSwitchSource =>
      _librarySources.length + (_sourceGroups.length > 1 ? 1 : 0) > 1;

  List<SourcePickerGroup> _sourcePickerGroups() => [
    if (_sourceGroups.length > 1)
      const SourcePickerGroup(
        title: '',
        entries: [SourcePickerEntry(id: _allSourcesEntryId, name: '全部站源')],
      ),
    for (final group in SourceGroup.sectionGroups(_librarySources))
      SourcePickerGroup(
        title: group.name,
        entries: [
          for (final site in group.sources)
            SourcePickerEntry(
              id: site.id,
              name: site.name,
              deletable:
                  SourceSite.importedSites.containsKey(site.id) ||
                  site.origin == SourceSite.originBuiltin,
            ),
        ],
      ),
  ];

  String _sourcePickerSectionName() => '片库';

  Future<void> _pickSource({bool editMode = false}) async {
    final picked = await showSitePickerDialog(
      context,
      sectionName: _sourcePickerSectionName(),
      currentId: _allSources ? _allSourcesEntryId : _source.id,
      groups: _sourcePickerGroups(),
      initialEditMode: editMode,
      onDeleteSite: _deleteSourceEntry,
      repository: widget.repository,
    );
    if (picked == null || !mounted) return;
    _applySourcePick(picked);
  }

  Future<bool> _deleteSourceEntry(SourcePickerEntry entry) async {
    if (entry.id == _allSourcesEntryId) return false;
    if (_librarySources.length <= 1 &&
        _librarySources.any((site) => site.id == entry.id)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('至少保留一个站源')));
      return false;
    }
    final imported = widget.store.importedSiteRecords
        .where((record) => record.id == entry.id)
        .firstOrNull;
    if (imported != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除导入站'),
          content: Text('确定删除「${imported.name}」吗？导入的蜘蛛文件副本将一并删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return false;
      if (imported.type == ImportedSiteRecord.typePy) {
        unawaited(
          ImportFileStore.pathOf(
            imported.fileName,
          ).then((path) => PyBridge.dispose(path)),
        );
      }
      await ImportFileStore.delete(imported.fileName);
      await widget.store.syncImportedSites([
        for (final item in widget.store.importedSiteRecords)
          if (item.id != imported.id) item,
      ]);
      _afterSourceDeleted(entry.id);
      return true;
    }
    final site = _librarySources
        .where((site) => site.id == entry.id)
        .firstOrNull;
    if (site == null || site.origin != SourceSite.originBuiltin) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('隐藏内置站'),
        content: Text('「${site.name}」将从列表隐藏，可在内置站管理里恢复显示。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('隐藏'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    await widget.store.setSiteVisible(entry.id, false);
    _afterSourceDeleted(entry.id);
    return true;
  }

  void _afterSourceDeleted(String id) {
    if (!_allSources && _source.id == id && _librarySources.isNotEmpty) {
      _changeSource(_librarySources.first);
    } else if (mounted) {
      setState(() {});
    }
  }

  void _applySourcePick(String picked) {
    if (picked == _allSourcesEntryId) {
      _changeGroup(_sourceGroups.firstWhere((group) => group.id == 'all'));
      return;
    }
    final site = _librarySources.where((site) => site.id == picked).firstOrNull;
    if (site != null) _changeSource(site);
  }

  void _changeFilter(String groupKey, String optionId) {
    if (_showRecommendations) return;
    setState(() {
      if (optionId.isEmpty) {
        _selectedFilters.remove(groupKey);
      } else {
        _selectedFilters[groupKey] = optionId;
      }
    });
    _load();
  }

  void _changeCategory(String category) {
    // 点顶层分类即退出文件夹下钻（筛选行与下钻并行保留，随时可切回）。
    if (category == _recommendationCategory && _group.id == 'hongguo') {
      if (_showRecommendations) return;
      _pauseCatalog();
      setState(() {
        _showRecommendations = true;
        _selectionMode = false;
        _selectedDramas.clear();
        _search.clear();
        _searchVisible = false;
        _submittedQuery = '';
      });
      return;
    }
    final wasDrilled = _drillStack.isNotEmpty;
    if (_category == category && !_showRecommendations && !wasDrilled) return;
    _debounce?.cancel();
    setState(() {
      _drillStack.clear();
      _tagLevel2 = null;
      _tagLevel3 = null;
      _catalogFilters = const [];
      _selectedFilters.clear();
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _categorySelections[_categoryKey(_group.id)] = category;
      if (_onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  /// 文件夹卡下钻：以 folderId 作为 category 参数再次请求目录，
  /// 面包屑栈记录层级（不限深度），筛选行仍作用于顶层分类切换。
  void _drillInto(Drama item) {
    if (!item.isFolder || item.folderId.isEmpty) return;
    _pauseCatalog();
    setState(() {
      _tagLevel2 = null;
      _tagLevel3 = null;
      _drillStack.add((
        folderId: item.folderId,
        name: item.title,
        sourceId: item.source,
      ));
      _selectionMode = false;
      _selectedDramas.clear();
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  void _drillTo(int depth) {
    if (depth < 0) depth = 0;
    if (depth >= _drillStack.length) return;
    _pauseCatalog();
    setState(() {
      _tagLevel2 = null;
      _tagLevel3 = null;
      _drillStack.removeRange(depth, _drillStack.length);
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  /// 按标签下钻（tag: 前缀 folderId），与文件夹下钻共用同一栈。
  void _openTag(CatalogTag tag) {
    _drillInto(
      Drama(
        id: tag.folderId,
        source: _effectiveGroup.sources.first.id,
        title: tag.name,
        kind: 'folder',
        folderId: tag.folderId,
      ),
    );
  }

  void _swipeCategory(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 240) return;
    final categories = _displayCategories;
    final index = categories.indexWhere(
      (entry) => entry.id == _displayCategory,
    );
    final next = index + (velocity < 0 ? 1 : -1);
    if (next >= 0 && next < categories.length) {
      _changeCategory(categories[next].id);
    }
  }

  void _openWebScrape() {
    Navigator.of(
      context,
    ).push(appPageRoute(builder: (_) => const WebScrapePage()));
  }

  void _toggleSearch() {
    if (AppLayout.isTelevision(context)) {
      _televisionSearch();
      return;
    }
    if (_showRecommendations) _changeCategory('');
    final hadQuery = _search.text.isNotEmpty;
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) _search.clear();
    });
    if (!_searchVisible && hadQuery) _searchChanged('');
  }

  void _openRankings() {
    _pauseCatalog();
    Navigator.push<void>(
      context,
      appPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialGroup: _group.id,
          sourceIds: null,
        ),
      ),
    );
  }

  Future<void> _manageSources() async {
    _pauseCatalog();
    // 统一站点区（站源管理页）点“进站浏览”会带回站源 id：先把该站设为
    // 可见，再切到它所属的区并打开目录；不带回 id 时只做原有对账。
    final picked = await Navigator.push<String?>(
      context,
      appPageRoute(
        builder: (_) => SourcesScreen(
          repository: widget.repository,
          store: widget.store,
          initialSource: _source.id,
        ),
      ),
    );
    if (!mounted) return;
    if (picked != null) {
      final site = widget.store.sources
          .where((candidate) => candidate.id == picked)
          .firstOrNull;
      if (site != null) {
        await saveUserChange(
          context,
          () => widget.store.setSiteVisible(site.id, true),
        );
        if (!mounted) return;
        _setZone(HomeZone.library);
        _changeSource(site);
      }
    }
    // 站源显示列表可能变了：当前源被隐藏时落到第一个可见站源。
    final next = SourceSite.byId(widget.store.source);
    if (next.id != _source.id) {
      setState(() {
        _source = next;
        _allSources = false;
        _items = [];
        _hasMore = true;
        _error = null;
      });
      _resetScrollOnNextLoad = true;
      unawaited(
        saveUserChange(
          context,
          () => widget.store.setCatalogSource(next.id, allSources: false),
        ),
      );
    }
    await _loadCategories();
    if (mounted && (!_onlineSearch || _submittedQuery.isEmpty)) {
      await _load(useCache: true);
    }
  }

  Future<void> _televisionSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: _group.id == 'all'
            ? '搜索已开放站源'
            : _onlineSearch
            ? '搜索${_group.name}短剧'
            : '筛选当前已加载短剧',
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        suggestions: _searchSuggestions ? widget.repository.suggestions : null,
        crossSource: _crossSourceSearch,
        onCrossSourceChanged: _crossSourceSearch || _visibleSourceIds.isNotEmpty
            ? _changeCrossSource
            : null,
        crossSourceCount: _visibleSourceIds.length,
      ),
    );
    if (query != null && mounted) {
      _submitSearch(query);
    }
  }

  void _televisionBack() {
    if (_selectionMode) {
      _cancelSelection();
    } else if (_zone != HomeZone.library) {
      _applyZoneChange(HomeZone.library);
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onCatalogScroll);
    _contentBinding = ContentZoneBinding(
      readPersisted: (key) => widget.store.preferences.getString(key),
      writePersisted: (key, value) {
        unawaited(widget.store.preferences.setString(key, value));
      },
    );
    _source = SourceSite.byId(widget.store.source);
    _zone = HomeZone.library;
    _allSources = widget.store.catalogView.allSources;
    if (_librarySources.isNotEmpty) {
      final remembered = _rememberedForCurrentZone();
      if (remembered != null) {
        _source = remembered.site;
        _allSources = remembered.allSources;
      } else if (!_librarySources.any((site) => site.id == _source.id)) {
        _source = _librarySources.first;
        _allSources = false;
      }
    }
    _browser = CatalogBrowser(widget.repository);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _firstLaunch =
        widget.store.preferences.getBool('first_catalog_loaded') != true;
    if (_librarySources.isNotEmpty) {
      unawaited(_loadWithAutoRetry(useCache: !_firstLaunch));
      _loadCategories();
    } else {
      _loading = false;
    }
    unawaited(ensureDramaUiStyleLoaded());
  }

  @override
  void dispose() {
    _cancelRetryDelay();
    _returnGraceTimer?.cancel();
    homeRouteObserver.unsubscribe(this);
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _liveRepository.dispose();
    _liveStore.dispose();
    _cacheRefreshTimer?.cancel();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    _debounce?.cancel();
    _search.dispose();
    _scroll.removeListener(_onCatalogScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onCatalogScroll() {
    if (!mounted ||
        _showRecommendations ||
        !_hasMore ||
        _loading ||
        _loadingMore ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.5).clamp(320.0, 900.0);
    if (position.extentAfter > threshold || _catalogLoadScheduled) return;
    _catalogLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _catalogLoadScheduled = false;
      if (!mounted ||
          _showRecommendations ||
          !_hasMore ||
          _loading ||
          _loadingMore ||
          !_scroll.hasClients) {
        return;
      }
      unawaited(_load(more: true));
    });
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _browser.updateDrama(drama);
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  /// 页面重建时检查一次：目录区是空的、又不是在加载，就自动补一次请求。
  ///
  /// 装完第一次打开时站源经常比页面晚一步就绪（本地配置还在读、远程配置还在同步），
  /// 那时首屏拿不到源，页面会停在空目录上；等源就绪后靠这里自动补拉，
  /// 不用用户再手动下拉一次。
  void _scheduleAutoLoad() {
    if (_autoLoadScheduled || _autoLoadedOnce || !mounted) return;
    if (!_isCatalogZone) return;
    if (_items.isNotEmpty || _loading || _showRecommendations) return;
    if (_librarySources.isEmpty) return;
    _autoLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoLoadScheduled = false;
      if (!mounted || _loading || _loadingMore || _showRecommendations) return;
      if (_items.isNotEmpty || _librarySources.isEmpty) return;
      _autoLoadedOnce = true;
      unawaited(_loadWithAutoRetry(useCache: true));
    });
  }

  void _resetAutoLoad() {
    _autoLoadedOnce = false;
  }

  /// 首屏 / 切站时的自动加载。
  ///
  /// 只读缓存的话，装完第一次打开、缓存为空、或者内核刚起来第一次请求落空时，
  /// 列表会一直是空的，得用户手动下拉才出内容。这里补成：
  /// 缓存读完还是空 → 立刻拉一次线上；还空 → 隔 1.5 秒再补一次。
  /// 失败（_error 有值）也要补拉：刚装完第一次打开、内核刚起来、
  /// 网络还没就绪时首次请求经常直接报错，以前一见 _error 就停，
  /// 页面停在“暂时无法加载”上等用户手动点重试。补拉次数有上限
  /// （最多再补 2 次），不会无限刷；补拉期间用户自己触发的加载
  /// 优先，检测到正在加载就停。
  Future<void> _loadWithAutoRetry({bool useCache = false}) async {
    await (useCache ? _load(useCache: true) : _load(force: true));
    if (!mounted) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_loading || _loadingMore || _showRecommendations) return;
      if (_items.isNotEmpty) return;
      if (_librarySources.isEmpty) return;
      if (attempt > 0) {
        await _cancellableRetryDelay();
        if (!mounted ||
            _loading ||
            _loadingMore ||
            _showRecommendations ||
            _items.isNotEmpty) {
          return;
        }
      }
      await _load(force: true);
      if (!mounted) return;
    }
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
    bool silent = false,
  }) async {
    if (_showRecommendations) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final group = _effectiveGroup;
    final query = _canSearchOnline ? _search.text.trim() : '';
    setState(() {
      if (!silent) _error = null;
      if (query.isNotEmpty && !silent) {
        _categorySelections[_categoryKey(group.id)] = '';
      }
      if (more) {
        _loadingMore = true;
      } else {
        if (!silent) _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery && !silent) _items = [];
      }
    });
    void accept(CatalogPage result, {bool cached = false}) {
      if (!mounted || generation != _generation) return;
      if (_firstLaunch && !cached && result.items.isNotEmpty) {
        _firstLaunch = false;
        unawaited(
          widget.store.preferences.setBool('first_catalog_loaded', true),
        );
      }
      setState(() {
        _items = result.items;
        if (result.tags.isNotEmpty) _catalogTags = result.tags;
        if (!more) _catalogFilters = result.filters;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        _loading = silent ? false : (cached && !result.fresh);
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
      if (!more && _resetScrollOnNextLoad) {
        _resetScrollOnNextLoad = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        });
      }
      unawaited(
        saveUserChange(context, () => widget.store.refreshDramas(result.items)),
      );
    }

    try {
      final result = await _browser.load(
        group,
        category: _effectiveCategory,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        crossSource: _crossSourceSearch,
        crossSources: _crossSourceSearch ? _visibleSourceIds : null,
        onCached: (result) => accept(result, cached: true),
        filters: _allSources ? const {} : _selectedFilters,
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (!silent) _error = error.toString();
      });
    }
  }

  /// 当前视频区上次选中的站（跨重启记忆）：先读本会话刚记下的，
  /// 再读落盘的；'__all__' 恢复全部站源模式，站源 id 恢复单站。
  /// 记过但已不在本区可见源里（被删、被摘、被隐藏）时返回 null，
  /// 由调用方回落默认站；门禁只做减法，记忆不把藏起的站翻出来。
  ({SourceSite site, bool allSources})? _rememberedForCurrentZone() {
    final value =
        _lastZoneSource[_zone.name] ?? widget.store.zoneSource(_zone.name);
    if (value.isEmpty) return null;
    final candidates = _librarySources;
    if (candidates.isEmpty) return null;
    if (value == LocalStore.zoneSourceAll) {
      return (site: candidates.first, allSources: _sourceGroups.length > 1);
    }
    final site = candidates.where((site) => site.id == value).firstOrNull;
    if (site == null) return null;
    return (site: site, allSources: false);
  }

  void _changeSource(SourceSite source, {bool allSources = false}) {
    _debounce?.cancel();
    _search.clear();
    // 戏剧首页内切站：钉住戏剧首页分支，换站后仍停在原界面、
    // 内容换成新站的（_group.id 随站源变，不钉住会跳通用分支）。
    final keepDramaHome =
        _zone == HomeZone.library && isHongguoDramaGroup(_group.id);
    setState(() {
      if (keepDramaHome) _dramaHomePinned = true;
      _drillStack.clear();
      _catalogTags = const [];
      _catalogFilters = const [];
      _selectedFilters.clear();
      _tagLevel2 = null;
      _tagLevel3 = null;
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _source = source;
      _allSources = allSources;
      _categorySelections[_categoryKey(_group.id)] = '';
      _items = [];
      _hasMore = true;
      _submittedQuery = '';
      _error = null;
    });
    unawaited(
      saveUserChange(
        context,
        () => widget.store.setCatalogSource(source.id, allSources: allSources),
      ),
    );
    _lastZoneSource[_zone.name] = allSources
        ? LocalStore.zoneSourceAll
        : source.id;
    unawaited(
      widget.store.setZoneSource(
        _zone.name,
        allSources ? LocalStore.zoneSourceAll : source.id,
      ),
    );
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    _resetScrollOnNextLoad = true;
    // 切站自动加载：首次请求落空或报错时自动补拉，用户不用手动刷新。
    unawaited(_loadWithAutoRetry());
    _loadCategories(force: true);
    // Win7 片库/短剧窗口在前台时，目录内换站后同步窗口描述，
    // 最小化恢复时换回同一站（描述只记站点，不碰界面状态）。
    final foreground = _win7Foreground;
    final window = foreground == null ? null : _win7Windows[foreground];
    if (window != null &&
        (window.kind == Win7WindowKind.library ||
            window.kind == Win7WindowKind.drama)) {
      _win7Windows[foreground!] = window.copyWith(
        sourceId: source.id,
        allSources: allSources,
      );
    }
  }

  void _changeCrossSource(bool value) {
    if (_crossSourceSearch == value) return;
    setState(() => _crossSourceSearch = value);
    if (_canSearchOnline && _search.text.trim().isNotEmpty) {
      _load();
    }
  }

  void _searchChanged(String query) {
    _debounce?.cancel();
    _selectionMode = false;
    _selectedDramas.clear();
    if (_canSearchOnline && (_loading || _loadingMore)) {
      _generation++;
      unawaited(_browser.cancel());
      _loading = _loadingMore = false;
    }
    setState(() {});
    if (_canSearchOnline && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _load());
    }
  }

  void _submitSearch(String query) {
    if (_drillStack.isNotEmpty) {
      setState(() => _drillStack.clear());
    }
    if (_tagLevel2 != null || _tagLevel3 != null) {
      setState(() {
        _tagLevel2 = null;
        _tagLevel3 = null;
      });
    }
    if (_showRecommendations) {
      _showRecommendations = false;
      _categorySelections[_categoryKey(_group.id)] = '';
    }
    _selectionMode = false;
    _selectedDramas.clear();
    _search.text = query.trim();
    _debounce?.cancel();
    if (_search.text.isNotEmpty) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.rememberSearch(_search.text),
        ),
      );
    }
    if (_canSearchOnline) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _chooseCatalogView() async {
    final selected = await chooseCatalogView(context, widget.store.catalogView);
    if (selected != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setCatalogView(selected),
      );
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  PlaybackQueue? _queueAround(Drama drama, List<Drama> items) =>
      items.any((item) => item.id == drama.id && item.source == drama.source)
      ? PlaybackQueue.around(items, drama)
      : null;

  /// DetailScreen.onTagTap 的壳侧实现：以 sourceId + tagId 打开标签目录。
  void _handleDetailTagTap(String sourceId, String tagId, String tagName) =>
      openDetailTag(
        context,
        repository: widget.repository,
        store: widget.store,
        sourceId: sourceId,
        tagId: tagId,
        tagName: tagName,
        onOpenDrama: (drama, queue) => _openDrama(drama, queue: queue),
      );

  void _openDrama(Drama drama, {bool resume = false, PlaybackQueue? queue}) {
    if (_openingPlayback) return;
    _pauseCatalog();
    final contextQueue = queue ?? _queueAround(drama, _visible);
    if (vodOpenAction(
          isVodZone: isVodZoneSource(SourceSite.byId(drama.source)),
          resume: resume,
        ) ==
        VodOpenAction.detail) {
      Navigator.of(context).push(
        appPageRoute<void>(
          settings: const RouteSettings(name: 'detail'),
          builder: (_) => DetailScreen(
            drama: drama,
            repository: widget.repository,
            store: widget.store,
            onTagTap: _handleDetailTagTap,
            queue: contextQueue,
          ),
        ),
      );
      return;
    }
    _openingPlayback = true;
    unawaited(
      openPlaybackDirectly(
        context,
        drama: drama,
        repository: widget.repository,
        store: widget.store,
        queue: contextQueue,
      ).whenComplete(() {
        _openingPlayback = false;
      }),
    );
  }

  void _openGlobalVideoResult(Drama drama) {
    final site = widget.store.sources
        .where((s) => s.id == drama.source)
        .firstOrNull;
    if (site == null) {
      _openDrama(drama);
      return;
    }
    if (_zone != HomeZone.library) _setZone(HomeZone.library);
    _changeSource(site);
    _openDrama(drama);
  }

  /// 霓虹轮播位点按：当前站源的幻灯片走普通打开；混入的其它站源
  /// 幻灯片先切区切源再打开，绝不套在当前站下打开。
  void _openFeaturedDrama(Drama drama) {
    final site = widget.store.sources
        .where((s) => s.id == drama.source)
        .firstOrNull;
    if (site == null) {
      _openDrama(drama);
      return;
    }
    if (_zone == HomeZone.library && (_allSources || site.id == _source.id)) {
      _openDrama(drama);
      return;
    }
    _openGlobalVideoResult(drama);
  }

  /// 打开全站全局搜索：搜索行里的全局搜索按钮与霓虹首页/频道页的
  /// 放大镜共用同一入口，点结果走 _openGlobalVideoResult 切区切源。
  void _openGlobalSearch() {
    Navigator.of(context).push(
      appPageRoute(
        builder: (_) => GlobalSearchPage(
          repository: widget.repository,
          store: widget.store,
          initialQuery: _search.text,
          onOpenDrama: _openGlobalVideoResult,
        ),
      ),
    );
  }

  void _setZone(HomeZone zone) {
    if (zone == _zone) return;
    _applyZoneChange(zone, recordHistory: true);
  }

  /// 当前主题绑定的内容档（存于显示方案，切主题即变）。
  ContentTier get _contentTier =>
      widget.store.displayScheme(widget.store.appTheme).contentTier;

  /// 内容档命中的分类 id（漫剧/真人剧档）；全部/成人档或命中不到为 null。
  String? get _tierCategoryId => tierCategoryId(_contentTier, _categories);

  /// 内容档锁定的分类在本站不存在：分类已取回（非空）且命中不到。
  /// 分类尚未取回时不判缺，避免加载中闪空态。
  bool get _tierMissing =>
      (_contentTier == ContentTier.manhua ||
          _contentTier == ContentTier.liveAction) &&
      _categories.isNotEmpty &&
      _tierCategoryId == null;

  /// 上次已驱动过的内容档选类（`档:分类id`），避免同一决议反复发请求。
  String? _lastTierDriveKey;

  /// 内容档选类驱动：漫剧/真人剧档命中分类后，把当前选类切过去，
  /// 取数随之只取该分类（复用 _changeCategory 的整条取数链）。
  /// 在 build 里以 post-frame 方式调度：主题切换只触发重建，不触发
  /// _loadCategories，必须在重建后把选类推过去；守卫键保证同一决议
  /// 只推一次，_changeCategory 自身也会因选类相同而提前返回。
  void _driveTierCategory() {
    final tierId = _tierCategoryId;
    if (tierId == null || _drillStack.isNotEmpty) return;
    final key = '${_contentTier.storageValue}:$tierId';
    if (_category == tierId || _lastTierDriveKey == key) return;
    _lastTierDriveKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _changeCategory(tierId);
    });
  }

  /// 外层壳当前选中的标签下标：0 片库、1 直播、2 听读、3 多媒体、
  /// 4 小程序、5 我的（听书/阅读已并为“听读”，两子区同指下标 2）。
  /// 多媒体/小程序/我的只是片库区内的请求态，先于区判断（与
  /// _onBottomTab 的递出顺序一致）。
  int get _bottomTabIndex {
    if (_zone == HomeZone.library && _multimediaRequested) return 3;
    if (_zone == HomeZone.library && _miniAppRequested) return 4;
    if (_zone == HomeZone.library && _mineRequested) return 5;
    return switch (_zone) {
      HomeZone.library => 0,
      HomeZone.live => 1,
      HomeZone.audio => 2,
      HomeZone.novel => 2,
    };
  }

  void _onBottomTab(int tabIndex) {
    final wantMine = tabIndex == 5;
    final wantMultimedia = tabIndex == 3;
    final wantMiniApp = tabIndex == 4;
    final zone = switch (tabIndex) {
      1 => HomeZone.live,
      2 => _lastListenReadZone,
      _ => HomeZone.library,
    };
    if (wantMine == _mineRequested &&
        wantMultimedia == _multimediaRequested &&
        wantMiniApp == _miniAppRequested &&
        zone == _zone) {
      return;
    }
    // 同区点“我的”/“多媒体”/“小程序”时 _setZone 会提前返回，必须先
    // setState 递出请求。
    setState(() {
      _mineRequested = wantMine;
      _multimediaRequested = wantMultimedia;
      _miniAppRequested = wantMiniApp;
    });
    _setZone(zone);
  }

  /// 底部标签样式的霓虹胶囊壳：只在手机端显示；电视/桌面走各自导航，
  /// 选片模式下隐藏。全部主题共用同一壳子（见 NeonCapsuleBar），只换
  /// 主题配色。中间播放键点开全屏推荐流，无内容时变暗不响应。
  Widget? _bottomTabBar({required bool television, required bool desktop}) {
    if (television || desktop || _selectionMode) {
      return null;
    }
    const entries = <(Object, String)>[
      (LucideIcons.clapperboard, '片库'),
      (LucideIcons.tv, '直播'),
      (LucideIcons.bookHeadphones, '听读'),
      (LucideIcons.hardDrive, '多媒体'),
      (LucideIcons.layoutGrid, '小程序'),
      (LucideIcons.user, '我的'),
    ];
    return NeonCapsuleBar(
      entries: entries,
      index: _bottomTabIndex,
      onSelect: _onBottomTab,
      onCenter: _openFullscreenFeed,
      centerAfter: 3,
      centerEnabled: _feedCenterEnabled,
      tabKeyPrefix: 'shell-tab',
      centerKey: 'shell-center',
    );
  }

  void _applyZoneChange(HomeZone zone, {bool recordHistory = false}) {
    if (recordHistory && zone != _zone) _zoneHistory.push(_zone);
    _resetAutoLoad();
    if (zone == HomeZone.audio || zone == HomeZone.novel) {
      _lastListenReadZone = zone;
    }
    setState(() {
      _zone = zone;
      if (zone != HomeZone.library) {
        _mineRequested = false;
        _multimediaRequested = false;
        _miniAppRequested = false;
        _dramaHomePinned = false;
      }
      _selectionMode = false;
      _selectedDramas.clear();
    });
  }

  bool _popZoneHistory() {
    final previous = _zoneHistory.pop();
    if (previous == null) return false;
    _applyZoneChange(previous);
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      homeRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    // 上方路由弹出、首页重新成为当前页：进入短暂保护期。
    _returnGraceTimer?.cancel();
    _justReturned = true;
    _returnGraceTimer = Timer(_returnGrace, () {
      if (mounted) _justReturned = false;
    });
    _consumeSubscriptionEntryRequest();
  }

  /// 消费订阅双入口的待办请求（订阅行点“影视/直播”后退回首页时）：
  /// 直播请求切到直播区并选中该订阅的直播源；影视请求切到片库区
  /// 并打开该站（先设为可见，与站源管理页“进站浏览”同一口径）。
  /// 请求只消费一次，消费前先清掉，避免重复触发。
  void _consumeSubscriptionEntryRequest() {
    if (!mounted) return;
    final liveId = widget.store.pendingLiveSourceId;
    final siteId = widget.store.pendingVideoSiteId;
    if (liveId.isEmpty && siteId.isEmpty) return;
    widget.store.clearSubscriptionEntryRequest();
    if (liveId.isNotEmpty) {
      _liveEntryNonce++;
      _liveEntrySourceId = liveId;
      _setZone(HomeZone.live);
      // 已在直播区时 _setZone 提前返回，仍需重建把新 nonce 递给直播页。
      if (mounted) setState(() {});
      return;
    }
    final site = widget.store.sources
        .where((candidate) => candidate.id == siteId)
        .firstOrNull;
    if (site == null) return;
    unawaited(
      saveUserChange(
        context,
        () => widget.store.setSiteVisible(site.id, true),
      ),
    );
    _setZone(HomeZone.library);
    _changeSource(site);
  }

  bool get _settlingAfterPop => _justReturned;

  /// 头像点按：抽屉拆除后，点头像进“我的”页（与底部栏“我的”
  /// 标签同一目的地）。
  void _openMine() => _onBottomTab(5);

  Widget _mineAvatarButton() => IconButton(
    key: const ValueKey('open-mine-page'),
    tooltip: '我的',
    iconSize: 32,
    padding: const EdgeInsets.all(8),
    onPressed: _openMine,
    icon: ClipOval(
      child: Image.asset(
        'assets/ant_logo.png',
        width: 32,
        height: 32,
        fit: BoxFit.cover,
      ),
    ),
  );

  /// 顶栏左侧：只有头像。站源选择只留标题上的一个（source-switch），
  /// 原头像旁的站源胶囊与标题选择器重复（同一站显示两遍），已删。
  Widget _appBarLeading() => _mineAvatarButton();

  void _openZoneSettings() {
    // 片库设置页已废弃（2026-11-14）：片库区直接进通用设置（五项已并入），
    // 只有直播区还走分区设置页；听书/阅读区本来就直接进通用设置。
    if (_zone == HomeZone.live) {
      _pushTool(
        ZoneSettingsScreen(
          repository: widget.repository,
          store: widget.store,
          zone: _zone,
        ),
      );
    } else {
      _openSettings();
    }
  }

  void _openSettings() {
    _pushTool(
      SettingsScreen(
        repository: widget.repository,
        store: widget.store,
        onHideAdult: () => unawaited(_onMinorProtectionChanged(true)),
      ),
    );
  }

  void _openSaved({required bool history}) {
    _pushTool(
      Scaffold(
        appBar: AppBar(title: Text(history ? '最近观看' : '追剧')),
        body: SavedLibrary(
          repository: widget.repository,
          store: widget.store,
          history: history,
          onOpen: _openDrama,
          onContinue: (drama) => _openDrama(drama, resume: true),
        ),
      ),
    );
  }

  void _toggleNewSort() {
    final view = widget.store.catalogView;
    final next = view.sort == CatalogSort.date
        ? CatalogSort.source
        : CatalogSort.date;
    unawaited(
      saveUserChange(
        context,
        () => widget.store.setCatalogView(view.copyWith(sort: next)),
      ),
    );
  }

  int? get _railIndex => switch (_zone) {
    HomeZone.library => 0,
    HomeZone.live => 1,
    _ => null,
  };

  void _onRailSelected(int index) {
    switch (index) {
      case 0:
        _setZone(HomeZone.library);
      case 1:
        _setZone(HomeZone.live);
      default:
        // 桌面导航轨第三项是“设置”：抽屉拆除后直接进设置页。
        _openSettings();
    }
  }

  /// 全屏流入口是否可用：流固定取红果短剧，不再依赖当前目录
  /// 是否为空；红果是内置站恒可用，取不到时屏内显示重试。
  bool get _feedCenterEnabled =>
      SourceSite.isAvailable(CenterFeedLoader.hongguoSourceId);

  void _openFullscreenFeed() {
    if (!_feedCenterEnabled) return;
    _pauseCatalog();
    // 加载器随屏新建：打开即取、刷新重取、每次重取都重新随机
    // 混排；验播缓存随屏走，屏内切分类不重验。
    final loader = CenterFeedLoader(
      repository: widget.repository,
      store: widget.store,
    );
    unawaited(
      Navigator.of(context).push<void>(
        appPageRoute<void>(
          builder: (_) => FullscreenFeedScreen(
            dramas: const [],
            repository: widget.repository,
            store: widget.store,
            onLoadFeed: loader.load,
          ),
        ),
      ),
    );
  }

  void _pushTool(Widget screen) {
    unawaited(
      Navigator.of(
        context,
      ).push<void>(appPageRoute<void>(builder: (_) => screen)),
    );
  }

  /// 未成年保护（与火蚁TV现行做法一致的一次性动作，无持久开关）：
  /// 点按后在片库区内切回短剧站；下次再切到点播站仍可见成人站，
  /// 与火蚁TV点按后离开午夜区、下次仍可再进午夜区的语义相同。
  Future<void> _onMinorProtectionChanged(bool enabled) async {
    if (!enabled) return;
    if (_zone != HomeZone.library || !_source.isVideoSection) return;
    final drama = _librarySources
        .where((site) => site.isDramaSection)
        .firstOrNull;
    if (drama != null && drama.id != _source.id) _changeSource(drama);
  }

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _dramaActions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    onDetail: () {
      Navigator.of(context).push(
        appPageRoute<void>(
          settings: const RouteSettings(name: 'detail'),
          builder: (_) => DetailScreen(
            drama: drama,
            repository: widget.repository,
            store: widget.store,
            onTagTap: _handleDetailTagTap,
            queue: _queueAround(drama, _visible),
          ),
        ),
      );
    },
    onContinue: () => _openDrama(drama, resume: true),
  );

  Widget _catalogTile(
    Drama drama, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final following = widget.store.following(drama.id);
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => drama.isFolder ? _drillInto(drama) : _openDrama(drama),
      onLongPress: null,
      onMore: drama.isFolder ? null : () => _dramaActions(drama),
      actions: drama.isFolder
          ? null
          : DramaActionButton(
              drama: drama,
              onPressed: () => _dramaActions(drama),
            ),
      selected: _selectionMode ? _selectedDramas.containsKey(drama.id) : null,
      badge: drama.isFolder
          ? (drama.isTagFolder ? '标签' : '文件夹')
          : following == null
          ? null
          : '${following.status.label}${following.hasUpdates ? ' · ${following.updateLabel}' : ''}',
    );
  }

  void _pauseCatalog() {
    _debounce?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    setState(() {
      _loading = false;
      _loadingMore = false;
    });
  }

  bool get _supportsVipFilter =>
      _group.sources.any((source) => source.id == 'huangdou');
  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;

  List<Drama> get _visible {
    final view = widget.store.catalogView;
    final key = [
      identityHashCode(_items),
      _items.length,
      _category,
      _tagLevel2 ?? '',
      _tagLevel3 ?? '',
      _search.text.trim().toLowerCase(),
      _onlineSearch,
      _hideVip,
      widget.store.hiddenSites.join(','),
      widget.store.profileEpoch,
      widget.store.locked,
      view.sort,
      view.release,
      view.allSources,
    ].join('|');
    if (_visibleCache != null && _visibleCacheKey == key) {
      return _visibleCache!;
    }
    final query = _search.text.trim().toLowerCase();
    final hidden = widget.store.hiddenSites;
    final visible = sortCatalog(
      _items.where((drama) {
        if (!widget.store.allowsSource(drama.source)) return false;
        if (hidden.contains(drama.source)) return false;
        if (_category.startsWith('local:') &&
            categoryName(drama.category) != _category.substring(6)) {
          return false;
        }
        if (_hideVip && drama.source == 'huangdou' && drama.vip) {
          return false;
        }
        if (_tagLevel2 != null && !drama.tags.contains(_tagLevel2)) {
          return false;
        }
        if (_tagLevel3 != null && !drama.tags.contains(_tagLevel3)) {
          return false;
        }
        return _onlineSearch ||
            query.isEmpty ||
            matchesDramaQuery(drama, query);
      }),
      view,
    );
    _visibleCache = visible;
    _visibleCacheKey = key;
    return visible;
  }

  List<String> get _level2Tags {
    final key = '${identityHashCode(_items)}|${_items.length}';
    if (_level2TagsCache != null && _level2TagsCacheKey == key) {
      return _level2TagsCache!;
    }
    final seen = <String>{};
    final out = <String>[];
    for (final drama in _items) {
      for (final tag in drama.tags) {
        if (seen.add(tag)) out.add(tag);
      }
    }
    _level2TagsCache = out;
    _level2TagsCacheKey = key;
    return out;
  }

  List<String> get _level3Tags {
    final level2 = _tagLevel2;
    if (level2 == null) return const [];
    final key = '${identityHashCode(_items)}|${_items.length}|$level2';
    if (_level3TagsCache != null && _level3TagsCacheKey == key) {
      return _level3TagsCache!;
    }
    final seen = <String>{};
    final out = <String>[];
    for (final drama in _items) {
      if (!drama.tags.contains(level2)) continue;
      for (final tag in drama.tags) {
        if (tag != level2 && seen.add(tag)) out.add(tag);
      }
    }
    _level3TagsCache = out;
    _level3TagsCacheKey = key;
    return out;
  }

  void _selectTagLevel2(String? tag) {
    if (_tagLevel2 == tag) return;
    setState(() {
      _tagLevel2 = tag;
      _tagLevel3 = null;
    });
  }

  void _selectTagLevel3(String? tag) {
    if (_tagLevel3 == tag) return;
    setState(() => _tagLevel3 = tag);
  }

  bool get _catalogBusy =>
      _loading ||
      _loadingMore ||
      _categoriesLoading ||
      _group.sources.any((source) => _updater.busy(source.id));

  /// Material 顶栏的片库目录操作组（排序/榜单/全屏流/搜索/网页爬取/
  /// 刷新）：宽屏放 actions 行，窄屏放顶栏第二行，
  /// 与玻璃顶栏的胶囊第二行同一道理，避免盖住站源条。
  /// 站源选择只留标题上的一个，这里不放下拉按钮。
  List<Widget> _materialCatalogActions({
    required bool television,
    required double maxWidth,
  }) {
    return [
      if (!_showRecommendations)
        IconButton(
          tooltip: '排序与筛选 · ${widget.store.catalogView.sort.label}',
          onPressed: _chooseCatalogView,
          color:
              widget.store.catalogView.sort != CatalogSort.source ||
                  widget.store.catalogView.release.isNotEmpty
              ? Theme.of(context).colorScheme.primary
              : null,
          icon: const Icon(Icons.sort_rounded),
        ),
      IconButton(
        key: const ValueKey('open-rankings'),
        tooltip: '榜单',
        onPressed: widget.store.visibleSources.isEmpty ? null : _openRankings,
        icon: const Icon(Icons.leaderboard_outlined),
      ),
      IconButton(
        key: const ValueKey('open-fullscreen-feed'),
        tooltip: '全屏流',
        onPressed: _feedCenterEnabled ? _openFullscreenFeed : null,
        icon: const Icon(Icons.play_arrow_rounded),
      ),
      // 片库区右上角不放齿轮（用户令）；齿轮只留在直播区。
      if (_zone == HomeZone.live && !television)
        IconButton(
          key: const ValueKey('open-settings'),
          tooltip: '设置',
          icon: const Icon(Icons.settings_outlined),
          onPressed: _openZoneSettings,
        ),
      IconButton(
        key: const ValueKey('toggle-search'),
        tooltip: _searchVisible ? '收起搜索' : '搜索',
        icon: Icon(
          _searchVisible ? Icons.search_off_rounded : Icons.search_rounded,
        ),
        onPressed: _toggleSearch,
      ),
      IconButton(
        key: const ValueKey('web-scrape'),
        tooltip: '网页爬取',
        icon: const Icon(Icons.travel_explore_rounded),
        onPressed: _openWebScrape,
      ),
      if (!_showRecommendations && maxWidth >= 400)
        RefreshAction(
          key: const ValueKey('catalog-refresh'),
          loading: _catalogBusy,
          tooltip: '更新剧库',
          onPressed:
              widget.store.visibleSources.isEmpty ? null : _refreshCatalog,
        ),
      if (!_showRecommendations && maxWidth < 400)
        IconButton(
          tooltip: '更新剧库',
          onPressed:
              widget.store.visibleSources.isEmpty ? null : _refreshCatalog,
          icon: const Icon(Icons.refresh_rounded),
        ),
      // 站源选择只留标题上的一个（source-switch）：原这里的下拉按钮
      // 与标题选择器重复（同一站显示两遍），已删。
    ];
  }

  PreferredSizeWidget _glassAppBar() {
    final colors = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final largeTitle = TextStyle(
      fontSize: 12,
      height: 1.1,
      fontWeight: FontWeight.w800,
      letterSpacing: 0,
      color: colors.onSurface,
    );
    final catalog = _showCatalogHeader && !_selectionMode;
    final customView =
        widget.store.catalogView.sort != CatalogSort.source ||
        widget.store.catalogView.release.isNotEmpty;
    final updating = _group.sources.any((source) => _updater.busy(source.id));
    final Widget title;
    if (_selectionMode) {
      title = Text('选择视频', style: largeTitle);
    } else if (_multimediaRequested) {
      title = Text('多媒体', style: largeTitle);
    } else if (_miniAppRequested) {
      title = Text('小程序', style: largeTitle);
    } else if (_mineRequested) {
      title = Text('我的', style: largeTitle);
    } else if (_showCatalogHeader) {
      title = GlassTapTarget(
        key: const ValueKey('source-switch'),
        onTap: _canSwitchSource ? () => unawaited(_pickSource()) : null,
        onLongPress: _canSwitchSource
            ? () => unawaited(_pickSource(editMode: true))
            : null,
        child: Semantics(
          button: _canSwitchSource,
          label: '切换站源',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: largeTitle,
                ),
              ),
              if (_canSwitchSource) ...[
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.chevronDown,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      );
    } else {
      title = Text(_zoneTitle, style: largeTitle);
    }
    // 工具胶囊：窄屏（手机）时顶栏一行放不下头像 + 标题 + 六项胶囊，
    // 胶囊会盖住标题；窄屏改放顶栏第二行（bottom），宽屏仍放 actions 行。
    final capsule = GlassButtonGroup(
      children: [
        if (updating || _loading && _items.isNotEmpty)
          const GlassGroupItem(
            key: ValueKey('catalog-refresh'),
            tooltip: '正在更新',
            onPressed: null,
            child: SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
            ),
          ),
        if (!_showRecommendations)
          GlassGroupItem(
            icon: LucideIcons.arrowUpDown,
            tooltip: '排序与筛选 · ${widget.store.catalogView.sort.label}',
            highlighted: customView,
            onPressed: _chooseCatalogView,
          ),
        GlassGroupItem(
          key: const ValueKey('open-rankings'),
          icon: LucideIcons.trophy,
          tooltip: '榜单',
          onPressed: widget.store.visibleSources.isEmpty
              ? null
              : _openRankings,
        ),
        GlassGroupItem(
          key: const ValueKey('open-fullscreen-feed'),
          icon: LucideIcons.play,
          tooltip: '全屏流',
          onPressed: _feedCenterEnabled ? _openFullscreenFeed : null,
        ),
        GlassGroupItem(
          key: const ValueKey('toggle-search'),
          icon: _searchVisible ? LucideIcons.searchX : LucideIcons.search,
          tooltip: _searchVisible ? '收起搜索' : '搜索',
          highlighted: _searchVisible,
          onPressed: _toggleSearch,
        ),
        GlassGroupItem(
          key: const ValueKey('web-scrape'),
          icon: LucideIcons.globe,
          tooltip: '网页爬取',
          onPressed: _openWebScrape,
        ),
        if (!_showRecommendations && !updating)
          GlassGroupItem(
            icon: LucideIcons.rotateCw,
            tooltip: '更新剧库',
            onPressed: widget.store.visibleSources.isEmpty
                ? null
                : _refreshCatalog,
          ),
      ],
    );
    return AppBar(
      toolbarHeight: 64,
      centerTitle: false,
      titleSpacing: 20,
      automaticallyImplyLeading: false,
      leading: _appBarLeading(),
      title: title,
      actions: [
        if (_selectionMode) ...[
          TextButton(
            key: const ValueKey('clear-catalog-selection'),
            onPressed: _selectedDramas.isEmpty
                ? null
                : () => setState(_selectedDramas.clear),
            child: const Text('清空'),
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            key: const ValueKey('cancel-catalog-selection'),
            icon: LucideIcons.x,
            tooltip: '取消',
            onPressed: _cancelSelection,
          ),
        ] else ...[
          if (catalog) ...[
            // 宽屏工具胶囊放 actions 行；站源选择只留标题上的一个，
            // 原 actions 里的下拉盒与标题选择器重复，已删。
            if (wide) capsule,
            if (wide) const SizedBox(width: 8),
          ],
          // 片库区右上角不放齿轮（用户令）；齿轮只留在直播区。
          if (!AppLayout.isTelevision(context) && _zone == HomeZone.live)
            GlassIconButton(
              key: const ValueKey('open-settings'),
              icon: LucideIcons.settings,
              tooltip: '设置',
              onPressed: _openZoneSettings,
            ),
        ],
        const SizedBox(width: 16),
      ],
      // 窄屏第二行：工具胶囊右对齐独占一行，不再盖住站源条。
      bottom: catalog && !wide
          ? PreferredSize(
              preferredSize: const Size.fromHeight(52),
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 8),
                  child: capsule,
                ),
              ),
            )
          : null,
    );
  }

  // ---- Win7 窗口管理器 ----
  //
  // 状态保留机制：所有已开窗口的 Frame + 内容体以 kind 为 key 固定在
  // _win7Shell 的 Stack 子列表同一位置，前台的正常显示、其余包在
  // Offstage 里——key 稳定则 Element 不重建，State 与界面状态完整
  // 保留；关闭只是把该 key 的子树从列表摘掉，State 随之销毁。
  // 换站语义见 _Win7Window：直播窗靠 nonce 切站、实例不重建，
  // 听读窗靠选站 key 换实例，片库/短剧窗靠共享目录状态换站。

  /// 打开窗口（或切到前台）：该种窗口已开则只切前台；[sourceId]
  /// 非空则换站（直播窗 nonce 切站、听读窗重建、片库/短剧窗换源）。
  /// 桌面图标与开始菜单点站点走同一入口。
  void _win7Open(
    Win7WindowKind kind, {
    String? sourceId,
    bool allSources = false,
  }) {
    final existing = _win7Windows[kind];
    final targetId =
        sourceId ?? existing?.sourceId ?? _win7DefaultSourceId(kind);
    final targetAll = sourceId != null
        ? allSources
        : (existing?.allSources ??
              (kind == Win7WindowKind.library ? _allSources : false));
    // 显式换站才递进 nonce（哪怕换回原记录的站也递进：窗口内可能
    // 已手动换走，nonce 是让已挂载实例切站的唯一信号）。
    final targetNonce = sourceId != null
        ? (existing?.nonce ?? 0) + 1
        : (existing?.nonce ?? 0);
    setState(() {
      _win7MenuOpen = false;
      _win7Windows[kind] = _Win7Window(
        kind: kind,
        sourceId: targetId,
        allSources: targetAll,
        nonce: targetNonce,
      );
      _win7Foreground = kind;
    });
    _win7ApplyForeground(kind, targetId, targetAll);
  }

  /// 新开窗口的默认站点：取各区当前选中的站（没有则空，由各区
  /// 自己的默认逻辑接手）。
  String? _win7DefaultSourceId(Win7WindowKind kind) => switch (kind) {
    Win7WindowKind.library => _source.id,
    Win7WindowKind.drama => _hongguoSource()?.id ?? _source.id,
    Win7WindowKind.live => _liveEntrySourceId.isEmpty
        ? null
        : _liveEntrySourceId,
    Win7WindowKind.audio =>
      _contentBinding.selectedIdFor(ContentSection.audio),
    Win7WindowKind.novel =>
      _contentBinding.selectedIdFor(ContentSection.novel),
    Win7WindowKind.miniApp => null,
    Win7WindowKind.multimedia => null,
  };

  SourceSite? _hongguoSource() {
    for (final site in _librarySources) {
      if (isHongguoDramaGroup(site.groupId)) return site;
    }
    return null;
  }

  SourceSite? _findLibrarySite(String id) {
    for (final site in _librarySources) {
      if (site.id == id) return site;
    }
    return null;
  }

  /// 把首页共享状态拨到前台窗口的描述：片库/短剧拨区与站点，
  /// 听读拨 binding 选站，其余只拨区（内容体由窗口描述直供参数）。
  /// 不记区历史：窗口层面的返回是最小化回桌面，不走区历史。
  void _win7ApplyForeground(
    Win7WindowKind kind,
    String? sourceId,
    bool allSources,
  ) {
    switch (kind) {
      case Win7WindowKind.library:
      case Win7WindowKind.drama:
        _applyZoneChange(HomeZone.library);
        final site = sourceId == null ? null : _findLibrarySite(sourceId);
        if (site != null &&
            (site.id != _source.id || allSources != _allSources)) {
          _changeSource(site, allSources: allSources);
        }
        setState(() {
          _mineRequested = false;
          _multimediaRequested = false;
          _miniAppRequested = false;
          // _changeSource 遇红果组会钉住戏剧首页，这里以窗口种类为准
          // 再拨一次：短剧窗钉住，片库窗不钉。
          _dramaHomePinned = kind == Win7WindowKind.drama;
        });
      case Win7WindowKind.live:
        _applyZoneChange(HomeZone.live);
      case Win7WindowKind.audio:
      case Win7WindowKind.novel:
        final section = kind == Win7WindowKind.audio
            ? ContentSection.audio
            : ContentSection.novel;
        if (sourceId != null &&
            _contentBinding.selectedIdFor(section) != sourceId) {
          for (final source in ContentRegistry.sourcesFor(section)) {
            if (source.id == sourceId) {
              _contentBinding.select(section, source);
              break;
            }
          }
        }
        _applyZoneChange(
          kind == Win7WindowKind.audio ? HomeZone.audio : HomeZone.novel,
        );
      case Win7WindowKind.miniApp:
      case Win7WindowKind.multimedia:
        _applyZoneChange(HomeZone.library);
        setState(() {
          _mineRequested = false;
          _multimediaRequested = false;
          _miniAppRequested = false;
        });
    }
  }

  /// 最小化：窗口退到任务栏，界面实例留在树里、状态保留。
  void _win7Minimize(Win7WindowKind kind) {
    setState(() {
      if (_win7Foreground == kind) _win7Foreground = null;
    });
  }

  /// 关闭：窗口从树里摘掉，界面状态丢弃，重开即全新。
  /// 听书播放是应用级单例，关窗口不影响正在播的音频（既有行为）。
  void _win7Close(Win7WindowKind kind) {
    setState(() {
      _win7Windows.remove(kind);
      if (_win7Foreground == kind) _win7Foreground = null;
    });
  }

  /// 任务栏条目点按：前台窗口点条目是最小化，其余是切到前台。
  void _win7ToggleEntry(Win7WindowKind kind) {
    if (_win7Foreground == kind) {
      _win7Minimize(kind);
    } else {
      _win7Open(kind);
    }
  }

  void _win7ToggleMenu() {
    final opening = !_win7MenuOpen;
    setState(() => _win7MenuOpen = opening);
    if (opening) _win7RefreshMiniApps();
  }

  Future<void> _win7RefreshMiniApps() async {
    try {
      final installed = await MiniAppStore().listInstalled();
      if (!mounted || !_win7MenuOpen) return;
      setState(() => _win7MiniApps = installed);
    } catch (_) {
      // 小程序清单读不到时该组显示暂无，不挡主流程。
    }
  }

  /// 窗口内听读子区切换（听书/阅读胶囊）= 切到另一个听读窗口，
  /// 各窗口保留各自状态。
  void _win7ListenReadSwitch(HomeZone zone) {
    _win7Open(
      zone == HomeZone.audio ? Win7WindowKind.audio : Win7WindowKind.novel,
    );
  }

  /// 开始菜单树：按区（片库/直播/听读/短剧/小程序/多媒体）分组，
  /// 组下挂该区真实站点，名全部取注册表。听读组下再分听书/阅读
  /// 两层，演示任意层级展开。空组挂一行“暂无可用站点”（点按无动作）。
  List<Win7TreeNode> _win7TreeGroups() {
    List<Win7TreeNode> orEmpty(List<Win7TreeNode> children) =>
        children.isEmpty
            ? const [Win7TreeNode(label: '暂无可用站点')]
            : children;
    return [
      Win7TreeNode(
        label: '片库',
        children: orEmpty([
          for (final site in _librarySources)
            Win7TreeNode(
              label: site.name,
              kind: Win7WindowKind.library,
              siteId: site.id,
            ),
        ]),
      ),
      Win7TreeNode(
        label: '直播',
        children: orEmpty([
          for (final source in LiveSource.visible(false))
            Win7TreeNode(
              label: source.name,
              kind: Win7WindowKind.live,
              siteId: source.id,
            ),
        ]),
      ),
      Win7TreeNode(
        label: '听读',
        children: [
          Win7TreeNode(
            label: '听书',
            children: orEmpty([
              for (final source in ContentRegistry.sourcesFor(
                ContentSection.audio,
              ))
                Win7TreeNode(
                  label: source.name,
                  kind: Win7WindowKind.audio,
                  siteId: source.id,
                ),
            ]),
          ),
          Win7TreeNode(
            label: '阅读',
            children: orEmpty([
              for (final source in ContentRegistry.sourcesFor(
                ContentSection.novel,
              ))
                Win7TreeNode(
                  label: source.name,
                  kind: Win7WindowKind.novel,
                  siteId: source.id,
                ),
            ]),
          ),
        ],
      ),
      Win7TreeNode(
        label: '短剧',
        children: orEmpty([
          for (final site in _librarySources)
            if (isHongguoDramaGroup(site.groupId))
              Win7TreeNode(
                label: site.name,
                kind: Win7WindowKind.drama,
                siteId: site.id,
              ),
        ]),
      ),
      // 小程序/多媒体屏不接受直达某项的参数，树节点只开窗口。
      Win7TreeNode(
        label: '小程序',
        children: orEmpty([
          for (final app in _win7MiniApps)
            Win7TreeNode(
              label: app.name,
              kind: Win7WindowKind.miniApp,
              siteId: app.appId,
            ),
        ]),
      ),
      Win7TreeNode(
        label: '多媒体',
        children: orEmpty([
          for (final site in _cloudDriveSites)
            Win7TreeNode(
              label: site.name,
              kind: Win7WindowKind.multimedia,
              siteId: site.id,
            ),
        ]),
      ),
    ];
  }

  /// 某窗口的内容体。直播体 key 固定、靠 nonce 换站；听读体 key 取
  /// binding 选站；片库/短剧体读首页共享目录状态，不常驻（最小化
  /// 时只留描述）。
  Widget _win7WindowBody(
    _Win7Window window, {
    required bool glass,
    required double maxWidth,
  }) {
    switch (window.kind) {
      case Win7WindowKind.live:
        // key 固定：实例常驻，换站靠 nonce 走 LiveScreen 自身切站。
        return LiveScreen(
          key: const ValueKey('win7-live'),
          repository: _liveRepository,
          store: _liveStore,
          greenMode: false,
          onExitLeft: () => _navKey.currentState?.focusCurrent(),
          appStore: widget.store,
          initialSourceId: window.sourceId ?? '',
          initialSourceNonce: window.nonce,
        );
      case Win7WindowKind.audio:
      case Win7WindowKind.novel:
        final zone = window.kind == Win7WindowKind.audio
            ? HomeZone.audio
            : HomeZone.novel;
        final section = zone == HomeZone.audio
            ? ContentSection.audio
            : ContentSection.novel;
        // key 取 binding 当前选站：只切前台/最小化时选站不变、实例
        // 保留；窗口内换站或树里换站都改选站、key 变、实例重建。
        return ListenReadPage(
          key: ValueKey(
            'win7-listenread-${zone.name}-${_contentBinding.selectedIdFor(section) ?? ''}',
          ),
          zone: zone,
          onZoneSelected: _win7ListenReadSwitch,
          zoneBuilder: (z) => ContentZoneScreen(
            section: z == HomeZone.audio
                ? ContentSection.audio
                : ContentSection.novel,
            binding: _contentBinding,
          ),
        );
      case Win7WindowKind.miniApp:
        return const MiniAppHomePage(key: ValueKey('win7-miniapp'));
      case Win7WindowKind.multimedia:
        return MultimediaScreen(
          key: const ValueKey('win7-multimedia'),
          repository: widget.repository,
          store: widget.store,
          driveSites: _cloudDriveSites,
          onOpenDrama: _openDrama,
          onOpenCloudLogin: _openCloudLogin,
        );
      case Win7WindowKind.library:
      case Win7WindowKind.drama:
        return _win7LibraryBody(glass: glass, maxWidth: maxWidth);
    }
  }

  /// 片库/短剧窗口体：与通用分支同口径（红果组/钉住且不在选片
  /// 模式时走戏剧首页，否则走带顶栏的目录），窗口内不挂胶囊栏。
  /// 直接调 _catalog，不走 _tabBody 的区派发，窗口内容不受区
  /// 状态侧路影响。
  Widget _win7LibraryBody({required bool glass, required double maxWidth}) {
    if (!_selectionMode &&
        (isHongguoDramaGroup(_group.id) || _dramaHomePinned)) {
      return SafeArea(
        bottom: !glass,
        child: _dramaHome(hideCapsuleBar: true),
      );
    }
    return Scaffold(
      appBar: _homeAppBar(television: false, maxWidth: maxWidth),
      body: SafeArea(
        top: false,
        bottom: !glass,
        child: _librarySources.isEmpty
            ? _noSourcesPanel()
            : _catalog(selectionInBody: false),
      ),
    );
  }

  /// 窗口槽位：直播/听读/小程序/多媒体体常驻（Offstage 藏起），
  /// 状态完整保留；片库/短剧体共用首页目录状态（同一 _scroll
  /// 控制器挂两份滚动视图会崩），只在前台时建体，最小化时槽位
  /// 只留一个空占位、描述留在 _win7Windows 里供恢复换站。
  Widget _win7WindowSlot(
    _Win7Window window, {
    required bool isForeground,
    required bool glass,
    required double maxWidth,
  }) {
    final slotKey = ValueKey('win7-window-${window.kind.name}');
    if ((window.kind == Win7WindowKind.library ||
            window.kind == Win7WindowKind.drama) &&
        !isForeground) {
      return SizedBox.shrink(key: slotKey);
    }
    return Offstage(
      key: slotKey,
      offstage: !isForeground,
      child: Win7WindowFrame(
        kind: window.kind,
        onMinimize: () => _win7Minimize(window.kind),
        onClose: () => _win7Close(window.kind),
        child: _win7WindowBody(window, glass: glass, maxWidth: maxWidth),
      ),
    );
  }

  /// Win7 外壳：桌面/窗口区 + 常驻任务栏。胶囊栏整个不出现。
  /// 系统返回：先关菜单，再退选片/搜索，最后把前台窗口最小化
  /// 回桌面；桌面上的返回才退出应用。
  Widget _win7Shell({required bool glass, required double maxWidth}) {
    final foregroundKind = _win7Foreground;
    final foregroundWindow = foregroundKind == null
        ? null
        : _win7Windows[foregroundKind];
    return PopScope(
      canPop:
          foregroundWindow == null &&
          !_win7MenuOpen &&
          !_selectionMode &&
          !_searchVisible &&
          _search.text.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_win7MenuOpen) {
          setState(() => _win7MenuOpen = false);
        } else if (_selectionMode) {
          _cancelSelection();
        } else if (_searchVisible || _search.text.isNotEmpty) {
          setState(() => _searchVisible = false);
          _search.clear();
          _searchChanged('');
        } else if (foregroundWindow != null) {
          _win7Minimize(foregroundWindow.kind);
        }
      },
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  if (foregroundWindow == null)
                    Win7Desktop(onIconTap: (kind) => _win7Open(kind)),
                  // 已开窗口各占一个 key 固定的槽位：前台显示、其余
                  // Offstage，状态保留靠 key 稳定 + 不换父级。
                  for (final entry in _win7Windows.entries)
                    _win7WindowSlot(
                      entry.value,
                      isForeground: entry.key == foregroundKind,
                      glass: glass,
                      maxWidth: maxWidth,
                    ),
                  if (_win7MenuOpen)
                    Win7StartMenu(
                      groups: _win7TreeGroups(),
                      onLeafTap: (kind, siteId) =>
                          _win7Open(kind, sourceId: siteId),
                      onDismiss: () =>
                          setState(() => _win7MenuOpen = false),
                    ),
                ],
              ),
            ),
            Win7Taskbar(
              openWindows: _win7Windows.keys.toList(),
              foreground: foregroundKind,
              onStartTap: _win7ToggleMenu,
              onEntryTap: _win7ToggleEntry,
            ),
          ],
        ),
      ),
    );
  }

  /// 戏剧首页体（通用分支与 Win7 短剧/片库窗口共用同一份构造，
  /// 只差胶囊栏显隐：Win7 窗口内恒藏）。
  Widget _dramaHome({required bool hideCapsuleBar}) {
    return HongguoDramaHome(
      dramas: List.of(_visible),
      repository: widget.repository,
      store: widget.store,
      onOpenDrama: _openDrama,
      onOpenFeed: _openFullscreenFeed,
      onPickSource: () => unawaited(_pickSource()),
      sourceLabel: '${_group.name} (${_group.sources.length})',
      currentSourceLabel: _allSources ? '全部站源' : _source.name,
      feedEnabled: _feedCenterEnabled,
      categories: _displayCategories,
      selectedCategory: _displayCategory,
      onCategorySelected: _changeCategory,
      contentTier: _contentTier,
      tierEmpty: _tierMissing,
      searchController: _search,
      searchHint: _searchHint,
      onSearchChanged: _searchChanged,
      onSearchSubmitted: _submitSearch,
      onOpenGlobalSearch: _openGlobalSearch,
      onAvatarPressed: _openMine,
      onFilterPressed: () => unawaited(_chooseCatalogView()),
      onRankingsPressed: _openRankings,
      onNewPressed: _toggleNewSort,
      filtersActive:
          widget.store.catalogView.sort != CatalogSort.source ||
          widget.store.catalogView.release.isNotEmpty,
      newActive: widget.store.catalogView.sort == CatalogSort.date,
      onOpenSaved: _openSaved,
      onSettingsPressed: _openZoneSettings,
      onOpenFeatured: _openFeaturedDrama,
      requestedTab: _multimediaRequested
          ? HongguoDramaHome.multimediaTabIndex
          : _miniAppRequested
          ? HongguoDramaHome.miniAppTabIndex
          : _mineRequested
          ? HongguoDramaHome.mineTabIndex
          : null,
      hideCapsuleBar: hideCapsuleBar,
      driveSites: _cloudDriveSites,
      onOpenCloudLogin: _openCloudLogin,
    );
  }

  /// 通用顶栏（通用分支与 Win7 片库/短剧窗口共用同一份构造）。
  PreferredSizeWidget _homeAppBar({
    required bool television,
    required double maxWidth,
  }) {
    if (glassDesign(context)) return _glassAppBar();
    return AppBar(
      toolbarHeight: television ? 64 : null,
      titleSpacing: 12,
      automaticallyImplyLeading: false,
      leading: _appBarLeading(),
      title: _selectionMode
          ? const Text(
              '选择视频',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : _multimediaRequested
          ? const Text('多媒体')
          : _miniAppRequested
          ? const Text('小程序')
          : _mineRequested
          ? const Text('我的')
          : _showCatalogHeader
          ? InkWell(
              key: const ValueKey('source-switch'),
              onTap: _canSwitchSource
                  ? () => unawaited(_pickSource())
                  : null,
              child: SizedBox(
                height: 48,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _group.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (_canSwitchSource)
                      const Icon(Icons.expand_more_rounded),
                  ],
                ),
              ),
            )
          : Text(_zoneTitle),
      actions: [
        if (_selectionMode) ...[
          TextButton(
            key: const ValueKey('clear-catalog-selection'),
            onPressed: _selectedDramas.isEmpty
                ? null
                : () => setState(_selectedDramas.clear),
            child: const Text('清空'),
          ),
          TextButton(
            key: const ValueKey('cancel-catalog-selection'),
            onPressed: _cancelSelection,
            child: const Text('取消'),
          ),
        ] else ...[
          if (_showCatalogHeader && maxWidth >= 840)
            ..._materialCatalogActions(
              television: television,
              maxWidth: maxWidth,
            ),
        ],
        const SizedBox(width: 8),
      ],
      // 窄屏第二行：目录操作组横排独占一行，不再盖住站源条。
      bottom:
          _showCatalogHeader && !_selectionMode && maxWidth < 840
          ? PreferredSize(
              preferredSize: const Size.fromHeight(56),
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _materialCatalogActions(
                      television: television,
                      maxWidth: maxWidth,
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  /// 无显示中站源的空态（通用 _tabBody 与 Win7 片库窗口共用）。
  Widget _noSourcesPanel() {
    return StatusPanel(
      title: '暂无显示中的站源',
      message: widget.store.sources.isEmpty
          ? '请联系管理员为当前用户开放站源。'
          : '所有站源已在「源显示列表」中关闭，请到站源管理中重新开启。',
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      _scheduleAutoLoad();
      _driveTierCategory();
      return LayoutBuilder(
        builder: (context, constraints) {
          final television = AppLayout.isTelevision(context);
          final glass = glassDesign(context);
          final desktop =
              Theme.of(context).platform != TargetPlatform.iOS &&
              constraints.maxWidth >= 840;
          // Win7 主题手机端：首页外壳换成桌面 + 窗口管理器 + 任务栏，
          // 霓虹胶囊栏整个不出现；电视与宽屏桌面布局不受影响。
          if (!television &&
              !desktop &&
              widget.store.appTheme == AppThemeMode.win7) {
            return _win7Shell(glass: glass, maxWidth: constraints.maxWidth);
          }
          // 底部标签栏：两个分支共用同一份（戏剧首页分支挂外层
          // Scaffold，与通用分支同一结构，点按可命中；挂内层
          // Scaffold 时嵌套结构下点按会被 body 盖住）。
          final bottomTabBar = _bottomTabBar(
            television: television,
            desktop: desktop,
          );
          if (!television &&
              !desktop &&
              !_selectionMode &&
              _zone == HomeZone.library) {
            if (isHongguoDramaGroup(_group.id) || _dramaHomePinned) {
              return Scaffold(
                // 无抽屉：抽屉拆除后首页不再有可盖住首页的抽屉状态，
                // 小退回前台也不会再丢首页。
                extendBody: glass,
                bottomNavigationBar: bottomTabBar,
                body: SafeArea(
                  bottom: !glass,
                  child: _dramaHome(hideCapsuleBar: bottomTabBar != null),
                ),
              );
            }
          }
          final scaffold = Scaffold(
            extendBody: glass && !desktop,
            bottomNavigationBar: bottomTabBar,
            appBar: _homeAppBar(
              television: television,
              maxWidth: constraints.maxWidth,
            ),
            body: SafeArea(
              top: false,
              bottom: !glass || desktop,
              child: Row(
                children: [
                  if (television) ...[
                    SizedBox(
                      width: 164,
                      child: RemoteList(
                        key: _navKey,
                        itemKeys: const ['library', 'live', 'settings'],
                        itemExtent: 64,
                        spacing: 14,
                        padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                        autofocus: true,
                        itemBuilder: (_, index, node, onFocus) {
                          final entries = [
                            (Icons.video_library_rounded, '片库'),
                            (Icons.live_tv_rounded, '直播'),
                            (Icons.settings_rounded, '设置'),
                          ];
                          final entry = entries[index];
                          final selected = switch (index) {
                            0 => _zone == HomeZone.library,
                            1 => _zone == HomeZone.live,
                            _ => false,
                          };
                          return RemoteButton(
                            key: ValueKey('tv-nav-$index'),
                            label: entry.$2,
                            icon: entry.$1,
                            selected: selected,
                            focusNode: node,
                            onFocus: onFocus,
                            onPressed: () {
                              switch (index) {
                                case 0:
                                  _setZone(HomeZone.library);
                                case 1:
                                  _setZone(HomeZone.live);
                                default:
                                  // 电视导航第三项是“设置”：抽屉拆除后直接进设置页。
                                  _openSettings();
                              }
                            },
                          );
                        },
                      ),
                    ),
                    const VerticalDivider(width: 1),
                  ] else if (desktop) ...[
                    NavigationRail(
                      selectedIndex: _railIndex,
                      onDestinationSelected: _onRailSelected,
                      labelType: NavigationRailLabelType.all,
                      groupAlignment: -.8,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.video_library_outlined),
                          selectedIcon: Icon(Icons.video_library),
                          label: Text('片库'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.live_tv_outlined),
                          selectedIcon: Icon(Icons.live_tv),
                          label: Text('直播'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings),
                          label: Text('设置'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                  ],
                  Expanded(
                    child: _tabBody(television: television, desktop: desktop),
                  ),
                ],
              ),
            ),
          );
          if (!television) {
            return PopScope(
              canPop:
                  !_selectionMode &&
                  !_searchVisible &&
                  _search.text.isEmpty &&
                  _zoneHistory.isEmpty,
              onPopInvokedWithResult: (didPop, result) {
                if (didPop) return;
                if (_selectionMode) {
                  _cancelSelection();
                } else if (_searchVisible || _search.text.isNotEmpty) {
                  setState(() => _searchVisible = false);
                  _search.clear();
                  _searchChanged('');
                } else if (_settlingAfterPop) {
                  // 上方路由（播放页等）弹出过渡还没跑完：首页尚未落定，
                  // 此时到达的返回是同一手势的重复投递，不得吞区历史，
                  // 否则播完返回会误退区。落定后的返回照常退区。
                } else {
                  _popZoneHistory();
                }
              },
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      Navigator.of(context).maybePop(),
                  const SingleActivator(LogicalKeyboardKey.goBack): () =>
                      Navigator.of(context).maybePop(),
                },
                child: scaffold,
              ),
            );
          }
          return PopScope(
            canPop:
                !_selectionMode &&
                (!television || _isCatalogZone && _search.text.isEmpty),
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) _televisionBack();
            },
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    Navigator.of(context).maybePop(),
                const SingleActivator(LogicalKeyboardKey.goBack): () =>
                    Navigator.of(context).maybePop(),
              },
              child: scaffold,
            ),
          );
        },
      );
    },
  );

  /// 显示中的网盘站（已登录的网盘在源显示列表里可见的才算），
  /// 供多媒体屏聚合浏览。
  List<SourceSite> get _cloudDriveSites => CloudDriveStations.stations
      .where((site) => widget.store.siteVisible(site.id))
      .toList();

  /// 打开网盘登录中心（与设置里是同一个屏）；回来后刷新，
  /// 刚登录的网盘立即出现在多媒体屏里。
  Future<void> _openCloudLogin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CloudDriveScreen(store: widget.store),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _tabBody({required bool television, required bool desktop}) {
    if (_zone == HomeZone.live) {
      return LiveScreen(
        repository: _liveRepository,
        store: _liveStore,
        greenMode: false,
        onExitLeft: () => _navKey.currentState?.focusCurrent(),
        appStore: widget.store,
        initialSourceId: _liveEntrySourceId,
        initialSourceNonce: _liveEntryNonce,
      );
    }
    if (_zone == HomeZone.audio || _zone == HomeZone.novel) {
      return ListenReadPage(
        zone: _zone,
        onZoneSelected: _setZone,
        zoneBuilder: (zone) => ContentZoneScreen(
          section: zone == HomeZone.audio
              ? ContentSection.audio
              : ContentSection.novel,
          binding: _contentBinding,
        ),
      );
    }
    // 多媒体：与短剧首页内层页签是同一个屏；网盘数据不依赖
    // 片库站源，放在“暂无站源”空态判断之前。
    if (_multimediaRequested) {
      return MultimediaScreen(
        repository: widget.repository,
        store: widget.store,
        driveSites: _cloudDriveSites,
        onOpenDrama: _openDrama,
        onOpenCloudLogin: _openCloudLogin,
      );
    }
    // 小程序：与短剧首页内层页签是同一个首页（抽屉里的小程序
    // 入口已移到这里），不依赖片库站源，同样放空态判断之前。
    if (_miniAppRequested) {
      return const MiniAppHomePage();
    }
    // 我的：与短剧首页内层页签是同一个共享页。
    if (_mineRequested) {
      return MinePage(
        repository: widget.repository,
        store: widget.store,
        sourceLabel: '${_group.name} (${_group.sources.length})',
        onOpenDrama: _openDrama,
        onOpenSaved: _openSaved,
        onSettingsPressed: _openZoneSettings,
      );
    }
    if (_librarySources.isEmpty) {
      return _noSourcesPanel();
    }
    final catalog = _catalog(selectionInBody: desktop || television);
    if (!neonStyleActive || television) return catalog;
    // 霓虹风格下，内容区（片库目录）铺同一套氛围光，
    // 与抽屉共用 NeonBackdrop.app 这一份定义，不再只有首页和频道页
    // 是霓虹、点播区还是原来的纯色底。
    return NeonBackdrop.app(child: catalog);
  }

  Widget _breadcrumbBar() {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            tooltip: '返回上一级',
            onPressed: () => _drillTo(_drillStack.length - 1),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ActionChip(
                    label: const Text('全部'),
                    onPressed: () => _drillTo(0),
                  ),
                  for (var i = 0; i < _drillStack.length; i++) ...[
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                    ActionChip(
                      label: Text(_drillStack[i].name),
                      onPressed: () => _drillTo(i + 1),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _catalog({required bool selectionInBody}) {
    final items = _visible;
    final television = AppLayout.isTelevision(context);
    // 左侧分类主题（第 9 套）专属布局：只在手机/平板目录主面生效；
    // 电视遥控路径、推荐屏、内容档缺失空态仍走原路径，一字不动。
    final leftCategoryLayout =
        widget.store.appTheme == AppThemeMode.leftCategories &&
        !television &&
        !_showRecommendations &&
        !_tierMissing;
    return Column(
      children: [
        if (_searchVisible && !television)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: SearchInput(
                    key: ValueKey('search-${_group.id}'),
                    controller: _search,
                    autofocus: true,
                    hint: _searchHint,
                    suggestions: _searchSuggestions
                        ? widget.repository.suggestions
                        : null,
                    onChanged: _searchChanged,
                    onCancel: () =>
                        unawaited(widget.repository.cancelSuggestions()),
                    onSearch: _submitSearch,
                    crossSource: _crossSourceSearch,
                    onCrossSourceChanged:
                        _crossSourceSearch || _visibleSourceIds.isNotEmpty
                        ? _changeCrossSource
                        : null,
                    crossSourceCount: _visibleSourceIds.length,
                  ),
                ),
                IconButton(
                  key: const ValueKey('global-search'),
                  tooltip: '全局搜索',
                  icon: const Icon(Icons.manage_search_rounded),
                  onPressed: _openGlobalSearch,
                ),
              ],
            ),
          ),
        if (_searchVisible &&
            _search.text.trim().isEmpty &&
            widget.store.recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final query in widget.store.recentSearches)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: const Icon(
                                Icons.history_rounded,
                                size: 16,
                              ),
                              label: Text(query),
                              onPressed: () => _submitSearch(query),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '清空最近搜索',
                  onPressed: () =>
                      saveUserChange(context, widget.store.clearRecentSearches),
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ],
            ),
          ),
        if (!leftCategoryLayout)
          CatalogFilters(
            key: ValueKey('filters-${_group.id}'),
          remoteKey: _filtersKey,
          onExitDown: television
              ? () => _gridKey.currentState?.focusCurrent()
              : null,
          categories: _displayCategories,
          category: _displayCategory,
          error: _categoriesError,
          onCategory: _changeCategory,
          onRetry: () => _loadCategories(force: true),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_supportsVipFilter)
                IconButton(
                  tooltip: widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
                  onPressed: () => saveUserChange(
                    context,
                    () => widget.store.setHideVip(!widget.store.hideVip),
                  ),
                  icon: VipIcon(hidden: widget.store.hideVip),
                ),
            ],
          ),
        ),
        if (!leftCategoryLayout &&
            !_allSources &&
            _drillStack.isEmpty &&
            _catalogFilters.isNotEmpty &&
            !_showRecommendations)
          television
              ? TvFilterBar(
                  groups: _catalogFilters,
                  selected: _selectedFilters,
                  onSelected: _changeFilter,
                )
              : CatalogFilterRows(
                  groups: _catalogFilters,
                  selected: _selectedFilters,
                  onSelected: _changeFilter,
                ),
        if (!leftCategoryLayout && _drillStack.isNotEmpty) _breadcrumbBar(),
        if (!leftCategoryLayout &&
            _catalogTags.isNotEmpty &&
            !_showRecommendations) ...[
          SizedBox(
            height: compactChipHeight(context),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final tag in _catalogTags)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: CompactFilterChip(
                      key: ValueKey('catalog-tag-${tag.id}'),
                      avatar: const Icon(Icons.label_outline_rounded, size: 11),
                      label: tag.name,
                      selected: false,
                      onSelected: () => _openTag(tag),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (!leftCategoryLayout &&
            _level2Tags.isNotEmpty &&
            !_showRecommendations) ...[
          SizedBox(
            height: compactChipHeight(context),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: CompactFilterChip(
                    label: '全部标签',
                    selected: _tagLevel2 == null,
                    onSelected: () => _selectTagLevel2(null),
                  ),
                ),
                for (final tag in _level2Tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: CompactFilterChip(
                      key: ValueKey('catalog-tag2-$tag'),
                      label: tag,
                      selected: _tagLevel2 == tag,
                      onSelected: () =>
                          _selectTagLevel2(_tagLevel2 == tag ? null : tag),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (!leftCategoryLayout &&
            _tagLevel2 != null &&
            _level3Tags.isNotEmpty &&
            !_showRecommendations) ...[
          SizedBox(
            height: compactChipHeight(context),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: CompactFilterChip(
                    label: '全部',
                    selected: _tagLevel3 == null,
                    onSelected: () => _selectTagLevel3(null),
                  ),
                ),
                for (final tag in _level3Tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: CompactFilterChip(
                      key: ValueKey('catalog-tag3-$tag'),
                      label: tag,
                      selected: _tagLevel3 == tag,
                      onSelected: () =>
                          _selectTagLevel3(_tagLevel3 == tag ? null : tag),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (leftCategoryLayout)
          Expanded(child: _leftCategoryView(items))
        else if (_showRecommendations)
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: RecommendationsScreen(
                repository: widget.repository,
                store: widget.store,
                embedded: true,
                gridKey: _gridKey,
              ),
            ),
          )
        else if (_tierMissing)
          Expanded(child: _tierEmptyPanel())
        else ...[
          if (_loading && _items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: _loading && _items.isEmpty && !_showCarouselStrip
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator.adaptive(),
                          SizedBox(height: 18),
                          Text('正在加载剧集'),
                        ],
                      ),
                    )
                  : _loading && _items.isEmpty && _showCarouselStrip
                  ? Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: ConstrainedBox(
                            // Cap the skeleton height: at full width its
                            // 16:9 ratio would overflow short viewports
                            // while this fixed Column cannot scroll.
                            constraints: BoxConstraints(maxHeight: 220),
                            child: HomeCarouselSkeleton(),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator.adaptive(),
                                SizedBox(height: 18),
                                Text('正在加载剧集'),
                              ],
                            ),
                          ),
                        ),
                      ],
                    )
                  : _items.isEmpty && _error != null
                  ? StatusPanel(
                      title: '暂时无法加载',
                      message: _error!,
                      onRetry: () => _load(force: true),
                      secondaryAction:
                          widget.repository.supportsSourceManagement
                          ? TextButton(
                              onPressed: _manageSources,
                              child: const Text('站源诊断'),
                            )
                          : null,
                      icon: Icons.wifi_off_rounded,
                    )
                  : items.isEmpty
                  ? StatusPanel(
                      title: '没有找到匹配的短剧',
                      message: _hideVip
                          ? '可以换个搜索词，或显示 VIP 内容。'
                          : widget.store.visibleSources.length > 1
                          ? '可以换个搜索词或切换站源。'
                          : '可以换个搜索词，或刷新后重试。',
                      onRetry:
                          _hasMore &&
                              !_loadingMore &&
                              (!_onlineSearch ||
                                  _search.text.isEmpty ||
                                  _group.sources.any(
                                    (source) => source.pagedSearch,
                                  ))
                          ? () => _load(more: true)
                          : null,
                      action: '加载更多',
                      secondaryAction:
                          widget.repository.supportsSourceManagement
                          ? TextButton(
                              onPressed: _manageSources,
                              child: const Text('站源诊断'),
                            )
                          : null,
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        if (television) {
                          return _televisionGrid(
                            items,
                            constraints.maxWidth,
                            controller: _scroll,
                            footer: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                              child: Center(
                                child: _loadingMore
                                    ? const CircularProgressIndicator()
                                    : _hasMore
                                    ? RemoteButton(
                                        label: '加载更多',
                                        icon: Icons.expand_more,
                                        onPressed: () => _load(more: true),
                                      )
                                    : const Text('已经看到这里的全部剧集'),
                              ),
                            ),
                          );
                        }
                        final padding = constraints.maxWidth < 600
                            ? 16.0
                            : 24.0;
                        return RefreshIndicator.adaptive(
                          onRefresh: _refreshCatalog,
                          child: CustomScrollView(
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              if (_showCarouselStrip &&
                                  carouselItems(items).isNotEmpty)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      padding,
                                      4,
                                      padding,
                                      12,
                                    ),
                                    child: HomeCarousel(
                                      key: ValueKey(
                                        'home-carousel-${_group.id}-${_source.id}',
                                      ),
                                      items: carouselItems(items),
                                      repository: widget.repository,
                                      onOpen: (drama) => _openDrama(drama),
                                    ),
                                  ),
                                ),
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  padding,
                                  0,
                                  padding,
                                  16,
                                ),
                                sliver: SliverGrid(
                                  gridDelegate: dramaGridDelegate(
                                    context,
                                    constraints.maxWidth - 2 * padding,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (_, index) => _catalogTile(items[index]),
                                    childCount: items.length,
                                  ),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    bottom:
                                        24 +
                                        MediaQuery.paddingOf(context).bottom,
                                  ),
                                  child: Center(
                                    child: _loadingMore
                                        ? const CircularProgressIndicator.adaptive()
                                        : _hasMore
                                        ? OutlinedButton.icon(
                                            onPressed: () => _load(more: true),
                                            icon: const Icon(
                                              Icons.expand_more_rounded,
                                            ),
                                            label: const Text('加载更多'),
                                          )
                                        : Text(
                                            '已经看到这里的全部剧集',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ],
    );
  }

  /// 左侧分类主题（第 9 套）的目录视图：左一级纵栏 + 右二级/筛选/
  /// 卡堆 + 下方现有网格。分类与筛选点选走 _changeCategory /
  /// _changeFilter，与现有分类行/筛选行同一链路；卡堆数据与首页
  /// 轮播同一条（目录头部有封面的条目），搜索/下钻/多选/多站时隐藏。
  Widget _leftCategoryView(List<Drama> items) {
    final levels = splitCategoryLevels(_displayCategories);
    final stackItems =
        !_allSources &&
            !_searchVisible &&
            _drillStack.isEmpty &&
            !_selectionMode
        ? carouselItems(items)
        : const <Drama>[];
    return LeftCategoryLayout(
      categories: levels.level1,
      selectedCategory: _displayCategory,
      onCategory: _changeCategory,
      subCategories: levels.level2,
      // 筛选行与原路径同口径：只在单站源、非下钻时显示目录自带的筛选组。
      filterGroups: !_allSources && _drillStack.isEmpty
          ? _catalogFilters
          : const <CatalogFilterGroup>[],
      selectedFilters: _selectedFilters,
      onFilter: _changeFilter,
      stackItems: stackItems,
      repository: widget.repository,
      onOpen: _openDrama,
      breadcrumb: _drillStack.isNotEmpty ? _breadcrumbBar() : null,
      catalogTags: _catalogTags,
      onOpenTag: _openTag,
      level2Tags: _level2Tags,
      selectedTagLevel2: _tagLevel2,
      onSelectTagLevel2: _selectTagLevel2,
      level3Tags: _level3Tags,
      selectedTagLevel3: _tagLevel3,
      onSelectTagLevel3: _selectTagLevel3,
      body: _leftCatalogBody(items),
    );
  }

  /// 左侧分类主题的内容区：加载/失败/空态与现有目录同一文案，网格
  /// 复用现有 dramaGridDelegate 与 _catalogTile（DramaTile），不含
  /// 首页轮播（卡堆已在布局中部）与横滑切分类（横滑只翻卡堆）。
  Widget _leftCatalogBody(List<Drama> items) {
    final Widget state;
    if (_loading && _items.isEmpty) {
      state = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator.adaptive(),
            SizedBox(height: 18),
            Text('正在加载剧集'),
          ],
        ),
      );
    } else if (_items.isEmpty && _error != null) {
      state = StatusPanel(
        title: '暂时无法加载',
        message: _error!,
        onRetry: () => _load(force: true),
        secondaryAction: widget.repository.supportsSourceManagement
            ? TextButton(
                onPressed: _manageSources,
                child: const Text('站源诊断'),
              )
            : null,
        icon: Icons.wifi_off_rounded,
      );
    } else if (items.isEmpty) {
      state = StatusPanel(
        title: '没有找到匹配的短剧',
        message: _hideVip
            ? '可以换个搜索词，或显示 VIP 内容。'
            : widget.store.visibleSources.length > 1
            ? '可以换个搜索词或切换站源。'
            : '可以换个搜索词，或刷新后重试。',
        onRetry:
            _hasMore &&
                !_loadingMore &&
                (!_onlineSearch ||
                    _search.text.isEmpty ||
                    _group.sources.any((source) => source.pagedSearch))
            ? () => _load(more: true)
            : null,
        action: '加载更多',
        secondaryAction: widget.repository.supportsSourceManagement
            ? TextButton(
                onPressed: _manageSources,
                child: const Text('站源诊断'),
              )
            : null,
      );
    } else {
      state = LayoutBuilder(
        builder: (context, constraints) {
          final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
          return RefreshIndicator.adaptive(
            onRefresh: _refreshCatalog,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, 16),
                  sliver: SliverGrid(
                    gridDelegate: dramaGridDelegate(
                      context,
                      constraints.maxWidth - 2 * padding,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => _catalogTile(items[index]),
                      childCount: items.length,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: 24 + MediaQuery.paddingOf(context).bottom,
                    ),
                    child: Center(
                      child: _loadingMore
                          ? const CircularProgressIndicator.adaptive()
                          : _hasMore
                          ? OutlinedButton.icon(
                              onPressed: () => _load(more: true),
                              icon: const Icon(Icons.expand_more_rounded),
                              label: const Text('加载更多'),
                            )
                          : Text(
                              '已经看到这里的全部剧集',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
    return Column(
      children: [
        if (_loading && _items.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(child: state),
      ],
    );
  }

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    ScrollController? controller,
    Widget? footer,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: _gridKey,
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      onExitUp: () => _filtersKey.currentState?.focusCurrent(),
      itemBuilder: (_, index, node, onFocus) =>
          _catalogTile(items[index], focusNode: node, onFocus: onFocus),
    );
  }
}
