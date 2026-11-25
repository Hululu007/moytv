import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'app_layout.dart';
import 'app_notice.dart';
import 'core_bridge.dart';
import 'live_catchup.dart';
import 'live_epg.dart';
import 'live_models.dart';
import 'live_playback.dart';
import 'live_player_screen.dart';
import 'live_repository.dart';
import 'live_sources.dart';
import 'live_store.dart';
import 'local_store.dart';
import 'm3u_subscriptions.dart';
import 'models.dart';
import 'network_speed.dart';
import 'playback_preferences.dart';
import 'player_route.dart';
import 'tvbox_video_pane.dart';
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

  /// 「+」导入进行中：防重复点（选文件/拉远程都是慢操作）。
  bool _importing = false;

  /// 当前源的节目单（源带 epg 地址时才拉）：拉到后信息行改用
  /// 真节目名显示正在播/即将播；拉不到或源没给地址就保持 null，
  /// 信息行走原来的频道名口径，绝不编节目名。
  LiveEpgGuide? _epgGuide;
  String _epgUrl = '';

  /// 节目单到手后每分钟重算一次正在播/即将播（节目到点切换时
  /// 信息行要跟上）；没有节目单时不启这个计时器。
  Timer? _epgTick;
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
    _epgTick?.cancel();
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

  /// 当前源带节目单地址时把节目单跟上：切源/进直播都走
  /// _loadPlatforms，在这里按地址比对——地址没变不重拉，
  /// 变了就换一份；源没给地址就清掉旧节目单，信息行回落
  /// 原来的频道名口径。
  void _syncEpgForSource(LiveSource source) {
    final url = source.epg.trim();
    if (url == _epgUrl) return;
    _epgUrl = url;
    _epgGuide = null;
    _epgTick?.cancel();
    _epgTick = null;
    if (url.isEmpty) return;
    unawaited(_loadEpg());
  }

  Future<void> _loadEpg({bool force = false}) async {
    final url = _epgUrl;
    if (url.isEmpty) return;
    try {
      final guide = await LiveEpgService.instance.load(url, force: force);
      if (!mounted || url != _epgUrl) return;
      setState(() => _epgGuide = guide);
      _epgTick ??= Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted && _epgGuide != null) setState(() {});
      });
    } catch (_) {
      // 节目单是增强项：拉不到就不显示节目名，不打扰用户。
    }
  }

  Future<void> _loadPlatforms({
    bool force = false,
    String keepGroup = '',
  }) async {
    final source = _source;
    if (source == null) return;
    _syncEpgForSource(source);
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
  /// 不读 LiveRepository 的会话内缓存。当前源是远程 m3u 订阅
  /// 时先重新拉取订阅本身（与导入中心的刷新同款），再重读
  /// 本地副本；拉取失败会提示并继续用本地副本刷新。
  Future<void> _refreshLive() async {
    if (_loading) return;
    if (_group == _favouritesId) {
      setState(() => _channels = widget.store.favourites);
      return;
    }
    await _refreshImportedRemote();
    if (_epgUrl.isNotEmpty) unawaited(_loadEpg(force: true));
    await _loadPlatforms(force: true, keepGroup: _group);
  }

  /// 远程 m3u 订阅的手动刷新：按原地址重拉、重解析、写回本地
  /// 副本与订阅记录。不是远程订阅（本地文件/内置源）直接跳过。
  Future<void> _refreshImportedRemote() async {
    final store = widget.appStore;
    final source = _source;
    if (store == null || source == null || !source.id.startsWith('m3u:')) {
      return;
    }
    final sub = store.m3uSubscriptions
        .where((item) => item.sourceId == source.id)
        .firstOrNull;
    if (sub == null || !sub.isUrl) return;
    try {
      final text = await M3uSubscriptionService.fetchText(sub.url);
      final updated = await M3uSubscriptionService.build(
        name: sub.name,
        kind: sub.kind,
        text: text,
        rawBytes: utf8.encode(text),
        url: sub.url,
        existing: sub.id,
      );
      await store.syncM3uSubscriptions([
        for (final item in store.m3uSubscriptions)
          if (item.id == sub.id) updated else item,
      ]);
    } catch (error) {
      if (mounted) {
        AppNotice.show(context, '远程订阅刷新失败，先用本地副本：$error');
      }
    }
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
                if (channel != null &&
                    _epgGuide != null &&
                    _epgGuide!.programmesFor(channel).isNotEmpty)
                  ListTile(
                    key: const ValueKey('live-info-epg'),
                    leading: const Icon(Icons.event_note_rounded),
                    title: const Text('节目单'),
                    subtitle: channel.catchup != null
                        ? const Text('过去的节目可点回看')
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop('epg'),
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
      case 'epg':
        final current = _playback.channel;
        if (current != null) await _showProgrammeSheet(current);
      case 'sleep':
        await _openSleepTimer();
    }
  }

  static String _epgClock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  /// 节目单弹层：当前频道今天的节目（按时间正序，打开时滚到
  /// 正在播的那条）。正在播的标「正在播」；已播完的在频道带
  /// 回看模板时可点，点完按模板生成回看地址起播；没回看模板
  /// 时只看单子，不给假入口。
  Future<void> _showProgrammeSheet(LiveChannel channel) async {
    final guide = _epgGuide;
    if (guide == null) return;
    final all = guide.programmesFor(channel);
    if (all.isEmpty) return;
    final now = DateTime.now();
    // 只列今天这一天的节目：结束晚于今天零点、开始早于明天
    // 零点（跨零点的节目按这个口径不会被漏掉）；节目单文件
    // 常含多天，全列出来太长。一条都不剩时回落全表。
    final dayStart = DateTime(now.year, now.month, now.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final todays = [
      for (final item in all)
        if (item.end.isAfter(dayStart) && item.start.isBefore(dayEnd)) item,
    ];
    final list = todays.isEmpty ? all : todays;
    final currentIndex = list.indexWhere((item) => item.contains(now));
    final scroll = ScrollController(
      initialScrollOffset: currentIndex > 0 ? currentIndex * 56.0 : 0,
    );
    final picked = await showModalBottomSheet<LiveEpgProgramme>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  '${channel.name} · 节目单',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('live-epg-list'),
                  controller: scroll,
                  itemCount: list.length,
                  itemBuilder: (itemContext, index) {
                    final item = list[index];
                    final playing = item.contains(now);
                    final past = item.end.isBefore(now) || item.end == now;
                    final canCatchup = past && channel.catchup != null;
                    return ListTile(
                      key: ValueKey('live-epg-item-$index'),
                      leading: Text(
                        _epgClock(item.start),
                        style: Theme.of(itemContext).textTheme.bodyMedium,
                      ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_epgClock(item.start)}–${_epgClock(item.end)}',
                      ),
                      trailing: playing
                          ? const Chip(label: Text('正在播'))
                          : canCatchup
                          ? const Icon(Icons.replay_rounded)
                          : null,
                      onTap: canCatchup
                          ? () => Navigator.of(sheetContext).pop(item)
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    scroll.dispose();
    if (picked == null || !mounted) return;
    final catchup = channel.catchup;
    if (catchup == null) return;
    final url = formatLiveCatchupUrl(
      catchup: catchup,
      liveUrl: channel.url,
      start: picked.start,
      end: picked.end,
    );
    if (url == null) {
      AppNotice.show(context, '这个节目生成不了回看地址');
      return;
    }
    _playCatchup(channel, picked, url);
  }

  /// 回看起播：播放列表里只把该频道这一条的地址换成回看地址
  /// （key 不变，分组/选中态都跟着走），其余频道不动；用户
  /// 再切分组/切源重拉列表后，该频道自然恢复直播地址。
  void _playCatchup(
    LiveChannel channel,
    LiveEpgProgramme programme,
    String url,
  ) {
    final source = _source;
    if (source == null) return;
    final base = _playback.channels.isNotEmpty
        ? _playback.channels
        : _channels;
    final index = base.indexWhere((entry) => entry.key == channel.key);
    if (index < 0) return;
    final replaced = [
      for (final entry in base)
        if (entry.key == channel.key) entry.withUrls([url]) else entry,
    ];
    unawaited(_playback.load(source, replaced, index: index));
    AppNotice.show(context, '回看：${programme.title}');
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
      // 删除只走弹窗自带的 onDeleteSite 入口（长按删除），弹窗
      // 样子与用法不动；可删的只有 m3u 订阅源（deletable 只给
      // 它们），内置源与 TVBox 配置源都不给删除。
      onDeleteSite: widget.appStore == null ? null : _deleteImportedSource,
      groups: [
        if (builtin.isNotEmpty)
          SourcePickerGroup(
            title: grouped ? '平台源' : '',
            entries: [
              for (final source in builtin)
                SourcePickerEntry(
                  id: source.id,
                  name: source.name,
                  deletable: false,
                ),
            ],
          ),
        if (imported.isNotEmpty)
          SourcePickerGroup(
            title: grouped ? '导入源' : '',
            entries: [
              for (final source in imported)
                SourcePickerEntry(
                  id: source.id,
                  name: source.name,
                  deletable: source.id.startsWith('m3u:'),
                ),
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
    final Widget content;
    if (_source == null) {
      content = StatusPanel(
        key: const ValueKey('live-green-empty'),
        title: '暂无可用直播源',
        message: '当前没有可用的直播源。',
        icon: Icons.verified_user_outlined,
      );
    } else {
      content = Column(
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
    // 没有 LocalStore（测试注入缺省）时不挂导入钮，页面与原来一致。
    if (widget.appStore == null) return content;
    return Stack(
      fit: StackFit.expand,
      children: [content, _importButton(context)],
    );
  }

  /// 左下角「+」导入钮：悬浮固定在页面左下角的独立层上——
  /// 不在频道列表的布局里、不随列表上下滑动而动，滑动时纹丝
  /// 不动；位置在列表区左下角，不挡信息行左槽的预览帧（那行
  /// 在列表区顶部）。点开给两个入口：导入本地文件 / 添加远程
  /// 链接（见 _showImportMenu）。
  Widget _importButton(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Positioned(
      left: 12,
      bottom: 12,
      child: Tooltip(
        message: '导入直播源',
        child: Material(
          key: const ValueKey('live-import-add'),
          color: colors.primary,
          shape: const CircleBorder(),
          elevation: 4,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _importing
                ? null
                : () => unawaited(_showImportMenu()),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(Icons.add_rounded, color: colors.onPrimary),
            ),
          ),
        ),
      ),
    );
  }

  /// 「+」菜单：导入本地 m3u/txt 文件、添加远程直播链接。
  /// 两条都走既有的 m3u 订阅机件（M3uSubscriptionService +
  /// LocalStore.syncM3uSubscriptions），与导入中心同一套，
  /// 不另起解析/存盘。
  Future<void> _showImportMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('live-import-local'),
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('导入本地文件'),
              subtitle: const Text('m3u / txt 直播列表'),
              onTap: () => Navigator.of(sheetContext).pop('local'),
            ),
            ListTile(
              key: const ValueKey('live-import-remote'),
              leading: const Icon(Icons.link_rounded),
              title: const Text('添加远程链接'),
              subtitle: const Text('粘贴 http(s) 直播订阅地址'),
              onTap: () => Navigator.of(sheetContext).pop('remote'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'local') {
      await _importLocalFile();
    } else if (action == 'remote') {
      await _importRemoteLink();
    }
  }

  /// 导入本地文件：选文件走与导入中心同款的 FilePicker 调用；
  /// 源名用文件名（去掉扩展名），不另问名字。解析失败由
  /// analyzeM3u 给明确原因（格式不对/没有可用频道），原样提示。
  Future<void> _importLocalFile() async {
    final store = widget.appStore;
    if (store == null || _importing) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8', 'txt'],
    );
    if (file == null || !mounted) return;
    setState(() => _importing = true);
    try {
      final bytes = await file.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      final name = file.name.replaceAll(
        RegExp(r'\.(m3u8?|txt)$', caseSensitive: false),
        '',
      );
      final record = await M3uSubscriptionService.build(
        name: name,
        kind: M3uSubscription.kindFile,
        text: text,
        rawBytes: bytes,
      );
      await store.syncM3uSubscriptions([
        ...store.m3uSubscriptions,
        record,
      ]);
      if (!mounted) return;
      AppNotice.show(
        context,
        '已导入「${record.name}」：${record.channelCount} 个频道，已切换到该源',
      );
      _switchToImported(record.sourceId);
    } catch (error) {
      if (mounted) AppNotice.show(context, '导入失败：$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 添加远程链接：只收 http/https；拉回来解析，源名用文件头
  /// #EXTM3U 的 name、没有就用链接主机名（m3uRemoteName）。
  /// 拉不到与解析失败分别由 fetchText / analyzeM3u 给原因。
  Future<void> _importRemoteLink() async {
    final store = widget.appStore;
    if (store == null || _importing) return;
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加远程直播链接'),
        content: TextField(
          key: const ValueKey('live-import-url-field'),
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '直播订阅地址',
            hintText: 'https://example.com/live.m3u',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('live-import-url-confirm'),
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || !mounted) return;
    if (url.isEmpty) {
      AppNotice.show(context, '请填写订阅地址');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      AppNotice.show(context, '订阅地址无效：只支持 http/https 链接');
      return;
    }
    setState(() => _importing = true);
    try {
      final text = await M3uSubscriptionService.fetchText(url);
      final record = await M3uSubscriptionService.build(
        name: m3uRemoteName(text, url),
        kind: M3uSubscription.kindUrl,
        text: text,
        rawBytes: utf8.encode(text),
        url: url,
      );
      await store.syncM3uSubscriptions([
        ...store.m3uSubscriptions,
        record,
      ]);
      if (!mounted) return;
      AppNotice.show(
        context,
        '已添加「${record.name}」：${record.channelCount} 个频道，已切换到该源',
      );
      _switchToImported(record.sourceId);
    } catch (error) {
      if (mounted) AppNotice.show(context, '添加失败：$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 导入成功后自动切到新源并刷新频道列表（与「导入数据库
  /// 自动刷新」同一口径）：新源已在可见列表里就直接切；
  /// 切的正是当前源时强制重拉。
  void _switchToImported(String sourceId) {
    final target = LiveSource.visible(
      widget.greenMode,
    ).where((item) => item.id == sourceId).firstOrNull;
    if (target == null) return;
    if (target.id == _source?.id) {
      unawaited(_loadPlatforms(force: true));
    } else {
      _changeSource(target);
    }
  }

  /// 选源弹窗里删导入的 m3u 订阅：走弹窗自带的删除入口
  /// （onDeleteSite，长按删除，弹窗的样子与用法没动），只对
  /// m3u 订阅条目开放（条目 deletable 也只给它们）。确认文案
  /// 与导入中心删订阅同款；删的正是当前源时，订阅表变化会
  /// 触发 _appStoreChanged 把当前源切走，不用在这里处理。
  Future<bool> _deleteImportedSource(SourcePickerEntry entry) async {
    final store = widget.appStore;
    if (store == null || !entry.id.startsWith('m3u:')) return false;
    final sub = store.m3uSubscriptions
        .where((item) => item.sourceId == entry.id)
        .firstOrNull;
    if (sub == null) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除直播订阅'),
        content: Text('确定删除「${sub.name}」吗？其频道将从直播区移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    await M3uFileStore.delete(sub.fileName);
    await store.syncM3uSubscriptions([
      for (final item in store.m3uSubscriptions)
        if (item.id != sub.id) item,
    ]);
    return true;
  }

  /// 直播解码模式 → EXO 核的解码模式（只在 DRM 频道走 EXO 时用）。
  TelevisionDecoder get _exoDecoderMode => switch (_playback.decoderMode) {
    LiveDecoderMode.auto => TelevisionDecoder.optimized,
    LiveDecoderMode.hardware => TelevisionDecoder.hardware,
    LiveDecoderMode.software => TelevisionDecoder.software,
  };

  /// DRM 频道的主画面：EXO pane（点播侧同款接法，drm 随计划带上）。
  /// pane 自带播放/暂停控制条，所以不再叠 mpv 那套点画面进全屏的
  /// 手势层；全屏走信息单里的全屏入口（全屏页同样走 EXO）。
  Widget _exoStage(BuildContext context, PlaybackPlan plan) {
    return TvboxVideoPane(
      key: const ValueKey('live-exo-pane'),
      plan: plan,
      startPosition: 0,
      autoplay: true,
      decoderMode: _exoDecoderMode,
      handle: _playback.exoHandle,
      onCompleted: _playback.reportExoCompleted,
      onError: _playback.reportExoError,
    );
  }

  Widget _video(BuildContext context, bool television) {
    final controller = _playback.controller;
    final error = _playback.error;
    final exoPlan = _playback.exoPlan;
    return ColoredBox(
      key: const ValueKey('live-stage'),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.videoBuilder != null)
            widget.videoBuilder!(_playback, false)
          else if (exoPlan != null)
            _exoStage(context, exoPlan)
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
          // DRM/EXO 频道不叠这层手势：pane 自带控制条要吃点按，
          // 全屏走信息单入口。普通频道（mpv）保持原手势不变。
          if (error == null && exoPlan == null)
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
          // 手机端播放区：中间居中转圈/速率 + 顶部频道名/分辨率/信息。
          // 顶栏画在错误遮罩之上，断流时照样能点信息换源；中间层只在无错时显示。
          if (!television) ...[
            if (error == null) _videoCenterOverlay(context),
            _videoHeader(context),
          ],
        ],
      ),
    );
  }

  /// 截图播放区顶栏：左频道名，右真实分辨率 + 帧率（帧率拿到时
  /// 拼在分辨率后面，拿不到就不显示那一段、绝不编数）+ 信息。
  /// 设置齿轮已按用户口径撤掉：解码模式/睡眠定时/恢复默认三项
  /// 挪进软件设置页「直播设置」节（见 live_settings.dart）。
  /// 顶栏本身不拦手势，只有信息按钮吃点按，其余位置仍落
  /// 到下面的全屏手势层。
  Widget _videoHeader(BuildContext context) {
    final channel = _playback.channel;
    final size = _playback.videoSize;
    final fps = _playback.videoFps;
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
                '[ ${size.width.toInt()} x ${size.height.toInt()}'
                '${fps != null ? ' · ${fps.round()} 帧/秒' : ''} ]',
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

  /// 播放区下方一行：左槽实时预览帧，中卡“正在播放 /
  /// 即将播放”，右端切源按钮卡（恢复改版前 _current 卡右端
  /// 的直达按钮：key live-source-button、电视图标、点开 _pickSource；
  /// 改版时手机端把它删了、切源只能绕 ⓘ 信息单）。
  /// 比例按用户参考截图瘦身：整行固定 80 高（约一颗半频道胶囊），
  /// 不再由内容撑高——此前大数字卡 + 两行文字 + 内边距把这行撑
  /// 到近 20% 屏高，用户嫌又大又丑。左槽原是显示频道号数字的
  /// 卡，用户改令整个换成预览帧（见 _infoPreviewSlot），频道号
  /// 只作小角标叠在帧一角，不另占卡；节目卡两行小字紧排、中间
  /// 细分隔线；切源钮随行高做成 56 宽的小方钮，不再是一根独立
  /// 高柱。
  /// 节目信息按用户口径接真数据：当前源带节目单（epg 地址）
  /// 且节目单对得上当前频道时，“正在播放 / 即将播放”用节目单
  /// 里的真节目名；没有节目单、或对不上台时回落原口径——
  /// “正在播放”= 当前条目标题（subtitle 是另一份真实信息且
  /// 与标题不同才拼在后面），“即将播放”= 频道列表里下一条的
  /// 标题，列表到尾、没有下一条才写“暂无节目信息”。绝不编
  /// 节目名。卡面与文字跟随应用主题（改版前口径）。
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
    final guide = _epgGuide;
    final epgHit = guide != null && channel != null
        ? guide.nowNext(channel, DateTime.now())
        : null;
    final epgMatched =
        guide != null &&
        channel != null &&
        guide.programmesFor(channel).isNotEmpty;
    final now = epgHit?.now != null
        ? epgHit!.now!.title
        : channel == null
        ? '暂无节目信息'
        : channel.subtitle.isNotEmpty && channel.subtitle != channel.name
        ? '${channel.name} · ${channel.subtitle}'
        : channel.name;
    final channels = _playback.channels;
    final nextIndex = _playback.index + 1;
    final next = epgMatched
        ? epgHit?.next?.title ?? '暂无节目信息'
        : channel != null && nextIndex < channels.length
        ? channels[nextIndex].name
        : '暂无节目信息';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      // 整行高度钉死 80（用户截图比例，约一颗半胶囊高）：不再由
      // 内容定高，内容再多也只在这 80 里排，两卡直接 stretch 等高。
      child: SizedBox(
        height: 80,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          Expanded(
            flex: 20,
            child: _infoPreviewSlot(context, channel, number),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 75,
            child: Material(
              key: const ValueKey('live-epg-card'),
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
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
                    Divider(color: theme.dividerColor, height: 8),
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
          // 切源钮：随瘦行做成 56 宽的小方钮（与行同高 80），
          // 不再是 46 宽撑满整行高的独立高柱。
          SizedBox(
            width: 56,
            child: Material(
              key: const ValueKey('live-source-card'),
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

  /// 信息行左槽：实时预览帧（用户改令，原来显示频道号数字的卡
  /// 整个换成它）。尺寸就是原数字卡的槽位（行高 80、flex 20 宽、
  /// 圆角 12 与原卡一致），里面是与上方播放区同一个播放器的实时
  /// 画面，完整显示不裁剪（contain）。频道号不另占卡，只以左上
  /// 角小角标（半透明黑底白字）叠在帧上。没在播时显示占位：
  /// 黑底 + 频道名小字（未选频道时写“未选择频道”）。
  /// 画面仍只用真 Video——不用 widget.videoBuilder 那个测试
  /// 接缝，它的契约是“主播放面有且只有一个”（全屏退出流程靠
  /// 这个不变量）；没有真控制器时（测试环境）落占位，不造第二
  /// 个假面。
  Widget _infoPreviewSlot(
    BuildContext context,
    LiveChannel? channel,
    String number,
  ) {
    // DRM 频道走 EXO、没有 mpv 纹理可镜像：小槽降级为不出预览帧，
    // 只留下面的频道号角标（任务口径）。普通频道照旧镜像真画面。
    final controller = _playback.usingExo ? null : _playback.controller;
    return Container(
      key: const ValueKey('live-info-preview'),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null)
            Video(
              controller: controller,
              fit: BoxFit.contain,
              wakelock: false,
              controls: (_) => const SizedBox.shrink(),
            )
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '实时预览',
                      style: TextStyle(color: Color(0xFF8B8F99), fontSize: 10),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      channel?.name ?? '未选择频道',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8B8F99),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_playback.buffering)
            const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          if (channel != null)
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  number,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
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

  /// 三列区：左分组/收藏、中频道、右线路（同行对齐、同一个列表
  /// 一起滚、占满全宽），全是同款胶囊格。选中项黄字（用户口径
  /// 保留）、未选中跟主题正文色；行数取三列中最长的一列，短的
  /// 列空着。没有右侧大预览区——预览收进正在播的那颗频道胶囊
  /// 本身（见 _channelCell）。频道多时滑到底自动续载。
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
    if (lineCount > rows) rows = lineCount;
    // 布局（用户口径）：分组/频道/线路三列同行对齐、一起滚、占满
    // 全宽，全是同款胶囊格；行数取三列中最长的一列，短的列空着。
    // 频道多时滑到底自动续载（与原来频道列一致）。
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
        key: const ValueKey('live-grid'),
        controller: _channelScroll,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
                Expanded(flex: 44, child: _channelCell(context, index)),
                const SizedBox(width: 6),
                Expanded(
                  flex: 26,
                  child: _lineCell(context, index, lineCount, multiRoute),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 线路列格：与分组/频道同款胶囊（同高、同圆角、同选中口径），
  /// 点按仍是同一播放器打开该线路真地址重播。只有直连型源可点；
  /// api 型源的线路走仓库解析、切线重播没有意义，只作展示不挂
  /// 点按（key 也不挂，与上一批预览区小按钮的口径一致）。
  Widget _lineCell(
    BuildContext context,
    int index,
    int lineCount,
    bool multiRoute,
  ) {
    if (index >= lineCount) return const SizedBox(height: 48);
    final selected = multiRoute && index == _playback.route;
    final cell = _gridCell(
      context,
      selected: selected,
      child: Text(
        '线路${index + 1}',
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _gridCellText(context, selected),
      ),
    );
    if (!multiRoute) return cell;
    return InkWell(
      key: ValueKey('live-line-$index'),
      onTap: () => unawaited(_playback.playRoute(index)),
      child: cell,
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
