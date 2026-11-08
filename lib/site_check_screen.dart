import 'dart:async';

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'core_bridge.dart';
import 'jar_bridge.dart';
import 'local_store.dart';
import 'site_check.dart';
import 'sources_screen.dart';
import 'widgets.dart';

class SiteCheckScreen extends StatefulWidget {
  const SiteCheckScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<SiteCheckScreen> createState() => _SiteCheckScreenState();
}

class _SiteCheckScreenState extends State<SiteCheckScreen> {
  List<SiteCheckResult> _results = [];
  bool _running = false;
  bool _cancelRequested = false;
  bool _cancelled = false;
  int _done = 0;
  int _total = 0;
  DateTime? _lastRun;
  final Set<String> _restored = {};
  final Set<String> _pendingRestore = {};

  @override
  void initState() {
    super.initState();
    _lastRun = widget.store.siteCheckLastRun;
    unawaited(_run());
  }

  @override
  void dispose() {
    _cancelRequested = true;
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final sites = widget.store.sources;
    final hidden = widget.store.hiddenSites;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _cancelled = false;
      _results = [];
      _restored.clear();
      _done = 0;
      _total = sites.length;
    });
    final probed = await runSiteChecks(
      sites: sites,
      hiddenIds: hidden,
      jarSupported: JarBridge.supported,
      probe: (siteId) async {
        final page = await widget.repository.catalog(
          siteId,
          category: '',
          force: true,
        );
        return page.items.length;
      },
      isCancelled: () => _cancelRequested,
      onProgress: (done, total) {
        if (mounted && !_cancelRequested) {
          setState(() {
            _done = done;
            _total = total;
          });
        }
      },
    );
    if (!mounted) return;
    if (_cancelRequested) {
      setState(() {
        _running = false;
        _cancelled = true;
        _results = probed;
        _done = probed.length;
      });
      return;
    }
    final marked = applySiteCheckAutoHide(probed);
    final applied = <SiteCheckResult>[];
    for (final result in marked) {
      if (!result.autoHidden) {
        applied.add(result);
        continue;
      }
      try {
        await widget.store.setSiteVisible(result.siteId, false);
        applied.add(result);
      } catch (_) {
        applied.add(result.copyWith(autoHidden: false));
      }
    }
    DateTime? lastRun;
    try {
      lastRun = DateTime.now();
      await widget.store.setSiteCheckLastRun(lastRun);
    } catch (_) {
      lastRun = widget.store.siteCheckLastRun;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = applied;
      _done = applied.length;
      _total = applied.length;
      _lastRun = lastRun;
    });
  }

  Future<void> _restore(SiteCheckResult result) async {
    if (_pendingRestore.contains(result.siteId)) return;
    setState(() => _pendingRestore.add(result.siteId));
    await saveUserChange(
      context,
      () => widget.store.setSiteVisible(result.siteId, true),
    );
    if (!mounted) return;
    setState(() {
      _pendingRestore.remove(result.siteId);
      _restored.add(result.siteId);
    });
  }

  Widget _resultTile(SiteCheckResult result) {
    final icon = result.isOk
        ? Icons.check_circle_outline
        : result.isSkipped
        ? Icons.block_outlined
        : Icons.error_outline;
    final color = result.isOk
        ? Colors.green
        : result.isSkipped
        ? Colors.grey
        : Colors.red;
    final autoHidden = result.autoHidden && !_restored.contains(result.siteId);
    final restored = _restored.contains(result.siteId);
    final subtitle = result.isOk
        ? '首分类 ${result.itemCount} 条'
        : result.isSkipped
        ? result.reason
        : result.reason;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(result.siteName),
      subtitle: Text(
        autoHidden
            ? '$subtitle · 已自动隐藏'
            : restored
            ? '$subtitle · 已恢复显示'
            : result.wasHidden && result.isFailed
            ? '$subtitle · 检查前已隐藏'
            : subtitle,
      ),
      trailing: autoHidden
          ? TextButton(
              onPressed: _pendingRestore.contains(result.siteId)
                  ? null
                  : () => _restore(result),
              child: const Text('恢复显示'),
            )
          : null,
    );
  }

  Widget _group(String title, List<SiteCheckResult> results) {
    if (results.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            '$title（${results.length}）',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final result in results) _resultTile(result),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupSiteCheckResults(_results);
    return Scaffold(
      appBar: AppBar(title: const Text('站点检查')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(formatSiteCheckLastRun(_lastRun)),
              const SizedBox(height: 8),
              const Text(
                '逐站请求首分类第一页：有内容算正常，空结果、报错或超时算异常。异常站会自动隐藏，不是删除，可在源管理里手动恢复显示。',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _running ? null : _run,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重新检查'),
                  ),
                  const SizedBox(width: 8),
                  if (_running)
                    OutlinedButton(
                      onPressed: () => setState(() => _cancelRequested = true),
                      child: const Text('取消'),
                    ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      appPageRoute<void>(
                        builder: (_) =>
                            SourceVisibilityScreen(store: widget.store),
                      ),
                    ),
                    child: const Text('源显示列表'),
                  ),
                ],
              ),
              if (_running) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _total > 0 ? _done / _total : null,
                ),
                const SizedBox(height: 4),
                Text('正在检查 $_done / $_total，单站最长 15 秒，4 路分批进行'),
              ],
              if (_cancelled)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('已取消：取消后未再发起新检查，本次不做自动隐藏，也不更新上次检查时间。'),
                ),
              if (!_running && _results.isEmpty && !_cancelled)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text('当前用户没有可用站点'),
                ),
              _group('正常', groups.ok),
              _group('异常', groups.failed),
              _group('本平台不支持', groups.skipped),
            ],
          ),
        ),
      ),
    );
  }
}
