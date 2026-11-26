import '../core_bridge.dart';
import '../models.dart';
import 'actress_online_detail.dart';

/// py 复用在线源（2026-11-26 六源扩线口径修正）：AVDB、
/// JavMenu、MemoJav、MissAV 四源在组装树里已有现成 py 站
/// 源（assets/py_spiders/ 的 avdb.py / javmenu.py /
/// memojav.py / missav.py），不新写 Dart 取流，直接复用
/// 既有 py 蜘蛛链做在线线路查询——与 who's py 链同路子：
/// 按番号走仓库 searchProgress（蜘蛛 searchContent）→
/// detail（detailContent）→ resolve（playerContent，
/// parse=0 直链 + dict 头）。状态如实回填线路区/竞速。
class ActressPyLineSource {
  const ActressPyLineSource({
    required this.id,
    required this.label,
    this.lazy = false,
  });

  /// 蜘蛛 key（同时是 Drama.source / 站点 id）。
  final String id;

  /// 线路区显示名。
  final String label;

  /// 懒查询：默认不自动查、点「点击查询」才查（重源用）。
  final bool lazy;
}

/// py 复用线路表（顺序按 AvPlay「在线播放」页签的提及序：
/// AVDB、JavMenu、MemoJav、MissAV）。
const kActressPyLineSources = <ActressPyLineSource>[
  ActressPyLineSource(id: 'avdb', label: 'AVDB'),
  ActressPyLineSource(id: 'javmenu', label: 'JavMenu'),
  ActressPyLineSource(id: 'memojav', label: 'MemoJav'),
  ActressPyLineSource(id: 'missav', label: 'MissAV', lazy: true),
];

/// 竞速里走 py 链的三路（MissAV 不在此列：女优页竞速已有
/// who's/MissAV 直达详情的 B 路，不重复查）。
const kActressPyRaceSourceIds = <String>['avdb', 'javmenu', 'memojav'];

/// 一次 py 链命中的全套：命中的剧目、详情（集的 id 是蜘蛛
/// 播放 id）、已解析的播放计划（直链 + 头）。
class ActressPyLineHit {
  const ActressPyLineHit({
    required this.drama,
    required this.detail,
    required this.plan,
  });

  final Drama drama;
  final DramaDetail detail;
  final PlaybackPlan plan;
}

/// 按番号在 py 链里查一条可播线路：
/// - MissAV 特殊：蜘蛛按番号直达详情（detailContent 吃番
///   号本身，与女优页竞速 B 路同口径），不走搜索；
/// - 其余三源：先 searchProgress 按番号搜，标题或 id 归一
///   后含番号才认命中（对不上不算找到、不拿别片充数），
///   再 detail + resolve 首集；
/// - resolve 出解析型计划（needsParse）或空地址都算没查
///   到（线路只认 parse=0 真直链，与全壳口径一致）。
/// 任何一步失败/落空回 null，不抛错、不编线路。
Future<ActressPyLineHit?> actressPyLineHit({
  required AppRepository repository,
  required String sourceId,
  required String code,
}) async {
  final target = actressCodeKey(code);
  if (target.isEmpty) return null;
  try {
    Drama? drama;
    if (sourceId == 'missav') {
      drama = Drama(id: code.trim(), source: 'missav', title: code.trim());
    } else {
      final page = await repository.searchProgress(sourceId, code.trim());
      for (final item in page.items) {
        if (actressCodeKey(item.title).contains(target) ||
            actressCodeKey(item.id).contains(target)) {
          drama = item;
          break;
        }
      }
      if (drama == null) return null;
    }
    final detail = await repository.detail(drama);
    if (detail.episodes.isEmpty) return null;
    final plan = await repository.resolve(drama, detail.episodes.first);
    if (plan.needsParse || plan.url.trim().isEmpty) return null;
    return ActressPyLineHit(drama: drama, detail: detail, plan: plan);
  } catch (_) {
    return null;
  }
}

/// py 命中转直链详情（线路区点播用，形状与
/// actressOnlinePlayDetail 一致：direct 集 + 播放头，交给
/// 正式播放器起播）。
DramaDetail actressPyLineDetail({
  required ActressPyLineSource source,
  required String code,
  required ActressPyLineHit hit,
}) {
  final title = hit.drama.title.isNotEmpty ? hit.drama.title : code;
  final drama = Drama(
    id: hit.drama.id,
    source: source.id,
    sourceId: hit.drama.id,
    title: title,
    cover: hit.drama.cover,
    tags: [code],
  );
  return DramaDetail(
    drama,
    [
      Episode({
        'id': hit.plan.url,
        'title': '正片',
        'direct': true,
        'headers': hit.plan.headers,
      }, 1),
    ],
    backdrop: hit.drama.cover,
  );
}
