import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'app_layout.dart';
import 'app_notice.dart';
import 'core_bridge.dart';
import 'live_models.dart';
import 'live_playback.dart';
import 'live_player_screen.dart';
import 'live_repository.dart';
import 'live_sources.dart';
import 'live_store.dart';
import 'local_store.dart';
import 'network_speed.dart';
import 'player_route.dart';
import 'remote_widgets.dart';
import 'source_picker_sheet.dart';
import 'widgets.dart';
import 'sleep_timer.dart';

/// 视频区右上角时钟的两行文案：日期行 `M/d 周X`、时间行 `HH:mm:ss`。
/// 纯函数，方便单测钉住格式；界面上的秒级刷新由 [_LiveClock] 自己计时。
String liveClockDateLine(DateTime time) {
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return '${time.month}/${time.day} ${weekdays[time.weekday - 1]}';
}

String liveClockTimeLine(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

/// 视频区角标文字：白字加暗色阴影，压在视频画面上仍可读。
const _videoOverlayStyle = TextStyle(
  color: Colors.white,
  fontSize: 12,
  fontFeatures: [FontFeature.tabularFigures()],
  shadows: [Shadow(color: Color(0xCC000000), blurRadius: 4)],
);

class LiveScreen extends StatefulWidget {
  const LiveScreen({
    super.key,
    required this.repository,
    required this.store,
    this.greenMode = true,
    this.onExitLeft,
    this.appStore,
    this.playbackController,
    this.videoBuilder,
    this.initialSourceId = '',
    this.initialSourceNonce = 0,
  });

  final LiveRepository repository;
  final LiveStore store;
  final bool greenMode;
  final VoidCallback? onExitLeft;
  final LocalStore? appStore;

  /// 订阅双入口递进来的直播源：首页切区时带上，直播页首选该源。
  /// [initialSourceNonce] 每递一次加一，已挂载的直播页靠它识别新请求。
  final String initialSourceId;
  final int initialSourceNonce;

  /// 测试注入：传了就用现成的播放控制器，不再自建。
  final LivePlaybackController? playbackController;

  /// 测试注入：传了就用它画播放画面，代替真实 Video（真机原生层
  /// 在测试环境建不起来）；不传则走真实 Video，行为不变。
  final Widget Function(LivePlaybackController playback, bool fullscreen)?
  videoBuilder;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  static const _favouritesId = '__favourites';
  static const _playbackShare = 9;
  static const _listShare = 14;

  LiveSource? _source;
  List<LivePlatform> _platforms = const [];
  List<LiveChannel> _channels = const [];
  String _group = '';
  ({String group, List<LiveChannel> channels})? _lastGood;
  bool _loading = true;
  bool _detached = false;
  bool _more = false;
  bool _hasMore = false;
  String? _error;
  int _page = 1;
  int _generation = 0;
  int _consumedEntryNonce = 0;
  final _groupTileKeys = <String, GlobalKey>{};
  late final LivePlaybackController _playback;
  final _listKey = GlobalKey<RemoteListState>();
  final _groupScroll = ScrollController();
  final _channelScroll = ScrollController();
  late final NetworkSpeedTracker _speedTracker;
  StreamSubscription<Duration>? _positionSubscription;

  @override
  void initState() {
    super.initState();
    _playback =
        widget.playbackController ??
        LivePlaybackController(repository: widget.repository);
    _playback.addListener(_playbackChanged);
    _speedTracker = NetworkSpeedTracker(
      sample: () async {
        final player = _playback.player;
        if (player == null) return null;
        return fetchMpvNetworkSpeedSample(player);
      },
    );
    _attachSpeedTracker();
    widget.store.addListener(_storeChanged);
    widget.appStore?.addListener(_appStoreChanged);
    _syncSources(honorEntry: true);
  }

  /// 播放器出现后开始跟进度采样网速：位置流每次推进就 tick 一次，
  /// 追踪器内部 900ms 节流；播放器尚未建立时等下一次状态通知再接。
  void _attachSpeedTracker() {
    if (_positionSubscription != null) return;
    final player = _playback.player;
    if (player == null) return;
    _positionSubscription = player.stream.position.listen(
      (_) => unawaited(_speedTracker.tick()),
    );
  }

  void _appStoreChanged() {
    if (!mounted) return;
    final visible = LiveSource.visible(widget.greenMode);
    if (_source != null && !visible.any((item) => item.id == _source!.id)) {
      _syncSources();
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _rememberChannelOffset();
    widget.store.removeListener(_storeChanged);
    widget.appStore?.removeListener(_appStoreChanged);
    _playback.removeListener(_playbackChanged);
    _positionSubscription?.cancel();
    _speedTracker.dispose();
    _playback.dispose();
    _groupScroll.dispose();
    _channelScroll.dispose();
    super.dispose();
  }

  void _playbackChanged() {
    _attachSpeedTracker();
    if (mounted) setState(() {});
  }

  void _storeChanged() {
    if (!mounted) return;
    // 只同步列表内容，不重建播放，否则刚点开的频道会被重置回第一条。
    setState(() {
      if (_group == _favouritesId) _channels = widget.store.favourites;
    });
    // 绿色模式开关会整源改变可见集合，必须重算当前源。
    final visible = LiveSource.visible(widget.greenMode);
    if (visible.isEmpty || !visible.any((item) => item.id == _source?.id)) {
      setState(() {
        _source = visible.isEmpty ? null : visible.first;
        _platforms = const [];
        _channels = const [];
        _group = '';
        _lastGood = null;
        _error = null;
      });
      if (_source != null) unawaited(_loadPlatforms());
    }
  }

  /// 绿色模式可能把直播源全部挡掉，此时保持空态，不能在 `.first` 上抛异常。
  @override
  void didUpdateWidget(covariant LiveScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 订阅双入口的新请求（nonce 变化）：已挂载时直接切到该直播源；
    // 源不可见时忽略，用户仍可用源选择器自选。
    if (widget.initialSourceNonce != _consumedEntryNonce &&
        widget.initialSourceId.isNotEmpty) {
      _consumedEntryNonce = widget.initialSourceNonce;
      final target = LiveSource.visible(
        widget.greenMode,
      ).where((item) => item.id == widget.initialSourceId).firstOrNull;
      if (target != null && target.id != _source?.id) {
        _changeSource(target);
      }
    }
    // 分级限制开关会在运行中改变可见源：开关打开时把全部源挡掉，关掉后
    // 又该重新出现，所以必须跟着重算，否则直播页会一直停在空态。
    if (oldWidget.greenMode == widget.greenMode || _source != null) return;
    _syncSources();
  }

  void _syncSources({bool honorEntry = false}) {
    final visible = LiveSource.visible(widget.greenMode);
    if (visible.isEmpty) {
      setState(() {
        _source = null;
        _loading = false;
        _platforms = const [];
        _channels = const [];
      });
      return;
    }
    // 首挂时 honorEntry 才认递进来的源：后续重算（源被挡掉等）不再
    // 把用户手动切走的源拉回入口源。
    _consumedEntryNonce = widget.initialSourceNonce;
    _source = honorEntry && widget.initialSourceId.isNotEmpty
        ? visible
              .where((item) => item.id == widget.initialSourceId)
              .firstOrNull ??
          visible.first
        : visible.first;
    unawaited(_loadPlatforms());
  }

  List<({String id, String name, int count})> get _entries => [
    (id: _favouritesId, name: '收藏', count: widget.store.favourites.length),
    for (final platform in _platforms)
      (id: platform.id, name: platform.name, count: platform.count),
  ];

  String get _groupName =>
      _entries
          .where((entry) => entry.id == _group)
          .map((entry) => entry.name)
          .firstOrNull ??
      '直播';

  void _applyChannels(List<LiveChannel> channels) {
    final source = _source;
    _channels = channels;
    if (source == null) return;
    unawaited(_playback.load(source, channels, autoplay: channels.isNotEmpty));
  }

  Future<void> _loadPlatforms({
    bool force = false,
    String keepGroup = '',
  }) async {
    final source = _source;
    if (source == null) return;
    final token = ++_generation;
    widget.repository.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _platforms = const [];
      _channels = const [];
      _group = '';
      _lastGood = null;
      _page = 1;
    });
    try {
      final platforms = _visiblePlatforms(
        await widget.repository.platforms(source, force: force),
      );
      if (!mounted || token != _generation) return;
      if (platforms.isEmpty) throw AppFailure('该直播源没有可用分类');
      setState(() {
        _platforms = platforms;
        _loading = false;
      });
      // 手机端切源回来落到上次看的分组（电视端保持首分组原行为）；
      // 刷新 keepGroup 优先于记忆。
      final remembered = widget.repository.groupMemory.lastGroupFor(source.id);
      final target =
          keepGroup.isNotEmpty &&
              platforms.any((platform) => platform.id == keepGroup)
          ? keepGroup
          : !AppLayout.isTelevision(context) &&
                remembered.isNotEmpty &&
                platforms.any((platform) => platform.id == remembered)
          ? remembered
          : platforms.first.id;
      await _loadChannels(target, force: force);
      _revealSelectedGroup();
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _loadChannels(
    String id, {
    bool append = false,
    bool force = false,
  }) async {
    final source = _source;
    if (source == null) return;
    if (id == _favouritesId) {
      _generation++;
      widget.repository.cancel();
      final channels = widget.store.favourites;
      _lastGood = (group: id, channels: channels);
      // 切到收藏只换列表，不打断正在播放的频道。
      setState(() {
        _group = id;
        _channels = channels;
        _error = null;
        _loading = false;
        _more = false;
        _hasMore = false;
      });
      return;
    }
    final platform = _platforms.where((entry) => entry.id == id).firstOrNull;
    if (platform == null) return;
    if (append && !_hasMore) return;
    if (!append && !force && id == _group) return;
    if (!append) {
      // 切分组前记下当前分组的滚动位置，回来时恢复，不丢位置。
      _rememberChannelOffset();
      _lastGood = (group: _group, channels: _channels);
    }
    final page = append ? _page + 1 : 1;
    setState(() {
      _group = id;
      _error = null;
      _more = append;
      if (!append) {
        _loading = true;
        _hasMore = false;
        _channels = const [];
      }
    });
    final token = _generation;
    try {
      final channels = await widget.repository.channels(
        source,
        platform,
        page: page,
        force: force,
      );
      if (!mounted || token != _generation) return;
      if (!append) _lastGood = (group: id, channels: channels);
      setState(() {
        _page = page;
        _loading = false;
        _more = false;
        _hasMore = _source!.paginated && channels.length >= 24;
        _applyChannels(
          append && !_playback.ready
              ? [..._channels, ...channels]
              : append
              ? [..._playback.channels, ...channels]
              : channels,
        );
      });
      if (!append) {
        widget.repository.groupMemory.rememberGroup(source.id, id);
        _restoreChannelOffset(id);
      }
    } catch (error) {
      if (!mounted || token != _generation) return;
      final restore = _lastGood;
      final fallback =
          !append && restore != null && restore.channels.isNotEmpty;
      setState(() {
        _loading = false;
        _more = false;
        if (fallback) {
          _group = restore.group;
          _channels = restore.channels;
          _error = null;
        } else {
          _error = '$error';
        }
      });
      if (fallback && mounted) {
        AppNotice.show(context, '${platform.name} 暂时不可用，已保留原分类');
      }
    }
  }

  /// 手动刷新：强制重新抓取直播分类与当前分类的频道列表，
  /// 不读 LiveRepository 的会话内缓存。
  Future<void> _refreshLive() async {
    if (_loading) return;
    if (_group == _favouritesId) {
      setState(() => _channels = widget.store.favourites);
      return;
    }
    await _loadPlatforms(force: true, keepGroup: _group);
  }

  void _changeSource(LiveSource source) {
    if (source.id == _source?.id) return;
    _rememberChannelOffset();
    setState(() => _source = source);
    _loadPlatforms();
  }

  /// 记下当前分组的频道列表滚动位置（换台/切分组/切源/离页时调）。
  void _rememberChannelOffset() {
    final source = _source;
    if (source == null || _group.isEmpty || !_channelScroll.hasClients) {
      return;
    }
    widget.repository.groupMemory.rememberOffset(
      source.id,
      _group,
      _channelScroll.offset,
    );
  }

  /// 分组列表加载完后恢复该分组记下的滚动位置（夹在列表可滚范围内）。
  void _restoreChannelOffset(String groupId) {
    final source = _source;
    if (source == null) return;
    final saved = widget.repository.groupMemory.offsetFor(source.id, groupId);
    if (saved <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_channelScroll.hasClients) return;
      _channelScroll.jumpTo(
        saved.clamp(0, _channelScroll.position.maxScrollExtent),
      );
    });
  }

  /// 切源加载完后把当前分组滚进分组栏视野（分组多时当前分组可能在屏外）。
  void _revealSelectedGroup() {
    final key = _groupTileKeys[_group];
    if (key == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tileContext = key.currentContext;
      if (!mounted || tileContext == null) return;
      unawaited(
        Scrollable.ensureVisible(
          tileContext,
          duration: const Duration(milliseconds: 200),
        ),
      );
    });
  }

  void _open(LiveChannel channel) {
    final index = _playback.channels.indexWhere(
      (entry) => entry.key == channel.key,
    );
    if (index >= 0) {
      unawaited(_playback.play(index));
      return;
    }
    final local = _channels.indexWhere((entry) => entry.key == channel.key);
    if (local < 0) return;
    final playing = _source;
    if (playing == null) return;
    unawaited(_playback.load(playing, _channels, index: local));
  }

  Future<void> _openFullscreen() async {
    final source = _source;
    if (source == null) return;
    if (_playback.channel == null || _playback.channels.isEmpty) return;
    setState(() => _detached = true);
    final route = playerRoute(
      LivePlayerScreen(
        playback: _playback,
        source: source,
        store: widget.store,
        videoBuilder: widget.videoBuilder,
      ),
    );
    await Navigator.push<void>(context, route);
    // push Future 在退场动画开始前就完成（Route.didComplete 在动画前调），
    // 必须等动画彻底结束（路由卸载、全屏 Video 已卸）再复位，否则
    // 退场过渡期间内嵌 Video 与全屏 Video 同挂一个 controller。
    await _waitForRouteDismissed(route);
    if (mounted) setState(() => _detached = false);
  }

  Future<void> _waitForRouteDismissed(Route<void> route) {
    final transitionRoute = route is TransitionRoute<void> ? route : null;
    final animation = transitionRoute?.animation;
    if (animation == null || animation.status == AnimationStatus.dismissed) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    late final void Function(AnimationStatus) listener;
    listener = (status) {
      if (status == AnimationStatus.dismissed && !completer.isCompleted) {
        animation.removeStatusListener(listener);
        completer.complete();
      }
    };
    animation.addStatusListener(listener);
    return completer.future;
  }

  List<LiveSource> get _sources => LiveSource.visible(widget.greenMode);

  /// 绿色模式下隐藏成人分类，收藏入口始终保留在最前。
  /// 主流直播源的分类是分区/游戏名，不在白名单里，按源的
  /// greenCategoryFilter 决定是否过滤；成人源与导入源保持默认过滤。
  List<LivePlatform> _visiblePlatforms(List<LivePlatform> platforms) => [
    for (final platform in platforms)
      if (_source?.greenCategoryFilter != true ||
          !LiveSource.hidesCategory(
            platform.name,
            greenMode: widget.greenMode,
          ))
        platform,
  ];

  Future<void> _pickSource() async {
    final sources = _sources;
    final builtin = [
      for (final source in sources)
        if (source.builtin) source,
    ];
    final imported = [
      for (final source in sources)
        if (!source.builtin) source,
    ];
    final grouped = builtin.isNotEmpty && imported.isNotEmpty;
    final picked = await showSitePickerDialog(
      context,
      sectionName: '直播',
      currentId: _source?.id ?? '',
      groups: [
        if (builtin.isNotEmpty)
          SourcePickerGroup(
            title: grouped ? '平台源' : '',
            entries: [
              for (final source in builtin)
                SourcePickerEntry(id: source.id, name: source.name),
            ],
          ),
        if (imported.isNotEmpty)
          SourcePickerGroup(
            title: grouped ? '导入源' : '',
            entries: [
              for (final source in imported)
                SourcePickerEntry(id: source.id, name: source.name),
            ],
          ),
      ],
    );
    if (picked == null || !mounted) return;
    final source = sources.where((source) => source.id == picked).firstOrNull;
    if (source != null) _changeSource(source);
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    if (_source == null) {
      return StatusPanel(
        key: const ValueKey('live-green-empty'),
        title: '暂无可用直播源',
        message: '当前没有可用的直播源。',
        icon: Icons.verified_user_outlined,
      );
    }
    return Column(
      children: [
        Expanded(flex: _playbackShare, child: _video(context, television)),
        Expanded(flex: _listShare, child: _panel(context, television)),
      ],
    );
  }

  Widget _video(BuildContext context, bool television) {
    final controller = _playback.controller;
    final error = _playback.error;
    return ColoredBox(
      key: const ValueKey('live-stage'),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.videoBuilder != null && !_detached)
            widget.videoBuilder!(_playback, false)
          else if (controller != null && !_detached)
            Video(
              controller: controller,
              fit: BoxFit.contain,
              wakelock: false,
              controls: (_) => const SizedBox.shrink(),
            )
          else if (!_detached)
            const Center(
              child: Text(
                '选择频道开始播放',
                style: TextStyle(color: Color(0xFF8B8F99), fontSize: 12),
              ),
            ),
          if (error == null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openFullscreen,
                onDoubleTap: () => unawaited(_playback.retry()),
                child: const SizedBox.expand(),
              ),
            ),
          if (error != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: .82),
                child: StatusPanel(
                  title: '直播暂时中断',
                  message: error,
                  icon: Icons.wifi_off_rounded,
                  action: '重新连接',
                  onRetry: () => unawaited(_playback.retry()),
                ),
              ),
            )
          else if (_playback.loading || _playback.buffering)
            const Center(
              child: SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
          if (_playback.channel != null && error == null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _nowPlaying(context),
            ),
          // 视频区角标：左上实时网速、右上日期时间。内嵌舞台没有控制层
          // 可跟随、点按要保留进全屏，所以角标常驻显示；全屏里网速本就
          // 在控制条里、随控制层显隐。电视端保留原有的分组名角标，不叠加。
          if (!television && _playback.channel != null && error == null) ...[
            Positioned(
              top: 8,
              left: 10,
              child: IgnorePointer(
                child: ValueListenableBuilder<String?>(
                  valueListenable: _speedTracker.speedText,
                  builder: (_, text, _) {
                    if (text == null || text.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Text(
                      text,
                      key: const ValueKey('live-speed-badge'),
                      style: _videoOverlayStyle,
                    );
                  },
                ),
              ),
            ),
            const Positioned(
              top: 8,
              right: 10,
              child: IgnorePointer(child: _LiveClock()),
            ),
          ],
          if (television)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _groupName,
                      style: const TextStyle(
                        color: Color(0xCCFFFFFF),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _nowPlaying(BuildContext context) {
    final channel = _playback.channel!;
    final favourite = widget.store.isFavourite(channel.key);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 4, 4),
        child: Row(
          children: [
            Text(
              channel.number,
              style: const TextStyle(
                color: Color(0xB3FFFFFF),
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              channel.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (channel.subtitle.isNotEmpty) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  channel.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 12,
                  ),
                ),
              ),
            ] else
              const Spacer(),
            if (channel.urls.length > 1)
              Text(
                '线路 ${channel.urls.length}',
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
              ),
            // 内嵌播放器此前只能靠点视频区域进全屏，没有可见入口；点播详情页
            // 的顶部播放器一直有显式全屏按钮，这里补上以保持一致。
            IconButton(
              key: const ValueKey('live-sleep-timer'),
              visualDensity: VisualDensity.compact,
              tooltip: _playback.sleepTimer.active
                  ? '睡眠定时 · ${_playback.sleepTimer.label}'
                  : '睡眠定时',
              onPressed: () => showSleepTimerSheet(
                context,
                controller: _playback.sleepTimer,
                showFinishEpisode: false,
                onSelect: (choice) {
                  if (mounted) _playback.sleepTimer.select(choice);
                },
              ),
              icon: const Icon(Icons.bedtime_outlined, size: 20),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '全屏与旋转',
              onPressed: () => unawaited(_openFullscreen()),
              icon: const Icon(Icons.screen_rotation_alt_rounded, size: 20),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: favourite ? '取消收藏' : '收藏频道',
              onPressed: () => widget.store.toggleFavourite(channel),
              icon: Icon(
                favourite ? Icons.star_rounded : Icons.star_border_rounded,
                size: 20,
                color: favourite ? Theme.of(context).colorScheme.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel(BuildContext context, bool television) => Column(
    children: [
      _current(context),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                key: const ValueKey('live-favourites-button'),
                onPressed: () => _loadChannels(_favouritesId),
                icon: Icon(
                  _group == _favouritesId
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                ),
                label: Text('直播收藏（${widget.store.favourites.length}）'),
              ),
            ),
            if (_group == _favouritesId)
              TextButton.icon(
                key: const ValueKey('live-categories-button'),
                onPressed: _loadPlatforms,
                icon: const Icon(Icons.list_rounded),
                label: const Text('直播分类'),
              ),
            IconButton(
              key: const ValueKey('live-refresh-button'),
              tooltip: '刷新直播',
              onPressed: _loading ? null : () => unawaited(_refreshLive()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
      Expanded(child: _lists(context, television)),
    ],
  );

  Widget _current(BuildContext context) {
    final theme = Theme.of(context);
    final channel = _playback.channel;
    final logo = channel?.logo ?? '';
    final channelName = channel?.name ?? '';
    // 第二行只显示真实节目信息：源数据带 subtitle（平台源的主播/房间名）
    // 才显示，没有就落回原来的源名·分组·序号说明，绝不编节目单。
    final caption = channel != null && channel.subtitle.isNotEmpty
        ? channel.subtitle
        : _caption();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 86,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 58,
                  height: 58,
                  child: logo.isEmpty
                      ? _logoFallback(theme, channelName)
                      : Image.network(
                          logo,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) =>
                              _logoFallback(theme, channelName),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        channel?.name ?? _groupName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 46,
                  height: 46,
                  child: IconButton(
                    key: const ValueKey('live-source-button'),
                    tooltip: '切换直播源',
                    onPressed: _pickSource,
                    icon: const Icon(Icons.tv_rounded),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _caption() {
    if (_loading) return '载入中…';
    final channel = _playback.channel;
    if (channel == null) return '${_source!.name} · 选择一个频道';
    return '${_source!.name} · ${channel.group} · '
        '${_playback.index + 1}/${_playback.count}';
  }

  /// 无台标时显示频道名的首字；没有频道时沿用原来的 TV 占位。
  Widget _logoFallback(ThemeData theme, String name) => Container(
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
    ),
    alignment: Alignment.center,
    child: Text(
      name.isEmpty ? 'TV' : String.fromCharCode(name.runes.first),
      style: theme.textTheme.titleLarge?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _lists(BuildContext context, bool television) {
    final error = _error;
    if (_group != _favouritesId &&
        _platforms.isEmpty &&
        error != null &&
        !_loading) {
      return StatusPanel(
        title: '${_source!.name} 直播源暂时不可用',
        message: error,
        icon: Icons.wifi_off_rounded,
        onRetry: _loadPlatforms,
      );
    }
    final entries = _entries;
    if (entries.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return StatusPanel(
        title: '没有可用分类',
        message: '可以切换其他直播源。',
        icon: Icons.live_tv_rounded,
      );
    }
    if (television) {
      if (_group == _favouritesId) {
        if (_channels.isEmpty) return _channelList(context);
        final current = _playback.channel?.key;
        return RemoteList(
          key: const ValueKey('live-favourites-list'),
          itemKeys: [for (final channel in _channels) channel.key],
          itemExtent: RemoteListTile.extent,
          onExitLeft: widget.onExitLeft,
          itemBuilder: (_, index, node, onFocus) {
            final channel = _channels[index];
            return RemoteListTile(
              key: ValueKey('live-channel-${channel.key}'),
              title: channel.name,
              subtitle: channel.group,
              leading: const Icon(Icons.star_rounded),
              selected: channel.key == current,
              focusNode: node,
              onFocus: onFocus,
              onPressed: () => _open(channel),
            );
          },
        );
      }
      return RemoteList(
        key: _listKey,
        itemKeys: [for (final entry in entries) entry.id],
        itemExtent: RemoteListTile.extent,
        onExitUp: null,
        onExitLeft: widget.onExitLeft,
        itemBuilder: (_, index, node, onFocus) => RemoteListTile(
          key: ValueKey('live-group-${entries[index].id}'),
          title: entries[index].name,
          subtitle: entries[index].count > 0
              ? '${entries[index].count} 个频道'
              : '',
          selected: entries[index].id == _group,
          focusNode: node,
          onFocus: onFocus,
          onPressed: () => _loadChannels(entries[index].id),
        ),
      );
    }
    return Row(
      children: [
        Expanded(flex: 31, child: _groupRail(context, entries)),
        Expanded(flex: 57, child: _channelPane(context)),
      ],
    );
  }

  Widget _channelPane(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null && _channels.isEmpty) {
      return StatusPanel(
        title: '这个分类暂时不可用',
        message: error,
        icon: Icons.wifi_off_rounded,
        onRetry: () => _loadChannels(_group),
      );
    }
    return _channelList(context);
  }

  Widget _groupRail(
    BuildContext context,
    List<({String id, String name, int count})> entries,
  ) {
    final theme = Theme.of(context);
    return Scrollbar(
      controller: _groupScroll,
      child: ListView.builder(
        key: const ValueKey('live-group-rail'),
        controller: _groupScroll,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          final selected = entry.id == _group;
          return InkWell(
            key: ValueKey('live-group-${entry.id}'),
            onTap: () => _loadChannels(entry.id),
            child: Container(
              key: _groupTileKeys.putIfAbsent(entry.id, GlobalKey.new),
              margin: const EdgeInsets.fromLTRB(12, 2, 6, 2),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(
                color: selected
                    ? theme.colorScheme.primaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  // 分组频道数只显示源数据真实带有的 count，没有就不画。
                  if (entry.count > 0)
                    Text(
                      '${entry.count} 个',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: selected
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _channelList(BuildContext context) {
    final theme = Theme.of(context);
    if (_channels.isEmpty) {
      return StatusPanel(
        title: _group == _favouritesId ? '还没有收藏频道' : '没有可用频道',
        message: _group == _favouritesId ? '播放时点星标即可加入收藏。' : '可以切换其他分类或直播源。',
        icon: Icons.live_tv_rounded,
      );
    }
    final current = _playback.channel?.key;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 600 &&
            !_more &&
            _hasMore &&
            _group != _favouritesId) {
          unawaited(_loadChannels(_group, append: true));
        }
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('live-channel-list'),
        controller: _channelScroll,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _channels.length + (_more ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _channels.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final channel = _channels[index];
          final selected = channel.key == current;
          // 第二行只显示真实信息（房间名/分组/线路数），没有就不画，
          // 绝不编假节目单，见 liveChannelRowCaption。
          final caption = liveChannelRowCaption(
            channel,
            inFavourites: _group == _favouritesId,
          );
          return InkWell(
            key: ValueKey('live-channel-${channel.key}'),
            onTap: () => _open(channel),
            child: Container(
              margin: const EdgeInsets.fromLTRB(6, 2, 12, 2),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
              decoration: BoxDecoration(
                color: selected
                    ? theme.colorScheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    // 当前频道以播放三角代替序号；其余行显示序号。
                    child: selected
                        ? Icon(
                            Icons.play_arrow_rounded,
                            size: 18,
                            color: theme.colorScheme.onSecondaryContainer,
                          )
                        : Text(
                            channel.number,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: selected
                                ? theme.colorScheme.onSecondaryContainer
                                : null,
                          ),
                        ),
                        // 节目行只显示源数据真实带有的信息，没有就不画
                        // 第二行，只留频道名，绝不编假节目单。
                        if (caption.isNotEmpty)
                          Text(
                            caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: selected
                                  ? theme.colorScheme.onSecondaryContainer
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 视频区右上角的日期时间角标：每秒刷新一次，只重建自己这一小块，
/// 不牵动整个直播页。显示设备本地时间，两行：`M/d 周X` 与 `HH:mm:ss`。
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('live-clock'),
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(liveClockDateLine(_now), style: _videoOverlayStyle),
        Text(liveClockTimeLine(_now), style: _videoOverlayStyle),
      ],
    );
  }
}
