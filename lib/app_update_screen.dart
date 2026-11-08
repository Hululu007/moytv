import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';
import 'midnight_zone.dart';
import 'update_config.dart';
import 'update_download.dart';

class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  AppVersion? _current;
  AppReleaseInfo? _latest;
  String? _error;
  bool _busy = false;
  bool _checked = false;
  DownloadProgress? _progress;
  final ResumableDownloader _downloader = ResumableDownloader();
  Future<void> _onVersionDoubleTap() async {
    await activateMidnightAndExit();
  }

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    try {
      final current = await AppUpdateChecker.currentVersion();
      if (mounted) setState(() => _current = current);
    } catch (_) {}
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final latest = await AppUpdateChecker.fetchLatest();
      if (!mounted) return;
      setState(() {
        _latest = latest;
        _checked = true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadAndInstall() async {
    final latest = _latest;
    if (latest == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });
    try {
      final file = await AppUpdateChecker.downloadApk(
        latest,
        downloader: _downloader,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      await AppUpdateChannel.installApk(file.path);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _openReleasePage() async {
    final url = _latest?.htmlUrl ?? releasesPageUrl;
    if (url == null) return;
    final opened = await AppUpdateChannel.openUrl(url);
    if (!opened && mounted) {
      setState(() => _error = '无法打开浏览器，请手动前往仓库发布页');
    }
  }

  String _forceWindowText(AppReleaseInfo latest) {
    String date(DateTime value) =>
        '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final after = latest.forceAfter;
    final until = latest.forceUntil;
    if (after != null && until != null) {
      return '（${date(after)} 至 ${date(until)}）';
    }
    if (after != null) return '（${date(after)} 起）';
    if (until != null) return '（${date(until)} 前）';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final latest = _latest;
    final hasUpdate =
        latest != null && current != null && latest.version > current;
    final forced =
        latest != null &&
        current != null &&
        AppUpdateChecker.isForceUpdate(current, latest, DateTime.now());
    return Scaffold(
      appBar: AppBar(title: const Text('软件更新')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GestureDetector(
            onDoubleTap: () => unawaited(_onVersionDoubleTap()),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('当前版本'),
              subtitle: Text(current?.toString() ?? '读取中…'),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('最新版本'),
            subtitle: Text(
              latest != null
                  ? '${latest.version}（${latest.tag}）'
                  : _checked
                  ? '未获取到'
                  : '尚未检查',
            ),
          ),
          if (!updateSourceConfigured)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('更新源未配置'),
              subtitle: Text('发布时需要在 lib/update_config.dart 填入仓库'),
            )
          else ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _check,
                  icon: const Icon(Icons.refresh),
                  label: const Text('检查更新'),
                ),
                if (hasUpdate && Platform.isAndroid)
                  FilledButton.icon(
                    onPressed: _busy ? null : _downloadAndInstall,
                    icon: const Icon(Icons.download),
                    label: Text('下载并安装 ${latest.version}'),
                  ),
                if (hasUpdate && !Platform.isAndroid)
                  FilledButton.icon(
                    onPressed: _openReleasePage,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('打开发布页下载'),
                  ),
              ],
            ),
            if (latest != null && forced)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '强制更新：请在窗口期内完成更新${_forceWindowText(latest)}，否则旧版本将无法继续使用。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_checked && latest != null && !hasUpdate)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('已是最新版本'),
              ),
            if (latest?.notes.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('更新说明：\n${latest!.notes}'),
              ),
            if (_progress != null) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress!.fraction),
              const SizedBox(height: 6),
              Text('已下载 ${_progress!.received} / ${_progress!.total} 字节'),
            ],
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
