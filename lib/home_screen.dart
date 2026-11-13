import 'dart:async';

import 'app_page_route.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_layout.dart';
import 'back_history.dart';
import 'liquid_glass.dart';
import 'app_drawer.dart';
import 'neon/neon_ui.dart';
import 'ui_style.dart';
import 'content_zone_binding.dart';
import 'content_zone_screen.dart';
import 'content_models.dart';
import 'player_picker.dart';
import 'app_update_screen.dart';
import 'content_source_screen.dart';
import 'import_center_screen.dart';
import 'parse_settings_screen.dart';
import 'proxy_kernel_screen.dart';
import 'lan_screen.dart';
import 'clearance_bridge.dart';
import 'miniapp/mini_app_home_page.dart';
import 'viewing_experience_screen.dart';
import 'torrent/torrent_home_screen.dart';
import 'rule_editor_screen.dart';

import 'watchroom/room_screen.dart';
import 'app_update.dart';
import 'core_bridge.dart';
import 'catalog_filters.dart';
import 'compact_chip.dart';
import 'tv_filter_bar.dart';
import 'catalog_browser.dart';
import 'catalog_sort.dart';
import 'catalog_sort_sheet.dart';
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

bool shouldSilentRefreshOnRestore(DateTime? fetchedAt, DateTime now) {
  if (fetchedAt == null) return true;
  return now.difference(fetchedAt) >= const Duration(minutes: 5);
}

/// 全局路由观察器：首页订阅它感知“上方路由弹出、首页重新成为当前页”
/// （didPopNext），用于识别返回过渡中的重复投递。MaterialApp 需把它
/// 放进 navigatorObservers；没放时首页收不到事件，退化为无保护的旧行为。
final RouteObserver<ModalRoute<dynamic>> homeRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

typedef _SectionSnapshot = ({
  List<Drama> items,
  List<CatalogTag> tags,
  bool hasMore,
  String? error,
  List<({String folderId, String name, String sourceId})> drillStack,
  SourceSite source,
  bool allSources,
  String category,
  String categoryGroupId,
  String query,
  String submittedQuery,
  bool searchVisible,
  bool crossSource,
  String? categoriesError,
  double scrollOffset,
  String? tagLevel2,
  String? tagLevel3,
  List<CatalogFilterGroup> filters,
  Map<String, String> selectedFilters,
});

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
  late SourceSite _source;
  bool _allSources = false;
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  HomeZone _zone = HomeZone.drama;
  final _zoneHistory = BackHistory<HomeZone>();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String _currentVersion = '';
  String _catalogSection = SourceSite.sectionDrama;
  final _sectionSourceIds = <String, String>{};
  HomeZone _sectionZone = HomeZone.drama;
  final _lastZoneSource = <String, String>{};
  late final ContentZoneBinding _contentBinding;
  final _sectionSnapshots = <String, _SectionSnapshot>{};
  final _sectionFetchedAt = <String, DateTime>{};
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

  bool get _isCatalogZone => _zone == HomeZone.drama || _zone == HomeZone.vod;

  String get _zoneTitle => switch (_zone) {
    HomeZone.vod => '点播',
    HomeZone.live => '直播',
    HomeZone.audio => '听书',
    HomeZone.novel => '阅读',

    _ => appName,
  };

  List<SourceSite> get _sectionSources {
    return [
      for (final site in widget.store.visibleSources)
        if (_zone == HomeZone.vod
            ? isVodZoneSource(site)
            : _catalogSection == SourceSite.sectionVideo
            ? site.isVideoSection || site.origin == SourceSite.originConfig
            : site.isDramaSection && site.origin != SourceSite.originConfig)
          site,
    ];
  }

  List<SourceGroup> get _sourceGroups {
    // 首页只显示「源显示列表」中开启的站源，被隐藏的站源不出现在分组里。
    final visible = _sectionSources;
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
        final visible = _sectionSources;
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
    for (final source in _sectionSources) source.id,
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
  String get _displayCategory =>
      _showRecommendations ? _recommendationCategory : _category;
  List<CatalogCategory> get _displayCategories => [
    CatalogCategory.all,
    if (_group.id == 'hongguo')
      const CatalogCategory(_recommendationCategory, '推荐'),
    ..._categories.where((entry) => entry.id.isNotEmpty),
  ];

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
      _sectionSources.length + (_sourceGroups.length > 1 ? 1 : 0) > 1;

  List<SourcePickerGroup> _sourcePickerGroups() => [
    if (_sourceGroups.length > 1)
      const SourcePickerGroup(
        title: '',
        entries: [SourcePickerEntry(id: _allSourcesEntryId, name: '全部站源')],
      ),
    for (final group in SourceGroup.sectionGroups(_sectionSources))
      if ((_catalogSection == SourceSite.sectionVideo
          ? group.id != 'builtin:drama'
          : group.id != 'builtin:video'))
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

  String _sourcePickerSectionName() =>
      _catalogSection == SourceSite.sectionVideo ? '点播' : '短剧';

  Future<void> _pickSource({bool editMode = false}) async {
    final picked = await showSitePickerDialog(
      context,
      sectionName: _sourcePickerSectionName(),
      currentId: _allSources ? _allSourcesEntryId : _source.id,
      groups: _sourcePickerGroups(),
      initialEditMode: editMode,
      onDeleteSite: _deleteSourceEntry,
    );
    if (picked == null || !mounted) return;
    _applySourcePick(picked);
  }

  Future<void> _pickSourceCentered() async {
    final picked = await showSitePickerDialog(
      context,
      sectionName: _sourcePickerSectionName(),
      currentId: _allSources ? _allSourcesEntryId : _source.id,
      groups: _sourcePickerGroups(),
      onDeleteSite: _deleteSourceEntry,
    );
    if (picked == null || !mounted) return;
    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      Navigator.of(context).pop();
    }
    _applySourcePick(picked);
  }

  Future<bool> _deleteSourceEntry(SourcePickerEntry entry) async {
    if (entry.id == _allSourcesEntryId) return false;
    if (_sectionSources.length <= 1 &&
        _sectionSources.any((site) => site.id == entry.id)) {
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
    final site = _sectionSources
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
    if (!_allSources && _source.id == id && _sectionSources.isNotEmpty) {
      _changeSource(_sectionSources.first);
    } else if (mounted) {
      setState(() {});
    }
  }

  void _applySourcePick(String picked) {
    if (picked == _allSourcesEntryId) {
      _changeGroup(_sourceGroups.firstWhere((group) => group.id == 'all'));
      return;
    }
    final site = _sectionSources.where((site) => site.id == picked).firstOrNull;
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

  void _saveSectionSnapshot() {
    _sectionSnapshots[_catalogSection] = (
      items: List.of(_items),
      tags: List.of(_catalogTags),
      hasMore: _hasMore,
      error: _error,
      drillStack: List.of(_drillStack),
      source: _source,
      allSources: _allSources,
      category: _category,
      categoryGroupId: _group.id,
      query: _search.text,
      submittedQuery: _submittedQuery,
      searchVisible: _searchVisible,
      crossSource: _crossSourceSearch,
      categoriesError: _categoriesError,
      scrollOffset: _scroll.hasClients ? _scroll.offset : 0,
      tagLevel2: _tagLevel2,
      tagLevel3: _tagLevel3,
      filters: List.of(_catalogFilters),
      selectedFilters: Map.of(_selectedFilters),
    );
  }

  void _restoreSectionSnapshot(String section, _SectionSnapshot snapshot) {
    setState(() {
      _catalogSection = section;
      _drillStack
        ..clear()
        ..addAll(snapshot.drillStack);
      _catalogTags = List.of(snapshot.tags);
      _catalogFilters = List.of(snapshot.filters);
      _selectedFilters
        ..clear()
        ..addAll(snapshot.selectedFilters);
      _tagLevel2 = snapshot.tagLevel2;
      _tagLevel3 = snapshot.tagLevel3;
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _search.text = snapshot.query;
      _submittedQuery = snapshot.submittedQuery;
      _searchVisible = snapshot.searchVisible;
      _crossSourceSearch = snapshot.crossSource;
      _items = List.of(snapshot.items);
      _hasMore = snapshot.hasMore;
      _error = snapshot.error;
      _loading = false;
      _loadingMore = false;
      _categoriesLoading = false;
      _categoriesError = snapshot.categoriesError;
      _source = snapshot.source;
      _allSources = snapshot.allSources;
      _categorySelections[_categoryKey(snapshot.categoryGroupId)] =
          snapshot.category;
    });
    final offset = snapshot.scrollOffset;
    if (offset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final target = offset.clamp(0.0, _scroll.position.maxScrollExtent);
        if (_scroll.offset != target) _scroll.jumpTo(target);
      });
    }
    if (_sectionSources.isNotEmpty &&
        shouldSilentRefreshOnRestore(
          _sectionFetchedAt[section],
          DateTime.now(),
        )) {
      unawaited(_load(silent: true));
    }
  }

  void _changeSection(String section) {
    final sameSection = _catalogSection == section;
    if (sameSection && _sectionZone == _zone) return;
    _sectionSourceIds[_catalogSection] = _source.id;
    _pauseCatalog();
    _resetAutoLoad();
    if (!sameSection) {
      _saveSectionSnapshot();
      final snapshot = _sectionSnapshots[section];
      if (snapshot != null) {
        _restoreSectionSnapshot(section, snapshot);
        _sectionZone = _zone;
        return;
      }
    }
    final remembered = _rememberedForCurrentZone();
    final sectionRemembered = _sectionSourceIds[section];
    setState(() {
      _catalogSection = section;
      _sectionZone = _zone;
      _drillStack.clear();
      _catalogTags = const [];
      _catalogFilters = const [];
      _selectedFilters.clear();
      _tagLevel2 = null;
      _tagLevel3 = null;
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _search.clear();
      _submittedQuery = '';
      _items = [];
      _hasMore = true;
      _error = null;
      final candidates = _sectionSources;
      if (candidates.isNotEmpty) {
        if (remembered != null) {
          _source = remembered.site;
          _allSources = remembered.allSources;
        } else {
          final site = sectionRemembered == null
              ? null
              : candidates
                    .where((site) => site.id == sectionRemembered)
                    .firstOrNull;
          if (site != null) {
            _source = site;
            _allSources = false;
          } else if (!candidates.any((site) => site.id == _source.id)) {
            _source = candidates.first;
            _allSources = false;
          }
        }
      }
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (_sectionSources.isNotEmpty) {
      unawaited(_loadWithAutoRetry(useCache: true));
      _loadCategories();
    } else {
      setState(() => _loading = false);
    }
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
    Navigator.of(context).push(
      appPageRoute(
        builder: (_) => const WebScrapePage(),
      ),
    );
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
          sourceIds: _zone == HomeZone.drama ? null : _visibleSourceIds.toSet(),
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
        _setZone(site.isDramaSection ? HomeZone.drama : HomeZone.vod);
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
    } else if (_zone != HomeZone.drama) {
      _applyZoneChange(HomeZone.drama);
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
    _catalogSection = SourceSite.sectionDrama;
    _zone = HomeZone.drama;
    _allSources = widget.store.catalogView.allSources;
    if (_sectionSources.isNotEmpty) {
      final remembered = _rememberedForCurrentZone();
      if (remembered != null) {
        _source = remembered.site;
        _allSources = remembered.allSources;
      } else if (!_sectionSources.any((site) => site.id == _source.id)) {
        _source = _sectionSources.first;
        _allSources = false;
        _sectionSourceIds[_catalogSection] = _source.id;
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
    if (_sectionSources.isNotEmpty) {
      unawaited(_loadWithAutoRetry(useCache: !_firstLaunch));
      _loadCategories();
    } else {
      _loading = false;
    }
    unawaited(_loadCurrentVersion());
    unawaited(ensureDramaUiStyleLoaded());
  }

  @override
  void dispose() {
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
    if (_sectionSources.isEmpty) return;
    _autoLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoLoadScheduled = false;
      if (!mounted || _loading || _loadingMore || _showRecommendations) return;
      if (_items.isNotEmpty || _sectionSources.isEmpty) return;
      _autoLoadedOnce = true;
      unawaited(_loadWithAutoRetry(useCache: true));
    });
  }

  void _resetAutoLoad() {
    _autoLoadedOnce = false;
  }

  /// 首屏 / 切板块时的自动加载。
  ///
  /// 只读缓存的话，装完第一次打开、缓存为空、或者内核刚起来第一次请求落空时，
  /// 列表会一直是空的，得用户手动下拉才出内容。这里补成：
  /// 缓存读完还是空 → 立刻拉一次线上；还空 → 隔 1.5 秒再补一次。
  Future<void> _loadWithAutoRetry({bool useCache = false}) async {
    await (useCache ? _load(useCache: true) : _load(force: true));
    if (!mounted) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_loading || _loadingMore || _showRecommendations) return;
      if (_items.isNotEmpty || _error != null) return;
      if (_sectionSources.isEmpty) return;
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
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
        _sectionFetchedAt[_catalogSection] = DateTime.now();
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
    final candidates = _sectionSources;
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
    setState(() {
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
    _load(force: true);
    _loadCategories(force: true);
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
    if (vodOpenAction(isVodZone: _zone == HomeZone.vod, resume: resume) ==
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
    final zone = isVodZoneSource(site) ? HomeZone.vod : HomeZone.drama;
    if (zone != _zone) _setZone(zone);
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
    final zone = isVodZoneSource(site) ? HomeZone.vod : HomeZone.drama;
    if (zone == _zone && (_allSources || site.id == _source.id)) {
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

  void _applyZoneChange(HomeZone zone, {bool recordHistory = false}) {
    if (recordHistory && zone != _zone) _zoneHistory.push(_zone);
    _resetAutoLoad();
    setState(() {
      _zone = zone;
      _selectionMode = false;
      _selectedDramas.clear();
    });
    if (zone == HomeZone.drama) {
      _changeSection(SourceSite.sectionDrama);
    } else if (zone == HomeZone.vod) {
      _changeSection(SourceSite.sectionVideo);
    }
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
  }

  bool get _settlingAfterPop => _justReturned;

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  Widget _drawerAvatarButton() => IconButton(
    key: const ValueKey('open-app-drawer'),
    tooltip: '导航',
    iconSize: 32,
    padding: const EdgeInsets.all(8),
    onPressed: _openDrawer,
    icon: ClipOval(
      child: Image.asset(
        'assets/ant_logo.png',
        width: 32,
        height: 32,
        fit: BoxFit.cover,
      ),
    ),
  );

  Widget _appBarLeading() {
    final button = _drawerAvatarButton();
    if (!_isCatalogZone || _selectionMode) return button;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(width: 4),
        Flexible(
          child: SiteSourceBox(
            key: const ValueKey('drawer-site-box'),
            label: '${_group.name} (${_group.sources.length})',
            onTap: () => unawaited(_pickSourceCentered()),
          ),
        ),
      ],
    );
  }

  AppDrawer _drawer() => AppDrawer(
    zone: _zone,
    currentVersion: _currentVersion,
    onZoneSelected: _onZoneSelected,
    onWatchRoom: _onWatchRoom,
    onTool: _onTool,
    onMinorProtectionChanged: _onMinorProtectionChanged,
  );

  void _openZoneSettings() {
    if (_zone == HomeZone.drama ||
        _zone == HomeZone.vod ||
        _zone == HomeZone.live) {
      _pushTool(
        ZoneSettingsScreen(
          repository: widget.repository,
          store: widget.store,
          zone: _zone,
          onHideAdult: () => unawaited(_onMinorProtectionChanged(true)),
        ),
      );
    } else {
      _openSettings();
    }
  }

  void _openSettings() {
    _pushTool(
      SettingsScreen(repository: widget.repository, store: widget.store),
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
    HomeZone.drama => 0,
    HomeZone.vod => 1,
    HomeZone.live => 2,
    _ => null,
  };

  void _onRailSelected(int index) {
    switch (index) {
      case 0:
        _setZone(HomeZone.drama);
      case 1:
        _setZone(HomeZone.vod);
      case 2:
        _setZone(HomeZone.live);
      default:
        _openDrawer();
    }
  }

  void _onZoneSelected(HomeZone zone) {
    Navigator.of(context).pop();
    _setZone(zone);
  }

  void _onWatchRoom() {
    Navigator.of(context).pop();
    unawaited(
      Navigator.of(context).push<void>(
        appPageRoute<void>(
          builder: (_) => WatchRoomScreen(
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      ),
    );
  }

  void _openFullscreenFeed() {
    if (_visible.isEmpty) return;
    _pauseCatalog();
    unawaited(
      Navigator.of(context).push<void>(
        appPageRoute<void>(
          builder: (_) => FullscreenFeedScreen(
            dramas: List.of(_visible),
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      ),
    );
  }

  void _onTool(AppDrawerTool tool) {
    Navigator.of(context).pop();
    switch (tool) {
      case AppDrawerTool.clearance:
        unawaited(openClearanceFlow(context, widget.repository));
      case AppDrawerTool.lanSync:
        openLanSync(context);
      case AppDrawerTool.sources:
        _pushTool(
          SourcesScreen(repository: widget.repository, store: widget.store),
        );
      case AppDrawerTool.settings:
        _openSettings();
      case AppDrawerTool.player:
        _pushTool(PlayerPickerScreen(store: widget.store));
      case AppDrawerTool.appUpdate:
        _pushTool(const AppUpdateScreen());
      case AppDrawerTool.importCenter:
        _pushTool(
          ImportCenterScreen(
            repository: widget.repository,
            store: widget.store,
          ),
        );
      case AppDrawerTool.contentSources:
        _pushTool(
          ContentSourceScreen(
            repository: widget.repository,
            store: widget.store,
          ),
        );
      case AppDrawerTool.parse:
        _pushTool(const ParseSettingsScreen());
      case AppDrawerTool.proxyKernel:
        _pushTool(ProxyKernelScreen(repository: widget.repository));
      case AppDrawerTool.ruleEditor:
        _pushTool(RuleEditorScreen(repository: widget.repository));
      case AppDrawerTool.miniApp:
        _pushTool(const MiniAppHomePage());
      case AppDrawerTool.viewingExperience:
        _pushTool(ViewingExperienceScreen(store: widget.store));
      case AppDrawerTool.torrent:
        _pushTool(
          TorrentHomePage(repository: widget.repository, store: widget.store),
        );
    }
  }

  void _pushTool(Widget screen) {
    unawaited(
      Navigator.of(
        context,
      ).push<void>(appPageRoute<void>(builder: (_) => screen)),
    );
  }

  /// 未成年保护（与火蚁TV现行做法一致的一次性动作，无持久开关）：
  /// 点按后离开统一视频区、回到短剧区；下次再进点播区仍可见成人站，
  /// 与火蚁TV点按后离开午夜区、下次仍可再进午夜区的语义相同。
  Future<void> _onMinorProtectionChanged(bool enabled) async {
    if (!enabled) return;
    if (_zone == HomeZone.vod) {
      _applyZoneChange(HomeZone.drama);
    }
  }

  Future<void> _loadCurrentVersion() async {
    try {
      final current = await AppUpdateChecker.currentVersion();
      if (mounted) setState(() => _currentVersion = current.toString());
    } catch (_) {}
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

  Widget _sourceDropdownBox() {
    final colors = Theme.of(context).colorScheme;
    return GlassTapTarget(
      key: const ValueKey('source-dropdown'),
      onTap: _canSwitchSource ? () => unawaited(_pickSource()) : null,
      onLongPress: _canSwitchSource
          ? () => unawaited(_pickSource(editMode: true))
          : null,
      child: SizedBox(
        height: 44,
        child: LiquidGlass(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    '${_group.name} (${_group.sources.length})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_canSwitchSource) ...[
                  const SizedBox(width: 4),
                  Icon(
                    LucideIcons.chevronDown,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
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
    final catalog = _isCatalogZone && !_selectionMode;
    final customView =
        widget.store.catalogView.sort != CatalogSort.source ||
        widget.store.catalogView.release.isNotEmpty;
    final updating = _group.sources.any((source) => _updater.busy(source.id));
    final Widget title;
    if (_selectionMode) {
      title = Text('选择短剧', style: largeTitle);
    } else if (_isCatalogZone) {
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
    return AppBar(
      toolbarHeight: 64,
      centerTitle: false,
      titleSpacing: 20,
      automaticallyImplyLeading: false,
      leadingWidth: _isCatalogZone && !_selectionMode ? 192 : null,
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
            if (wide) ...[_sourceDropdownBox(), const SizedBox(width: 8)],
            GlassButtonGroup(
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
                if (_zone == HomeZone.drama)
                  GlassGroupItem(
                    key: const ValueKey('open-fullscreen-feed'),
                    icon: LucideIcons.play,
                    tooltip: '全屏流',
                    onPressed: _visible.isEmpty ? null : _openFullscreenFeed,
                  ),
                GlassGroupItem(
                  key: const ValueKey('toggle-search'),
                  icon: _searchVisible
                      ? LucideIcons.searchX
                      : LucideIcons.search,
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
            ),
            const SizedBox(width: 8),
          ],
          if (!AppLayout.isTelevision(context) &&
              (_isCatalogZone || _zone == HomeZone.live) &&
              (_zone != HomeZone.drama || wide))
            GlassIconButton(
              key: const ValueKey('open-settings'),
              icon: LucideIcons.settings,
              tooltip: '设置',
              onPressed: _openZoneSettings,
            ),
        ],
        const SizedBox(width: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      _scheduleAutoLoad();
      return LayoutBuilder(
        builder: (context, constraints) {
          final television = AppLayout.isTelevision(context);
          final glass = glassDesign(context);
          final desktop =
              Theme.of(context).platform != TargetPlatform.iOS &&
              constraints.maxWidth >= 840;
          if (!television &&
              !desktop &&
              !_selectionMode &&
              _zone == HomeZone.drama) {
            if (isHongguoDramaGroup(_group.id)) {
              return Scaffold(
                key: _scaffoldKey,
                drawer: _drawer(),
                extendBody: glass,
                body: SafeArea(
                  bottom: !glass,
                  child: HongguoDramaHome(
                    dramas: List.of(_visible),
                    repository: widget.repository,
                    store: widget.store,
                    onOpenDrama: _openDrama,
                    onOpenFeed: _openFullscreenFeed,
                    onPickSource: () => unawaited(_pickSource()),
                    sourceLabel: '${_group.name} (${_group.sources.length})',
                    feedEnabled: _visible.isNotEmpty,
                    categories: _displayCategories,
                    selectedCategory: _displayCategory,
                    onCategorySelected: _changeCategory,
                    searchController: _search,
                    searchHint: _searchHint,
                    onSearchChanged: _searchChanged,
                    onSearchSubmitted: _submitSearch,
                    onOpenGlobalSearch: _openGlobalSearch,
                    onMenuPressed: _openDrawer,
                    onFilterPressed: () => unawaited(_chooseCatalogView()),
                    onRankingsPressed: _openRankings,
                    onNewPressed: _toggleNewSort,
                    filtersActive:
                        widget.store.catalogView.sort != CatalogSort.source ||
                        widget.store.catalogView.release.isNotEmpty,
                    newActive:
                        widget.store.catalogView.sort == CatalogSort.date,
                    onOpenSaved: _openSaved,
                    onSettingsPressed: _openZoneSettings,
                    onOpenFeatured: _openFeaturedDrama,
                  ),
                ),
              );
            }
          }
          final scaffold = Scaffold(
            key: _scaffoldKey,
            drawer: _drawer(),
            extendBody: glass && !desktop,
            appBar: glass
                ? _glassAppBar()
                : AppBar(
                    toolbarHeight: television ? 64 : null,
                    titleSpacing: 12,
                    automaticallyImplyLeading: false,
                    leadingWidth: _isCatalogZone && !_selectionMode
                        ? 192
                        : null,
                    leading: _appBarLeading(),
                    title: _selectionMode
                        ? const Text(
                            '选择短剧',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : _isCatalogZone
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
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
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
                        if (_isCatalogZone) ...[
                          if (!_showRecommendations)
                            IconButton(
                              tooltip:
                                  '排序与筛选 · ${widget.store.catalogView.sort.label}',
                              onPressed: _chooseCatalogView,
                              color:
                                  widget.store.catalogView.sort !=
                                          CatalogSort.source ||
                                      widget
                                          .store
                                          .catalogView
                                          .release
                                          .isNotEmpty
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                              icon: const Icon(Icons.sort_rounded),
                            ),
                          IconButton(
                            key: const ValueKey('open-rankings'),
                            tooltip: '榜单',
                            onPressed: widget.store.visibleSources.isEmpty
                                ? null
                                : _openRankings,
                            icon: const Icon(Icons.leaderboard_outlined),
                          ),
                          if (_zone == HomeZone.drama)
                            IconButton(
                              key: const ValueKey('open-fullscreen-feed'),
                              tooltip: '全屏流',
                              onPressed: _visible.isEmpty
                                  ? null
                                  : _openFullscreenFeed,
                              icon: const Icon(Icons.play_arrow_rounded),
                            ),
                          if ((_isCatalogZone || _zone == HomeZone.live) &&
                              !television)
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
                              _searchVisible
                                  ? Icons.search_off_rounded
                                  : Icons.search_rounded,
                            ),
                            onPressed: _toggleSearch,
                          ),
                          IconButton(
                            key: const ValueKey('web-scrape'),
                            tooltip: '网页爬取',
                            icon: const Icon(
                              Icons.travel_explore_rounded,
                            ),
                            onPressed: _openWebScrape,
                          ),
                        ],
                        if (_isCatalogZone &&
                            !_showRecommendations &&
                            constraints.maxWidth >= 400)
                          RefreshAction(
                            key: const ValueKey('catalog-refresh'),
                            loading: _catalogBusy,
                            tooltip: '更新剧库',
                            onPressed: widget.store.visibleSources.isEmpty
                                ? null
                                : _refreshCatalog,
                          ),
                        if (_isCatalogZone &&
                            !_showRecommendations &&
                            constraints.maxWidth < 400)
                          IconButton(
                            tooltip: '更新剧库',
                            onPressed: widget.store.visibleSources.isEmpty
                                ? null
                                : _refreshCatalog,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        if (_isCatalogZone)
                          OutlinedButton.icon(
                            key: const ValueKey('source-dropdown'),
                            onPressed: _canSwitchSource
                                ? () => unawaited(_pickSource())
                                : null,
                            icon: const Icon(
                              Icons.expand_more_rounded,
                              size: 18,
                            ),
                            label: Text(
                              '${_group.name} (${_group.sources.length})',
                            ),
                          ),
                      ],
                      const SizedBox(width: 8),
                    ],
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
                        itemKeys: const ['drama', 'video', 'live', 'settings'],
                        itemExtent: 64,
                        spacing: 14,
                        padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                        autofocus: true,
                        itemBuilder: (_, index, node, onFocus) {
                          final entries = [
                            (Icons.movie_rounded, '短剧'),
                            (Icons.video_library_rounded, '影视'),
                            (Icons.live_tv_rounded, '直播'),
                            (Icons.settings_rounded, '设置'),
                          ];
                          final entry = entries[index];
                          final selected = switch (index) {
                            0 => _zone == HomeZone.drama,
                            1 => _zone == HomeZone.vod,
                            2 => _zone == HomeZone.live,
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
                                  _setZone(HomeZone.drama);
                                case 1:
                                  _setZone(HomeZone.vod);
                                case 2:
                                  _setZone(HomeZone.live);
                                default:
                                  _openDrawer();
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
                          icon: Icon(Icons.movie_outlined),
                          selectedIcon: Icon(Icons.movie),
                          label: Text('短剧'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.video_library_outlined),
                          selectedIcon: Icon(Icons.video_library),
                          label: Text('影视'),
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
                  // 否则点播播完返回会落到短剧区。落定后的返回照常退区。
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

  Widget _tabBody({required bool television, required bool desktop}) {
    if (_zone == HomeZone.live) {
      return LiveScreen(
        repository: _liveRepository,
        store: _liveStore,
        greenMode: false,
        onExitLeft: () => _navKey.currentState?.focusCurrent(),
        appStore: widget.store,
      );
    }
    if (_zone == HomeZone.audio) {
      return ContentZoneScreen(
        section: ContentSection.audio,
        binding: _contentBinding,
      );
    }
    if (_zone == HomeZone.novel) {
      return ContentZoneScreen(
        section: ContentSection.novel,
        binding: _contentBinding,
      );
    }
    if (_sectionSources.isEmpty) {
      return StatusPanel(
        title: _zone == HomeZone.vod
            ? '暂无显示中的点播站源'
            : _catalogSection == SourceSite.sectionVideo
            ? '暂无显示中的点播站源'
            : '暂无显示中的站源',
        message: widget.store.sources.isEmpty
            ? '请联系管理员为当前用户开放站源。'
            : '所有站源已在「源显示列表」中关闭，请到站源管理中重新开启。',
      );
    }
    final catalog = _catalog(selectionInBody: desktop || television);
    if (!neonStyleActive || television) return catalog;
    // 霓虹风格下，内容区（点播 / 短剧目录）铺同一套氛围光，
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
        if (!_allSources &&
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
        if (_drillStack.isNotEmpty) _breadcrumbBar(),
        if (_catalogTags.isNotEmpty && !_showRecommendations) ...[
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
        if (_level2Tags.isNotEmpty && !_showRecommendations) ...[
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
        if (_tagLevel2 != null &&
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
        if (_showRecommendations)
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
