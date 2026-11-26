// 剧照补图（2026-11-26）：详情自带剧照为空时按番号去
// JavDB 接口补预览图——纯逻辑层用假取数验：番号精确相等
// 才补、近似不认、搜不到不补、出错/超时不挡、已有剧照不
// 覆盖不发请求；详情页接线用组件测试验补上后剧照区出现、
// 对不上时整区仍不显示。真接口未验（本机出口断），这里只
// 验解析/匹配/接线，夹具结构照 javdb_api_test 的信封口径。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_online_detail.dart';
import 'package:moyi/actress/javdb_api.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

String _envelope(Object? data) => jsonEncode({'success': true, 'data': data});

Map<String, Object?> _movieJson(String id, String number) => {
  'id': id,
  'number': number,
  'title': '标题 $number',
  'thumb_url': 'https://c0.jdbstatic.com/thumbs/$id.jpg',
  'cover_url': 'https://c0.jdbstatic.com/covers/$id.jpg',
};

/// 假取数：按网址分发搜索/详情响应，并记录请求过的网址。
class _FakeJavdb {
  _FakeJavdb({required this.searchResults, this.stillsById = const {}});

  final List<Map<String, Object?>> searchResults;
  final Map<String, List<String>> stillsById;
  final requested = <String>[];

  Future<String> fetch(String url) async {
    requested.add(url);
    if (url.contains('api/v2/search')) {
      return _envelope({'movies': searchResults});
    }
    if (url.contains('api/v1/movies/')) {
      final id = url.split('api/v1/movies/').last;
      final stills = stillsById[id] ?? const <String>[];
      return _envelope({
        'preview_images': [
          for (final s in stills) {'large_url': s},
        ],
      });
    }
    throw StateError('未预期的网址：$url');
  }

  JavdbApiClient get client => JavdbApiClient(fetch: fetch);
}

void main() {
  group('actressJavdbStillsSupplement', () {
    test('番号精确相等才补：多结果里只认番号相同那部', () async {
      final fake = _FakeJavdb(
        searchResults: [_movieJson('m2', 'SSIS-002'), _movieJson('m1', 'SSIS-001')],
        stillsById: {
          'm1': [
            'https://c0.jdbstatic.com/samples/s1.jpg',
            'https://c0.jdbstatic.com/samples/s2.jpg',
          ],
          'm2': ['https://c0.jdbstatic.com/samples/other.jpg'],
        },
      );
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: 'SSIS-001',
        client: fake.client,
      );
      expect(stills, [
        'https://c0.jdbstatic.com/samples/s1.jpg',
        'https://c0.jdbstatic.com/samples/s2.jpg',
      ]);
      // 只对命中那部取详情补充，别片的详情不碰。
      expect(fake.requested.where((u) => u.contains('api/v1/movies/m1')), hasLength(1));
      expect(fake.requested.where((u) => u.contains('api/v1/movies/m2')), isEmpty);
    });

    test('近似番号不认：只差一位数不算找到', () async {
      final fake = _FakeJavdb(
        searchResults: [_movieJson('m9', 'SSIS-0010'), _movieJson('m8', 'SSIS-010')],
        stillsById: {
          'm9': ['https://c0.jdbstatic.com/samples/x.jpg'],
          'm8': ['https://c0.jdbstatic.com/samples/y.jpg'],
        },
      );
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: 'SSIS-001',
        client: fake.client,
      );
      expect(stills, isEmpty);
      expect(fake.requested.where((u) => u.contains('api/v1/movies/')), isEmpty);
    });

    test('番号写法不同但归一后相等也认（小写/无分隔符）', () async {
      final fake = _FakeJavdb(
        searchResults: [_movieJson('m1', 'SSIS-001')],
        stillsById: {
          'm1': ['https://c0.jdbstatic.com/samples/s1.jpg'],
        },
      );
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: 'ssis001',
        client: fake.client,
      );
      expect(stills, ['https://c0.jdbstatic.com/samples/s1.jpg']);
    });

    test('搜不到（空结果）不补', () async {
      final fake = _FakeJavdb(searchResults: const []);
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: 'SSIS-001',
        client: fake.client,
      );
      expect(stills, isEmpty);
    });

    test('命中作品没有 id 不认（没法取详情补充）', () async {
      final fake = _FakeJavdb(
        searchResults: [_movieJson('', 'SSIS-001')],
        stillsById: {'': ['https://c0.jdbstatic.com/samples/s1.jpg']},
      );
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: 'SSIS-001',
        client: fake.client,
      );
      expect(stills, isEmpty);
    });

    test('命中但接口没给预览图：保持空', () async {
      final fake = _FakeJavdb(
        searchResults: [_movieJson('m1', 'SSIS-001')],
        stillsById: const {},
      );
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: 'SSIS-001',
        client: fake.client,
      );
      expect(stills, isEmpty);
    });

    test('搜索出错不抛、保持空', () async {
      final client = JavdbApiClient(
        fetch: (url) async => throw StateError('网络断了'),
      );
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: 'SSIS-001',
        client: client,
      );
      expect(stills, isEmpty);
    });

    test('超时不挡：取数迟迟不回就放弃、保持空', () async {
      final client = JavdbApiClient(
        fetch: (url) => Future<String>.delayed(
          const Duration(milliseconds: 300),
          () => _envelope({'movies': []}),
        ),
      );
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: 'SSIS-001',
        client: client,
        timeout: const Duration(milliseconds: 30),
      );
      expect(stills, isEmpty);
    });

    test('已有剧照不覆盖、且不发任何请求', () async {
      var calls = 0;
      final client = JavdbApiClient(
        fetch: (url) async {
          calls++;
          return _envelope({'movies': []});
        },
      );
      const existing = ['https://img.example.com/page-still.jpg'];
      final stills = await actressJavdbStillsSupplement(
        current: existing,
        code: 'SSIS-001',
        client: client,
      );
      expect(stills, existing);
      expect(calls, 0);
    });

    test('番号为空不发请求', () async {
      var calls = 0;
      final client = JavdbApiClient(
        fetch: (url) async {
          calls++;
          return _envelope({'movies': []});
        },
      );
      final stills = await actressJavdbStillsSupplement(
        current: const [],
        code: '---',
        client: client,
      );
      expect(stills, isEmpty);
      expect(calls, 0);
    });
  });

  group('javdbIsImageUrl', () {
    test('图床域名认、其他域名不认', () {
      expect(javdbIsImageUrl('https://c0.jdbstatic.com/samples/a.jpg'), isTrue);
      expect(javdbIsImageUrl('https://jdbstatic.com/covers/a.jpg'), isTrue);
      expect(javdbIsImageUrl('https://img.example.com/samples/a.jpg'), isFalse);
      expect(javdbIsImageUrl('https://jdforrepam.com/api/v1/movies/x'), isFalse);
      expect(javdbIsImageUrl('不是网址'), isFalse);
      expect(javdbIsImageUrl(''), isFalse);
    });
  });

  group('详情页接线', () {
    setUpAll(() {
      // 与 actress_detail_sections_test 同口径：潮流是 py 导入
      // 站，测试里补登，完后摘掉。
      SourceSite.importedSites['chaoliu'] = const SourceSite(
        'chaoliu',
        '潮流',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originImport,
        importType: 'py',
      );
    });

    tearDownAll(() {
      SourceSite.importedSites.remove('chaoliu');
    });

    const drama = Drama(
      id: 'chaoliu:SSIS-001',
      source: 'chaoliu',
      title: 'SSIS-001 样本影片',
      category: '成人影片',
      onlineDate: '2024-06-15',
      tags: ['SSIS-001'],
      episodes: 1,
    );

    Future<void> pumpDetail(
      WidgetTester tester, {
      required JavdbApiClient client,
    }) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = LocalStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            drama: drama,
            repository: _EmptyDetailRepository(),
            store: store,
            javdbStillsClient: client,
          ),
        ),
      );
    }

    // 剧照区在懒加载滚动体下半段，没滚到不构建：轮询等补图
    // 落地的同时手动拖拽滚到该区（与 actress_detail_
    // sections_test 同口径）。
    Future<bool> waitForStillsSection(WidgetTester tester) async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        if (find
            .byKey(const ValueKey('detail-stills-section'))
            .evaluate()
            .isNotEmpty) {
          return true;
        }
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -400),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      return false;
    }

    testWidgets('自带剧照为空时按番号从 JavDB 补上、剧照区出现', (tester) async {
      final fake = _FakeJavdb(
        searchResults: [_movieJson('m1', 'SSIS-001')],
        stillsById: {
          'm1': [
            for (var i = 1; i <= 4; i++)
              'https://c0.jdbstatic.com/samples/w$i.jpg',
          ],
        },
      );
      await pumpDetail(tester, client: fake.client);
      expect(await waitForStillsSection(tester), isTrue);
      expect(find.text('全部 4 >'), findsOneWidget);
    });

    testWidgets('JavDB 搜不到这部时剧照区仍不显示', (tester) async {
      final fake = _FakeJavdb(
        searchResults: [_movieJson('m9', 'SSIS-999')],
        stillsById: {
          'm9': ['https://c0.jdbstatic.com/samples/z.jpg'],
        },
      );
      await pumpDetail(tester, client: fake.client);
      // 给足补充链跑完的时间并拖到底，再断言整区不出现。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -400),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const ValueKey('detail-stills-section')),
        findsNothing,
      );
    });
  });
}

class _EmptyDetailRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async =>
      DramaDetail(drama, const []);
}
