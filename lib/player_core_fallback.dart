import 'package:shared_preferences/shared_preferences.dart';

import 'player_core.dart';

/// 核间回退的失败分类：各播放核（EXO 平台视图 / MPV media_kit /
/// IJK）上报的错误形态各异，统一先归到这四类，再按回退档位决定
/// 是否换核。与 playback_error.dart 的面向用户分类（网络/站源/
/// 解码/权限）分工不同：那套决定报错文案，这套决定换不换核。
enum CoreFailureKind { decode, network, formatUnsupported, other }

/// 把一个核上报的失败归类。纯函数，可单测。
///
/// 输入形态：
/// - [message]：错误文本。MPV 是 stream.error 的字符串，EXO/IJK 是
///   平台通道回传的字符串，结构化异常走 toString() 后也落到这里。
/// - [code]：可选的结构化错误码（如 ExoPlayer 的
///   ERROR_CODE_DECODER_INIT_FAILED、media_kit/MPV 的数字码），
///   与文本一起参与匹配。
///
/// 判定顺序定死：格式不支持 → 解码 → 网络 → 其他。
/// 格式优先于解码：「格式不支持」常与 codec 一词同时出现，先判
/// 格式才能让「仅解码类回退」档位把它算作可换核的格式问题。
/// 网络放在解码之后：解码错误文案偶尔带 http 字样（流地址），
/// 先判解码避免把核自身的问题误判成网络问题而不换核。
CoreFailureKind classifyPlayerCoreFailure(String message, {Object? code}) {
  final text = '${code ?? ''} $message'.toLowerCase();
  if (_matches(text, const [
    '格式不支持',
    '不支持该格式',
    '不支持的格式',
    '容器不支持',
    'unsupported format',
    'format not supported',
    'unsupported container',
    'unknown format',
    'unrecognized format',
    'invalid data found',
    'moov atom not found',
    'error_code_parser',
    'parser_exception',
    'no playable stream',
    'demuxer failed',
    'failed to open demuxer',
  ])) {
    return CoreFailureKind.formatUnsupported;
  }
  if (_matches(text, const [
    '解码',
    '无法解码',
    '解码器',
    'decode',
    'decoder',
    'codec',
    'mediacodec',
    'hwdec',
    'video_decoder',
    'audio_decoder',
    'error_code_decoder',
    'decoder_init_failed',
    'decoder_query_failed',
    'no decoder',
    '渲染失败',
    'rendering failed',
    'renderer error',
    'error_code_renderer',
  ])) {
    return CoreFailureKind.decode;
  }
  if (_matches(text, const [
    '网络',
    '连接',
    '超时',
    '断网',
    'network',
    'timeout',
    'timed out',
    'socket',
    'dns',
    'failed host lookup',
    'connection refused',
    'connection reset',
    'reset by peer',
    'unreachable',
    'http error',
    'error_code_io',
    'io_network',
    '502',
    '503',
    '504',
    '500 internal',
    '404 not found',
    'failed to load resource',
    '无法加载',
    '加载失败',
  ])) {
    return CoreFailureKind.network;
  }
  return CoreFailureKind.other;
}

bool _matches(String text, List<String> needles) => needles.any(text.contains);

/// 回退档位（设置项）：
/// - [all] 全回退：任何分类的失败都按序换核。
/// - [decodeOnly] 仅解码类回退：只有解码失败与格式不支持才换核；
///   网络失败、其他失败直接报错。
/// - [playerOnly] 仅播放器回退：只有核自身的问题才换核——解码、
///   格式不支持、其他/未知（无法归因到网络时按核自身处理）；
///   网络失败不换核，直接报错（换核也解决不了断网）。
/// - [off] 关：不换核，失败直接报错。
enum CoreFallbackMode {
  all('all', '全回退', '任何播放失败都自动换核重试'),
  decodeOnly('decode_only', '仅解码类回退', '只有解码失败或格式不支持才换核'),
  playerOnly('player_only', '仅播放器回退', '只有播放器自身报错才换核，网络失败直接报错'),
  off('off', '关', '不自动换核，失败直接报错');

  const CoreFallbackMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static CoreFallbackMode parse(String? value) => CoreFallbackMode.values
      .firstWhere((mode) => mode.id == value, orElse: () => CoreFallbackMode.all);

  bool allows(CoreFailureKind kind) => switch (this) {
    CoreFallbackMode.all => true,
    CoreFallbackMode.decodeOnly =>
      kind == CoreFailureKind.decode ||
          kind == CoreFailureKind.formatUnsupported,
    CoreFallbackMode.playerOnly => kind != CoreFailureKind.network,
    CoreFallbackMode.off => false,
  };
}

class CoreFallbackModeStorage {
  static const String key = 'playerCoreFallbackMode';

  static CoreFallbackMode read(SharedPreferences preferences) =>
      CoreFallbackMode.parse(preferences.getString(key));

  static Future<void> write(
    SharedPreferences preferences,
    CoreFallbackMode mode,
  ) => preferences.setString(key, mode.id);
}

/// 固定的核回退顺序（定死）：MPV → EXO → IJK。
/// 一次会话从起始核出发，沿这个环形顺序取下一个没试过的核：
/// 例：起始 MPV → EXO → IJK；起始 EXO → IJK → MPV；
/// 起始 IJK → MPV → EXO。每个核最多试一次，全试完返回 null。
const List<PlayerCore> coreFallbackOrder = [
  PlayerCore.mpv,
  PlayerCore.exo,
  PlayerCore.ijk,
];

List<PlayerCore> coreFallbackSequence(PlayerCore start) {
  final index = coreFallbackOrder.indexOf(start);
  if (index < 0) return List.of(coreFallbackOrder);
  return [
    for (var i = 1; i < coreFallbackOrder.length; i++)
      coreFallbackOrder[(index + i) % coreFallbackOrder.length],
  ];
}

/// 一次播放会话的核回退状态机（纯逻辑，可单测）。
/// 会话 = 同一集的一次播放尝试链；换集/手动换核都应新建会话。
class CoreFallbackController {
  CoreFallbackController({
    required PlayerCore start,
    this.mode = CoreFallbackMode.all,
  }) : _current = start,
       _sessionStart = start,
       _tried = {start},
       _attemptOrder = [start];

  final CoreFallbackMode mode;
  PlayerCore _current;
  PlayerCore _sessionStart;
  final Set<PlayerCore> _tried;
  final List<PlayerCore> _attemptOrder;

  PlayerCore get current => _current;

  /// 已实际尝试过的核（含起始核），按尝试先后。
  List<PlayerCore> get attempts => List.unmodifiable(_attemptOrder);

  Set<PlayerCore> get tried => Set.unmodifiable(_tried);

  bool get hasUntried => _tried.length < PlayerCore.values.length;

  /// 当前核以 [kind] 失败后，决定下一个要试的核。
  /// 档位不允许该分类换核、或所有核都试过时返回 null（把错误抛给用户）。
  PlayerCore? advance(CoreFailureKind kind) {
    if (!mode.allows(kind)) return null;
    for (final next in coreFallbackSequence(_sessionStart)) {
      // 环形序列从起始核出发；跳过已试过的，并保证不回到当前核重复试。
      if (_tried.contains(next)) continue;
      _tried.add(next);
      _attemptOrder.add(next);
      _current = next;
      return next;
    }
    // 起始核之外的都试过时，环形序列已覆盖全部核；无核可换。
    return null;
  }

  void reset(PlayerCore start) {
    _current = start;
    _sessionStart = start;
    _tried
      ..clear()
      ..add(start);
    _attemptOrder
      ..clear()
      ..add(start);
  }
}

/// 换核时要保留的播放上下文：集数与续播位置（秒）。
/// 换核只换 [core]，episodeIndex 与 resumePositionSeconds 原样带过去，
/// 从失败点续播，不从头来。
class CoreFallbackAttempt {
  const CoreFallbackAttempt({
    required this.core,
    required this.episodeIndex,
    required this.resumePositionSeconds,
    required this.attemptNumber,
  });

  final PlayerCore core;
  final int episodeIndex;
  final double resumePositionSeconds;
  final int attemptNumber;
}

class CorePlaybackFailure implements Exception {
  const CorePlaybackFailure(this.kind, this.message);

  final CoreFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// 全部核都失败（或档位不允许继续）时抛出的终态错误。
class CoreFallbackExhausted implements Exception {
  const CoreFallbackExhausted({
    required this.attemptedCores,
    required this.lastKind,
    required this.lastError,
  });

  final List<PlayerCore> attemptedCores;
  final CoreFailureKind lastKind;
  final Object lastError;

  @override
  String toString() => lastError.toString();
}

class CoreFallbackOutcome<T> {
  const CoreFallbackOutcome({
    required this.value,
    required this.coreUsed,
    required this.attemptedCores,
  });

  final T value;
  final PlayerCore coreUsed;
  final List<PlayerCore> attemptedCores;
}

/// 通用编排：用 [attempt] 在起始核上播放，失败后按档位与固定顺序
/// 换核重试。每 次换核前调用 [currentPositionSeconds] 取最新进度，
/// 作为下个核的续播位置；集数全程不变。任何一个核成功即返回；
/// 档位不允许换核或全核失败时抛 [CoreFallbackExhausted]。
Future<CoreFallbackOutcome<T>> runWithCoreFallback<T>({
  required PlayerCore start,
  required CoreFallbackMode mode,
  required int episodeIndex,
  required double initialPositionSeconds,
  required Future<T> Function(CoreFallbackAttempt attempt) attempt,
  double Function()? currentPositionSeconds,
  CoreFailureKind Function(Object error)? classifyError,
}) async {
  final controller = CoreFallbackController(start: start, mode: mode);
  var resume = initialPositionSeconds;
  var attemptNumber = 0;
  while (true) {
    attemptNumber++;
    final current = controller.current;
    try {
      final value = await attempt(
        CoreFallbackAttempt(
          core: current,
          episodeIndex: episodeIndex,
          resumePositionSeconds: resume,
          attemptNumber: attemptNumber,
        ),
      );
      return CoreFallbackOutcome(
        value: value,
        coreUsed: current,
        attemptedCores: controller.attempts,
      );
    } catch (error) {
      final kind = error is CorePlaybackFailure
          ? error.kind
          : (classifyError?.call(error) ??
                classifyPlayerCoreFailure(error.toString()));
      final next = controller.advance(kind);
      if (next == null) {
        throw CoreFallbackExhausted(
          attemptedCores: controller.attempts,
          lastKind: kind,
          lastError: error,
        );
      }
      final latest = currentPositionSeconds?.call();
      if (latest != null && latest.isFinite && latest > 0) {
        resume = latest;
      }
    }
  }
}
