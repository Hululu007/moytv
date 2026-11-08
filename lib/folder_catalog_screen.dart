import 'dart:async';

import 'app_page_route.dart';

import 'package:flutter/material.dart';

import 'catalog_browser.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_queue.dart';
import 'widgets.dart';

/// 文件夹/标签目录里点开视频卡的回调：带当前列表上下文队列
/// （PlaybackQueue，供播放器单集上下滑切条目）。
typedef FolderCatalogOpen = void Function(Drama drama, PlaybackQueue? queue);

/// DetailScreen.onTagTap 的标准壳侧实现：各列表页构造 DetailScreen 时
/// 以此注入 onTagTap，签名 (sourceId, tagId, tagName)。
void openDetailTag(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required String sourceId,
  required String tagId,
  required String tagName,
  required FolderCatalogOpen onOpenDrama,
}) {
  unawaited(
    FolderCatalogScreen.openTag(
      context,
      repository: repository,
      store: store,
      source: sourceId,
      tag: CatalogTag(tagId, tagName),
      onOpenDrama: onOpenDrama,
    ),
  );
}

/// 文件夹 / 标签目录页：以某个 folderId 作为 category 参数向核心请求
/// 单站目录，条目仍可为文件夹（递归下钻，层级不限）或视频卡。
///
/// 可复用入口（详情页标签跳转用）：
///   FolderCatalogScreen.openTag(context,
///     repository: ..., store: ...,
///     source: drama.source, tag: CatalogTag('actor:xxx', '名字'),
///     onOpenDrama: (drama) => ...);
///   FolderCatalogScreen.openFolder(context, ..., folderId: item.folderId)
class FolderCatalogScreen extends StatefulWidget {
  const FolderCatalogScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.source,
    required this.category,
    required this.title,
    required this.onOpenDrama,
  });

  final AppRepository repository;
  final LocalStore store;
  final String source;
  final String category;
  final String title;
  final FolderCatalogOpen onOpenDrama;

  /// 按标签打开目录：tag.id 自动归一为 tag: 前缀的 folderId。
  static Future<void> openTag(
    BuildContext context, {
    required AppRepository repository,
    required LocalStore store,
    required String source,
    required CatalogTag tag,
    required FolderCatalogOpen onOpenDrama,
  }) => Navigator.of(context).push<void>(
    appPageRoute(
      builder: (_) => FolderCatalogScreen(
        repository: repository,
        store: store,
        source: source,
        category: tag.folderId,
        title: tag.name,
        onOpenDrama: onOpenDrama,
      ),
    ),
  );

  /// 按文件夹条目打开目录（子分类、标签集或视频列表均可）。
  static Future<void> openFolder(
    BuildContext context, {
    required AppRepository repository,
    required LocalStore store,
    required Drama folder,
    required FolderCatalogOpen onOpenDrama,
  }) => Navigator.of(context).push<void>(
    appPageRoute(
      builder: (_) => FolderCatalogScreen(
        repository: repository,
        store: store,
        source: folder.source,
        category: folder.folderId,
        title: folder.title,
        onOpenDrama: onOpenDrama,
      ),
    ),
  );

  @override
  State<FolderCatalogScreen> createState() => _FolderCatalogScreenState();
}

class _FolderCatalogScreenState extends State<FolderCatalogScreen> {
  late final CatalogBrowser _browser = CatalogBrowser(widget.repository);
  List<Drama> _items = const [];
  List<CatalogTag> _tags = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  SourceGroup get _group {
    final site = SourceSite.byId(widget.source);
    return SourceGroup(site.groupId, site.groupName, [site]);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_browser.cancel());
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final result = await _browser.load(
        _group,
        category: widget.category,
        more: more,
      );
      if (!mounted) return;
      setState(() {
        _items = result.items;
        _tags = result.tags;
        _hasMore = result.hasMore;
        _loading = false;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
      });
    }
  }

  void _open(Drama item) {
    if (item.isFolder) {
      unawaited(
        FolderCatalogScreen.openFolder(
          context,
          repository: widget.repository,
          store: widget.store,
          folder: item,
          onOpenDrama: widget.onOpenDrama,
        ),
      );
      return;
    }
    widget.onOpenDrama(item, PlaybackQueue.around(_items, item));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Column(
      children: [
        if (_tags.isNotEmpty)
          SizedBox(
            height: 35,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final tag in _tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(tag.name),
                      labelStyle: const TextStyle(fontSize: 8),
                      onPressed: () => unawaited(
                        FolderCatalogScreen.openTag(
                          context,
                          repository: widget.repository,
                          store: widget.store,
                          source: widget.source,
                          tag: tag,
                          onOpenDrama: widget.onOpenDrama,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator.adaptive())
              : _items.isEmpty
              ? StatusPanel(
                  title: '暂无内容',
                  message: _error ?? '该目录下暂时没有条目。',
                  onRetry: () => _load(),
                )
              : RefreshIndicator.adaptive(
                  onRefresh: () => _load(),
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        sliver: SliverGrid(
                          gridDelegate: dramaGridDelegate(
                            context,
                            MediaQuery.sizeOf(context).width - 32,
                          ),
                          delegate: SliverChildBuilderDelegate((_, index) {
                            final item = _items[index];
                            return DramaTile(
                              drama: item,
                              repository: widget.repository,
                              onTap: () => _open(item),
                              badge: item.isFolder
                                  ? (item.isTagFolder ? '标签' : '文件夹')
                                  : null,
                            );
                          }, childCount: _items.length),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator.adaptive()
                                : _hasMore
                                ? OutlinedButton.icon(
                                    onPressed: () => _load(more: true),
                                    icon: const Icon(Icons.expand_more_rounded),
                                    label: const Text('加载更多'),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    ),
  );
}
