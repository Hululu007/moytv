import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app_page_route.dart';
import 'audio_background.dart';
import 'audio_capsule.dart';
import 'audio_history.dart';
import 'audio_media_session.dart';
import 'content_models.dart';
import 'core_bridge.dart';
import 'novel_cover.dart';
import 'novel_reader_page.dart';
import 'playback_foreground.dart';
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

class _ContentDetailScreenState extends State<ContentDetailScreen>
    with WidgetsBindingObserver {
  ContentBookDetail? _detail;
  String _error = '';
  bool _loading = true;
  bool _shelved = false;
  late final Player _player = Player();
  int _playingIndex = -1;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _autoPlayed = false;
  bool _trackLoading = false;
  String _trackError = '';
  bool _autoRetried = false;
  double _rate = 1.0;
  AudioListenRecord? _resume;
  bool _favorited = false;
  ({int chapter, int ms})? _pendingSeek;
  int _lastSavedAtMs = 0;
  int _lastSavedPositionMs = -1;
  final List<StreamSubscription<dynamic>> _subs = [];

  // 听书后台三件的状态。
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  final ManualPauseTracker _manualPause = ManualPauseTracker();
  bool _mediaPublished = false;
  bool _capsuleVisible = false;
  int _lastMediaStateAtMs = 0;

  /// 当前有没有在播的听书曲目（小说区永远为假，三件只对听书生效）。
  bool get _audioActive =>
      widget.source.section == ContentSection.audio &&
      _detail != null &&
      _playingIndex >= 0 &&
      _playingIndex < _detail!.chapters.length;

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
    WidgetsBinding.instance.addObserver(this);
    AudioMediaSession.setActionHandler(_onMediaAction);
    unawaited(_loadShelved());
    unawaited(_loadAudioState());
    _subs.addAll([
      _player.stream.position.listen((value) {
        if (mounted) setState(() => _position = value);
        unawaited(_saveResumeThrottled());
        _publishMediaStateThrottled();
      }),
      _player.stream.duration.listen((value) {
        if (mounted) setState(() => _duration = value);
        _applyPendingSeek();
      }),
      _player.stream.playing.listen((value) {
        if (mounted) setState(() => _playing = value);
        unawaited(_syncBackgroundOutputs());
      }),
      _player.stream.completed.listen((completed) {
        if (completed == true) {
          unawaited(_saveResumeNow());
          _next(auto: true);
        }
      }),
      _player.stream.error.listen((_) {
        if (!mounted || _trackError.isNotEmpty) return;
        if (!_autoRetried) {
          _autoRetried = true;
          unawaited(_playChapter(_playingIndex));
        } else {
          setState(() => _trackError = '音频播放出错');
        }
      }),
    ]);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AudioMediaSession.setActionHandler(null);
    unawaited(_releaseBackgroundOutputs());
    unawaited(_saveResumeNow());
    for (final sub in _subs) {
      sub.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (!_audioActive) return;
    if (state == AppLifecycleState.resumed) {
      // 回前台只同步状态，永不自动播放：播着的本来就没停，
      // 手动暂停过的不替用户恢复（见 shouldAutoPlayOnResume）。
      try {
        final current = _player.state;
        if (mounted) {
          setState(() {
            _playing = current.playing;
            _position = current.position;
            _duration = current.duration;
          });
        }
      } catch (_) {}
      unawaited(_syncBackgroundOutputs());
    } else if (isAudioBackgroundState(state)) {
      // 切后台不暂停播放：前台服务保活，播放器继续播。
      unawaited(_saveResumeNow());
      unawaited(_syncBackgroundOutputs());
    } else if (state == AppLifecycleState.detached) {
      unawaited(_saveResumeNow());
      unawaited(_releaseBackgroundOutputs());
    }
  }

  /// 锁屏按键回落：锁屏上点的暂停同样算手动暂停，点播放算用户意图播放。
  void _onMediaAction(String action) {
    if (!mounted || !_audioActive) return;
    switch (action) {
      case 'play':
        if (!_playing && !_trackLoading) {
          _manualPause.userPlayed();
          unawaited(_player.play());
        }
      case 'pause':
        if (_playing) {
          _manualPause.userPaused();
          unawaited(_player.pause());
        }
      case 'previous':
        if (_playingIndex > 0) _prev();
      case 'next':
        _next();
    }
  }

  AudioLockscreenInfo _lockscreenInfo() {
    final detail = _detail!;
    return AudioLockscreenInfo(
      bookTitle: detail.book.title,
      chapterTitle: detail.chapters[_playingIndex].title,
      coverUrl: detail.book.cover,
      playing: _playing,
      positionMs: _position.inMilliseconds,
      durationMs: _duration.inMilliseconds,
      hasPrevious: _playingIndex > 0,
      hasNext: _playingIndex + 1 < detail.chapters.length,
      rate: _rate,
    );
  }

  /// 三路输出同步：前台服务保活 + 锁屏界面 + 胶囊显隐。
  /// 暂停时也发布锁屏界面（显示播放按钮）；胶囊只在后台且在播时出现。
  Future<void> _syncBackgroundOutputs() async {
    if (!_audioActive) return;
    final info = _lockscreenInfo();
    if (_playing) {
      unawaited(PlaybackForeground.acquire(widget.book.title));
    } else {
      unawaited(PlaybackForeground.release());
    }
    _mediaPublished = await AudioMediaSession.publish(info);
    unawaited(_refreshCapsule());
  }

  /// 锁屏进度刷新：播着时每 5 秒推一次播放态，避免每帧都过通道。
  void _publishMediaStateThrottled() {
    if (!_audioActive || !_playing || !_mediaPublished) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastMediaStateAtMs < 5000) return;
    _lastMediaStateAtMs = now;
    unawaited(
      AudioMediaSession.updateState(
        playing: true,
        positionMs: _position.inMilliseconds,
        durationMs: _duration.inMilliseconds,
        rate: _rate,
      ),
    );
  }

  /// 胶囊显隐：后台 + 在播 + 悬浮窗权限，三件齐了才显示；
  /// 任一不满足就藏起，只留通知栏控制，不反复要权限。
  Future<void> _refreshCapsule() async {
    final backgrounded = isAudioBackgroundState(_lifecycleState);
    final want = _audioActive && _playing && backgrounded;
    if (want) {
      final granted = await AudioCapsule.isPermissionGranted();
      if (!mounted) return;
      if (granted &&
          isAudioBackgroundState(_lifecycleState) &&
          _playing &&
          _audioActive) {
        final detail = _detail!;
        final ready = await AudioCapsule.ensureService();
        if (!mounted) return;
        if (ready) {
          final shown = await AudioCapsule.show(
            title: detail.book.title,
            chapter: detail.chapters[_playingIndex].title,
            playing: true,
          );
          _capsuleVisible = shown;
          return;
        }
      }
    }
    if (_capsuleVisible) {
      _capsuleVisible = false;
      await AudioCapsule.hide();
    }
  }

  /// 撤掉三路输出：前台服务标记、锁屏界面、胶囊服务。
  Future<void> _releaseBackgroundOutputs() async {
    _mediaPublished = false;
    _capsuleVisible = false;
    unawaited(PlaybackForeground.release());
    await AudioMediaSession.release();
    await AudioCapsule.stop();
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

  AudioListenRecord _recordFor(int chapterIndex, int positionMs) {
    final detail = _detail;
    final chapter =
        detail != null &&
            chapterIndex >= 0 &&
            chapterIndex < detail.chapters.length
        ? detail.chapters[chapterIndex]
        : null;
    return AudioListenRecord(
      sourceId: widget.source.id,
      sourceName: widget.source.name,
      bookId: widget.book.id,
      title: widget.book.title,
      cover: widget.book.cover,
      author: widget.book.author,
      chapterIndex: chapterIndex,
      chapterTitle: chapter?.title ?? '',
      positionMs: positionMs,
      durationMs: _duration.inMilliseconds,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _saveChapterStart(int index) async {
    if (widget.source.section != ContentSection.audio) return;
    try {
      final record = _recordFor(index, 0);
      await saveAudioResume(record);
      await recordAudioHistory(record);
      if (mounted) setState(() => _resume = record);
    } catch (_) {}
  }

  Future<void> _saveResumeNow() async {
    if (widget.source.section != ContentSection.audio) return;
    if (_playingIndex < 0 || _position.inMilliseconds <= 0) return;
    try {
      final record = _recordFor(_playingIndex, _position.inMilliseconds);
      await saveAudioResume(record);
      await recordAudioHistory(record);
      if (mounted) setState(() => _resume = record);
    } catch (_) {}
  }

  Future<void> _saveResumeThrottled() async {
    if (widget.source.section != ContentSection.audio) return;
    if (_playingIndex < 0 || !_playing) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final positionMs = _position.inMilliseconds;
    if (positionMs <= 0) return;
    if (now - _lastSavedAtMs < 5000 &&
        (positionMs - _lastSavedPositionMs).abs() < 5000) {
      return;
    }
    _lastSavedAtMs = now;
    _lastSavedPositionMs = positionMs;
    try {
      final record = _recordFor(_playingIndex, positionMs);
      await saveAudioResume(record);
      if (mounted) setState(() => _resume = record);
    } catch (_) {}
  }

  void _applyPendingSeek() {
    final pending = _pendingSeek;
    if (pending == null) return;
    if (pending.chapter != _playingIndex) return;
    if (_duration.inMilliseconds <= 0) return;
    final target = pending.ms.clamp(0, _duration.inMilliseconds);
    _pendingSeek = null;
    unawaited(_player.seek(Duration(milliseconds: target)));
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
    _pendingSeek = seekMs > 0 ? (chapter: index, ms: seekMs) : null;
    setState(() {
      _playingIndex = index;
      _trackLoading = true;
      _trackError = '';
      _autoRetried = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      final track = await widget.source.audioTrack(
        detail.book.id,
        detail.chapters[index],
      );
      if (!mounted) return;
      await _player.open(Media(track.url));
      await _player.setRate(_rate);
      await _player.play();
      _manualPause.userPlayed();
      if (mounted) {
        setState(() => _trackLoading = false);
        unawaited(_saveChapterStart(index));
        unawaited(_syncBackgroundOutputs());
      }
    } on AppFailure catch (e) {
      _pendingSeek = null;
      if (mounted) {
        setState(() {
          _trackLoading = false;
          _trackError = e.message;
        });
      }
    } catch (_) {
      _pendingSeek = null;
      if (mounted) {
        setState(() {
          _trackLoading = false;
          _trackError = '音频加载失败';
        });
      }
    }
  }

  void _next({bool auto = false}) {
    final detail = _detail;
    if (detail == null) return;
    if (_playingIndex + 1 >= detail.chapters.length) return;
    _playChapter(_playingIndex + 1);
  }

  void _prev() {
    if (_playingIndex - 1 < 0) return;
    _playChapter(_playingIndex - 1);
  }

  Future<void> _toggle() async {
    if (_trackLoading || _playingIndex < 0) return;
    if (_playing) {
      _manualPause.userPaused();
      await _player.pause();
    } else {
      _manualPause.userPlayed();
      await _player.play();
    }
  }

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    await _player.setRate(rate);
  }

  Future<void> _stop() async {
    _pendingSeek = null;
    _manualPause.stopped();
    await _saveResumeNow();
    await _player.stop();
    if (mounted) {
      setState(() {
        _playingIndex = -1;
        _position = Duration.zero;
        _duration = Duration.zero;
        _playing = false;
        _trackLoading = false;
        _trackError = '';
      });
    }
    await _releaseBackgroundOutputs();
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
                      _pendingSeek = null;
                      _player.seek(Duration(milliseconds: value.toInt()));
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
