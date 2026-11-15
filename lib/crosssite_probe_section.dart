import 'dart:async';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'crosssite_probe.dart';
import 'local_store.dart';
import 'models.dart';

/// 详情页跨站选线路区：只在带番号的片上出现（无番号不显示，由
/// 调用方用 extractAvId 判断）。详情页上只留一行紧凑入口（番号 +
/// 有线家数/推荐摘要），点开底部弹窗看完整内容（平台行、版本、线路、
/// 推荐标、×/点击查询/重试、未接入）；按番号探全部可见视频站（当前
/// 站除外），探到线路的行置顶、按耗时从快到慢，排第一的标“推荐”，
/// 只推荐不自动播；慢站/盾站与超出自动探活上限的站点一下才查；探过
/// 无线的标 ×，点 × 可重试；无源平台显示“未接入”。离开详情页时
/// state 销毁，在途探活结果不再写回（代次守卫）；弹窗只是同一份
/// 状态的另一副面孔，关弹窗不取消探活。
class CrossSiteProbeSection extends StatefulWidget {
  const CrossSiteProbeSection({
    super.key,
    required this.repository,
    required this.store,
    required this.avId,
    required this.onPlayLine,
    this.currentSourceId = '',
    this.service,
    this.candidateSites,
  });

  final AppRepository repository;
  final LocalStore store;
  final String avId;

  /// 点某条线路：走现有播放链（调用方用 pushPlayer 起播）。
  final void Function(DramaDetail detail, int episodeIndex) onPlayLine;

  /// 当前正在看的站源 id：跨站线路只取其他站点，本站不进计划。
  final String currentSourceId;

  @visibleForTesting
  final CrossSiteProbeService? service;

  /// 候选站源表（测试注入）：不传时取 store.visibleSources。
  @visibleForTesting
  final List<SourceSite>? candidateSites;

  @override
  State<CrossSiteProbeSection> createState() => _CrossSiteProbeSectionState();
}

class _CrossSiteProbeSectionState extends State<CrossSiteProbeSection> {
  late CrossSiteProbeService _service;
  late List<CrossSiteRowPlan> _plans;
  final _results = <String, CrossSiteProbeResult>{};
  final _probing = <String>{};
  final _deferred = <String>{};
  final _probeTokens = <String, int>{};
  var _generation = 0;

  /// 弹窗内容刷新通知：弹窗与入口行共用同一份探活状态，状态变化时
  /// 既 setState（入口行重建）也 bump 它（弹窗内 AnimatedBuilder 重建）。
  final _sheetRefresh = ValueNotifier<int>(0);

  /// 显示状态变化统一入口：入口行与已打开的弹窗同时刷新。
  void _refreshDisplay(void Function() fn) {
    setState(fn);
    _sheetRefresh.value++;
  }

  List<CrossSiteRowPlan> _computePlans() => planCrossSiteRows(
    sites: widget.candidateSites ?? widget.store.visibleSources,
    siteVisible: widget.store.siteVisible,
    currentSourceId: widget.currentSourceId,
  );

  @override
  void initState() {
    super.initState();
    _service =
        widget.service ?? CrossSiteProbeService(repository: widget.repository);
    _plans = _computePlans();
    widget.store.addListener(_onStoreChanged);
    _startEagerProbes();
  }

  /// 站点登记表变化（插件安装/卸载）时重算站点池：在池里的新站
  /// 出现、被卸的站消失并丢弃其旧结果，不用重进详情页。
  void _onStoreChanged() {
    final next = _computePlans();
    final nextIds = next.map((plan) => plan.provider.id).toSet();
    final prevIds = _plans.map((plan) => plan.provider.id).toSet();
    if (nextIds.length == prevIds.length &&
        nextIds.containsAll(prevIds) &&
        next.length == _plans.length) {
      return;
    }
    if (!mounted) return;
    _refreshDisplay(() {
      _plans = next;
      _results.removeWhere((id, _) => !nextIds.contains(id));
      _deferred.removeWhere((id) => !nextIds.contains(id));
    });
    _startEagerProbes();
  }

  @override
  void didUpdateWidget(covariant CrossSiteProbeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
    if (oldWidget.avId != widget.avId ||
        oldWidget.repository != widget.repository ||
        oldWidget.currentSourceId != widget.currentSourceId) {
      // 换片：旧探活结果作废，代次守卫拦住在途回写。
      _generation++;
      _results.clear();
      _probing.clear();
      _deferred.clear();
    }
    _plans = _computePlans();
    final ids = _plans.map((plan) => plan.provider.id).toSet();
    _results.removeWhere((id, _) => !ids.contains(id));
    _deferred.removeWhere((id) => !ids.contains(id));
    _startEagerProbes();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _generation++;
    _sheetRefresh.dispose();
    super.dispose();
  }

  void _startEagerProbes() {
    final generation = _generation;
    final targets = _plans
        .where(
          (plan) =>
              plan.siteId != null &&
              !plan.provider.lazy &&
              !_deferred.contains(plan.provider.id) &&
              !_results.containsKey(plan.provider.id) &&
              !_probing.contains(plan.provider.id),
        )
        .toList();
    if (targets.isEmpty) return;
    for (final plan in targets) {
      _probing.add(plan.provider.id);
    }
    unawaited(
      _service
          .probePlans(
            targets,
            widget.avId,
            onResult: (result) {
              if (!mounted || generation != _generation) return;
              _refreshDisplay(() {
                _results[result.provider.id] = result;
                _probing.remove(result.provider.id);
              });
            },
          )
          .then((_) {
            if (!mounted || generation != _generation) return;
            _refreshDisplay(() {
              // 预算耗尽未起跑的计划改走懒查，不挂“正在查询”。
              for (final plan in targets) {
                if (_probing.remove(plan.provider.id)) {
                  _deferred.add(plan.provider.id);
                }
              }
            });
          })
          .catchError((_) {
            // probePlans 内部已把失败落到 failed 状态；这里只防万一，
            // 在途行一律改走懒查，不挂死。
            if (mounted && generation == _generation) {
              _refreshDisplay(() {
                for (final plan in targets) {
                  _probing.remove(plan.provider.id);
                  _deferred.add(plan.provider.id);
                }
              });
            }
          }),
    );
  }

  void _probeOne(CrossSiteRowPlan plan) {
    final siteId = plan.siteId;
    if (siteId == null || _probing.contains(plan.provider.id)) return;
    // 单家重查只作废本家的旧回写，不动代次（避免拖垮其它在途探活）。
    final token = (_probeTokens[plan.provider.id] ?? 0) + 1;
    _probeTokens[plan.provider.id] = token;
    final generation = _generation;
    _refreshDisplay(() {
      _probing.add(plan.provider.id);
      _deferred.remove(plan.provider.id);
      _results.remove(plan.provider.id);
    });
    unawaited(
      _service
          .probeProvider(plan.provider, siteId, widget.avId)
          .then((result) {
            if (!mounted ||
                generation != _generation ||
                _probeTokens[plan.provider.id] != token) {
              return;
            }
            _refreshDisplay(() {
              _results[result.provider.id] = result;
              _probing.remove(result.provider.id);
            });
          })
          .catchError((_) {
            if (mounted &&
                generation == _generation &&
                _probeTokens[plan.provider.id] == token) {
              _refreshDisplay(() {
                _probing.remove(plan.provider.id);
                _results[plan.provider.id] = CrossSiteProbeResult(
                  provider: plan.provider,
                  siteId: siteId,
                  status: CrossSiteProbeStatus.failed,
                );
              });
            }
          }),
    );
  }

  bool _isLazy(CrossSiteRowPlan plan) =>
      plan.provider.lazy || _deferred.contains(plan.provider.id);

  @override
  Widget build(BuildContext context) {
    if (_plans.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final display = sortCrossSitePlansForDisplay(_plans, _results);
    final found = display
        .where(
          (plan) =>
              _results[plan.provider.id]?.status ==
              CrossSiteProbeStatus.found,
        )
        .toList();
    final recommendedId =
        display.isNotEmpty &&
            _results[display.first.provider.id]?.status ==
                CrossSiteProbeStatus.found
        ? display.first.provider.id
        : null;
    final recommendedName = recommendedId == null
        ? null
        : display
              .firstWhere((plan) => plan.provider.id == recommendedId)
              .provider
              .name;
    final String summary;
    if (found.isNotEmpty) {
      summary =
          '${found.length} 家有线路${recommendedName == null ? '' : ' · 推荐 $recommendedName'}';
    } else if (_probing.isNotEmpty) {
      summary = '正在查询…';
    } else {
      summary = '点开查看各平台';
    }
    return Padding(
      key: const ValueKey('crosssite-section'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('crosssite-entry'),
          onTap: _openSheet,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(Icons.public_rounded, size: 15, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  '跨站选线路',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.avId,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (_probing.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 打开底部弹窗：完整平台行 + 版本 + 线路，内容与探活状态实时同步
  /// （_sheetRefresh）；关弹窗不取消在途探活，离页才取消。
  void _openSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => AnimatedBuilder(
        animation: _sheetRefresh,
        builder: (context, _) => _sheetContent(sheetContext),
      ),
    );
  }

  Widget _sheetContent(BuildContext sheetContext) {
    final colors = Theme.of(sheetContext).colorScheme;
    final display = sortCrossSitePlansForDisplay(_plans, _results);
    final recommendedId =
        display.isNotEmpty &&
            _results[display.first.provider.id]?.status ==
                CrossSiteProbeStatus.found
        ? display.first.provider.id
        : null;
    final anyProbing = _probing.isNotEmpty;
    return Container(
      key: const ValueKey('crosssite-sheet'),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.82,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.outlineVariant,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                Icon(Icons.public_rounded, size: 15, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  '跨站选线路',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.avId,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (anyProbing) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                const Spacer(),
                IconButton(
                  key: const ValueKey('crosssite-sheet-close'),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final plan in display)
                    _row(
                      sheetContext,
                      plan,
                      recommended: plan.provider.id == recommendedId,
                      onBeforePlay: () =>
                          Navigator.of(sheetContext).pop(),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    CrossSiteRowPlan plan, {
    required bool recommended,
    VoidCallback? onBeforePlay,
  }) {
    final colors = Theme.of(context).colorScheme;
    final result = _results[plan.provider.id];
    final probing = _probing.contains(plan.provider.id);
    Widget trailing;
    VoidCallback? onTap;
    if (plan.siteId == null) {
      trailing = Text(
        '未接入',
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      );
    } else if (probing) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 6),
          Text(
            '正在查询…',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ],
      );
    } else if (result == null && _isLazy(plan)) {
      trailing = Text(
        '点击查询',
        style: TextStyle(color: colors.primary, fontSize: 12),
      );
      onTap = () => _probeOne(plan);
    } else if (result?.status == CrossSiteProbeStatus.empty) {
      trailing = Text(
        '× 无此片',
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      );
      onTap = () => _probeOne(plan);
    } else if (result?.status == CrossSiteProbeStatus.failed) {
      trailing = Text(
        '× 查询失败，点按重试',
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      );
      onTap = () => _probeOne(plan);
    } else if (result?.status == CrossSiteProbeStatus.found) {
      trailing = Text(
        '${result!.versions.length} 个版本',
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      );
    } else {
      trailing = Text(
        '正在查询…',
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      );
    }
    return Padding(
      key: ValueKey('crosssite-row-${plan.provider.id}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: ValueKey('crosssite-rowtap-${plan.provider.id}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            plan.provider.name,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (recommended) ...[
                          const SizedBox(width: 6),
                          Container(
                            key: const ValueKey('crosssite-recommended'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colors.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '推荐',
                              style: TextStyle(
                                color: colors.onPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing,
                ],
              ),
            ),
          ),
          if (result?.status == CrossSiteProbeStatus.found)
            for (var v = 0; v < result!.versions.length; v++)
              _versionBlock(
                context,
                plan,
                result.versions[v],
                v,
                recommended: recommended,
                onBeforePlay: onBeforePlay,
              ),
        ],
      ),
    );
  }

  Widget _versionBlock(
    BuildContext context,
    CrossSiteRowPlan plan,
    CrossSiteVersion version,
    int versionIndex, {
    required bool recommended,
    VoidCallback? onBeforePlay,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            version.label,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < version.lines.length; i++)
                _lineCapsule(
                  context,
                  key: ValueKey(
                    'crosssite-line-${plan.provider.id}-$versionIndex-$i',
                  ),
                  label: version.lines[i].label,
                  recommended: recommended,
                  onTap: () {
                    onBeforePlay?.call();
                    widget.onPlayLine(
                      version.detail,
                      version.lines[i].episodeIndex,
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 线路胶囊小片：圆角 999 的胶囊容器，颜色随主题；推荐行的
  /// 胶囊用主题主色容器以示区分，点哪条播哪条，不自动播。
  Widget _lineCapsule(
    BuildContext context, {
    required Key key,
    required String label,
    required bool recommended,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: recommended
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: recommended ? colors.primary : colors.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.play_arrow_rounded,
              size: 16,
              color: recommended
                  ? colors.onPrimaryContainer
                  : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: recommended
                    ? colors.onPrimaryContainer
                    : colors.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
