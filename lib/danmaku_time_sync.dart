import 'danmaku_models.dart';

class DanmakuTimeSync {
  DanmakuTimeSync({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  DateTime? _anchorTime;
  int _anchorPosition = 0;
  double _anchorRate = 1;
  bool _anchorMoving = false;

  void reset({
    required int positionMs,
    required double rate,
    required bool moving,
  }) {
    _anchorTime = _now();
    _anchorPosition = positionMs;
    _anchorRate = rate;
    _anchorMoving = moving;
  }

  num expectedPosition() {
    final elapsed = _anchorTime == null
        ? 0
        : _now()
              .difference(_anchorTime!)
              .inMilliseconds
              .clamp(0, danmakuMaxDurationMs);
    return _anchorPosition + (_anchorMoving ? elapsed * _anchorRate : 0);
  }
}
