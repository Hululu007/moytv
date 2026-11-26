import 'dart:async';

import 'models.dart';

/// 无缝换集可用的播放内核。EXO / MPV 支持双播放器首帧预热对调；
/// IJK 插件是 prepare 完自动开播、没有暂停预热模式，也没有首帧
/// 事件，能力不够，恒降级为现行换集（见 SeamlessStandbyManager
/// 的调用方判定，这里只留枚举位以便状态可述）。
enum SeamlessKernel { exo, mpv, ijk }

enum SeamlessPhase { idle, warming, ready, failed }

/// 待命播放器的身份键：同一播放会话（session）即同一逻辑播放，
/// 地址经 302 预解析改写也不影响命中；无会话的直链按地址认。
String seamlessStandbyKey({required int index, required PlaybackPlan plan}) {
  final identity = plan.session.isNotEmpty
      ? 's:${plan.session}'
      : 'u:${plan.url}';
  return '$index|$identity';
}

/// 这条 plan 能不能拿去给待命播放器预热首帧：
/// - 本地文件不用预热（打开即播）；
/// - 需要解析 / 是网页地址的，解析出直链前没法喂给播放器；
/// - 带内存解密密钥的走专用解密路，不预热；
/// - 音频文件集走音频路，不预热。
/// DRM plan 只在 EXO 核可播，由调用方按内核再判，这里不拦。
bool seamlessPlanWarmable(PlaybackPlan plan) {
  if (plan.local || plan.url.isEmpty) return false;
  if (plan.needsParse || plan.decryptionKey.isNotEmpty) return false;
  final lower = plan.url.split('?').first.toLowerCase();
  if (lower.endsWith('.html') ||
      lower.endsWith('.htm') ||
      lower.endsWith('.php')) {
    return false;
  }
  const audioSuffixes = ['.mp3', '.m4a', '.aac', '.opus', '.ogg', '.wav'];
  for (final suffix in audioSuffixes) {
    if (lower.endsWith(suffix)) return false;
  }
  return true;
}

/// 无缝换集的待命状态机：只管账，不碰具体播放器。
///
/// 调用方（播放页）在预加载备好下一集 plan 后调 [warm]，并把
/// 「内核侧首帧就绪」的 Future 交进来（EXO 看首帧渲染事件、
/// MPV 看 videoParams 到达）；首帧在超时内到达 → ready，
/// 失败或超时 → failed，调用方据此拆掉内核侧待命、回落常规换集。
/// 换集时调用方用 [take] 按 key 取走待命：命中才做对调，
/// 没命中（没预热好 / 目标不对 / 已失败）走常规路，天然回落。
class SeamlessStandbyManager {
  SeamlessStandbyManager({
    this.firstFrameTimeout = const Duration(seconds: 8),
  });

  final Duration firstFrameTimeout;

  SeamlessPhase _phase = SeamlessPhase.idle;
  String? _key;
  int? _targetIndex;
  SeamlessKernel? _kernel;
  PlaybackPlan? _plan;
  int _generation = 0;

  SeamlessPhase get phase => _phase;
  String? get key => _key;
  int? get targetIndex => _targetIndex;
  SeamlessKernel? get kernel => _kernel;
  PlaybackPlan? get plan => _plan;
  bool get hasStandby =>
      _phase == SeamlessPhase.warming || _phase == SeamlessPhase.ready;
  bool get isReady => _phase == SeamlessPhase.ready;

  /// 开始为 [key] 预热。同 key 已在预热中或已就绪时直接返回，
  /// 不重复折腾内核侧；不同 key 会顶掉旧待命（旧的首帧结果
  /// 回来时按代次丢弃）。返回的 Future 在状态落定
  /// （ready / failed / 被顶掉或丢弃）时完成。
  Future<void> warm({
    required String key,
    required int targetIndex,
    required SeamlessKernel kernel,
    required PlaybackPlan plan,
    required Future<bool> firstFrame,
  }) async {
    if (_key == key &&
        (_phase == SeamlessPhase.warming || _phase == SeamlessPhase.ready)) {
      return;
    }
    final ticket = ++_generation;
    _phase = SeamlessPhase.warming;
    _key = key;
    _targetIndex = targetIndex;
    _kernel = kernel;
    _plan = plan;
    var ok = false;
    try {
      ok = await firstFrame.timeout(
        firstFrameTimeout,
        onTimeout: () => false,
      );
    } catch (_) {
      ok = false;
    }
    if (ticket != _generation) return;
    _phase = ok ? SeamlessPhase.ready : SeamlessPhase.failed;
  }

  /// 换集时取走待命：key 对得上且已就绪才返回 plan 并复位，
  /// 否则返回 null（调用方走常规换集）。
  PlaybackPlan? take(String key) {
    if (_phase != SeamlessPhase.ready || _key != key) return null;
    final plan = _plan;
    discard();
    return plan;
  }

  /// 丢弃待命（目标变了 / 关了无缝 / 预热条件失效）。内核侧的
  /// 实际拆除由调用方在调本方法前后自行完成。
  void discard() {
    _generation++;
    _phase = SeamlessPhase.idle;
    _key = null;
    _targetIndex = null;
    _kernel = null;
    _plan = null;
  }
}
