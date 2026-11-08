import 'dart:async';

import 'app_page_route.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'feed_diagonal_drag.dart';
import 'hongguo_comment.dart';
import 'hongguo_danmaku.dart';
import 'local_store.dart';
import 'models.dart';
import 'network_speed.dart';
import 'playback_foreground.dart';
import 'playback_preferences.dart';
import 'player_picker.dart';
import 'tvbox_player_bridge.dart';
import 'video_enhancement_preferences.dart';
import 'watchroom/player.dart';
import 'widgets.dart';

String feedResumeKey(Drama drama) => '${drama.source}|${drama.id}';

List<Drama> feedPlayableDramas(List<Drama> items) =>
    items.where((drama) => drama.kind == 'video').toList();

int clampFeedEpisodeIndex(int index, int count) {
  if (count <= 0) return 0;
  if (index < 0) return 0;
  if (index >= count) return count - 1;
  return index;
}

String feedEpisodeBarLabel(String releaseStatus, int total) {
  final status = switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '',
  };
  if (status.isEmpty) return '选集 · 全$total集';
  return '选集 · $status · 全$total集';
}

List<({int start, int end})> feedEpisodeSegments(int total, [int size = 100]) {
  if (total <= 0 || size <= 0) return const [];
  final segments = <({int start, int end})>[];
  var start = 1;
  while (start <= total) {
    final end = (start + size - 1).clamp(1, total);
    segments.add((start: start, end: end));
    start = end + 1;
  }
  return segments;
}

enum FeedCompletionAction { nextEpisode, nextVideo, stop }

FeedCompletionAction feedCompletionAction({
  required int episode,
  required int? episodeCount,
  required int videoIndex,
  required int videoCount,
}) {
  if (episodeCount != null && episode < episodeCount - 1) {
    return FeedCompletionAction.nextEpisode;
  }
  if (videoIndex < videoCount - 1) return FeedCompletionAction.nextVideo;
  return FeedCompletionAction.stop;
}

const feedMoreSpeeds = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

List<({String key, bool enabled})> feedLandscapeActions({
  required bool hasPrevious,
  required bool hasNext,
}) => [
  (key: 'previous', enabled: hasPrevious),
  (key: 'playPause', enabled: true),
  (key: 'episodes', enabled: true),
  (key: 'next', enabled: hasNext),
  (key: 'more', enabled: true),
  (key: 'exitFullscreen', enabled: true),
];

class FullscreenFeedScreen extends StatefulWidget {
  const FullscreenFeedScreen({
    super.key,
    required this.dramas,
    required this.repository,
    required this.store,
    this.onMenuPressed,
    this.categories = const [],
    this.selectedCategory = '',
    this.onCategorySelected,
  });

  final List<Drama> dramas;
  final AppRepository repository;
  final LocalStore store;
  final VoidCallback? onMenuPressed;
  final List<CatalogCategory> categories;
  final String selectedCategory;
  final ValueChanged<String>? onCategorySelected;

  @override
  State<FullscreenFeedScreen> createState() => _FullscreenFeedScreenState();
}

class _FullscreenFeedScreenState extends State<FullscreenFeedScreen>
    with WidgetsBindingObserver {
  late List<Drama> _items = feedPlayableDramas(widget.dramas);
  late final PageController _pages = PageController();
  final RoomPlayerHandle _player = RoomPlayerHandle();
  late final NetworkSpeedTracker _speedTracker;
  StreamSubscription<double>? _positionSubscription;
  final Map<String, DramaDetail> _details = {};
  final Map<String, int> _episodeByKey = {};
  final Map<String, double> _positionByKey = {};
  int _index = 0;
  int _episode = 0;
  bool _detailLoading = false;
  String? _detailError;
  int _playToken = 0;
  bool _opening = false;
  bool _pendingPlay = false;
  bool _clearScreen = false;
  bool _overlayVisible = true;
  Timer? _hideTimer;
  bool _lastPlaying = false;
  bool _playbackServiceHeld = false;
  bool _backgrounded = false;
  bool _landscape = false;
  bool _sheetOpen = false;
  Drag? _diagonalDrag;
  bool _descriptionExpanded = false;
  String? _commentDramaId;
  HongguoCommentPage? _commentPage;

  @override
  void initState() {
    super.initState();
    _speedTracker = NetworkSpeedTracker(
      sample: () async {
        final player = _player.videoController?.player;
        if (player == null) return null;
        return fetchMpvNetworkSpeedSample(player);
      },
    );
    _positionSubscription = _player.positionStream.listen((_) {
      unawaited(_speedTracker.tick());
    });
    _player.addListener(_onPlayerChanged);
    WidgetsBinding.instance.addObserver(this);
    _lastPlaying = _player.playing;
    if (_items.isNotEmpty) {
      unawaited(_playCurrent());
      _prefetch(1);
    }
  }

  @override
  void didUpdateWidget(FullscreenFeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = feedPlayableDramas(widget.dramas);
    final nextKeys = [for (final drama in next) _keyFor(drama)].join('|');
    final currentKeys = [for (final drama in _items) _keyFor(drama)].join('|');
    if (nextKeys == currentKeys) return;
    _savePosition();
    _playToken++;
    setState(() {
      _items = next;
      _index = 0;
      _episode = 0;
      _detailError = null;
    });
    if (next.isEmpty) return;
    if (_pages.hasClients && (_pages.page ?? 0) != 0) {
      _pages.jumpToPage(0);
    } else {
      unawaited(_playCurrent());
      _prefetch(1);
    }
  }

  @override
  void dispose() {
    _playToken++;
    _hideTimer?.cancel();
    _player.removeListener(_onPlayerChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (_playbackServiceHeld) {
      _playbackServiceHeld = false;
      unawaited(PlaybackForeground.release());
    }
    _positionSubscription?.cancel();
    _speedTracker.dispose();
    _pages.dispose();
    _player.dispose();
    if (_landscape) {
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
    }
    super.dispose();
  }

  void _enterLandscape() {
    if (_landscape) return;
    setState(() => _landscape = true);
    _showOverlay();
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
  }

  void _exitLandscape() {
    if (!_landscape) return;
    setState(() => _landscape = false);
    _showOverlay();
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
  }

  void _exitClearScreen() {
    if (!_clearScreen) return;
    setState(() => _clearScreen = false);
    _showOverlay();
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    final playing = _player.playing;
    if (playing == _lastPlaying) return;
    _lastPlaying = playing;
    if (playing) {
      _scheduleHide();
    } else {
      _showOverlay();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!feedOverlayCanHide(
      overlayVisible: _overlayVisible,
      clearScreen: _clearScreen,
      sheetOpen: _sheetOpen,
      playing: _player.playing,
    )) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 4), () {
      _hideTimer = null;
      if (mounted &&
          feedOverlayCanHide(
            overlayVisible: _overlayVisible,
            clearScreen: _clearScreen,
            sheetOpen: _sheetOpen,
            playing: _player.playing,
          )) {
        setState(() => _overlayVisible = false);
      }
    });
  }

  void _showOverlay() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_overlayVisible && mounted) setState(() => _overlayVisible = true);
    _scheduleHide();
  }

  void _handleVideoTap() {
    if (_clearScreen) {
      _exitClearScreen();
      return;
    }
    if (!_overlayVisible) {
      _showOverlay();
      return;
    }
    _togglePlay();
    _scheduleHide();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgrounded = true;
      if (!_playbackServiceHeld &&
          shouldAcquirePlaybackService(
            playing: _player.playing,
            useTvbox: _player.useTvbox,
          )) {
        _playbackServiceHeld = true;
        unawaited(PlaybackForeground.acquire(_feedTitle()));
      }
    } else if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
    }
  }

  String _feedTitle() {
    if (_items.isEmpty) return '';
    return _items[_index].title;
  }

  Future<void> _openMoreSheet() async {
    var prefs = widget.store.playbackPreferences;
    setState(() => _sheetOpen = true);
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> save(PlaybackPreferences next) async {
            await saveUserChange(
              sheetContext,
              () => widget.store.setPlaybackPreferences(next),
            );
            prefs = widget.store.playbackPreferences;
            setSheetState(() {});
          }

          Future<void> pickDefaultSpeed() async {
            final selected = await showDialog<double>(
              context: sheetContext,
              builder: (dialogContext) => SimpleDialog(
                title: const Text('设置默认倍速'),
                children: [
                  for (final value in playbackSpeeds)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(dialogContext, value),
                      child: Row(
                        children: [
                          Text('${speedLabel(value)}x'),
                          const Spacer(),
                          if (prefs.speed == value)
                            const Icon(Icons.check_rounded, size: 16),
                        ],
                      ),
                    ),
                ],
              ),
            );
            if (selected != null) {
              await save(prefs.copyWith(speed: selected));
            }
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: .4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '更多',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const Divider(),
                  const ListTile(title: Text('当前倍速')),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final value in feedMoreSpeeds)
                          ChoiceChip(
                            label: Text('${speedLabel(value)}x'),
                            selected: prefs.speed == value,
                            onSelected: (selected) {
                              if (selected) {
                                unawaited(save(prefs.copyWith(speed: value)));
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.speed_rounded),
                    title: const Text('设置默认倍速'),
                    subtitle: Text('当前默认 ${speedLabel(prefs.speed)}x'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => unawaited(pickDefaultSpeed()),
                  ),
                  const Divider(),
                  const ListTile(title: Text('画质增强')),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final mode in VideoEnhancementMode.values)
                          ChoiceChip(
                            label: Text(mode.label),
                            selected: prefs.enhancement.mode == mode,
                            onSelected: (selected) {
                              if (selected) {
                                unawaited(
                                  save(
                                    prefs.copyWith(
                                      enhancement: prefs.enhancement.copyWith(
                                        mode: mode,
                                      ),
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                  const Divider(),
                  SwitchListTile(
                    title: const Text('弹幕'),
                    value: prefs.danmaku,
                    onChanged: (value) =>
                        unawaited(save(prefs.copyWith(danmaku: value))),
                  ),
                  SwitchListTile(
                    title: const Text('自动连播'),
                    value: prefs.autoAdvance,
                    onChanged: (value) =>
                        unawaited(save(prefs.copyWith(autoAdvance: value))),
                  ),
                  ListTile(
                    leading: const Icon(Icons.video_settings_outlined),
                    title: const Text('播放器'),
                    subtitle: Text(widget.store.player),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      sheetContext,
                      appPageRoute<void>(
                        builder: (_) => PlayerPickerScreen(store: widget.store),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.crop_free_rounded),
                    title: const Text('清屏播放'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (mounted) setState(() => _clearScreen = true);
                      _hideTimer?.cancel();
                    },
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text('倍速与弹幕偏好保存后供播放器使用，当前流内播放暂不实时切换。'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _sheetOpen = false);
      _scheduleHide();
    });
  }

  Future<void> _openEpisodePanel() async {
    if (_items.isEmpty) return;
    final drama = _items[_index];
    final detail = _details[_keyFor(drama)];
    final total = detail?.episodes.length ?? drama.episodes;
    if (total <= 0) return;
    final segments = feedEpisodeSegments(total);
    var segment = segments.indexWhere(
      (part) => _episode + 1 >= part.start && _episode + 1 <= part.end,
    );
    if (segment < 0) segment = 0;
    final titles = <int, String>{
      for (final episode in detail?.episodes ?? const <Episode>[])
        episode.number: episode.title,
    };
    final status = drama.releaseStatus;
    final statusLabel = status == 'finished' || status == 'completed'
        ? '已完结'
        : status == 'ongoing'
        ? '连载中'
        : '';
    setState(() => _sheetOpen = true);
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final part = segments[segment];
          return DraggableScrollableSheet(
            initialChildSize: 0.72,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            expand: false,
            builder: (sheetContext, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: Theme.of(sheetContext).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        children: [
                          if (drama.cover.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.network(
                                drama.cover,
                                width: 48,
                                height: 64,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox(width: 48, height: 64),
                              ),
                            ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  drama.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  statusLabel.isEmpty
                                      ? '共$total集'
                                      : '$statusLabel · 共$total集',
                                  style: TextStyle(
                                    color: Theme.of(
                                      sheetContext,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    if (segments.length > 1)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            for (var i = 0; i < segments.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(
                                    '${segments[i].start}-${segments[i].end}集',
                                  ),
                                  selected: segment == i,
                                  onSelected: (_) =>
                                      setSheetState(() => segment = i),
                                ),
                              ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListenableBuilder(
                        listenable: _player,
                        builder: (_, _) => GridView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 5,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio: 1.8,
                              ),
                          itemCount: part.end - part.start + 1,
                          itemBuilder: (context, index) {
                            final number = part.start + index;
                            final selected = number - 1 == _episode;
                            final scheme = Theme.of(context).colorScheme;
                            return InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                _jumpToEpisode(number - 1);
                              },
                              child: Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? scheme.primary
                                      : scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  titles[number] ?? '第$number集',
                                  style: TextStyle(
                                    color: selected
                                        ? scheme.onPrimary
                                        : scheme.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _sheetOpen = false);
      _scheduleHide();
    });
  }

  Future<void> _toggleFollow(Drama drama) async {
    await saveUserChange(context, () => widget.store.toggleFavorite(drama));
    if (mounted) setState(() {});
  }

  Future<void> _toggleDanmaku() async {
    final prefs = widget.store.playbackPreferences;
    await saveUserChange(
      context,
      () => widget.store.setPlaybackPreferences(
        prefs.copyWith(danmaku: !prefs.danmaku),
      ),
    );
    if (mounted) setState(() {});
  }

  void _jumpToEpisode(int index) {
    if (_items.isEmpty) return;
    final detail = _details[_keyFor(_items[_index])];
    final count = detail?.episodes.length ?? _items[_index].episodes;
    final next = clampFeedEpisodeIndex(index, count);
    _savePosition();
    _episodeByKey[_keyFor(_items[_index])] = next;
    setState(() => _episode = next);
    _showOverlay();
    unawaited(_playCurrent());
  }

  String _keyFor(Drama drama) => feedResumeKey(drama);

  String _resumeKeyFor(Drama drama, int episode) =>
      '${_keyFor(drama)}|$episode';

  void _savePosition() {
    if (_items.isEmpty || !_player.hasVideo) return;
    final drama = _items[_index];
    _episodeByKey[_keyFor(drama)] = _episode;
    _positionByKey[_resumeKeyFor(drama, _episode)] = _player.position;
  }

  Future<void> _prefetch(int index) async {
    if (index < 0 || index >= _items.length) return;
    final drama = _items[index];
    if (_details.containsKey(_keyFor(drama))) return;
    try {
      final detail = await widget.repository.detail(drama);
      if (!mounted) return;
      _details[_keyFor(drama)] = detail;
    } catch (_) {}
  }

  Future<void> _playCurrent() async {
    if (_items.isEmpty || !mounted) return;
    if (_opening) {
      _pendingPlay = true;
      return;
    }
    final token = ++_playToken;
    _opening = true;
    try {
      final drama = _items[_index];
      var detail = _details[_keyFor(drama)];
      if (detail == null) {
        setState(() {
          _detailLoading = true;
          _detailError = null;
        });
        try {
          detail = await widget.repository.detail(drama);
        } catch (error) {
          if (!mounted || token != _playToken) return;
          setState(() {
            _detailLoading = false;
            _detailError = error.toString();
          });
          return;
        }
        if (!mounted || token != _playToken) return;
        _details[_keyFor(drama)] = detail;
        setState(() => _detailLoading = false);
      }
      if (detail.episodes.isEmpty) {
        if (!mounted || token != _playToken) return;
        setState(() => _detailError = '暂无可播剧集');
        return;
      }
      final episode = clampFeedEpisodeIndex(
        _episodeByKey[_keyFor(drama)] ?? _episode,
        detail.episodes.length,
      );
      final start = _positionByKey[_resumeKeyFor(drama, episode)] ?? 0;
      if (!mounted || token != _playToken) return;
      setState(() => _episode = episode);
      await _player.open(
        detail: detail,
        episodeIndex: episode,
        startPosition: start,
        repository: widget.repository,
        store: widget.store,
      );
      if (mounted) {
        final plan = _player.plan;
        if (plan != null && _commentDramaId != drama.id) {
          _commentDramaId = drama.id;
          _commentPage = null;
          unawaited(_loadCommentCounts(drama.id, plan));
        }
        setState(() {});
      }
    } finally {
      _opening = false;
      if (_pendingPlay) {
        _pendingPlay = false;
        if (mounted) unawaited(_playCurrent());
      }
    }
  }

  void _onPageChanged(int index) {
    _savePosition();
    setState(() {
      _index = index;
      _episode = _episodeByKey[_keyFor(_items[index])] ?? 0;
      _detailError = null;
      _clearScreen = false;
    });
    _showOverlay();
    unawaited(_playCurrent());
    _prefetch(index + 1);
  }

  void _startDiagonalDrag(DragStartDetails details) {
    if (!_pages.hasClients) return;
    _diagonalDrag?.cancel();
    _diagonalDrag = _pages.position.drag(details, () {
      _diagonalDrag = null;
    });
  }

  void _updateDiagonalDrag(DragUpdateDetails details) {
    _diagonalDrag?.update(details);
  }

  void _endDiagonalDrag(DragEndDetails details) {
    _diagonalDrag?.end(details);
    _diagonalDrag = null;
  }

  void _cancelDiagonalDrag() {
    _diagonalDrag?.cancel();
    _diagonalDrag = null;
  }

  void _switchEpisode(int delta) {
    if (_items.isEmpty) return;
    final detail = _details[_keyFor(_items[_index])];
    if (detail == null || detail.episodes.isEmpty) return;
    final next = clampFeedEpisodeIndex(
      _episode + delta,
      detail.episodes.length,
    );
    if (next == _episode) return;
    _savePosition();
    _episodeByKey[_keyFor(_items[_index])] = next;
    setState(() => _episode = next);
    _showOverlay();
    unawaited(_playCurrent());
  }

  Future<void> _togglePlay() async {
    if (!_player.hasVideo) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    if (mounted) setState(() {});
  }

  void _onCompleted() {
    if (_items.isEmpty || !_player.hasVideo) return;
    final detail = _details[_keyFor(_items[_index])];
    switch (feedCompletionAction(
      episode: _episode,
      episodeCount: detail?.episodes.length,
      videoIndex: _index,
      videoCount: _items.length,
    )) {
      case FeedCompletionAction.nextEpisode:
        _switchEpisode(1);
      case FeedCompletionAction.nextVideo:
        if (_backgrounded) {
          _pages.jumpToPage(_index + 1);
        } else {
          unawaited(
            _pages.nextPage(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            ),
          );
        }
      case FeedCompletionAction.stop:
        break;
    }
  }

  String _formatTime(double seconds) {
    final total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
    final minutes = total ~/ 60;
    final secs = total % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  Widget _coverPlaceholder(Drama drama) {
    if (drama.cover.isEmpty) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              drama.title,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Image.network(
      drama.cover,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              drama.title,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Widget _feedTab(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            border: Border.all(color: selected ? Colors.white : Colors.white54),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: TextStyle(color: selected ? Colors.black : Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _interactionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    String? count,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: label,
            onPressed: onTap,
            icon: Icon(icon, color: Colors.white),
          ),
          Text(label, style: const TextStyle(color: Colors.white)),
          if (count != null)
            Text(
              count,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _danmakuPill() {
    final enabled = widget.store.playbackPreferences.danmaku;
    return InkWell(
      onTap: _toggleDanmaku,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: enabled ? Colors.white : Colors.black54,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '弹',
          style: TextStyle(
            color: enabled ? Colors.black : Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Future<void> _loadCommentCounts(String dramaId, PlaybackPlan plan) async {
    final seriesId = hongguoNumericId(dramaId);
    if (plan.session.isEmpty && seriesId == null) return;
    try {
      final page = plan.session.isEmpty
          ? await widget.repository.commentsBySeries(seriesId!)
          : await widget.repository.comments(plan);
      if (!mounted || _commentDramaId != dramaId) return;
      setState(() => _commentPage = page);
    } catch (_) {}
  }

  Future<void> _openComments(Drama drama) async {
    final plan = _player.plan;
    final seriesId = hongguoNumericId(drama.id);
    if (plan == null || (plan.session.isEmpty && seriesId == null)) {
      _showNoDataNote('该剧暂无评论数据');
      return;
    }
    await showHongguoComments(
      context,
      plan,
      widget.repository,
      initialPage: _commentDramaId == drama.id ? _commentPage : null,
      seriesId: plan.session.isEmpty ? seriesId : null,
    );
  }

  void _showNoDataNote(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _whiteProgressBar(bool isCurrent) {
    return ListenableBuilder(
      listenable: _player,
      builder: (context, _) => StreamBuilder<double>(
        stream: _player.positionStream,
        builder: (context, snapshot) {
          final position = snapshot.data ?? _player.position;
          final duration = _player.duration;
          final max = duration > 0 ? duration : 1.0;
          final fraction = (position / max).clamp(0.0, 1.0);
          void seekTo(double localX, double width) {
            if (!isCurrent || !_player.hasVideo || width <= 0) return;
            unawaited(_player.seek((localX / width * max).clamp(0.0, max)));
          }

          return Row(
            children: [
              Text(
                _formatTime(position),
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final fill = width * fraction;
                    return GestureDetector(
                      onTapDown: (details) =>
                          seekTo(details.localPosition.dx, width),
                      onHorizontalDragUpdate: (details) =>
                          seekTo(details.localPosition.dx, width),
                      child: Container(
                        height: 20,
                        color: Colors.transparent,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            Container(
                              height: 3,
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Container(
                              width: fill,
                              height: 3,
                              color: Colors.white,
                            ),
                            Positioned(
                              left: (fill - 5).clamp(0.0, width - 10),
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
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatTime(duration),
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _landscapeActionButton(
    ({String key, bool enabled}) action,
    bool isCurrent,
  ) {
    Future<void> openMore() async {
      await _openMoreSheet();
      if (mounted) setState(() {});
    }

    VoidCallback? onTap;
    switch (action.key) {
      case 'previous':
        onTap = action.enabled ? () => _switchEpisode(-1) : null;
      case 'next':
        onTap = action.enabled ? () => _switchEpisode(1) : null;
      case 'episodes':
        onTap = _openEpisodePanel;
      case 'more':
        onTap = openMore;
      case 'exitFullscreen':
        onTap = _exitLandscape;
      case 'playPause':
        onTap = isCurrent && _player.hasVideo ? _togglePlay : null;
    }
    final label = switch (action.key) {
      'previous' => '上一集',
      'playPause' => '播放',
      'episodes' => '选集',
      'next' => '下一集',
      'more' => '更多',
      'exitFullscreen' => '退出全屏',
      _ => action.key,
    };
    final icon = switch (action.key) {
      'previous' => Icons.skip_previous_rounded,
      'playPause' => Icons.play_arrow_rounded,
      'episodes' => Icons.grid_view_rounded,
      'next' => Icons.skip_next_rounded,
      'more' => Icons.more_horiz_rounded,
      'exitFullscreen' => Icons.fullscreen_exit_rounded,
      _ => Icons.circle,
    };
    final enabled = action.enabled && onTap != null;
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (action.key == 'playPause')
                ListenableBuilder(
                  listenable: _player,
                  builder: (context, _) => Icon(
                    _player.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: enabled ? Colors.white : Colors.white38,
                  ),
                )
              else
                Icon(icon, color: enabled ? Colors.white : Colors.white38),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? Colors.white : Colors.white38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context, int index) {
    final drama = _items[index];
    final isCurrent = index == _index;
    final detail = _details[_keyFor(drama)];
    final episodeCount = detail?.episodes.length ?? drama.episodes;
    final episodeTitle = detail != null && _episode < detail.episodes.length
        ? detail.episodes[_episode].title
        : '第${_episode + 1}集';
    final episodeLine = episodeTitle == '第${_episode + 1}集'
        ? '第${_episode + 1}集'
        : '第${_episode + 1}集 | $episodeTitle';
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: isCurrent ? _handleVideoTap : null,
          child: isCurrent
              ? RoomPlayerView(
                  handle: _player,
                  viewType: TvboxPlayerController.viewType,
                  onCompleted: _onCompleted,
                  onError: (_) {},
                  onRetry: () => unawaited(_playCurrent()),
                )
              : _coverPlaceholder(drama),
        ),
        if (isCurrent)
          HongguoDanmakuLayer(
            handle: _player,
            repository: widget.repository,
            store: widget.store,
            available: _player.videoKey == '${drama.id}|$_episode' &&
                _player.hasVideo,
            aspectRatio: hongguoVideoAspect(_player),
            seriesId: hongguoNumericId(drama.id),
            videoId: detail != null && _episode < detail.episodes.length
                ? hongguoNumericId(detail.episodes[_episode].id)
                : null,
          ),
        if (!_clearScreen && _overlayVisible)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: _landscape
                            ? '退出全屏'
                            : widget.onMenuPressed == null
                            ? '返回列表'
                            : '导航',
                        onPressed: _landscape
                            ? _exitLandscape
                            : widget.onMenuPressed ??
                                  () => Navigator.of(context).pop(),
                        icon: Icon(
                          _landscape
                              ? Icons.fullscreen_exit_rounded
                              : widget.onMenuPressed == null
                              ? Icons.arrow_back_rounded
                              : Icons.menu_rounded,
                          color: Colors.white,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          _landscape
                              ? '${drama.title} · 第${_episode + 1}集'
                              : drama.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      networkSpeedLabel(_speedTracker.speedText),
                    ],
                  ),
                  if (!_landscape &&
                      widget.categories.isNotEmpty &&
                      widget.onCategorySelected != null)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(left: 12, bottom: 4),
                      child: Row(
                        children: [
                          _feedTab(
                            '全部',
                            widget.selectedCategory.isEmpty,
                            () => widget.onCategorySelected!(''),
                          ),
                          for (final category in widget.categories)
                            _feedTab(
                              category.name,
                              category.id == widget.selectedCategory,
                              () => widget.onCategorySelected!(category.id),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (!_clearScreen && !_landscape && _overlayVisible) ...[
          Positioned.fill(
            child: Align(
              alignment: const Alignment(1.0, -0.05),
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _interactionButton(
                      icon: widget.store.following(drama.id) != null
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_outline_rounded,
                      label: '收藏',
                      onTap: isCurrent
                          ? () => unawaited(_toggleFollow(drama))
                          : null,
                    ),
                    _interactionButton(
                      icon: Icons.chat_bubble_outline_rounded,
                      label: '评论',
                      count: _commentDramaId == drama.id &&
                              _commentPage != null &&
                              _commentPage!.total > 0
                          ? '${_commentPage!.total}'
                          : null,
                      onTap: isCurrent
                          ? () => unawaited(_openComments(drama))
                          : null,
                    ),
                    _interactionButton(
                      icon: Icons.favorite_outline_rounded,
                      label: '点赞',
                      onTap: isCurrent
                          ? () => _showNoDataNote('该剧暂无点赞数据')
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Align(
              alignment: const Alignment(-1.0, -0.05),
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: _danmakuPill(),
              ),
            ),
          ),
        ],
        if (!_clearScreen && _overlayVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                child: _landscape
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _whiteProgressBar(isCurrent),
                          const SizedBox(height: 8),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final action in feedLandscapeActions(
                                  hasPrevious: isCurrent && _episode > 0,
                                  hasNext:
                                      isCurrent &&
                                      episodeCount > 0 &&
                                      _episode < episodeCount - 1,
                                ))
                                  _landscapeActionButton(action, isCurrent),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(
                            child: InkWell(
                              onTap: _enterLandscape,
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.fullscreen_rounded,
                                      size: 16,
                                      color: Colors.white,
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
                          const SizedBox(height: 8),
                          Text(
                            drama.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (drama.tags.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final tag in drama.tags)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white12,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: Text(
                                          tag,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      episodeLine,
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (drama.description.isNotEmpty)
                                      Text(
                                        drama.description,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                        maxLines: _descriptionExpanded
                                            ? null
                                            : 2,
                                        overflow: _descriptionExpanded
                                            ? null
                                            : TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              if (drama.description.isNotEmpty)
                                TextButton(
                                  onPressed: () => setState(
                                    () => _descriptionExpanded =
                                        !_descriptionExpanded,
                                  ),
                                  child: Text(
                                    _descriptionExpanded ? '收起' : '展开',
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _whiteProgressBar(isCurrent),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: episodeCount > 0
                                      ? _openEpisodePanel
                                      : null,
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white12,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            episodeCount > 0
                                                ? feedEpisodeBarLabel(
                                                    drama.releaseStatus,
                                                    episodeCount,
                                                  )
                                                : '选集',
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const Icon(
                                          Icons.expand_less_rounded,
                                          color: Colors.white,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '全屏观看',
                                onPressed: _enterLandscape,
                                icon: const Icon(
                                  Icons.fullscreen_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              IconButton(
                                tooltip: '上一集',
                                onPressed: isCurrent && _episode > 0
                                    ? () => _switchEpisode(-1)
                                    : null,
                                icon: const Icon(
                                  Icons.skip_previous_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              ListenableBuilder(
                                listenable: _player,
                                builder: (context, _) => IconButton(
                                  tooltip: _player.playing ? '暂停' : '播放',
                                  onPressed: isCurrent && _player.hasVideo
                                      ? _togglePlay
                                      : null,
                                  icon: Icon(
                                    _player.playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '下一集',
                                onPressed:
                                    isCurrent &&
                                        episodeCount > 0 &&
                                        _episode < episodeCount - 1
                                    ? () => _switchEpisode(1)
                                    : null,
                                icon: const Icon(
                                  Icons.skip_next_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              IconButton(
                                tooltip: '更多',
                                onPressed: () async {
                                  await _openMoreSheet();
                                  if (mounted) setState(() {});
                                },
                                icon: const Icon(
                                  Icons.more_horiz_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          if (isCurrent && _detailLoading)
                            const LinearProgressIndicator(),
                          if (isCurrent && _detailError != null)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _detailError!,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(_playCurrent()),
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                        ],
                      ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('全屏流'),
        ),
        body: const Center(
          child: Text('暂无可播短剧', style: TextStyle(color: Colors.white70)),
        ),
      );
    }
    return PopScope(
      canPop: !_landscape,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _landscape) _exitLandscape();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: RawGestureDetector(
          gestures: <Type, GestureRecognizerFactory>{
            FeedDiagonalDragRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  FeedDiagonalDragRecognizer
                >(
                  () => FeedDiagonalDragRecognizer(
                    isBlocked: () => _sheetOpen,
                    onStart: _startDiagonalDrag,
                    onUpdate: _updateDiagonalDrag,
                    onEnd: _endDiagonalDrag,
                    onCancel: _cancelDiagonalDrag,
                  ),
                  (recognizer) {
                    recognizer.isBlocked = () => _sheetOpen;
                    recognizer.onStart = _startDiagonalDrag;
                    recognizer.onUpdate = _updateDiagonalDrag;
                    recognizer.onEnd = _endDiagonalDrag;
                    recognizer.onCancel = _cancelDiagonalDrag;
                  },
                ),
          },
          child: PageView.builder(
            scrollDirection: Axis.vertical,
            physics: _sheetOpen ? const NeverScrollableScrollPhysics() : null,
            controller: _pages,
            onPageChanged: _onPageChanged,
            itemCount: _items.length,
            itemBuilder: _buildPage,
          ),
        ),
      ),
    );
  }
}
