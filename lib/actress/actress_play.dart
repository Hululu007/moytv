import 'dart:async';

import 'actress_models.dart';
import 'actress_search.dart';
import '../core_bridge.dart';
import '../crosssite_probe.dart';
import '../local_store.dart';
import '../models.dart';

/// 一条候选线路：探活取回的详情 + 起播集序号（首版本首线路）。
class ActressPlayCandidate {
  const ActressPlayCandidate({
    required this.detail,
    required this.episodeIndex,
  });

  final DramaDetail detail;
  final int episodeIndex;
}

/// 静默换线播放链：点卡后按番号把各站候选排成一条链，挨个试。
///
/// - 候选顺序 = 跨站探活计划顺序（优先序表 → 🔞站 → 其余站），确定性
///   优先，不按延迟排；懒查计划（慢站/盾站/超名额）只在 eager 波次
///   无果或候选全部预检失败后才探；
/// - 起播前每候选都过 resolve 预检（单候选超时），首个解出的才推
///   播放器；预检失败的静默跳过，不弹错；
/// - 无番号的作品走标题模式：按标题搜全部可见站，取标题相符的命中
///   （每站首个）成链，其余流程相同；
/// - 每推一个候选前都查 [LocalStore.allowsSource] 并校验 profileEpoch
///   未变（与详情页 `_playCrossSite` 同一范式），用户切了身份立即停；
/// - 播放中途恢复耗尽时，播放器回调里继续调 [nextPlayable] 换下一个，
///   链耗尽才让播放器原错误界面留着；
/// - 来源信息只在内部流转，调用方绝不向界面暴露候选的站源身份。
class ActressPlayChain {
  ActressPlayChain({
    required this.repository,
    required this.store,
    required this.avId,
    this.titleQuery = '',
    this.candidateSites,
    CrossSiteProbeService? probeService,
    this.resolveTimeout = const Duration(seconds: 20),
    this.probeConcurrency = 4,
    this.titleHitsCap = 8,
  }) : _probeService =
           probeService ??
           CrossSiteProbeService(
             repository: repository,
             perSiteTimeout: const Duration(seconds: 15),
             eagerBudget: const Duration(seconds: 30),
             concurrency: 4,
             maxVersions: 1,
           ) {
    final plans = planCrossSiteRows(
      sites: candidateSites ?? store.visibleSources,
      siteVisible: store.siteVisible,
    );
    _pendingEager = [
      for (final plan in plans)
        if (!plan.provider.lazy && plan.siteId != null) plan,
    ];
    _pendingLazy = [
      for (final plan in plans)
        if (plan.provider.lazy && plan.siteId != null) plan,
    ];
  }

  final AppRepository repository;
  final LocalStore store;

  /// 探活番号：extractAvId 形态（如 SSIS-00123，保留原始前导零，
  /// 与 crossSiteHitMatches 的比对口径一致）。为空时走标题模式。
  final String avId;
  final String titleQuery;
  final List<SourceSite>? candidateSites;
  final CrossSiteProbeService _probeService;
  final Duration resolveTimeout;
  final int probeConcurrency;
  final int titleHitsCap;

  final _candidates = <ActressPlayCandidate>[];
  var _next = 0;
  late List<CrossSiteRowPlan> _pendingEager;
  late List<CrossSiteRowPlan> _pendingLazy;
  var _titleWaveDone = false;

  bool get hasMore =>
      _next < _candidates.length ||
      _pendingEager.isNotEmpty ||
      _pendingLazy.isNotEmpty ||
      (!_titleWaveDone && avId.isEmpty && titleQuery.isNotEmpty);

  /// 取下一个可播候选：按链序预检，首个解出的返回；链耗尽返回 null。
  /// 已试过的候选不再试；[shouldStop] 为真时立即停（界面已取消）。
  Future<ActressPlayCandidate?> nextPlayable({
    required int profileEpoch,
    bool Function()? shouldStop,
  }) async {
    if (avId.isEmpty && titleQuery.isEmpty) return null;
    while (true) {
      if (shouldStop?.call() == true) return null;
      if (store.profileEpoch != profileEpoch) return null;
      if (_next < _candidates.length) {
        final candidate = _candidates[_next++];
        if (!store.allowsSource(candidate.detail.drama.source)) continue;
        if (await _resolves(candidate, profileEpoch)) return candidate;
        continue;
      }
      if (avId.isNotEmpty) {
        if (_pendingEager.isNotEmpty) {
          final found = await _probeWave(_pendingEager, shouldStop);
          _candidates.addAll(found);
          if (found.isNotEmpty) continue;
        }
        if (_pendingLazy.isNotEmpty) {
          final found = await _probeWave(_pendingLazy, shouldStop);
          _candidates.addAll(found);
          if (found.isNotEmpty) continue;
        }
        return null;
      }
      if (!_titleWaveDone) {
        _titleWaveDone = true;
        final found = await _probeTitleWave(shouldStop);
        _candidates.addAll(found);
        if (found.isNotEmpty) continue;
      }
      return null;
    }
  }

  Future<bool> _resolves(
    ActressPlayCandidate candidate,
    int profileEpoch,
  ) async {
    final episodes = candidate.detail.episodes;
    if (candidate.episodeIndex < 0 ||
        candidate.episodeIndex >= episodes.length) {
      return false;
    }
    try {
      await repository
          .resolve(candidate.detail.drama, episodes[candidate.episodeIndex])
          .timeout(resolveTimeout);
      return store.profileEpoch == profileEpoch;
    } catch (_) {
      return false;
    }
  }

  /// 探一波计划：工作池并发 [probeConcurrency]；一旦已有命中且排在
  /// 它前面的计划都已出结果，就不再起跑新计划（在途的跑完，结果照收），
  /// 命中按计划顺序成链。起跑过的计划从 [pending] 里挪走。
  Future<List<ActressPlayCandidate>> _probeWave(
    List<CrossSiteRowPlan> pending,
    bool Function()? shouldStop,
  ) async {
    if (pending.isEmpty) return const [];
    final plans = List.of(pending);
    pending.clear();
    final results = <String, CrossSiteProbeResult>{};
    final resolved = <String>{};
    final order = <String, int>{
      for (var i = 0; i < plans.length; i++) plans[i].provider.id: i,
    };
    var next = 0;
    var stopStarting = false;

    bool exitCondition() {
      var bestFound = 1 << 30;
      for (final entry in results.entries) {
        if (entry.value.status == CrossSiteProbeStatus.found) {
          final index = order[entry.key] ?? 1 << 30;
          if (index < bestFound) bestFound = index;
        }
      }
      if (bestFound == 1 << 30) return false;
      for (var i = 0; i < bestFound; i++) {
        if (!resolved.contains(plans[i].provider.id)) return false;
      }
      return true;
    }

    Future<void> worker() async {
      while (!stopStarting) {
        if (shouldStop?.call() == true) return;
        if (next >= plans.length) return;
        final plan = plans[next++];
        final siteId = plan.siteId;
        if (siteId == null) {
          resolved.add(plan.provider.id);
          continue;
        }
        final result = await _probeService.probeProvider(
          plan.provider,
          siteId,
          avId,
        );
        results[plan.provider.id] = result;
        resolved.add(plan.provider.id);
        if (exitCondition()) stopStarting = true;
      }
    }

    final workers = probeConcurrency < plans.length
        ? probeConcurrency
        : plans.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    // 没起跑的计划放回待探列，下次 nextPlayable 接着探。
    for (var i = next; i < plans.length; i++) {
      pending.add(plans[i]);
    }
    final out = <ActressPlayCandidate>[];
    for (final plan in plans) {
      final result = results[plan.provider.id];
      if (result == null || result.status != CrossSiteProbeStatus.found) {
        continue;
      }
      if (result.versions.isEmpty) continue;
      final version = result.versions.first;
      if (version.lines.isEmpty) continue;
      out.add(
        ActressPlayCandidate(
          detail: version.detail,
          episodeIndex: version.lines.first.episodeIndex,
        ),
      );
    }
    return out;
  }

  /// 标题模式一波：按标题搜全部可见站，标题相符的命中每站取首个，
  /// 取详情成链。
  Future<List<ActressPlayCandidate>> _probeTitleWave(
    bool Function()? shouldStop,
  ) async {
    final siteIds = actressSearchSiteIds(store);
    if (siteIds.isEmpty) return const [];
    List<Drama> hits;
    try {
      final page = await repository.searchAcross(siteIds, titleQuery);
      hits = page.items;
    } catch (_) {
      return const [];
    }
    final queryKey = actressTitleKey(titleQuery);
    if (queryKey.length < 2) return const [];
    final seenSources = <String>{};
    final picked = <Drama>[];
    for (final hit in hits) {
      if (picked.length >= titleHitsCap) break;
      if (actressTextBlocked(hit.title)) continue;
      if (!actressTitleKey(hit.title).contains(queryKey)) continue;
      if (!seenSources.add(hit.source)) continue;
      picked.add(hit);
    }
    final out = <ActressPlayCandidate>[];
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (shouldStop?.call() == true) return;
        if (next >= picked.length) return;
        final hit = picked[next++];
        try {
          final detail = await repository.detail(hit);
          final lines = crossSiteLinesOf(detail);
          if (lines.isEmpty) continue;
          out.add(
            ActressPlayCandidate(
              detail: detail,
              episodeIndex: lines.first.episodeIndex,
            ),
          );
        } catch (_) {
          // 某命中取详情失败，换下一个，不拖垮整链。
        }
      }
    }

    final workers = probeConcurrency < picked.length
        ? probeConcurrency
        : picked.length;
    if (workers <= 0) return const [];
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return out;
  }
}

/// 作品起播用的番号：优先从显示番号里现取 extractAvId 形态（保留
/// 原始前导零，与探活比对口径一致），取不到用显示番号原文，
/// 再取不到从标题里现取，都没有返回 ''（走标题模式）。
String actressPlayAvId(ActressWork work) {
  final fromCode = work.codeDisplay.isNotEmpty
      ? extractAvId(title: work.codeDisplay)
      : null;
  if (fromCode != null) return fromCode;
  if (work.codeDisplay.isNotEmpty) return work.codeDisplay;
  return extractAvId(title: work.title) ?? '';
}
