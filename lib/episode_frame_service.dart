import 'dart:async';
import 'dart:typed_data';

import 'episode_frame_cache.dart';
import 'models.dart';

/// 选集解析：复用播放链（仓库/蜘蛛链，含 Go 中继解密后的地址）。
typedef EpisodeFrameResolver =
    Future<PlaybackPlan> Function(Drama drama, Episode episode);

/// 取帧：给定已解析的播放计划，取一帧 JPEG，失败返回 null。
typedef EpisodeFrameExtractor =
    Future<Uint8List?> Function(PlaybackPlan plan);

/// 释放播放会话（中继 session 用完即放，不占 8 会话位）。
typedef EpisodeFrameReleaser = Future<void> Function(String session);

class _FrameJob {
  const _FrameJob(this.drama, this.episode, this.key);

  final Drama drama;
  final Episode episode;
  final String key;
}

/// 后台取帧服务：只为当前详情页可见范围内的选集取真实视频帧，
/// 经 [EpisodeFrameCache.saveFrame] 进现有缓存，卡片复用现有刷新链
/// 显示（调用方把 [onFrame] 回调的键并入自己的帧键集合即可）。
///
/// 约束（用户令 + 树内既有行为）：
/// - 每集只取一次：缓存命中、已尝试、取帧中、已排队的都不重复取；
///   缓存命中即止，24 小时内不重复取就是“文件在就不取”。
/// - 并发最多 [maxConcurrent] 路（默认 2），队列按可见顺序推进，
///   滚动/翻页时只补新增的，不雪崩。
/// - [cancel] 后在途任务的结果一律丢弃、不写缓存（但会话照常释放）；
///   取消的任务不记“已尝试”，下次 [prefetch] 可重试。
/// - 解析/取帧/存帧失败一律静默：卡片继续显示剧照/海报。
/// - 不常驻：随详情页创建与销毁，[dispose] 后不再接活。
class EpisodeFrameService {
  EpisodeFrameService({
    required this.resolve,
    required this.extract,
    required this.release,
    EpisodeFrameCache? cache,
    this.cachedKeys,
    this.onFrame,
    this.maxConcurrent = 2,
  }) : _cache = cache ?? EpisodeFrameCache.instance;

  final EpisodeFrameResolver resolve;
  final EpisodeFrameExtractor extract;
  final EpisodeFrameReleaser release;

  /// 已缓存的帧键（调用方 warmUp 集合的实时快照）。
  final Set<String> Function()? cachedKeys;

  /// 取帧成功并已存缓存后回调，参数为帧键。
  final void Function(String key)? onFrame;

  final int maxConcurrent;
  final EpisodeFrameCache _cache;

  final _attempted = <String>{};
  final _inFlight = <String>{};
  final _queue = <_FrameJob>[];
  var _active = 0;
  var _cancelled = false;
  var _disposed = false;

  /// 请求为 [visible] 中的选集取帧。只把“新露面”的集排进队列：
  /// 已缓存、已尝试、取帧中、已排队的都跳过。
  void prefetch(Drama drama, List<Episode> visible) {
    if (_disposed) return;
    _cancelled = false;
    final cached = cachedKeys?.call() ?? const <String>{};
    for (final episode in visible) {
      final key = EpisodeFrameCache.frameKey(
        source: drama.source,
        dramaId: drama.id,
        episodeNumber: episode.number,
      );
      if (cached.contains(key) ||
          _attempted.contains(key) ||
          _inFlight.contains(key) ||
          _queue.any((job) => job.key == key)) {
        continue;
      }
      _queue.add(_FrameJob(drama, episode, key));
    }
    _pump();
  }

  /// 取消在排与在途任务：队列清空，在途任务的结果丢弃、不写缓存。
  /// 播放开始时调（取帧解析与播放解析共用同一序列号通道，播放
  /// 优先）；页面退出调 [dispose]。
  void cancel() {
    _cancelled = true;
    _queue.clear();
  }

  void dispose() {
    _disposed = true;
    _cancelled = true;
    _queue.clear();
  }

  void _pump() {
    if (_disposed || _cancelled) return;
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      _inFlight.add(job.key);
      _active++;
      unawaited(
        _run(job).whenComplete(() {
          _active--;
          _inFlight.remove(job.key);
          _pump();
        }),
      );
    }
  }

  Future<void> _run(_FrameJob job) async {
    PlaybackPlan? plan;
    try {
      plan = await resolve(job.drama, job.episode);
      if (_cancelled || _disposed) return;
      if (plan.url.isEmpty) return;
      final bytes = await extract(plan);
      if (_cancelled || _disposed) return;
      if (bytes == null || bytes.isEmpty) return;
      final saved = await _cache.saveFrame(job.key, bytes);
      if (_cancelled || _disposed) return;
      if (saved) onFrame?.call(job.key);
    } catch (_) {
      // 解析/取帧/存帧失败静默回落海报。
    } finally {
      // 取消/销毁时不记“已尝试”，下次 prefetch 可重试；会话照常释放。
      if (!_cancelled && !_disposed) _attempted.add(job.key);
      final session = plan?.session ?? '';
      if (session.isNotEmpty) {
        try {
          await release(session);
        } catch (_) {
          // 释放失败不影响卡片。
        }
      }
    }
  }
}
