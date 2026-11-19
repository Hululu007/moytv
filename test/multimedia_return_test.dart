import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:moyi/player_back.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _DriveFakeRepository extends FixtureRepository {
  // 封面不抛错：否则卡片重试回调会在 pump 里把测试炸掉。
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (source.startsWith('cloud:')) {
      return CatalogPage([
        Drama(
          id: 'pan115:f1',
          source: source,
          title: '剧集',
          kind: 'folder',
          folderId: 'f1',
        ),
        Drama(
          id: 'pan115:e1',
          source: source,
          title: '仙剑 第1集.mp4',
          kind: 'video',
        ),
        Drama(
          id: 'pan115:m1',
          source: source,
          title: '电影A.mp4',
          kind: 'video',
        ),
      ]);
    }
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
      filters: filters,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('网盘视频返回', () {
    late LocalStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'hiddenSites': '[]',
        // 默认主题已改 XP：本测试验通用外壳，显式钉住紫蓝霓虹。
        'appThemeMode': 'purpleNeon',
      });
      store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      // 种子一个已登录网盘：与 CloudDriveStations.refresh 同一注册表。
      SourceSite.cloudDriveSites['cloud:pan115'] = SourceSite(
        'cloud:pan115',
        '115网盘',
        '网盘站源',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originBuiltin,
      );
      addTearDown(SourceSite.cloudDriveSites.clear);
    });

    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [homeRouteObserver],
          home: HomeScreen(
            repository: _DriveFakeRepository(),
            store: store,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> openMultimedia(WidgetTester tester) async {
      // 底部标签栏下标 3 是网盘（听读合并后）。
      await tester.tap(find.byKey(const ValueKey('shell-tab-3')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MultimediaScreen), findsOneWidget);
    }

    testWidgets('点网盘视频进详情再退出，回到网盘页、首页仍在', (tester) async {
      await pumpHome(tester);
      await openMultimedia(tester);
      // 选 115 网盘，列出视频。
      final driveChip = find.text('115网盘');
      if (driveChip.evaluate().isNotEmpty) {
        await tester.tap(driveChip.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('仙剑 第1集.mp4'), findsWidgets);
      await tester.tap(find.text('仙剑 第1集.mp4').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(DetailScreen), findsOneWidget);
      // 退出播放/详情：内嵌播放器会先截一次返回，循环退到详情消失。
      for (var i = 0; i < 3; i++) {
        if (find.byType(DetailScreen).evaluate().isEmpty) break;
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.byType(DetailScreen), findsNothing);
      expect(find.byType(MultimediaScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });

  group('播放器返回判定', () {
    test('首路由才回首页，否则回列表', () {
      expect(
        resolvePlayerBackAction(
          panelOpen: false,
          pageFullscreen: false,
          fullscreen: false,
          television: false,
          isFirstRoute: true,
        ),
        PlayerBackAction.toHome,
      );
      expect(
        resolvePlayerBackAction(
          panelOpen: false,
          pageFullscreen: false,
          fullscreen: false,
          television: false,
          isFirstRoute: false,
        ),
        PlayerBackAction.backToList,
      );
    });

    test('面板与全屏优先于返回', () {
      expect(
        resolvePlayerBackAction(
          panelOpen: true,
          pageFullscreen: true,
          fullscreen: true,
          television: false,
          isFirstRoute: false,
        ),
        PlayerBackAction.closePanel,
      );
      expect(
        resolvePlayerBackAction(
          panelOpen: false,
          pageFullscreen: false,
          fullscreen: true,
          television: false,
          isFirstRoute: false,
        ),
        PlayerBackAction.exitFullscreen,
      );
    });

    test('回列表停在首页路由，跳过播放与详情路由', () {
      Route<dynamic> routeWithName(String? name) => MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => const SizedBox.shrink(),
      );
      expect(isBackToListStop(routeWithName('player')), isFalse);
      expect(isBackToListStop(routeWithName('detail')), isFalse);
      expect(isBackToListStop(routeWithName('/')), isTrue);
      expect(isBackToListStop(routeWithName(null)), isTrue);
    });
  });
}
