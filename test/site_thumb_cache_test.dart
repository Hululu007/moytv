// 站点列表缩图地址缓存测试：命中、落盘重读、失败不记、在途去重。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/site_thumb_cache.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('site_thumb_cache_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  SiteThumbCache cache() =>
      SiteThumbCache(directoryProvider: () async => tempDir);

  test('取到就缓存，第二次不再拉首页', () async {
    final c = cache();
    var calls = 0;
    Future<String?> fetcher(String siteId) async {
      calls++;
      return 'https://example.com/$siteId.jpg';
    }

    expect(
      await c.thumbUrlFor('a', fetcher: fetcher),
      'https://example.com/a.jpg',
    );
    expect(calls, 1);
    expect(c.cachedUrl('a'), 'https://example.com/a.jpg');
    expect(
      await c.thumbUrlFor('a', fetcher: fetcher),
      'https://example.com/a.jpg',
    );
    expect(calls, 1);
  });

  test('落盘后新实例直接读盘，不拉首页', () async {
    final c1 = cache();
    await c1.thumbUrlFor(
      'a',
      fetcher: (_) async => 'https://example.com/a.jpg',
    );
    // 等落盘排队写完。
    await Future.delayed(const Duration(milliseconds: 200));

    final c2 = cache();
    var calls = 0;
    final url = await c2.thumbUrlFor(
      'a',
      fetcher: (_) async {
        calls++;
        return 'https://example.com/other.jpg';
      },
    );
    expect(url, 'https://example.com/a.jpg');
    expect(calls, 0);
  });

  test('拉不到不记失败，下次再拉', () async {
    final c = cache();
    var calls = 0;
    Future<String?> failing(String siteId) async {
      calls++;
      return null;
    }

    expect(await c.thumbUrlFor('dead', fetcher: failing), isNull);
    expect(await c.thumbUrlFor('dead', fetcher: failing), isNull);
    expect(calls, 2);
    expect(c.cachedUrl('dead'), isNull);
  });

  test('取数抛错也不记失败，下次再拉', () async {
    final c = cache();
    var calls = 0;
    Future<String?> throwing(String siteId) async {
      calls++;
      throw StateError('boom');
    }

    expect(await c.thumbUrlFor('bad', fetcher: throwing), isNull);
    expect(await c.thumbUrlFor('bad', fetcher: throwing), isNull);
    expect(calls, 2);
  });

  test('同站并发只拉一次', () async {
    final c = cache();
    var calls = 0;
    Future<String?> slow(String siteId) async {
      calls++;
      await Future.delayed(const Duration(milliseconds: 50));
      return 'https://example.com/$siteId.jpg';
    }

    final results = await Future.wait([
      c.thumbUrlFor('a', fetcher: slow),
      c.thumbUrlFor('a', fetcher: slow),
      c.thumbUrlFor('a', fetcher: slow),
    ]);
    expect(results, [
      'https://example.com/a.jpg',
      'https://example.com/a.jpg',
      'https://example.com/a.jpg',
    ]);
    expect(calls, 1);
  });

  test('磁盘映射损坏当空缓存，不抛错', () async {
    File(
      '${tempDir.path}/${SiteThumbCache.fileName}',
    ).writeAsStringSync('{bad json');
    final c = cache();
    var calls = 0;
    final url = await c.thumbUrlFor(
      'a',
      fetcher: (_) async {
        calls++;
        return 'https://example.com/a.jpg';
      },
    );
    expect(url, 'https://example.com/a.jpg');
    expect(calls, 1);
  });
}
