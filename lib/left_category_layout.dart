import 'package:flutter/material.dart';

import 'app_theme_config.dart';
import 'catalog_filters.dart';
import 'compact_chip.dart';
import 'core_bridge.dart';
import 'flip_card_stack.dart';
import 'models.dart';

/// 左侧分类布局（第 9 套主题“左侧分类”专属，只随主题切换出现，不另设开关）。
///
/// 结构（效果图为准）：左侧一级分类纵栏 + 右侧顶部二级分类横排 +
/// 筛选行 + 中间 3D 翻页卡堆 + 下方现有网格（由调用方以 [body] 传入，
/// 本布局不重写网格）。效果图底部的胶囊栏不在范围，本布局不画。
///
/// 数据全部取站点真实返回：二级行、筛选行、标签行、卡堆任一没有数据
/// 就整行隐藏，绝不编假选项。分类与筛选点选走调用方传入的回调，与
/// 现有分类行/筛选行同一链路（`_changeCategory` / `_changeFilter`）。
class LeftCategoryLayout extends StatelessWidget {
  const LeftCategoryLayout({
    super.key,
    required this.categories,
    required this.selectedCategory,
    required this.onCategory,
    this.subCategories = const [],
    this.filterGroups = const [],
    this.selectedFilters = const {},
    this.onFilter,
    this.stackItems = const [],
    this.repository,
    this.onOpen,
    this.breadcrumb,
    this.catalogTags = const [],
    this.onOpenTag,
    this.level2Tags = const [],
    this.selectedTagLevel2,
    this.onSelectTagLevel2,
    this.level3Tags = const [],
    this.selectedTagLevel3,
    this.onSelectTagLevel3,
    required this.body,
  });

  /// 一级分类：站方分类（`splitCategoryLevels` 的 level1，含“全部”）。
  final List<CatalogCategory> categories;

  /// 当前选中分类 id（一级或二级都可能命中）。
  final String selectedCategory;

  /// 分类点选回调，与现有分类行同一链路。
  final ValueChanged<String> onCategory;

  /// 二级分类：本地归纳的题材筛分类（`splitCategoryLevels` 的 level2）。
  /// 为空时二级行整行隐藏。
  final List<CatalogCategory> subCategories;

  /// 筛选组：目录响应自带的 `CatalogPage.filters`，只含站点真实有的
  /// 维度与选项；为空或无回调时筛选行整行隐藏。
  final List<CatalogFilterGroup> filterGroups;
  final Map<String, String> selectedFilters;
  final void Function(String groupKey, String optionId)? onFilter;

  /// 卡堆数据：与首页轮播同一条（目录头部有封面的条目）；为空或无
  /// 仓库/回调时卡堆区整区隐藏。
  final List<Drama> stackItems;
  final AppRepository? repository;
  final void Function(Drama drama)? onOpen;

  /// 文件夹下钻时的面包屑（调用方有下钻栈时传入，否则不画）。
  final Widget? breadcrumb;

  /// 标签行（目录响应自带的标签集与条目标签归纳），与现有目录页
  /// 同一口径；为空或无回调时各行隐藏。
  final List<CatalogTag> catalogTags;
  final ValueChanged<CatalogTag>? onOpenTag;
  final List<String> level2Tags;
  final String? selectedTagLevel2;
  final ValueChanged<String?>? onSelectTagLevel2;
  final List<String> level3Tags;
  final String? selectedTagLevel3;
  final ValueChanged<String?>? onSelectTagLevel3;

  /// 下方内容区：调用方传入的现有网格/状态区（含加载、空态、网格）。
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final railWidth = (constraints.maxWidth * 0.26).clamp(76.0, 104.0);
        return Row(
          key: const ValueKey('left-category-layout'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: railWidth,
              child: _rail(config),
            ),
            Expanded(
              child: Column(
                children: [
                  if (breadcrumb != null) breadcrumb!,
                  if (subCategories.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _subRow(context),
                  ],
                  if (filterGroups.isNotEmpty && onFilter != null)
                    CatalogFilterRows(
                      groups: filterGroups,
                      selected: selectedFilters,
                      onSelected: onFilter!,
                    ),
                  if (catalogTags.isNotEmpty && onOpenTag != null) ...[
                    _tagRow(
                      context,
                      children: [
                        for (final tag in catalogTags)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: CompactFilterChip(
                              key: ValueKey('catalog-tag-${tag.id}'),
                              avatar: const Icon(
                                Icons.label_outline_rounded,
                                size: 11,
                              ),
                              label: tag.name,
                              selected: false,
                              onSelected: () => onOpenTag!(tag),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (level2Tags.isNotEmpty && onSelectTagLevel2 != null) ...[
                    _tagRow(
                      context,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: CompactFilterChip(
                            label: '全部标签',
                            selected: selectedTagLevel2 == null,
                            onSelected: () => onSelectTagLevel2!(null),
                          ),
                        ),
                        for (final tag in level2Tags)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: CompactFilterChip(
                              key: ValueKey('catalog-tag2-$tag'),
                              label: tag,
                              selected: selectedTagLevel2 == tag,
                              onSelected: () => onSelectTagLevel2!(
                                selectedTagLevel2 == tag ? null : tag,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (selectedTagLevel2 != null &&
                      level3Tags.isNotEmpty &&
                      onSelectTagLevel3 != null) ...[
                    _tagRow(
                      context,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: CompactFilterChip(
                            label: '全部',
                            selected: selectedTagLevel3 == null,
                            onSelected: () => onSelectTagLevel3!(null),
                          ),
                        ),
                        for (final tag in level3Tags)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: CompactFilterChip(
                              key: ValueKey('catalog-tag3-$tag'),
                              label: tag,
                              selected: selectedTagLevel3 == tag,
                              onSelected: () => onSelectTagLevel3!(
                                selectedTagLevel3 == tag ? null : tag,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (stackItems.isNotEmpty &&
                      repository != null &&
                      onOpen != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                      child: FlipCardStack(
                        key: const ValueKey('flip-card-stack'),
                        items: stackItems,
                        repository: repository!,
                        onOpen: onOpen!,
                      ),
                    ),
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 左侧一级分类纵栏：选中高亮，分类名完整显示不截断。
  Widget _rail(AppThemeConfig config) {
    return Container(
      decoration: BoxDecoration(
        color: config.surfaceColor,
        border: Border(right: BorderSide(color: config.dividerColor)),
      ),
      child: ListView.builder(
        key: const ValueKey('left-category-rail'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: categories.length,
        itemBuilder: (context, index) {
          final entry = categories[index];
          final selected = entry.id == selectedCategory;
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
            child: Material(
              color: selected ? config.selectedBg : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                key: ValueKey('left-category-item-${entry.id}'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => onCategory(entry.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 10,
                  ),
                  child: Center(
                    child: Text(
                      entry.name,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: selected
                            ? config.selectedText
                            : config.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 右侧顶部二级分类横排：只有二级数据时才渲染。
  Widget _subRow(BuildContext context) {
    return SizedBox(
      key: const ValueKey('left-category-sublevel'),
      height: compactChipHeight(context),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final entry in subCategories)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: CompactFilterChip(
                key: ValueKey('left-category-sub-${entry.id}'),
                label: entry.name,
                selected: entry.id == selectedCategory,
                onSelected: () => onCategory(entry.id),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tagRow(BuildContext context, {required List<Widget> children}) {
    return SizedBox(
      height: compactChipHeight(context),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: children,
      ),
    );
  }
}

