import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme_config.dart';
import '../category_sidebar.dart';
import '../core_bridge.dart';
import '../models.dart';
import '../widgets.dart';
import 'neon_ui.dart';

/// 霓虹频道页（参考「频道分类」布局）：
/// 大标题 + 筛选行（首页入口 / 类型胶囊）→ 左侧竖排频道 + 右侧交错媒体墙。
///
/// 纯展示组件：分类、筛选、分页全部由外层注入。
class NeonChannelView extends StatelessWidget {
  const NeonChannelView({
    super.key,
    required this.items,
    required this.repository,
    required this.categories,
    required this.selectedCategory,
    required this.onCategory,
    required this.onOpen,
    required this.onBack,
    required this.onSearch,
    required this.onFilter,
    required this.onRankings,
    this.onLoadMore,
    this.sortLabel = '全部类型',
    this.filtersActive = false,
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = false,
    this.scrollController,
  });

  final List<Drama> items;
  final AppRepository repository;
  final List<CatalogCategory> categories;
  final String selectedCategory;
  final ValueChanged<String> onCategory;
  final ValueChanged<Drama> onOpen;
  final VoidCallback onBack;
  final VoidCallback onSearch;
  final VoidCallback onFilter;
  final VoidCallback onRankings;
  final VoidCallback? onLoadMore;
  final String sortLabel;
  final bool filtersActive;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Column(
      children: [
        _header(config),
        _filterBar(),
        const SizedBox(height: 6),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CategorySidebar(
                config: config,
                items: [
                  const CategorySidebarItem(id: '', name: '热门'),
                  for (final category in categories)
                    CategorySidebarItem(
                      id: category.id,
                      name: category.name,
                    ),
                ],
                selectedId: selectedCategory,
                onSelect: onCategory,
              ),
              const SizedBox(width: 8),
              Expanded(child: _wall(config)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(AppThemeConfig config) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 12, 4),
      child: Row(
        children: [
          NeonIconButton(
            key: const ValueKey('neon-channel-back'),
            icon: LucideIcons.chevronLeft,
            onTap: onBack,
            size: 32,
            highlight: true,
          ),
          const SizedBox(width: 10),
          Text(
            '频道分类',
            style: TextStyle(
              fontSize: 25,
              height: 1.0,
              fontWeight: FontWeight.w900,
              letterSpacing: .5,
              color: config.textPrimary,
            ),
          ),
          const Spacer(),
          NeonIconButton(
            key: const ValueKey('neon-channel-search'),
            icon: LucideIcons.search,
            onTap: onSearch,
            size: 34,
          ),
          const SizedBox(width: 8),
          NeonIconButton(
            key: const ValueKey('neon-channel-rank'),
            icon: LucideIcons.trophy,
            onTap: onRankings,
            size: 34,
          ),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          const SizedBox(width: 14),
          _homeDot(),
          const SizedBox(width: 8),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 12),
              children: [
                NeonPill(
                  key: const ValueKey('neon-filter-all'),
                  label: sortLabel,
                  icon: const Icon(
                    LucideIcons.chevronDown,
                    size: 11,
                    color: Neon.textDim,
                  ),
                  selected: filtersActive,
                  onTap: onFilter,
                ),
                const SizedBox(width: 7),
                NeonPill(
                  label: '热门',
                  selected: !filtersActive,
                  onTap: onFilter,
                ),
                const SizedBox(width: 7),
                NeonPill(label: '最新', selected: false, onTap: onFilter),
                const SizedBox(width: 7),
                NeonPill(label: '完结', selected: false, onTap: onFilter),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _homeDot() {
    return GestureDetector(
      onTap: onBack,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: Neon.hotGradient,
          boxShadow: [
            BoxShadow(
              color: Neon.pink.withValues(alpha: .45),
              blurRadius: 14,
              spreadRadius: -3,
            ),
          ],
        ),
        child: const Icon(LucideIcons.house, size: 16, color: Colors.white),
      ),
    );
  }

  Widget _wall(AppThemeConfig config) {
    if (loading && items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator.adaptive(strokeWidth: 2),
      );
    }
    if (items.isEmpty) {
      return Center(
        child: Text(
          '这个频道暂时没有内容',
          style: TextStyle(color: config.textSecondary, fontSize: 12),
        ),
      );
    }
    // 每 3 张一组：左侧一张竖长大卡 + 右侧两张小卡（参考图交错节奏）。
    final groups = <List<Drama>>[];
    for (var i = 0; i < items.length; i += 3) {
      groups.add(items.sublist(i, (i + 3).clamp(0, items.length)));
    }
    return CustomScrollView(
      controller: scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(0, 4, 14, 8),
          sliver: SliverList.builder(
            itemCount: groups.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _group(groups[index], index),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Center(
              child: loadingMore
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : hasMore
                  ? GestureDetector(
                      onTap: onLoadMore ?? () {},
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
                  : Text(
                      '已经到底了',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: config.textSecondary,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _group(List<Drama> group, int groupIndex) {
    if (group.length == 1) {
      return SizedBox(
        height: 240,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _tile(group.first, groupIndex, 0, tall: true)),
            const SizedBox(width: 10),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      );
    }
    final rest = group.sublist(1);
    return SizedBox(
      height: 306,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _tile(group.first, groupIndex, 0, tall: true)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              children: [
                for (var i = 0; i < rest.length; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  Expanded(
                    child: _tile(rest[i], groupIndex, i + 1, tall: false),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(Drama drama, int groupIndex, int slot, {required bool tall}) {
    final badge = switch ((groupIndex + slot) % 4) {
      0 => 'HD',
      1 => 'NEW',
      _ => null,
    };
    return NeonPoster(
      key: ValueKey('neon-tile-${drama.id}'),
      cover: DramaCover(drama: drama, repository: repository, radius: 12),
      title: drama.title,
      subtitle: drama.tags.isNotEmpty
          ? drama.tags.take(2).join(' · ')
          : (drama.episodes > 0 ? '${drama.episodes} 集' : null),
      badge: badge,
      badgeColor: badge == 'NEW' ? Neon.pink : Neon.cyan,
      radius: 12,
      titleSize: tall ? 12 : 10.5,
      onTap: () => onOpen(drama),
    );
  }
}
