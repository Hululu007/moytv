import 'dart:async';

import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_detail_page.dart';
import 'actress_models.dart';
import 'actress_ranking_page.dart';
import 'actress_roster_sources.dart';
import 'actress_sync.dart';
import 'actress_widgets.dart';
import '../content_http.dart';
import '../core_bridge.dart';
import '../local_store.dart';

/// 女优库浏览页：人物列表 + 搜索/性别筛选/排序 + 同步横幅。
///
/// 打开只读本地库；库空时自动开始一次全量同步（进度显示、可取消、
/// 断点续跑），之后只手动刷新、不自动重拉。排行榜入口在顶栏奖杯钮。
class ActressListPage extends StatefulWidget {
  const ActressListPage({
    super.key,
    required this.repository,
    required this.store,
    this.database,
    this.syncService,
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

  @override
  State<ActressListPage> createState() => _ActressListPageState();
}

class _ActressListPageState extends State<ActressListPage> {
  static const _pageSize = 60;

  late final ActressDatabase _db;
  late final ActressSyncService _sync;
  ContentHttp? _http;
  StreamSubscription<ActressSyncProgress>? _progressSub;

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
  ActressSyncOverview? _overview;
  var _lastSyncFailed = false;
  var _autoSyncStarted = false;

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
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    _sync.cancel();
    _sync.dispose();
    _http?.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    final overview = await _db.overview();
    if (!mounted || generation != _generation) return;
    setState(() => _overview = overview);
    // _loadPage(reset) 会推进代次，这里只判 mounted，不再比代次。
    await _loadPage(reset: true);
    if (!mounted) return;
    // 库空时自动开始一次全量同步；已有数据（哪怕没同步完）只手动续跑，
    // 不自动重拉。
    if (!_autoSyncStarted && overview.persons == 0 && !_sync.isRunning) {
      _autoSyncStarted = true;
      unawaited(_runSync(refresh: false));
    }
  }

  void _onProgress(ActressSyncProgress progress) {
    if (!mounted) return;
    setState(() => _progress = progress);
    if (!progress.running && progress.phase == 'done') {
      unawaited(_refreshAfterSync());
    }
  }

  Future<void> _refreshAfterSync() async {
    final overview = await _db.overview();
    if (!mounted) return;
    setState(() => _overview = overview);
    await _loadPage(reset: true);
  }

  Future<void> _runSync({required bool refresh}) async {
    if (_sync.isRunning) return;
    setState(() => _lastSyncFailed = false);
    final result = await _sync.run(refresh: refresh);
    if (!mounted) return;
    setState(() => _lastSyncFailed = result.hasFailures);
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
        toolbarHeight: 48,
        title: widget.showTitle
            ? Text(
                overview == null
                    ? '女优库'
                    : '女优库 ${overview.persons} 位演员',
              )
            : overview == null
            ? null
            : Text('${overview.persons} 位演员'),
        actions: [
          IconButton(
            key: const ValueKey('open-actress-ranking'),
            tooltip: '女优排行榜',
            icon: const Icon(Icons.emoji_events_outlined),
            onPressed: _openRanking,
          ),
          IconButton(
            key: const ValueKey('refresh-actress-library'),
            tooltip: '刷新同步',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _progress.running ? null : () => _runSync(refresh: true),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSyncBanner(colors),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
            child: TextField(
              key: const ValueKey('actress-search'),
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜女优名：中文 / 日文都行',
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
        actions: [TextButton(onPressed: _sync.cancel, child: const Text('取消'))],
      );
    }
    if (overview == null) return const SizedBox.shrink();
    if (overview.persons == 0) {
      return MaterialBanner(
        backgroundColor: colors.surfaceContainerHigh,
        content: const Text('还没有数据，点刷新开始同步女优库。'),
        actions: [
          TextButton(
            onPressed: () => _runSync(refresh: false),
            child: const Text('开始同步'),
          ),
        ],
      );
    }
    final unfinished = !overview.allDone;
    if (_lastSyncFailed || unfinished) {
      return MaterialBanner(
        backgroundColor: colors.surfaceContainerHigh,
        content: Text(
          '已同步 ${overview.persons} 人 · ${overview.works} 部作品，'
          '部分内容还没同步完，点刷新继续补。',
        ),
        actions: [
          TextButton(
            onPressed: () => _runSync(refresh: true),
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
    return GridView.builder(
      key: const ValueKey('actress-person-list'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 8,
        childAspectRatio: 0.88,
      ),
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
