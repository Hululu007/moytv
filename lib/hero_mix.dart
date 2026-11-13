import 'dart:math';

import 'midnight_zone.dart';
import 'models.dart';

/// 霓虹首页轮播混入成人站视频的纯逻辑：抽站、取条、混排、重抽键。
///
/// 口径（用户 2026-11-13 令，混着播、不全换）：基础位是当前站源的
/// 轮播位；成人位从可见的 🔞 站里随机抽站、各取首页前 1–2 条带真
/// 封面的视频，随机穿插进轮播，成人约占三分之一；同一份首页数据
/// 内牌序固定，只有首页数据刷新才重抽；成人取数失败/为空时回落
/// 基础位，绝不出现空图、假图、断链幻灯片。

/// 基础轮播位上限（与霓虹首页原有取法一致：目录头部 6 条）。
const heroMixMaxBaseSlides = 6;

/// 混入的成人幻灯片上限：6 基础 + 3 成人 = 9，成人占三分之一。
const heroMixMaxAdultSlides = 3;

/// 混排后轮播总上限。
const heroMixMaxTotalSlides = 9;

/// 每次重抽时随机抽的成人站数上限（绝不全量拉站）。
const heroMixMaxAdultSites = 4;

/// 每站取的首页条目上限。
const heroMixMaxPerSite = 2;

/// 单站取首页的超时：某站挂了不拖垮整次混排。
const heroMixSiteTimeout = Duration(seconds: 15);

/// 轮播基础位：目录前 [max] 条带真封面的非文件夹条目。
List<Drama> heroBaseSlides(
  List<Drama> items, {
  int max = heroMixMaxBaseSlides,
}) {
  final out = <Drama>[];
  for (final drama in items) {
    if (drama.isFolder || drama.cover.trim().isEmpty) continue;
    out.add(drama);
    if (out.length >= max) break;
  }
  return out;
}

/// 成人站抽样：只认 App 自身的 🔞 标记（[isAdultSourceName]），不按
/// 站名猜；调用方须先按可见性（`LocalStore.siteVisible`）过滤；
/// [excludeIds] 里的站不抽（基础位已有的站源，避免重复）。
List<SourceSite> sampleAdultSites(
  List<SourceSite> sites, {
  required Random random,
  int count = heroMixMaxAdultSites,
  Set<String> excludeIds = const {},
}) {
  final pool = sites
      .where(
        (site) =>
            !excludeIds.contains(site.id) && isAdultSourceName(site.name),
      )
      .toList();
  pool.shuffle(random);
  return pool.take(count).toList();
}

/// 单站首页页里可进轮播的条目：前 [max] 条带真封面的非文件夹条目。
List<Drama> adultHeroCandidates(
  List<Drama> items, {
  int max = heroMixMaxPerSite,
}) {
  final out = <Drama>[];
  for (final drama in items) {
    if (drama.isFolder || drama.cover.trim().isEmpty) continue;
    out.add(drama);
    if (out.length >= max) break;
  }
  return out;
}

/// 混排：成人条目按（站源，id）对基础位去重后，随机穿插进基础位。
///
/// 首位恒为基础首条：成人幻灯片异步补进时，轮播不重置用户正在看
/// 的位置（霓虹首页只在首条变化时才跳回第 0 页）。成人为空时原样
/// 回落基础位；基础位为空时返回空（调用方回落默认取法）。
List<Drama> mixHeroSlides({
  required List<Drama> base,
  required List<Drama> adult,
  required Random random,
  int maxAdult = heroMixMaxAdultSlides,
  int maxTotal = heroMixMaxTotalSlides,
}) {
  if (base.isEmpty) return const [];
  final seen = base.map((drama) => '${drama.source}|${drama.id}').toSet();
  final picks = <Drama>[];
  for (final drama in adult) {
    if (drama.isFolder || drama.cover.trim().isEmpty) continue;
    if (!seen.add('${drama.source}|${drama.id}')) continue;
    picks.add(drama);
    if (picks.length >= maxAdult) break;
  }
  if (picks.isEmpty) return List.of(base);
  picks.shuffle(random);
  final mixed = List.of(base);
  for (final pick in picks) {
    // 插在 [1, length] 之间，首位不动。
    mixed.insert(1 + random.nextInt(mixed.length), pick);
  }
  return mixed.take(maxTotal).toList();
}

/// 混排重抽键：基础位内容变化（换站/刷新/搜词/切分类）才重抽；
/// 同一份首页数据内键不变，牌序固定不自洗。
String heroMixKey(List<Drama> base) =>
    '${base.length}|${base.map((drama) => '${drama.source}|${drama.id}').join(',')}';
