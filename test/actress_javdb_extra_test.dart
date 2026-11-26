// JavDB 补充第二路（2026-11-26）：磁力区 + 评论区 + 信息
// 卡系列/评分。解析层用假取数验夹具：磁力照 AvPlay 实证字
// 段（hash 拼 magnet 链接、size 数字按 MB、created_at、
// hd/cnsub），评论照 JavDbApiReview 字段（username/content/
// created_at/likes_count），评分照原值 + 人数兜底链。详情
// 页接线用组件测试验三处都出现、磁力点按复制、番号没命中
// 时全都不出现。真接口未验（本机出口断），只验解析与接线。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// 假取数：按网址分发搜索/磁力/评论/详情响应。
class _FakeJavdbExtra {
  _FakeJavdbExtra({
    required this.searchResults,
    this.magnetsById = const {},
    this.reviewsById = const {},
    this.detailById = const {},
  });

  final List<Map<String, Object?>> searchResults;
  final Map<String, List<Map<String, Object?>>> magnetsById;
  final Map<String, List<Map<String, Object?>>> reviewsById;
  final Map<String, Map<String, Object?>> detailById;
  final requested = <String>[];

  Future<String> fetch(String url) async {
    requested.add(url);
    if (url.contains('api/v2/search')) {
      return _envelope({'movies': searchResults});
    }
    if (url.contains('/magnets')) {
      final id = url.split('api/v1/movies/').last.split('/').first;
      return _envelope({'magnets': magnetsById[id] ?? const []});
    }
    if (url.contains('/reviews')) {
      final id = url.split('api/v1/movies/').last.split('/').first;
      return _envelope({'reviews': reviewsById[id] ?? const []});
    }
    if (url.contains('api/v1/movies/')) {
      final id = url.split('api/v1/movies/').last;
      return _envelope(detailById[id] ?? const {});
    }
    throw StateError('未预期的网址：$url');
  }

  JavdbApiClient get client => JavdbApiClient(fetch: fetch);
}

void main() {
  group('磁力解析', () {
    test('AvPlay 实证字段：hash 拼链接、size 数字按 MB、日期归一、hd/字幕', () async {
      final fake = _FakeJavdbExtra(
        searchResults: const [],
        magnetsById: {
          'm1': [
            {
              'hash': 'ABCDEF0123',
              'name': 'SSIS-001 HD',
              'size': 2048,
              'created_at': '2024-06-15T00:00:00.000Z',
              'hd': true,
              'cnsub': true,
            },
          ],
        },
      );
      final magnets = await fake.client.movieMagnets('m1');
      expect(magnets, hasLength(1));
      final magnet = magnets.single;
      expect(magnet.url, 'magnet:?xt=urn:btih:ABCDEF0123');
      expect(magnet.name, 'SSIS-001 HD');
      expect(magnet.sizeLabel, '2 GB');
      expect(magnet.date, '20240615');
      expect(magnet.metaLabel, '2 GB · HD · 字幕 · 2024-06-15');
    });

    test('size 字符串照原样、小数 MB 不进位、无 hash 无链接的行跳过', () async {
      final fake = _FakeJavdbExtra(
        searchResults: const [],
        magnetsById: {
          'm1': [
            {'hash': 'H1', 'name': '甲', 'size': '850 MB'},
            {'hash': 'H2', 'name': '乙', 'size': 850},
            {'name': '无 hash 也无链接', 'size': 100},
            {'magnet': 'magnet:?xt=urn:btih:DIRECT', 'name': '丙'},
          ],
        },
      );
      final magnets = await fake.client.movieMagnets('m1');
      expect(magnets, hasLength(3));
      expect(magnets[0].sizeLabel, '850 MB');
      expect(magnets[1].sizeLabel, '850 MB');
      expect(magnets[2].url, 'magnet:?xt=urn:btih:DIRECT');
    });

    test('接口出错时抛错、由调用方兜底（与既有方法同口径）', () async {
      final client = JavdbApiClient(
        fetch: (_) async => throw StateError('网络断开'),
      );
      await expectLater(client.movieMagnets('m1'), throwsStateError);
      await expectLater(client.movieReviews('m1'), throwsStateError);
    });
  });

  group('评论解析', () {
    test('实证字段直认、user 子对象兜底昵称头像、空内容跳过', () async {
      final fake = _FakeJavdbExtra(
        searchResults: const [],
        reviewsById: {
          'm1': [
            {
              'username': '甲',
              'content': '画质很好',
              'created_at': '2024-06-20 10:00:00',
              'likes_count': 7,
              'score': 5,
            },
            {
              'user': {
                'nickname': '乙',
                'avatar_url': 'https://c0.jdbstatic.com/avatars/b.jpg',
              },
              'content': '同感',
              'created_at': '2024-06-21',
              'likes_count': '3',
            },
            {'username': '丙', 'content': ''},
          ],
        },
      );
      final reviews = await fake.client.movieReviews('m1');
      expect(reviews, hasLength(2));
      expect(reviews[0].username, '甲');
      expect(reviews[0].content, '画质很好');
      expect(reviews[0].likes, 7);
      expect(reviews[1].username, '乙');
      expect(reviews[1].avatarUrl, 'https://c0.jdbstatic.com/avatars/b.jpg');
      expect(reviews[1].likes, 3);
    });
  });

  group('评分解析', () {
    test('score 照原值、人数 reviews_count 兜底、系列进 extraInfo', () async {
      final fake = _FakeJavdbExtra(
        searchResults: const [],
        detailById: {
          'm1': {
            'score': 4.5,
            'reviews_count': 123,
            'series_name': 'S1 NO.1 STYLE',
          },
        },
      );
      final extra = await fake.client.movieExtra('m1');
      expect(extra.score, '4.5');
      expect(extra.scoreCount, 123);
      expect(extra.extraInfo, contains(('系列', 'S1 NO.1 STYLE')));
    });

    test('score_count 优先于 reviews_count', () async {
      final fake = _FakeJavdbExtra(
        searchResults: const [],
        detailById: {
          'm1': {'score': '4.0', 'score_count': 9, 'reviews_count': 100},
        },
      );
      final extra = await fake.client.movieExtra('m1');
      expect(extra.scoreCount, 9);
    });
  });

  group('详情页接线', () {
    setUpAll(() {
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

    Future<bool> waitFor(WidgetTester tester, Finder finder) async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        if (finder.evaluate().isNotEmpty) return true;
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 100));
      }
      return false;
    }

    _FakeJavdbExtra hitFake() => _FakeJavdbExtra(
      searchResults: [_movieJson('m1', 'SSIS-001')],
      magnetsById: {
        'm1': [
          {
            'hash': 'ABCDEF0123',
            'name': 'SSIS-001 HD',
            'size': 2048,
            'created_at': '2024-06-15',
            'hd': true,
            'cnsub': true,
          },
        ],
      },
      reviewsById: {
        'm1': [
          {
            'username': '甲',
            'content': '画质很好',
            'created_at': '2024-06-20',
            'likes_count': 7,
          },
        ],
      },
      detailById: {
        'm1': {
          'score': 4.5,
          'reviews_count': 123,
          'series_name': 'S1 NO.1 STYLE',
          'preview_images': const [],
        },
      },
    );

    testWidgets('磁力区/评论区出现、信息卡补系列与评分、磁力点按复制', (tester) async {
      String? clipboardText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardText =
                  (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pumpDetail(tester, client: hitFake().client);
      // 信息卡在页面上半段：先等评分行落地（补充链完成）。
      expect(
        await waitFor(tester, find.text('4.5（共 123 人评分）')),
        isTrue,
      );
      expect(find.text('S1 NO.1 STYLE'), findsOneWidget);
      // 磁力区：名称与副标在，点按复制并给中文提示。
      expect(
        await waitFor(
          tester,
          find.byKey(const ValueKey('javdb-magnets-section')),
        ),
        isTrue,
      );
      expect(find.text('SSIS-001 HD'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('javdb-magnet-magnet:?xt=urn:btih:ABCDEF0123')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(clipboardText, 'magnet:?xt=urn:btih:ABCDEF0123');
      expect(find.text('磁力链接已复制'), findsOneWidget);
      // 评论区在最下方。
      expect(
        await waitFor(
          tester,
          find.byKey(const ValueKey('javdb-reviews-section')),
        ),
        isTrue,
      );
      expect(find.text('画质很好'), findsOneWidget);
    });

    testWidgets('番号没命中时磁力/评论/评分全都不出现', (tester) async {
      final fake = _FakeJavdbExtra(
        searchResults: [_movieJson('m9', 'SSIS-999')],
        magnetsById: {
          'm9': [
            {'hash': 'ZZZ', 'name': '别片磁力'},
          ],
        },
        reviewsById: {
          'm9': [
            {'username': '路人', 'content': '别片评论'},
          ],
        },
        detailById: {
          'm9': {'score': 9.9, 'reviews_count': 999},
        },
      );
      await pumpDetail(tester, client: fake.client);
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('javdb-magnets-section')), findsNothing);
      expect(find.byKey(const ValueKey('javdb-reviews-section')), findsNothing);
      expect(find.text('别片磁力'), findsNothing);
      expect(find.text('别片评论'), findsNothing);
      // 没命中就不该去取那部的磁力/评论/详情。
      expect(
        fake.requested.where((u) => u.contains('m9')),
        isEmpty,
      );
    });
  });
}

class _EmptyDetailRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async =>
      DramaDetail(drama, const []);
}
