import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'torrent_engine.dart';
import 'torrent_magnet.dart';
import 'torrent_playback_adapter.dart';
import 'torrent_session_store.dart';

class TorrentHomePage extends StatefulWidget {
  const TorrentHomePage({super.key, this.initialMagnet = ''});

  final String initialMagnet;

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

  @override
  void initState() {
    super.initState();
    _input.text = widget.initialMagnet;
    if (widget.initialMagnet.isNotEmpty) _parse();
    _reload();
  }

  @override
  void dispose() {
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已保存，引擎接入后才能解析与播放')));
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

  void _play(TorrentSession session) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('种子引擎未接入，无法播放：先接 TorrServer 或迅雷引擎')),
    );
  }

  void _resolve(TorrentSession session) {
    try {
      session.transitionTo(
        TorrentSessionState.resolvingMetadata,
        engineAvailable: _adapter.isAvailable,
      );
    } on TorrentEngineUnavailable catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    } on StateError catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
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
                for (final session in _sessions) ...[
                  _sessionCard(session, colors),
                  const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }

  Widget _engineCard(ColorScheme colors) {
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

  Widget _sessionCard(TorrentSession session, ColorScheme colors) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
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
              '哈希：${session.magnet.shortHash}…',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            Text(
              session.stats.hasLiveData
                  ? '进度以引擎返回为准'
                  : '进度、速度、Peer 数：无引擎，无数据',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
            if (session.files.isEmpty)
              const Text('文件列表：需引擎解析元数据后才能显示'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => _resolve(session),
                  child: const Text('解析'),
                ),
                FilledButton(
                  onPressed: () => _play(session),
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
}
