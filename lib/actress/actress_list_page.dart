import 'dart:async';

import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_detail_page.dart';
import 'actress_models.dart';
import 'actress_ranking_page.dart';
import 'actress_roster_sources.dart';
import 'actress_search.dart';
import 'actress_stacking.dart';
import 'actress_sync.dart';
import 'actress_widgets.dart';
import '../content_http.dart';
import '../core_bridge.dart';
import '../local_store.dart';

/// 女优库浏览页：人物列表 + 搜索/性别筛选/排序 + 同步横幅。
///
/// 打开只读本地库；库空时自动开始一次全量同步（进度显示、可取消、
/// 断点续跑），之后只手动刷新、不自动重拉。排行榜入口在顶栏奖杯钮。
/// 全站叠加入口在同步横幅下方：手动开始/继续，按番号把各站作品
/// 叠加进库，断点续跑，不自动跑、不与名册同步抢着跑。
class ActressListPage extends StatefulWidget {
  const ActressListPage({
    super.key,
    required this.repository,
    required this.store,
    this.database,
    this.syncService,
    this.stackingService,
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

  @override
  State<ActressListPage> createState() => _ActressListPageState();
}

class _ActressListPageState extends State<ActressListPage> {
  static const _pageSize = 60;
  // 自动续跑预算：一次进页最多自动起 3 次（含首次自动开始），每次间隔
  // 2 秒；跑完仍未完且预算用尽时只等手动点，不无限循环。
  static const _maxAutoSyncRuns = 3;
  static const _autoSyncRetryDelay = Duration(seconds: 2);

  late final ActressDatabase _db;
  late final ActressSyncService _sync;
  late final ActressStackingService _stacking;
  ContentHttp? _http;
  StreamSubscription<ActressSyncProgress>? _progressSub;
  StreamSubscription<ActressStackingProgress>? _stackingSub;

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
  var _query = '';
  var _generation = 0;

  ActressSyncProgress _progress = ActressSyncProgress.idle;
  ActressStackingProgress _stackingProgress = ActressStackingProgress.idle;
  ActressSyncOverview? _overview;
  var _lastSyncFailed = false;
  var _autoSyncStarted = false;
  Timer? _autoSyncTimer;
  var _autoSyncRuns = 0;

  @override
  void initState() {
    super.initState();
    _db = widget.database ?? SqfliteActressDatabase.instance;
    if (widget.syncService != null) {
      _sync = widget.syncService!;
    } else {
      _http = ContentHttp();
      _sync = ActressSyncService(
        db: _db,
        sources: [
          ChaoliuRosterSource(),
          WhosRosterSource(),
          MissavRosterSource(),
        ],
        fetch: actressDefaultFetch(_http!),
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
    _bootstrap();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _stackingSub?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    _autoSyncTimer?.cancel();
    _sync.cancel();
    _sync.dispose();
    _stacking.cancel();
    _stacking.dispose();
    _http?.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    final overview = await _db.overview();
    if (!mounted || generation != _generation) return;
    setState(() => _overview = overview);
    // 叠加只读一次断点作横幅状态，绝不自动跑。
    final stacking = await _stacking.snapshot();
    if (!mounted || generation != _generation) return;
    setState(() => _stackingProgress = stacking);
    // _loadPage(reset) 会推进代次，这里只判 mounted，不再比代次。
    await _loadPage(reset: true);
    if (!mounted) return;
    // 库空、或已有数据但没同步完，都自动开始一次断点续跑，不等手动点。
    if (!_autoSyncStarted &&
        (overview.persons == 0 || !overview.allDone) &&
        !_sync.isRunning) {
      _autoSyncStarted = true;
      _autoSyncRuns = 1;
      unawaited(_runSync());
    }
  }

  void _onProgress(ActressSyncProgress progress) {
    if (!mounted) return;
    setState(() => _progress = progress);
    if (!progress.running && progress.phase == 'done') {
      unawaited(_refreshAfterSync());
    }
  }

  void _onStackingProgress(ActressStackingProgress progress) {
    if (!mounted) return;
    setState(() => _stackingProgress = progress);
    if (!progress.running) {
      // 叠加写库刷新了 works_count：总览与列表都要重读才显示真数。
      unawaited(_refreshAfterSync());
    }
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
  }

  /// 只断点续跑：永远不从头重拉（refresh 恒为 false）。跑完仍没同步完、
  /// 且没被取消、且自动预算还有剩时，2 秒后自动再续一次；手动点的那
  /// 次跑完也一样续。预算用尽后只等手动点。
  Future<void> _runSync() async {
    _autoSyncTimer?.cancel();
    if (_sync.isRunning) return;
    setState(() => _lastSyncFailed = false);
    final result = await _sync.run(refresh: false);
    if (!mounted) return;
    setState(() => _lastSyncFailed = result.hasFailures);
    final overview = await _db.overview();
    if (!mounted) return;
    setState(() => _overview = overview);
    if (result.cancelled ||
        overview.allDone ||
        _autoSyncRuns >= _maxAutoSyncRuns) {
      return;
    }
    _autoSyncTimer = Timer(_autoSyncRetryDelay, () {
      if (!mounted || _sync.isRunning) return;
      _autoSyncRuns++;
      unawaited(_runSync());
    });
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

  Future<void> _loadPage({bool reset = false}) async {
    if (reset) {
      final generation = ++_generation;
      setState(() {
        _loading = true;
        _persons = [];
        _hasMore = true;
      });
      final persons = await _db.listPersons(
        sex: _sex,
        sort: _sort,
        query: _query,
        tag: _tagFilter.tagValue,
        offset: 0,
        limit: _pageSize,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _persons = persons;
        _hasMore = persons.length >= _pageSize;
        _loading = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final persons = await _db.listPersons(
      sex: _sex,
      sort: _sort,
      query: _query,
      tag: _tagFilter.tagValue,
      offset: _persons.length,
      limit: _pageSize,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _persons = [..._persons, ...persons];
      _hasMore = persons.length >= _pageSize;
      _loadingMore = false;
    });
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final overview = _overview;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: widget.showTitle
            ? Text(
                overview == null
                    ? '演员库'
                    : '演员库 ${overview.persons} 位演员',
              )
            : overview == null
            ? null
            : Text('${overview.persons} 位演员'),
        actions: [
          IconButton(
            key: const ValueKey('open-actress-ranking'),
            tooltip: '演员排行榜',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.emoji_events_outlined),
            onPressed: _openRanking,
          ),
          IconButton(
            key: const ValueKey('refresh-actress-library'),
            tooltip: '刷新同步',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _progress.running ? null : () => _runSync(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSyncBanner(colors),
          _buildStackingBanner(colors),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
            child: TextField(
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
                  ],
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sort_rounded, size: 18),
                      const SizedBox(width: 4),
                      Text(_sort == ActressSort.worksDesc ? '按作品数' : '按名字'),
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
          Expanded(child: _buildList(colors)),
        ],
      ),
    );
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

  Widget _buildSyncBanner(ColorScheme colors) {
    final overview = _overview;
    if (_progress.running) {
      final detail = _progress.total > 0
          ? '${_progress.done}/${_progress.total}'
          : '第 ${_progress.done} 页';
      return MaterialBanner(
        backgroundColor: colors.surfaceContainerHigh,
        padding: const EdgeInsetsDirectional.only(start: 16, top: 2, end: 4, bottom: 2),
        content: Row(
          children: [
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${_progress.phaseLabel}（${_progress.sourceIndex}/${_progress.sourceCount}）· $detail',
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_persons.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty ? '暂无人物' : '没有找到“$_query”',
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
