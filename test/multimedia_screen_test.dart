import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:moyi/tmdb/tmdb_metadata.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _pan115 = SourceSite('cloud:pan115', '115网盘', '');
const _quark = SourceSite('cloud:quark', '夸克网盘', '');

Drama _video(String id, String source, String title) =>
    Drama(id: id, source: source, title: title, kind: 'video');

Drama _folder(String id, String source, String title, String folderId) => Drama(
  id: id,
  source: source,
  title: title,
  kind: 'folder',
  folderId: folderId,
);

class _MultimediaFakeRepository extends FixtureRepository {
  final calls = <String>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    calls.add('$source|$category|$query');
    if (query.isNotEmpty) {
      if (source == 'cloud:pan115' && query == '仙剑') {
        return CatalogPage([_video('pan115:e1', source, '仙剑 第1集.mp4')]);
      }
      return CatalogPage([]);
    }
    if (category == 'f1') {
      return CatalogPage([
        _video('pan115:e1', source, '仙剑 第1集.mp4'),
        _video('pan115:e2', source, '仙剑 第2集.mp4'),
      ]);
    }
    if (source == 'cloud:pan115') {
      return CatalogPage([
        _folder('pan115:f1', source, '剧集', 'f1'),
        _video('pan115:e1', source, '仙剑 第1集.mp4'),
        _video('pan115:m1', source, '电影A.mp4'),
      ]);
    }
    if (source == 'cloud:quark') {
      return CatalogPage([_video('quark:d1', source, '纪录片.mp4')]);
    }
    return CatalogPage([]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> makeStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    required _MultimediaFakeRepository repository,
    List<SourceSite> driveSites = const [_pan115, _quark],
    void Function(Drama)? onOpenDrama,
    VoidCallback? onOpenCloudLogin,
    MultimediaMetadataFetcher? metadataFetcher,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultimediaScreen(
            repository: repository,
            store: await makeStore(),
            driveSites: driveSites,
            onOpenDrama: onOpenDrama ?? (_) {},
            onOpenCloudLogin: onOpenCloudLogin,
            metadataFetcher: metadataFetcher,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  group('多媒体屏（第 6 件）', () {
    testWidgets('未登录时诚实提示 + 跳转按钮回调', (tester) async {
      var tapped = false;
      await pumpScreen(
        tester,
        repository: _MultimediaFakeRepository(),
        driveSites: const [],
        onOpenCloudLogin: () => tapped = true,
      );
      expect(find.text('还没有登录任何网盘'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('multimedia-login-button')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('multimedia-login-button')));
      expect(tapped, isTrue);
    });

    testWidgets('未登录且无跳转回调时不显示按钮', (tester) async {
      await pumpScreen(
        tester,
        repository: _MultimediaFakeRepository(),
        driveSites: const [],
      );
      expect(find.text('还没有登录任何网盘'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('multimedia-login-button')),
        findsNothing,
      );
    });

    testWidgets('已登录聚合两家网盘，点网盘芯片只看那家', (tester) async {
      await pumpScreen(
        tester,
        repository: _MultimediaFakeRepository(),
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async =>
                null,
      );
      expect(find.text('仙剑 第1集.mp4'), findsOneWidget);
      expect(find.text('电影A.mp4'), findsOneWidget);
      expect(find.text('纪录片.mp4'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('multimedia-drive-chip-cloud:quark')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('纪录片.mp4'), findsOneWidget);
      expect(find.text('电影A.mp4'), findsNothing);
    });

    testWidgets('文件夹下钻与返回', (tester) async {
      final repository = _MultimediaFakeRepository();
      await pumpScreen(
        tester,
        repository: repository,
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async =>
                null,
      );
      await tester.tap(find.text('剧集'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.calls, contains('cloud:pan115|f1|'));
      expect(find.text('仙剑 第2集.mp4'), findsOneWidget);
      expect(find.byKey(const ValueKey('multimedia-back')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('multimedia-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('电影A.mp4'), findsOneWidget);
      expect(find.byKey(const ValueKey('multimedia-back')), findsNothing);
    });

    testWidgets('点视频卡进详情回调', (tester) async {
      Drama? opened;
      await pumpScreen(
        tester,
        repository: _MultimediaFakeRepository(),
        onOpenDrama: (drama) => opened = drama,
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async =>
                null,
      );
      await tester.tap(find.text('电影A.mp4'));
      expect(opened, isNotNull);
      expect(opened!.id, 'pan115:m1');
    });

    testWidgets('搜索走网盘搜索并显示结果', (tester) async {
      final repository = _MultimediaFakeRepository();
      await pumpScreen(
        tester,
        repository: repository,
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async =>
                null,
      );
      await tester.enterText(
        find.byKey(const ValueKey('multimedia-search')),
        '仙剑',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.calls.any((call) => call.endsWith('|仙剑')), isTrue);
      expect(find.text('仙剑 第1集.mp4'), findsWidgets);
      expect(find.text('电影A.mp4'), findsNothing);
    });

    testWidgets('刷新按钮重新取数', (tester) async {
      final repository = _MultimediaFakeRepository();
      await pumpScreen(
        tester,
        repository: repository,
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async =>
                null,
      );
      final before = repository.calls.length;
      await tester.tap(find.byKey(const ValueKey('multimedia-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.calls.length, greaterThan(before));
    });
  });

  group('多媒体屏刮削（第 7 件）', () {
    testWidgets('刮削命中显示刮削标题与年份类型副标题', (tester) async {
      await pumpScreen(
        tester,
        repository: _MultimediaFakeRepository(),
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async =>
                const TmdbMetadata(
                  mediaType: 'movie',
                  title: '刮削标题',
                  year: '2024',
                  overview: '刮削简介',
                  posterPath: '/p.jpg',
                ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('刮削标题'), findsWidgets);
      expect(find.text('2024 · 电影'), findsWidgets);
    });

    testWidgets('刮削无果回落原文件名', (tester) async {
      await pumpScreen(
        tester,
        repository: _MultimediaFakeRepository(),
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async =>
                null,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('电影A.mp4'), findsOneWidget);
    });

    testWidgets('刮削抛错不卡列表', (tester) async {
      await pumpScreen(
        tester,
        repository: _MultimediaFakeRepository(),
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async =>
                throw StateError('刮削炸了'),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('电影A.mp4'), findsOneWidget);
      expect(find.text('纪录片.mp4'), findsOneWidget);
    });

    testWidgets('刮削只发搜索标题不带集数后缀', (tester) async {
      final asked = <String>[];
      await pumpScreen(
        tester,
        repository: _MultimediaFakeRepository(),
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async {
              asked.add(title);
              return null;
            },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(asked, contains('仙剑'));
      expect(asked.any((t) => t.contains('第1集')), isFalse);
    });
  });
}
