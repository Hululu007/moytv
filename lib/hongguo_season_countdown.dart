import 'dart:async';

import 'package:flutter/material.dart';

/// 跨季连播倒计时秒数：播完本季最后一集后等这么久再切下一季。
const hongguoSeasonCountdownSeconds = 5;

/// 跨季连播倒计时状态机：1 秒一跳，remaining 从 totalSeconds 减到
/// 0 时触发一次 onFire；cancel/dispose 后不再触发。播放页持有，
/// 切集/退出/取消时 cancel；测试用 fakeAsync 驱动 Timer。
class SeasonAutoplayCountdown extends ChangeNotifier {
  SeasonAutoplayCountdown({
    required this.onFire,
    this.totalSeconds = hongguoSeasonCountdownSeconds,
  }) : _remaining = totalSeconds;

  final VoidCallback onFire;
  final int totalSeconds;

  Timer? _timer;
  int _remaining;

  int get remaining => _remaining;
  bool get active => _timer != null;

  void start() {
    cancel();
    _remaining = totalSeconds;
    notifyListeners();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _remaining--;
      if (_remaining <= 0) {
        cancel();
        onFire();
      } else {
        notifyListeners();
      }
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}

/// 跨季连播倒计时提示卡：显示下一季名字 + 剩余秒数 + 取消钮。
/// 放在视频画面 Stack 里（竖屏/全屏共用 _videoArea，都能看到）。
class SeasonAutoplayCountdownOverlay extends StatelessWidget {
  const SeasonAutoplayCountdownOverlay({
    super.key,
    required this.nextTitle,
    required this.seasonLabel,
    required this.remaining,
    required this.onCancel,
  });

  final String nextTitle;
  final String seasonLabel;
  final int remaining;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('season-countdown-overlay'),
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '即将播放下一季',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            seasonLabel.isEmpty ? nextTitle : '$seasonLabel · $nextTitle',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$remaining 秒后自动播放',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          TextButton(
            key: const ValueKey('season-countdown-cancel'),
            onPressed: onCancel,
            child: const Text('取消', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
