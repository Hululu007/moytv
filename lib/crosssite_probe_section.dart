import 'dart:async';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'crosssite_probe.dart';
import 'jar_bridge.dart';
import 'local_store.dart';
import 'models.dart';

/// 详情页跨站选线路区：只在带番号的片上出现（无番号不显示，由
/// 调用方用 [extractAvId] 判断）。平台→版本→线路三级；探过无线
/// 的标 ×；慢站/盾站点一下才查；探活失败只标状态，不挡主链。
/// 离开详情页时 state 销毁，在途探活结果不再写回（代次守卫）。
class CrossSiteProbeSection extends StatefulWidget {
  const CrossSiteProbeSection({
    super.key,
    required this.repository,
    required this.store,
    required this.avId,
    required this.onPlayLine,
    this.service,
    this.siteAvailable,
  });

  final AppRepository repository;
  final LocalStore store;
  final String avId;

  /// 点某条线路：走现有播放链（调用方用 pushPlayer 起播）。
  final void Function(DramaDetail detail, int episodeIndex) onPlayLine;

  @visibleForTesting
  final CrossSiteProbeService? service;

  @visibleForTesting
  final bool Function(String siteId)? siteAvailable;

  @override
  State<CrossSiteProbeSection> createState() => _CrossSiteProbeSectionState();
}

class _CrossSiteProbeSectionState extends State<CrossSiteProbeSection> {
  late CrossSiteProbeService _service;
  late List<CrossSiteRowPlan> _plans;
  final _results = <String, CrossSiteProbeResult>{};
  final _probing = <String>{};
  final _probeTokens = <String, int>{};
  var _generation = 0;

  bool _defaultSiteAvailable(String siteId) =>
      JarBridge.isJarSource(siteId) || SourceSite.isKnown(siteId);

  List<CrossSiteRowPlan> _computePlans() => planCrossSiteRows(
    siteAvailable: widget.siteAvailable ?? _defaultSiteAvailable,
    siteVisible: widget.store.siteVisible,
  );

  @override
  void initState() {
    super.initState();
    _service =
        widget.service ?? CrossSiteProbeService(repository: widget.repository);
    _plans = _computePlans();
    _startEagerProbes();
  }

  @override
  void didUpdateWidget(covariant CrossSiteProbeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avId != widget.avId ||
        oldWidget.repository != widget.repository) {
      // 换片：旧探活结果作废，代次守卫拦住在途回写。
      _generation++;
      _results.clear();
      _probing.clear();
    }
    _plans = _computePlans();
    _results.removeWhere(
      (id, _) => _plans.every((plan) => plan.provider.id != id),
    );
    _startEagerProbes();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _startEagerProbes() {
    final generation = _generation;
    final targets = _plans
        .where(
          (plan) =>
              plan.siteId != null &&
              !plan.provider.lazy &&
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
          .probeAll(targets, widget.avId)
          .then((results) {
            if (!mounted || generation != _generation) return;
            setState(() {
              for (final result in results) {
                _results[result.provider.id] = result;
                _probing.remove(result.provider.id);
              }
            });
          })
          .catchError((_) {
            // probeAll 内部已把失败落到 failed 状态；这里只防万一。
            if (mounted && generation == _generation) {
              setState(() {
                for (final plan in targets) {
                  _probing.remove(plan.provider.id);
                  _results.putIfAbsent(
                    plan.provider.id,
                    () => CrossSiteProbeResult(
                      provider: plan.provider,
                      siteId: plan.siteId!,
                      status: CrossSiteProbeStatus.failed,
                    ),
                  );
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
    setState(() {
      _probing.add(plan.provider.id);
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
            setState(() {
              _results[result.provider.id] = result;
              _probing.remove(result.provider.id);
            });
          })
          .catchError((_) {
            if (mounted &&
                generation == _generation &&
                _probeTokens[plan.provider.id] == token) {
              setState(() {
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

  @override
  Widget build(BuildContext context) {
    if (_plans.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final anyProbing = _probing.isNotEmpty;
    return Padding(
      key: const ValueKey('crosssite-section'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
            ],
          ),
          const SizedBox(height: 8),
          for (final plan in _plans) _row(context, plan),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, CrossSiteRowPlan plan) {
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
    } else if (result == null && plan.provider.lazy) {
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
                    child: Text(
                      plan.provider.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  trailing,
                ],
              ),
            ),
          ),
          if (result?.status == CrossSiteProbeStatus.found)
            for (var v = 0; v < result!.versions.length; v++)
              _versionBlock(context, plan, result.versions[v], v),
        ],
      ),
    );
  }

  Widget _versionBlock(
    BuildContext context,
    CrossSiteRowPlan plan,
    CrossSiteVersion version,
    int versionIndex,
  ) {
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
                ActionChip(
                  key: ValueKey(
                    'crosssite-line-${plan.provider.id}-$versionIndex-$i',
                  ),
                  avatar: Icon(
                    Icons.play_arrow_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  label: Text(version.lines[i].label),
                  onPressed: () => widget.onPlayLine(
                    version.detail,
                    version.lines[i].episodeIndex,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
