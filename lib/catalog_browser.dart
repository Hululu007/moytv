import 'dart:math';

import 'core_bridge.dart';
import 'models.dart';

String categoryName(String name) {
  final compact = name.trim().replaceAll(RegExp(r'\s+'), '');
  return switch (compact) {
    'AI成人短剧' || 'AI短剧' => 'AI 短剧',
    'AI成人漫剧' || 'AI漫剧' => 'AI 漫剧',
    'AI换脸' => 'AI 换脸',
    'AI魔改' => 'AI 魔改',
    'AI剧' => 'AI 剧',
    '' => '未分类',
    _ => name.trim(),
  };
}

class _CatalogChoice {
  _CatalogChoice(this.category);
  final CatalogCategory category;
  final requests = <String, String>{};
}

class _CatalogEntry {
  List<Drama> items = [];
  List<CatalogTag> tags = [];
  List<CatalogFilterGroup> filters = [];
  int page = 0;
  int nextPage = 1;
  bool hasMore = true;
  bool fresh = false;
}

class _CatalogSession {
  final entries = <String, _CatalogEntry>{};
  int generation = 0;
}

class CatalogBrowser {
  CatalogBrowser(this.repository);
  final AppRepository repository;
  final _menus = <String, List<CatalogCategory>>{};
  final _library = <String, Map<String, Drama>>{};
  final _sessions = <String, _CatalogSession>{};
  int _generation = 0;

  Future<void> cancel() {
    _generation++;
    for (final session in _sessions.values) {
      session.generation++;
    }
    return repository.cancelCatalog();
  }

  void _remember(String source, Iterable<Drama> items) {
    final library = _library.putIfAbsent(source, () => {});
    for (final drama in items) {
      if (drama.source == source) {
        library[drama.id] = library[drama.id]?.merge(drama) ?? drama;
      }
    }
  }

  void updateDrama(Drama drama) {
    updateDramas([drama]);
  }

  void updateDramas(Iterable<Drama> dramas) {
    final updates = {for (final drama in dramas) drama.id: drama};
    for (final drama in updates.values) {
      final library = _library[drama.source];
      if (library?.containsKey(drama.id) == true) {
        library![drama.id] = library[drama.id]!.merge(drama);
      }
    }
    for (final session in _sessions.values) {
      for (final entry in session.entries.values) {
        entry.items = [
          for (final item in entry.items)
            updates[item.id] == null ? item : item.merge(updates[item.id]!),
        ];
      }
    }
  }

  Future<void> _each<T>(List<T> entries, Future<void> Function(T) visit) async {
    var index = 0;
    Future<void> worker() async {
      while (index < entries.length) {
        final entry = entries[index++];
        await visit(entry);
      }
    }

    await Future.wait(List.generate(min(2, entries.length), (_) => worker()));
  }

  Future<String?> loadCategories(
    SourceGroup group, {
    bool force = false,
    bool cacheOnly = false,
    void Function()? onMenu,
  }) async {
    final failures = <String>[];
    await _each(group.sources, (source) async {
      try {
        final cached = await repository.cached(source.id);
        _remember(source.id, cached.items);
      } catch (_) {}
      if (cacheOnly) return;
      try {
        _menus[source.id] = await repository.categories(
          source.id,
          force: force,
        );
        onMenu?.call();
      } catch (_) {
        failures.add(source.groupName);
      }
    });
    return failures.isEmpty ? null : '部分分类暂未加载，点击重试';
  }

  List<_CatalogChoice> _choices(SourceGroup group) {
    final choices = <String, _CatalogChoice>{};
    for (final source in group.sources) {
      for (final category in _menus[source.id] ?? const <CatalogCategory>[]) {
        if (category.id.isEmpty) continue;
        final name = categoryName(category.name);
        final choice = choices.putIfAbsent(
          name,
          () => _CatalogChoice(CatalogCategory('category:$name', name)),
        );
        choice.requests[source.id] = category.id;
      }
    }
    final names = {
      for (final source in group.sources)
        for (final item in _library[source.id]?.values ?? const <Drama>[])
          categoryName(item.category),
    }.toList()..sort();
    for (final name in names) {
      choices.putIfAbsent(
        name,
        () => _CatalogChoice(CatalogCategory('local:$name', name, local: true)),
      );
    }
    return choices.values.toList();
  }

  List<CatalogCategory> categories(SourceGroup group) => [
    CatalogCategory.all,
    for (final choice in _choices(group)) choice.category,
  ];

  _CatalogChoice? _choice(SourceGroup group, String category) => _choices(
    group,
  ).where((choice) => choice.category.id == category).firstOrNull;

  Future<CatalogPage> load(
    SourceGroup group, {
    String category = '',
    String query = '',
    bool more = false,
    bool force = false,
    bool useCache = false,
    bool cacheOnly = false,
    // crossSource 为 true 时并发搜索 crossSources（可见站源）并归一去重，否则只搜当前站源。
    bool crossSource = false,
    List<String>? crossSources,
    void Function(CatalogPage)? onCached,
    Map<String, String> filters = const {},
  }) async {
    if (cacheOnly && (more || force || query.trim().isNotEmpty)) {
      throw AppFailure('缓存读取不能同时请求搜索或续页');
    }
    final request = ++_generation;
    for (final session in _sessions.values) {
      session.generation++;
    }
    await repository.cancelCatalog();
    if (request != _generation) throw AppFailure('已取消加载');
    final choice = query.isEmpty ? _choice(group, category) : null;
    // 文件夹下钻：category 是核心给出的不透明 folderId（子分类、标签集
    // tag:* 或视频列表）时不在本地分类表里，原样透传给各源作 category
    // 参数再次请求目录；普通分类仍走按名聚合的 choice 映射。
    final requests = choice != null && !choice.category.local
        ? choice.requests
        : category.isNotEmpty && choice == null && query.isEmpty
        ? {for (final source in group.sources) source.id: category}
        : {for (final source in group.sources) source.id: ''};
    final filterPart =
        filters.entries
            .where((entry) => entry.value.isNotEmpty)
            .map((entry) => '${entry.key}=${entry.value}')
            .toList()
          ..sort();
    final key =
        '${group.sources.map((s) => s.id).join(',')}|'
        '${choice?.category.local == false || choice == null && category.isNotEmpty ? category : ''}|$query|${filterPart.join(',')}';
    final session = _sessions.putIfAbsent(key, _CatalogSession.new);
    final generation = ++session.generation;
    final failures = <String, String>{};
    final sourceOrder = requests.keys.toList();
    for (final source in sourceOrder) {
      session.entries.putIfAbsent(source, _CatalogEntry.new);
    }

    CatalogPage snapshot() {
      final rows = sourceOrder
          .map((source) => session.entries[source]!.items)
          .toList();
      final items = <String, Drama>{};
      final count = rows.fold<int>(0, (count, row) => max(count, row.length));
      for (var index = 0; index < count; index++) {
        for (final row in rows) {
          if (index < row.length) items[row[index].id] = row[index];
        }
      }
      // 实时口径：普通分类只呈现本次（或占位缓存）目录结果，不再把
      // 本地库里同分类的旧条目混入冒充最新内容；仅「本地筛选」分类
      // （local:）按定义从本地库取数。
      if (choice != null && choice.category.local) {
        for (final source in group.sources) {
          for (final item in _library[source.id]?.values ?? const <Drama>[]) {
            items.putIfAbsent(item.id, () => item);
          }
        }
      }
      return CatalogPage(
        items.values.toList(),
        hasMore: sourceOrder.any((source) => session.entries[source]!.hasMore),
        page: sourceOrder.fold<int>(
          1,
          (page, source) => max(page, session.entries[source]!.page),
        ),
        fresh: sourceOrder.every((source) => session.entries[source]!.fresh),
        warning: failures.values.toSet().join('；'),
        tags: [
          for (final source in sourceOrder) ...session.entries[source]!.tags,
        ],
        filters: sourceOrder.length == 1
            ? session.entries[sourceOrder.first]!.filters
            : const [],
      );
    }

    if ((useCache || cacheOnly) && !force && !more && query.isEmpty) {
      await _each(sourceOrder, (source) async {
        try {
          final cached = await repository.cached(
            source,
            category: requests[source]!,
          );
          if (generation != session.generation || cached.items.isEmpty) return;
          final entry = session.entries[source]!;
          entry.items = cached.items;
          if (cached.tags.isNotEmpty) entry.tags = cached.tags;
          if (cached.filters.isNotEmpty) entry.filters = cached.filters;
          entry.page = cached.page;
          entry.nextPage = cached.page + 1;
          entry.hasMore = cached.hasMore || cached.warning.isNotEmpty;
          entry.fresh = cached.fresh && cached.warning.isEmpty;
          if (cached.warning.isNotEmpty) failures[source] = cached.warning;
          _remember(source, cached.items);
        } catch (error) {
          if (cacheOnly) failures[source] = error.toString();
        }
      });
      if (generation != session.generation) return snapshot();
      final cached = snapshot();
      if (cached.items.isNotEmpty) onCached?.call(cached);
      if (cacheOnly) return cached;
      // 实时口径：缓存只作首屏占位（已通过 onCached 呈现），随后必须
      // 继续现抓并以实时结果覆盖，不再因缓存未过期而停在旧结果。
    }

    // 跨源聚合搜索：并发打所有可见站源，由原生核心按标题/年份/集数归一去重，
    // 每条结果自带 peers（其它站源的同一部剧），供详情页一键切换播放源。
    if (crossSource && query.trim().isNotEmpty) {
      if (more) return snapshot();
      try {
        // 可见站源由调用方给出（站源管理里勾选显示的源），核心侧会跳过没有搜索接口的源。
        final targets = crossSources ?? sourceOrder;
        final result = await repository.searchAcross(targets, query);
        if (generation != session.generation) return snapshot();
        // 不写入 _library：搜索结果不应污染分类浏览的本地缓存。
        for (final source in sourceOrder) {
          session.entries[source]!.items = [
            for (final drama in result.items)
              if (drama.source == source) drama,
          ];
        }
        return CatalogPage(
          result.items,
          hasMore: false,
          page: 1,
          fresh: false,
          warning: result.warning,
          tags: result.tags,
        );
      } on AppFailure {
        rethrow;
      } catch (error) {
        if (generation != session.generation) return snapshot();
        throw AppFailure(error.toString());
      }
    }

    await _each(sourceOrder, (source) async {
      if (generation != session.generation) return;
      final entry = session.entries[source]!;
      if (more && !entry.hasMore) return;
      // 实时口径：同一会话再次加载也重新抓第一页，不再因会话内
      // entry.fresh 跳过抓取（useCache 只决定是否先读占位缓存）。
      final page = more ? entry.nextPage : 1;
      try {
        final result = await repository.catalog(
          source,
          category: requests[source]!,
          query: query,
          page: page,
          force: force,
          filters: filters,
        );
        if (generation != session.generation) return;
        final items = <String, Drama>{
          if (more)
            for (final item in entry.items) item.id: item,
          for (final item in result.items) item.id: item,
        };
        entry.items = items.values.toList();
        if (result.tags.isNotEmpty) entry.tags = result.tags;
        if (result.filters.isNotEmpty) entry.filters = result.filters;
        entry.page = result.page;
        entry.nextPage = result.warning.isEmpty ? result.page + 1 : page;
        entry.hasMore =
            (query.isEmpty || SourceSite.byId(source).pagedSearch) &&
            (result.hasMore || result.warning.isNotEmpty);
        entry.fresh = result.fresh && result.warning.isEmpty;
        if (query.isEmpty) _remember(source, result.items);
        if (result.warning.isNotEmpty) {
          failures[source] = result.warning;
        } else {
          failures.remove(source);
        }
      } catch (error) {
        if (generation != session.generation) return;
        entry.nextPage = page;
        entry.hasMore = query.isEmpty || SourceSite.byId(source).pagedSearch;
        entry.fresh = false;
        failures[source] = error.toString();
      }
    });
    final result = snapshot();
    if (result.items.isEmpty && failures.isNotEmpty) {
      throw AppFailure(result.warning);
    }
    return result;
  }
}
