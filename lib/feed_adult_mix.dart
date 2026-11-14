import 'dart:math';

import 'models.dart';

/// 全屏流成人频道与推荐频道混排的纯逻辑。
///
/// 口径与首页轮播 [hero_mix] 一致：只认 App 自身的 🔞 标记，调用方
/// 须先按可见性（`LocalStore.siteVisible`）过滤，藏起来的站绝不
/// 出现；顺序一会话内固定，只在数据刷新（重抽键变化）时重抽；
/// 取不到成人内容时原样回落，不留空位。

/// 推荐频道混入比例：每 [recommendAdultMixDenominator] 条里约 1 条
/// 成人条目（约五分之一）。
const recommendAdultMixDenominator = 5;

/// 成人频道每次重抽时取的成人站数上限（绝不全量拉站）。
const feedAdultMaxSites = 6;

/// 成人频道每站取的首页条目上限。
const feedAdultMaxPerSite = 8;

/// 单站首页里可进成人频道的条目：前 [max] 条带真封面的非文件夹
/// 条目（与轮播候选同一过滤口径，只放宽条数）。
List<Drama> feedAdultCandidates(
  List<Drama> items, {
  int max = feedAdultMaxPerSite,
}) {
  final out = <Drama>[];
  for (final drama in items) {
    if (drama.isFolder || drama.cover.trim().isEmpty) continue;
    out.add(drama);
    if (out.length >= max) break;
  }
  return out;
}

/// 成人频道列表：各站候选按站序拼接，并按（站源，id）去重。
List<Drama> buildAdultFeed(List<List<Drama>> perSite) {
  final seen = <String>{};
  final out = <Drama>[];
  for (final list in perSite) {
    for (final drama in list) {
      if (seen.add('${drama.source}|${drama.id}')) out.add(drama);
    }
  }
  return out;
}

/// 推荐频道混排：成人条目均匀散布进基础列表，每
/// [recommendAdultMixDenominator] 条里约 1 条成人。
///
/// 成人条目先按（站源，id）对基础位去重、再洗牌；成人为空时原样
/// 回落基础位；基础位为空时返回空（推荐频道不以成人内容顶替）。
/// 同输入同 [Random] 种子 → 同顺序。
List<Drama> mixRecommendFeed({
  required List<Drama> base,
  required List<Drama> adult,
  required Random random,
  int denominator = recommendAdultMixDenominator,
}) {
  if (base.isEmpty) return const [];
  final seen = base.map((drama) => '${drama.source}|${drama.id}').toSet();
  final picks = <Drama>[];
  for (final drama in adult) {
    if (drama.isFolder || drama.cover.trim().isEmpty) continue;
    if (!seen.add('${drama.source}|${drama.id}')) continue;
    picks.add(drama);
  }
  if (picks.isEmpty) return List.of(base);
  picks.shuffle(random);
  final step = denominator > 1 ? denominator - 1 : 1;
  final mixed = <Drama>[];
  var nextPick = 0;
  for (var i = 0; i < base.length; i++) {
    mixed.add(base[i]);
    if ((i + 1) % step == 0 && nextPick < picks.length) {
      mixed.add(picks[nextPick]);
      nextPick++;
    }
  }
  return mixed;
}

/// 混排重抽键：可见成人站集合或基础目录变化才重抽；同一份数据
/// 内键不变，牌序固定不自洗。
String feedMixKey(List<String> visibleAdultIds, String baseKey) =>
    '${visibleAdultIds.join(',')}|$baseKey';
