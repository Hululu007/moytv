import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../player_picker.dart';
import 'actress_db_fields_page.dart';
import 'actress_generic_db.dart';
import 'video_db_repair.dart';

/// 外来数据库浏览页（2026-11-21 用户令，第二轮修复）：
/// 顶部一级分类瓦片点进来后，这里就是**这个库自己的视频列表**——
/// 先把第一页卡片立刻铺出来（不再等全表 COUNT），再后台补总数；
/// 库内部的多级分类（分类/类型/标签/系列/地区…）按列分组做筛选
/// chips，组内多选取并、跨组取交；点卡片直接播（本地库地址是直链，
/// 不再绕蜘蛛取流）。
///
/// 库文件只读打开、只读不写。认不出作品表时不空白：列出探到的表，
/// 给“数据库字段”手动指定入口。
class ActressDbFilePage extends StatefulWidget {
  const ActressDbFilePage({
    super.key,
    required this.filePath,
    required this.title,
    required this.repository,
    required this.store,
  });

  /// 要浏览的数据库文件绝对路径（只读打开）。
  final String filePath;

  /// 一级分类瓦片上显示的名字（数据库文件名，去后缀）。
  final String title;

  final AppRepository repository;
  final LocalStore store;

  @override
  State<ActressDbFilePage> createState() => _ActressDbFilePageState();
}

class _ActressDbFilePageState extends State<ActressDbFilePage> {
  static const _pageSize = 60;

  Database? _db;
  GenericDbReader? _reader;
  GenericDbSchema? _schema;

  final _works = <GenericDbWork>[];
  final _facets = <GenericDbFacet>[];
  final _selected = <String, Set<String>>{};
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  var _total = -1; // -1 = 还在后台数
  var _loadingFirst = true;
  var _loadingMore = false;
  var _loadingFacets = false;
  var _hasMore = false;
  var _error = '';
  var _query = '';
  String _table = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
    unawaited(_open());
  }

  @override
  void dispose() {
    _generation++;
    _scrollController.dispose();
    _searchController.dispose();
    final db = _db;
    _db = null;
    if (db != null) {
      // 关掉只读连接：页面退出不占文件句柄（用户可能同时在换库）。
      db.close().catchError((_) {});
    }
    super.dispose();
  }

  Map<String, List<String>> get _filters => {
    for (final entry in _selected.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
  };

  int get _selectedCount =>
      _selected.values.fold(0, (sum, values) => sum + values.length);

  bool _repairing = false;
  bool _repairCancel = false;

  /// 体检修复当前库：逐条验活播放地址，确认打不开的行删掉，重建演员
  /// 汇总与分类计数。开修前自动备份一份 .bak，修完重开库刷新列表。
  Future<void> _repairLibrary() async {
    if (_repairing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('体检修复这个库'),
        content: const Text(
          '逐条测播放地址：能播的留着，确认打不开的删掉，'
          '测不准的（403、超时、TLS 失败）一律保留，不误删能播的源。\n\n'
          '30 万条的库大约要几十分钟，期间别退出页面。开修前会自动存一份 .bak 备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始修复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _repairing = true;
      _repairCancel = false;
    });

    // 先关只读连接，免得写库时被占着。
    final db = _db;
    _db = null;
    try {
      await db?.close();
    } catch (_) {}

    var backupNote = '';
    try {
      final file = File(widget.filePath);
      if (await file.exists()) {
        await file.copy('${widget.filePath}.bak');
        backupNote = '已备份到 ${path.basename(widget.filePath)}.bak';
      }
    } catch (_) {
      backupNote = '备份没做成（可能空间不够），修复照常进行';
    }

    final progress = ValueNotifier<String>('正在读库…');
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('正在体检'),
          content: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(minHeight: 4),
                const SizedBox(height: 14),
                Text(value),
                const SizedBox(height: 6),
                Text(
                  '测不准的地址不会删，只删确认打不开的',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => _repairCancel = true,
              child: const Text('中止'),
            ),
          ],
        ),
      ),
    );

    VideoDbRepairReport? report;
    var error = '';
    try {
      report = await VideoDbRepair.run(
        widget.filePath,
        onProgress: (done, total) {
          progress.value = total > 0
              ? '已测 $done / $total（${(done * 100 / total).toStringAsFixed(0)}%）'
              : '已测 $done';
        },
        cancelled: () => _repairCancel,
      );
    } catch (e) {
      error = e.toString();
    } finally {
      progress.dispose();
      if (mounted) navigator.pop();
    }

    if (!mounted) return;
    setState(() => _repairing = false);
    await _open();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(error.isEmpty ? '体检修复完成' : '修复没做成'),
        content: Text(
          error.isEmpty
              ? [
                  if (report != null) report.summary,
                  if (report?.cancelled ?? false) '（中途中止，已测的部分已生效）',
                  if (backupNote.isNotEmpty) backupNote,
                  '修复只删确认打不开的行，测不准的都保留。',
                ].join('\n')
              : '$error\n\n$backupNote',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _open() async {
    final generation = ++_generation;
    setState(() {
      _loadingFirst = true;
      _error = '';
    });
    try {
      if (!File(widget.filePath).existsSync()) {
        setState(() {
          _loadingFirst = false;
          _error = '库文件不在了：${path.basename(widget.filePath)}';
        });
        return;
      }
      final db = await openDatabase(
        widget.filePath,
        readOnly: true,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('打开库超时'),
      );
      if (!mounted || generation != _generation) {
        await db.close();
        return;
      }
      final schema = await probeGenericDbSchema(db).timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('读库结构超时'),
      );
      final reader = GenericDbReader(
        db: db,
        schema: schema,
        mappingStore: GenericDbMappingStore(
          file: File(path.join(path.dirname(widget.filePath), '字段映射.json')),
        ),
      );
      if (!mounted || generation != _generation) {
        await db.close();
        return;
      }
      _db = db;
      _reader = reader;
      _schema = schema;
      _table = schema.worksTable?.table ?? '';
      if (schema.worksTable == null) {
        // 认不出作品表：不空白，进诊断态（列已探到的表 + 手动指定入口）。
        setState(() => _loadingFirst = false);
        return;
      }
      await _loadFirst(generation);
      unawaited(_loadTotalAndFacets(generation));
    } on TimeoutException {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingFirst = false;
        _error = '这个库打开/读结构太慢，先退回去了。它可能太大或正被别的程序占用，\n'
            '过一会儿再点一次，或者把库文件名告诉我换个读法。';
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingFirst = false;
        _error = '打不开这个库：$error';
      });
    }
  }

  /// 第一页：只查作品，不等 COUNT（大库 COUNT 很慢，等它就白屏）。
  Future<void> _loadFirst(int generation) async {
    final reader = _reader;
    if (reader == null) return;
    setState(() {
      _loadingFirst = true;
      _error = '';
      _works.clear();
      _hasMore = true;
      _total = -1;
    });
    try {
      final works = await reader.works(
        offset: 0,
        limit: _pageSize,
        query: _query,
        filters: _filters,
      ).timeout(const Duration(seconds: 25));
      if (!mounted || generation != _generation) return;
      setState(() {
        _works
          ..clear()
          ..addAll(works);
        _hasMore = works.length >= _pageSize;
        _loadingFirst = false;
      });
    } on TimeoutException {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingFirst = false;
        _error = '读这个库太慢（可能是大库没索引），换个筛选或稍后再试。';
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingFirst = false;
        _error = '读库失败：$error';
      });
    }
  }

  /// 后台补总数与分类维度（不阻塞首屏）。
  Future<void> _loadTotalAndFacets(int generation) async {
    final reader = _reader;
    if (reader == null) return;
    setState(() => _loadingFacets = true);
    // 分类先查：大库 COUNT 可能慢几十秒，等它会把分类条一起拖住，
    // 用户看到的就是「点进来没有分类」。
    try {
      // 分类维度逐列查（副表维度在前），大库上可能几秒到十几秒；
      // 给足时间，别一超时就把整批分类丢掉（那正是「读不到分类」）。
      final facets = await reader
          .facets()
          .timeout(const Duration(seconds: 90));
      if (!mounted || generation != _generation) return;
      setState(() {
        _facets
          ..clear()
          ..addAll(facets);
        _loadingFacets = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingFacets = false);
    }
    try {
      final total = await reader.countWorks(
        query: _query,
        filters: _filters,
      ).timeout(const Duration(seconds: 60));
      if (!mounted || generation != _generation) return;
      setState(() => _total = total);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _total = _works.length);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      unawaited(_loadMore());
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query == _query) return;
    _query = query;
    _reload();
  }

  void _reload() {
    final generation = ++_generation;
    unawaited(_loadFirst(generation));
    unawaited(_loadTotalAndFacets(generation));
  }

  Future<void> _loadMore() async {
    final reader = _reader;
    if (reader == null || _loadingMore || !_hasMore || _loadingFirst) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final works = await reader.works(
        offset: _works.length,
        limit: _pageSize,
        query: _query,
        filters: _filters,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _works.addAll(works);
        _hasMore = works.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _play(GenericDbWork work) async {
    if (!work.playable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            work.playUrl.isEmpty
                ? '这条在库里没有播放地址（可能地址在另一张表，点“数据库字段”指定一下）'
                : '这条地址不是可播的 http 地址：${work.playUrl}',
          ),
        ),
      );
      return;
    }
    final entry = work.toJsonEntry();
    await pushPlayer<void>(
      context,
      detail: entry.toDramaDetail(),
      initialIndex: 0,
      repository: widget.repository,
      store: widget.store,
    );
  }

  Future<void> _openFieldPage() async {
    final reader = _reader;
    if (reader == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ActressDbFieldsPage(reader: reader)),
    );
    if (changed == true && mounted) {
      setState(() {
        _schema = reader.schema;
        _table = reader.schema.worksTable?.table ?? '';
        _selected.clear();
      });
      _reload();
    }
  }

  Future<void> _pickFacet(GenericDbFacet facet) async {
    final selected = {...?_selected[facet.column]};
    final applied = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _FacetSheet(
        facet: facet,
        selected: selected,
      ),
    );
    if (applied == null || !mounted) return;
    setState(() {
      if (applied.isEmpty) {
        _selected.remove(facet.column);
      } else {
        _selected[facet.column] = applied;
      }
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              _subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          if (_reader != null && _schema?.worksTable != null)
            IconButton(
              tooltip: '数据库字段',
              icon: const Icon(Icons.tune_rounded),
              onPressed: _openFieldPage,
            ),
          IconButton(
            key: const ValueKey('actress-db-repair'),
            tooltip: '体检修复这个库',
            icon: _repairing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.healing_rounded),
            onPressed: _repairing ? null : () => unawaited(_repairLibrary()),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: TextField(
              key: const ValueKey('actress-db-file-search'),
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜标题或番号',
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
          if (_facets.isNotEmpty || _selectedCount > 0) _buildFacetBar(colors),
          if (_facets.isEmpty &&
              !_loadingFacets &&
              !_loadingFirst &&
              _error.isEmpty &&
              _works.isNotEmpty)
            _buildNoFacetHint(colors),
          Expanded(child: _body(colors)),
        ],
      ),
    );
  }

  String get _subtitle {
    if (_schema == null) return '外来数据库';
    if (_schema!.worksTable == null) return '外来数据库 · 认不出作品表';
    final parts = <String>[
      '表 $_table',
      _total >= 0 ? '$_total 条' : '读取中…',
      if (_selectedCount > 0) '筛选 $_selectedCount 项',
    ];
    return parts.join(' · ');
  }

  /// 分类筛选条：每个维度一个 chip（列名 + 已选数），点开多选。
  Widget _buildFacetBar(ColorScheme colors) {
    return SizedBox(
      height: 42,
      child: ListView(
        key: const ValueKey('actress-db-file-facets'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final facet in _facets)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                key: ValueKey('db-facet-${facet.column}'),
                label: Text(
                  _selected[facet.column]?.isNotEmpty == true
                      ? '${_facetLabel(facet.column)} '
                          '${_selected[facet.column]!.length}'
                      : _facetLabel(facet.column),
                  style: const TextStyle(fontSize: 12),
                ),
                selected: _selected[facet.column]?.isNotEmpty == true,
                onSelected: (_) => _pickFacet(facet),
              ),
            ),
          if (_loadingFacets)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (_selectedCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                key: const ValueKey('db-facet-clear'),
                avatar: const Icon(Icons.clear_rounded, size: 14),
                label: const Text('清除筛选', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  setState(() => _selected.clear());
                  _reload();
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 列名转人话（库里字段名多是英文）。副表维度的 key 是
  /// `表.列`（如 video_category.main_category），只拿列名去转，
  /// 给用户看库表名没意义。
  String _facetLabel(String column) => facetDisplayLabel(column);

  /// 一个分类维度都没认出来时的提示条（不静默空白：告诉用户在哪儿
  /// 手动指定，或者这个库本身就没有分类列）。
  Widget _buildNoFacetHint(ColorScheme colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(
        children: [
          Icon(Icons.filter_alt_off_outlined, size: 15,
              color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '这个库里没认出分类列，点右上角「数据库字段」指定一下',
              style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme colors) {
    if (_loadingFirst) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return _message(
        colors,
        _error,
        actions: [
          FilledButton(
            onPressed: () => unawaited(_open()),
            child: const Text('重试'),
          ),
          if (_reader != null)
            OutlinedButton(
              onPressed: _openFieldPage,
              child: const Text('数据库字段'),
            ),
        ],
      );
    }
    final schema = _schema;
    if (schema != null && schema.worksTable == null) {
      return _buildSchemaHelp(colors, schema);
    }
    if (_works.isEmpty) {
      return _message(
        colors,
        _query.isNotEmpty || _selectedCount > 0
            ? '当前条件下没有作品'
            : '这个库里没有作品',
      );
    }
    return GridView.builder(
      key: const ValueKey('actress-db-file-grid'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.58,
      ),
      itemCount: _works.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _works.length) {
          return const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final work = _works[index];
        return _DbWorkCard(
          key: ValueKey('db-work-${work.id ?? work.title}'),
          work: work,
          onTap: () => unawaited(_play(work)),
        );
      },
    );
  }

  Widget _message(
    ColorScheme colors,
    String text, {
    List<Widget> actions = const [],
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(spacing: 10, children: actions),
            ],
          ],
        ),
      ),
    );
  }

  /// 认不出作品表时的诊断：把探到的表和字段摆出来，让用户能手动
  /// 指定（不然只报一句“认不出”，用户无从下手）。
  Widget _buildSchemaHelp(ColorScheme colors, GenericDbSchema schema) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '这个库的表结构没自动认出来。下面是库里探到的表，'
          '点“数据库字段”手动指定哪个是标题、哪个是播放地址。',
          style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
        ),
        const SizedBox(height: 12),
        for (final table in schema.tables)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              dense: true,
              title: Text(table.table),
              subtitle: Text(
                table.allColumns.take(12).join('、') +
                    (table.allColumns.length > 12 ? ' …' : ''),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text('${table.allColumns.length} 列'),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _openFieldPage,
          icon: const Icon(Icons.tune_rounded),
          label: const Text('数据库字段'),
        ),
      ],
    );
  }
}

/// 分类维度 key 转人话：`video_category.main_category` 这种带表名的
/// key 只取最后一段列名；列名里的英文按常见对应关系翻译。
String facetDisplayLabel(String column) {
  final dot = column.lastIndexOf('.');
  final name = dot >= 0 ? column.substring(dot + 1) : column;
  final lower = name.toLowerCase();
  const map = {
    'category': '分类',
    'main_category': '分类',
    'type': '类型',
    'class': '分类',
    'genre': '题材',
    'tag': '标签',
    'tags': '标签',
    'series': '系列',
    'area': '地区',
    'kind': '种类',
    'group': '分组',
    'theme': '主题',
    'studio': '片商',
  };
  for (final entry in map.entries) {
    if (lower.contains(entry.key)) return entry.value;
  }
  return name;
}

/// 一个分类维度的多选面板：组内多选取并（勾几个都算）。
class _FacetSheet extends StatefulWidget {
  const _FacetSheet({required this.facet, required this.selected});

  final GenericDbFacet facet;
  final Set<String> selected;

  @override
  State<_FacetSheet> createState() => _FacetSheetState();
}

class _FacetSheetState extends State<_FacetSheet> {
  late final _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      facetDisplayLabel(widget.facet.column),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_picked.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(_picked.clear),
                      child: const Text('清空'),
                    ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.facet.values.length,
                itemBuilder: (context, index) {
                  final value = widget.facet.values[index];
                  final checked = _picked.contains(value.value);
                  return CheckboxListTile(
                    dense: true,
                    value: checked,
                    title: Text(
                      value.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    secondary: Text(
                      '${value.count}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    onChanged: (next) => setState(() {
                      if (next == true) {
                        _picked.add(value.value);
                      } else {
                        _picked.remove(value.value);
                      }
                    }),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_picked),
                  child: Text(
                    _picked.isEmpty ? '不筛选' : '应用（${_picked.length} 项）',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 外来库作品卡：封面 + 标题 + 副标题（番号/女优/日期），点卡直播。
class _DbWorkCard extends StatelessWidget {
  const _DbWorkCard({super.key, required this.work, required this.onTap});

  final GenericDbWork work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subtitle = [
      if (work.code.isNotEmpty) work.code,
      if (work.actress.isNotEmpty) work.actress,
      if (work.date.isNotEmpty) work.date,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: colors.surfaceContainerHighest,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (work.coverUrl.isEmpty)
                      Center(
                        child: Icon(
                          Icons.movie_outlined,
                          color: colors.onSurfaceVariant,
                        ),
                      )
                    else
                      Image.network(
                        work.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (!work.playable)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '无地址',
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            work.title.isEmpty
                ? (work.code.isEmpty ? '未命名' : work.code)
                : work.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, height: 1.25),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
