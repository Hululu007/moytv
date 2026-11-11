import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'audio_history.dart';
import 'content_detail_screen.dart';
import 'content_models.dart';

String _formatMs(int ms) {
  final total = ms < 0 ? 0 : ms ~/ 1000;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$mm:$ss';
  return '$mm:$ss';
}

class AudioHistoryScreen extends StatefulWidget {
  const AudioHistoryScreen({
    super.key,
    required this.sources,
    this.initialTab = 0,
  });

  final List<ContentSource> sources;
  final int initialTab;

  @override
  State<AudioHistoryScreen> createState() => _AudioHistoryScreenState();
}

class _AudioHistoryScreenState extends State<AudioHistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 1),
  );
  List<AudioListenRecord> _history = const [];
  List<AudioFavoriteEntry> _favorites = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    List<AudioListenRecord> history = const [];
    List<AudioFavoriteEntry> favorites = const [];
    try {
      history = await loadAudioHistory();
    } catch (_) {}
    try {
      favorites = await loadAudioFavorites();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _history = history;
      _favorites = favorites;
      _loading = false;
    });
  }

  ContentSource? _sourceOf(String sourceId) {
    return widget.sources.where((item) => item.id == sourceId).firstOrNull;
  }

  Future<void> _openHistory(AudioListenRecord record) async {
    final source = _sourceOf(record.sourceId);
    if (source == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该书的源已不在，请重新导入')));
      }
      return;
    }
    await Navigator.of(context).push(
      appPageRoute(
        builder: (_) => ContentDetailScreen(
          source: source,
          book: ContentBook(
            id: record.bookId,
            title: record.title,
            cover: record.cover,
            author: record.author,
          ),
          initialChapterIndex: record.chapterIndex,
          initialPositionMs: record.positionMs,
        ),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _openFavorite(AudioFavoriteEntry entry) async {
    final source = _sourceOf(entry.sourceId);
    if (source == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该书的源已不在，请重新导入')));
      }
      return;
    }
    await Navigator.of(context).push(
      appPageRoute(
        builder: (_) => ContentDetailScreen(
          source: source,
          book: ContentBook(
            id: entry.bookId,
            title: entry.title,
            cover: entry.cover,
            author: entry.author,
          ),
        ),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _removeHistory(AudioListenRecord record) async {
    try {
      await removeAudioHistory(record.sourceId, record.bookId);
    } catch (_) {}
    if (mounted) _reload();
  }

  Future<void> _removeFavorite(AudioFavoriteEntry entry) async {
    try {
      await removeAudioFavorite(entry.sourceId, entry.bookId);
    } catch (_) {}
    if (mounted) _reload();
  }

  Widget _cover(String url, ColorScheme colors) {
    if (url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          url,
          width: 56,
          height: 76,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _coverFallback(colors),
        ),
      );
    }
    return _coverFallback(colors);
  }

  Widget _coverFallback(ColorScheme colors) {
    return Container(
      width: 56,
      height: 76,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.headphones_outlined, color: colors.onSurfaceVariant),
    );
  }

  Widget _row({
    required String cover,
    required String title,
    required String line,
    required String sourceName,
    required ColorScheme colors,
    required VoidCallback onTap,
    required VoidCallback onRemove,
    required String removeTooltip,
    required String removeKey,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cover(cover, colors),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    line,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey(removeKey),
              tooltip: removeTooltip,
              icon: const Icon(Icons.delete_outline),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyList() {
    final colors = Theme.of(context).colorScheme;
    final visible = visibleAudioRecords(_history);
    if (visible.isEmpty) {
      return const Center(child: Text('还没有收听记录，听过的书会出现在这里'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final record = visible[index];
        final position = record.durationMs > 0
            ? '听到 ${_formatMs(record.positionMs)} / ${_formatMs(record.durationMs)}'
            : record.positionMs > 0
            ? '听到 ${_formatMs(record.positionMs)}'
            : '第 ${record.chapterIndex + 1} 集';
        final line = record.chapterTitle.isNotEmpty
            ? '第 ${record.chapterIndex + 1} 集 · ${record.chapterTitle} · $position'
            : '第 ${record.chapterIndex + 1} 集 · $position';
        return _row(
          cover: record.cover,
          title: record.title,
          line: line,
          sourceName: record.sourceName,
          colors: colors,
          onTap: () => _openHistory(record),
          onRemove: () => _removeHistory(record),
          removeTooltip: '删除这条记录',
          removeKey: 'audio-history-remove-${record.sourceId}-${record.bookId}',
        );
      },
    );
  }

  Widget _favoriteList() {
    final colors = Theme.of(context).colorScheme;
    final visible = visibleAudioFavorites(_favorites);
    if (visible.isEmpty) {
      return const Center(child: Text('还没有收藏，听书详情页点星标即可收藏'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final entry = visible[index];
        return _row(
          cover: entry.cover,
          title: entry.title,
          line: entry.author.isNotEmpty ? entry.author : '已收藏',
          sourceName: entry.sourceName,
          colors: colors,
          onTap: () => _openFavorite(entry),
          onRemove: () => _removeFavorite(entry),
          removeTooltip: '取消收藏',
          removeKey: 'audio-favorite-remove-${entry.sourceId}-${entry.bookId}',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('听书'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '收听记录'),
            Tab(text: '我的收藏'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [_historyList(), _favoriteList()],
            ),
    );
  }
}
