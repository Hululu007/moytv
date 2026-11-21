import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../player_picker.dart';
import 'actress_generic_db.dart';

/// 外来数据库浏览页（2026-11-21 用户令）：女优库顶部把 MYTV/db 与补充
/// 目录里的其它 .db 按**数据库名**摆成一级分类瓦片，点一个瓦片就进这
/// 一页——只读打开那个库，按通用读库层（[probeGenericDbSchema] +
/// [GenericDbReader]）探结构，作品按网格卡片列出来，点卡直接播
///（toJsonEntry 的 parse=0 直通地址）。
///
/// 源库只读打开、只读不写：用户放的库文件一个字都不动。认不出作品表
/// 时如实报原因，不显示空白。
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
  final _works = <GenericDbWork>[];
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
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
    _open();
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
      unawaitedClose(db);
    }
    super.dispose();
  }

  static void unawaitedClose(Database db) {
    db.close().catchError((_) {});
  }

  Future<void> _open() async {
    final generation = ++_generation;
    try {
      if (!File(widget.filePath).existsSync()) {
        setState(() {
          _loading = false;
          _error = '库文件不在了：${path.basename(widget.filePath)}';
        });
        return;
      }
      final db = await openDatabase(widget.filePath, readOnly: true);
      if (!mounted || generation != _generation) {
        await db.close();
        return;
      }
      final schema = await probeGenericDbSchema(db);
      final worksTable = schema.worksTable;
      if (worksTable == null) {
        await db.close();
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _error = '这个库认不出作品表（没有同时含标题与播放地址的表）';
        });
        return;
      }
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
      setState(() {
        _db = db;
        _reader = reader;
        _table = worksTable.table;
      });
      await _loadPage(reset: true);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '打不开这个库：$error';
      });
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      _loadPage();
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query == _query) return;
    _query = query;
    _loadPage(reset: true);
  }

  Future<void> _loadPage({bool reset = false}) async {
    final reader = _reader;
    if (reader == null) return;
    if (reset) {
      final generation = ++_generation;
      setState(() {
        _loading = true;
        _error = '';
        _works.clear();
        _hasMore = true;
      });
      try {
        final total = await reader.countWorks(query: _query);
        final works = await reader.works(
          offset: 0,
          limit: _pageSize,
          query: _query,
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          _total = total;
          _works
            ..clear()
            ..addAll(works);
          _hasMore = works.length >= _pageSize;
          _loading = false;
        });
      } catch (error) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _error = '读库失败：$error';
        });
      }
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final works = await reader.works(
        offset: _works.length,
        limit: _pageSize,
        query: _query,
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
              _table.isEmpty ? '外来数据库' : '外来数据库 · 表 $_table · $_total 条',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ],
        ),
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
          Expanded(child: _body(colors)),
        ],
      ),
    );
  }

  Widget _body(ColorScheme colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = '';
                  });
                  _open();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_works.isEmpty) {
      return Center(
        child: Text(
          _query.isNotEmpty ? '没有找到“$_query”' : '这个库里没有作品',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
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
          onTap: () => _play(work),
        );
      },
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
                child: work.coverUrl.isEmpty
                    ? Center(
                        child: Icon(
                          Icons.movie_outlined,
                          color: colors.onSurfaceVariant,
                        ),
                      )
                    : Image.network(
                        work.coverUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, _, _) => Center(
                          child: Icon(
                            Icons.movie_outlined,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            work.title.isEmpty ? (work.code.isEmpty ? '未命名' : work.code) : work.title,
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
