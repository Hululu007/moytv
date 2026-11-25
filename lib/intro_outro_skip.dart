import 'dart:convert';

/// 跳过片头片尾的纯逻辑层（第 7 点，自研实现）。
///
/// 数据按剧存：键是「站源 id + 剧 id」，见 [IntroOutroSettings.keyFor]。
/// 存储由 LocalStore 挂在 SharedPreferences 上（键 introOutroSkipEnabled /
/// introOutroSkipByDrama），本文件只负责模型与判定，不碰存储与播放器，
/// 因此全部可单测。
///
/// 生效规则：
/// - 片头：只对从头播（续播进度约 0）或进度落在片头段内的情形生效，
///   seek 到片头结束处；进度已越过片头时原样保留续播位置，不冲掉。
/// - 片尾：总时长已知、且有下一集时，播放位置进入
///   「总时长 - 片尾时长」后触发切下一集；无下一集不跳。
/// - 防误跳：片头 + 片尾合计超过单集总时长的 [maxSkipRatio]（50%）
///   时整段抑制（短剧一集可能只有几十秒，固定 90+90 秒会把正片跳没）；
///   总时长未知时不跳片尾。抑制原因以 [IntroOutroSuppression] 返回，
///   供设置界面提示与测试断言。
const double maxSkipRatio = 0.5;

/// 单项秒数上限（1 小时），防手滑输入把整集跳完。
const int maxSkipSeconds = 3600;

int _clampSeconds(Object? value) {
  final seconds = value is num ? value.round() : 0;
  return seconds.clamp(0, maxSkipSeconds).toInt();
}

class IntroOutroSettings {
  const IntroOutroSettings({this.introSeconds = 0, this.outroSeconds = 0});

  final int introSeconds;
  final int outroSeconds;

  bool get isEmpty => introSeconds <= 0 && outroSeconds <= 0;

  IntroOutroSettings copyWith({int? introSeconds, int? outroSeconds}) =>
      IntroOutroSettings(
        introSeconds: _clampSeconds(introSeconds ?? this.introSeconds),
        outroSeconds: _clampSeconds(outroSeconds ?? this.outroSeconds),
      );

  Map<String, dynamic> toJson() => {
    'intro': introSeconds,
    'outro': outroSeconds,
  };

  factory IntroOutroSettings.fromJson(Object? value) {
    if (value is! Map) return const IntroOutroSettings();
    return IntroOutroSettings(
      introSeconds: _clampSeconds(value['intro']),
      outroSeconds: _clampSeconds(value['outro']),
    );
  }

  /// 按剧定键：站源 id 与剧 id 拼在一起，同一部剧在不同站互不串。
  static String keyFor(String source, String dramaId) => '$source::$dramaId';

  static Map<String, IntroOutroSettings> decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key.toString().isNotEmpty)
            entry.key.toString(): IntroOutroSettings.fromJson(entry.value),
      }..removeWhere((_, settings) => settings.isEmpty);
    } catch (_) {
      return {};
    }
  }

  static String encodeMap(Map<String, IntroOutroSettings> values) =>
      jsonEncode({
        for (final entry in values.entries)
          if (!entry.value.isEmpty) entry.key: entry.value.toJson(),
      });

  @override
  bool operator ==(Object other) =>
      other is IntroOutroSettings &&
      other.introSeconds == introSeconds &&
      other.outroSeconds == outroSeconds;

  @override
  int get hashCode => Object.hash(introSeconds, outroSeconds);

  @override
  String toString() =>
      'IntroOutroSettings(intro: $introSeconds, outro: $outroSeconds)';
}

/// 跳过被抑制 / 不动作的原因。UI 可据此提示，测试可据此断言。
enum IntroOutroSuppression {
  /// 全局「自动跳过」总开关关着。
  disabled,

  /// 这部剧没设片头/片尾（或对应段为 0 秒）。
  notConfigured,

  /// 单集总时长未知：片尾判定没有锚点，不跳。
  unknownDuration,

  /// 片头+片尾合计超过总时长的 50%：短剧防误跳，整段抑制。
  ratioExceeded,

  /// 续播进度已越过片头：保留用户位置，不往回跳。
  beyondIntro,

  /// 还没播到片尾段。
  beforeOutro,

  /// 没有下一集：片尾不跳，播完为止。
  noNextEpisode,

  /// 本集片尾已经触发过一次（防重复切集）。
  alreadyTriggered,
}

class IntroSkipDecision {
  const IntroSkipDecision.skip(this.targetSeconds)
    : suppression = null;
  const IntroSkipDecision.suppressed(this.suppression) : targetSeconds = null;

  /// 应 seek 到的秒数；null 表示不跳。
  final double? targetSeconds;
  final IntroOutroSuppression? suppression;

  bool get shouldSkip => targetSeconds != null;
}

class OutroSkipDecision {
  const OutroSkipDecision.advance()
    : shouldAdvance = true,
      suppression = null;
  const OutroSkipDecision.suppressed(this.suppression)
    : shouldAdvance = false;

  final bool shouldAdvance;
  final IntroOutroSuppression? suppression;
}

/// 片头+片尾合计是否超过总时长的一定比例（总时长未知/无效时不算超）。
bool skipRatioExceeded({
  required IntroOutroSettings settings,
  required double? durationSeconds,
}) {
  if (durationSeconds == null || durationSeconds <= 0) return false;
  final total = settings.introSeconds + settings.outroSeconds;
  return total > durationSeconds * maxSkipRatio;
}

/// 片头判定：见文件头规则。durationSeconds 未知时片头仍可跳
/// （片头不依赖总时长），只是无法做比例抑制检查。
IntroSkipDecision decideIntroSkip({
  required bool enabled,
  required IntroOutroSettings settings,
  required double resumePositionSeconds,
  double? durationSeconds,
}) {
  if (!enabled) {
    return const IntroSkipDecision.suppressed(
      IntroOutroSuppression.disabled,
    );
  }
  if (settings.introSeconds <= 0) {
    return const IntroSkipDecision.suppressed(
      IntroOutroSuppression.notConfigured,
    );
  }
  if (skipRatioExceeded(settings: settings, durationSeconds: durationSeconds)) {
    return const IntroSkipDecision.suppressed(
      IntroOutroSuppression.ratioExceeded,
    );
  }
  final resume = resumePositionSeconds < 0 ? 0.0 : resumePositionSeconds;
  if (resume >= settings.introSeconds) {
    return const IntroSkipDecision.suppressed(
      IntroOutroSuppression.beyondIntro,
    );
  }
  return IntroSkipDecision.skip(settings.introSeconds.toDouble());
}

/// 片尾判定：见文件头规则。
OutroSkipDecision decideOutroSkip({
  required bool enabled,
  required IntroOutroSettings settings,
  required double positionSeconds,
  required double? durationSeconds,
  required bool hasNextEpisode,
}) {
  if (!enabled) {
    return const OutroSkipDecision.suppressed(
      IntroOutroSuppression.disabled,
    );
  }
  if (settings.outroSeconds <= 0) {
    return const OutroSkipDecision.suppressed(
      IntroOutroSuppression.notConfigured,
    );
  }
  if (durationSeconds == null || durationSeconds <= 0) {
    return const OutroSkipDecision.suppressed(
      IntroOutroSuppression.unknownDuration,
    );
  }
  if (skipRatioExceeded(settings: settings, durationSeconds: durationSeconds)) {
    return const OutroSkipDecision.suppressed(
      IntroOutroSuppression.ratioExceeded,
    );
  }
  if (!hasNextEpisode) {
    return const OutroSkipDecision.suppressed(
      IntroOutroSuppression.noNextEpisode,
    );
  }
  final triggerAt = durationSeconds - settings.outroSeconds;
  if (positionSeconds < triggerAt) {
    return const OutroSkipDecision.suppressed(
      IntroOutroSuppression.beforeOutro,
    );
  }
  return const OutroSkipDecision.advance();
}

/// 会话级状态：记住每集片尾已触发过，避免位置监听反复切集；
/// 同时留最近一次片尾抑制原因，供 UI 提示与测试断言。
class IntroOutroSkipEngine {
  final Set<String> _outroFiredEpisodeKeys = {};
  IntroOutroSuppression? _lastOutroSuppression;
  IntroOutroSuppression? get lastOutroSuppression => _lastOutroSuppression;

  /// 本集片尾是否应在此刻切下一集。每集只返回一次 true。
  bool consumeOutro({
    required String episodeKey,
    required bool enabled,
    required IntroOutroSettings settings,
    required double positionSeconds,
    required double? durationSeconds,
    required bool hasNextEpisode,
  }) {
    if (_outroFiredEpisodeKeys.contains(episodeKey)) {
      _lastOutroSuppression = IntroOutroSuppression.alreadyTriggered;
      return false;
    }
    final decision = decideOutroSkip(
      enabled: enabled,
      settings: settings,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      hasNextEpisode: hasNextEpisode,
    );
    _lastOutroSuppression = decision.suppression;
    if (!decision.shouldAdvance) return false;
    _outroFiredEpisodeKeys.add(episodeKey);
    return true;
  }

  void reset() {
    _outroFiredEpisodeKeys.clear();
    _lastOutroSuppression = null;
  }
}
