import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'neon_glass_kit.dart';

/// 侧边栏条目：id 与名字取自真实分类数据；filters 只有站方真实
/// 返回筛选数据时才有，没有就不画筛选区，绝不编假筛选。
class CategorySidebarItem {
  const CategorySidebarItem({
    required this.id,
    required this.name,
    this.filters = const [],
  });

  final String id;
  final String name;
  final List<CategorySidebarFilter> filters;
}

class CategorySidebarFilter {
  const CategorySidebarFilter({required this.name, required this.value});

  final String name;
  final String value;
}

/// 动态分类侧边栏：按当前主题绑定的样式自动切换 8 种形态。
///
/// 宽度取演示代码的 72–140 逻辑宽，并收敛到屏宽的 36% 以内，
/// 竖屏手机上不挤占右侧内容区。
class CategorySidebar extends StatelessWidget {
  const CategorySidebar({
    super.key,
    required this.config,
    required this.items,
    required this.selectedId,
    required this.onSelect,
    this.onFilter,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<CategorySidebarFilter>? onFilter;

  /// 演示宽度（逻辑宽）。
  static double demoWidthFor(CategoryNavStyle style) => switch (style) {
    CategoryNavStyle.darkSidebar => 110,
    CategoryNavStyle.colorBlockSidebar => 120,
    CategoryNavStyle.miniIconSidebar => 72,
    CategoryNavStyle.foldFilterSidebar => 140,
    CategoryNavStyle.lightSidebar => 110,
    CategoryNavStyle.goldSidebar => 120,
    CategoryNavStyle.cyberSidebar => 110,
    CategoryNavStyle.tvWideSidebar => 140,
  };

  /// 实际宽度：演示宽与屏宽 36% 取小。
  static double widthFor(CategoryNavStyle style, double screenWidth) {
    final demo = demoWidthFor(style);
    final cap = screenWidth * 0.36;
    return demo < cap ? demo : cap;
  }

  @override
  Widget build(BuildContext context) {
    final width = widthFor(
      config.navStyle,
      MediaQuery.sizeOf(context).width,
    );
    if (items.isEmpty) {
      return SizedBox(
        width: width,
        child: Container(
          color: config.surfaceColor,
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final selectedIndex = items.indexWhere((item) => item.id == selectedId);
    final effectiveIndex = selectedIndex < 0 ? 0 : selectedIndex;
    void onTap(int index) => onSelect(items[index].id);
    switch (config.navStyle) {
      case CategoryNavStyle.darkSidebar:
        return _DarkSidebar(
          config: config,
          items: items,
          selectedIndex: effectiveIndex,
          width: width,
          onTap: onTap,
        );
      case CategoryNavStyle.colorBlockSidebar:
        return _ColorBlockSidebar(
          config: config,
          items: items,
          selectedIndex: effectiveIndex,
          width: width,
          onTap: onTap,
        );
      case CategoryNavStyle.miniIconSidebar:
        return _MiniIconSidebar(
          config: config,
          items: items,
          selectedIndex: effectiveIndex,
          width: width,
          onTap: onTap,
        );
      case CategoryNavStyle.foldFilterSidebar:
        return _FoldFilterSidebar(
          config: config,
          items: items,
          selectedIndex: effectiveIndex,
          width: width,
          onTap: onTap,
          onFilter: onFilter,
        );
      case CategoryNavStyle.lightSidebar:
        return _LightSidebar(
          config: config,
          items: items,
          selectedIndex: effectiveIndex,
          width: width,
          onTap: onTap,
        );
      case CategoryNavStyle.goldSidebar:
        return _GoldSidebar(
          config: config,
          items: items,
          selectedIndex: effectiveIndex,
          width: width,
          onTap: onTap,
        );
      case CategoryNavStyle.cyberSidebar:
        return _CyberSidebar(
          config: config,
          items: items,
          selectedIndex: effectiveIndex,
          width: width,
          onTap: onTap,
        );
      case CategoryNavStyle.tvWideSidebar:
        return _TvWideSidebar(
          config: config,
          items: items,
          selectedIndex: effectiveIndex,
          width: width,
          onTap: onTap,
        );
    }
  }
}

Key _itemKey(String id) => ValueKey('category-sidebar-item-$id');

// -------------------- 样式1：简约暗黑侧边栏 --------------------
class _DarkSidebar extends StatelessWidget {
  const _DarkSidebar({
    required this.config,
    required this.items,
    required this.selectedIndex,
    required this.width,
    required this.onTap,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final int selectedIndex;
  final double width;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = config;
    return Container(
      width: width,
      color: theme.surfaceColor,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '影库',
              style: TextStyle(
                color: theme.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('category-sidebar-list'),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == selectedIndex;
                return Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: selected ? theme.selectedGradient : null,
                    color: selected ? null : theme.unselectedBg,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: selected ? [neonGlow(theme)] : null,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      key: _itemKey(item.id),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    leading: Icon(
                      Icons.category,
                      color: selected
                          ? theme.selectedText
                          : theme.unselectedText,
                      size: 18,
                    ),
                    title: Text(
                      item.name,
                      style: TextStyle(
                        color: selected
                            ? theme.selectedText
                            : theme.unselectedText,
                        fontSize: 13,
                      ),
                    ),
                    onTap: () => onTap(index),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- 样式2：彩色块侧边栏 --------------------
class _ColorBlockSidebar extends StatelessWidget {
  const _ColorBlockSidebar({
    required this.config,
    required this.items,
    required this.selectedIndex,
    required this.width,
    required this.onTap,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final int selectedIndex;
  final double width;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = config;
    // 色块取色：主色→辅色 6 档取样，色块缤纷但不出当前主题色系。
    Color blockTint(int index) {
      final t = (index % 6) / 5;
      return Color.lerp(theme.primaryColor, theme.secondaryColor, t)!
          .withValues(alpha: 0.35);
    }

    return Container(
      width: width,
      color: theme.surfaceColor,
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '分类',
              style: TextStyle(
                color: theme.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              key: const ValueKey('category-sidebar-list'),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == selectedIndex;
                return GestureDetector(
                  key: _itemKey(item.id),
                  onTap: () => onTap(index),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 46),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? theme.selectedBg : blockTint(index),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? theme.selectedBg
                            : Colors.transparent,
                        width: 2,
                      ),
                      boxShadow: selected ? [neonGlow(theme)] : null,
                    ),
                    child: Text(
                      item.name,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected
                            ? theme.selectedText
                            : theme.textPrimary,
                        fontWeight: selected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- 样式3：窄版迷你侧边栏 --------------------
class _MiniIconSidebar extends StatelessWidget {
  const _MiniIconSidebar({
    required this.config,
    required this.items,
    required this.selectedIndex,
    required this.width,
    required this.onTap,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final int selectedIndex;
  final double width;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = config;
    return Container(
      width: width,
      color: theme.surfaceColor,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Icon(Icons.movie_filter, color: theme.primaryColor),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('category-sidebar-list'),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == selectedIndex;
                return GestureDetector(
                  key: _itemKey(item.id),
                  onTap: () => onTap(index),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 56),
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? theme.selectedBg : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: selected ? [neonGlow(theme)] : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.category,
                          color: selected
                              ? theme.selectedText
                              : theme.unselectedText,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.name,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: selected
                                ? theme.selectedText
                                : theme.unselectedText,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- 样式4：带二级筛选折叠侧边栏 --------------------
class _FoldFilterSidebar extends StatefulWidget {
  const _FoldFilterSidebar({
    required this.config,
    required this.items,
    required this.selectedIndex,
    required this.width,
    required this.onTap,
    this.onFilter,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final int selectedIndex;
  final double width;
  final ValueChanged<int> onTap;
  final ValueChanged<CategorySidebarFilter>? onFilter;

  @override
  State<_FoldFilterSidebar> createState() => _FoldFilterSidebarState();
}

class _FoldFilterSidebarState extends State<_FoldFilterSidebar> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = widget.config;
    final item = widget.items[widget.selectedIndex];
    final filters = item.filters;
    final showFilters = _expanded && filters.isNotEmpty;
    return Container(
      width: widget.width,
      color: theme.surfaceColor,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  '分类',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Icon(
                    _expanded
                        ? Icons.arrow_drop_up
                        : Icons.arrow_drop_down,
                    color: theme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (showFilters)
            SizedBox(
              height: 140,
              child: _categoryList(theme),
            )
          else
            Expanded(child: _categoryList(theme)),
          if (showFilters) ...[
            Divider(color: theme.dividerColor),
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 8, bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '筛选',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('category-sidebar-filters'),
                itemCount: filters.length,
                itemBuilder: (context, index) {
                  final filter = filters[index];
                  final row = Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    child: Text(
                      filter.name,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  );
                  final onFilter = widget.onFilter;
                  if (onFilter == null) return row;
                  return GestureDetector(
                    key: ValueKey('category-sidebar-filter-${filter.value}'),
                    onTap: () => onFilter(filter),
                    child: row,
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _categoryList(AppThemeConfig theme) {
    return ListView.builder(
      key: const ValueKey('category-sidebar-list'),
      itemCount: widget.items.length,
      itemBuilder: (context, index) {
        final cat = widget.items[index];
        final selected = index == widget.selectedIndex;
        return GestureDetector(
          key: _itemKey(cat.id),
          onTap: () => widget.onTap(index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? theme.selectedBg : Colors.transparent,
              border: selected
                  ? Border(
                      left: BorderSide(color: theme.primaryColor, width: 3),
                    )
                  : null,
            ),
            child: Text(
              cat.name,
              style: TextStyle(
                color: selected ? theme.selectedText : theme.unselectedText,
              ),
            ),
          ),
        );
      },
    );
  }
}

// -------------------- 样式5：浅色侧边栏 --------------------
class _LightSidebar extends StatelessWidget {
  const _LightSidebar({
    required this.config,
    required this.items,
    required this.selectedIndex,
    required this.width,
    required this.onTap,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final int selectedIndex;
  final double width;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = config;
    return Container(
      width: width,
      color: theme.surfaceColor,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Icon(Icons.video_library, color: theme.primaryColor),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('category-sidebar-list'),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == selectedIndex;
                return GestureDetector(
                  key: _itemKey(item.id),
                  onTap: () => onTap(index),
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 10,
                    ),
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? theme.selectedBg
                          : theme.unselectedBg,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: selected ? [neonGlow(theme)] : null,
                    ),
                    child: Center(
                      child: Text(
                        item.name,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: selected
                              ? theme.selectedText
                              : theme.unselectedText,
                          fontWeight: selected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- 样式6：黑金侧边栏 --------------------
class _GoldSidebar extends StatelessWidget {
  const _GoldSidebar({
    required this.config,
    required this.items,
    required this.selectedIndex,
    required this.width,
    required this.onTap,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final int selectedIndex;
  final double width;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = config;
    return Container(
      width: width,
      color: theme.surfaceColor,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              gradient: theme.selectedGradient,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'VIP',
              style: TextStyle(
                color: theme.selectedText,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('category-sidebar-list'),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == selectedIndex;
                return Container(
                  margin: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 10,
                  ),
                  decoration: BoxDecoration(
                    gradient: selected ? theme.selectedGradient : null,
                    color: selected ? null : theme.unselectedBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected
                          ? theme.selectedBg
                          : Colors.transparent,
                    ),
                    boxShadow: selected ? [neonGlow(theme)] : null,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      key: _itemKey(item.id),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    leading: Icon(
                      Icons.stars,
                      color: selected
                          ? theme.selectedText
                          : theme.unselectedText,
                      size: 18,
                    ),
                    title: Text(
                      item.name,
                      style: TextStyle(
                        color: selected
                            ? theme.selectedText
                            : theme.unselectedText,
                      ),
                    ),
                    onTap: () => onTap(index),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- 样式7：赛博侧边栏 --------------------
class _CyberSidebar extends StatelessWidget {
  const _CyberSidebar({
    required this.config,
    required this.items,
    required this.selectedIndex,
    required this.width,
    required this.onTap,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final int selectedIndex;
  final double width;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = config;
    return Container(
      width: width,
      color: theme.surfaceColor,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Text(
            'CYBER TV',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.primaryColor,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('category-sidebar-list'),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == selectedIndex;
                return Container(
                  margin: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 10,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? theme.selectedBg : Colors.transparent,
                    border: Border.all(
                      color: selected
                          ? theme.selectedBg
                          : theme.dividerColor,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: theme.primaryColor.withValues(alpha: 0.6),
                              blurRadius: 10,
                            ),
                          ]
                        : [],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      key: _itemKey(item.id),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    leading: Icon(
                      Icons.memory,
                      color: selected
                          ? theme.selectedText
                          : theme.unselectedText,
                      size: 18,
                    ),
                    title: Text(
                      item.name,
                      style: TextStyle(
                        color: selected
                            ? theme.selectedText
                            : theme.unselectedText,
                      ),
                    ),
                    onTap: () => onTap(index),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- 样式8：TV宽侧边栏 --------------------
class _TvWideSidebar extends StatelessWidget {
  const _TvWideSidebar({
    required this.config,
    required this.items,
    required this.selectedIndex,
    required this.width,
    required this.onTap,
  });

  final AppThemeConfig config;
  final List<CategorySidebarItem> items;
  final int selectedIndex;
  final double width;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = config;
    return Container(
      width: width,
      color: theme.surfaceColor,
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          Text(
            'TV BOX',
            style: TextStyle(
              color: theme.primaryColor,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('category-sidebar-list'),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = index == selectedIndex;
                return Container(
                  margin: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 12,
                  ),
                  decoration: BoxDecoration(
                    gradient: selected ? theme.selectedGradient : null,
                    color: selected ? null : theme.unselectedBg,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: selected ? [neonGlow(theme)] : null,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      key: _itemKey(item.id),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                    leading: Icon(
                      Icons.tv,
                      color: selected
                          ? theme.selectedText
                          : theme.unselectedText,
                    ),
                    title: Text(
                      item.name,
                      style: TextStyle(
                        color: selected
                            ? theme.selectedText
                            : theme.unselectedText,
                        fontSize: 15,
                        fontWeight: selected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    onTap: () => onTap(index),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
