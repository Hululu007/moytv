/// 多媒体屏：网盘数据的媒体库浏览（飞牛 NAS 影视式的海报墙组织，
/// 只借通用样式与组织方式，不碰其品牌与素材）。
///
/// 数据走网盘引擎的现有目录/详情/播放链（[AppRepository] 的
/// cloud: 站源）：文件夹=分类下钻、视频=卡片、点卡进详情/播放，
/// 与站源同一套链路；疑似广告视频的默认隐藏由引擎侧执行，这里
/// 只呈现引擎返回的结果与 warning。
/// 卡片刮削复用 TMDB 刮削链（[TmdbService]，无 key 也能用）：
/// 文件名解析出标题后后台补海报/标题/简介，刮不到的显示原文件
/// 名 + 原封面/占位，绝不编假数据；刮削失败/无网不阻塞列表。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'cloud_drive/cloud_filename.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'tmdb/tmdb_config.dart';
import 'tmdb/tmdb_metadata.dart';
import 'tmdb/tmdb_service.dart';
import 'widgets.dart';

/// 刮削取数函数（测试注入假取数；为空时用 [TmdbService] 真链）。
typedef MultimediaMetadataFetcher =
    Future<TmdbMetadata?> Function({
      required String title,
      String? year,
      String? typeHint,
    });

class MultimediaScreen extends StatefulWidget {
  const MultimediaScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.driveSites,
    required this.onOpenDrama,
    this.onOpenCloudLogin,
    this.metadataFetcher,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 已登录且显示中的网盘站（`cloud:<网盘>`）；为空时显示未登录提示。
  final List<SourceSite> driveSites;
  final ValueChanged<Drama> onOpenDrama;

  /// 未登录提示里的“去网盘登录”跳转；为空时不显示跳转按钮。
  final VoidCallback? onOpenCloudLogin;
  final MultimediaMetadataFetcher? metadataFetcher;

  @override
  State<MultimediaScreen> createState() => _MultimediaScreenState();
}

class _MultimediaScreenState extends State<MultimediaScreen> {
  /// 每页最多刮削的条目数（海报墙首屏 + 滚动缓冲；超出部分保持
  /// 文件名条目，避免一次取数几百条拖垮界面与刮削源）。
  static const _enrichCap = 100;

  /// 刮削并发上限与单条超时（与推荐流验播同一口径：收紧超时、
  /// 并发有上限、失败不卡列表）。
  static const _enrichConcurrency = 4;
  static const _enrichTimeout = Duration(seconds: 10);

  final _searchController = TextEditingController();
  String _selectedSource = '';
  final _drillStack = <({String source, String category, String title})>[];
  var _items = const <Drama>[];
  var _loading = false;
  var _error = '';
  var _warning = '';

  /// 刮削后的卡片副本（id → 副本），原条目 id/source 不变。
  final _enriched = <String, Drama>{};

  /// 刮削结果（id → 元数据），供副标题（年份/类型）显示用。
  final _enrichedMeta = <String, TmdbMetadata>{};

  /// 会话内刮削缓存（搜索标题 + 年份 → 结果，含 null），同一标题
  /// 在本会话里只刮一次。
  final _enrichCache = <String, TmdbMetadata?>{};
  var _generation = 0;
  var _tmdbConfig = const TmdbConfig();

  MultimediaMetadataFetcher get _fetcher =>
      widget.metadataFetcher ??
      (({required String title, String? year, String? typeHint}) => TmdbService
          .instance
          .fetchMetadata(title: title, year: year, typeHint: typeHint));

  @override
  void initState() {
    super.initState();
    unawaited(_loadTmdbConfig());
    if (widget.driveSites.isNotEmpty) {
      unawaited(_load());
    }
  }

  Future<void> _loadTmdbConfig() async {
    final config = await TmdbConfig.load();
    if (mounted) setState(() => _tmdbConfig = config);
  }

  @override
  void didUpdateWidget(MultimediaScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.driveSites.map((s) => s.id).join(',');
    final newIds = widget.driveSites.map((s) => s.id).join(',');
    if (oldIds != newIds || oldWidget.repository != widget.repository) {
      _drillStack.clear();
      _selectedSource = '';
      _enriched.clear();
      _enrichedMeta.clear();
      if (widget.driveSites.isNotEmpty) {
        unawaited(_load());
      } else {
        setState(() {
          _items = const [];
          _loading = false;
          _error = '';
          _warning = '';
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
    });
    final query = _searchController.text.trim();
    try {
      final page = await _fetchPage(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = page.items;
        _warning = page.warning;
        _loading = false;
      });
      unawaited(_enrich(page.items, generation));
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  /// 取一页：下钻中只取所在夹；否则按选中网盘取，或聚合全部网盘。
  Future<CatalogPage> _fetchPage(String query) async {
    if (_drillStack.isNotEmpty) {
      final top = _drillStack.last;
      return widget.repository.catalog(
        top.source,
        category: top.category,
        query: query,
      );
    }
    final targets = _selectedSource.isEmpty
        ? widget.driveSites.map((s) => s.id).toList()
        : [_selectedSource];
    if (targets.length == 1) {
      return widget.repository.catalog(targets.first, query: query);
    }
    final items = <Drama>[];
    final seen = <String>{};
    final warnings = <String>[];
    for (final source in targets) {
      try {
        final page = await widget.repository.catalog(source, query: query);
        for (final item in page.items) {
          if (seen.add(item.id)) items.add(item);
        }
        if (page.warning.isNotEmpty) warnings.add(page.warning);
      } catch (error) {
        warnings.add('$source 加载失败：$error');
      }
    }
    return CatalogPage(items, warning: warnings.join(' '));
  }

  /// 后台刮削：先出文件名条目，再逐条补海报/标题/简介；任何失败
  /// 都静默回落（保留原条目），绝不阻塞列表、不抛错。
  Future<void> _enrich(List<Drama> items, int generation) async {
    final candidates = items
        .where((drama) => !drama.isFolder)
        .take(_enrichCap)
        .toList();
    if (candidates.isEmpty) return;
    var next = 0;
    Future<void> worker() async {
      while (mounted && generation == _generation) {
        if (next >= candidates.length) return;
        final drama = candidates[next++];
        final parsed = parseCloudFileName(drama.title);
        final cacheKey = '${parsed.searchTitle}|${parsed.year ?? ''}';
        TmdbMetadata? meta;
        if (_enrichCache.containsKey(cacheKey)) {
          meta = _enrichCache[cacheKey];
        } else {
          try {
            meta = await _fetcher(
              title: parsed.searchTitle,
              year: parsed.year,
            ).timeout(_enrichTimeout);
          } catch (_) {
            meta = null;
          }
          _enrichCache[cacheKey] = meta;
        }
        if (!mounted || generation != _generation) return;
        if (meta == null) continue;
        final poster = meta.posterUrl(_tmdbConfig);
        final enriched = Drama(
          id: drama.id,
          source: drama.source,
          sourceId: drama.sourceId,
          title: meta.title.isNotEmpty ? meta.title : drama.title,
          description: meta.overview.isNotEmpty
              ? meta.overview
              : drama.description,
          cover: poster.isNotEmpty ? poster : drama.cover,
          episodes: drama.episodes,
          category: drama.category,
          vip: drama.vipStatus,
          heat: drama.heat,
          views: drama.views,
          onlineDate: drama.onlineDate,
          tags: drama.tags,
          releaseStatus: drama.releaseStatus,
          kind: drama.kind,
          folderId: drama.folderId,
          peers: drama.peers,
        );
        setState(() {
          _enriched[drama.id] = enriched;
          _enrichedMeta[drama.id] = meta!;
        });
      }
    }

    await Future.wait([for (var i = 0; i < _enrichConcurrency; i++) worker()]);
  }

  void _onTapDrama(Drama drama) {
    if (drama.isFolder) {
      setState(() {
        _drillStack.add((
          source: drama.source,
          category: drama.folderId,
          title: drama.title,
        ));
        _searchController.clear();
      });
      unawaited(_load());
      return;
    }
    widget.onOpenDrama(_enriched[drama.id] ?? drama);
  }

  void _onBack() {
    if (_drillStack.isEmpty) return;
    setState(() {
      _drillStack.removeLast();
      _searchController.clear();
    });
    unawaited(_load());
  }

  void _onSelectDrive(String sourceId) {
    if (_selectedSource == sourceId) return;
    setState(() {
      _selectedSource = sourceId;
      _drillStack.clear();
      _searchController.clear();
    });
    unawaited(_load());
  }

  String? _subtitleFor(Drama drama) {
    final meta = _enrichedMeta[drama.id];
    if (meta == null) return null;
    final parts = <String>[
      if (meta.year.isNotEmpty) meta.year,
      if (meta.mediaType == 'tv') '剧集' else if (meta.mediaType == 'movie') '电影',
    ];
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.driveSites.isEmpty) {
      return _loggedOutView();
    }
    return Column(
      key: const ValueKey('multimedia-screen'),
      children: [
        _driveRow(),
        _searchRow(),
        if (_drillStack.isNotEmpty) _breadcrumbRow(),
        if (_warning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              _warning,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _loggedOutView() {
    return Center(
      key: const ValueKey('multimedia-empty'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 12),
            const Text('还没有登录任何网盘', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '去设置 → 网盘登录扫码登录后，这里的网盘视频会显示出来',
              textAlign: TextAlign.center,
            ),
            if (widget.onOpenCloudLogin != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('multimedia-login-button'),
                onPressed: widget.onOpenCloudLogin,
                child: const Text('去网盘登录'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _driveRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          ChoiceChip(
            key: const ValueKey('multimedia-drive-chip-all'),
            label: const Text('全部网盘'),
            selected: _selectedSource.isEmpty,
            onSelected: (_) => _onSelectDrive(''),
          ),
          const SizedBox(width: 8),
          for (final site in widget.driveSites) ...[
            ChoiceChip(
              key: ValueKey('multimedia-drive-chip-${site.id}'),
              label: Text(site.name),
              selected: _selectedSource == site.id,
              onSelected: (_) => _onSelectDrive(site.id),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('multimedia-search'),
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: '搜索网盘视频',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('multimedia-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  Widget _breadcrumbRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('multimedia-back'),
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回上一级',
            onPressed: _onBack,
          ),
          Expanded(
            child: Text(
              _drillStack.map((e) => e.title).join(' / '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty && _items.isEmpty) {
      return Center(
        key: const ValueKey('multimedia-error'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(child: Text('这里空空如也'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          gridDelegate: dramaGridDelegate(context, constraints.maxWidth - 24),
          itemCount: _items.length,
          itemBuilder: (context, index) {
            final drama = _items[index];
            final display = _enriched[drama.id] ?? drama;
            return DramaTile(
              key: ValueKey(display.id),
              drama: display,
              repository: widget.repository,
              subtitle: _subtitleFor(drama),
              badge: drama.isFolder ? '文件夹' : null,
              onTap: () => _onTapDrama(drama),
            );
          },
        );
      },
    );
  }
}
