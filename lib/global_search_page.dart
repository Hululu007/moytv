import 'dart:async';

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'content_detail_screen.dart';
import 'content_models.dart';
import 'content_registry.dart';
import 'core_bridge.dart';
import 'global_search_service.dart';
import 'local_store.dart';
import 'models.dart';
import 'novel_reader_page.dart';
import 'novel_source_store.dart';

/// 视频腿整批预算：searchAcross 是整批回（Go 核聚合），Dart 侧此前
/// 对 Go 腿没有超时——Go 核 6 路 × 25 秒/源，30 个源最坏约 125 秒。
/// 150 秒只拦桥接卡死，不砍健康腿；超时只记本腿失败，阅读结果不受影响。
const globalSearchVideoOverallTimeout = Duration(seconds: 150);

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({
    super.key,
    required this.repository,
    required this.store,
    this.initialQuery = '',
    this.onOpenDrama,
    this.videoSearchOverride,
    this.bookSearchOverride,
  });

  final AppRepository repository;
  final LocalStore store;
  final String initialQuery;
  final void Function(Drama drama)? onOpenDrama;

  /// 视频腿搜索函数（测试注入）：不传时走 repository.searchAcross。
  @visibleForTesting
  final Future<CatalogPage> Function(List<String> sources, String query)?
  videoSearchOverride;

  /// 阅读腿搜索函数（测试注入）：不传时走 searchReadingTargetsProgressive。
  @visibleForTesting
  final Future<void> Function(
    String query,
    List<GlobalSearchBookTarget> targets,
    void Function(GlobalSearchBookGroup group) onGroup,
  )?
  bookSearchOverride;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class GlobalVideoGroup {
  GlobalVideoGroup({
    required this.section,
    required this.siteId,
    required this.siteName,
    required this.items,
  });

  final String section;
  final String siteId;
  final String siteName;
  final List<Drama> items;
}

String globalSearchSectionOf(SourceSite? site) {
  if (site == null) return '其他';
  if (isVodZoneSource(site)) return '点播';
  return '短剧';
}

int globalSearchSectionRank(String section) => switch (section) {
  '短剧' => 0,
  '点播' => 1,
  '听书' => 3,
  '阅读' => 4,
  _ => 5,
};

List<GlobalVideoGroup> groupGlobalVideoResults(
  List<Drama> items,
  List<SourceSite> sites,
) {
  final byKey = <String, GlobalVideoGroup>{};
  final order = <String>[];
  for (final drama in items) {
    final site = sites.where((s) => s.id == drama.source).firstOrNull;
    final section = globalSearchSectionOf(site);
    final key = '$section|${drama.source}';
    final group = byKey.putIfAbsent(key, () {
      order.add(key);
      return GlobalVideoGroup(
        section: section,
        siteId: drama.source,
        siteName: site?.name ?? drama.source,
        items: [],
      );
    });
    group.items.add(drama);
  }
  final groups = [for (final key in order) byKey[key]!];
  groups.sort((a, b) {
    final rank = globalSearchSectionRank(
      a.section,
    ).compareTo(globalSearchSectionRank(b.section));
    return rank != 0 ? rank : a.siteName.compareTo(b.siteName);
  });
  return groups;
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  late final _controller = TextEditingController(text: widget.initialQuery);

  /// 两腿各自的待回 / 失败态：任一腿先回就先上屏，另一腿的加载态
  /// 只占底部一行，已出的结果可点；单腿失败不拖垮另一腿的结果。
  bool _videoPending = false;
  bool _bookPending = false;
  bool _videoFailed = false;
  bool _bookFailed = false;
  String _error = '';
  bool _searched = false;
  List<GlobalVideoGroup> _videoGroups = const [];
  List<GlobalSearchBookGroup> _bookGroups = const [];

  /// 搜索代次：连续发起两次搜索时，过期那次的结果不写回界面。
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    final generation = ++_searchGeneration;
    setState(() {
      _videoPending = true;
      _bookPending = true;
      _videoFailed = false;
      _bookFailed = false;
      _error = '';
      _searched = true;
      _videoGroups = const [];
      _bookGroups = const [];
    });
    try {
      await NovelSourceStore.applyToRegistry();
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _videoPending = false;
        _bookPending = false;
        _error = '搜索失败，请重试';
      });
      return;
    }
    if (!mounted || generation != _searchGeneration) return;
    final videoIds = widget.store.visibleSources
        .where((s) => !s.isHtmlSite)
        .map((s) => s.id)
        .toList();
    // 阅读侧：注册表全量收录，逐站回、回来一个显示一个（见
    // global_search_service.dart）；视频侧仍走 searchAcross 整批回，
    // 回了就上屏。两腿并发跑，各自失败只记本腿，不拖另一腿。
    final bookTargets = globalSearchBookTargets(
      audioSources: ContentRegistry.sourcesFor(ContentSection.audio),
      novelSources: ContentRegistry.sourcesFor(ContentSection.novel),
    );
    unawaited(_runVideoLeg(generation, videoIds, query));
    unawaited(_runBookLeg(generation, query, bookTargets));
  }

  /// 视频腿：整批回，回了就上屏；超时 / 报错只记本腿失败。
  Future<void> _runVideoLeg(
    int generation,
    List<String> videoIds,
    String query,
  ) async {
    var failed = false;
    CatalogPage? videoPage;
    try {
      final videoSearch =
          widget.videoSearchOverride ?? widget.repository.searchAcross;
      videoPage = await videoSearch(
        videoIds,
        query,
      ).timeout(globalSearchVideoOverallTimeout);
    } catch (_) {
      failed = true;
    }
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      if (!failed && videoPage != null) {
        _videoGroups = groupGlobalVideoResults(
          videoPage.items,
          widget.store.sources,
        );
      }
      _videoPending = false;
      _videoFailed = failed;
    });
    _settleLeg(generation);
  }

  /// 阅读腿：逐站回，每组到就追加上屏；整腿报错只记本腿失败。
  Future<void> _runBookLeg(
    int generation,
    String query,
    List<GlobalSearchBookTarget> bookTargets,
  ) async {
    var failed = false;
    try {
      final bookSearch = widget.bookSearchOverride;
      if (bookSearch != null) {
        await bookSearch(query, bookTargets, (group) {
          _onBookGroup(generation, group);
        });
      } else {
        await searchReadingTargetsProgressive(
          query,
          bookTargets,
          onGroup: (group) => _onBookGroup(generation, group),
        );
      }
    } catch (_) {
      failed = true;
    }
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _bookPending = false;
      _bookFailed = failed;
    });
    _settleLeg(generation);
  }

  void _onBookGroup(int generation, GlobalSearchBookGroup group) {
    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _bookGroups = [..._bookGroups, group]..sort(_compareBookGroups);
    });
  }

  static int _compareBookGroups(
    GlobalSearchBookGroup a,
    GlobalSearchBookGroup b,
  ) {
    final rank = globalSearchSectionRank(
      a.section.title,
    ).compareTo(globalSearchSectionRank(b.section.title));
    return rank != 0 ? rank : a.source.name.compareTo(b.source.name);
  }

  /// 一腿收尾：两腿都结算、都失败、又一张结果都没有时，才报整轮失败；
  /// 只要任一腿出过结果，就只显示结果，不报失败。
  void _settleLeg(int generation) {
    if (!mounted || generation != _searchGeneration) return;
    if (_videoPending || _bookPending) return;
    if (_videoFailed &&
        _bookFailed &&
        _videoGroups.isEmpty &&
        _bookGroups.isEmpty) {
      setState(() => _error = '搜索失败，请重试');
    }
  }

  /// 底部待回提示：只报还没回完的那条腿。
  String get _pendingLabel {
    if (_videoPending && _bookPending) return '正在搜索更多站源…';
    if (_videoPending) return '正在搜索视频站源…';
    return '正在搜索阅读站源…';
  }

  void _openVideo(Drama drama) {
    final open = widget.onOpenDrama;
    Navigator.of(context).pop();
    open?.call(drama);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sections = <String>[];
    for (final group in _videoGroups) {
      if (!sections.contains(group.section)) sections.add(group.section);
    }
    for (final group in _bookGroups) {
      if (!sections.contains(group.section.title)) {
        sections.add(group.section.title);
      }
    }
    sections.sort(
      (a, b) =>
          globalSearchSectionRank(a).compareTo(globalSearchSectionRank(b)),
    );
    final stillSearching = _videoPending || _bookPending;
    final hasResults = _videoGroups.isNotEmpty || _bookGroups.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('全局搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: '搜全部区域与站源',
                      prefixIcon: Icon(Icons.search_rounded),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _search, child: const Text('搜索')),
              ],
            ),
          ),
          // 全屏转圈只在“一组结果都还没回”时出现；只要有结果上屏，
          // 待回的腿就只占列表底部一行，已出的结果可点。
          if (stillSearching && !hasResults && _error.isEmpty)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error.isNotEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error, style: TextStyle(color: colors.error)),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _search, child: const Text('重试')),
                  ],
                ),
              ),
            )
          else if (_searched && !hasResults)
            const Expanded(child: Center(child: Text('暂无结果')))
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  for (final section in sections) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Text(
                        section,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    for (final group in _videoGroups.where(
                      (g) => g.section == section,
                    )) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: Text(
                          '${group.siteName} · ${group.items.length}',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 180,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.62,
                            ),
                        itemCount: group.items.length,
                        itemBuilder: (context, index) =>
                            _videoCard(group.items[index]),
                      ),
                    ],
                    for (final group in _bookGroups.where(
                      (g) => g.section.title == section,
                    )) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: Text(
                          '${group.source.name} · ${group.items.length}',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 180,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.62,
                            ),
                        itemCount: group.items.length,
                        itemBuilder: (context, index) =>
                            _bookCard(group, group.items[index]),
                      ),
                    ],
                  ],
                  if (stillSearching)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _pendingLabel,
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _videoCard(Drama drama) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _openVideo(drama),
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: drama.cover.isNotEmpty
                  ? Image.network(
                      drama.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          _coverFallback(colors, drama.title),
                    )
                  : _coverFallback(colors, drama.title),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _bookCard(GlobalSearchBookGroup group, ContentBook book) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        if (group.section == ContentSection.novel) {
          Navigator.of(context).push(
            appPageRoute(
              builder: (_) => NovelReaderPage(source: group.source, book: book),
            ),
          );
        } else {
          Navigator.of(context).push(
            appPageRoute(
              builder: (_) => ContentDetailScreen(
                source: group.source,
                book: book,
                autoPlay: true,
              ),
            ),
          );
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: book.cover.isNotEmpty
                  ? Image.network(
                      book.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          _coverFallback(colors, book.title),
                    )
                  : _coverFallback(colors, book.title),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _coverFallback(ColorScheme colors, String title) => Container(
    color: colors.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Icon(Icons.image_not_supported, color: colors.onSurfaceVariant),
  );
}
