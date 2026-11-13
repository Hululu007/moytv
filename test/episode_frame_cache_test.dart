import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/episode_frame_cache.dart';

void main() {
  group('EpisodeFrameCache.frameKey', () {
    test('同一站同一剧同一集：键稳定', () {
      const args = (
        source: 'hongguo',
        dramaId: 'd123',
        episodeNumber: 2,
      );
      final a = EpisodeFrameCache.frameKey(
        source: args.source,
        dramaId: args.dramaId,
        episodeNumber: args.episodeNumber,
      );
      final b = EpisodeFrameCache.frameKey(
        source: args.source,
        dramaId: args.dramaId,
        episodeNumber: args.episodeNumber,
      );
      expect(a, b);
      expect(a, endsWith('.jpg'));
    });

    test('集号不同、站不同、剧不同：键都不同', () {
      final base = EpisodeFrameCache.frameKey(
        source: 'hongguo',
        dramaId: 'd123',
        episodeNumber: 2,
      );
      final otherEpisode = EpisodeFrameCache.frameKey(
        source: 'hongguo',
        dramaId: 'd123',
        episodeNumber: 3,
      );
      final otherSource = EpisodeFrameCache.frameKey(
        source: 'other',
        dramaId: 'd123',
        episodeNumber: 2,
      );
      final otherDrama = EpisodeFrameCache.frameKey(
        source: 'hongguo',
        dramaId: 'd999',
        episodeNumber: 2,
      );
      expect({base, otherEpisode, otherSource, otherDrama}.length, 4);
    });
  });

  group('episodeFramePrunePlan', () {
    EpisodeFrameEntry entry(String name, int size, int day) =>
        EpisodeFrameEntry(
          name: name,
          size: size,
          modified: DateTime.utc(2026, 1, day),
        );

    test('未超上限：一个不删', () {
      final plan = episodeFramePrunePlan([
        entry('a.jpg', 100, 1),
        entry('b.jpg', 100, 2),
      ]);
      expect(plan, isEmpty);
    });

    test('超数量上限：先删最旧的', () {
      final plan = episodeFramePrunePlan(
        [entry('a.jpg', 10, 1), entry('b.jpg', 10, 2), entry('c.jpg', 10, 3)],
        maxFiles: 2,
        maxBytes: 100000,
      );
      expect(plan, ['a.jpg']);
    });

    test('超字节上限：删到字节回落为止', () {
      final plan = episodeFramePrunePlan(
        [entry('a.jpg', 60, 1), entry('b.jpg', 60, 2), entry('c.jpg', 60, 3)],
        maxFiles: 100,
        maxBytes: 100,
      );
      expect(plan, ['a.jpg', 'b.jpg']);
    });
  });

  group('EpisodeFrameCache IO（临时目录）', () {
    late Directory temp;
    late EpisodeFrameCache cache;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('frame_cache_test');
      cache = EpisodeFrameCache(directoryProvider: () async => temp);
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('存一帧后 warmUp 能列出，pathForKey 指向该文件', () async {
      const key = 'abc.jpg';
      final saved = await cache.saveFrame(key, [1, 2, 3, 4]);
      expect(saved, isTrue);
      final keys = await cache.warmUp();
      expect(keys, contains(key));
      final path = cache.pathForKey(key);
      expect(path, isNotNull);
      expect(await File(path!).readAsBytes(), [1, 2, 3, 4]);
    });

    test('空字节不存', () async {
      expect(await cache.saveFrame('empty.jpg', []), isFalse);
      expect(await cache.warmUp(), isEmpty);
    });

    test('非 jpg 文件不进集合', () async {
      await File('${temp.path}/notes.txt').writeAsString('x');
      expect(await cache.warmUp(), isEmpty);
    });

    test('超上限存帧时删最旧的文件', () async {
      final small = EpisodeFrameCache(
        directoryProvider: () async => temp,
        maxFiles: 2,
      );
      await small.saveFrame('old1.jpg', List.filled(10, 1));
      await small.saveFrame('old2.jpg', List.filled(10, 2));
      // 显式拉开修改时间，避免同毫秒写导致“最旧”不确定。
      await File(
        '${temp.path}/old1.jpg',
      ).setLastModified(DateTime.utc(2026, 1, 1));
      await File(
        '${temp.path}/old2.jpg',
      ).setLastModified(DateTime.utc(2026, 1, 2));
      // 第三帧存入后超 2 个上限，最旧的 old1.jpg 应被清理。
      await small.saveFrame('new3.jpg', List.filled(10, 3));
      final keys = await small.warmUp();
      expect(keys, containsAll(['old2.jpg', 'new3.jpg']));
      expect(keys, isNot(contains('old1.jpg')));
      expect(File('${temp.path}/old1.jpg').existsSync(), isFalse);
    });
  });
}
