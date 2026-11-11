import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'content_detail_screen.dart';
import 'content_models.dart';
import 'content_registry.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'novel_reader_page.dart';
import 'novel_source_store.dart';

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({
    super.key,
    required this.repository,
    required this.store,
    this.initialQuery = '',
    this.onOpenDrama,
  });

  final AppRepository repository;
  final LocalStore store;
  final String initialQuery;
  final void Function(Drama drama)? onOpenDrama;

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

class _BookGroup {
  _BookGroup({
    required this.section,
    required this.source,
    required this.items,
  });

  final String section;
  final ContentSource source;
  final List<ContentBook> items;
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  bool _loading = false;
  String _error = '';
  bool _searched = false;
  List<GlobalVideoGroup> _videoGroups = const [];
  List<_BookGroup> _bookGroups = const [];

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
    setState(() {
      _loading = true;
      _error = '';
      _searched = true;
    });
    try {
      await NovelSourceStore.applyToRegistry();
      final videoIds = widget.store.visibleSources.map((s) => s.id).toList();
      final videoPage = await widget.repository.searchAcross(videoIds, query);
      final videoGroups = groupGlobalVideoResults(
        videoPage.items,
        widget.store.sources,
      );
      final bookGroups = <_BookGroup>[];
      for (final entry in [
        ('听书', ContentRegistry.sourcesFor(ContentSection.audio)),
        ('阅读', ContentRegistry.sourcesFor(ContentSection.novel)),
      ]) {
        for (final source in entry.$2) {
          try {
            final page = await source.search(query, 1);
            if (page.items.isNotEmpty) {
              bookGroups.add(
                _BookGroup(
                  section: entry.$1,
                  source: source,
                  items: page.items,
                ),
              );
            }
          } catch (_) {}
        }
      }
      if (!mounted) return;
      bookGroups.sort((a, b) {
        final rank = globalSearchSectionRank(
          a.section,
        ).compareTo(globalSearchSectionRank(b.section));
        return rank != 0 ? rank : a.source.name.compareTo(b.source.name);
      });
      setState(() {
        _loading = false;
        _videoGroups = videoGroups;
        _bookGroups = bookGroups;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '搜索失败，请重试';
        });
      }
    }
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
      if (!sections.contains(group.section)) sections.add(group.section);
    }
    sections.sort(
      (a, b) =>
          globalSearchSectionRank(a).compareTo(globalSearchSectionRank(b)),
    );
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
          if (_loading)
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
          else if (_searched && _videoGroups.isEmpty && _bookGroups.isEmpty)
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
                      (g) => g.section == section,
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

  Widget _bookCard(_BookGroup group, ContentBook book) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        if (group.section == '阅读') {
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
