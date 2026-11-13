import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'compact_chip.dart';
import 'core_bridge.dart';
import 'hero_mix.dart';
import 'hongguo_account.dart';
import 'hongguo_account_entry.dart';
import 'hongguo_comment.dart';
import 'hongguo_danmaku.dart';
import 'hongguo_playback_page.dart';
import 'hongguo_preload.dart';
import 'local_store.dart';
import 'models.dart';
import 'neon/neon_channel_view.dart';
import 'neon/neon_home_view.dart';
import 'neon/neon_ui.dart';
import 'playback_foreground.dart';
import 'tvbox_player_bridge.dart';
import 'watchroom/player.dart';
import 'widgets.dart';

bool isHongguoDramaGroup(String groupId) => groupId == 'hongguo';

/// 试播失败重试两档延迟（对齐对照仓 HomeFeedScreen.trialRecoveryDelays）。
const hongguoTrialRetryDelays = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 5),
];

/// 试播单轮最多往后探的集数（含首集）：第 0/1/2 集。
/// 对齐对照仓 FeedPlayback.openTrialEpisode“最多探到第三集”。
const hongguoTrialMaxProbeEpisodes = 3;

/// 试播探集：从 [startIndex] 起按集号顺序调用 [tryEpisode]，返回首个
/// 能播的集下标；全部探完都播不了返回 null（调用方负责重试或停住，
/// 不静默跳下一部）。[tryEpisode] 返回 true 表示该集已播起来。
Future<int?> hongguoFirstPlayableEpisode({
  required int episodeCount,
  int startIndex = 0,
  required Future<bool> Function(int episodeIndex) tryEpisode,
  int maxProbe = hongguoTrialMaxProbeEpisodes,
}) async {
  final end = episodeCount < startIndex + maxProbe
      ? episodeCount
      : startIndex + maxProbe;
  for (var index = startIndex; index < end; index++) {
    if (await tryEpisode(index)) return index;
  }
  return null;
}

class HongguoDramaHome extends StatefulWidget {
  const HongguoDramaHome({
    super.key,
    required this.dramas,
    required this.repository,
    required this.store,
    required this.onOpenDrama,
    required this.onOpenFeed,
    required this.onPickSource,
    required this.sourceLabel,
    required this.feedEnabled,
    required this.categories,
    required this.selectedCategory,
    required this.onCategorySelected,
    required this.searchController,
    required this.searchHint,
    required this.onSearchChanged,
    required this.onSearchSubmitted,
    required this.onOpenGlobalSearch,
    required this.onMenuPressed,
    required this.onFilterPressed,
    required this.onRankingsPressed,
    required this.onNewPressed,
    required this.filtersActive,
    required this.newActive,
    required this.onOpenSaved,
    this.onSettingsPressed,
    this.onOpenFeatured,
  });

  final List<Drama> dramas;
  final AppRepository repository;
  final LocalStore store;
  final ValueChanged<Drama> onOpenDrama;
  final VoidCallback onOpenFeed;
  final VoidCallback onPickSource;
  final String sourceLabel;
  final bool feedEnabled;
  final List<CatalogCategory> categories;
  final String selectedCategory;
  final ValueChanged<String> onCategorySelected;
  final TextEditingController searchController;
  final String searchHint;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSearchSubmitted;

  /// 霓虹首页/频道页放大镜的动作：那两处没有输入框，点放大镜直接
  /// 打开全站全局搜索（剧场页自带输入框，仍走 onSearchSubmitted）。
  final VoidCallback onOpenGlobalSearch;
  final VoidCallback onMenuPressed;
  final VoidCallback onFilterPressed;
  final VoidCallback onRankingsPressed;
  final VoidCallback onNewPressed;
  final bool filtersActive;
  final bool newActive;
  final void Function({required bool history}) onOpenSaved;
  final VoidCallback? onSettingsPressed;

  /// 霓虹轮播位点按：混入的其它站源幻灯片由此打开（壳侧先切区切
  /// 源）；为空时轮播点按走 [onOpenDrama]。
  final ValueChanged<Drama>? onOpenFeatured;

  @override
  State<HongguoDramaHome> createState() => _HongguoDramaHomeState();
}

typedef _Channel = ({String key, String label, String? categoryId});

typedef _FeedResume = ({String key, int episode, double position});

class _HongguoDramaHomeState extends State<HongguoDramaHome> {
  static _FeedResume? _resume;

  int _tab = 3;
  String _channel = 'recommend';
  bool _didRandomStart = false;
  bool _synopsisExpanded = false;
  late final PageController _pages;
  final RoomPlayerHandle _player = RoomPlayerHandle();
  late final HongguoAccountController _accountController =
      HongguoAccountController.withTransport(
        GoHongguoAccountTransport(widget.repository),
        repository: widget.repository,
      );
  late final HongguoPreloadWindow _preloadWindow = HongguoPreloadWindow(
    widget.repository,
    detailOf: (drama) async {
      final cached = _details[_keyFor(drama)];
      if (cached != null) return cached;
      try {
        final detail = await widget.repository.detail(drama);
        if (mounted) _details[_keyFor(drama)] = detail;
        return detail;
      } catch (_) {
        return null;
      }
    },
  );
  final Map<String, DramaDetail> _details = {};
  final Map<String, HongguoCommentPage> _commentPages = {};
  int _index = 0;
  int _episode = 0;
  double _startPosition = 0;
  bool _detailLoading = false;
  String? _detailError;
  int _playToken = 0;
  bool _opening = false;
  bool _pendingPlay = false;
  bool _playbackServiceHeld = false;
  String? _theaterTagLevel2;
  String? _theaterTagLevel3;
  List<CatalogCategory> _drillPath = [];
  String _videoKeys = '';

  /// 霓虹轮播混排结果：null = 尚未混入（只显示基础位）；非空 =
  /// 基础位 + 随机混入的成人站幻灯片。重抽只发生在首页数据刷新时。
  List<Drama>? _heroMixed;
  String _heroMixKey = '';
  int _heroMixGen = 0;

  /// 轮播混排重抽判断：默认首页（无搜词、未选分类）才混入；搜词
  /// 与分类浏览时轮播保持当前目录原样。键不变时不重抽、不重取。
  void _maybeRefreshHeroMix() {
    final base = heroBaseSlides(widget.dramas);
    final blocked = widget.searchController.text.trim().isNotEmpty ||
        widget.selectedCategory.isNotEmpty;
    final key = blocked ? 'blocked:${heroMixKey(base)}' : heroMixKey(base);
    if (key == _heroMixKey) return;
    _heroMixKey = key;
    _heroMixed = null;
    if (blocked || base.isEmpty) return;
    final gen = ++_heroMixGen;
    final sites = sampleAdultSites(
      widget.store.sources
          .where((site) => widget.store.siteVisible(site.id))
          .toList(),
      random: Random(),
      excludeIds: base.map((drama) => drama.source).toSet(),
    );
    if (sites.isEmpty) return;
    unawaited(_loadHeroMix(sites, key, gen));
  }

  /// 异步取成人站首页：单站超时隔离、失败静默跳过；结果只在
  /// 代次与键都未变时才生效，过期结果直接丢弃。
  Future<void> _loadHeroMix(
    List<SourceSite> sites,
    String key,
    int gen,
  ) async {
    final results = await Future.wait(sites.map((site) async {
      try {
        final page = await widget.repository
            .catalog(site.id)
            .timeout(heroMixSiteTimeout);
        return adultHeroCandidates(page.items);
      } catch (_) {
        return const <Drama>[];
      }
    }));
    if (!mounted || gen != _heroMixGen || key != _heroMixKey) return;
    final adult = results.expand((list) => list).toList();
    if (adult.isEmpty) return;
    final base = heroBaseSlides(widget.dramas);
    if (heroMixKey(base) != key) return;
    setState(() {
      _heroMixed =
          mixHeroSlides(base: base, adult: adult, random: Random());
    });
  }

  @override
  void initState() {
    super.initState();
    final videos = _videos;
    _videoKeys = videos.map(_keyFor).join('|');
    final resume = _resume;
    final resumeIndex = resume == null
        ? -1
        : videos.indexWhere((drama) => _keyFor(drama) == resume.key);
    if (resumeIndex >= 0 && resume != null) {
      _didRandomStart = true;
      _index = resumeIndex;
      _episode = resume.episode;
      _startPosition = resume.position;
      _pages = PageController(initialPage: _index);
    } else if (videos.length > 1) {
      _didRandomStart = true;
      _index = Random().nextInt(videos.length);
      _pages = PageController(initialPage: _index);
    } else {
      _pages = PageController();
    }
    if (videos.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _videos.isEmpty) return;
        unawaited(_playCurrent());
        unawaited(_prefetch(_index + 1));
      });
    }
    unawaited(_accountController.load());
    _maybeRefreshHeroMix();
  }

  String get _siteName {
    final label = widget.sourceLabel;
    final match = RegExp(r'^(.*) \(\d+\)$').firstMatch(label);
    return match?.group(1) ?? label;
  }

  List<Drama> get _theaterVideos {
    var videos = _theaterBaseVideos;
    if (_theaterTagLevel2 != null) {
      videos = videos
          .where((drama) => drama.tags.contains(_theaterTagLevel2))
          .toList();
    }
    if (_theaterTagLevel3 != null) {
      videos = videos
          .where((drama) => drama.tags.contains(_theaterTagLevel3))
          .toList();
    }
    return videos;
  }

  List<Drama> get _theaterBaseVideos =>
      widget.dramas.where((drama) => drama.kind == 'video').toList();

  List<String> get _theaterLevel2Tags {
    final seen = <String>{};
    final out = <String>[];
    for (final drama in _theaterBaseVideos) {
      for (final tag in drama.tags) {
        if (seen.add(tag)) out.add(tag);
      }
    }
    return out;
  }

  List<String> get _theaterLevel3Tags {
    final level2 = _theaterTagLevel2;
    if (level2 == null) return const [];
    final seen = <String>{};
    final out = <String>[];
    for (final drama in _theaterBaseVideos) {
      if (!drama.tags.contains(level2)) continue;
      for (final tag in drama.tags) {
        if (tag != level2 && seen.add(tag)) out.add(tag);
      }
    }
    return out;
  }

  void _onTheaterCategoryTap(CatalogCategory category) {
    if (category.isFolder) {
      setState(() {
        _drillPath = [..._drillPath, category];
        _theaterTagLevel2 = null;
        _theaterTagLevel3 = null;
      });
      widget.onCategorySelected(category.drillId);
      return;
    }
    setState(() {
      _drillPath = [];
      _theaterTagLevel2 = null;
      _theaterTagLevel3 = null;
    });
    widget.onCategorySelected(category.id);
  }

  void _onTheaterBack() {
    if (_drillPath.isEmpty) return;
    final path = [..._drillPath]..removeLast();
    setState(() {
      _drillPath = path;
      _theaterTagLevel2 = null;
      _theaterTagLevel3 = null;
    });
    widget.onCategorySelected(path.isEmpty ? '' : path.last.drillId);
  }

  @override
  void didUpdateWidget(HongguoDramaHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeRefreshHeroMix();
    if (widget.selectedCategory != oldWidget.selectedCategory) {
      _theaterTagLevel2 = null;
      _theaterTagLevel3 = null;
      _drillPath = [];
    }
    if (_channel != 'follow') {
      _channel = _channelForCategory(widget.selectedCategory) ?? '';
    }
    final next = _videos;
    final nextKeys = next.map(_keyFor).join('|');
    if (nextKeys == _videoKeys) return;
    _videoKeys = nextKeys;
    _playToken++;
    var target = 0;
    if (!_didRandomStart && next.length > 1) {
      _didRandomStart = true;
      target = Random().nextInt(next.length);
    }
    setState(() {
      _index = target;
      _episode = 0;
      _synopsisExpanded = false;
      _detailError = null;
    });
    if (next.isEmpty) return;
    _scheduleGoTo(target);
  }

  @override
  void dispose() {
    _playToken++;
    if (_player.hasVideo && _videos.isNotEmpty) {
      final current = _videos[_index.clamp(0, _videos.length - 1)];
      _resume = (
        key: _keyFor(current),
        episode: _episode,
        position: _player.position,
      );
    }
    _pages.dispose();
    _player.dispose();
    _preloadWindow.dispose();
    _accountController.dispose();
    if (_playbackServiceHeld) {
      _playbackServiceHeld = false;
      unawaited(PlaybackForeground.release());
    }
    super.dispose();
  }

  Future<void> _loadCommentCounts(Drama drama, PlaybackPlan plan) async {
    final key = _keyFor(drama);
    if (_commentPages.containsKey(key)) return;
    final seriesId = hongguoNumericId(drama.id);
    if (plan.session.isEmpty && seriesId == null) return;
    try {
      final page = plan.session.isEmpty
          ? await widget.repository.commentsBySeries(seriesId!)
          : await widget.repository.comments(plan);
      if (!mounted || _videos.isEmpty) return;
      final current = _videos[_index.clamp(0, _videos.length - 1)];
      if (_keyFor(current) != key) return;
      if (_commentPages.length >= 10) {
        _commentPages.remove(_commentPages.keys.first);
      }
      setState(() => _commentPages[key] = page);
    } catch (_) {}
  }

  Future<void> _openComments(Drama drama) async {
    final plan = _player.plan;
    if (plan == null) {
      _note('本集暂不支持评论');
      return;
    }
    final seriesId = hongguoNumericId(drama.id);
    if (plan.session.isEmpty && seriesId == null) {
      _note('本集暂不支持评论');
      return;
    }
    await showHongguoComments(
      context,
      plan,
      widget.repository,
      initialPage: _commentPages[_keyFor(drama)],
      seriesId: plan.session.isEmpty ? seriesId : null,
    );
  }

  String _keyFor(Drama drama) => '${drama.source}|${drama.id}';

  List<Drama> get _videos {
    if (_channel == 'follow') {
      return widget.store.favorites
          .where(
            (drama) =>
                drama.source == 'hongguo' ||
                drama.id.startsWith('hongguo:'),
          )
          .toList();
    }
    return widget.dramas.where((drama) => drama.kind == 'video').toList();
  }

  _Channel _recommendChannel() {
    for (final category in widget.categories) {
      if (category.name == '推荐') {
        return (
          key: 'recommend',
          label: '推荐',
          categoryId: category.id,
        );
      }
    }
    for (final category in widget.categories) {
      if (category.name == '全部' || category.id.isEmpty) {
        return (
          key: 'recommend',
          label: '推荐',
          categoryId: category.id,
        );
      }
    }
    return (
      key: 'recommend',
      label: '推荐',
      categoryId:
          widget.categories.isEmpty ? null : widget.categories.first.id,
    );
  }

  List<_Channel> get _channels {
    final byKey = <String, _Channel>{'recommend': _recommendChannel()};
    for (final category in widget.categories) {
      if (category.name == '真人剧' || category.id == 'short_play') {
        byKey.putIfAbsent(
          'real',
          () => (key: 'real', label: '真人剧', categoryId: category.id),
        );
      }
      if (category.name == '漫剧' || category.id == 'comic_series') {
        byKey.putIfAbsent(
          'comic',
          () => (key: 'comic', label: '漫剧', categoryId: category.id),
        );
      }
    }
    byKey['follow'] = (key: 'follow', label: '关注', categoryId: null);
    return [
      for (final key in ['follow', 'comic', 'real', 'recommend'])
        if (byKey.containsKey(key)) byKey[key]!,
    ];
  }

  String? _channelForCategory(String categoryId) {
    for (final channel in _channels) {
      if (channel.categoryId != null &&
          channel.categoryId == categoryId) {
        return channel.key;
      }
    }
    for (final category in widget.categories) {
      if (category.id == categoryId && category.name == '全部') {
        return 'recommend';
      }
    }
    return null;
  }

  void _scheduleGoTo(int index) {
    if (_pages.hasClients) {
      _goToPage(index);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _videos.isEmpty) return;
        _goToPage(index.clamp(0, _videos.length - 1));
      });
    }
  }

  void _goToPage(int index) {
    if (_pages.hasClients && (_pages.page?.round() ?? 0) != index) {
      _pages.jumpToPage(index);
    } else {
      unawaited(_playCurrent());
      unawaited(_prefetch(index + 1));
    }
  }

  void _onPageChanged(int index) {
    // 翻页即作废上一部的试播（含重试等待），新一部的试播另起 token。
    _playToken++;
    setState(() {
      _index = index;
      _episode = 0;
      _synopsisExpanded = false;
      _detailError = null;
    });
    unawaited(_playCurrent());
    unawaited(_prefetch(index + 1));
  }

  Future<void> _playCurrent() async {
    final videos = _videos;
    if (videos.isEmpty || !mounted || _tab != 0) return;
    if (_opening) {
      _pendingPlay = true;
      return;
    }
    final token = ++_playToken;
    _opening = true;
    try {
      final index = _index.clamp(0, videos.length - 1);
      final drama = videos[index];
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
      final startIndex = _episode.clamp(0, detail.episodes.length - 1);
      if (startIndex != _episode) {
        setState(() => _episode = startIndex);
      }
      if (!mounted || token != _playToken) return;
      final start = _startPosition;
      _startPosition = 0;
      // 上一轮试播失败的提示清掉，成功播起来后不再显示。
      if (_detailError != null) {
        setState(() => _detailError = null);
      }
      final preloaded = _preloadWindow.take(
        drama,
        detail.episodes[startIndex],
      );
      // 试播：先探首集（或续播集），播不起来就往后探；整轮都失败时
      // 按 2 秒、5 秒两档重试；耗尽后停在当前推荐，不跳下一部。
      var playedIndex = await _tryTrialEpisodes(
        detail: detail,
        drama: drama,
        startIndex: startIndex,
        startPosition: start,
        preloadedPlan: preloaded,
        token: token,
      );
      for (final delay in hongguoTrialRetryDelays) {
        if (playedIndex != null) break;
        if (!mounted || token != _playToken) return;
        if (!await _sleepOrAbort(delay, token)) return;
        if (!mounted || token != _playToken) return;
        playedIndex = await _tryTrialEpisodes(
          detail: detail,
          drama: drama,
          startIndex: startIndex,
          startPosition: 0,
          token: token,
        );
      }
      if (playedIndex == null) {
        if (!mounted || token != _playToken) return;
        setState(() => _detailError = '试播暂时失败，可点重试或上下滑动换一部');
        return;
      }
      if (!mounted || token != _playToken) return;
      if (_tab != 0) {
        unawaited(_player.pause());
        return;
      }
      final episodeIndex = playedIndex;
      final plan = _player.plan;
      if (plan != null) {
        if (!_playbackServiceHeld) {
          _playbackServiceHeld = true;
          unawaited(PlaybackForeground.acquire(drama.title));
        }
        unawaited(_loadCommentCounts(drama, plan));
      }
      final nextVideos = <Drama>[];
      for (var i = index + 1; i < videos.length && nextVideos.length < 3; i++) {
        nextVideos.add(videos[i]);
      }
      _preloadWindow.recenter(
        drama: drama,
        episodes: detail.episodes,
        episodeIndex: episodeIndex,
        upcoming: nextVideos,
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

  /// 试播探集：从 [startIndex] 起按顺序试播，最多探
  /// [hongguoTrialMaxProbeEpisodes] 集，返回首个能播的集下标，
  /// 全部失败返回 null。首集可用预加载的 plan，其余集现取现验
  /// （取流失败即该集不可播）；续播起始位置只用于首集，
  /// 回退的集从头播。播起来的集写回 [_episode]，信息区集号与之一致。
  Future<int?> _tryTrialEpisodes({
    required DramaDetail detail,
    required Drama drama,
    required int startIndex,
    required double startPosition,
    required int token,
    PlaybackPlan? preloadedPlan,
  }) async {
    final played = await hongguoFirstPlayableEpisode(
      episodeCount: detail.episodes.length,
      startIndex: startIndex,
      tryEpisode: (index) async {
        if (!mounted || token != _playToken) return false;
        await _player.open(
          detail: detail,
          episodeIndex: index,
          startPosition: index == startIndex ? startPosition : 0,
          repository: widget.repository,
          store: widget.store,
          preloadedPlan: index == startIndex ? preloadedPlan : null,
        );
        if (!mounted || token != _playToken) return false;
        // _player.open 内部已把取流/打开失败记进 error：
        // error 为空且有视频才算该集播起来。
        return _player.error == null && _player.hasVideo;
      },
    );
    if (played != null && mounted && _episode != played) {
      setState(() => _episode = played);
    }
    return played;
  }

  /// 可中断的等待：每 100 毫秒检查一次，翻页/切 tab/退出即返回 false，
  /// 否则等满 [delay] 返回 true。
  Future<bool> _sleepOrAbort(Duration delay, int token) async {
    var waited = Duration.zero;
    const step = Duration(milliseconds: 100);
    while (waited < delay) {
      if (!mounted || token != _playToken) return false;
      final rest = delay - waited;
      final slice = rest < step ? rest : step;
      await Future<void>.delayed(slice);
      waited += slice;
    }
    return mounted && token == _playToken;
  }

  Future<void> _prefetch(int index) async {
    final videos = _videos;
    if (index < 0 || index >= videos.length) return;
    final drama = videos[index];
    if (_details.containsKey(_keyFor(drama))) return;
    try {
      final detail = await widget.repository.detail(drama);
      if (!mounted) return;
      _details[_keyFor(drama)] = detail;
    } catch (_) {}
  }

  Future<void> _togglePlay() async {
    if (!_player.hasVideo) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  void _onCompleted() {
    final videos = _videos;
    if (videos.isEmpty) return;
    if (_index + 1 < videos.length) {
      unawaited(
        _pages.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
    } else {
      unawaited(_playCurrent());
    }
  }

  Future<void> _openPlayback(
    Drama drama, {
    int? episodeIndex,
    double? startPosition,
  }) async {
    final wasPlaying = _player.hasVideo && _player.playing;
    if (_player.hasVideo) await _player.pause();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      appPageRoute<void>(
        settings: const RouteSettings(name: 'hongguo-playback'),
        builder: (_) => HongguoPlaybackPage(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
          detail: _details[_keyFor(drama)],
          initialEpisode: episodeIndex ?? _episode,
          startPosition: startPosition ?? _player.position,
        ),
      ),
    );
    if (!mounted) return;
    if (wasPlaying && _player.hasVideo) unawaited(_player.play());
  }

  Future<void> _toggleFavorite(Drama drama) async {
    await widget.store.toggleFavorite(drama);
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

  void _onChannelTap(_Channel channel) {
    setState(() {
      _channel = channel.key;
      _index = 0;
      _episode = 0;
      _synopsisExpanded = false;
      _detailError = null;
    });
    if (channel.key == 'follow') {
      _goToPage(0);
    } else if (channel.categoryId != null &&
        channel.categoryId != widget.selectedCategory) {
      widget.onCategorySelected(channel.categoryId!);
    } else {
      _goToPage(0);
    }
  }

  void _selectTab(int index) {
    if (index == _tab) return;
    setState(() => _tab = index);
    if (index != 0) {
      _playToken++;
      if (_player.hasVideo) unawaited(_player.pause());
    } else if (_player.hasVideo) {
      if (!_player.playing) unawaited(_player.play());
    } else {
      unawaited(_playCurrent());
    }
  }

  // 霓虹页签（追加到原有的 0=全屏流 / 1=剧场 / 2=我的 之后，
  // 这样原有播放与剧场逻辑完全不受影响）。
  static const _neonHomeTab = 3;
  static const _neonChannelTab = 4;

  int get _barIndex => switch (_tab) {
        3 => 0,
        4 => 1,
        1 => 2,
        2 => 3,
        _ => -1,
      };

  void _onBarSelect(int index) {
    _selectTab(switch (index) {
      0 => _neonHomeTab,
      1 => _neonChannelTab,
      2 => 1,
      _ => 2,
    });
  }

  @override
  Widget build(BuildContext context) {
    final neonTab = _tab >= 3;
    return Scaffold(
      backgroundColor: _tab == 0 ? Colors.black : (neonTab ? Neon.bg : null),
      extendBody: neonTab,
      body: neonTab
          ? NeonBackdrop(
              // 频道页参考图是「顶部紫色主光 + 左中光更弱」的布局。
              intensity: _tab == _neonHomeTab ? 1 : .58,
              magentaY: _tab == _neonHomeTab ? .40 : .26,
              tealY: _tab == _neonHomeTab ? .40 : .30,
              topGlow: _tab == _neonHomeTab ? .26 : .58,
              rightGlowColor: _tab == _neonHomeTab ? Neon.teal : Neon.blue,
              rightGlowAlpha: _tab == _neonHomeTab ? 1 : .62,
              child: SafeArea(
                bottom: false,
                child: _tab == _neonHomeTab
                    ? _neonHome(context)
                    : _neonChannel(context),
              ),
            )
          : switch (_tab) {
              1 => _theater(context),
              2 => _mine(context),
              _ => _feed(context),
            },
      bottomNavigationBar: NeonBottomBar(
        index: _barIndex,
        onSelect: _onBarSelect,
        onCenter: () => _selectTab(0),
      ),
    );
  }

  Widget _neonHome(BuildContext context) {
    return NeonHomeView(
      items: widget.dramas,
      repository: widget.repository,
      brand: '魔蚁box',
      sourceLabel: widget.sourceLabel,
      onOpen: widget.onOpenDrama,
      onSearch: widget.onOpenGlobalSearch,
      onSourceTap: widget.onPickSource,
      onLongPress: widget.onOpenDrama,
      onMenu: widget.onMenuPressed,
      onRankings: widget.onRankingsPressed,
      onFeaturedPlay: widget.onOpenFeatured ?? widget.onOpenDrama,
      featuredItems: _heroMixed,
      onOpenFeatured: widget.onOpenFeatured,
    );
  }

  Widget _neonChannel(BuildContext context) {
    return NeonChannelView(
      items: widget.dramas,
      repository: widget.repository,
      categories: widget.categories,
      selectedCategory: widget.selectedCategory,
      onCategory: widget.onCategorySelected,
      onOpen: widget.onOpenDrama,
      onBack: () => _selectTab(_neonHomeTab),
      onSearch: widget.onOpenGlobalSearch,
      onFilter: widget.onFilterPressed,
      onRankings: widget.onRankingsPressed,
      filtersActive: widget.filtersActive,
    );
  }

  Widget _feed(BuildContext context) {
    final videos = _videos;
    if (videos.isEmpty) {
      return SafeArea(
        child: StatusPanel(
          title: _channel == 'follow' ? '暂无关注短剧' : '暂无可播短剧',
          message: _channel == 'follow'
              ? '在剧集上点收藏后，这里会显示你关注的短剧。'
              : '可以换个分类或刷新后重试。',
        ),
      );
    }
    return Stack(
      children: [
        PageView.builder(
          scrollDirection: Axis.vertical,
          controller: _pages,
          onPageChanged: _onPageChanged,
          itemCount: videos.length,
          itemBuilder: (context, index) {
            return _buildFeedPage(context, videos[index], index == _index);
          },
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _feedTopBar(),
        ),
      ],
    );
  }

  Widget _feedTopBar() {
    final channels = _channels;
    final tabWidgets = <Widget>[];
    for (var i = 0; i < channels.length; i++) {
      if (i > 0) tabWidgets.add(const SizedBox(width: 20));
      final channel = channels[i];
      tabWidgets.add(
        GestureDetector(
          onTap: () => _onChannelTap(channel),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                channel.label,
                style: TextStyle(
                  color:
                      _channel == channel.key ? Colors.white : Colors.white70,
                  fontSize: 16,
                  fontWeight: _channel == channel.key
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 20,
                height: 3,
                decoration: BoxDecoration(
                  color: _channel == channel.key
                      ? Colors.white
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: tabWidgets,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                onPressed: () => _selectTab(1),
                icon: const Icon(Icons.search, color: Colors.white),
                tooltip: '搜索',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeedPage(BuildContext context, Drama drama, bool isCurrent) {
    return GestureDetector(
      onTap: isCurrent ? _togglePlay : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _videoArea(context, drama, isCurrent),
          if (isCurrent) ...[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.25),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.75),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Align(
                alignment: const Alignment(1.0, 0.0),
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _feedAction(
                        icon: widget.store.isFavorite(drama.id)
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        label: '收藏',
                        count: _commentPageFor(drama)?.collectorsCount,
                        onTap: () => unawaited(_toggleFavorite(drama)),
                      ),
                      const SizedBox(height: 20),
                      _feedAction(
                        icon: Icons.chat_bubble_outline_rounded,
                        label: '评论',
                        count: _commentPageFor(drama)?.total,
                        onTap: () => unawaited(_openComments(drama)),
                      ),
                      const SizedBox(height: 20),
                      _feedAction(
                        icon: Icons.favorite_outline_rounded,
                        label: '点赞',
                        onTap: () => _note('该剧暂无点赞数据'),
                      ),
                      const SizedBox(height: 20),
                      _feedAction(
                        icon: Icons.comment_rounded,
                        label: widget.store.playbackPreferences.danmaku
                            ? '弹幕开'
                            : '弹幕关',
                        onTap: () => unawaited(_toggleDanmaku()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 72,
              bottom: 24,
              child: _feedInfo(context, drama),
            ),
          ],
        ],
      ),
    );
  }

  Widget _videoArea(BuildContext context, Drama drama, bool isCurrent) {
    if (!isCurrent) {
      return DramaCover(drama: drama, repository: widget.repository);
    }
    return ListenableBuilder(
      listenable: _player,
      builder: (context, _) {
        final keyMatches = _player.videoKey == '${drama.id}|$_episode';
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
              ),
              HongguoDanmakuLayer(
                handle: _player,
                repository: widget.repository,
                store: widget.store,
                available: keyMatches && _player.hasVideo,
                aspectRatio: hongguoVideoAspect(_player),
                seriesId: hongguoNumericId(drama.id),
                videoId: _details[_keyFor(drama)] != null &&
                        _episode >= 0 &&
                        _episode <
                            _details[_keyFor(drama)]!.episodes.length
                    ? hongguoNumericId(
                        _details[_keyFor(drama)]!.episodes[_episode].id,
                      )
                    : null,
              ),
            ],
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            DramaCover(drama: drama, repository: widget.repository),
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
    );
  }

  HongguoCommentPage? _commentPageFor(Drama drama) {
    final page = _commentPages[_keyFor(drama)];
    return page;
  }

  Widget _feedAction({
    required IconData icon,
    required String label,
    int? count,
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
          if (count != null && count > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '$count',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _feedInfo(BuildContext context, Drama drama) {
    final detail = _details[_keyFor(drama)];
    final episodeCount = detail?.episodes.length ?? drama.episodes;
    final synopsis =
        detail?.drama.description ?? drama.description;
    final episodeLine = detail != null && _episode < detail.episodes.length
        ? '第${_episode + 1}集 | ${detail.episodes[_episode].title}'
        : null;
    final isComic = _channel == 'comic' ||
        drama.category == 'comic_series' ||
        drama.category.contains('漫') ||
        drama.category.contains('comic');
    final kindLabel = isComic ? '漫剧' : '短剧';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (drama.tags.isNotEmpty)
          Wrap(
            spacing: 6,
            children: drama.tags
                .take(4)
                .map(
                  (tag) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      tag,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => unawaited(_openPlayback(drama)),
          child: Text(
            drama.title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (episodeLine != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              episodeLine,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.white70),
            ),
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
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: Colors.white70),
                    maxLines: _synopsisExpanded ? null : 2,
                    overflow: _synopsisExpanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                ),
                if (synopsis.length > 80)
                  GestureDetector(
                    onTap: () => setState(
                      () => _synopsisExpanded = !_synopsisExpanded,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        _synopsisExpanded ? '收起' : '展开',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (drama.heat.isNotEmpty || drama.views.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              drama.heat.isNotEmpty
                  ? '热度 ${drama.heat}'
                  : '播放 ${drama.views}',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.white70),
            ),
          ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () => unawaited(_openPlayback(drama)),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF262626),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.play_arrow, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    episodeCount > 0
                        ? '观看完整$kindLabel · 全$episodeCount集'
                        : '观看完整$kindLabel',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white),
              ],
            ),
          ),
        ),
        if (detail != null && detail.related.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            '系列剧',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: detail.related.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final item = detail.related[index];
                return GestureDetector(
                  onTap: () => unawaited(
                    _openPlayback(
                      item,
                      episodeIndex: 0,
                      startPosition: 0,
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      item.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _theater(BuildContext context) {
    final videos = _theaterVideos;
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: widget.searchController,
                decoration: InputDecoration(
                  hintText: widget.searchHint,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(24)),
                  ),
                ),
                onChanged: widget.onSearchChanged,
                onSubmitted: widget.onSearchSubmitted,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _theaterAction(
                    context,
                    label: '区域',
                    icon: Icons.menu,
                    active: false,
                    onPressed: widget.onMenuPressed,
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: widget.onPickSource,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .secondaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _siteName,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSecondaryContainer,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.expand_more_rounded,
                            size: 16,
                            color: Theme.of(context)
                                .colorScheme
                                .onSecondaryContainer,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _theaterAction(
                    context,
                    label: '筛选',
                    icon: Icons.filter_list,
                    active: widget.filtersActive,
                    onPressed: widget.onFilterPressed,
                  ),
                  const SizedBox(width: 8),
                  _theaterAction(
                    context,
                    label: '排行榜',
                    icon: Icons.leaderboard_outlined,
                    active: false,
                    onPressed: widget.onRankingsPressed,
                  ),
                  const SizedBox(width: 8),
                  _theaterAction(
                    context,
                    label: '新剧',
                    icon: Icons.new_releases_outlined,
                    active: widget.newActive,
                    onPressed: widget.onNewPressed,
                  ),
                ],
              ),
            ),
          ),
          if (_drillPath.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    ActionChip(
                      label: const Text('← 上一级'),
                      onPressed: _onTheaterBack,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _drillPath.last.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: widget.categories
                    .map(
                      (category) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(category.name),
                              if (category.isFolder) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.folder_open, size: 14),
                              ],
                            ],
                          ),
                          selected: widget.selectedCategory ==
                              (category.isFolder
                                  ? category.drillId
                                  : category.id),
                          onSelected: (_) =>
                              _onTheaterCategoryTap(category),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          if (_theaterLevel2Tags.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: compactChipHeight(context),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: CompactFilterChip(
                        label: '全部标签',
                        selected: _theaterTagLevel2 == null,
                        onSelected: () => setState(() {
                          _theaterTagLevel2 = null;
                          _theaterTagLevel3 = null;
                        }),
                      ),
                    ),
                    for (final tag in _theaterLevel2Tags)
                      Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: CompactFilterChip(
                          key: ValueKey('theater-tag2-$tag'),
                          label: tag,
                          selected: _theaterTagLevel2 == tag,
                          onSelected: () => setState(() {
                            _theaterTagLevel2 =
                                _theaterTagLevel2 == tag ? null : tag;
                            _theaterTagLevel3 = null;
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (_theaterTagLevel2 != null && _theaterLevel3Tags.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: compactChipHeight(context),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: CompactFilterChip(
                        label: '全部',
                        selected: _theaterTagLevel3 == null,
                        onSelected: () =>
                            setState(() => _theaterTagLevel3 = null),
                      ),
                    ),
                    for (final tag in _theaterLevel3Tags)
                      Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: CompactFilterChip(
                          key: ValueKey('theater-tag3-$tag'),
                          label: tag,
                          selected: _theaterTagLevel3 == tag,
                          onSelected: () => setState(() {
                            _theaterTagLevel3 =
                                _theaterTagLevel3 == tag ? null : tag;
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.62,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final drama = videos[index];
                  return GestureDetector(
                    onTap: () => widget.onOpenDrama(drama),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: DramaCover(
                              drama: drama,
                              repository: widget.repository,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          drama.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (drama.heat.isNotEmpty || drama.views.isNotEmpty)
                          Text(
                            drama.heat.isNotEmpty
                                ? '热度 ${drama.heat}'
                                : '播放 ${drama.views}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  );
                },
                childCount: videos.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _theaterAction(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback onPressed,
  }) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: active
          ? FilledButton.styleFrom(
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
            )
          : null,
    );
  }

  Widget _mine(BuildContext context) {
    return SafeArea(
      child: ListView(
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: const Text('我的'),
            subtitle: Text(widget.sourceLabel),
          ),
          const Divider(),
          HongguoAccountEntry(
            controller: _accountController,
            repository: widget.repository,
          ),
          const Divider(),
          HongguoAccountCloudSection(
            controller: _accountController,
            onOpenDrama: widget.onOpenDrama,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: const Text('追剧'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => widget.onOpenSaved(history: false),
          ),
          ListTile(
            leading: const Icon(Icons.history_outlined),
            title: const Text('最近观看'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => widget.onOpenSaved(history: true),
          ),
          if (widget.onSettingsPressed != null)
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: widget.onSettingsPressed,
            ),
        ],
      ),
    );
  }
}
