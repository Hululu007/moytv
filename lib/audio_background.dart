import 'dart:ui' show AppLifecycleState;

/// 听书后台 / 锁屏 / 灵动岛三件的纯决策逻辑。
///
/// 不碰平台通道，只做判断与数据组装，可单测。
/// 树里验不了、须手机实测的部分（悬浮窗能否在鸿蒙 NEXT + 卓易通容器里显示、
/// 锁屏媒体界面是否出现）不在这里决定，只由调用方按权限与降级规则处理。

/// 切后台的状态：paused（回家/锁屏）与 hidden（被遮住）。
/// inactive 只是短暂过渡（来电、切后台途中），不算后台。
bool isAudioBackgroundState(AppLifecycleState state) {
  return state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
}

/// 手动暂停跟踪：只记“用户亲手停过没有”。
///
/// 用户在界面、锁屏、胶囊任一处点暂停都算手动暂停；
/// 用户点播放、切章节（含自动连播到下一集）都算用户意图播放，清掉标记。
/// 自动连播不会把标记置起：播完自动下一集时播放本就没停过。
class ManualPauseTracker {
  bool _manuallyPaused = false;

  bool get manuallyPaused => _manuallyPaused;

  void userPaused() {
    _manuallyPaused = true;
  }

  void userPlayed() {
    _manuallyPaused = false;
  }

  void stopped() {
    _manuallyPaused = true;
  }
}

/// 回前台是否自动恢复播放：永远否。
///
/// 播着的切后台本来就没停，不需要恢复；停了的就是用户亲手停的，
/// 不许替用户按播放。回前台只同步进度、播放态、章节。
bool shouldAutoPlayOnResume({
  required bool manuallyPaused,
  required bool wasPlaying,
}) {
  return false;
}

/// 胶囊是否该显示：切后台、正在播、悬浮窗权限已拿到，三件齐了才显示。
///
/// 任一条件不满足就降级：只留通知栏控制，不弹胶囊、不报错、不反复要权限。
bool capsuleShouldShow({
  required bool backgrounded,
  required bool playing,
  required bool overlayGranted,
}) {
  return backgrounded && playing && overlayGranted;
}

/// 锁屏简化播放界面的数据：只含用户列的六项——
/// 书名、章节、封面、播放/暂停、上一章/下一章、进度。
///
/// [hasPrevious]/[hasNext] 是上下章按钮的可用状态，不是额外界面；
/// [rate] 只用来让锁屏进度按实际倍速走字，不在锁屏上显示。
class AudioLockscreenInfo {
  const AudioLockscreenInfo({
    required this.bookTitle,
    required this.chapterTitle,
    required this.coverUrl,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.hasPrevious,
    required this.hasNext,
    required this.rate,
  });

  final String bookTitle;
  final String chapterTitle;
  final String coverUrl;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final bool hasPrevious;
  final bool hasNext;
  final double rate;

  /// 通道载荷：键固定为这 9 个，不多带任何字段。
  Map<String, dynamic> toChannelPayload() {
    final safeDuration = durationMs < 0 ? 0 : durationMs;
    final safePosition = safeDuration > 0
        ? positionMs.clamp(0, safeDuration)
        : (positionMs < 0 ? 0 : positionMs);
    final safeRate = rate.isFinite ? rate.clamp(0.25, 4.0) : 1.0;
    return <String, dynamic>{
      'bookTitle': bookTitle,
      'chapterTitle': chapterTitle,
      'coverUrl': coverUrl,
      'playing': playing,
      'positionMs': safePosition,
      'durationMs': safeDuration,
      'hasPrevious': hasPrevious,
      'hasNext': hasNext,
      'rate': safeRate,
    };
  }
}
