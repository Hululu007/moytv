/// 自动刷新节流门：判断“距上次刷新是否已满节流窗”，与 widget 解耦、可单测。
///
/// 语义：自动刷新最多每 [throttle] 一次；手动刷新（🔄 钮/下拉）不受
/// 节流限制，完成时调 [markRefreshed] 重置计时。构造时默认记一次
/// “刚刷过”：应用启动时首批数据正在加载，首次回到前台/切回首页
/// 不额外触发；被跳过的触发不改状态、不重置计时。
class AutoRefreshGate {
  AutoRefreshGate({
    DateTime? lastRefresh,
    this.throttle = const Duration(minutes: 5),
  }) : _lastRefresh = lastRefresh ?? DateTime.now();

  /// 默认节流窗：5 分钟。
  static const defaultThrottle = Duration(minutes: 5);

  final Duration throttle;
  DateTime? _lastRefresh;

  /// 纯判断：距 [lastRefresh] 是否已满 [throttle]。从未刷过时为真。
  static bool shouldRefresh(
    DateTime? lastRefresh,
    DateTime now, {
    Duration throttle = defaultThrottle,
  }) {
    if (lastRefresh == null) return true;
    return now.difference(lastRefresh) >= throttle;
  }

  /// 节流窗已满则认领一次刷新（记下时间戳）并返回 true，否则返回
  /// false 且不改状态。
  bool tryClaim([DateTime? now]) {
    final at = now ?? DateTime.now();
    if (!shouldRefresh(_lastRefresh, at, throttle: throttle)) return false;
    _lastRefresh = at;
    return true;
  }

  /// 记一次刷新完成（手动/自动均可），重置计时。
  void markRefreshed([DateTime? now]) {
    _lastRefresh = now ?? DateTime.now();
  }
}
