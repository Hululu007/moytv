import 'dart:async';

import 'app_page_route.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'custom_sources_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'source_status.dart';
import 'widgets.dart';

String sourceTimestamp(DateTime? value) {
  if (value == null) return '尚无记录';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

String _importBucket(String name) {
  if (name.isEmpty) return 'other';
  final first = name[0].toUpperCase();
  if (first.compareTo('A') >= 0 && first.compareTo('Z') <= 0) return first;
  if (first.compareTo('0') >= 0 && first.compareTo('9') <= 0) return '0-9';
  return 'other';
}

List<SourceGroup> sourceManageGroups(List<SourceSite> sources) {
  final drama = <SourceSite>[];
  final video = <SourceSite>[];
  final custom = <SourceSite>[];
  final looseConfig = <SourceSite>[];
  final byConfig = <String, List<SourceSite>>{};
  final importBuckets = <String, List<SourceSite>>{};
  for (final source in sources) {
    if (SourceSite.isCustomId(source.id)) {
      custom.add(source);
    } else if (source.origin == SourceSite.originConfig) {
      if (source.configId.isNotEmpty) {
        (byConfig[source.configId] ??= []).add(source);
      } else {
        looseConfig.add(source);
      }
    } else if (source.origin == SourceSite.originImport) {
      (importBuckets[_importBucket(source.name)] ??= []).add(source);
    } else if (source.isVideoSection) {
      video.add(source);
    } else {
      drama.add(source);
    }
  }
  final groups = <SourceGroup>[];
  if (drama.isNotEmpty) {
    groups.add(SourceGroup('builtin:drama', '内置短剧', drama));
  }
  if (video.isNotEmpty) {
    groups.add(SourceGroup('builtin:video', '内置影视', video));
  }
  if (custom.isNotEmpty) {
    groups.add(SourceGroup('custom', '自定义', custom));
  }
  for (final entry in byConfig.entries) {
    final name = entry.value.first.configName;
    groups.add(
      SourceGroup.config(
        configId: entry.key,
        name: name.isNotEmpty ? name : '导入配置',
        sources: entry.value,
      ),
    );
  }
  if (looseConfig.isNotEmpty) {
    groups.add(
      SourceGroup(
        'config:custom',
        '导入配置',
        looseConfig,
        origin: SourceSite.originConfig,
        configId: 'custom',
      ),
    );
  }
  final bucketKeys = importBuckets.keys.toList()
    ..sort((a, b) {
      if (a == 'other') return 1;
      if (b == 'other') return -1;
      if (a == '0-9') return 1;
      if (b == '0-9') return -1;
      return a.compareTo(b);
    });
  for (final bucket in bucketKeys) {
    final name = switch (bucket) {
      'other' => '导入 · 其他',
      '0-9' => '导入 · 数字',
      _ => '导入 · $bucket',
    };
    groups.add(
      SourceGroup(
        'import:$bucket',
        name,
        importBuckets[bucket]!,
        origin: SourceSite.originImport,
      ),
    );
  }
  return groups;
}

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialSource,
    this.drama,
  });

  final AppRepository repository;
  final LocalStore store;
  final String? initialSource;
  final Drama? drama;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  final _statuses = <String, SourceStatus>{};
  final _errors = <String, String>{};
  final _pending = <String>{};
  final _revisions = <String, int>{};
  final _expandedHealth = <String>{};
  late Set<String> _expandedGroups;
  int _expandEpoch = 0;
  Timer? _timer;
  bool _polling = false;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _expandedGroups = Set.of(widget.store.expandedSourceGroups);
    final initial = widget.initialSource;
    if (initial != null) {
      for (final group in sourceManageGroups(widget.store.sources)) {
        if (group.sources.any((source) => source.id == initial)) {
          _expandedGroups.add(group.id);
        }
      }
    }
    ensureTelevisionFocus(context);
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _ticks++;
      if (_statuses.values.any((status) => status.retryAt != null)) {
        setState(() {});
      }
      if (_ticks % 2 == 0 &&
          (_statuses.values.any((status) => status.running) ||
              _ticks % 10 == 0)) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_polling) return;
    _polling = true;
    final epoch = widget.store.profileEpoch;
    try {
      await Future.wait([
        for (final source in widget.store.sources)
          (() async {
            final revision = _revisions[source.id] ?? 0;
            try {
              final status = await widget.repository.sourceStatus(source.id);
              if (!mounted ||
                  epoch != widget.store.profileEpoch ||
                  revision != (_revisions[source.id] ?? 0)) {
                return;
              }
              setState(() {
                _statuses[source.id] = status;
                _errors.remove(source.id);
              });
            } catch (error) {
              if (mounted &&
                  epoch == widget.store.profileEpoch &&
                  revision == (_revisions[source.id] ?? 0)) {
                setState(() => _errors[source.id] = error.toString());
              }
            }
          })(),
      ]);
    } finally {
      _polling = false;
    }
  }

  Future<void> _run(SourceSite source, String operation) async {
    if (_pending.contains(source.id)) return;
    final epoch = widget.store.profileEpoch;
    setState(() {
      _pending.add(source.id);
      _errors.remove(source.id);
      _revisions[source.id] = (_revisions[source.id] ?? 0) + 1;
      if (operation == 'check' || operation == 'checkCatalog') {
        _expandedHealth.add(source.id);
      }
    });
    try {
      final status = operation == 'cancel'
          ? await widget.repository.cancelSourceJob(source.id)
          : await widget.repository.startSourceJob(
              source.id,
              operation,
              drama: source.id == widget.drama?.source ? widget.drama : null,
            );
      if (mounted && epoch == widget.store.profileEpoch) {
        setState(() => _statuses[source.id] = status);
      }
    } catch (error) {
      if (mounted && epoch == widget.store.profileEpoch) {
        setState(() => _errors[source.id] = error.toString());
      }
    } finally {
      if (mounted) setState(() => _pending.remove(source.id));
    }
  }

  void _setGroupExpanded(String groupId, bool expanded) {
    setState(() {
      if (expanded) {
        _expandedGroups.add(groupId);
      } else {
        _expandedGroups.remove(groupId);
      }
    });
    unawaited(widget.store.setExpandedSourceGroups(_expandedGroups));
  }

  void _setAllGroupsExpanded(List<SourceGroup> groups, bool expanded) {
    setState(() {
      _expandedGroups = expanded
          ? groups.map((group) => group.id).toSet()
          : <String>{};
      _expandEpoch++;
    });
    unawaited(widget.store.setExpandedSourceGroups(_expandedGroups));
  }

  IconData _groupIcon(SourceGroup group) {
    if (group.origin == SourceSite.originImport) {
      return Icons.download_outlined;
    }
    if (group.isConfig) return Icons.hub_outlined;
    if (group.id == 'custom') return Icons.edit_outlined;
    return Icons.dns_outlined;
  }

  Future<void> _copy(SourceSite source, SourceStatus status) async {
    final text = StringBuffer('${source.name}\n');
    text.writeln(
      '缓存 ${status.count} 部，更新 ${sourceTimestamp(status.updatedAt)}',
    );
    final health = status.health;
    if (health != null) {
      text.writeln('${health.label} · ${sourceTimestamp(health.checkedAt)}');
      if (health.sample.isNotEmpty) text.writeln('检测剧集：${health.sample}');
      for (final step in health.steps) {
        text.writeln('${step.name}：${step.message}');
        text.writeln(
          '${step.host} HTTP ${step.httpStatus} · ${step.elapsedMs} ms',
        );
        if (step.cfRay.isNotEmpty) text.writeln('CF Ray: ${step.cfRay}');
      }
    }
    if (status.error.isNotEmpty) text.writeln(status.error);
    if (status.storageError.isNotEmpty) text.writeln(status.storageError);
    await Clipboard.setData(ClipboardData(text: text.toString()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('诊断信息已复制')));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final sources = widget.store.sources.toList()
        ..sort((a, b) {
          final aFirst = a.id == widget.initialSource ? 0 : 1;
          final bFirst = b.id == widget.initialSource ? 0 : 1;
          return aFirst.compareTo(bFirst);
        });
      final groups = sourceManageGroups(sources);
      final viewPaddingBottom = MediaQuery.viewPaddingOf(context).bottom;
      final paddingBottom = MediaQuery.paddingOf(context).bottom;
      final bottomInset = viewPaddingBottom > paddingBottom
          ? viewPaddingBottom
          : paddingBottom;
      return Scaffold(
        appBar: AppBar(title: const Text('站源管理')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
                children: [
                  Card(
                    key: const ValueKey('source-visibility-entry'),
                    margin: const EdgeInsets.only(bottom: 16),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: const Icon(Icons.visibility_outlined),
                      title: const Text('源显示列表'),
                      subtitle: Text(
                        '控制在首页显示的站源（含内置站源）· 当前 '
                        '${widget.store.visibleSources.length}/${widget.store.sources.length} 个可见',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.push<void>(
                        context,
                        appPageRoute<void>(
                          builder: (_) =>
                              SourceVisibilityScreen(store: widget.store),
                        ),
                      ),
                    ),
                  ),
                  Card(
                    key: const ValueKey('custom-sources-entry'),
                    margin: const EdgeInsets.only(bottom: 16),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: const Icon(Icons.add_circle_outline),
                      title: const Text('自定义源'),
                      subtitle: const Text(
                        '录入 MacCMS 站点地址或粘贴 XBPQ 爬虫规则，支持批量导入与导出',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.push<void>(
                        context,
                        appPageRoute<void>(
                          builder: (_) => CustomSourcesScreen(
                            repository: widget.repository,
                            store: widget.store,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      '各站源可分别更新和检测。更新会查找新剧、继续加载一页历史内容，并分批补齐资料；离开此页后任务继续。',
                    ),
                  ),
                  if (sources.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('当前用户没有可用站源'),
                    ),
                  if (groups.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          TextButton.icon(
                            key: const ValueKey('expand-all-source-groups'),
                            onPressed: () =>
                                _setAllGroupsExpanded(groups, true),
                            icon: const Icon(Icons.unfold_more_rounded),
                            label: const Text('全部展开'),
                          ),
                          TextButton.icon(
                            key: const ValueKey('collapse-all-source-groups'),
                            onPressed: () =>
                                _setAllGroupsExpanded(groups, false),
                            icon: const Icon(Icons.unfold_less_rounded),
                            label: const Text('全部折叠'),
                          ),
                          const Spacer(),
                          Text('${sources.length} 个站源'),
                        ],
                      ),
                    ),
                  for (final group in groups)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: ValueKey('source-group-${group.id}-$_expandEpoch'),
                        initiallyExpanded: _expandedGroups.contains(group.id),
                        onExpansionChanged: (expanded) =>
                            _setGroupExpanded(group.id, expanded),
                        leading: Icon(_groupIcon(group)),
                        title: Text(group.name),
                        subtitle: Text(
                          '${group.sources.length} 个站源 · ${group.sources.fold<int>(0, (count, source) => count + (_statuses[source.id]?.count ?? 0))} 部',
                        ),
                        childrenPadding: const EdgeInsets.all(8),
                        children: _expandedGroups.contains(group.id)
                            ? [
                                for (final source in group.sources)
                                  _sourceCard(source),
                              ]
                            : const [],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _sourceCard(SourceSite source) {
    final status = _statuses[source.id];
    final pending = _pending.contains(source.id);
    final busy = pending || status?.running == true;
    final seconds = status?.retrySeconds ?? 0;
    final enabled =
        !busy && seconds == 0 && widget.repository.supportsSourceManagement;
    final error = _errors[source.id] ?? status?.error ?? '';
    final health = status?.health;
    final healthExpanded = _expandedHealth.contains(source.id);
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('source-${source.id}'),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.dns_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    source.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text('${status?.count ?? 0} 部'),
              ],
            ),
            const SizedBox(height: 8),
            Text('最近更新：${sourceTimestamp(status?.updatedAt)}'),
            if (status != null && status.count > 0)
              Text(
                '已加载至第 ${status.page} 页${status.hasMore ? ' · 可继续加载' : ' · 当前分页已加载完'}',
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: ValueKey('update-${source.id}'),
                  onPressed: enabled ? () => _run(source, 'update') : null,
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('更新'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('check-${source.id}'),
                  onPressed: enabled ? () => _run(source, 'check') : null,
                  icon: const Icon(Icons.network_check),
                  label: const Text('检测连接与播放'),
                ),
                if (status?.running == true)
                  TextButton(
                    onPressed: pending ? null : () => _run(source, 'cancel'),
                    child: const Text('停止'),
                  ),
                PopupMenuButton<String>(
                  tooltip: '${source.name}更多操作',
                  enabled: enabled,
                  onSelected: (operation) => _run(source, operation),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'more',
                      enabled: status?.hasMore ?? true,
                      child: const Text('继续加载一页'),
                    ),
                    const PopupMenuItem(value: 'metadata', child: Text('补齐资料')),
                    if (source.id == 'huangdou')
                      PopupMenuItem(
                        value: 'vipMetadata',
                        enabled: (status?.unknownVip ?? 0) > 0,
                        child: Text('补齐 VIP 资料（${status?.unknownVip ?? 0} 部）'),
                      ),
                    const PopupMenuItem(
                      value: 'checkCatalog',
                      child: Text('仅检测目录'),
                    ),
                  ],
                ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: status != null && status.total > 0
                    ? (status.completed / status.total).clamp(0, 1)
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                '${status?.stage ?? '准备中'}${(status?.total ?? 0) > 0 ? ' · ${status!.completed}/${status.total}' : ''}',
              ),
            ] else if (status != null && status.stage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${status.stage}${status.added > 0 ? ' · 新增 ${status.added} 部' : ''}',
              ),
            ],
            if (seconds > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '请在 $seconds 秒后重试',
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  error,
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (status != null && status.storageError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status.storageError,
                      style: TextStyle(color: colors.error),
                    ),
                    TextButton.icon(
                      key: ValueKey('save-${source.id}'),
                      onPressed:
                          !busy && widget.repository.supportsSourceManagement
                          ? () => _run(source, 'retrySave')
                          : null,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('重试保存'),
                    ),
                  ],
                ),
              ),
            if (health != null) ...[
              const Divider(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      expanded: healthExpanded,
                      child: Tooltip(
                        message: healthExpanded ? '收起检测详情' : '展开检测详情',
                        child: TextButton(
                          key: ValueKey('health-toggle-${source.id}'),
                          onPressed: () => setState(() {
                            if (healthExpanded) {
                              _expandedHealth.remove(source.id);
                            } else {
                              _expandedHealth.add(source.id);
                            }
                          }),
                          style: TextButton.styleFrom(
                            foregroundColor: colors.onSurface,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(health.label),
                                    Text(
                                      sourceTimestamp(health.checkedAt),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                healthExpanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制诊断信息',
                    onPressed: () => _copy(source, status!),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
              if (healthExpanded) ...[
                if (health.sample.isNotEmpty) Text('检测剧集：${health.sample}'),
                for (final step in health.steps)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          step.state == 'ok'
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 20,
                          color: step.state == 'ok'
                              ? colors.primary
                              : colors.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${step.name}：${step.message}'),
                              if (step.host.isNotEmpty || step.httpStatus > 0)
                                Text(
                                  '${step.host}${step.httpStatus > 0 ? ' · HTTP ${step.httpStatus}' : ''} · ${step.elapsedMs} ms',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ] else ...[
              const SizedBox(height: 12),
              const Text('尚未检测连接'),
            ],
          ],
        ),
      ),
    );
  }
}

/// 源显示列表：开关每个站源（含内置与自定义）在首页的显示。
/// 与站源权限无关——隐藏只是不在首页出现，站源管理里的更新/检测不受影响。
class SourceVisibilityScreen extends StatefulWidget {
  const SourceVisibilityScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<SourceVisibilityScreen> createState() => _SourceVisibilityScreenState();
}

class _SourceVisibilityScreenState extends State<SourceVisibilityScreen> {
  final Set<String> _pending = {};

  Future<void> _toggle(SourceSite source, bool visible) async {
    if (_pending.contains(source.id)) return;
    setState(() => _pending.add(source.id));
    await saveUserChange(
      context,
      () => widget.store.setSiteVisible(source.id, visible),
    );
    if (mounted) setState(() => _pending.remove(source.id));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final sources = widget.store.sources;
      final hidden = widget.store.hiddenSites;
      return Scaffold(
        appBar: AppBar(title: const Text('源显示列表')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('关闭的站源不会出现在首页站源分组与目录中；更新、检测与已缓存内容不受影响，随时可以重新开启。'),
                ),
                if (sources.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('当前用户没有可用站源'),
                  ),
                for (final group in SourceGroup.sectionGroups(sources))
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  group.name,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              if (group.isConfig)
                                const Chip(label: Text('导入配置')),
                            ],
                          ),
                        ),
                        for (final source in group.sources)
                          SwitchListTile(
                            secondary: const Icon(Icons.dns_outlined),
                            title: Text(
                              group.id == 'huangguo' && group.sources.length > 1
                                  ? source.entryName
                                  : source.name,
                            ),
                            subtitle: Text(source.description),
                            value: !hidden.contains(source.id),
                            onChanged: _pending.contains(source.id)
                                ? null
                                : (value) => _toggle(source, value),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        floatingActionButton: sources.isEmpty
            ? null
            : FloatingActionButton.extended(
                key: const ValueKey('visibility-show-all'),
                onPressed: () async {
                  for (final source in sources) {
                    if (hidden.contains(source.id)) {
                      await _toggle(source, true);
                    }
                  }
                },
                icon: const Icon(Icons.visibility_rounded),
                label: const Text('全部显示'),
              ),
      );
    },
  );
}

class SourceDiagnosticsButton extends StatelessWidget {
  const SourceDiagnosticsButton({
    super.key,
    required this.repository,
    required this.store,
    required this.drama,
  });
  final AppRepository repository;
  final LocalStore store;
  final Drama drama;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => Navigator.push<void>(
      context,
      appPageRoute(
        builder: (_) => SourcesScreen(
          repository: repository,
          store: store,
          initialSource: drama.source,
          drama: drama,
        ),
      ),
    ),
    icon: const Icon(Icons.network_check),
    label: const Text('站源诊断'),
  );
}
