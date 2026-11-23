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
    _groupScroll.dispose();
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

  Widget _panel(BuildContext context, bool television) => Column(
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
