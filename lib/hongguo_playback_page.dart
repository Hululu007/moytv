import 'dart:async';

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'core_bridge.dart';
import 'hongguo_comment.dart';
import 'hongguo_danmaku.dart';
import 'hongguo_preload.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_foreground.dart';
import 'playback_preferences.dart';
import 'tvbox_player_bridge.dart';
import 'watchroom/player.dart';
import 'widgets.dart';

class HongguoPlaybackPage extends StatefulWidget {
  const HongguoPlaybackPage({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    this.detail,
    this.initialEpisode = 0,
    this.startPosition = 0,
  });

  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final DramaDetail? detail;
  final int initialEpisode;
  final double startPosition;

  @override
  State<HongguoPlaybackPage> createState() => _HongguoPlaybackPageState();
}

String _formatSpeed(double value) =>
    value == value.roundToDouble() ? '${value.toInt()}.0' : '$value';

class _HongguoPlaybackPageState extends State<HongguoPlaybackPage> {
  final RoomPlayerHandle _player = RoomPlayerHandle();
  late final HongguoPreloadWindow _preloadWindow = HongguoPreloadWindow(
    widget.repository,
    detailOf: (drama) async {
      if (drama.id == widget.drama.id) return _detail;
      try {
        return await widget.repository.detail(drama);
      } catch (_) {
        return null;
      }
    },
  );
  DramaDetail? _detail;
  late int _episode;
  bool _detailLoading = false;
  String? _detailError;
  int _playToken = 0;
  bool _opening = false;
  bool _pendingPlay = false;
  bool _usedStartPosition = false;
  bool _synopsisExpanded = false;
  bool _fullscreen = false;
  bool _playbackServiceHeld = false;
  String? _commentDramaId;
  HongguoCommentPage? _commentPage;

  @override
  void initState() {
    super.initState();
    _detail = widget.detail;
    _episode = widget.initialEpisode;
    unawaited(_playCurrent());
  }

  @override
  void dispose() {
    _playToken++;
    _player.dispose();
    _preloadWindow.dispose();
    if (_playbackServiceHeld) {
      _playbackServiceHeld = false;
      unawaited(PlaybackForeground.release());
    }
    super.dispose();
  }

  Future<void> _loadCommentCounts(PlaybackPlan plan) async {
    final seriesId = hongguoNumericId(widget.drama.id);
    if (plan.session.isEmpty && seriesId == null) return;
    try {
      final page = plan.session.isEmpty
          ? await widget.repository.commentsBySeries(seriesId!)
          : await widget.repository.comments(plan);
      if (!mounted || _commentDramaId != widget.drama.id) return;
      setState(() => _commentPage = page);
    } catch (_) {}
  }

  Future<void> _openComments() async {
    final plan = _player.plan;
    if (plan == null) {
      _note('本集暂不支持评论');
      return;
    }
    final seriesId = hongguoNumericId(widget.drama.id);
    if (plan.session.isEmpty && seriesId == null) {
      _note('本集暂不支持评论');
      return;
    }
    await showHongguoComments(
      context,
      plan,
      widget.repository,
      initialPage: _commentPage,
      seriesId: plan.session.isEmpty ? seriesId : null,
    );
  }

  Future<void> _playCurrent() async {
    if (!mounted) return;
    if (_opening) {
      _pendingPlay = true;
      return;
    }
    final token = ++_playToken;
    _opening = true;
    try {
      var detail = _detail;
      if (detail == null) {
        setState(() {
          _detailLoading = true;
          _detailError = null;
        });
        try {
          detail = await widget.repository.detail(widget.drama);
        } catch (error) {
          if (!mounted || token != _playToken) return;
          setState(() {
            _detailLoading = false;
            _detailError = error.toString();
          });
          return;
        }
        if (!mounted || token != _playToken) return;
        _detail = detail;
        setState(() => _detailLoading = false);
      }
      if (detail.episodes.isEmpty) {
        if (!mounted || token != _playToken) return;
        setState(() => _detailError = '暂无可播剧集');
        return;
      }
      final episodeIndex = _episode.clamp(0, detail.episodes.length - 1);
      if (episodeIndex != _episode) {
        setState(() => _episode = episodeIndex);
      }
      var start = 0.0;
      if (!_usedStartPosition && _episode == widget.initialEpisode) {
        start = widget.startPosition;
        _usedStartPosition = true;
      }
      if (!mounted || token != _playToken) return;
      final preloaded = _preloadWindow.take(
        widget.drama,
        detail.episodes[episodeIndex],
      );
      await _player.open(
        detail: detail,
        episodeIndex: episodeIndex,
        startPosition: start,
        repository: widget.repository,
        store: widget.store,
        preloadedPlan: preloaded,
      );
      if (!mounted || token != _playToken) return;
      final plan = _player.plan;
      if (plan != null) {
        if (!_playbackServiceHeld) {
          _playbackServiceHeld = true;
          unawaited(PlaybackForeground.acquire(widget.drama.title));
        }
        if (_commentDramaId != widget.drama.id) {
          _commentDramaId = widget.drama.id;
          unawaited(_loadCommentCounts(plan));
        }
      }
      _preloadWindow.recenter(
        drama: widget.drama,
        episodes: detail.episodes,
        episodeIndex: episodeIndex,
        upcoming: detail.related,
      );
      if (mounted) setState(() {});
    } finally {
      _opening = false;
      if (_pendingPlay) {
        _pendingPlay = false;
        if (mounted) unawaited(_playCurrent());
      }
    }
  }

  void _playEpisode(int index) {
    setState(() {
      _episode = index;
      _synopsisExpanded = false;
    });
    unawaited(_playCurrent());
  }

  void _onCompleted() {
    final detail = _detail;
    if (detail == null || detail.episodes.isEmpty) return;
    if (_episode + 1 < detail.episodes.length) {
      _playEpisode(_episode + 1);
    } else {
      _openEpisodeSheet(initialTab: 1);
    }
  }

  Future<void> _togglePlay() async {
    if (!_player.hasVideo) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> _toggleFavorite() async {
    await widget.store.toggleFavorite(widget.drama);
    if (mounted) setState(() {});
  }

  Future<void> _toggleDanmaku() async {
    final prefs = widget.store.playbackPreferences;
    await widget.store.setPlaybackPreferences(
      prefs.copyWith(danmaku: !prefs.danmaku),
    );
    if (mounted) setState(() {});
  }

  void _note(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _releaseStatusLabel() {
    return switch (widget.drama.releaseStatus) {
      'finished' || 'completed' => '已完结',
      'ongoing' => '连载中',
      _ => '',
    };
  }

  Future<void> _openEpisodeSheet({required int initialTab}) async {
    final detail = _detail;
    if (detail == null) {
      if (!_detailLoading) unawaited(_playCurrent());
      return;
    }
    if (detail.episodes.isEmpty) {
      _note('暂无可播剧集');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _EpisodeSheet(
        detail: detail,
        drama: widget.drama,
        repository: widget.repository,
        store: widget.store,
        currentEpisode: _episode,
        initialTab: initialTab,
        onSelect: (index) {
          Navigator.of(context).pop();
          _playEpisode(index);
        },
        onToggleFavorite: () => unawaited(_toggleFavorite()),
        onOpenRelated: (drama) {
          Navigator.of(context).pop();
          unawaited(
            Navigator.of(this.context).push<void>(
              appPageRoute<void>(
                builder: (_) => HongguoPlaybackPage(
                  drama: drama,
                  repository: widget.repository,
                  store: widget.store,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openSpeedSheet() async {
    final prefs = widget.store.playbackPreferences;
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '倍速',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Wrap(
                spacing: 8,
                children: playbackSpeeds
                    .map(
                      (value) => ChoiceChip(
                        label: Text('${_formatSpeed(value)}x'),
                        selected: value == prefs.speed,
                        onSelected: (_) =>
                            Navigator.of(context).pop(value),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await widget.store.setPlaybackPreferences(
      prefs.copyWith(speed: selected),
    );
    try {
      await _player.videoController?.player.setRate(selected);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _openMoreSheet() async {
    final favorite = widget.store.isFavorite(widget.drama.id);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                favorite ? Icons.star_rounded : Icons.star_outline_rounded,
              ),
              title: Text(favorite ? '取消收藏' : '收藏'),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(_toggleFavorite());
              },
            ),
            ListTile(
              leading: const Icon(Icons.grid_view_rounded),
              title: const Text('选集'),
              onTap: () {
                Navigator.of(context).pop();
                Future.microtask(() {
                  if (mounted) _openEpisodeSheet(initialTab: 1);
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.comment_rounded),
              title: Text(
                widget.store.playbackPreferences.danmaku
                    ? '关闭弹幕'
                    : '开启弹幕',
              ),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(_toggleDanmaku());
              },
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('关闭'),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _videoArea(),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.6),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: _topBar(),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.42,
              child: _videoArea(),
            ),
            Expanded(child: _infoArea()),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final prefs = widget.store.playbackPreferences;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          tooltip: '返回',
          onPressed: () {
            if (_fullscreen) {
              setState(() => _fullscreen = false);
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
        Text(
          '第${_episode + 1}集',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: _openSpeedSheet,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.timer_outlined,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 4),
                Text(
                  '${_formatSpeed(prefs.speed)}x',
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
          tooltip: '更多',
          onPressed: _openMoreSheet,
        ),
      ],
    );
  }

  Widget _videoArea() {
    return GestureDetector(
      onTap: _togglePlay,
      child: ListenableBuilder(
        listenable: _player,
        builder: (context, _) {
          final keyMatches =
              _player.videoKey == '${widget.drama.id}|$_episode';
          if (_player.loading ||
              _player.error != null ||
              (keyMatches && _player.hasVideo)) {
            return Stack(
              fit: StackFit.expand,
              children: [
                RoomPlayerView(
                  handle: _player,
                  viewType: TvboxPlayerController.viewType,
                  onCompleted: _onCompleted,
                  onError: (_) {},
                  onRetry: () => unawaited(_playCurrent()),
                  onFullscreen: _fullscreen
                      ? () => setState(() => _fullscreen = false)
                      : null,
                  isFullscreen: _fullscreen,
                ),
                HongguoDanmakuLayer(
                  handle: _player,
                  repository: widget.repository,
                  store: widget.store,
                  available: keyMatches && _player.hasVideo,
                  aspectRatio: hongguoVideoAspect(_player),
                  seriesId: hongguoNumericId(widget.drama.id),
                  videoId: _detail != null &&
                          _episode >= 0 &&
                          _episode < _detail!.episodes.length
                      ? hongguoNumericId(_detail!.episodes[_episode].id)
                      : null,
                ),
              ],
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              DramaCover(
                drama: widget.drama,
                repository: widget.repository,
              ),
              if (_detailLoading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              if (_detailError != null)
                Center(
                  child: StatusPanel(
                    title: '加载失败',
                    message: _detailError!,
                    onRetry: () => unawaited(_playCurrent()),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _infoArea() {
    final detail = _detail;
    final episodes = detail?.episodes ?? const <Episode>[];
    final episodeTitle =
        detail != null && _episode < episodes.length
            ? episodes[_episode].title
            : null;
    final episodeLine = episodeTitle == null
        ? '第${_episode + 1}集'
        : episodeTitle == '第${_episode + 1}集'
        ? episodeTitle
        : '第${_episode + 1}集 | $episodeTitle';
    final synopsis = detail?.drama.description ?? widget.drama.description;
    final status = _releaseStatusLabel();
    return Container(
      color: const Color(0xFF1A1A1A),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: GestureDetector(
                onTap: () => setState(() => _fullscreen = true),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fullscreen_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '全屏观看',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_episode != 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GestureDetector(
                            onTap: () => _playEpisode(0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                  Text(
                                    '从第1集开始看',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      GestureDetector(
                        onTap: () => _openEpisodeSheet(initialTab: 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.drama.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const Text(
                              ' >',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        episodeLine,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      if (synopsis.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  synopsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                  ),
                                  maxLines: _synopsisExpanded ? null : 2,
                                  overflow: _synopsisExpanded
                                      ? TextOverflow.visible
                                      : TextOverflow.ellipsis,
                                ),
                              ),
                              if (synopsis.length > 80)
                                GestureDetector(
                                  onTap: () => setState(
                                    () => _synopsisExpanded =
                                        !_synopsisExpanded,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: Text(
                                      _synopsisExpanded ? '收起' : '展开',
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 12),
                      _progressBar(),
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: () => _openEpisodeSheet(initialTab: 1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Text(
                                status.isEmpty
                                    ? '选集 · 全${episodes.length}集'
                                    : '选集 · $status · 全${episodes.length}集',
                                style: const TextStyle(color: Colors.white),
                              ),
                              const Spacer(),
                              const Icon(
                                Icons.keyboard_arrow_up_rounded,
                                color: Colors.white,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  children: [
                    _action(
                      icon: widget.store.isFavorite(widget.drama.id)
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      label: '收藏',
                      count: _commentPage != null &&
                              _commentPage!.collectorsCount > 0
                          ? '${_commentPage!.collectorsCount}'
                          : null,
                      onTap: () => unawaited(_toggleFavorite()),
                    ),
                    const SizedBox(height: 20),
                    _action(
                      icon: Icons.chat_bubble_outline_rounded,
                      label: '评论',
                      count: _commentPage != null && _commentPage!.total > 0
                          ? '${_commentPage!.total}'
                          : null,
                      onTap: () => unawaited(_openComments()),
                    ),
                    const SizedBox(height: 20),
                    _action(
                      icon: Icons.favorite_outline_rounded,
                      label: '点赞',
                      onTap: () => _note('该剧暂无点赞数据'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    String? count,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 30),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
          if (count != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                count,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _progressBar() {
    return ListenableBuilder(
      listenable: _player,
      builder: (context, _) {
        final duration = _player.duration;
        return StreamBuilder<double>(
          stream: _player.positionStream,
          initialData: _player.position,
          builder: (context, snapshot) {
            final position = snapshot.data ?? _player.position;
            final fraction = duration > 0
                ? (position / duration).clamp(0.0, 1.0)
                : 0.0;
            return LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final fill = width * fraction;
                return SizedBox(
                  height: 12,
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 3,
                          width: width,
                          color: Colors.white24,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 3,
                          width: fill,
                          color: Colors.white,
                        ),
                      ),
                      Positioned(
                        left: (fill - 5).clamp(0.0, width - 10),
                        top: 1,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _EpisodeSheet extends StatefulWidget {
  const _EpisodeSheet({
    required this.detail,
    required this.drama,
    required this.repository,
    required this.store,
    required this.currentEpisode,
    required this.onSelect,
    required this.onToggleFavorite,
    required this.onOpenRelated,
    this.initialTab = 1,
  });

  final DramaDetail detail;
  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final int currentEpisode;
  final ValueChanged<int> onSelect;
  final VoidCallback onToggleFavorite;
  final ValueChanged<Drama> onOpenRelated;
  final int initialTab;

  @override
  State<_EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<_EpisodeSheet> {
  late int _tab = widget.initialTab;
  late int _range = widget.currentEpisode ~/ 30;
  late bool _favorite = widget.store.isFavorite(widget.drama.id);

  List<String> get _ranges {
    final count = widget.detail.episodes.length;
    final ranges = <String>[];
    for (var start = 0; start < count; start += 30) {
      final end = (start + 30).clamp(0, count);
      ranges.add('${start + 1}-$end');
    }
    return ranges;
  }

  String get _seasonLine {
    final season = widget.drama.tags.firstWhere(
      (tag) => RegExp(r'第\d+季').hasMatch(tag),
      orElse: () => '',
    );
    final parts = [
      if (season.isNotEmpty) season,
      '全${widget.detail.episodes.length}集',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 64,
                    height: 88,
                    child: DramaCover(
                      drama: widget.drama,
                      repository: widget.repository,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => setState(() => _tab = 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.drama.title,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Text(' >'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _seasonLine,
                        style: const TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const SizedBox(width: 16),
              _sheetTab(0, '简介'),
              const SizedBox(width: 24),
              _sheetTab(1, '选集'),
              const SizedBox(width: 24),
              _sheetTab(2, '系列剧'),
            ],
          ),
          Container(height: 1, color: Colors.black12),
          Expanded(child: _tabBody()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  widget.onToggleFavorite();
                  setState(() => _favorite = !_favorite);
                },
                icon: Icon(
                  _favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                ),
                label: Text(_favorite ? '已收藏' : '收藏'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF7A00),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sheetTab(int index, String label) {
    final selected = _tab == index;
    return GestureDetector(
      onTap: () => setState(() => _tab = index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? Colors.black : Colors.black54,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 20,
            height: 3,
            decoration: BoxDecoration(
              color: selected ? Colors.black : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabBody() {
    if (_tab == 0) {
      final description = widget.detail.drama.description;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          description.isEmpty ? '暂无简介' : description,
          style: const TextStyle(height: 1.6),
        ),
      );
    }
    if (_tab == 2) {
      final related = widget.detail.related;
      if (related.isEmpty) {
        return const Center(child: Text('暂无系列剧数据'));
      }
      return ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: related.length,
        itemBuilder: (context, index) {
          final drama = related[index];
          return GestureDetector(
            onTap: () {
              Navigator.of(context).pop();
              widget.onOpenRelated(drama);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 48,
                      height: 64,
                      child: DramaCover(
                        drama: drama,
                        repository: widget.repository,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      drama.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.black38,
                  ),
                ],
              ),
            ),
          );
        },
      );
    }
    final ranges = _ranges;
    final range = _range.clamp(0, ranges.length - 1);
    final start = range * 30;
    final end = (start + 30).clamp(0, widget.detail.episodes.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (var i = 0; i < ranges.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _range = i),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 24, top: 12),
                    child: Text(
                      ranges[i],
                      style: TextStyle(
                        fontWeight:
                            i == range ? FontWeight.bold : FontWeight.normal,
                        color: i == range ? Colors.black : Colors.black45,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.1,
            ),
            itemCount: end - start,
            itemBuilder: (context, offset) {
              final index = start + offset;
              final selected = index == widget.currentEpisode;
              return GestureDetector(
                onTap: () => widget.onSelect(index),
                child: Stack(
                  children: [
                    Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFFFFEDE3)
                            : const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          color: selected
                              ? const Color(0xFFFF7A00)
                              : Colors.black87,
                          fontWeight:
                              selected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (selected)
                      const Positioned(
                        top: 4,
                        right: 6,
                        child: Icon(
                          Icons.bar_chart_rounded,
                          size: 12,
                          color: Color(0xFFFF7A00),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
