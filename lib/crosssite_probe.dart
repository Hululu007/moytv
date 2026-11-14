import 'dart:async';

import 'core_bridge.dart';
import 'models.dart';

/// 跨站选线路：详情页按番号向多家站源探活，平台→版本→线路三级。
/// 规格见 ~/workspace/moyi_crosssite_probe/SPEC.md：只复用魔蚁现有源
/// 体系（searchAcross + detail），不另写解析器；只探可见站；无番号
/// 的片不显示；探活失败只标状态，绝不挡本源线路与海报播放。

/// 番号提取：只认“字母+数字”结构的番号，返回归一化形式 `前缀-数字`
/// （如 HMN-927、FC2-PPV-1234567、1PONDO-102726）。找不到返回 null。
///
/// 标题里可接受无分隔符的写法（如 SSIS123）；站源 id 里只认带分隔符
/// 的写法，避免把网址、哈希里的字母数字串误认成番号。
String? extractAvId({
  required String title,
  String id = '',
  String sourceId = '',
}) {
  for (final entry in [(title, false), (id, true), (sourceId, true)]) {
    final found = _extractAvIdFromText(entry.$1, requireSeparator: entry.$2);
    if (found != null) return found;
  }
  return null;
}

/// 标题里常见的非番号词：遇到这些前缀不认作番号。
const _avIdStopPrefixes = {
  'EP',
  'HD',
  'SD',
  'UHD',
  'FHD',
  'TV',
  'PV',
  'MV',
  'CD',
  'DVD',
  'BD',
  'AV',
  'ID',
  'URL',
  'MP',
};

String? _extractAvIdFromText(String text, {required bool requireSeparator}) {
  if (text.isEmpty) return null;
  // FC2-PPV-1234567：先认全形，避免只截到 PPV-1234567。
  final fc2 = RegExp(
    r'fc2[-\s_]?ppv[-\s_]?(\d{5,7})',
    caseSensitive: false,
  ).allMatches(text);
  for (final match in fc2) {
    if (_hasCleanBounds(text, match)) {
      return 'FC2-PPV-${match.group(1)}';
    }
  }
  // 数字开头：1PONDO-102726、259LUXU-1234、10MUSUME-123456。
  final digitLeading = RegExp(
    r'(\d{1,4}[a-z]{2,6})[-\s_]?(\d{3,7})',
    caseSensitive: false,
  ).allMatches(text);
  for (final match in digitLeading) {
    if (!_hasCleanBounds(text, match)) continue;
    final prefix = match.group(1)!.toUpperCase();
    final number = match.group(2)!;
    if (requireSeparator && !_matchHasSeparator(match)) continue;
    return '$prefix-$number';
  }
  // 标准形：SSIS-123、HMN-927、SIRO-1234。
  final standard = RegExp(
    r'([a-z]{2,7})[-\s_]?(\d{3,7})',
    caseSensitive: false,
  ).allMatches(text);
  for (final match in standard) {
    if (!_hasCleanBounds(text, match)) continue;
    final prefix = match.group(1)!.toUpperCase();
    if (_avIdStopPrefixes.contains(prefix)) continue;
    final number = match.group(2)!;
    if (requireSeparator && !_matchHasSeparator(match)) continue;
    return '$prefix-$number';
  }
  return null;
}

/// 匹配两端不能紧贴字母或数字，避免从长串里截一段误认。
bool _hasCleanBounds(String text, RegExpMatch match) {
  if (match.start > 0 && _isAlphanumeric(text.codeUnitAt(match.start - 1))) {
    return false;
  }
  if (match.end < text.length && _isAlphanumeric(text.codeUnitAt(match.end))) {
    return false;
  }
  return true;
}

bool _isAlphanumeric(int code) =>
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x5A) ||
    (code >= 0x61 && code <= 0x7A);

bool _matchHasSeparator(RegExpMatch match) {
  final text = match.group(0)!;
  return text.contains('-') || text.contains('_') || text.contains(' ');
}

/// 搜索命中是否与番号同一部片：标题或 id 里含番号核心（去分隔符比对）。
bool crossSiteHitMatches({
  required String title,
  required String id,
  required String avId,
}) {
  final core = avId.replaceAll('-', '').toUpperCase();
  String norm(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[-_\s]'), '');
  return norm(title).contains(core) || norm(id).contains(core);
}

/// 版本名：命中标题/id 里含番号的那段代号（如 HMN-927-LADA），
/// 找不到代号时回落番号本身。
String crossSiteVersionLabel({
  required String title,
  required String id,
  required String avId,
}) {
  final core = avId.replaceAll('-', '').toUpperCase();
  for (final text in [title, id]) {
    final token = _codeTokenContaining(text, core);
    if (token != null) return token;
  }
  return avId;
}

String? _codeTokenContaining(String text, String core) {
  final tokens = RegExp(
    r'[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)+|[A-Za-z]+\d+',
  ).allMatches(text);
  for (final match in tokens) {
    final raw = match.group(0)!;
    final norm = raw.toUpperCase().replaceAll(RegExp(r'[-_]'), '');
    if (!norm.contains(core)) continue;
    return raw.toUpperCase().replaceAll('_', '-');
  }
  return null;
}

/// 跨站探活的一家平台：固定 6 家（AVPlay 截图顺序），每家对应魔蚁
/// 里同站的站源 id（按优先顺序）；一家在魔蚁里没有对应站源时
/// [siteIds] 为空，界面显示“未接入”，不探活、不硬凑。
class CrossSiteProvider {
  const CrossSiteProvider({
    required this.id,
    required this.name,
    required this.siteIds,
    required this.lazy,
  });

  final String id;
  final String name;
  final List<String> siteIds;

  /// 懒查：慢站/盾站，点一下才查（MissAV、Jable）。
  final bool lazy;
}

const crossSiteProviders = <CrossSiteProvider>[
  CrossSiteProvider(id: 'avdb', name: 'AVDB', siteIds: [], lazy: false),
  CrossSiteProvider(
    id: 'javmenu',
    name: 'JavMenu',
    // py 内置站运行时 id 即注册 key（importedSites 的键，isPySource /
    // isKnown 都认它），与 BuiltinPySites.javmenuSiteId 交叉锁定。
    siteIds: ['javmenu'],
    lazy: false,
  ),
  CrossSiteProvider(
    id: 'av01',
    name: 'AV01',
    // jar 内置站运行时 id 形如 jar:zakatv:<key>
    //（JarSiteSpec.siteIdFor，见 jar_import.dart 内置注册）。
    siteIds: ['jar:zakatv:zakav01'],
    lazy: false,
  ),
  CrossSiteProvider(id: 'memojav', name: 'MemoJav', siteIds: [], lazy: false),
  CrossSiteProvider(
    id: 'missav',
    name: 'MissAV',
    siteIds: [
      'jar:zakatv:ZakaMissav',
      'jar:zakatv:ZakaMissavOff',
      'jar:zakatv:ZakaMirror',
      'jar:zakatv:missavt',
    ],
    lazy: true,
  ),
  CrossSiteProvider(
    id: 'jable',
    name: 'Jable',
    siteIds: ['jar:zakatv:ZakaJable'],
    lazy: true,
  ),
];

/// 一行探活计划：[siteId] 为 null 表示该平台在魔蚁里没有对应站源
/// （显示“未接入”）；站源存在但被用户藏起来的平台不在计划里，
/// 整行不显示（只探可见站，与全局搜索、轮播混成人站同一口径）。
class CrossSiteRowPlan {
  const CrossSiteRowPlan({required this.provider, this.siteId});

  final CrossSiteProvider provider;
  final String? siteId;
}

List<CrossSiteRowPlan> planCrossSiteRows({
  required bool Function(String siteId) siteAvailable,
  required bool Function(String siteId) siteVisible,
}) {
  final plans = <CrossSiteRowPlan>[];
  for (final provider in crossSiteProviders) {
    String? chosen;
    var anyAvailable = false;
    for (final siteId in provider.siteIds) {
      if (!siteAvailable(siteId)) continue;
      anyAvailable = true;
      if (siteVisible(siteId)) {
        chosen = siteId;
        break;
      }
    }
    if (chosen != null) {
      plans.add(CrossSiteRowPlan(provider: provider, siteId: chosen));
    } else if (!anyAvailable) {
      plans.add(CrossSiteRowPlan(provider: provider));
    }
    // 站源存在但被藏起：整行省略，不探活。
  }
  return plans;
}

/// 一条可播线路：某版本详情里同一线路名（flag）下的首集。
class CrossSiteLine {
  const CrossSiteLine({required this.label, required this.episodeIndex});

  final String label;
  final int episodeIndex;
}

/// 一个版本：一次搜索命中取详情后的全部线路。
class CrossSiteVersion {
  const CrossSiteVersion({
    required this.label,
    required this.detail,
    required this.lines,
  });

  final String label;
  final DramaDetail detail;
  final List<CrossSiteLine> lines;
}

enum CrossSiteProbeStatus {
  /// 懒查平台尚未点按。
  lazy,

  /// 正在探活。
  probing,

  /// 探到可播线路。
  found,

  /// 已探活，无此片的线路（标 ×）。
  empty,

  /// 探活失败/超时（标 ×，点按重试；不弹错、不挡主链）。
  failed,

  /// 魔蚁里没有该平台的对应站源（显示“未接入”）。
  unavailable,
}

class CrossSiteProbeResult {
  const CrossSiteProbeResult({
    required this.provider,
    required this.siteId,
    required this.status,
    this.versions = const [],
  });

  final CrossSiteProvider provider;
  final String siteId;
  final CrossSiteProbeStatus status;
  final List<CrossSiteVersion> versions;
}

/// 详情集按线路名（episode raw 的 flag，jar/py 详情都带）分组，
/// 每组取首集作为该线路的起播集；无 flag 信息时整部片算一条“正片”。
List<CrossSiteLine> crossSiteLinesOf(DramaDetail detail) {
  final lines = <CrossSiteLine>[];
  final seen = <String>{};
  for (var i = 0; i < detail.episodes.length; i++) {
    final flag = (detail.episodes[i].raw['flag'] as String? ?? '').trim();
    final label = flag.isEmpty ? '正片' : flag;
    if (seen.add(label)) {
      lines.add(CrossSiteLine(label: label, episodeIndex: i));
    }
  }
  return lines;
}

/// 跨站探活服务：只走 [AppRepository] 现有接口（searchAcross +
/// detail），不另写解析器。单站超时 + 总预算双重兜底，任何失败
/// 都只落到 failed 状态，不抛错到界面。
class CrossSiteProbeService {
  CrossSiteProbeService({
    required this.repository,
    this.perSiteTimeout = const Duration(seconds: 20),
    this.totalBudget = const Duration(seconds: 30),
    this.maxVersions = 3,
  });

  final AppRepository repository;
  final Duration perSiteTimeout;
  final Duration totalBudget;
  final int maxVersions;

  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    try {
      return await _probe(provider, siteId, avId).timeout(perSiteTimeout);
    } on TimeoutException {
      return CrossSiteProbeResult(
        provider: provider,
        siteId: siteId,
        status: CrossSiteProbeStatus.failed,
      );
    } catch (_) {
      return CrossSiteProbeResult(
        provider: provider,
        siteId: siteId,
        status: CrossSiteProbeStatus.failed,
      );
    }
  }

  Future<List<CrossSiteProbeResult>> probeAll(
    List<CrossSiteRowPlan> plans,
    String avId,
  ) {
    final targets = plans.where((plan) => plan.siteId != null).toList();
    return Future.wait(
      targets.map((plan) {
        final future = probeProvider(plan.provider, plan.siteId!, avId);
        return future.timeout(
          totalBudget,
          onTimeout: () => CrossSiteProbeResult(
            provider: plan.provider,
            siteId: plan.siteId!,
            status: CrossSiteProbeStatus.failed,
          ),
        );
      }),
    );
  }

  Future<CrossSiteProbeResult> _probe(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    final page = await repository.searchAcross([siteId], avId);
    final hits = page.items
        .where(
          (drama) =>
              crossSiteHitMatches(title: drama.title, id: drama.id, avId: avId),
        )
        .take(maxVersions)
        .toList();
    final versions = <CrossSiteVersion>[];
    for (final hit in hits) {
      try {
        final detail = await repository.detail(hit);
        final lines = crossSiteLinesOf(detail);
        if (lines.isEmpty) continue;
        versions.add(
          CrossSiteVersion(
            label: crossSiteVersionLabel(
              title: hit.title,
              id: hit.id,
              avId: avId,
            ),
            detail: detail,
            lines: lines,
          ),
        );
      } catch (_) {
        // 某个命中取详情失败，换下一个命中，不拖垮整家平台。
      }
    }
    return CrossSiteProbeResult(
      provider: provider,
      siteId: siteId,
      status: versions.isEmpty
          ? CrossSiteProbeStatus.empty
          : CrossSiteProbeStatus.found,
      versions: versions,
    );
  }
}
