import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

class _RecommendRepository extends FixtureRepository {
  final catalogCategories = <String>[];
  bool emptyCatalog = false;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory('cat1', '合成数据'),
    CatalogCategory('cat2', '其他分类'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    catalogCategories.add(category);
    if (emptyCatalog) return CatalogPage([]);
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
      filters: filters,
    );
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// 拖动详情页主滚动视图直到目标出现：scrollUntilVisible 在详情页会因
/// 多个 Scrollable 撞上 .single 抛错，这里显式拖 CustomScrollView。
Future<void> _dragToVisible(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 15 && target.evaluate().isEmpty; i++) {
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -500),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDetail(
    WidgetTester tester,
    _RecommendRepository repository,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DetailScreen(
          drama: FixtureRepository.free,
          repository: repository,
          store: store,
          playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('recommended section shows same-site videos except current',
      (tester) async {
    final repository = _RecommendRepository();
    await pumpDetail(tester, repository);
    await _dragToVisible(tester, find.text('推荐视频'));
    expect(find.text('推荐视频'), findsOneWidget);
    // 同分类优先：先按匹配到的分类 id 拉。
    expect(repository.catalogCategories, contains('cat1'));
    // 当前这部被排除，其他两部在。
    expect(
      find.byKey(const ValueKey('recommended-hongguo:100')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('recommended-huangdou:200')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recommended-hongguo:auto-1')),
      findsOneWidget,
    );
  });

  testWidgets('tapping a recommended card opens detail, not playback',
      (tester) async {
    final repository = _RecommendRepository();
    await pumpDetail(tester, repository);
    final card = find.byKey(const ValueKey('recommended-huangdou:200'));
    await _dragToVisible(tester, card);
    await tester.tap(card);
    await _settle(tester);
    expect(find.byType(DetailScreen), findsNWidgets(2));
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('recommended section hides when no data', (tester) async {
    final repository = _RecommendRepository()..emptyCatalog = true;
    await pumpDetail(tester, repository);
    expect(find.text('推荐视频'), findsNothing);
  });
}
