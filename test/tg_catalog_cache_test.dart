import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/models.dart';
import 'package:moyi/tg_catalog_cache.dart';
import 'package:moyi/tg_list_postprocess.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TgCatalogCache', () {
    test('hit within ttl, miss at ttl boundary', () {
      var now = DateTime(2026, 11, 14, 10);
      final cache = TgCatalogCache(now: () => now);
      const source = 'jar:zakatv:ZakaTg';
      final page = CatalogPage(const []);
      cache.store(source, '@chan1', page);
      now = now.add(const Duration(minutes: 59));
      expect(cache.lookup(source, '@chan1'), same(page));
      now = now.add(const Duration(minutes: 1));
      expect(cache.lookup(source, '@chan1'), isNull);
    });

    test('entries are isolated per source and category', () {
      final cache = TgCatalogCache(now: () => DateTime(2026, 11, 14, 10));
      final pageA = CatalogPage(const []);
      final pageB = CatalogPage(const []);
      cache.store('jar:zakatv:ZakaTg', '@chan1', pageA);
      cache.store('jar:zakatv:ZakaTg', '@chan2', pageB);
      expect(cache.lookup('jar:zakatv:ZakaTg', '@chan1'), same(pageA));
      expect(cache.lookup('jar:zakatv:ZakaTg', '@chan2'), same(pageB));
      expect(cache.lookup('jar:zakatv:ZakaTgMovie', '@chan1'), isNull);
    });

    test('clear drops everything', () {
      final cache = TgCatalogCache(now: () => DateTime(2026, 11, 14, 10));
      cache.store('s', 'c', CatalogPage(const []));
      cache.clear();
      expect(cache.lookup('s', 'c'), isNull);
    });
  });

  group('NativeRepository TG catalog cache', () {
    const tgSiteId = 'jar:zakatv:ZakaTg';
    const movieSiteId = 'jar:zakatv:ZakaTgMovie';
    const otherSiteId = 'jar:zakatv:Other';
    const channel = MethodChannel('moyi/jarbridge');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    late DateTime fakeNow;
    late TgCatalogCache cache;
    late NativeRepository repository;
    late List<String> calls;

    Map<String, dynamic> listJson(List<Map<String, String>> rows) => {
      'list': rows,
      'pagecount': 1,
      'total': rows.length,
    };

    setUp(() {
      fakeNow = DateTime(2026, 11, 14, 10);
      cache = TgCatalogCache(now: () => fakeNow);
      repository = NativeRepository(tgCatalogCache: cache);
      calls = [];
      JarBridge.setTestJarPath('zakatv', '/tmp/test.jar');
      for (final spec in [
        const JarSiteSpec(
          siteId: tgSiteId,
          configId: 'zakatv',
          name: 'TG频道',
          className: tgAllAmnsClass,
          jarUrl: '',
          jarMd5: '',
          ext: '{}',
        ),
        const JarSiteSpec(
          siteId: movieSiteId,
          configId: 'zakatv',
          name: 'TG电影',
          className: tgMovieAmnsClass,
          jarUrl: '',
          jarMd5: '',
          ext: '{}',
        ),
        const JarSiteSpec(
          siteId: otherSiteId,
          configId: 'zakatv',
          name: '其它',
          className: 'com.example.Other',
          jarUrl: '',
          jarMd5: '',
          ext: '{}',
        ),
      ]) {
        JarBridge.register(spec);
        SourceSite.importedSites[spec.siteId] = SourceSite(
          spec.siteId,
          spec.name,
          '',
          section: SourceSite.sectionVideo,
          origin: SourceSite.originImport,
          importType: 'jar',
        );
      }
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'call') return null;
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final method = args['method'] as String? ?? '';
        calls.add(method);
        switch (method) {
          case 'categoryContent':
            // 标题带拉取代次：缓存命中返回旧代次，现拉返回新代次。
            final gen = calls
                .where((method) => method == 'categoryContent')
                .length;
            return {
              'text': jsonEncode(
                listJson([
                  {
                    'vod_id': 'chan1|1',
                    'vod_name': '剧A-$gen',
                    'vod_pic': 'https://example.com/a.jpg',
                  },
                  {
                    'vod_id': 'chan1|2',
                    'vod_name': '剧B-$gen',
                    'vod_pic': 'https://example.com/b.jpg',
                  },
                ]),
              ),
            };
          case 'homeVideoContent':
            return {'text': jsonEncode(listJson([]))};
          case 'homeContent':
            return {
              'text': jsonEncode({
                'class': [
                  {'type_id': '@chan1', 'type_name': '频道一'},
                ],
                'list': [],
              }),
            };
          case 'searchContent':
            return {
              'text': jsonEncode(
                listJson([
                  {
                    'vod_id': 'chan1|9',
                    'vod_name': '搜到剧',
                    'vod_pic': 'https://example.com/s.jpg',
                  },
                ]),
              ),
            };
          case 'detailContent':
            return {
              'text': jsonEncode({
                'list': [
                  {
                    'vod_id': 'chan1|1',
                    'vod_name': '剧A',
                    'vod_play_from': 'TG直连',
                    'vod_play_url': '正片\$chan1|1',
                  },
                ],
              }),
            };
          default:
            return {'text': jsonEncode({})};
        }
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      for (final siteId in [tgSiteId, movieSiteId, otherSiteId]) {
        JarBridge.unregister(siteId);
        SourceSite.importedSites.remove(siteId);
      }
      JarBridge.clearTestJarPaths();
    });

    int categoryCalls() =>
        calls.where((method) => method == 'categoryContent').length;

    test('second entry within an hour sends no request', () async {
      final first = await repository.catalog(tgSiteId, category: '@chan1');
      expect(first.items.map((drama) => drama.title), ['剧A-1', '剧B-1']);
      expect(categoryCalls(), 1);
      fakeNow = fakeNow.add(const Duration(minutes: 30));
      final second = await repository.catalog(tgSiteId, category: '@chan1');
      expect(second.items.map((drama) => drama.title), ['剧A-1', '剧B-1']);
      expect(categoryCalls(), 1);
    });

    test('entry after an hour refetches', () async {
      await repository.catalog(tgSiteId, category: '@chan1');
      expect(categoryCalls(), 1);
      fakeNow = fakeNow.add(const Duration(minutes: 61));
      final second = await repository.catalog(tgSiteId, category: '@chan1');
      expect(second.items.map((drama) => drama.title), ['剧A-2', '剧B-2']);
      expect(categoryCalls(), 2);
    });

    test('manual force refresh refetches within ttl', () async {
      await repository.catalog(tgSiteId, category: '@chan1');
      expect(categoryCalls(), 1);
      final forced = await repository.catalog(
        tgSiteId,
        category: '@chan1',
        force: true,
      );
      expect(forced.items.map((drama) => drama.title), ['剧A-2', '剧B-2']);
      expect(categoryCalls(), 2);
      // 强制刷新后缓存被刷新：紧接着的普通进入不发请求、且是新内容。
      final third = await repository.catalog(tgSiteId, category: '@chan1');
      expect(third.items.map((drama) => drama.title), ['剧A-2', '剧B-2']);
      expect(categoryCalls(), 2);
    });

    test('cache is per category', () async {
      await repository.catalog(tgSiteId, category: '@chan1');
      await repository.catalog(tgSiteId, category: '@chan2');
      expect(categoryCalls(), 2);
      await repository.catalog(tgSiteId, category: '@chan1');
      await repository.catalog(tgSiteId, category: '@chan2');
      expect(categoryCalls(), 2);
    });

    test('movie station caches independently', () async {
      await repository.catalog(movieSiteId, category: '@chan1');
      await repository.catalog(movieSiteId, category: '@chan1');
      expect(categoryCalls(), 1);
      await repository.catalog(tgSiteId, category: '@chan1');
      expect(categoryCalls(), 2);
    });

    test('search is never cached', () async {
      await repository.catalog(tgSiteId, query: '剧');
      await repository.catalog(tgSiteId, query: '剧');
      expect(calls.where((method) => method == 'searchContent').length, 2);
    });

    test('pages after the first are never cached', () async {
      await repository.catalog(tgSiteId, category: '@chan1', page: 2);
      await repository.catalog(tgSiteId, category: '@chan1', page: 2);
      expect(categoryCalls(), 2);
    });

    test('non-TG jar station is never cached', () async {
      await repository.catalog(otherSiteId, category: '@chan1');
      await repository.catalog(otherSiteId, category: '@chan1');
      expect(categoryCalls(), 2);
    });

    test('detail is not affected by the catalog cache', () async {
      await repository.catalog(tgSiteId, category: '@chan1');
      const drama = Drama(id: 'chan1|1', source: tgSiteId, title: '剧A');
      final first = await repository.detail(drama);
      final second = await repository.detail(drama);
      expect(first.episodes, hasLength(1));
      expect(second.episodes, hasLength(1));
      expect(calls.where((method) => method == 'detailContent').length, 2);
    });

    test('home view (empty category) caches too', () async {
      final first = await repository.catalog(tgSiteId);
      expect(first.items, isEmpty);
      final homeCalls = calls.where((m) => m == 'homeContent').length;
      expect(homeCalls, 1);
      await repository.catalog(tgSiteId);
      expect(calls.where((m) => m == 'homeContent').length, 1);
    });
  });
}
