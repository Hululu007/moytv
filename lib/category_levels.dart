import 'models.dart';

/// 分类分两级（用户叫法：一级/二级）。
///
/// 级数判定来自分类数据的真实来源，不编分组：
/// - 一级：站方分类接口返回的分类（`local` 为 false），如全部、真人剧、
///   漫剧、小说、听书——点选后按站方路由取目录；
/// - 二级：由已缓存条目的题材字段归纳出的本地筛分类（`local` 为
///   true，id 带 `local:` 前缀），如冒险、剧情、动作——点选后在
///   当前目录内按题材筛片子（见 `CatalogBrowser` 的本地筛选口径）。
///
/// 一级为空时不分级，全部归入一级，原样单排显示，避免只剩二级
/// 的空首排。
({List<CatalogCategory> level1, List<CatalogCategory> level2})
splitCategoryLevels(List<CatalogCategory> categories) {
  final level1 = categories.where((entry) => !entry.local).toList();
  final level2 = categories.where((entry) => entry.local).toList();
  if (level1.isEmpty) return (level1: categories, level2: const []);
  return (level1: level1, level2: level2);
}
