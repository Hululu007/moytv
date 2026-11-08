import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'content_models.dart';
import 'nonvideo_content.dart';
import 'novel_tts.dart';
import 'reading_bookshelf.dart';

class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.source,
    required this.book,
    this.ttsEngine,
    this.initialChapterIndex,
  });

  final ContentSource source;
  final ContentBook book;
  final NovelTtsEngine? ttsEngine;
  final int? initialChapterIndex;

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  List<ContentChapter> _chapters = const [];
  int _index = 0;
  int _initialPage = 0;
  int _currentPage = 0;
  int _historyChapterIndex = -1;
  bool _shelved = false;
  NonVideoContent? _content;
  bool _loading = true;
  String _error = '';
  bool _overlayVisible = false;
  bool _ttsPlaying = false;
  bool _ttsPaused = false;
  double _ttsRate = 1.0;
  List<String> _ttsChunks = const [];
  int _ttsChunkIndex = 0;

  late final NovelTtsEngine _tts =
      widget.ttsEngine ?? FlutterTtsNovelTtsEngine();

  double get _pluginRate => _ttsRate * 0.5;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_initTts());
    unawaited(_loadShelved());
    _loadDetail();
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
            lastChapterIndex: _chapters.isEmpty ? 0 : _index,
            lastChapterTitle: _chapters.isEmpty ? '' : _chapters[_index].title,
            chapterTotal: _chapters.length,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (mounted) setState(() => _shelved = true);
      }
    } catch (_) {}
  }

  Future<void> _savePosition() async {
    if (_chapters.isEmpty) return;
    try {
      await saveBookmark(
        sourceId: widget.source.id,
        bookId: widget.book.id,
        chapterIndex: _index,
        pageIndex: _currentPage,
        chapterTitle: _chapters[_index].title,
        chapterTotal: _chapters.length,
      );
    } catch (_) {}
    if (_index != _historyChapterIndex) {
      unawaited(_recordHistory());
    }
  }

  Future<void> _recordHistory() async {
    if (_chapters.isEmpty) return;
    try {
      await recordReadingHistory(
        ReadingShelfEntry(
          sourceId: widget.source.id,
          sourceName: widget.source.name,
          bookId: widget.book.id,
          title: widget.book.title,
          cover: widget.book.cover,
          author: widget.book.author,
          lastChapterIndex: _index,
          lastChapterTitle: _chapters[_index].title,
          chapterTotal: _chapters.length,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _historyChapterIndex = _index;
    } catch (_) {}
  }

  void _onReaderPageChanged(int page) {
    _currentPage = page;
    unawaited(_savePosition());
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setRate(_pluginRate);
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_savePosition());
    unawaited(_tts.stop().then((_) {}, onError: (_) {}));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadDetail() async {
    try {
      final detail = await widget.source.detail(widget.book.id);
      if (!mounted) return;
      if (detail.chapters.isEmpty) {
        setState(() {
          _loading = false;
          _error = '该书暂无章节';
        });
        return;
      }
      _chapters = detail.chapters;
      ReadingBookmark? bookmark;
      try {
        bookmark = await loadBookmark(widget.source.id, widget.book.id);
      } catch (_) {}
      final startIndex = (widget.initialChapterIndex ??
              (bookmark == null ? 0 : bookmark.chapterIndex))
          .clamp(0, _chapters.length - 1);
      _initialPage =
          widget.initialChapterIndex != null ? 0 : bookmark?.pageIndex ?? 0;
      await _loadChapter(startIndex, resume: true);
      unawaited(_recordHistory());
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载章节失败';
        });
      }
    }
  }

  Future<void> _loadChapter(int index, {bool resume = false}) async {
    if (index < 0 || index >= _chapters.length) return;
    setState(() {
      _loading = true;
      _error = '';
      _index = index;
      if (!resume) _initialPage = 0;
    });
    try {
      final track = await widget.source.audioTrack(
        widget.book.id,
        _chapters[index],
      );
      final parsed = parseNonVideoUrl(track.url, headers: track.headers);
      if (!mounted) return;
      if (parsed == null || (!parsed.isNovel && !parsed.isPics)) {
        final url = track.url.toLowerCase();
        final isVideo =
            (url.startsWith('http://') || url.startsWith('https://')) &&
            (url.contains('.m3u8') ||
                RegExp(r'\.(mp4|mkv|mov|webm|avi|flv)(\?|$)').hasMatch(url));
        setState(() {
          _loading = false;
          _error = isVideo ? '该章是视频，阅读器打不开' : '该章不是小说文本';
          _ttsPlaying = false;
          _ttsPaused = false;
        });
        return;
      }
      setState(() {
        _loading = false;
        _content = parsed;
        _ttsChunks = const [];
        _ttsChunkIndex = 0;
        _currentPage = _initialPage;
      });
      unawaited(_savePosition());
      if (_ttsPlaying) _speakCurrent();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载章节失败';
          _ttsPlaying = false;
          _ttsPaused = false;
        });
      }
    }
  }

  Future<void> _speakCurrent() async {
    final content = _content;
    if (content == null || content.text.isEmpty) {
      if (mounted) {
        setState(() {
          _ttsPlaying = false;
          _ttsPaused = false;
        });
      }
      return;
    }
    _ttsChunks = splitTtsText(content.text);
    _ttsChunkIndex = 0;
    _speakChunk();
  }

  Future<void> _speakChunk() async {
    if (_ttsChunkIndex >= _ttsChunks.length) {
      _onChapterReadComplete();
      return;
    }
    try {
      await _tts.setRate(_pluginRate);
      await _tts.speak(_ttsChunks[_ttsChunkIndex], () {
        if (!mounted || !_ttsPlaying) return;
        _ttsChunkIndex++;
        _speakChunk();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _ttsPlaying = false;
        _ttsPaused = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('朗读失败')));
    }
  }

  void _onChapterReadComplete() {
    if (!mounted || !_ttsPlaying) return;
    if (_index + 1 < _chapters.length) {
      _loadChapter(_index + 1);
    } else {
      setState(() {
        _ttsPlaying = false;
        _ttsPaused = false;
      });
    }
  }

  void _toggleTts() {
    if (_content == null || _error.isNotEmpty) return;
    if (_ttsPlaying) {
      setState(() {
        _ttsPlaying = false;
        _ttsPaused = true;
      });
      unawaited(_tts.stop());
    } else {
      final resume = _ttsChunks.isNotEmpty;
      setState(() {
        _ttsPlaying = true;
        _ttsPaused = false;
      });
      if (resume) {
        _speakChunk();
      } else {
        _speakCurrent();
      }
    }
  }

  void _stopTts() {
    if (!_ttsPlaying && !_ttsPaused) return;
    setState(() {
      _ttsPlaying = false;
      _ttsPaused = false;
      _ttsChunks = const [];
      _ttsChunkIndex = 0;
    });
    unawaited(_tts.stop());
  }

  void _setTtsRate(double rate) {
    setState(() => _ttsRate = rate);
    unawaited(_tts.setRate(_pluginRate));
  }

  Future<void> _pickChapter() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择章节'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: ListView.builder(
            itemCount: _chapters.length,
            itemBuilder: (context, i) => ListTile(
              title: Text(_chapters[i].title),
              selected: i == _index,
              onTap: () => Navigator.of(context).pop(i),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (picked != null && picked != _index) _loadChapter(picked);
  }

  @override
  Widget build(BuildContext context) {
    final chapterTitle = _chapters.isEmpty ? '' : _chapters[_index].title;
    final showTop = _overlayVisible || _loading || _error.isNotEmpty;
    final showBottom = _overlayVisible && _content != null && _error.isEmpty;
    return PopScope(
      canPop: !_overlayVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _overlayVisible) {
          setState(() => _overlayVisible = false);
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Stack(
          children: [
            _loading
                ? const Center(child: CircularProgressIndicator())
                : _error.isNotEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => _index < _chapters.length
                              ? _loadChapter(_index)
                              : _loadDetail(),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  )
                : _content == null
                ? const Center(child: Text('暂无内容'))
                : _content!.isPics
                ? PicsViewerView(
                    content: _content!,
                    title: chapterTitle,
                    initialIndex: _initialPage,
                    onIndexChanged: _onReaderPageChanged,
                  )
                : NovelReaderView(
                    content: _content!,
                    title: chapterTitle,
                    onCenterTap: () =>
                        setState(() => _overlayVisible = !_overlayVisible),
                    initialPage: _initialPage,
                    onPageChanged: _onReaderPageChanged,
                  ),
            if (showTop)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  child: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('novel-back'),
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(
                          widget.book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('novel-bookshelf-toggle'),
                        tooltip: _shelved ? '移出书架' : '加入书架',
                        onPressed: _toggleShelf,
                        icon: Icon(
                          _shelved
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('novel-chapter-list'),
                        tooltip: '章节列表',
                        onPressed: _chapters.isEmpty ? null : _pickChapter,
                        icon: const Icon(
                          Icons.list_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (showBottom)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        key: const ValueKey('novel-prev-chapter'),
                        tooltip: '上一章',
                        onPressed: _index > 0
                            ? () => _loadChapter(_index - 1)
                            : null,
                        icon: const Icon(
                          Icons.chevron_left,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('novel-tts-play-pause'),
                        tooltip: _ttsPlaying ? '暂停朗读' : '开始朗读',
                        onPressed: _toggleTts,
                        icon: Icon(
                          _ttsPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('novel-tts-stop'),
                        tooltip: '停止朗读',
                        onPressed: _ttsPlaying || _ttsPaused ? _stopTts : null,
                        icon: const Icon(Icons.stop, color: Colors.white),
                      ),
                      PopupMenuButton<double>(
                        key: const ValueKey('novel-tts-rate'),
                        tooltip: '朗读语速',
                        initialValue: _ttsRate,
                        onSelected: _setTtsRate,
                        icon: const Icon(Icons.speed, color: Colors.white),
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 0.5, child: Text('0.5倍')),
                          PopupMenuItem(value: 1.0, child: Text('1倍')),
                          PopupMenuItem(value: 1.5, child: Text('1.5倍')),
                          PopupMenuItem(value: 2.0, child: Text('2倍')),
                        ],
                      ),
                      IconButton(
                        key: const ValueKey('novel-next-chapter'),
                        tooltip: '下一章',
                        onPressed: _index + 1 < _chapters.length
                            ? () => _loadChapter(_index + 1)
                            : null,
                        icon: const Icon(
                          Icons.chevron_right,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
