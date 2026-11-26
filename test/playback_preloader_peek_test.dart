import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/playback_preloader.dart';

import 'fixtures.dart';

class _PreloadRepository extends FixtureRepository {
  PlaybackPlan? nextPlan;
  int preloadCalls = 0;

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
    int route = 0,
    bool adBlock = true,
  }) async {
    preloadCalls++;
    return nextPlan;
  }
}

void main() {
  const drama = FixtureRepository.free;
  final episode = Episode(const {'id': 'ep-2', 'currentEpisode': 2}, 2);

  test('peekReady 在 plan 备好后返回同一 plan 且不消费，take 仍可取走', () async {
    final repository = _PreloadRepository()
      ..nextPlan = PlaybackPlan(
        url: 'https://x/2.m3u8',
        session: 's-2',
        expiresAt: DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      );
    final preloader = PlaybackPreloader(repository);
    addTearDown(preloader.dispose);

    expect(preloader.peekReady(drama, episode), isNull);
    preloader.prepare(drama, episode);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(repository.preloadCalls, 1);

    final peeked = preloader.peekReady(drama, episode);
    expect(peeked, isNotNull);
    expect(peeked!.session, 's-2');
    // peek 不消费：再 peek 还是同一个，take 也还能取走。
    expect(preloader.peekReady(drama, episode), same(peeked));
    final taken = preloader.take(drama, episode);
    expect(taken, same(peeked));
    expect(preloader.peekReady(drama, episode), isNull);
  });

  test('peekReady 身份对不上（画质不同）返回 null', () async {
    final repository = _PreloadRepository()
      ..nextPlan = PlaybackPlan(url: 'https://x/2.m3u8', session: 's-2');
    final preloader = PlaybackPreloader(repository);
    addTearDown(preloader.dispose);
    preloader.prepare(drama, episode);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(preloader.peekReady(drama, episode, quality: 720), isNull);
    expect(preloader.peekReady(drama, episode), isNotNull);
  });
}
