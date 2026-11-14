import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'app_theme_config.dart';
import 'content_tier_filter.dart';
import 'core_bridge.dart';
import 'feed_adult_mix.dart';
import 'feed_playability.dart';
import 'hero_mix.dart';
import 'hongguo_account.dart';
import 'hongguo_account_entry.dart';
import 'hongguo_comment.dart';
import 'hongguo_danmaku.dart';
import 'hongguo_playback_page.dart';
import 'hongguo_preload.dart';
import 'local_store.dart';
import 'midnight_zone.dart';
import 'models.dart';
import 'multimedia_screen.dart';
import 'neon/neon_channel_view.dart';
import 'neon/neon_home_view.dart';
import 'neon/neon_ui.dart';
import 'playback_foreground.dart';
import 'theme_settings_screen.dart';
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
  /// “我的”页的内层页签下标（0 全屏流 / 1 多媒体 / 2 我的 / 3 霓虹首页 / 4 频道）。
  static const mineTabIndex = 2;

  /// 多媒体页的内层页签下标（原片单位置）。
  static const multimediaTabIndex = 1;

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
    this.currentSourceLabel,
    this.requestedTab,
    this.contentTier,
    this.tierEmpty = false,
    this.hideCapsuleBar = false,
    this.playabilityVerifier,
    this.driveSites = const [],
    this.onOpenCloudLogin,
    this.metadataFetcher,
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
  /// 打开全站全局搜索（多媒体屏自带网盘搜索框，不走这里）。
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

  /// 频道页站点切换胶囊上显示的当前站名（全部站源时为“全部站源”）；
  /// 不传时胶囊显示旧的 sortLabel。
  final String? currentSourceLabel;

  /// 外层请求的内层页签：非空且与上次不同时，state 把页签驱过去
  /// （底部 Tab“我的”由此进入“我的”页）；胶囊栏点按不受其影响。
  final int? requestedTab;

  /// 当前主题绑定的内容档：非全部档时，频道行只显示该档对应的频道，
  /// 且当前频道被锁定在该档上（漫剧/真人剧档的内容由上游选类保证，
  /// 成人档走成人聚合流）。不传或全部档时行为与原来一致。
  final ContentTier? contentTier;

  /// 内容档锁定的分类在本站不存在：所有内容页签（除“我的”页）显示
  /// 诚实空态，不拿别的分类内容冒充。
  final bool tierEmpty;

  /// 藏胶囊栏：底部标签样式下为真，内层 Scaffold 不挂胶囊栏
  /// （底栏由外层 Scaffold 挂，与通用分支同一结构），同时显示
  /// 内层页签芯片行保住频道等去向；全屏流页签内改由顶栏返回
  /// 键退出。为假时胶囊栏原样。
  final bool hideCapsuleBar;

  /// 成人条目验播器：测试注入假验播器；为空时用默认真实验播器
  /// （取流 + 验真，会产生网络请求）。
  final FeedPlayabilityVerifier? playabilityVerifier;

  /// 已登录且显示中的网盘站，供多媒体页签用；为空时多媒体页
  /// 显示未登录提示。
  final List<SourceSite> driveSites;

  /// 多媒体页未登录提示里的“去网盘登录”跳转。
  final VoidCallback? onOpenCloudLogin;

  /// 多媒体页卡片刮削取数（注入假的供测试；为空时用真刮削链）。
  final MultimediaMetadataFetcher? metadataFetcher;

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
  String _videoKeys = '';

  /// 霓虹轮播混排结果：null = 尚未混入（只显示基础位）；非空 =
  /// 基础位 + 随机混入的成人站幻灯片。重抽只发生在首页数据刷新时。
  List<Drama>? _heroMixed;
  String _heroMixKey = '';
  int _heroMixGen = 0;

  /// 成人频道条目：null = 尚未取到（加载中显示转圈，不显示空状态）；
  /// [] = 取过但无内容（显示诚实空状态）。只在重抽键变化时重取。
  /// 取到后先验播：只有验真的条目才进列表，验不过的一个都不留。
  List<Drama>? _adultFeed;
  String _adultFeedKey = '';
  int _adultFeedGen = 0;

  /// 成人条目验播器（会话内缓存）：取流 + 验真，复用详情缓存。
  /// 测试可经 [HongguoDramaHome.playabilityVerifier] 注入假验播器。
  late final FeedPlayabilityVerifier _playabilityVerifier =
      widget.playabilityVerifier ??
      FeedPlayabilityVerifier(
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
        resolveOf: (drama, episode) =>
            widget.repository.resolve(drama, episode),
      );

  /// 推荐频道混排结果：基础目录 + 均匀混入的成人条目；null = 尚未
  /// 混入（显示未混排的基础目录）。与成人频道共用同一重抽键。
  List<Drama>? _recommendMixed;

  /// 成人频道与推荐混排的重抽判断：只在成人/推荐频道才取数；键
  /// 不变时不重抽、不重取，牌序一会话内固定。
  void _maybeRefreshAdultFeed() {
    if (_channel != 'adult' && _channel != 'recommend') return;
    final base = widget.dramas.where((drama) => drama.kind == 'video').toList();
    final visibleAdultIds = widget.store.sources
        .where(
          (site) =>
              widget.store.siteVisible(site.id) && isAdultSourceName(site.name),
        )
        .map((site) => site.id)
        .toList();
    final key = feedMixKey(visibleAdultIds, heroMixKey(base));
    if (key == _adultFeedKey) {
      if (_recommendMixed == null && _adultFeed != null) {
        _recommendMixed = mixRecommendFeed(
          base: base,
          adult: _adultFeed!,
          random: Random(key.hashCode),
        );
      }
      return;
    }
    final hadFeed = _adultFeed != null;
    _adultFeedKey = key;
    _adultFeed = null;
    _recommendMixed = null;
    if (visibleAdultIds.isEmpty) {
      _adultFeed = const [];
      if (hadFeed && mounted) setState(() {});
      return;
    }
    final gen = ++_adultFeedGen;
    final sites = sampleAdultSites(
      widget.store.sources
          .where((site) => widget.store.siteVisible(site.id))
          .toList(),
      random: Random(),
      count: feedAdultMaxSites,
    );
    if (sites.isEmpty) {
      _adultFeed = const [];
      if (hadFeed && mounted) setState(() {});
      return;
    }
    unawaited(_loadAdultFeed(sites, key, gen));
  }

  /// 异步取成人站首页：单站超时隔离、失败静默跳过；结果只在代次
  /// 与键都未变时才生效，过期结果直接丢弃（与轮播混排同一做法）。
  Future<void> _loadAdultFeed(
    List<SourceSite> sites,
    String key,
    int gen,
  ) async {
    final results = await Future.wait(
      sites.map((site) async {
        try {
          final page = await widget.repository
              .catalog(site.id)
              .timeout(heroMixSiteTimeout);
          return feedAdultCandidates(page.items);
        } catch (_) {
          return const <Drama>[];
        }
      }),
    );
    if (!mounted || gen != _adultFeedGen || key != _adultFeedKey) return;
    final adult = buildAdultFeed(results);
    // 验播：只有取流验真的条目才进流；验播期间代次/键变了就丢弃。
    final verified = await _playabilityVerifier.verifyAll(adult);
    if (!mounted || gen != _adultFeedGen || key != _adultFeedKey) return;
    final base = widget.dramas.where((drama) => drama.kind == 'video').toList();
    setState(() {
      _adultFeed = verified;
      _recommendMixed = mixRecommendFeed(
        base: base,
        adult: verified,
        random: Random(key.hashCode),
      );
    });
    // 成人频道刚取到内容时主动起播首条；推荐频道若已在播则不打断，
    // 混排只影响下一刷的顺序。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _videos.isEmpty) return;
      if (_channel == 'adult' || !_player.hasVideo) {
        unawaited(_playCurrent());
      }
    });
  }

  /// 轮播混排重抽判断：默认首页（无搜词、未选分类）才混入；搜词
  /// 与分类浏览时轮播保持当前目录原样。键不变时不重抽、不重取。
  void _maybeRefreshHeroMix() {
    final base = heroBaseSlides(widget.dramas);
    final blocked =
        widget.searchController.text.trim().isNotEmpty ||
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
  Future<void> _loadHeroMix(List<SourceSite> sites, String key, int gen) async {
    final results = await Future.wait(
      sites.map((site) async {
        try {
          final page = await widget.repository
              .catalog(site.id)
              .timeout(heroMixSiteTimeout);
          return adultHeroCandidates(page.items);
        } catch (_) {
          return const <Drama>[];
        }
      }),
    );
    if (!mounted || gen != _heroMixGen || key != _heroMixKey) return;
    final adult = results.expand((list) => list).toList();
    if (adult.isEmpty) return;
    final base = heroBaseSlides(widget.dramas);
    if (heroMixKey(base) != key) return;
    setState(() {
      _heroMixed = mixHeroSlides(base: base, adult: adult, random: Random());
    });
  }

  @override
  void initState() {
    super.initState();
    final requested = widget.requestedTab;
    if (requested != null) _tab = requested;
    final locked = _lockedChannelKey;
    if (locked != null) _channel = locked;
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
    _maybeRefreshAdultFeed();
  }

  @override
  void didUpdateWidget(HongguoDramaHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requestedTab != oldWidget.requestedTab) {
      if (widget.requestedTab != null) {
        _selectTab(widget.requestedTab!);
      } else if (_tab == oldWidget.requestedTab) {
        // 外层请求撤回（点回片库）：若内层仍停在被请求的页签上
        // （我的/多媒体），回到霓虹首页；用户已在内层自行切走
        // 时不动，避免抢用户正在看的页。
        _selectTab(_neonHomeTab);
      }
    }
    _maybeRefreshHeroMix();
    if (_channel != 'follow' && _channel != 'adult') {
      _channel = _channelForCategory(widget.selectedCategory) ?? '';
    }
    // 内容档锁定位于选类同步之后：锁定的档优先于选类推导出的频道。
    final locked = _lockedChannelKey;
    if (locked != null && _channel != locked) _channel = locked;
    _maybeRefreshAdultFeed();
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
    // 内容档锁定的分类不存在：绝不拿别的分类内容冒充。
    if (widget.tierEmpty) return const [];
    if (_channel == 'follow') {
      return widget.store.favorites
          .where(
            (drama) =>
                drama.source == 'hongguo' || drama.id.startsWith('hongguo:'),
          )
          .toList();
    }
    if (_channel == 'adult') return _adultFeed ?? const [];
    final base = widget.dramas.where((drama) => drama.kind == 'video').toList();
    if (_channel == 'recommend' && _recommendMixed != null) {
      return _recommendMixed!;
    }
    return base;
  }

  _Channel _recommendChannel() {
    for (final category in widget.categories) {
      if (category.name == '推荐') {
        return (key: 'recommend', label: '推荐', categoryId: category.id);
      }
    }
    for (final category in widget.categories) {
      if (category.name == '全部' || category.id.isEmpty) {
        return (key: 'recommend', label: '推荐', categoryId: category.id);
      }
    }
    return (
      key: 'recommend',
      label: '推荐',
      categoryId: widget.categories.isEmpty ? null : widget.categories.first.id,
    );
  }

  /// 内容档锁定的频道键；全部档（或未传档）不锁定。
  String? get _lockedChannelKey =>
      tierChannelKey(widget.contentTier ?? ContentTier.all);

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
    byKey['adult'] = (key: 'adult', label: '成人视频', categoryId: null);
    final all = [
      for (final key in ['follow', 'comic', 'real', 'adult', 'recommend'])
        if (byKey.containsKey(key)) byKey[key]!,
    ];
    // 内容档锁定时频道行只留该档对应的频道；对应分类不存在时仍显示
    // 该档标签（内容区由诚实空态接管），不回落到别的频道。
    final locked = _lockedChannelKey;
    if (locked != null) {
      final hit = all.where((channel) => channel.key == locked).toList();
      if (hit.isNotEmpty) return hit;
      final tier = widget.contentTier ?? ContentTier.all;
      return [(key: locked, label: tier.label, categoryId: null)];
    }
    return all;
  }

  String? _channelForCategory(String categoryId) {
    for (final channel in _channels) {
      if (channel.categoryId != null && channel.categoryId == categoryId) {
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
      final preloaded = _preloadWindow.take(drama, detail.episodes[startIndex]);
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _onChannelTap(_Channel channel) {
    setState(() {
      _channel = channel.key;
      _index = 0;
      _episode = 0;
      _synopsisExpanded = false;
      _detailError = null;
    });
    if (channel.key == 'follow' || channel.key == 'adult') {
      _goToPage(0);
    } else if (channel.categoryId != null &&
        channel.categoryId != widget.selectedCategory) {
      widget.onCategorySelected(channel.categoryId!);
    } else {
      _goToPage(0);
    }
    _maybeRefreshAdultFeed();
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

  // 霓虹页签（追加到原有的 0=全屏流 / 1=多媒体 / 2=我的 之后，
  // 这样原有播放逻辑完全不受影响）。
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
    // 内容档锁定的分类不存在：除“我的”页外，所有内容页签都显示诚实空态。
    // 档位空态只拦站源内容页签：我的页与多媒体页（用户自己的
    // 网盘库，不参与内容档位过滤）不受档位限制。
    final tierGated =
        widget.tierEmpty &&
        _tab != HongguoDramaHome.mineTabIndex &&
        _tab != HongguoDramaHome.multimediaTabIndex;
    final hideCapsuleBar = widget.hideCapsuleBar;
    final body = tierGated
        ? _tierEmptyView()
        : neonTab
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
            1 => _multimedia(context),
            2 => _mine(context),
            _ => _feed(context),
          };
    return Scaffold(
      backgroundColor: _tab == 0 ? Colors.black : (neonTab ? Neon.bg : null),
      extendBody: neonTab,
      body: hideCapsuleBar && _tab != 0
          ? Column(
              children: [
                _internalNavRow(),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: hideCapsuleBar
          ? null
          : NeonBottomBar(
              index: _barIndex,
              onSelect: _onBarSelect,
              onCenter: () => _selectTab(0),
            ),
    );
  }

  /// 底部标签样式下的内层页签行：胶囊栏藏起后，首页/频道/多媒体/
  /// 推荐四个内层去向改由这行芯片到达（“我的”走外层底栏经
  /// requestedTab 驱动）。全屏流页签不显示此行，改由顶栏返回键
  /// 退出（全屏流要保持全屏）。
  Widget _internalNavRow() {
    const entries = [
      ('home', '首页', _neonHomeTab),
      ('channel', '频道', _neonChannelTab),
      ('multimedia', '多媒体', 1),
      ('feed', '推荐', 0),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        key: const ValueKey('drama-internal-nav'),
        spacing: 8,
        children: [
          for (final entry in entries)
            ChoiceChip(
              key: ValueKey('drama-nav-${entry.$1}'),
              label: Text(entry.$2),
              selected: _tab == entry.$3,
              onSelected: (_) => _selectTab(entry.$3),
            ),
        ],
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
      onSwitchSource: widget.onPickSource,
      sourceLabel: widget.currentSourceLabel,
      filtersActive: widget.filtersActive,
    );
  }

  /// 内容档锁定的分类在本站不存在时的诚实空态：两个动作都是真实的——
  /// 切回全部内容档（写回当前主题的显示方案）、切换站点（外层选源）。
  /// 空态本身不提供抽屉入口，这两个出口就是逃生通道，不可删。
  Widget _tierEmptyView() {
    final tier = widget.contentTier ?? ContentTier.all;
    return SafeArea(
      child: StatusPanel(
        title: '暂无${tier.label}',
        message: '当前站点没有「${tier.label}」分类，切回全部内容或换个站点。',
        action: '切回全部内容',
        onRetry: () => saveUserChange(
          context,
          () => widget.store.setDisplayScheme(
            widget.store.appTheme,
            widget.store
                .displayScheme(widget.store.appTheme)
                .copyWith(contentTier: ContentTier.all),
          ),
        ),
        secondaryAction: TextButton(
          onPressed: widget.onPickSource,
          child: const Text('切换站点'),
        ),
      ),
    );
  }

  Widget _feed(BuildContext context) {
    final videos = _videos;
    if (videos.isEmpty) {
      if (_channel == 'adult' && _adultFeed == null) {
        return const SafeArea(
          child: Center(
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
        );
      }
      return SafeArea(
        child: StatusPanel(
          title: _channel == 'follow'
              ? '暂无关注短剧'
              : _channel == 'adult'
              ? '暂无成人视频'
              : '暂无可播短剧',
          message: _channel == 'follow'
              ? '在剧集上点收藏后，这里会显示你关注的短剧。'
              : _channel == 'adult'
              ? '没有可见的成人站，或成人站暂无内容。'
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
        Positioned(top: 0, left: 0, right: 0, child: _feedTopBar()),
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
                  color: _channel == channel.key
                      ? Colors.white
                      : Colors.white70,
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
            if (widget.hideCapsuleBar)
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  key: const ValueKey('feed-back-home'),
                  onPressed: () => _selectTab(_neonHomeTab),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  tooltip: '返回首页',
                ),
              ),
            Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: tabWidgets),
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
                videoId:
                    _details[_keyFor(drama)] != null &&
                        _episode >= 0 &&
                        _episode < _details[_keyFor(drama)]!.episodes.length
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
    final synopsis = detail?.drama.description ?? drama.description;
    final episodeLine = detail != null && _episode < detail.episodes.length
        ? '第${_episode + 1}集 | ${detail.episodes[_episode].title}'
        : null;
    final isComic =
        _channel == 'comic' ||
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
                      style: const TextStyle(color: Colors.white, fontSize: 12),
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
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
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
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                    maxLines: _synopsisExpanded ? null : 2,
                    overflow: _synopsisExpanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                ),
                if (synopsis.length > 80)
                  GestureDetector(
                    onTap: () =>
                        setState(() => _synopsisExpanded = !_synopsisExpanded),
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
              drama.heat.isNotEmpty ? '热度 ${drama.heat}' : '播放 ${drama.views}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
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
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
                    _openPlayback(item, episodeIndex: 0, startPosition: 0),
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
                      style: const TextStyle(color: Colors.white, fontSize: 12),
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

  /// 多媒体页签（内层页签 1，原片单位置）：网盘媒体库，与底部
  /// 标签栏的“多媒体”是同一个屏（见 [MultimediaScreen]）。
  Widget _multimedia(BuildContext context) {
    return MultimediaScreen(
      repository: widget.repository,
      store: widget.store,
      driveSites: widget.driveSites,
      onOpenDrama: widget.onOpenDrama,
      onOpenCloudLogin: widget.onOpenCloudLogin,
      metadataFetcher: widget.metadataFetcher,
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
          ListTile(
            key: const ValueKey('mine-theme-entry'),
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题切换'),
            subtitle: Text(
              '当前：${AppThemeConfig.forTheme(widget.store.appTheme).themeName} · 8 套主题',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              appPageRoute<void>(
                builder: (_) => ThemeSettingsScreen(
                  store: widget.store,
                  repository: widget.repository,
                  sourceId: widget.store.source,
                ),
              ),
            ),
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
