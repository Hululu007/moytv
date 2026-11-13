import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import 'magnet_file_import.dart';
import 'native_torrent_engine.dart';
import 'torrent_engine.dart';
import 'torrent_magnet.dart';
import 'torrent_playback_adapter.dart';
import 'torrent_playback_launch.dart';
import 'torrent_session_store.dart';

class TorrentHomePage extends StatefulWidget {
  const TorrentHomePage({
    super.key,
    this.initialMagnet = '',
    this.repository,
    this.store,
  });

  final String initialMagnet;

  /// 播放要用的仓库与本地存储；不传时只能解析与保存，不能播。
  final AppRepository? repository;
  final LocalStore? store;

  @override
  State<TorrentHomePage> createState() => _TorrentHomePageState();
}

class _TorrentHomePageState extends State<TorrentHomePage> {
  final _input = TextEditingController();
  final _store = TorrentSessionStore();
  final _adapter = TorrentPlaybackAdapter();
  List<TorrentSession> _sessions = [];
  TorrentMagnet? _parsed;
  String? _parseError;
  bool _loading = true;
  bool _importing = false;
  String _engineNote = '';
  final Set<String> _busyIds = {};
  Timer? _statsTimer;

  @override
  void initState() {
    super.initState();
    _input.text = widget.initialMagnet;
    if (widget.initialMagnet.isNotEmpty) _parse();
    _reload();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final sessions = await _store.load();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loading = false;
    });
  }

  void _parse() {
    final parsed = parseMagnetUri(_input.text);
    setState(() {
      _parsed = parsed;
      _parseError = parsed == null ? '不是有效的磁力链接：需要 magnet:?xt=urn:btih: 开头并带 40 位十六进制或 32 位 Base32 哈希' : null;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    setState(() => _input.text = text);
    _parse();
  }

  Future<void> _saveParsed() async {
    final parsed = _parsed;
    if (parsed == null) return;
    final sessions = await _store.add(parsed);
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _parsed = null;
      _input.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _adapter.isAvailable
              ? '已保存，点“解析”取文件列表'
              : '已保存，引擎接入后才能解析与播放',
        ),
      ),
    );
  }

  Future<void> _remove(TorrentSession session) async {
    final sessions = await _store.remove(session.id);
    if (!mounted) return;
    setState(() => _sessions = sessions);
  }

  Future<void> _copyLink(TorrentSession session) async {
    await Clipboard.setData(ClipboardData(text: session.magnet.uri));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('磁力链接已复制')));
  }

  Future<void> _importFiles() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'csv', 'xlsx', 'xls'],
      );
      if (!mounted) return;
      if (picked.isEmpty) return;
      final found = <TorrentMagnet>[];
      var skipped = 0;
      final unsupported = <String>[];
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          skipped++;
          continue;
        }
        final result = importMagnetsFromBytes(bytes, file.name);
        if (result.unsupported) {
          unsupported.add('${file.name}：${result.unsupportedReason}');
          continue;
        }
        found.addAll(result.magnets);
        skipped += result.skipped;
      }
      final outcome = await _store.addAll(found);
      if (!mounted) return;
      setState(() => _sessions = outcome.sessions);
      final summary = StringBuffer(
        '导入完成：新增 ${outcome.added} 个，重复 ${outcome.duplicates} 个',
      );
      if (skipped > 0) summary.write('，跳过坏行 $skipped 行');
      if (unsupported.isNotEmpty) {
        summary.write('，${unsupported.length} 个文件不支持');
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(summary.toString())));
      if (unsupported.isNotEmpty && mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('部分文件不支持'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final row in unsupported)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(row),
                    ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 解析一条会话：取元数据与文件列表，成功后状态为可播放。
  Future<bool> _resolveSession(TorrentSession session) async {
    if (!_adapter.isAvailable) {
      _showMessage('种子引擎未接入，无法解析：先接 TorrServer 或迅雷引擎');
      return false;
    }
    if (_busyIds.contains(session.id)) return false;
    if (session.state == TorrentSessionState.streaming) return false;
    _busyIds.add(session.id);
    try {
      try {
        if (session.state == TorrentSessionState.ready) {
          session.transitionTo(
            TorrentSessionState.stopped,
            engineAvailable: true,
          );
        }
        session.transitionTo(
          TorrentSessionState.resolvingMetadata,
          engineAvailable: true,
        );
      } on TorrentEngineUnavailable catch (error) {
        _showMessage(error.message);
        return false;
      } on StateError catch (error) {
        _showMessage(error.message);
        return false;
      }
      if (mounted) setState(() {});
      try {
        final torrent = await _adapter.engine.addTorrent(session.magnet);
        session.files = torrent.files;
        session.transitionTo(
          TorrentSessionState.ready,
          engineAvailable: true,
        );
        final engine = _adapter.engine;
        _engineNote = torrent.backendLabel.isEmpty
            ? ''
            : '上次解析走${torrent.backendLabel}。'
              '${engine is NativeTorrentEngine && engine.serverError.isNotEmpty ? 'TorrServer：${engine.serverError}。' : ''}';
        await _refreshStats(session);
        _startStatsTimer();
        if (mounted) setState(() {});
        return true;
      } catch (error) {
        final message = error is TorrentEngineUnavailable
            ? error.message
            : error is AppFailure
            ? error.message
            : '解析失败：$error';
        session.markFailed(message);
        if (mounted) setState(() {});
        _showMessage(message);
        return false;
      }
    } finally {
      _busyIds.remove(session.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshStats(TorrentSession session) async {
    if (!_adapter.isAvailable) return;
    try {
      final stats = await _adapter.engine.stats(session.id);
      session.stats = stats;
    } catch (_) {}
  }

  void _startStatsTimer() {
    if (_statsTimer != null) return;
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final active = [
        for (final session in _sessions)
          if (session.state == TorrentSessionState.ready ||
              session.state == TorrentSessionState.streaming)
            session,
      ];
      if (active.isEmpty) {
        _statsTimer?.cancel();
        _statsTimer = null;
        return;
      }
      for (final session in active) {
        await _refreshStats(session);
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _play(TorrentSession session) async {
    final repository = widget.repository;
    final store = widget.store;
    if (repository == null || store == null) {
      _showMessage('当前入口没有播放器上下文，请从详情页或首页种子入口打开');
      return;
    }
    if (!_adapter.isAvailable) {
      _showMessage('种子引擎未接入，无法播放：先接 TorrServer 或迅雷引擎');
      return;
    }
    if (_busyIds.contains(session.id)) return;
    if (session.files.isEmpty ||
        session.state == TorrentSessionState.saved ||
        session.state == TorrentSessionState.stopped ||
        session.state == TorrentSessionState.failed) {
      final ok = await _resolveSession(session);
      if (!ok || !mounted) return;
    }
    final file = await _pickFile(session);
    if (file == null || !mounted) return;
    _busyIds.add(session.id);
    try {
      try {
        if (session.state == TorrentSessionState.ready) {
          session.transitionTo(
            TorrentSessionState.streaming,
            engineAvailable: true,
          );
        }
      } on StateError catch (error) {
        _showMessage(error.message);
        return;
      }
      if (mounted) setState(() {});
      final url = await _adapter.resolvePlayableUrl(
        session,
        fileIndex: file.index,
      );
      if (!mounted) return;
      await playTorrentFile(
        context,
        repository: repository,
        store: store,
        session: session,
        file: file,
        streamUrl: url,
      );
      try {
        session.transitionTo(
          TorrentSessionState.stopped,
          engineAvailable: true,
        );
      } catch (_) {}
      if (mounted) setState(() {});
    } on TorrentEngineUnavailable catch (error) {
      _showMessage(error.message);
    } catch (error) {
      _showMessage(error is AppFailure ? error.message : '播放失败：$error');
    } finally {
      _busyIds.remove(session.id);
      if (mounted) setState(() {});
    }
  }

  /// 选文件：只有一个文件直接播；多个弹列表，默认项标出来。
  Future<EngineFile?> _pickFile(TorrentSession session) async {
    final files = session.files;
    if (files.isEmpty) {
      _showMessage('没有可播放的文件：先解析种子');
      return null;
    }
    final preferred = defaultPlayableFile(files);
    if (files.length == 1 || preferred == null) return files.first;
    return showModalBottomSheet<EngineFile>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('选择要播放的文件'),
              subtitle: Text('默认选最大的视频文件'),
            ),
            for (final file in files)
              ListTile(
                leading: Icon(
                  file.isVideo
                      ? Icons.play_circle_outline_rounded
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(
                  file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_formatSize(file.size)),
                trailing: file == preferred
                    ? const Chip(label: Text('默认'))
                    : null,
                onTap: () => Navigator.of(context).pop(file),
              ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('种子')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _engineCard(colors),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('torrent-magnet-input'),
                  controller: _input,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '磁力链接',
                    hintText: '粘贴 magnet:?xt=urn:btih:…',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _parse(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _paste,
                      icon: const Icon(Icons.content_paste_rounded),
                      label: const Text('粘贴'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _parse,
                      child: const Text('解析'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _parsed == null ? null : _saveParsed,
                      child: const Text('保存'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _importing ? null : _importFiles,
                      icon: const Icon(Icons.upload_file_rounded),
                      label: const Text('导入文件'),
                    ),
                  ],
                ),
                if (_parseError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _parseError!,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                if (_parsed != null) ...[
                  const SizedBox(height: 12),
                  _parsedCard(_parsed!, colors),
                ],
                const SizedBox(height: 20),
                Text('已保存的种子', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_sessions.isEmpty)
                  const Text('还没有保存的种子：粘贴磁力链接解析后保存'),
                for (var i = 0; i < _sessions.length; i++) ...[
                  _sessionCard(_sessions[i], i, colors),
                  const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }

  Widget _engineCard(ColorScheme colors) {
    if (!_adapter.isAvailable) {
      return Card(
        color: colors.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: colors.onErrorContainer),
                  const SizedBox(width: 8),
                  Text(
                    '种子引擎未接入',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onErrorContainer,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '磁力链接可以解析与保存，但解析种子元数据、取文件列表、边下边播都需要引擎；现在没有引擎，所以不能下载、不能播放，这里不显示假进度、假速度。',
              ),
              const SizedBox(height: 8),
              const Text('接上去还需要：'),
              for (final piece in TorrentEngineFactory.missingPieces)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('· '),
                      Expanded(child: Text(piece)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Card(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_outline_rounded, color: colors.onPrimaryContainer),
                const SizedBox(width: 8),
                Text(
                  '种子引擎：TorrServer + 迅雷',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '点“解析”取文件列表，点“播放”边下边播；magnet 走 TorrServer，迅雷/ed2k 链接走迅雷。本地服务在首次解析时启动，迅雷链接按普通速度下载，没有加速。',
            ),
            if (_engineNote.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_engineNote),
            ],
          ],
        ),
      ),
    );
  }

  Widget _parsedCard(TorrentMagnet parsed, ColorScheme colors) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('名称：${parsed.nameOrHash}'),
            const SizedBox(height: 4),
            Text('哈希：${parsed.infoHash}'),
            if (parsed.isBase32Hash) const Text('哈希格式：Base32'),
            const SizedBox(height: 4),
            Text(
              parsed.trackers.isEmpty
                  ? 'Tracker：无'
                  : 'Tracker：${parsed.trackers.length} 个',
            ),
            for (final tracker in parsed.trackers.take(3))
              Text(
                tracker,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            const SizedBox(height: 4),
            const Text('文件列表需引擎解析元数据后才能显示'),
          ],
        ),
      ),
    );
  }

  Widget _sessionCard(TorrentSession session, int index, ColorScheme colors) {
    final busy = _busyIds.contains(session.id);
    final isMagnet = session.magnet.uri.toLowerCase().startsWith('magnet:?');
    final number = (index + 1).toString().padLeft(3, '0');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  child: Text(
                    number,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    session.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Chip(
                  label: Text(torrentSessionStateLabel(session.state)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              isMagnet
                  ? '磁力 $number · 哈希：${session.magnet.shortHash}…'
                  : '磁力 $number · ${session.magnet.uri}',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _statsLine(session),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            if (session.files.isEmpty)
              const Text('文件列表：需引擎解析元数据后才能显示')
            else
              ..._fileRows(session, colors),
            if (session.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  session.error,
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => _resolveSession(session),
                  child: const Text('解析'),
                ),
                FilledButton(
                  onPressed: busy ? null : () => _play(session),
                  child: const Text('播放'),
                ),
                TextButton(
                  onPressed: () => _copyLink(session),
                  child: const Text('复制链接'),
                ),
                TextButton(
                  onPressed: () => _remove(session),
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _fileRows(TorrentSession session, ColorScheme colors) {
    const cap = 20;
    final files = session.files;
    final shown = files.take(cap).toList();
    final rows = <Widget>[
      Text(
        '文件 ${files.length} 个，点一行直接播该文件',
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      ),
    ];
    for (final file in shown) {
      rows.add(
        InkWell(
          onTap: () => _playFile(session, file),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  file.isVideo
                      ? Icons.play_circle_outline_rounded
                      : Icons.insert_drive_file_outlined,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Text(
                  _formatSize(file.size),
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (files.length > cap) {
      rows.add(
        Text(
          '其余 ${files.length - cap} 个文件点“播放”时选',
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
        ),
      );
    }
    return rows;
  }

  Future<void> _playFile(TorrentSession session, EngineFile file) async {
    final repository = widget.repository;
    final store = widget.store;
    if (repository == null || store == null) {
      _showMessage('当前入口没有播放器上下文，请从详情页或首页种子入口打开');
      return;
    }
    if (!_adapter.isAvailable) {
      _showMessage('种子引擎未接入，无法播放：先接 TorrServer 或迅雷引擎');
      return;
    }
    if (session.state != TorrentSessionState.ready &&
        session.state != TorrentSessionState.streaming) {
      _showMessage('先点“解析”，等文件列表出来再播');
      return;
    }
    try {
      if (session.state == TorrentSessionState.ready) {
        session.transitionTo(
          TorrentSessionState.streaming,
          engineAvailable: true,
        );
      }
      if (mounted) setState(() {});
      final url = await _adapter.resolvePlayableUrl(
        session,
        fileIndex: file.index,
      );
      if (!mounted) return;
      await playTorrentFile(
        context,
        repository: repository,
        store: store,
        session: session,
        file: file,
        streamUrl: url,
      );
      try {
        session.transitionTo(
          TorrentSessionState.stopped,
          engineAvailable: true,
        );
      } catch (_) {}
      if (mounted) setState(() {});
    } on TorrentEngineUnavailable catch (error) {
      _showMessage(error.message);
    } catch (error) {
      _showMessage(error is AppFailure ? error.message : '播放失败：$error');
    }
  }

  String _statsLine(TorrentSession session) {
    final stats = session.stats;
    if (!stats.hasLiveData) {
      return _adapter.isAvailable
          ? '进度、速度、Peer 数：解析后显示真实数据'
          : '进度、速度、Peer 数：无引擎，无数据';
    }
    final parts = <String>[];
    if (stats.downloadBytesPerSec != null) {
      parts.add('速度 ${_formatSpeed(stats.downloadBytesPerSec!)}');
    }
    if (stats.progress != null) {
      parts.add('进度 ${(stats.progress! * 100).toStringAsFixed(0)}%');
    }
    if (stats.peers != null || stats.seeds != null) {
      parts.add('Peer ${stats.peers ?? 0}/种子 ${stats.seeds ?? 0}');
    }
    if (stats.downloadedBytes != null && stats.totalBytes != null) {
      parts.add(
        '${_formatSize(stats.downloadedBytes!)}/${_formatSize(stats.totalBytes!)}',
      );
    }
    return parts.isEmpty ? '暂无实时数据' : parts.join(' · ');
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec < 1024) return '$bytesPerSec B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }
}
