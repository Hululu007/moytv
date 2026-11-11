import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'core_bridge.dart';
import 'hongguo_account_store.dart';
import 'hongguo_comment.dart';
import 'hongguo_danmaku.dart';
import 'hongguo_preload.dart';
import 'hongguo_series.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_foreground.dart';
import 'playback_preferences.dart';
import 'sleep_timer.dart';
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

String _formatClock(double seconds) {
  final total = seconds.round().clamp(0, 1 << 30);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final secs = total % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = secs.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$mm:$ss';
  return '$mm:$ss';
}

// 画面模式三档。播放器 widget（RoomPlayerView 内的 Video）只认固定
// BoxFit.contain、不带画面模式与旋转参数，所以三档与旋转都在本页用包一层
// 的办法落：旋转走 RotatedBox（只转画面，不改系统方向），画面模式走
// ClipRect + Transform 缩放，见 _frameWrap。
enum HongguoFrameMode {
  fit('适配'),
  zoom('等比铺满'),
  fill('拉伸铺满');

  const HongguoFrameMode(this.label);

  final String label;

  static HongguoFrameMode fromStored(String? value) =>
      HongguoFrameMode.values.asNameMap()[value] ?? HongguoFrameMode.fit;
}

// 纯函数：按画面模式算缩放系数。容器宽高比 containerAspect、画面宽高比
// videoAspect；返回的 scaleX/scaleY 乘在 contain 尺寸上。
class HongguoFrameFit {
  static ({double scaleX, double scaleY}) scale({
    required HongguoFrameMode mode,
    required double videoAspect,
    required double containerAspect,
  }) {
    switch (mode) {
      case HongguoFrameMode.fit:
        return (scaleX: 1.0, scaleY: 1.0);
      case HongguoFrameMode.zoom:
        final factor = containerAspect > videoAspect
            ? containerAspect / videoAspect
            : videoAspect / containerAspect;
        return (scaleX: factor, scaleY: factor);
      case HongguoFrameMode.fill:
        final containWidth = containerAspect < videoAspect
            ? containerAspect
            : videoAspect;
        final containHeight = containWidth / videoAspect;
        return (
          scaleX: containerAspect / containWidth,
          scaleY: 1 / containHeight,
        );
    }
  }
}

// 清晰度：三档上限 1080，超上限的档标注“兼容资源”。
// Dart 侧取流结果只带高度（PlaybackPlan.qualities），编码与宽高在 Go 核
// 里，核内已跳过 bytevc2；所以档位选择以高度为准。
class HongguoQualityOptions {
  static const int maxQuality = 1080;
  static const List<int> standard = [1080, 720, 480];

  static bool isCompatibleResource(int quality) => quality > maxQuality;

  static String label(int quality) {
    if (quality <= 0) return '自动';
    if (isCompatibleResource(quality)) return '${quality}P · 兼容资源';
    return '${quality}P';
  }

  // 可选档位：降序去重，并跳过已记下的失败高度。
  static List<int> available(
    List<int> qualities, {
    Set<int> failedHeights = const {},
  }) {
    final seen = <int>{};
    final out = <int>[];
    for (final quality in qualities) {
      if (quality > 0 &&
          !failedHeights.contains(quality) &&
          seen.add(quality)) {
        out.add(quality);
      }
    }
    out.sort((a, b) => b.compareTo(a));
    return out;
  }

  // 下一低档：比当前低的最大可选档，失败高度跳过；没有返回 null。
  static int? nextLower(
    List<int> qualities,
    int current, {
    Set<int> failedHeights = const {},
  }) {
    int? best;
    for (final quality in qualities) {
      if (quality > 0 &&
          quality < current &&
          !failedHeights.contains(quality)) {
        if (best == null || quality > best) best = quality;
      }
    }
    return best;
  }
}

// 播放恢复预算：快段重试 + 退避，最长累计约 5 分钟。
// 延迟表与 hongguoTV 的 RecoveryBudget 同量级；每集重置，用户显式重试
// 才重置；耗尽后不再自动重试，改出恢复 UI。
class HongguoRecoveryBudget {
  static const List<double> delaysSeconds = [1, 2.5, 5, 15, 30, 60, 90, 105];

  // 1+2.5+5+15+30+60+90+105 = 308.5 秒，约 5 分钟。
  static const double totalSeconds = 308.5;

  int _used = 0;

  int get used => _used;

  int get remaining => delaysSeconds.length - _used;

  bool get exhausted => _used >= delaysSeconds.length;

  Duration? nextDelay() {
    if (exhausted) return null;
    final seconds = delaysSeconds[_used];
    _used++;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  void reset() {
    _used = 0;
  }
}

// 解码失败教训：本机记“编码 + 宽 + 高”组合，存在 SharedPreferences
//（hongguoDecoderLessons 键，JSON 对象，键是“编码|宽|高”，值是失败次数）。
// Dart 侧取流结果只带高度，编码与宽未知时记空串与 0；匹配时空串/0 当通配，
// 即只记了高度的教训会跳过该高度的全部档位——宁可多跳，不播黑屏。
class HongguoDecoderLessons {
  HongguoDecoderLessons([Map<String, int>? counts])
    : _counts = Map.of(counts ?? {});

  factory HongguoDecoderLessons.fromJson(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '') as Map;
      final counts = <String, int>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is num) counts[entry.key.toString()] = value.toInt();
      }
      return HongguoDecoderLessons(counts);
    } catch (_) {
      return HongguoDecoderLessons();
    }
  }

  static String key({String codec = '', int width = 0, int height = 0}) =>
      '$codec|$width|$height';

  final Map<String, int> _counts;

  Map<String, int> get counts => Map.unmodifiable(_counts);

  bool get isEmpty => _counts.isEmpty;

  Set<int> get failedHeights {
    final heights = <int>{};
    for (final rawKey in _counts.keys) {
      final parts = rawKey.split('|');
      if (parts.length != 3) continue;
      final height = int.tryParse(parts[2]) ?? 0;
      if (height > 0) heights.add(height);
    }
    return heights;
  }

  void remember({String codec = '', int width = 0, int height = 0}) {
    final lessonKey = key(codec: codec, width: width, height: height);
    _counts.update(lessonKey, (value) => value + 1, ifAbsent: () => 1);
  }

  bool fails({String codec = '', int width = 0, int height = 0}) {
    for (final rawKey in _counts.keys) {
      final parts = rawKey.split('|');
      if (parts.length != 3) continue;
      final lessonCodec = parts[0];
      final lessonWidth = int.tryParse(parts[1]) ?? 0;
      final lessonHeight = int.tryParse(parts[2]) ?? 0;
      if (lessonHeight == height &&
          (lessonCodec.isEmpty || codec.isEmpty || lessonCodec == codec) &&
          (lessonWidth == 0 || width == 0 || lessonWidth == width)) {
        return true;
      }
    }
    return false;
  }

  bool failsHeight(int height) => fails(height: height);

  String toJson() => jsonEncode(_counts);
}

// 常驻进度值按千分比算：0~1000。
int hongguoProgressPermille(double position, double duration) {
  if (duration <= 0 || position <= 0) return 0;
  return ((position / duration) * 1000).round().clamp(0, 1000);
}

// 跨季连播门：自动连播与跨季开关都开才生效。
bool hongguoSeasonAutoplayAllowed({
  required bool autoNext,
  required bool seasonAutoplay,
}) => autoNext && seasonAutoplay;

// 下一季：复用 hongguo_series.dart 的 hongguoSeriesEntries（季数据与
// observeHongguoSeriesSeasons 共用同一套取数）；只找比当前季大的最小一季。
// observeHongguoSeriesSeasons 本身只产收藏剧的新季提醒 FollowState，不
// 返回可播的下一季 Drama，所以连播查找直接用 entries，不另写取数逻辑。
Drama? hongguoNextSeasonDrama({
  required Drama anchor,
  required Iterable<Drama> candidates,
}) {
  final entries = hongguoSeriesEntries(anchor, candidates);
  final anchorEntry = entries
      .where((entry) => entry.drama.id == anchor.id)
      .firstOrNull;
  if (anchorEntry == null) return null;
  final next = entries
      .where((entry) => entry.season > anchorEntry.season)
      .firstOrNull;
  return next?.drama;
}

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

  // 红果播放控制新增状态。
  late final SleepTimerController _sleepTimer;
  // 会话内清晰度：0 表示自动（最高档）。显式选档才落盘；播放失败自动降档
  // 只改会话值，不改用户存的偏好。
  int _requestedQuality = 0;
  HongguoFrameMode _frameMode = HongguoFrameMode.fit;
  int _videoRotation = 0;
  double? _resumePosition;
  bool _forceFreshPlan = false;
  final HongguoRecoveryBudget _recoveryBudget = HongguoRecoveryBudget();
  Timer? _recoveryTimer;
  bool _recoveryArmed = false;
  bool _recoveryExhausted = false;
  bool _recoveryAllQualitiesFailed = false;
  String? _lastPlayerError;
  HongguoDecoderLessons _decoderLessons = HongguoDecoderLessons();

  @override
  void initState() {
    super.initState();
    _detail = widget.detail;
    _episode = widget.initialEpisode;
    _requestedQuality = widget.store.hongguoQuality;
    _frameMode = HongguoFrameMode.fromStored(widget.store.hongguoFrameMode);
    _videoRotation = widget.store.hongguoVideoRotation;
    _decoderLessons = HongguoDecoderLessons.fromJson(
      widget.store.hongguoDecoderLessonsRaw,
    );
    _sleepTimer = SleepTimerController(onExpire: _onSleepTimerExpired);
    _player.addListener(_onPlayerChanged);
    unawaited(_playCurrent());
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _player.removeListener(_onPlayerChanged);
    _sleepTimer.dispose();
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

  // 播放器状态变化：播起来清恢复态，出错走恢复预算。
  void _onPlayerChanged() {
    final error = _player.error;
    if (error == null) {
      if (_player.hasVideo &&
          !_player.loading &&
          (_recoveryBudget.used > 0 ||
              _recoveryExhausted ||
              _recoveryArmed)) {
        _cancelRecovery();
      }
      return;
    }
    if (error == _lastPlayerError) return;
    _lastPlayerError = error;
    _onPlaybackFailure(error);
  }

  // 播放失败入口：记失败教训，按预算排一次重试；预算耗尽出恢复 UI。
  // 与自动降档共用同一份预算，不各搞一套。
  void _onPlaybackFailure(String message, {int height = 0}) {
    if (!mounted || _recoveryArmed || _recoveryExhausted) return;
    final failedHeight = height > 0
        ? height
        : (_requestedQuality > 0
            ? _requestedQuality
            : (_player.plan?.quality ?? 0));
    if (failedHeight > 0) {
      _decoderLessons.remember(height: failedHeight);
      unawaited(
        widget.store.setHongguoDecoderLessons(_decoderLessons.toJson()),
      );
    }
    final delay = _recoveryBudget.nextDelay();
    if (delay == null) {
      setState(() {
        _recoveryExhausted = true;
        _recoveryAllQualitiesFailed = _nextLowerQuality() == null;
      });
      return;
    }
    _recoveryArmed = true;
    if (mounted) setState(() {});
    _recoveryTimer = Timer(delay, () {
      _recoveryArmed = false;
      if (!mounted) return;
      _retryWithDowngrade();
    });
  }

  // 下一低档：比正在播的档低的最大可选档，失败高度跳过；没有返回 null。
  int? _nextLowerQuality() {
    final plan = _player.plan;
    if (plan == null) return null;
    final current = _requestedQuality > 0 ? _requestedQuality : plan.quality;
    if (current <= 0) return null;
    return HongguoQualityOptions.nextLower(
      plan.qualities,
      current,
      failedHeights: _decoderLessons.failedHeights,
    );
  }

  // 预算内重试：有更低档先降一档（只改会话值），没有就同档重新取流。
  // 每次重试都重新取流一次：_forceFreshPlan 让 _playCurrent 不用预取的
  // 旧计划；已 pin 清晰度时 _playCurrent 本来就会重新 resolve。
  void _retryWithDowngrade() {
    final lower = _nextLowerQuality();
    if (lower != null) _requestedQuality = lower;
    _forceFreshPlan = true;
    _lastPlayerError = null;
    _captureResumePosition();
    unawaited(_playCurrent());
  }

  // 用户显式重试：重置预算，再播一次。
  void _manualRetry() {
    _cancelRecovery();
    _forceFreshPlan = true;
    _captureResumePosition();
    unawaited(_playCurrent());
  }

  void _cancelRecovery() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    final hadState =
        _recoveryBudget.used > 0 || _recoveryExhausted || _recoveryArmed;
    _recoveryBudget.reset();
    _recoveryExhausted = false;
    _recoveryAllQualitiesFailed = false;
    _recoveryArmed = false;
    _lastPlayerError = null;
    if (hadState && mounted) setState(() {});
  }

  void _captureResumePosition() {
    final position = _player.position;
    final duration = _player.duration;
    _resumePosition = position > 1 && (duration <= 0 || position < duration - 5)
        ? position
        : null;
  }

  Future<void> _saveCurrentPosition() async {
    final detail = _detail;
    if (detail == null || detail.episodes.isEmpty) return;
    final position = _player.position;
    final duration = _player.duration;
    if (position < 0.1) return;
    final entry = WatchEntry(
      drama: widget.drama,
      episode: detail.episodes[_episode].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await widget.store.saveWatch(entry);
    } catch (_) {}
    // 云端进度上传（唯一一处）：本机已存好后，把同一条进度入队发云端；
    // 未登录或未建账号 store 时直接跳过，不影响本机保存。
    unawaited(
      HongguoAccountStore.current?.enqueueCloudProgress(
            seriesId: hongguoNumericId(widget.drama.id) ?? widget.drama.id,
            itemId: detail.episodes[_episode].id.isEmpty
                ? detail.episodes[_episode].number.toString()
                : detail.episodes[_episode].id,
            episodeIndex: _episode,
            episodeCount: detail.episodes.length,
            positionSeconds: position,
            totalSeconds: duration,
          ) ??
          Future.value(),
    );
  }

  Future<void> _onSleepTimerExpired() async {
    if (!mounted) return;
    await _player.pause();
    await _saveCurrentPosition();
    if (!mounted) return;
    _note('定时停止已生效 · 观看位置已保存');
  }

  void _openDrama(Drama drama) {
    unawaited(
      Navigator.of(context).push<void>(
        appPageRoute<void>(
          builder: (_) => HongguoPlaybackPage(
            drama: drama,
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      ),
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
      if (_resumePosition != null) {
        // 切清晰度/失败重试续播：不断点。
        start = _resumePosition!;
        _resumePosition = null;
      } else if (!_usedStartPosition && _episode == widget.initialEpisode) {
        start = widget.startPosition;
        _usedStartPosition = true;
      }
      if (!mounted || token != _playToken) return;
      // 已 pin 清晰度时直接按该档重新取流（不用预取的旧计划，否则档位
      // 落不下去）；取流失败走恢复预算，不静默回最高档。
      PlaybackPlan? forcedPlan;
      if (_requestedQuality > 0) {
        try {
          forcedPlan = await widget.repository.resolve(
            widget.drama,
            detail.episodes[episodeIndex],
            quality: _requestedQuality,
          );
        } catch (error) {
          if (!mounted || token != _playToken) return;
          _onPlaybackFailure(error.toString(), height: _requestedQuality);
          return;
        }
        if (!mounted || token != _playToken) return;
      }
      final preloaded = forcedPlan ??
          (_forceFreshPlan
              ? null
              : _preloadWindow.take(
                  widget.drama,
                  detail.episodes[episodeIndex],
                ));
      _forceFreshPlan = false;
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
    _cancelRecovery();
    setState(() {
      _episode = index;
      _synopsisExpanded = false;
    });
    unawaited(_playCurrent());
  }

  void _onCompleted() {
    // 睡眠定时“播完本集”：到集末暂停并保存位置，不再连播。
    if (_sleepTimer.consumeFinishEpisode()) {
      unawaited(_onSleepTimerExpired());
      return;
    }
    final detail = _detail;
    if (detail == null || detail.episodes.isEmpty) return;
    if (_episode + 1 < detail.episodes.length) {
      _playEpisode(_episode + 1);
      return;
    }
    // 本季最后一集：自动连播与跨季开关都开时才进下一季，否则保持原行为
    // （开选集面板）。季内连播本身不设门，行为与原来一致。
    if (hongguoSeasonAutoplayAllowed(
      autoNext: widget.store.playbackPreferences.autoAdvance,
      seasonAutoplay: widget.store.hongguoSeasonAutoplay,
    )) {
      final candidates = <Drama>{
        ...detail.related,
        ...widget.store.seriesDramasFor(widget.drama),
      };
      final next = hongguoNextSeasonDrama(
        anchor: widget.drama,
        candidates: candidates,
      );
      if (next != null) {
        _openDrama(next);
        return;
      }
    }
    _openEpisodeSheet(initialTab: 1);
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
          _openDrama(drama);
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

  String _qualityLabel() {
    if (_requestedQuality > 0) {
      return HongguoQualityOptions.label(_requestedQuality);
    }
    final plan = _player.plan;
    if (plan != null && plan.quality > 0) {
      return HongguoQualityOptions.label(plan.quality);
    }
    return '自动';
  }

  Future<void> _openQualitySheet() async {
    final plan = _player.plan;
    final offered = plan == null || plan.qualities.isEmpty
        ? HongguoQualityOptions.standard
        : plan.qualities;
    final failed = _decoderLessons.failedHeights;
    final options = HongguoQualityOptions.available(offered, failedHeights: failed);
    final hiddenFailed = {
      for (final quality in offered)
        if (failed.contains(quality)) quality,
    };
    final selected = await showModalBottomSheet<int>(
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
                '清晰度',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (hiddenFailed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '已跳过播不动的档位：${hiddenFailed.map((quality) => '${quality}P').join('、')}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('自动（最高档）'),
                    selected: _requestedQuality == 0,
                    onSelected: (_) => Navigator.of(context).pop(0),
                  ),
                  for (final quality in options)
                    ChoiceChip(
                      label: Text(
                        HongguoQualityOptions.label(quality),
                      ),
                      selected: quality == _requestedQuality,
                      onSelected: (_) =>
                          Navigator.of(context).pop(quality),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted || selected == _requestedQuality) return;
    await _switchQuality(selected);
  }

  // 显式选档：落盘偏好、重置恢复预算、不断点切流。
  Future<void> _switchQuality(int quality) async {
    _cancelRecovery();
    _requestedQuality = quality;
    await widget.store.setHongguoQuality(quality);
    _captureResumePosition();
    if (mounted) setState(() {});
    unawaited(_playCurrent());
  }

  Future<void> _openFrameSheet() async {
    final selected = await showModalBottomSheet<HongguoFrameMode>(
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
                '画面模式',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Wrap(
                spacing: 8,
                children: HongguoFrameMode.values
                    .map(
                      (mode) => ChoiceChip(
                        label: Text(mode.label),
                        selected: mode == _frameMode,
                        onSelected: (_) =>
                            Navigator.of(context).pop(mode),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted || selected == _frameMode) return;
    _frameMode = selected;
    await widget.store.setHongguoFrameMode(selected.name);
    if (mounted) setState(() {});
  }

  Future<void> _openRotationSheet() async {
    const rotations = [0, 90, 180, 270];
    final selected = await showModalBottomSheet<int>(
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
                '旋转',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Wrap(
                spacing: 8,
                children: rotations
                    .map(
                      (degrees) => ChoiceChip(
                        label: Text('$degrees°'),
                        selected: degrees == _videoRotation,
                        onSelected: (_) =>
                            Navigator.of(context).pop(degrees),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted || selected == _videoRotation) return;
    _videoRotation = selected;
    await widget.store.setHongguoVideoRotation(selected);
    if (mounted) setState(() {});
  }

  Future<void> _openSleepTimerSheet() async {
    await showSleepTimerSheet(
      context,
      controller: _sleepTimer,
      onSelect: (choice) {
        _sleepTimer.select(choice);
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _openMoreSheet() async {
    final favorite = widget.store.isFavorite(widget.drama.id);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    favorite
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
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
                  leading: const Icon(Icons.high_quality_rounded),
                  title: const Text('清晰度'),
                  trailing: Text(_qualityLabel()),
                  onTap: () {
                    Navigator.of(context).pop();
                    Future.microtask(() {
                      if (mounted) _openQualitySheet();
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.aspect_ratio_rounded),
                  title: const Text('画面模式'),
                  trailing: Text(_frameMode.label),
                  onTap: () {
                    Navigator.of(context).pop();
                    Future.microtask(() {
                      if (mounted) _openFrameSheet();
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.screen_rotation_alt_rounded),
                  title: const Text('旋转'),
                  trailing: Text('$_videoRotation°'),
                  onTap: () {
                    Navigator.of(context).pop();
                    Future.microtask(() {
                      if (mounted) _openRotationSheet();
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.bedtime_outlined),
                  title: const Text('睡眠定时'),
                  trailing: Text(
                    _sleepTimer.active ? _sleepTimer.label : '未设置',
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    Future.microtask(() {
                      if (mounted) _openSleepTimerSheet();
                    });
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.playlist_play_rounded),
                  title: const Text('自动连播'),
                  value: widget.store.playbackPreferences.autoAdvance,
                  onChanged: (value) async {
                    final prefs = widget.store.playbackPreferences;
                    await widget.store.setPlaybackPreferences(
                      prefs.copyWith(autoAdvance: value),
                    );
                    setSheetState(() {});
                    if (mounted) setState(() {});
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.skip_next_rounded),
                  title: const Text('跨季自动连播（需开启自动连播）'),
                  subtitle: widget.store.playbackPreferences.autoAdvance
                      ? null
                      : const Text('自动连播未开，本开关暂不生效'),
                  value: widget.store.hongguoSeasonAutoplay,
                  onChanged: (value) async {
                    await widget.store.setHongguoSeasonAutoplay(value);
                    setSheetState(() {});
                    if (mounted) setState(() {});
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.linear_scale_rounded),
                  title: const Text('全屏常驻播放进度'),
                  value: widget.store.hongguoAlwaysShowProgress,
                  onChanged: (value) async {
                    await widget.store.setHongguoAlwaysShowProgress(value);
                    setSheetState(() {});
                    if (mounted) setState(() {});
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
            // 常驻播放进度：开关默认关；开着时即使控制层隐藏也可见。
            if (widget.store.hongguoAlwaysShowProgress)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: _alwaysOnProgress(),
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
          onTap: _openQualitySheet,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.high_quality_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 4),
                Text(
                  _qualityLabel(),
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
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
            return _frameWrap(
              Stack(
                fit: StackFit.expand,
                children: [
                  RoomPlayerView(
                    handle: _player,
                    viewType: TvboxPlayerController.viewType,
                    onCompleted: _onCompleted,
                    onError: (_) {},
                    onRetry: _manualRetry,
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
                  if (_recoveryArmed)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 8,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            '正在重试 · 第 ${_recoveryBudget.used} 次',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_recoveryExhausted)
                    Positioned.fill(child: _recoveryExhaustedPanel()),
                ],
              ),
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

  // 画面模式与旋转：包在播放器 widget 外面一层，不改系统方向。
  // 旋转 90/270° 后有效宽高比取倒数，再按该比例算画面模式缩放。
  Widget _frameWrap(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var wrapped = child;
        if (_videoRotation != 0) {
          wrapped = RotatedBox(
            quarterTurns: _videoRotation ~/ 90,
            child: wrapped,
          );
        }
        if (_frameMode != HongguoFrameMode.fit &&
            constraints.maxWidth > 0 &&
            constraints.maxHeight > 0) {
          final videoAspect = hongguoVideoAspect(_player);
          final containerAspect =
              constraints.maxWidth / constraints.maxHeight;
          if (videoAspect > 0 && containerAspect > 0) {
            final effectiveAspect =
                (_videoRotation == 90 || _videoRotation == 270)
                ? 1 / videoAspect
                : videoAspect;
            final factors = HongguoFrameFit.scale(
              mode: _frameMode,
              videoAspect: effectiveAspect,
              containerAspect: containerAspect,
            );
            wrapped = ClipRect(
              child: Transform(
                transform: Matrix4.diagonal3Values(
                  factors.scaleX,
                  factors.scaleY,
                  1,
                ),
                alignment: Alignment.center,
                child: wrapped,
              ),
            );
          }
        }
        return wrapped;
      },
    );
  }

  // 全屏常驻进度：细进度条 + 进度文本，控制层之外独立显示。
  // 进度值按千分比算；睡眠定时开着时后缀剩时。
  Widget _alwaysOnProgress() {
    return ListenableBuilder(
      listenable: _player,
      builder: (context, _) {
        final duration = _player.duration;
        return StreamBuilder<double>(
          stream: _player.positionStream,
          initialData: _player.position,
          builder: (context, snapshot) {
            final position = snapshot.data ?? _player.position;
            final permille = hongguoProgressPermille(position, duration);
            final fraction = permille / 1000;
            return ListenableBuilder(
              listenable: _sleepTimer,
              builder: (context, _) {
                final timerSuffix = _sleepTimer.active
                    ? ' · 定时 ${_sleepTimer.label}'
                    : '';
                return Container(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.6),
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${_formatClock(position)} / ${_formatClock(duration)}$timerSuffix',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 3,
                        child: Stack(
                          children: [
                            Container(
                              height: 3,
                              color: Colors.white24,
                            ),
                            FractionallySizedBox(
                              widthFactor: fraction,
                              child: Container(
                                height: 3,
                                color: Colors.white,
                              ),
                            ),
                          ],
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

  // 恢复预算耗尽后的恢复 UI：文案 + 手动重试；全档都不兼容时如实说明。
  Widget _recoveryExhaustedPanel() {
    final lower = _nextLowerQuality();
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '恢复失败',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _recoveryAllQualitiesFailed
                    ? '已尝试全部清晰度档位，仍无法播放。'
                    : '多次重试后仍无法播放，请检查网络后手动重试。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _manualRetry,
                child: const Text('手动重试'),
              ),
              if (lower != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    _requestedQuality = lower;
                    _manualRetry();
                  },
                  child: Text(
                    '换 ${HongguoQualityOptions.label(lower)} 重试',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ],
          ),
        ),
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
