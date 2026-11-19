import 'builtin_py_sites.dart';
import 'core_bridge.dart';
import 'crosssite_probe.dart';
import 'models.dart';
import 'tmdb/tmdb_metadata.dart';

/// 成人内容刮削优先链：MissAV 打头的大站 + AVDB 殿后 + 落回原链。
///
/// 只复用现有站源引擎（[AppRepository.searchAcross] + [AppRepository.detail]），
/// 不写裸请求、不另写解析器。番号匹配口径与跨站探活一致
/// （[extractAvId] + [crossSiteHitMatches]）；单站超时与总预算双重
/// 兜底，任何失败都静默换下一家，绝不抛错到调用方。
///
/// 触发门（两者皆无时立即返回 null，不发任何请求，非成人链路零影响）：
/// - 标题/id/sourceId 里带番号（[extractAvId] 非空）→ 按番号探；
/// - 源站是 🔞站（站名含 🔞）→ 按标题搜，取首命中详情。
///
/// 返回的 [Drama] 一律带原始 id/source，只换显示字段（标题/封面/
/// 简介/tags）：[Drama.merge] 遇 id 不同会整体替换身份，换身份就
/// 丢了原片的播放集数与来源。Drama 模型无演员字段，演员随 tags/简介走。
///
/// 海阔 WebView 详情够不着这条链，不做；Go 核、主题、播放器一律不动。

/// 刮削顺序（只试这张有名表）：MissAV 四个 jar 站 → Jable → AV01 →
/// JavMenu → MemoJav → AVDB 殿后。未注册/不可见的站静默跳过。
const adultScrapeSiteIds = <String>[
  'jar:missav30:ZakaMissav',
  'jar:missav30:ZakaMissavOff',
  'jar:zakatv:ZakaMirror',
  'jar:missav30:missavt',
  'jar:zakatv:ZakaJable',
  'jar:zakatv:zakav01',
  BuiltinPySites.javmenuSiteId,
  BuiltinPySites.memojavSiteId,
  BuiltinPySites.avdbSiteId,
];

/// 从站源表里排出本次刮削要试的站 id：只取有名表里的站，且必须
/// 已注册（在 [sites] 里）且可见（[siteVisible]），并排除当前正在看
/// 的站（[currentSourceId]，详情页路径与探活同一口径；网盘路径无
/// 本站可排，传空即可）。顺序即 [adultScrapeSiteIds] 的固定顺序，
/// 与站源表本身的顺序无关。
List<String> planAdultScrapeSiteIds({
  required List<SourceSite> sites,
  required bool Function(String siteId) siteVisible,
  String currentSourceId = '',
}) {
  final registered = <String>{for (final site in sites) site.id};
  return [
    for (final siteId in adultScrapeSiteIds)
      if (siteId != currentSourceId &&
          registered.contains(siteId) &&
          siteVisible(siteId))
        siteId,
  ];
}

/// 网盘刮削转换：只带标题/简介/封面。cast 留空——tags 里分不清
/// 演员与标签，宁缺毋滥，不拿标签冒充演员。
/// posterPath 放完整封面 URL 是安全的：`TmdbConfig.imageUrl` 对
/// http(s) 绝对地址原样返回，不拼 TMDB 图床前缀。
TmdbMetadata adultDramaToTmdbMetadata(Drama drama) => TmdbMetadata(
  title: drama.title,
  overview: drama.description,
  posterPath: drama.cover,
);

/// 成人刮削服务：顺序探有名表，首家刮到有效元数据即停。
class AdultScrapeService {
  AdultScrapeService({
    required this.repository,
    this.perSiteTimeout = const Duration(seconds: 10),
    this.totalBudget = const Duration(seconds: 30),
    this.maxHitsPerSite = 3,
  });

  final AppRepository repository;

  /// 单站预算（搜索 + 详情）：超时当该站失败，换下一家。
  final Duration perSiteTimeout;

  /// 整条链的总预算：预算耗尽时尚未起跑的站不再起跑。
  final Duration totalBudget;

  /// 每站最多试几个命中详情：首个详情失败时换下一个命中，
  /// 不拖垮整家站。
  final int maxHitsPerSite;

  /// 详情页路径：对 [drama] 做成人刮削，返回带原始身份的富化
  /// [Drama]；刮不到或非成人内容返回 null（调用方落回原链）。
  /// 本站（[Drama.source]）不进探查表。永不抛错。
  Future<Drama?> enrich(
    Drama drama, {
    required List<SourceSite> candidateSites,
    bool Function(String siteId)? siteVisible,
  }) async {
    try {
      return await _enrich(
        drama,
        candidateSites: candidateSites,
        siteVisible: siteVisible ?? (_) => true,
      );
    } catch (_) {
      return null;
    }
  }

  /// 网盘路径：只从文件名里提番号探查，无番号立即返回 null
  /// （不发任何请求）；无本站可排。返回的 [Drama] 只有显示字段，
  /// 调用方经 [adultDramaToTmdbMetadata] 转 TMDB 元数据。永不抛错。
  Future<Drama?> enrichFileName(
    String fileName, {
    required List<SourceSite> candidateSites,
    bool Function(String siteId)? siteVisible,
  }) async {
    try {
      final avId = extractAvId(title: fileName);
      if (avId == null) return null;
      final siteIds = planAdultScrapeSiteIds(
        sites: candidateSites,
        siteVisible: siteVisible ?? (_) => true,
      );
      final hit = await _probeByAvId(siteIds, avId);
      if (hit == null) return null;
      return Drama(
        id: '',
        source: '',
        title: hit.title,
        description: hit.description,
        cover: hit.cover,
        tags: hit.tags,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Drama?> _enrich(
    Drama drama, {
    required List<SourceSite> candidateSites,
    required bool Function(String siteId) siteVisible,
  }) async {
    final avId = extractAvId(
      title: drama.title,
      id: drama.id,
      sourceId: drama.sourceId,
    );
    final siteIds = planAdultScrapeSiteIds(
      sites: candidateSites,
      siteVisible: siteVisible,
      currentSourceId: drama.source,
    );
    if (avId != null) {
      final hit = await _probeByAvId(siteIds, avId);
      if (hit == null) return null;
      return _reidentify(original: drama, enriched: hit);
    }
    // 无番号：只有 🔞源站才按标题搜，否则立即返回、不发请求。
    if (!_isAdultSource(drama.source, candidateSites)) return null;
    final query = drama.title.trim();
    if (query.isEmpty) return null;
    final hit = await _probeByTitle(siteIds, query);
    if (hit == null) return null;
    return _reidentify(original: drama, enriched: hit);
  }

  /// 源站是否 🔞站：先在候选站源表里找站名，找不到落到
  /// [SourceSite.byId]（未知 id 回落红果站名，不含 🔞，不会误判）。
  bool _isAdultSource(String sourceId, List<SourceSite> candidateSites) {
    for (final site in candidateSites) {
      if (site.id == sourceId) return site.name.contains('🔞');
    }
    return SourceSite.byId(sourceId).name.contains('🔞');
  }

  /// 按番号顺序探：命中须与番号同一部片（[crossSiteHitMatches]，
  /// 与探活同一口径）；首家刮到有效元数据即停。
  Future<Drama?> _probeByAvId(List<String> siteIds, String avId) async {
    final deadline = DateTime.now().add(totalBudget);
    for (final siteId in siteIds) {
      if (DateTime.now().isAfter(deadline)) return null;
      try {
        final found = await _probeSite(
          siteId,
          avId,
          onlyMatchingAvId: avId,
        ).timeout(perSiteTimeout);
        if (found != null) return found;
      } catch (_) {
        // 该站搜索/详情失败或超时，静默换下一家。
      }
    }
    return null;
  }

  /// 按标题顺序探：取首命中详情（详情失败换下一个命中）。
  Future<Drama?> _probeByTitle(List<String> siteIds, String query) async {
    final deadline = DateTime.now().add(totalBudget);
    for (final siteId in siteIds) {
      if (DateTime.now().isAfter(deadline)) return null;
      try {
        final found = await _probeSite(
          siteId,
          query,
        ).timeout(perSiteTimeout);
        if (found != null) return found;
      } catch (_) {
        // 该站搜索/详情失败或超时，静默换下一家。
      }
    }
    return null;
  }

  /// 单站探查：搜索后逐个命中取详情，详情字段优先、命中卡片字段
  /// 补空；首个带有效元数据的详情即返回。无有效元数据返回 null。
  /// 不要求详情带可播集数：AVDB 这类元数据站的命中也照常接纳，
  /// 这与跨站探活（只要可播线路）不同。
  Future<Drama?> _probeSite(
    String siteId,
    String query, {
    String? onlyMatchingAvId,
  }) async {
    final page = await repository.searchAcross([siteId], query);
    final hits = page.items
        .where(
          (drama) =>
              onlyMatchingAvId == null ||
              crossSiteHitMatches(
                title: drama.title,
                id: drama.id,
                avId: onlyMatchingAvId,
              ),
        )
        .take(maxHitsPerSite);
    for (final hit in hits) {
      try {
        final detail = await repository.detail(hit);
        final merged = _mergeHitDetail(hit, detail.drama);
        if (_hasEnrichment(merged)) return merged;
      } catch (_) {
        // 某个命中取详情失败，换下一个命中。
      }
    }
    return null;
  }

  /// 详情字段优先、命中卡片字段补空，只留显示字段。
  Drama _mergeHitDetail(Drama hit, Drama detailDrama) => Drama(
    id: detailDrama.id.isNotEmpty ? detailDrama.id : hit.id,
    source: detailDrama.source.isNotEmpty ? detailDrama.source : hit.source,
    title: detailDrama.title.isNotEmpty ? detailDrama.title : hit.title,
    description: detailDrama.description.isNotEmpty
        ? detailDrama.description
        : hit.description,
    cover: detailDrama.cover.isNotEmpty ? detailDrama.cover : hit.cover,
    tags: detailDrama.tags.isNotEmpty ? detailDrama.tags : hit.tags,
  );

  /// 有效元数据：至少带封面、简介、tags 其中一项；三项全空的
  /// 命中不算刮到，继续往下一家探（避免空壳命中挡住 AVDB）。
  bool _hasEnrichment(Drama drama) =>
      drama.cover.isNotEmpty ||
      drama.description.isNotEmpty ||
      drama.tags.isNotEmpty;

  /// 换回原始身份：只取富化后的显示字段，其余字段一律用原始值，
  /// 保证 [Drama.merge] 走同 id 分支、不整体替换身份。
  Drama _reidentify({required Drama original, required Drama enriched}) =>
      Drama(
        id: original.id,
        source: original.source,
        sourceId: original.sourceId,
        title: enriched.title.isNotEmpty ? enriched.title : original.title,
        description: enriched.description.isNotEmpty
            ? enriched.description
            : original.description,
        cover: enriched.cover.isNotEmpty ? enriched.cover : original.cover,
        episodes: original.episodes,
        category: original.category,
        vip: original.vipStatus,
        heat: original.heat,
        views: original.views,
        onlineDate: original.onlineDate,
        tags: enriched.tags.isNotEmpty ? enriched.tags : original.tags,
        releaseStatus: original.releaseStatus,
        kind: original.kind,
        folderId: original.folderId,
        peers: original.peers,
      );
}
