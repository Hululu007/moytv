import 'dart:async';

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'audio_history.dart';
import 'audio_playback.dart';
import 'content_models.dart';
import 'core_bridge.dart';
import 'novel_cover.dart';
import 'novel_reader_page.dart';
import 'reading_bookshelf.dart';

class ContentDetailScreen extends StatefulWidget {
  const ContentDetailScreen({
    super.key,
    required this.source,
    required this.book,
    this.autoPlay = false,
    this.initialChapterIndex,
    this.initialPositionMs,
  });

  final ContentSource source;
  final ContentBook book;
  final bool autoPlay;
  final int? initialChapterIndex;
  final int? initialPositionMs;

  @override
  State<ContentDetailScreen> createState() => _ContentDetailScreenState();
}

String _formatAudioTime(Duration value) {
  final total = value.inSeconds;
  if (total < 0) return '00:00';
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$mm:$ss';
  return '$mm:$ss';
}

class _ContentDetailScreenState extends State<ContentDetailScreen> {
  ContentBookDetail? _detail;
  String _error = '';
  bool _loading = true;
  bool _shelved = false;
  bool _autoPlayed = false;
  AudioListenRecord? _resume;
  bool _favorited = false;
  int _lastSeenPlayingIndex = -1;

  /// 播放器归应用级单例所有，详情页只挂接界面：离开页面播放继续，
  /// 重进显示当前真实状态（播/停/进度/章节）。
  AudioPlaybackController get _audio => AudioPlaybackController.instance;

  bool get _isCurrentBook =>
      _audio.isCurrentBook(widget.source.id, widget.book.id);

  /// 以下播放态只在单例播的正是本书时取单例的值，否则闲置态。
  int get _playingIndex => _isCurrentBook ? _audio.playingIndex : -1;
  Duration get _position => _isCurrentBook ? _audio.position : Duration.zero;
  Duration get _duration => _isCurrentBook ? _audio.duration : Duration.zero;
  bool get _playing => _isCurrentBook && _audio.playing;
  double get _rate => _audio.rate;
  bool get _trackLoading => _isCurrentBook && _audio.trackLoading;
  String get _trackError => _isCurrentBook ? _audio.trackError : '';

  Widget _coverBox(
    ContentBook book,
    ColorScheme colors,
    double width,
    double height,
  ) {
    if (widget.source.section == ContentSection.novel) {
      return novelCoverFallback(book.id, width, height);
    }
    return Container(
      width: width,
      height: height,
      color: colors.surfaceContainerHighest,
    );
  }

  @override
  void initState() {
    super.initState();
    _audio.addListener(_onAudioChanged);
    unawaited(_loadShelved());
    unawaited(_loadAudioState());
    _load();
  }

  void _onAudioChanged() {
    if (!mounted) return;
    final current = _playingIndex;
    if (current != _lastSeenPlayingIndex) {
      _lastSeenPlayingIndex = current;
      unawaited(_loadAudioState());
    }
    setState(() {});
  }

  @override
  void dispose() {
    // 只摘监听：播放器与三路后台输出归单例所有，离页继续播。
    _audio.removeListener(_onAudioChanged);
    super.dispose();
  }

  Future<void> _loadAudioState() async {
    if (widget.source.section != ContentSection.audio) return;
    try {
      final resume = await loadAudioResume(widget.source.id, widget.book.id);
      final favorited = await isAudioFavorite(widget.source.id, widget.book.id);
      if (mounted) {
        setState(() {
          _resume = resume;
          _favorited = favorited;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    try {
      if (_favorited) {
        await removeAudioFavorite(widget.source.id, widget.book.id);
        if (mounted) setState(() => _favorited = false);
      } else {
        await addAudioFavorite(
          AudioFavoriteEntry(
            sourceId: widget.source.id,
            sourceName: widget.source.name,
            bookId: widget.book.id,
            title: widget.book.title,
            cover: widget.book.cover,
            author: widget.book.author,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (mounted) setState(() => _favorited = true);
      }
    } catch (_) {}
  }

  Future<void> _loadShelved() async {
    try {
      final shelved = await isShelved(widget.source.id, widget.book.id);
      if (mounted) setState(() => _shelved = shelved);
    } catch (_) {}
  }

  Future<void> _toggleShelf() async {
    try {
      if (_shelved) {
        await removeShelfEntry(widget.source.id, widget.book.id);
        if (mounted) setState(() => _shelved = false);
      } else {
        await addShelfEntry(
          ReadingShelfEntry(
            sourceId: widget.source.id,
            sourceName: widget.source.name,
            bookId: widget.book.id,
            title: widget.book.title,
            cover: widget.book.cover,
            author: widget.book.author,
            chapterTotal: _detail?.chapters.length ?? 0,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (mounted) setState(() => _shelved = true);
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final fetched = await widget.source.detail(widget.book.id);
      final detail = fetched.book.title.isEmpty
          ? ContentBookDetail(
              book: widget.book,
              chapters: fetched.chapters,
              note: fetched.note,
            )
          : fetched;
      if (mounted) {
        setState(() {
          _detail = detail;
          _loading = false;
        });
        if (widget.source.section == ContentSection.audio &&
            detail.chapters.isNotEmpty &&
            !_autoPlayed) {
          if (widget.initialChapterIndex != null) {
            _autoPlayed = true;
            final start = widget.initialChapterIndex!.clamp(
              0,
              detail.chapters.length - 1,
            );
            unawaited(
              _playChapter(start, seekMs: widget.initialPositionMs ?? 0),
            );
          } else if (widget.autoPlay) {
            _autoPlayed = true;
            await _loadAudioState();
            final start = (_resume?.chapterIndex ?? 0).clamp(
              0,
              detail.chapters.length - 1,
            );
            unawaited(
              _playChapter(
                start,
                seekMs: _resume?.chapterIndex == start
                    ? _resume!.positionMs
                    : 0,
              ),
            );
          }
        }
      }
    } on AppFailure catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '详情加载失败';
          _loading = false;
        });
      }
    }
  }

  Future<void> _playChapter(int index, {int seekMs = 0}) async {
    final detail = _detail;
    if (detail == null || index < 0 || index >= detail.chapters.length) return;
    await _audio.playChapter(widget.source, detail, index, seekMs: seekMs);
  }

  void _next() {
    if (!_isCurrentBook) return;
    _audio.next();
  }

  void _prev() {
    if (!_isCurrentBook) return;
    _audio.previous();
  }

  Future<void> _toggle() async {
    if (!_isCurrentBook) return;
    await _audio.toggle();
  }

  Future<void> _setRate(double rate) async {
    await _audio.setRate(rate);
  }

  Future<void> _stop() async {
    if (!_isCurrentBook) return;
    await _audio.stop();
  }

  void _openNovelReader([int? chapterIndex]) {
    Navigator.of(context).push(
      appPageRoute(
        builder: (_) => NovelReaderPage(
          source: widget.source,
          book: widget.book,
          initialChapterIndex: chapterIndex,
        ),
      ),
    );
  }

  void _onChapterTap(int index) {
    if (widget.source.section == ContentSection.novel) {
      _openNovelReader(index);
      return;
    }
    if (index == _playingIndex) {
      _toggle();
    } else {
      _playChapter(index);
    }
  }

  Widget _playerBar() {
    final detail = _detail;
    if (detail == null || _playingIndex < 0) return const SizedBox.shrink();
    final chapter = detail.chapters[_playingIndex];
    final book = detail.book;
    final colors = Theme.of(context).colorScheme;
    final maxMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;
    final posMs = _position.inMilliseconds.toDouble().clamp(0.0, maxMs);
    return Material(
      elevation: 6,
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: book.cover.isNotEmpty
                      ? Image.network(
                          book.cover,
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              _coverBox(book, colors, 40, 40),
                        )
                      : _coverBox(book, colors, 40, 40),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '第 ${_playingIndex + 1} 集 / 共 ${detail.chapters.length} 集',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '停止',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _stop,
                ),
              ],
            ),
            if (_trackError.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _trackError,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => _playChapter(_playingIndex),
                    child: const Text('重试'),
                  ),
                ],
              ),
            Row(
              children: [
                Text(_formatAudioTime(_position)),
                Expanded(
                  child: Slider(
                    value: posMs,
                    max: maxMs,
                    onChanged: (value) {
                      unawaited(
                        _audio.seek(Duration(milliseconds: value.toInt())),
                      );
                    },
                  ),
                ),
                Text(_formatAudioTime(_duration)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一集',
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: _playingIndex > 0 ? _prev : null,
                ),
                const SizedBox(width: 12),
                _trackLoading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: _playing ? '暂停' : '播放',
                        iconSize: 40,
                        icon: Icon(
                          _playing
                              ? Icons.pause_circle_filled_rounded
                              : Icons.play_circle_filled_rounded,
                        ),
                        onPressed: _toggle,
                      ),
                const SizedBox(width: 12),
                IconButton(
                  tooltip: '下一集',
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: _playingIndex + 1 < detail.chapters.length
                      ? () => _next()
                      : null,
                ),
                const SizedBox(width: 12),
                PopupMenuButton<double>(
                  tooltip: '倍速',
                  initialValue: _rate,
                  onSelected: _setRate,
                  itemBuilder: (_) => [
                    for (final rate in [0.75, 1.0, 1.25, 1.5, 2.0])
                      PopupMenuItem(value: rate, child: Text('${rate}x')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    child: Text('${_rate}x'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final book = _detail?.book ?? widget.book;
    final detailNote = _detail?.note ?? '';
    final showNote =
        detailNote.isNotEmpty &&
        detailNote.trim().replaceAll(RegExp(r'\s+'), ' ') !=
            book.intro.trim().replaceAll(RegExp(r'\s+'), ' ');
    return Scaffold(
      appBar: AppBar(title: Text(book.title, maxLines: 1)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error, style: TextStyle(color: colors.error)),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _error = '';
                      });
                      _load();
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: book.cover.isNotEmpty
                          ? Image.network(
                              book.cover,
                              width: 96,
                              height: 128,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _coverBox(book, colors, 96, 128),
                            )
                          : _coverBox(book, colors, 96, 128),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (book.author.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              book.author,
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ],
                          if (book.remarks.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              book.remarks,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            '${widget.source.name} · '
                            '${_detail?.chapters.length ?? 0} '
                            '${widget.source.section == ContentSection.audio ? '集' : '章'}',
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          if (widget.source.section ==
                              ContentSection.novel) ...[
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 10,
                                children: [
                                  FilledButton.icon(
                                    onPressed: () => _openNovelReader(),
                                    icon: const Icon(Icons.menu_book_outlined),
                                    label: const Text('阅读'),
                                  ),
                                  FilledButton.icon(
                                    key: const ValueKey(
                                      'detail-bookshelf-toggle',
                                    ),
                                    onPressed: _toggleShelf,
                                    icon: Icon(
                                      _shelved
                                          ? Icons.bookmark
                                          : Icons.bookmark_border,
                                    ),
                                    label: Text(_shelved ? '移出书架' : '加入书架'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (widget.source.section ==
                              ContentSection.audio) ...[
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 10,
                                children: [
                                  FilledButton.icon(
                                    key: const ValueKey(
                                      'detail-audio-favorite-toggle',
                                    ),
                                    onPressed: _toggleFavorite,
                                    icon: Icon(
                                      _favorited
                                          ? Icons.star
                                          : Icons.star_border,
                                    ),
                                    label: Text(_favorited ? '已收藏' : '收藏'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (widget.source.section == ContentSection.audio &&
                    _resume != null &&
                    _resume!.started &&
                    _resume!.chapterIndex < (_detail?.chapters.length ?? 0) &&
                    !(_playingIndex == _resume!.chapterIndex &&
                        _position.inMilliseconds >=
                            _resume!.positionMs - 2000)) ...[
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const ValueKey('detail-audio-resume'),
                      onPressed: () => _playChapter(
                        _resume!.chapterIndex,
                        seekMs: _resume!.positionMs,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        '继续收听：第 ${_resume!.chapterIndex + 1} 集 '
                        '${_formatAudioTime(Duration(milliseconds: _resume!.positionMs))}',
                      ),
                    ),
                  ),
                ],
                if (_playingIndex >= 0) ...[
                  const SizedBox(height: 14),
                  _playerBar(),
                ],
                if (book.intro.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(book.intro, style: const TextStyle(height: 1.5)),
                ],
                if (showNote) ...[
                  const SizedBox(height: 10),
                  Text(
                    detailNote,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Text(
                  widget.source.section == ContentSection.audio ? '集数' : '章节',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                if (_detail != null && _detail!.chapters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无章节'),
                  ),
                for (var i = 0; i < (_detail?.chapters.length ?? 0); i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    selected: i == _playingIndex,
                    leading: CircleAvatar(child: Text('${i + 1}')),
                    title: Text(
                      _detail!.chapters[i].title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: _detail!.chapters[i].meta.isNotEmpty
                        ? Text(_detail!.chapters[i].meta)
                        : null,
                    trailing: Icon(
                      i == _playingIndex && _playing
                          ? Icons.volume_up_rounded
                          : widget.source.section == ContentSection.audio
                          ? Icons.play_circle_outline_rounded
                          : Icons.chevron_right_rounded,
                    ),
                    onTap: () => _onChapterTap(i),
                  ),
              ],
            ),
    );
  }
}
