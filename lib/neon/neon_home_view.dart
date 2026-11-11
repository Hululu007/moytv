import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core_bridge.dart';
import '../models.dart';
import '../widgets.dart';
import 'neon_ui.dart';

/// 霓虹首页（参考「潮影」布局）：
/// 品牌栏 → 堆叠式主推轮播（居中大卡、两侧缩小压暗）→ 热播推荐横排 → 推荐网格。
///
/// 纯展示组件：数据、跳转、刷新全部由 HomeScreen 注入，避免复制业务逻辑。
class NeonHomeView extends StatefulWidget {
  const NeonHomeView({
    super.key,
    required this.items,
    required this.repository,
    required this.brand,
    required this.sourceLabel,
    required this.onOpen,
    required this.onSearch,
    required this.onSourceTap,
    required this.onLongPress,
    this.onRefresh,
    this.onMenu,
    this.onRankings,
    this.onFeaturedPlay,
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = false,
    this.onLoadMore,
    this.scrollController,
  });

  final List<Drama> items;
  final AppRepository repository;
  final String brand;
  final String sourceLabel;
  final ValueChanged<Drama> onOpen;
  final VoidCallback onSearch;
  final VoidCallback onSourceTap;
  final void Function(Drama drama) onLongPress;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onMenu;
  final VoidCallback? onRankings;
  final ValueChanged<Drama>? onFeaturedPlay;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final ScrollController? scrollController;

  @override
  State<NeonHomeView> createState() => _NeonHomeViewState();
}

class _NeonHomeViewState extends State<NeonHomeView> {
  late PageController _pages;
  Timer? _timer;
  int _page = 0;

  List<Drama> get _featured {
    final out = <Drama>[];
    for (final drama in widget.items) {
      if (drama.isFolder || drama.cover.trim().isEmpty) continue;
      out.add(drama);
      if (out.length >= 6) break;
    }
    return out.isEmpty ? widget.items.take(6).toList() : out;
  }

  @override
  void initState() {
    super.initState();
    _pages = PageController(viewportFraction: .68);
    _armTimer();
  }

  @override
  void didUpdateWidget(covariant NeonHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.items.firstOrNull?.id;
    final newId = widget.items.firstOrNull?.id;
    if (oldId != newId && _pages.hasClients) {
      _pages.jumpToPage(0);
      _page = 0;
    }
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    if (_featured.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_pages.hasClients) return;
      final next = (_page + 1) % _featured.length;
      _pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final featured = _featured;
    final gridItems = widget.items.where((item) => !item.isFolder).toList();

    return RefreshIndicator.adaptive(
      onRefresh: widget.onRefresh ?? () async {},
      color: Neon.purple,
      backgroundColor: Neon.surface,
      child: CustomScrollView(
        controller: widget.scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: NeonTopBar(
              brand: widget.brand,
              subtitle: widget.sourceLabel,
              leading: widget.onMenu == null
                  ? null
                  : GestureDetector(
                      key: const ValueKey('neon-avatar'),
                      onTap: widget.onMenu,
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: Neon.hotGradient,
                          boxShadow: [Neon.bloom(Neon.pink, blur: 16)],
                        ),
                        child: const Icon(
                          LucideIcons.user,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
              actions: [
                NeonIconButton(
                  key: const ValueKey('neon-top-search'),
                  icon: LucideIcons.search,
                  tooltip: '搜索',
                  onTap: widget.onSearch,
                ),
                NeonIconButton(
                  key: const ValueKey('neon-top-source'),
                  icon: LucideIcons.refreshCw,
                  tooltip: '切换/更新站源',
                  onTap: widget.onSourceTap,
                ),
              ],
            ),
          ),
          if (featured.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: width * .92,
                child: PageView.builder(
                  key: const ValueKey('neon-hero'),
                  controller: _pages,
                  itemCount: featured.length,
                  onPageChanged: (page) => setState(() => _page = page),
                  itemBuilder: (context, index) => _heroCard(
                    featured[index],
                    index == _page,
                  ),
                ),
              ),
            ),
          if (featured.length > 1)
            SliverToBoxAdapter(child: _dots(featured.length)),
          const SliverToBoxAdapter(
            child: NeonSectionHeader(title: '热播推荐', action: '全部'),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 178,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                itemCount: gridItems.length.clamp(0, 12),
                separatorBuilder: (_, _) => const SizedBox(width: 11),
                itemBuilder: (context, index) {
                  final drama = gridItems[index];
                  return SizedBox(
                    width: 112,
                    child: NeonPoster(
                      cover: DramaCover(
                        drama: drama,
                        repository: widget.repository,
                        radius: 14,
                      ),
                      title: drama.title,
                      subtitle: _subtitleOf(drama),
                      badge: index % 3 == 0 ? 'HD' : null,
                      badgeColor: index % 3 == 0 ? Neon.cyan : Neon.pink,
                      radius: 14,
                      titleSize: 10.5,
                      onTap: () => widget.onOpen(drama),
                      onLongPress: () => widget.onLongPress(drama),
                    ),
                  );
                },
              ),
            ),
          ),
          const SliverToBoxAdapter(
            child: NeonSectionHeader(title: '猜你想看'),
          ),
          if (widget.loading && gridItems.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
            )
          else if (gridItems.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  '这个站源暂时没有内容',
                  style: TextStyle(color: Neon.textDim, fontSize: 12),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: width < 600 ? 3 : 5,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 12,
                  childAspectRatio: .60,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final drama = gridItems[index];
                    return NeonPoster(
                      cover: DramaCover(
                        drama: drama,
                        repository: widget.repository,
                        radius: 12,
                      ),
                      title: drama.title,
                      subtitle: _subtitleOf(drama),
                      radius: 12,
                      titleSize: 10,
                      showTitle: false,
                      onTap: () => widget.onOpen(drama),
                      onLongPress: () => widget.onLongPress(drama),
                    );
                  },
                  childCount: gridItems.length,
                ),
              ),
            ),
          SliverToBoxAdapter(child: _footer()),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  String _subtitleOf(Drama drama) {
    if (drama.tags.isNotEmpty) return drama.tags.take(2).join(' · ');
    if (drama.episodes > 0) return '${drama.episodes} 集';
    if (drama.category.trim().isNotEmpty) return drama.category;
    return '';
  }

  Widget _heroCard(Drama drama, bool active) {
    final width = MediaQuery.sizeOf(context).width;
    final tags = <String>[
      if (drama.category.trim().isNotEmpty) drama.category,
      ...drama.tags,
    ].take(3).toList();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: width * .012, vertical: 8),
      child: AnimatedScale(
        scale: active ? 1 : .88,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: active ? 1 : .55,
          duration: const Duration(milliseconds: 260),
          child: GestureDetector(
            key: ValueKey('neon-hero-${drama.id}'),
            onTap: () => widget.onOpen(drama),
            onLongPress: () => widget.onLongPress(drama),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [neonDropShadow()],
              ),
              child: NeonFrame(
                radius: 24,
                thickness: 1.6,
                glow: false,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DramaCover(
                      drama: drama,
                      repository: widget.repository,
                      radius: 24,
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [.35, .72, 1],
                            colors: [
                              Colors.transparent,
                              const Color(0xFF0B0617).withValues(alpha: .55),
                              const Color(0xFF0B0617).withValues(alpha: .95),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 12,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A0F2E).withValues(alpha: .82),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .08),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  drama.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    height: 1.1,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                                if (tags.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      for (var i = 0; i < tags.length; i++) ...[
                                        if (i > 0) const SizedBox(width: 7),
                                        _tagDot(
                                          tags[i],
                                          [
                                            Neon.pink,
                                            Neon.cyan,
                                            Neon.purple,
                                          ][i % 3],
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 10),
                                NeonActionButton(
                                  label: '马上看',
                                  height: 34,
                                  onTap: () => (widget.onFeaturedPlay ??
                                          widget.onOpen)(drama),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tagDot(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: .8), blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: const TextStyle(fontSize: 9.5, color: Color(0xFFD3C6EA)),
        ),
      ],
    );
  }

  Widget _dots(int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              width: i == _page ? 16 : 5,
              height: 4,
              decoration: BoxDecoration(
                gradient: i == _page ? Neon.hotGradient : null,
                color: i == _page ? null : Colors.white.withValues(alpha: .22),
                borderRadius: BorderRadius.circular(2),
                boxShadow: i == _page
                    ? [
                        BoxShadow(
                          color: Neon.pink.withValues(alpha: .6),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Center(
        child: widget.loadingMore
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : widget.hasMore
            ? GestureDetector(
                onTap: widget.onLoadMore,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Neon.purple.withValues(alpha: .45),
                    ),
                    color: Neon.surfaceHigh.withValues(alpha: .8),
                  ),
                  child: const Text(
                    '加载更多',
                    style: TextStyle(fontSize: 11.5, color: Neon.textDim),
                  ),
                ),
              )
            : const Text(
                '已经到底了',
                style: TextStyle(fontSize: 10.5, color: Neon.textFaint),
              ),
      ),
    );
  }
}
