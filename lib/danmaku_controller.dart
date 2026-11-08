import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'danmaku_loader.dart';
import 'danmaku_models.dart';
import 'danmaku_time_sync.dart';
import 'local_danmaku_store.dart';
import 'models.dart';

class DanmakuController extends ChangeNotifier {
  DanmakuController(this.repository, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _loader = DanmakuLoader(
      now: _now,
      state: () => DanmakuWindowState(
        visible: visible,
        buffering: _buffering,
        positionMs: positionMs,
        moving: moving,
        durationMs: durationMs,
        plan: _plan,
      ),
      loadPage: (plan, start, duration) =>
          _bySeries != null &&
                  _byVideo != null &&
                  plan.session == _byIdSession
              ? repository.danmakuById(
                  _bySeries!,
                  _byVideo!,
                  startMs: start,
                  durationMs: duration,
                )
              : repository.danmaku(plan, startMs: start, durationMs: duration),
      cancelLoad: () => repository.cancelDanmaku(),
      onItems: (list) {
        _remoteItems = list;
        dataRevision++;
      },
      onChanged: notifyListeners,
    );
    _sync = DanmakuTimeSync(now: _now);
  }

  final AppRepository repository;
  final DateTime Function() _now;
  late final DanmakuLoader _loader;
  late final DanmakuTimeSync _sync;
  PlaybackPlan? _plan;
  PlaybackPlan? _basePlan;
  String? _bySeries;
  String? _byVideo;
  static const String _byIdSession = 'byid';
  bool _closed = false;
  bool _enabled = true;
  bool _available = false;
  bool _foreground = true;
  bool _playing = false;
  bool _buffering = false;
  bool _seeking = false;
  DateTime _lastPositionNotification = DateTime.fromMillisecondsSinceEpoch(0);
  int positionMs = 0;
  int durationMs = 0;
  double rate = 1;
  int motionRevision = 0;
  int dataRevision = 0;
  List<DanmakuItem> _remoteItems = const [];
  List<DanmakuItem> _localItems = const [];
  String? _localKey;
  int _localLoadToken = 0;

  List<DanmakuItem> get items => [..._remoteItems, ..._localItems];

  bool get supported =>
      _plan != null &&
      !_plan!.local &&
      _plan!.session.isNotEmpty &&
      _plan!.danmakuId.isNotEmpty;
  bool get visible =>
      !_closed &&
      supported &&
      _enabled &&
      _available &&
      _foreground &&
      !_seeking &&
      durationMs > 0 &&
      positionMs < durationMs;
  bool get moving => visible && _playing && !_buffering;
  bool get localVisible =>
      !_closed &&
      _enabled &&
      _available &&
      _foreground &&
      !_seeking &&
      durationMs > 0 &&
      positionMs < durationMs &&
      _localItems.isNotEmpty;
  bool get anyVisible => visible || localVisible;
  bool get anyMoving =>
      anyVisible && _playing && !_buffering;
  bool get canSendLocal => _localKey != null;
  bool get loading => _loader.loading;
  bool get canRetry => visible && _loader.hasFailures;
  String get status {
    if (!_enabled) return '弹幕已关闭';
    if (_plan?.local == true) {
      return _localItems.isEmpty
          ? '暂无本地弹幕'
          : '本地弹幕 ${_localItems.length} 条';
    }
    if (_plan != null && !supported) return '本集暂不支持弹幕';
    if (canRetry) return '弹幕暂不可用，可重试';
    if (loading && !_loader.hasPages) return '正在加载弹幕';
    if (_loader.hasPages) {
      return items.isEmpty ? '这段暂无弹幕' : '已载入 ${items.length} 条弹幕';
    }
    return '等待播放';
  }

  void setPlan(PlaybackPlan? plan) {
    if (_closed || identical(_basePlan, plan)) return;
    _cancel();
    _basePlan = plan;
    _plan = plan;
    _bySeries = null;
    _byVideo = null;
    _loader.clearPages();
    _seeking = false;
    _available = false;
    positionMs = durationMs = 0;
    _resetMotion();
    _localItems = const [];
    _localKey = _computeLocalKey();
    _loadLocal();
    notifyListeners();
  }

  void setById(String? seriesId, String? videoId) {
    if (_closed) return;
    if (_bySeries == seriesId && _byVideo == videoId) return;
    _bySeries = seriesId;
    _byVideo = videoId;
    final base = _basePlan;
    if (base == null) return;
    final next = seriesId != null &&
            videoId != null &&
            !base.local &&
            (base.session.isEmpty || base.danmakuId.isEmpty)
        ? base.withDanmaku(_byIdSession, videoId)
        : base;
    if (identical(_plan, next)) return;
    _cancel();
    _plan = next;
    _loader.clearPages();
    _resetMotion();
    _localItems = const [];
    _localKey = _computeLocalKey();
    _loadLocal();
    notifyListeners();
    _ensureWindow();
  }

  Future<void> sendLocal(String text) async {
    final key = _localKey;
    final trimmed = text.trim();
    if (_closed || key == null || trimmed.isEmpty) return;
    final entry = LocalDanmakuEntry(text: trimmed, timeMs: positionMs);
    await LocalDanmakuStore.add(key, entry);
    if (_closed || _localKey != key) return;
    _localItems = [
      ..._localItems,
      DanmakuItem(
        id: 'local:$key:${_localItems.length}',
        text: entry.text,
        timeMs: entry.timeMs,
      ),
    ];
    dataRevision++;
    notifyListeners();
  }

  Future<void> clearLocal() async {
    final key = _localKey;
    if (_closed || key == null) return;
    await LocalDanmakuStore.clear(key);
    if (_closed || _localKey != key) return;
    _localItems = const [];
    dataRevision++;
    notifyListeners();
  }

  String? _computeLocalKey() {
    if (_bySeries != null && _byVideo != null) {
      return 'byid:$_bySeries:$_byVideo';
    }
    final plan = _plan;
    if (plan == null) return null;
    if (plan.danmakuId.isNotEmpty) return 'dm:${plan.danmakuId}';
    if (plan.local) return 'local:${plan.url}';
    return null;
  }

  Future<void> _loadLocal() async {
    final key = _localKey;
    final token = ++_localLoadToken;
    if (key == null) return;
    final entries = await LocalDanmakuStore.load(key);
    if (_closed || token != _localLoadToken || _localKey != key) return;
    _localItems = [
      for (var i = 0; i < entries.length; i++)
        DanmakuItem(
          id: 'local:$key:$i',
          text: entries[i].text,
          timeMs: entries[i].timeMs,
        ),
    ];
    dataRevision++;
    notifyListeners();
  }

  void setEnabled(bool enabled) {
    if (_closed || _enabled == enabled) return;
    _enabled = enabled;
    _cancel();
    _loader.clearPages();
    _resetMotion();
    notifyListeners();
    _ensureWindow();
  }

  void update({
    required Duration position,
    required Duration duration,
    required double speed,
    required bool playing,
    required bool buffering,
    required bool foreground,
    required bool available,
    bool discontinuity = false,
  }) {
    if (_closed) return;
    final wasVisible = anyVisible, wasMoving = anyMoving;
    final previousRate = rate;
    final nextPosition = position.inMilliseconds.clamp(0, danmakuMaxDurationMs);
    final nextDuration = duration.inMilliseconds;
    final expected = _sync.expectedPosition();
    final drift = !_seeking && (nextPosition - expected).abs() > 600;
    final durationChanged = nextDuration != durationMs && durationMs > 0;
    final jumped =
        !_seeking &&
        (discontinuity ||
            nextPosition < positionMs ||
            nextPosition - positionMs > 2000);
    if (durationChanged) {
      _cancel();
      _loader.clearPages();
    } else if (jumped) {
      _cancel();
    }
    if (!_seeking) positionMs = nextPosition;
    durationMs = nextDuration > 0 && nextDuration <= danmakuMaxDurationMs
        ? nextDuration
        : 0;
    rate = speed.isFinite && speed > 0 ? speed : 1;
    _playing = playing;
    _buffering = buffering;
    _foreground = foreground;
    _available = available;
    if (wasVisible && !anyVisible) _cancel();
    final motionChanged =
        drift ||
        jumped ||
        durationChanged ||
        wasVisible != anyVisible ||
        wasMoving != anyMoving ||
        previousRate != rate;
    if (motionChanged) {
      _resetMotion();
    }
    final now = _now();
    if (motionChanged ||
        anyMoving &&
            items.isNotEmpty &&
            now.difference(_lastPositionNotification).inMilliseconds >= 250) {
      _lastPositionNotification = now;
      notifyListeners();
    }
    _ensureWindow();
  }

  void beginSeek() {
    if (_closed) return;
    _cancel();
    _seeking = true;
    _resetMotion();
    notifyListeners();
  }

  void endSeek(Duration position) {
    if (_closed) return;
    _seeking = false;
    positionMs = position.inMilliseconds.clamp(0, danmakuMaxDurationMs);
    _resetMotion();
    notifyListeners();
    _ensureWindow();
  }

  void retry() {
    if (_closed || !visible) return;
    _loader.clearFailures();
    _ensureWindow();
    notifyListeners();
  }

  void _resetMotion() {
    motionRevision++;
    _sync.reset(positionMs: positionMs, rate: rate, moving: anyMoving);
  }

  void _cancel() {
    _loader.cancel();
  }

  void _ensureWindow() {
    _loader.ensureWindow();
  }

  @override
  void dispose() {
    _closed = true;
    _cancel();
    super.dispose();
  }
}
