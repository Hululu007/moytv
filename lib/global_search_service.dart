import 'dart:async';

import 'content_models.dart';

/// 全局搜索里一个阅读站的一组结果（听书 / 阅读两区共用）。
class GlobalSearchBookGroup {
  const GlobalSearchBookGroup({
    required this.section,
    required this.source,
    required this.items,
  });

  final ContentSection section;
  final ContentSource source;
  final List<ContentBook> items;
}

/// 全局搜索的阅读目标站：注册表里的一个可搜源。
class GlobalSearchBookTarget {
  const GlobalSearchBookTarget({required this.source, required this.section});

  final ContentSource source;
  final ContentSection section;
}

/// 阅读目标站表（纯函数，可单测）：听书区 + 阅读区注册表全量收录，
/// 一个不落；同 id 只留先出现的（听书优先），不重复搜。
///
/// 魔蚁没有境界 / 修为系统，午夜门禁早已整段摘掉，成人源也在列，
/// 不做任何门禁过滤；漫画挂在阅读区里，不单独成区。视频站不走这里：
/// 视频侧以站源注册表为准，由 [searchAcross] 一次扇出（见全局搜索页）。
List<GlobalSearchBookTarget> globalSearchBookTargets({
  required List<ContentSource> audioSources,
  required List<ContentSource> novelSources,
}) {
  final seen = <String>{};
  final targets = <GlobalSearchBookTarget>[];
  for (final entry in [
    (ContentSection.audio, audioSources),
    (ContentSection.novel, novelSources),
  ]) {
    for (final source in entry.$2) {
      if (!seen.add(source.id)) continue;
      targets.add(GlobalSearchBookTarget(source: source, section: entry.$1));
    }
  }
  return targets;
}

/// 单站搜索预算：单个源超时只回空组，不拖垮整轮搜索。
const globalSearchPerSiteTimeout = Duration(seconds: 30);

/// 对一批阅读目标站并行搜索（执行层，可单测）：单站超时 / 报错 /
/// 无结果只回空组，不拖垮整次搜索；只有出结果的站才进返回列表，
/// 顺序与目标站表一致（展示层再按区排序）。
Future<List<GlobalSearchBookGroup>> searchReadingTargets(
  String query,
  List<GlobalSearchBookTarget> targets, {
  Duration perSiteTimeout = globalSearchPerSiteTimeout,
}) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty || targets.isEmpty) return const [];
  final results = await Future.wait(
    targets.map((target) async {
      try {
        final page = await target.source
            .search(trimmed, 1)
            .timeout(perSiteTimeout);
        if (page.items.isEmpty) return null;
        return GlobalSearchBookGroup(
          section: target.section,
          source: target.source,
          items: page.items,
        );
      } catch (_) {
        return null;
      }
    }),
  );
  return [for (final result in results) ?result];
}
