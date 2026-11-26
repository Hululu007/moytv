import 'core_bridge.dart';
import 'models.dart';

class PlaybackLoader {
  PlaybackLoader(this.repository);

  final AppRepository repository;
  int _generation = 0;
  bool _closed = false;

  Future<PlaybackPlan?> load(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool localOnly = false,
    bool online = false,
    int route = 0,
    bool adBlock = true,
  }) => _load(() async {
    if (online) {
      return repository.resolveOnline(
        drama,
        episode,
        quality: quality,
        route: route,
        adBlock: adBlock,
      );
    }
    // 本地库条目的集 id 本身就是可播直链：直接交给播放器。
    // 绕蜘蛛取流时，蜘蛛站换域名/没这个番号就播不出来——本地库
    // 里存着地址却播不了，用户要的就是别绕。
    // 集里带 headers 时一并透传（2026-11-26 演员库在线源：站点
    // 签名 m3u8 要带 Referer/UA 才肯放行）；没带的集行为不变。
    final direct = episode.raw['direct'] == true
        ? episode.raw['id']?.toString() ?? episode.id
        : '';
    if (_looksLikeMediaUrl(direct)) {
      final rawHeaders = episode.raw['headers'];
      final headers = rawHeaders is Map
          ? <String, String>{
              for (final entry in rawHeaders.entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const <String, String>{};
      return PlaybackPlan(url: direct, originalUrl: direct, headers: headers);
    }
    if (localOnly) {
      final plan = await repository.localPlayback(drama, episode);
      if (plan == null || !plan.local) {
        throw AppFailure('本地视频不可用，请重新下载或选择在线播放。', code: 'local_media');
      }
      return plan;
    }
    return repository.resolve(
      drama,
      episode,
      quality: quality,
      route: route,
      adBlock: adBlock,
    );
  });

  Future<PlaybackPlan?> fallback(PlaybackPlan current) =>
      _load(() => repository.fallback(current));

  Future<PlaybackPlan?> selectRoute(PlaybackPlan current, int route) =>
      _load(() => repository.selectRoute(current, route));

  Future<PlaybackPlan?> use(PlaybackPlan prepared) =>
      _load(() async => prepared);

  Future<PlaybackPlan?> _load(Future<PlaybackPlan> Function() resolve) async {
    if (_closed) {
      return null;
    }
    final generation = ++_generation;
    try {
      await repository.cancelPlayback();
      if (_closed || generation != _generation) {
        return null;
      }
      final plan = await resolve();
      if (_closed || generation != _generation) {
        await repository.release(plan.session);
        return null;
      }
      return plan;
    } catch (_) {
      if (_closed || generation != _generation) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    _generation++;
    await repository.cancelPlayback();
  }
}

/// 是不是能直接交给播放器的媒体地址（m3u8/mp4 等）：只有这类才
/// 跳过蜘蛛取流，网页地址照旧走原来的解析流程。
bool _looksLikeMediaUrl(String url) {
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return false;
  }
  final lower = url.toLowerCase();
  const suffixes = [
    '.m3u8',
    '.mp4',
    '.m4v',
    '.flv',
    '.mkv',
    '.ts',
    '.mov',
    '.webm',
  ];
  for (final suffix in suffixes) {
    if (lower.contains(suffix)) return true;
  }
  return false;
}
