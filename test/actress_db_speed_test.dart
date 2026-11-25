// 读库提速第二阶段（2026-11-25）：NvkuEntryCache 总数缓存。
// countFilms / countLibraryFilms 按“库指纹 + 计数种类 + 过滤条件”
// 缓存 5 分钟（与作品第一页同口径），手动刷新 / 同步完成调 clear()
// 全清。纯内存逻辑，不碰真库、不走网络。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_nvku_cache.dart';

void main() {
  setUp(() => NvkuEntryCache.clearForTest());
  tearDown(() => NvkuEntryCache.clearForTest());

  group('NvkuEntryCache 总数缓存（读库提速第二阶段）', () {
    test('未存过回 null', () {
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'a|b'), isNull);
    });

    test('存后命中回值', () {
      NvkuEntryCache.putCount('stamp1', 'countFilms', 'a|b', 339840);
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'a|b'), 339840);
    });

    test('库指纹不同不串', () {
      NvkuEntryCache.putCount('stamp1', 'countFilms', 'a|b', 10);
      expect(NvkuEntryCache.count('stamp2', 'countFilms', 'a|b'), isNull);
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'a|b'), 10);
    });

    test('计数种类不同不串', () {
      NvkuEntryCache.putCount('stamp1', 'countFilms', 'a|b', 10);
      expect(
        NvkuEntryCache.count('stamp1', 'countLibraryFilms', 'a|b'),
        isNull,
      );
    });

    test('过滤条件不同不串', () {
      NvkuEntryCache.putCount('stamp1', 'countFilms', 'typeA', 10);
      NvkuEntryCache.putCount('stamp1', 'countFilms', 'typeB', 20);
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'typeA'), 10);
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'typeB'), 20);
    });

    test('同 key 复写取新值', () {
      NvkuEntryCache.putCount('stamp1', 'countFilms', 'a|b', 10);
      NvkuEntryCache.putCount('stamp1', 'countFilms', 'a|b', 11);
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'a|b'), 11);
    });

    test('clear() 清掉总数，不留旧库数据', () {
      NvkuEntryCache.putCount('stamp1', 'countFilms', 'a|b', 10);
      NvkuEntryCache.clear();
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'a|b'), isNull);
    });

    test('超 32 个 key 淘汰最久没用的', () {
      for (var i = 0; i < 33; i++) {
        NvkuEntryCache.putCount('stamp1', 'countFilms', 'k$i', i);
      }
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'k0'), isNull);
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'k32'), 32);
      expect(NvkuEntryCache.count('stamp1', 'countFilms', 'k1'), 1);
    });
  });
}
