import 'dart:async';
import 'dart:math';

import 'core_bridge.dart';
import 'feed_adult_mix.dart';
import 'feed_playability.dart';
import 'hero_mix.dart';
import 'local_store.dart';
import 'models.dart';

/// 底部中间播放键打开的全屏流取数器。
///
/// 口径（用户 2026-11-16 令）：主内容固定取红果短剧，不跟站点
/// 切换走；再混入成人推荐——每次打开/刷新都随机重新挑，只从
/// 可见的成人站里挑（藏起来的站不参与），成人站取不到内容时
/// 回落纯红果短剧，绝不空屏、绝不编假数据。红果本身取不到时
/// 抛错，调用方显示重试。
class CenterFeedData {
  const CenterFeedData({required this.dramas, required this.categories});

  /// 混排后的流条目（红果 + 验播过的成人推荐），或纯红果。
  final List<Drama> dramas;

  /// 红果分类（已去掉“全部”与文件夹类，屏里自己画“全部”芯片；
  /// 取不到时为空，屏里只剩“全部”）。
  final List<CatalogCategory> categories;
}

class CenterFeedLoader {
  CenterFeedLoader({
    required this.repository,
    required this.store,
    FeedPlayabilityVerifier? verifier,
    Random? random,
    this.adultSiteTimeout = heroMixSiteTimeout,
    this.hongguoTimeout = const Duration(seconds: 30),
  }) : _verifier = verifier,
       _random = random ?? Random();

  /// 全屏流的固定主站：红果短剧。
  static const hongguoSourceId = 'hongguo';

  final AppRepository repository;
  final LocalStore store;
  final FeedPlayabilityVerifier? _verifier;
  final Random _random;
  final Duration adultSiteTimeout;
  final Duration hongguoTimeout;

  /// 自有验播器（紧预算：全屏流打开就要播，不能久等；会话内
  /// 缓存，同一屏内切分类不重验）。
  late final FeedPlayabilityVerifier _ownedVerifier =
      FeedPlayabilityVerifier(
        detailOf: (drama) async {
          try {
            return await repository.detail(drama);
          } catch (_) {
            return null;
          }
        },
        resolveOf: (drama, episode) => repository.resolve(drama, episode),
        itemTimeout: const Duration(seconds: 5),
        batchBudget: const Duration(seconds: 12),
        concurrency: 6,
      );

  FeedPlayabilityVerifier get _effectiveVerifier =>
      _verifier ?? _ownedVerifier;

  /// 取一屏全屏流数据：红果分类 + 该分类红果目录 + 随机成人推荐。
  ///
  /// [categoryId] 为空 = 全部。红果目录取不到/超时抛错；红果
  /// 目录为空返回空数据（不拿成人内容顶替）；成人阶段任何失败
  /// 都回落纯红果。
  Future<CenterFeedData> load(String categoryId) async {
    List<CatalogCategory> categories = const [];
    try {
      final fetched = await repository.categories(hongguoSourceId);
      categories = fetched
          .where((category) => category.id.isNotEmpty && !category.isFolder)
          .toList();
    } catch (_) {
      categories = const [];
    }
    final page = await repository
        .catalog(hongguoSourceId, category: categoryId)
        .timeout(hongguoTimeout);
    final base = page.items.where((drama) => drama.kind == 'video').toList();
    if (base.isEmpty) {
      return CenterFeedData(dramas: const [], categories: categories);
    }
    var mixed = base;
    try {
      final sites = sampleAdultSites(
        store.sources
            .where((site) => store.siteVisible(site.id) && !site.isHtmlSite)
            .toList(),
        random: _random,
        count: feedAdultMaxSites,
        excludeIds: const {hongguoSourceId},
      );
      if (sites.isNotEmpty) {
        final results = await Future.wait(
          sites.map((site) async {
            try {
              final sitePage = await repository
                  .catalog(site.id)
                  .timeout(adultSiteTimeout);
              return feedAdultCandidates(sitePage.items);
            } catch (_) {
              return const <Drama>[];
            }
          }),
        );
        final adult = buildAdultFeed(results);
        if (adult.isNotEmpty) {
          final verified = await _effectiveVerifier.verifyAll(adult);
          if (verified.isNotEmpty) {
            mixed = mixRecommendFeed(
              base: base,
              adult: verified,
              random: _random,
            );
          }
        }
      }
    } catch (_) {
      mixed = base;
    }
    return CenterFeedData(dramas: mixed, categories: categories);
  }
}
