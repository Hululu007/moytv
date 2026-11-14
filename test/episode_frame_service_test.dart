import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/episode_frame_cache.dart';
import 'package:moyi/episode_frame_service.dart';
import 'package:moyi/models.dart';

Drama _drama() => const Drama(
  id: 'hongguo:100',
  source: 'hongguo',
  title: '测试短剧',
  episodes: 5,
);

Episode _episode(int number) => Episode({
  'id': 'e$number',
  'title': '第$number集',
  'currentEpisode': number,
}, number);

Future<void> _waitUntil(
  bool Function() done, {
  String label = '',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待超时：$label');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeResolver {
  final calls = <int>[];
  Future<PlaybackPlan> Function(Drama, Episode)? handler;

  Future<PlaybackPlan> call(Drama drama, Episode episode) async {
    calls.add(episode.number);
    if (handler != null) return handler!(drama, episode);
    return PlaybackPlan(
      url: 'http://127.0.0.1:9/${episode.number}',
      session: 's${episode.number}',
    );
  }
}

class _FakeExtractor {
  final calls = <String>[];
  var active = 0;
  var maxActive = 0;
  Duration delay = Duration.zero;
  Future<Uint8List?> Function(PlaybackPlan)? handler;

  Future<Uint8List?> call(PlaybackPlan plan) async {
    calls.add(plan.url);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (handler != null) {
        final result = await handler!(plan);
        return result;
      }
      return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x01]);
    } finally {
      active--;
    }
  }
}

class _FakeReleaser {
  final sessions = <String>[];

  Future<void> call(String session) async {
    sessions.add(session);
  }
}

void main() {
  group('EpisodeFrameService', () {
    late Directory temp;
    late EpisodeFrameCache cache;
    late _FakeResolver resolver;
    late _FakeExtractor extractor;
    late _FakeReleaser releaser;
    late List<String> framed;
    late Set<String> cached;
    late EpisodeFrameService service;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('frame_service_test');
      cache = EpisodeFrameCache(directoryProvider: () async => temp);
      resolver = _FakeResolver();
      extractor = _FakeExtractor();
      releaser = _FakeReleaser();
      framed = [];
      cached = {};
      service = EpisodeFrameService(
        resolve: resolver.call,
        extract: extractor.call,
        release: releaser.call,
        cache: cache,
        cachedKeys: () => cached,
        onFrame: framed.add,
      );
    });

    tearDown(() async {
      service.dispose();
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('缓存命中不解析不取帧', () async {
      final key1 = EpisodeFrameCache.frameKey(
        source: 'hongguo',
        dramaId: 'hongguo:100',
        episodeNumber: 1,
      );
      cached = {key1};
      service.prefetch(_drama(), [_episode(1), _episode(2)]);
      await _waitUntil(() => framed.length == 1, label: '第2集取帧完成');
      expect(resolver.calls, [2]);
      expect(extractor.calls, ['http://127.0.0.1:9/2']);
    });

    test('成功：帧写缓存、回调、会话释放', () async {
      service.prefetch(_drama(), [_episode(1)]);
      await _waitUntil(() => framed.length == 1, label: '取帧完成');
      final key = EpisodeFrameCache.frameKey(
        source: 'hongguo',
        dramaId: 'hongguo:100',
        episodeNumber: 1,
      );
      expect(framed, [key]);
      expect(
        await File('${temp.path}/$key').readAsBytes(),
        [0xFF, 0xD8, 0xFF, 0xE0, 0x01],
      );
      expect(releaser.sessions, ['s1']);
    });

    test('解析失败静默回落：不写缓存、不回调、不释放', () async {
      resolver.handler = (_, _) async => throw Exception('合成解析失败');
      service.prefetch(_drama(), [_episode(1)]);
      await _waitUntil(() => resolver.calls.isNotEmpty, label: '解析被调');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await cache.warmUp(), isEmpty);
      expect(framed, isEmpty);
      expect(extractor.calls, isEmpty);
      expect(releaser.sessions, isEmpty);
    });

    test('取帧返回空回落：不写缓存、不回调、会话照常释放', () async {
      extractor.handler = (_) async => null;
      service.prefetch(_drama(), [_episode(1)]);
      await _waitUntil(() => releaser.sessions.isNotEmpty, label: '会话释放');
      expect(await cache.warmUp(), isEmpty);
      expect(framed, isEmpty);
      expect(releaser.sessions, ['s1']);
    });

    test('空地址不取帧、会话照常释放', () async {
      resolver.handler = (_, episode) async =>
          PlaybackPlan(url: '', session: 's${episode.number}');
      service.prefetch(_drama(), [_episode(1)]);
      await _waitUntil(() => releaser.sessions.isNotEmpty, label: '会话释放');
      expect(extractor.calls, isEmpty);
      expect(releaser.sessions, ['s1']);
    });

    test('取消后不写缓存、不回调、会话照常释放', () async {
      extractor.delay = const Duration(milliseconds: 200);
      service.prefetch(_drama(), [_episode(1)]);
      await _waitUntil(() => extractor.calls.isNotEmpty, label: '取帧开始');
      service.cancel();
      await _waitUntil(() => releaser.sessions.isNotEmpty, label: '会话释放');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await cache.warmUp(), isEmpty);
      expect(framed, isEmpty);
    });

    test('取消的任务下次 prefetch 可重试', () async {
      extractor.delay = const Duration(milliseconds: 150);
      service.prefetch(_drama(), [_episode(1)]);
      await _waitUntil(() => extractor.calls.isNotEmpty, label: '取帧开始');
      service.cancel();
      await _waitUntil(() => releaser.sessions.isNotEmpty, label: '会话释放');
      extractor.delay = Duration.zero;
      service.prefetch(_drama(), [_episode(1)]);
      await _waitUntil(() => framed.length == 1, label: '重试取帧完成');
      expect(resolver.calls, [1, 1]);
    });

    test('并发上限 2 路', () async {
      extractor.delay = const Duration(milliseconds: 100);
      service.prefetch(
        _drama(),
        [_episode(1), _episode(2), _episode(3), _episode(4), _episode(5)],
      );
      await _waitUntil(() => framed.length == 5, label: '5 集全部取完');
      expect(extractor.maxActive, lessThanOrEqualTo(2));
      expect(extractor.maxActive, greaterThanOrEqualTo(1));
      expect((await cache.warmUp()).length, 5);
      expect(releaser.sessions.length, 5);
    });

    test('重复 prefetch 不重复取', () async {
      service.prefetch(_drama(), [_episode(1), _episode(2)]);
      await _waitUntil(() => framed.length == 2, label: '首次取完');
      service.prefetch(_drama(), [_episode(1), _episode(2)]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(resolver.calls.length, 2);
      expect(resolver.calls.toSet(), {1, 2});
    });

    test('可见范围变化只补新增的', () async {
      service.prefetch(_drama(), [_episode(1)]);
      await _waitUntil(() => framed.length == 1, label: '第1集取完');
      service.prefetch(_drama(), [_episode(1), _episode(2)]);
      await _waitUntil(() => framed.length == 2, label: '第2集补完');
      expect(resolver.calls, [1, 2]);
    });

    test('dispose 后 prefetch 无效', () async {
      service.dispose();
      service.prefetch(_drama(), [_episode(1)]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(resolver.calls, isEmpty);
      expect(extractor.calls, isEmpty);
    });
  });
}
