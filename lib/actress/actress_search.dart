import 'dart:async';

import 'actress_database.dart';
import 'actress_models.dart';
import '../core_bridge.dart';
import '../crosssite_probe.dart';
import '../local_store.dart';
import '../models.dart';

/// 全站搜索用的站源 id：可见视频站（与跨站探活同一口径，去网盘站）。
List<String> actressSearchSiteIds(LocalStore store) => [
  for (final site in store.visibleSources)
    if (site.isVideoSection &&
        !site.id.startsWith('cloud:') &&
        store.siteVisible(site.id))
      site.id,
];

/// 双键合流补全：人物页打开时后台跑，把站源搜索结果叠加进本地作品。
///
/// - 名字路：按显示名（+ 首个别名）搜全部可见站，命中按番号对上本地
///   作品后附封面；番号不在本地的命中新增为跨站发现作品（只限带番号
///   的命中，无番号命中只附到标题相同的已有行，不新增）；
/// - 番号路：对仍无封面的作品按番号逐个搜（每轮上限 120 个、并发 4），
///   只补已有行，不新增；
/// - 两路结果都按归一化番号去重（无番号按标题键），同一部只留一张卡；
/// - 搜过的结果写进库，下次打开同一人物直接读缓存（[ActressPerson.enrichedAt]
///   非空即跳过）；失败的站静默跳过，不弹错、不挡列表；
/// - 来源信息只写进库内字段供封面解析用，界面绝不显示。
class ActressEnrichment {
  ActressEnrichment({
    required this.repository,
    required this.store,
    required this.db,
    this.concurrency = 4,
    this.codeSearchCap = 120,
    this.nameHitsCap = 100,
  });

  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase db;
  final int concurrency;
  final int codeSearchCap;
  final int nameHitsCap;

  /// 跑一轮补全。返回 true 表示本轮已把能查的都查完（调用方记
  /// enrichedAt，下次打开不再跑）；返回 false 表示番号路触到上限，
  /// 还有没查的作品，下次打开继续。
  Future<bool> enrichPerson(
    ActressPerson person, {
    bool Function()? isCancelled,
    void Function()? onChanged,
  }) async {
    if (person.enrichedAt != null) return true;
    final works = await _allWorks(person.localId);
    if (works.isEmpty) return true;
    if (isCancelled?.call() == true) return false;

    final siteIds = actressSearchSiteIds(store);
    if (siteIds.isEmpty) return false;
    var changedAt = DateTime.fromMillisecondsSinceEpoch(0);
    void notifyChanged() {
      final now = DateTime.now();
      if (now.difference(changedAt).inMilliseconds < 500) return;
      changedAt = now;
      onChanged?.call();
    }

    await _enrichByName(person, siteIds, isCancelled, notifyChanged);
    if (isCancelled?.call() == true) return false;

    final refreshed = await _allWorks(person.localId);
    final uncovered = refreshed
        .where((work) => !work.hasCover && work.codeKey.isNotEmpty)
        .toList();
    final capped = uncovered.length > codeSearchCap;
    final targets = capped ? uncovered.take(codeSearchCap).toList() : uncovered;
    await _enrichByCode(person, targets, siteIds, isCancelled, notifyChanged);
    if (isCancelled?.call() == true) return false;
    onChanged?.call();
    return !capped;
  }

  Future<List<ActressWork>> _allWorks(int personId) async {
    const pageSize = 500;
    final out = <ActressWork>[];
    var offset = 0;
    while (true) {
      final page = await db.worksForPerson(
        personId,
        offset: offset,
        limit: pageSize,
      );
      if (page.isEmpty) break;
      out.addAll(page);
      if (page.length < pageSize) break;
      offset += page.length;
    }
    return out;
  }

  Future<void> _enrichByName(
    ActressPerson person,
    List<String> siteIds,
    bool Function()? isCancelled,
    void Function() notifyChanged,
  ) async {
    final queries = <String>[person.displayName];
    if (person.aliases.isNotEmpty) queries.add(person.aliases.first);
    for (final query in queries) {
      if (isCancelled?.call() == true) return;
      if (query.trim().isEmpty) continue;
      List<Drama> hits;
      try {
        final page = await repository.searchAcross(siteIds, query);
        hits = page.items;
      } catch (_) {
        continue;
      }
      var attached = 0;
      for (final hit in hits.take(nameHitsCap)) {
        if (isCancelled?.call() == true) return;
        if (actressTextBlocked(hit.title)) continue;
        final code = extractAvId(
          title: hit.title,
          id: hit.id,
          sourceId: hit.sourceId,
        );
        final codeKey = code == null ? '' : normalizeAvCode(code);
        await db.attachCover(
          personId: person.localId,
          codeKey: codeKey,
          titleKey: actressTitleKey(hit.title),
          codeDisplay: code ?? '',
          title: hit.title,
          coverSource: hit.source,
          coverDramaId: hit.id,
          coverUrl: hit.cover,
          // 无番号的命中只附已有行，不新增（防名字搜索的杂标题淹没列表）。
          insertIfMissing: codeKey.isNotEmpty,
        );
        attached++;
        if (attached % 10 == 0) notifyChanged();
      }
      notifyChanged();
    }
  }

  Future<void> _enrichByCode(
    ActressPerson person,
    List<ActressWork> targets,
    List<String> siteIds,
    bool Function()? isCancelled,
    void Function() notifyChanged,
  ) async {
    var next = 0;
    var attached = 0;
    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) return;
        if (next >= targets.length) return;
        final work = targets[next++];
        final query = work.codeDisplay.isNotEmpty
            ? work.codeDisplay
            : work.codeKey;
        if (query.isEmpty) continue;
        List<Drama> hits;
        try {
          final page = await repository.searchAcross(siteIds, query);
          hits = page.items;
        } catch (_) {
          continue;
        }
        for (final hit in hits) {
          if (actressTextBlocked(hit.title)) continue;
          if (hit.cover.isEmpty) continue;
          if (!crossSiteHitMatches(title: hit.title, id: hit.id, avId: query)) {
            continue;
          }
          await db.attachCover(
            personId: person.localId,
            codeKey: work.codeKey,
            titleKey: work.titleKey,
            coverSource: hit.source,
            coverDramaId: hit.id,
            coverUrl: hit.cover,
            insertIfMissing: false,
          );
          attached++;
          if (attached % 10 == 0) notifyChanged();
          break;
        }
      }
    }

    final workers = concurrency < targets.length ? concurrency : targets.length;
    if (workers <= 0) return;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }
}
