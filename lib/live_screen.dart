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

/// 选中态文字色：用户定的“选中变黄”口径保留这一项；其余配色
/// （面板、卡、格、未选中文字）全部跟随应用主题——改版时写死的
/// 灰绿整页一色已按用户口径删除恢复。
const _liveSelectedText = Color(0xFFFFDF00);

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
  // 手机端视频区占比照截图（约 3:7）；电视端保持原来的 9:14。
  static const _playbackShare = 7;
  static const _listShare = 16;
  static const _tvPlaybackShare = 9;
  static const _tvListShare = 14;

  LiveSource? _source;
  List<LivePlatform> _platforms = const [];
  List<LiveChannel> _channels = const [];
  String _group = '';
  ({String group, List<LiveChannel> channels})? _lastGood;
  bool _loading = true;
  bool _more = false;
  bool _hasMore = false;
  String? _error;
  int _page = 1;
  int _generation = 0;

  /// 可取消的补拉等待：页面销毁时取消计时器，测试的假时钟里不留挂起的 Timer。
  Timer? _retryTimer;
  Completer<void>? _retryCompleter;

  Future<void> _cancellableRetryDelay() async {
    final completer = Completer<void>();
    _retryCompleter = completer;
    _retryTimer = Timer(const Duration(milliseconds: 1500), () {
      _retryTimer = null;
      _retryCompleter = null;
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    if (_retryCompleter == completer) {
      _retryTimer = null;
      _retryCompleter = null;
    }
  }

  void _cancelRetryDelay() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final completer = _retryCompleter;
    _retryCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
  int _consumedEntryNonce = 0;

  /// 进直播待续播的上次观看（只认第一次选源）；频道到货时按 key 找，
  /// 找到播它，找不到回退首频道并清记忆；用户手动换台/换组/换源
  /// 即作废，记忆本身保留。
  LiveLastWatched? _pendingResume;
  String _pendingResumeGroupId = '';
  bool _entryMemoryConsumed = false;

  /// 点播（m3u）当前频道的最后采样位置与上次写盘时的媒体位置；
  /// 换台时清零重采，位置每推进 10 秒媒体进度写一次盘
  /// （不用 DateTime 节流：widget 测试里 DateTime.now 不跟 pump 走）。
  int _lastVodPositionMs = 0;
  int _lastWrittenPositionMs = -1;
  StreamSubscription<Duration>? _vodPositionSubscription;
  String _lastRecordedKey = '';

  /// 进直播那一刻的记忆快照：“上次观看”按钮的目标。
  /// 直播中每次换台都会重记记忆（当前频道），按钮不能跟它走，
  /// 否则永远等于正在播的频道、永不出现。
  LiveLastWatched? _entryResume;
  final _groupTileKeys = <String, GlobalKey>{};
  late final LivePlaybackController _playback;
  final _listKey = GlobalKey<RemoteListState>();
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
    _cancelRetryDelay();
    _rememberChannelOffset();
    _flushVodPosition();
    widget.store.removeListener(_storeChanged);
    widget.appStore?.removeListener(_appStoreChanged);
    _playback.removeListener(_playbackChanged);
    _positionSubscription?.cancel();
    _vodPositionSubscription?.cancel();
    _speedTracker.dispose();
    _playback.dispose();
    _channelScroll.dispose();
    super.dispose();
  }

  void _playbackChanged() {
    _attachSpeedTracker();
    _recordLastWatched();
    if (mounted) setState(() {});
  }

  /// 播放频道一变就记一条上次观看：源 + 分组 + 频道 key/名 + 时间。
  /// 内嵌与全屏共用同一 controller，这里记一次就全覆盖。
  /// 点播位置由位置流另行节流写，不在这里每帧刷盘。
  void _recordLastWatched() {
    final source = _source;
    final channel = _playback.channel;
    if (source == null || channel == null) return;
    final key = channel.key;
    if (key.isEmpty || key == _lastRecordedKey) return;
    _lastRecordedKey = key;
    // 换台了：旧频道的采样位置作废，新频道从 0 重采。
    _lastVodPositionMs = 0;
    _lastWrittenPositionMs = -1;
    unawaited(
      widget.store.rememberLastWatched(
        sourceId: source.id,
        groupId: _group == _favouritesId ? '' : _group,
        groupName: channel.group,
        channel: channel,
      ),
    );
    _attachVodPosition();
  }

  /// 点播（m3u 文件型）才接位置流：位置每推进 10 秒媒体进度写一次，
  /// 往回跳立即写；换台/离页时以最后采样值刷盘一次；直播流不记位置。
  void _attachVodPosition() {
    if (_vodPositionSubscription != null) return;
    final player = _playback.player;
    if (player == null) return;
    _vodPositionSubscription = player.stream.position.listen((position) {
      if (!mounted) return;
      if (_source?.protocol != LiveProtocol.list) return;
      final channel = _playback.channel;
      if (channel == null || channel.key != _lastRecordedKey) return;
      final ms = position.inMilliseconds;
      if (ms <= 0) return;
      _lastVodPositionMs = ms;
      final lastWritten = _lastWrittenPositionMs;
      if (lastWritten >= 0 && ms >= lastWritten && ms - lastWritten < 10000) {
        return;
      }
      _lastWrittenPositionMs = ms;
      unawaited(widget.store.rememberPosition(ms));
    });
  }

  /// 离页时把最后采到的点播位置刷盘：离页前最后一次落盘机会。
  void _flushVodPosition() {
    if (_source?.protocol != LiveProtocol.list) return;
    if (_lastVodPositionMs <= 0) return;
    unawaited(widget.store.rememberPosition(_lastVodPositionMs));
  }

  /// 记忆分组在当前分组列表里的匹配：先按平台 id，再按平台名
  /// （平台源的 id 是地址串，可能变；名稳定）。收藏里播的频道
  /// 没有分组 id，只按频道自身的 group 名匹配。
  LivePlatform? _platformForMemory(
    List<LivePlatform> platforms,
    LiveLastWatched memory,
  ) {
    if (memory.groupId.isNotEmpty) {
      final byId = platforms
          .where((platform) => platform.id == memory.groupId)
          .firstOrNull;
      if (byId != null) return byId;
    }
    if (memory.groupName.isNotEmpty) {
      return platforms
          .where((platform) => platform.name == memory.groupName)
          .firstOrNull;
    }
    return null;
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
      if (_source != null) unawaited(_loadPlatformsWithAutoRetry());
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
    // 把用户手动切走的源拉回入口源；记忆源同理，只认第一次。
    _consumedEntryNonce = widget.initialSourceNonce;
    LiveLastWatched? memory;
    LiveSource? memorySource;
    final firstEntry = !_entryMemoryConsumed;
    if (firstEntry) {
      _entryMemoryConsumed = true;
      memory = widget.store.lastWatched;
      if (memory != null) {
        final memoryId = memory.sourceId;
        memorySource = visible
            .where((item) => item.id == memoryId)
            .firstOrNull;
        if (memorySource == null && LiveSource.byId(memoryId) == null) {
          // 记忆的源已经不在了（源被删）：清掉失效记忆，走默认源。
          unawaited(widget.store.clearLastWatched());
          memory = null;
        }
      }
      // “上次观看”按钮的目标就是进直播那一刻的记忆快照，
      // 不是直播中不断重记的当前频道。
      _entryResume = memory;
    }
    _source = honorEntry && widget.initialSourceId.isNotEmpty
        ? visible
              .where((item) => item.id == widget.initialSourceId)
              .firstOrNull ??
          memorySource ??
          visible.first
        : memorySource ?? visible.first;
    // 记忆的源就是本次进来的源：频道到货后按 key 续播它。
    if (memory != null && _source?.id == memory.sourceId) {
      _pendingResume = memory;
    } else {
      _pendingResume = null;
    }
    _pendingResumeGroupId = '';
    unawaited(_loadPlatformsWithAutoRetry());
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

  void _applyChannels(
    List<LiveChannel> channels, {
    int index = 0,
    Duration? startAt,
  }) {
    final source = _source;
    _channels = channels;
    if (source == null) return;
    unawaited(
      _playback
          .load(
            source,
            channels,
            index: index,
            autoplay: channels.isNotEmpty,
          )
          .then((_) async {
            // 点播续播：起播完成后再跳位置；位置非法（太靠头/尾、
            // 总时长未知）就从头播，不报错、不卡住。
            final target = startAt;
            if (target == null) return;
            if (source.protocol != LiveProtocol.list) return;
            final duration =
                _playback.player?.state.duration ?? Duration.zero;
            if (duration <= Duration.zero) return;
            if (target <= const Duration(seconds: 5)) return;
            if (target >= duration - const Duration(seconds: 15)) return;
            await _playback.seekTo(target);
          }),
    );
  }

  /// 进直播页 / 切直播源时的自动加载：分类首次请求落空或报错时
  /// 自动补拉（最多再补 2 次），不用用户手动下拉刷新；切源后旧的
  /// 补拉自动作废。分类已取到时不补（频道失败走分组内兜底）。
  Future<void> _loadPlatformsWithAutoRetry({
    bool force = false,
    String keepGroup = '',
  }) async {
    final sourceId = _source?.id;
    await _loadPlatforms(force: force, keepGroup: keepGroup);
    // 首轮加载落定的分组：补拉期间用户已点别的分组就作废，
    // 不能把用户的选组刷回去。
    final group = _group;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!mounted || _loading || _source?.id != sourceId || _group != group) {
        return;
      }
      if (_platforms.isNotEmpty || _error == null) return;
      if (attempt > 0) {
        await _cancellableRetryDelay();
        if (!mounted ||
            _loading ||
            _source?.id != sourceId ||
            _group != group) {
          return;
        }
        if (_platforms.isNotEmpty || _error == null) return;
      }
      await _loadPlatforms(force: true, keepGroup: keepGroup);
    }
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
      // 刷新 keepGroup 优先于记忆；进直播的自动续播（待续播记忆）
      // 优先于分组记忆。
      final pending = _pendingResume;
      final resumeGroup =
          pending != null && pending.sourceId == source.id
          ? _platformForMemory(platforms, pending)
          : null;
      if (pending != null && pending.sourceId == source.id) {
        if (resumeGroup == null) {
          // 记忆的分组已不在：清掉失效记忆，播首分组首频道。
          _pendingResume = null;
          _pendingResumeGroupId = '';
          _entryResume = null;
          unawaited(widget.store.clearLastWatched());
        } else {
          _pendingResumeGroupId = resumeGroup.id;
        }
      } else if (pending != null) {
        // 待续播的源不是当前源：本次不续播，记忆本身保留。
        _pendingResume = null;
        _pendingResumeGroupId = '';
      }
      final remembered = widget.repository.groupMemory.lastGroupFor(source.id);
      final target =
          keepGroup.isNotEmpty &&
              platforms.any((platform) => platform.id == keepGroup)
          ? keepGroup
          : resumeGroup != null
          ? resumeGroup.id
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
    if (id != _pendingResumeGroupId) {
      // 用户手动进了别的分组（或收藏）：本次进直播的自动续播作废，
      // 记忆本身保留，下次进直播还按它续。
      _pendingResume = null;
      _pendingResumeGroupId = '';
    }
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
      // 本次就是待续播的那次加载：按 key 在新列表里找上次频道，
      // 找到播它（含点播位置），找不到回退首频道并清掉记忆。
      var resumeIndex = 0;
      Duration? resumeStart;
      var resumeMissed = false;
      if (!append &&
          _pendingResume != null &&
          id == _pendingResumeGroupId) {
        final pending = _pendingResume!;
        final found = channels.indexWhere(
          (channel) => channel.key == pending.channelKey,
        );
        if (found >= 0) {
          resumeIndex = found;
          if (pending.positionMs > 0) {
            resumeStart = Duration(milliseconds: pending.positionMs);
          }
        } else {
          resumeMissed = true;
        }
        _pendingResume = null;
        _pendingResumeGroupId = '';
      }
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
          index: resumeIndex,
          startAt: resumeStart,
        );
      });
      if (resumeMissed) {
        _entryResume = null;
        unawaited(widget.store.clearLastWatched());
      }
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

  void _changeSource(LiveSource source, {bool cancelResume = true}) {
    if (source.id == _source?.id) return;
    if (cancelResume) {
      _pendingResume = null;
      _pendingResumeGroupId = '';
    }
    _rememberChannelOffset();
    setState(() => _source = source);
    unawaited(_loadPlatformsWithAutoRetry());
  }

  /// “上次观看”入口：记忆源就是当前源 → 进记忆组续播；
  /// 是别的源 → 切源后走同一条续播链；记忆已失效 → 清掉并提示。
  void _resumeLastWatched() {
    final memory = _entryResume;
    if (memory == null) return;
    final target = LiveSource.visible(
      widget.greenMode,
    ).where((item) => item.id == memory.sourceId).firstOrNull;
    if (target == null) {
      // 源不在了：清掉失效记忆，不卡死。
      unawaited(widget.store.clearLastWatched());
      AppNotice.show(context, '上次看的直播源已不在');
      return;
    }
    _pendingResume = memory;
    _pendingResumeGroupId = '';
    if (target.id == _source?.id) {
      final group = _platformForMemory(_platforms, memory);
      if (group == null) {
        _pendingResume = null;
        unawaited(widget.store.clearLastWatched());
        AppNotice.show(context, '上次看的分组已不在');
        return;
      }
      _pendingResumeGroupId = group.id;
      if (group.id == _group) {
        final index = _channels.indexWhere(
          (channel) => channel.key == memory.channelKey,
        );
        if (index >= 0) {
          _pendingResume = null;
          _pendingResumeGroupId = '';
          _open(_channels[index]);
          return;
        }
      }
      unawaited(_loadChannels(group.id, force: group.id == _group));
    } else {
      _changeSource(target, cancelResume: false);
    }
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
    // 画面层绝不卸载重挂：内嵌 Video 全程留在树里，全屏页另挂一个
    // 同 controller 的 Video（同一纹理，两处同时显示）。
    // v56 四处黑屏修的是同一条——全屏时把画面层从旧父级卸掉、挂到
    // 新父级，表面重建后解码器照旧出声、画面全黑；直播全屏是剩下
    // 的一处：以前进全屏先卸内嵌（_detached=true）、退全屏等动画
    // 结束才复位，中间纹理无人持有，手机上直接黑屏。
    // 两个 Video 同挂一个 controller 在安卓上是安全的（同一纹理
    // id，两处 Texture 各自显示；内嵌那处被不透明全屏路由盖住，
    // 不参与绘制）；只有 Web 端有“只显示最后挂载”的限制，本应用
    // 不走 Web。
    await Navigator.push<void>(
      context,
      playerRoute(
        LivePlayerScreen(
          playback: _playback,
          source: source,
          store: widget.store,
          videoBuilder: widget.videoBuilder,
          swipeSeek: () =>
              widget.appStore?.playbackPreferences.swipeSeekSeconds ?? 60,
        ),
      ),
    );
  }

  /// 频道信息单：只列源数据真实带有的字段（频道名/号、源、分组、
  /// 线路、分辨率），没有节目单数据就不写节目名；下面是原来散在
  /// 视频区底部条与面板行里的入口（全屏/换源/刷新/收藏/睡眠定时），
  /// 截图版式里它们不再占常驻位置，改放这里。
  Future<void> _showChannelInfo() async {
    final channel = _playback.channel;
    final source = _source;
    if (source == null) return;
    final size = _playback.videoSize;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) {
        final favourite =
            channel != null && widget.store.isFavourite(channel.key);
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.live_tv_rounded),
                  title: Text(channel?.name ?? '未选择频道'),
                  subtitle: Text(
                    [
                      if (channel != null && channel.number.isNotEmpty)
                        '频道号 ${channel.number}',
                      '直播源 ${source.name}',
                      if (channel != null && channel.group.isNotEmpty)
                        '分组 ${channel.group}',
                    ].join(' · '),
                  ),
                ),
                if (channel != null)
                  ListTile(
                    leading: const Icon(Icons.route_rounded),
                    title: Text(
                      '线路 ${_playback.route + 1}/${channel.urls.length}',
                    ),
                    subtitle: channel.subtitle.isNotEmpty
                        ? Text(channel.subtitle)
                        : null,
                  ),
                if (size != null)
                  ListTile(
                    leading: const Icon(Icons.high_quality_rounded),
                    title: Text(
                      '分辨率 ${size.width.toInt()} x ${size.height.toInt()}',
                    ),
                  ),
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('live-info-fullscreen'),
                  leading: const Icon(Icons.fullscreen_rounded),
                  title: const Text('全屏播放'),
                  onTap: () => Navigator.of(sheetContext).pop('fullscreen'),
                ),
                ListTile(
                  key: const ValueKey('live-info-switch-source'),
                  leading: const Icon(Icons.tv_rounded),
                  title: const Text('切换直播源'),
                  onTap: () => Navigator.of(sheetContext).pop('source'),
                ),
                ListTile(
                  key: const ValueKey('live-info-refresh'),
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('刷新直播'),
                  onTap: () => Navigator.of(sheetContext).pop('refresh'),
                ),
                if (channel != null)
                  ListTile(
                    key: const ValueKey('live-info-favourite'),
                    leading: Icon(
                      favourite
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                    ),
                    title: Text(favourite ? '取消收藏' : '收藏频道'),
                    onTap: () => Navigator.of(sheetContext).pop('favourite'),
                  ),
                ListTile(
                  key: const ValueKey('live-info-sleep'),
                  leading: const Icon(Icons.bedtime_outlined),
                  title: Text(
                    _playback.sleepTimer.active
                        ? '睡眠定时 · ${_playback.sleepTimer.label}'
                        : '睡眠定时',
                  ),
                  onTap: () => Navigator.of(sheetContext).pop('sleep'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    switch (action) {
      case 'fullscreen':
        await _openFullscreen();
      case 'source':
        await _pickSource();
      case 'refresh':
        await _refreshLive();
      case 'favourite':
        final current = _playback.channel;
        if (current != null) widget.store.toggleFavourite(current);
      case 'sleep':
        await _openSleepTimer();
    }
  }

  /// 播放设置单：解码模式（点一下换下一个）、恢复默认、睡眠定时。
  /// 原来视频区底部条里的睡眠定时与已删功能键排的解码/默认入口都在这里。
  Future<void> _showPlaybackSettings() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      key: const ValueKey('live-settings-decoder'),
                      leading: const Icon(Icons.memory_rounded),
                      title: const Text('解码模式'),
                      subtitle: Text(
                        '当前：${_playback.decoderMode.label}，点一下换下一个',
                      ),
                      trailing: Text(_playback.decoderMode.label),
                      onTap: () async {
                        await _playback.setDecoderMode(
                          _playback.decoderMode.next,
                        );
                        setSheetState(() {});
                      },
                    ),
                    ListTile(
                      key: const ValueKey('live-settings-reset'),
                      leading: const Icon(Icons.restart_alt_rounded),
                      title: const Text('恢复默认'),
                      subtitle: const Text('线路回到第 1 条、解码回到自动'),
                      onTap: () => Navigator.of(sheetContext).pop('reset'),
                    ),
                    ListTile(
                      key: const ValueKey('live-settings-sleep'),
                      leading: const Icon(Icons.bedtime_outlined),
                      title: Text(
                        _playback.sleepTimer.active
                            ? '睡眠定时 · ${_playback.sleepTimer.label}'
                            : '睡眠定时',
                      ),
                      onTap: () => Navigator.of(sheetContext).pop('sleep'),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
    if (!mounted) return;
    switch (action) {
      case 'reset':
        final changed = await _playback.resetDefaults();
        if (mounted) {
          AppNotice.show(context, changed ? '已恢复默认设置' : '已经是默认设置');
        }
      case 'sleep':
        await _openSleepTimer();
    }
  }

  Future<void> _openSleepTimer() async {
    await showSleepTimerSheet(
      context,
      controller: _playback.sleepTimer,
      showFinishEpisode: false,
      onSelect: (choice) {
        if (mounted) _playback.sleepTimer.select(choice);
      },
    );
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
        Expanded(
          flex: television ? _tvPlaybackShare : _playbackShare,
          child: _video(context, television),
        ),
        Expanded(
          flex: television ? _tvListShare : _listShare,
          child: _panel(context, television),
        ),
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
          if (widget.videoBuilder != null)
            widget.videoBuilder!(_playback, false)
          else if (controller != null)
            Video(
              controller: controller,
              fit: BoxFit.contain,
              wakelock: false,
              controls: (_) => const SizedBox.shrink(),
            )
          else
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
          else if (television &&
              (_playback.loading || _playback.buffering))
            const Center(
              child: SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
          // 电视端保持原来的底部信息条与分组名角标，不动。
          if (television &&
              _playback.channel != null &&
              error == null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _nowPlaying(context),
            ),
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
          // 手机端播放区：中间居中转圈/速率 + 顶部频道名/分辨率/信息/设置。
          // 顶栏画在错误遮罩之上，断流时照样能点信息换源；中间层只在无错时显示。
          if (!television) ...[
            if (error == null) _videoCenterOverlay(context),
            _videoHeader(context),
          ],
        ],
      ),
    );
  }

  /// 截图播放区顶栏：左频道名，右真实分辨率（拿不到就不显示）+
  /// 信息 + 设置。顶栏本身不拦手势，只有两个按钮吃点按，其余位置
  /// 仍落到下面的全屏手势层。
  Widget _videoHeader(BuildContext context) {
    final channel = _playback.channel;
    final size = _playback.videoSize;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                channel?.name ?? _source?.name ?? '直播',
                key: const ValueKey('live-video-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _videoOverlayStyle.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (size != null)
              Text(
                '[ ${size.width.toInt()} x ${size.height.toInt()} ]',
                key: const ValueKey('live-video-resolution'),
                style: _videoOverlayStyle,
              ),
            IconButton(
              key: const ValueKey('live-video-info'),
              visualDensity: VisualDensity.compact,
              tooltip: '频道信息',
              onPressed: _showChannelInfo,
              icon: const Icon(
                Icons.info_outlined,
                size: 22,
                color: Colors.white,
              ),
            ),
            IconButton(
              key: const ValueKey('live-video-settings'),
              visualDensity: VisualDensity.compact,
              tooltip: '播放设置',
              onPressed: _showPlaybackSettings,
              icon: const Icon(
                Icons.settings_outlined,
                size: 22,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 播放区中间层（恢复改版前口径）：缓冲时只有正中心一个 34×34
  /// 转圈 + 下方实时速率，没有大播放三角——改版时加的 72px 三角
  /// 把转圈挤到右上角，用户实拍截图里两者不在同一中心。暂停态
  /// 也不盖三角（改版前就没有），点画面本身切换播放/暂停。
  Widget _videoCenterOverlay(BuildContext context) {
    if (_playback.loading || _playback.buffering) {
      return Center(
        key: const ValueKey('live-center-overlay'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              key: ValueKey('live-center-spinner'),
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<String?>(
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
          ],
        ),
      );
    }
    return const SizedBox.shrink();
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

  /// “上次观看”入口：有记忆、且不是正在播的那个频道时才显示。
  /// 目标取进直播那一刻的记忆快照，不是直播中不断重记的当前频道。
  LiveLastWatched? get _resumeEntry {
    final memory = _entryResume;
    if (memory == null) return null;
    if (_playback.channel?.key == memory.channelKey) return null;
    return memory;
  }

  Widget _resumeRow(BuildContext context) {
    final memory = _resumeEntry!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('live-resume-button'),
          onPressed: _resumeLastWatched,
          icon: const Icon(Icons.history_rounded),
          label: Text(
            '上次观看：${memory.channelName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context, bool television) {
    // 电视端保持原来的面板（频道卡 + 上次观看 + 收藏/分类/刷新行 +
    // 遥控列表），只改手机端。
    if (television) {
      return Column(
        children: [
          _current(context),
          if (_resumeEntry != null) _resumeRow(context),
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
                    label: Text(
                      '直播收藏（${widget.store.favourites.length}）',
                    ),
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
    }
    // 配色恢复改版前口径：面板不铺自己的底色，透出页面背景跟随
    // 应用主题。改版时写死的灰绿渐变（_livePanelTop/_livePanelBottom）
    // 让整页下半部一个颜色，用户明确说没让改成一样的，已删。
    return Column(
      children: [
        _infoCards(context),
        if (_resumeEntry != null) _resumeRow(context),
        Expanded(child: _lists(context, television)),
      ],
    );
  }

  /// 播放区下方一行：左卡大频道号 + 频道名，中卡“正在播放 /
  /// 即将播放”，右端 46px 切源按钮卡（恢复改版前 _current 卡右端
  /// 的直达按钮：key live-source-button、电视图标、点开 _pickSource；
  /// 改版时手机端把它删了、切源只能绕 ⓘ 信息单）。
  /// 节目信息按用户口径接真数据：“正在播放”= 当前条目标题
  /// （subtitle 是另一份真实信息且与标题不同才拼在后面）；“即将
  /// 播放”= 频道列表里下一条的标题。App 里没有任何节目单（EPG）
  /// 数据模型，电视源也只有频道名/台标/地址，所以“即将播放”对
  /// 所有源都按下一条口径；列表到尾、没有下一条才写“暂无节目
  /// 信息”。卡面与文字跟随应用主题（改版前口径）。
  Widget _infoCards(BuildContext context) {
    final theme = Theme.of(context);
    final cardColor = theme.colorScheme.surfaceContainerHighest;
    final textColor = theme.colorScheme.onSurface;
    final channel = _playback.channel;
    final number = channel == null
        ? '--'
        : channel.number.isNotEmpty
        ? channel.number
        : '${_playback.index + 1}'.padLeft(3, '0');
    final now = channel == null
        ? '暂无节目信息'
        : channel.subtitle.isNotEmpty && channel.subtitle != channel.name
        ? '${channel.name} · ${channel.subtitle}'
        : channel.name;
    final channels = _playback.channels;
    final nextIndex = _playback.index + 1;
    final next = channel != null && nextIndex < channels.length
        ? channels[nextIndex].name
        : '暂无节目信息';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      // 两卡等高：Row 在竖向 Column 里高度无界，不能直接 stretch，
      // 先由 IntrinsicHeight 按最高那张卡定高，再拉伸另一张。
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          Expanded(
            flex: 25,
            child: Material(
              key: const ValueKey('live-number-card'),
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 大号数字也等比缩小装下，不用省略号截断：右端加了
                    // 切源按钮后左卡变窄，34px 的三位号会溢出，省略号
                    // 在子集字体环境里会整行画空（预览图实测），真机上
                    // 也会截成半个号。FittedBox 与下面频道名同口径。
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        number,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 34,
                          fontWeight: FontWeight.bold,
                          fontFeatures: const [
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    // 左卡窄，频道名一行放不下会被截成“CCTV-1 …”，
                    // 截图里是整名：等比缩小整名显示，不换行不截断。
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        channel?.name ?? '未选择频道',
                        maxLines: 1,
                        style: TextStyle(color: textColor, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 70,
            child: Material(
              key: const ValueKey('live-epg-card'),
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '正在播放：$now',
                      key: const ValueKey('live-epg-now'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: textColor, fontSize: 13),
                    ),
                    Divider(color: theme.dividerColor, height: 12),
                    Text(
                      '即将播放：$next',
                      key: const ValueKey('live-epg-next'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: textColor, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 46,
            child: Material(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              child: IconButton(
                key: const ValueKey('live-source-button'),
                tooltip: '切换直播源',
                onPressed: _pickSource,
                icon: const Icon(Icons.tv_rounded),
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }

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
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 78,
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
        if (_channels.isEmpty) {
          return StatusPanel(
            title: '还没有收藏频道',
            message: '播放时点星标即可加入收藏。',
            icon: Icons.live_tv_rounded,
          );
        }
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
    return _grid(context, entries);
  }

  /// 三列区：左分组/收藏、中频道（同行对齐、同一个列表一起滚，
  /// 频道列已按用户口径缩窄）、右预览区（固定不滚，见 _previewPane）。
  /// 选中项黄字（用户口径保留）、未选中跟主题正文色；行数取左中
  /// 两列中最长的一列，短的列空着。频道多时滑到底自动续载。
  Widget _grid(
    BuildContext context,
    List<({String id, String name, int count})> entries,
  ) {
    if (_loading && _channels.isEmpty) {
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
    if (_channels.isEmpty) {
      return StatusPanel(
        title: _group == _favouritesId ? '还没有收藏频道' : '没有可用频道',
        message: _group == _favouritesId
            ? '播放时点星标即可加入收藏。'
            : '可以切换其他分类或直播源。',
        icon: Icons.live_tv_rounded,
      );
    }
    final current = _playback.channel;
    final lineCount = current?.urls.length ?? 0;
    // 只有直连型源（面板/列表）支持同一频道内切线路；api 型源
    // 的线路走仓库解析，切线重播没有意义，线路按钮只作展示、不点。
    final multiRoute =
        _source?.protocol == LiveProtocol.pingtai ||
        _source?.protocol == LiveProtocol.list;
    var rows = entries.length;
    if (_channels.length > rows) rows = _channels.length;
    // 布局（用户口径）：左分组列 + 中频道列同行对齐、一起滚，频道
    // 列比改版时缩窄；右侧整块让给预览区（见 _previewPane），不再
    // 逐行排线路格。行数取左中两列中最长的一列，短的列空着。
    // 频道多时滑到底自动续载（与原来频道列一致）。
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 55,
            child: NotificationListener<ScrollNotification>(
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
                key: const ValueKey('live-grid'),
                controller: _channelScroll,
                padding: EdgeInsets.zero,
                itemCount: rows + (_more ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= rows) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 25,
                          child: _groupCell(context, entries, index),
                        ),
                        const SizedBox(width: 6),
                        Expanded(flex: 30, child: _channelCell(context, index)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 45,
            child: _previewPane(context, lineCount, multiRoute),
          ),
        ],
      ),
    );
  }

  /// 右侧预览区（用户口径）：放正在播的实时画面 + 帧率。画面与
  /// 上方播放区共用同一个播放器（同一纹理的镜像显示），是真实时
  /// 流、不是封面图或静态图；切线路换的也是这一个播放器的地址，
  /// 上方与预览区同步换台。线路切换收在预览下方的小按钮排里
  /// （逐行线路格退役后线路不能没地方切）。分辨率与帧率一行小字
  /// 显示在按钮排下方：分辨率来自 videoParams、帧率来自 mpv
  /// 属性，哪个没拿到就不显示哪个，绝不编数。
  Widget _previewPane(BuildContext context, int lineCount, bool multiRoute) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _playback.controller;
    final size = _playback.videoSize;
    final fps = _playback.videoFps;
    final stats = [
      if (size != null) '${size.width.toInt()} x ${size.height.toInt()}',
      if (fps != null) '${fps.round()} 帧/秒',
    ].join(' · ');
    return Material(
      key: const ValueKey('live-preview-pane'),
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 注意：这里不用 widget.videoBuilder 那个测试接缝——
                    // 它的契约是“主播放面有且只有一个”（全屏退出流程
                    // 靠这个不变量），预览镜像面只能用真 Video；测试
                    // 环境没有真控制器时落占位，不造第二个假面。
                    if (controller != null)
                      Video(
                        controller: controller,
                        fit: BoxFit.contain,
                        wakelock: false,
                        controls: (_) => const SizedBox.shrink(),
                      )
                    else
                      Center(
                        child: Text(
                          _playback.channel == null
                              ? '选择频道后这里实时预览'
                              : '实时预览',
                          style: const TextStyle(
                            color: Color(0xFF8B8F99),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (_playback.buffering)
                      const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (lineCount > 0)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < lineCount; i++)
                    _routeChip(context, i, multiRoute),
                ],
              )
            else
              Text(
                '暂无线路',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            const SizedBox(height: 6),
            Text(
              _playback.channel == null
                  ? ''
                  : stats.isEmpty
                  ? '参数读取中…'
                  : stats,
              key: const ValueKey('live-preview-stats'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 预览区下方的线路小按钮：选中态跟全页口径一致（主题选中底
  /// 色 + 黄字），未选中描边 + 主题正文色。
  Widget _routeChip(BuildContext context, int index, bool multiRoute) {
    final scheme = Theme.of(context).colorScheme;
    final selected = multiRoute && index == _playback.route;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        border: Border.all(
          color: selected ? scheme.primaryContainer : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '线路${index + 1}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? _liveSelectedText : scheme.onSurface,
        ),
      ),
    );
    if (!multiRoute) return chip;
    return InkWell(
      key: ValueKey('live-line-$index'),
      onTap: () => unawaited(_playback.playRoute(index)),
      child: chip,
    );
  }

  Widget _gridCell(
    BuildContext context, {
    required bool selected,
    required Widget child,
  }) => Container(
    height: 48,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: child,
  );

  TextStyle _gridCellText(BuildContext context, bool selected) => TextStyle(
    fontSize: 13,
    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
    color: selected
        ? _liveSelectedText
        : Theme.of(context).colorScheme.onSurface,
  );

  Widget _groupCell(
    BuildContext context,
    List<({String id, String name, int count})> entries,
    int index,
  ) {
    if (index >= entries.length) return const SizedBox(height: 48);
    final scheme = Theme.of(context).colorScheme;
    final entry = entries[index];
    final selected = entry.id == _group;
    return InkWell(
      key: ValueKey('live-group-${entry.id}'),
      onTap: () => _loadChannels(entry.id),
      child: Container(
        key: _groupTileKeys.putIfAbsent(entry.id, GlobalKey.new),
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              entry.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _gridCellText(context, selected),
            ),
            // 分组频道数只显示源数据真实带有的 count，没有就不画。
            if (entry.count > 0)
              Text(
                '${entry.count} 个',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: selected
                      ? _liveSelectedText.withValues(alpha: .85)
                      : scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _channelCell(BuildContext context, int index) {
    if (index >= _channels.length) return const SizedBox(height: 48);
    final channel = _channels[index];
    final selected = channel.key == _playback.channel?.key;
    return InkWell(
      key: ValueKey('live-channel-${channel.key}'),
      onTap: () => _open(channel),
      child: _gridCell(
        context,
        selected: selected,
        child: Text(
          channel.name,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _gridCellText(context, selected),
        ),
      ),
    );
  }
}

/// 时钟格式函数（liveClockDateLine/liveClockTimeLine）仍在文件顶部，
/// 供单测钉住格式；视频区角标时钟已随截图版式撤掉（手机状态栏已有时间）。
