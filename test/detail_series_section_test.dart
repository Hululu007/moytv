import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:moyi/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const _anchor = Drama(
  id: 'hongguo:12345678901',
  source: 'hongguo',
  title: '测试剧第一季',
  episodes: 2,
  category: '合成数据',
);

Drama _season(String id, String title) => Drama(
  id: id,
  source: 'hongguo',
  title: title,
  episodes: 2,
  category: '合成数据',
);

class SeriesTestRepository extends FixtureRepository {
  List<Drama> related = const [];
  List<Map<String, Object?>>? apiItems;
  bool apiThrows = true;

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [];

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    return DramaDetail(drama, [
      Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
      Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
    ], related: related);
  }

  @override
  Future<Map<String, dynamic>> hongguoAccountRelated(String seriesId) async {
    if (apiThrows) throw AppFailure('当前环境不支持红果账号');
    return {'items': apiItems ?? const []};
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _dragToVisible(WidgetTester tester, Finder finder) async {
  final scroll = find.byType(CustomScrollView);
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await tester.drag(scroll, const Offset(0, -500));
    await _settle(tester);
  }
}

Future<void> pumpDetail(
  WidgetTester tester,
  SeriesTestRepository repository, {
  Drama drama = _anchor,
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = LocalStore(await SharedPreferences.getInstance());
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: DetailScreen(
        drama: drama,
        repository: repository,
        store: store,
        playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
      ),
    ),
  );
  await _settle(tester);
}

/// 相关区卡片在树里的顺序即季号顺序。
List<String> _seriesCardIds(WidgetTester tester) {
  final tiles = tester.widgetList(
    find.byWidgetPredicate(
      (widget) =>
          widget is DramaTile &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('series-card-'),
    ),
  );
  return tiles.map((tile) => (tile as DramaTile).drama.id).toList();
}

void main() {
  testWidgets('接口不可用时回落标题规律：相关区按季号升序、当前标出', (
    tester,
  ) async {
    final repository = SeriesTestRepository()
      ..related = [
        _season('hongguo:12345678903', '测试剧第三季'),
        _season('hongguo:12345678902', '测试剧第二季'),
        _season('hongguo:12345678904', '别的剧第一季'),
        const Drama(
          id: 'huangdou:12345678905',
          source: 'huangdou',
          title: '测试剧第四季',
          episodes: 2,
        ),
      ];
    await pumpDetail(tester, repository);
    await _dragToVisible(tester, find.text('相关剧集'));
    expect(find.text('相关剧集'), findsOneWidget);
    expect(
      _seriesCardIds(tester),
      ['hongguo:12345678901', 'hongguo:12345678902', 'hongguo:12345678903'],
    );
    // 当前这季的卡标“当前”；季标签只查卡内（选季 chips 里也有同文）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('series-card-hongguo:12345678901')),
        matching: find.text('当前'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('series-card-hongguo:12345678902')),
        matching: find.text('第 2 季'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('series-card-hongguo:12345678903')),
        matching: find.text('第 3 季'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('点其它季的卡进那一季详情页，点当前季不动', (tester) async {
    final repository = SeriesTestRepository()
      ..related = [_season('hongguo:12345678902', '测试剧第二季')];
    await pumpDetail(tester, repository);
    final currentCard = find.byKey(
      const ValueKey('series-card-hongguo:12345678901'),
    );
    await _dragToVisible(tester, currentCard);
    await tester.tap(currentCard);
    await _settle(tester);
    expect(find.byType(DetailScreen), findsOneWidget);
    expect(
      tester.widget<DetailScreen>(find.byType(DetailScreen)).drama.id,
      'hongguo:12345678901',
    );

    final nextCard = find.byKey(
      const ValueKey('series-card-hongguo:12345678902'),
    );
    await tester.tap(nextCard);
    await _settle(tester);
    expect(find.byType(DetailScreen), findsOneWidget);
    expect(
      tester.widget<DetailScreen>(find.byType(DetailScreen)).drama.id,
      'hongguo:12345678902',
    );
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('站方接口有季号时优先用接口，待上线的不进区', (tester) async {
    final repository = SeriesTestRepository()
      ..apiThrows = false
      ..apiItems = [
        {
          'seriesId': '12345678902',
          'title': '测试剧第二季',
          'seasonIndex': 2,
          'upcoming': false,
        },
        {
          'seriesId': '12345678903',
          'title': '测试剧第三季',
          'seasonIndex': 3,
          'upcoming': false,
        },
        {
          'seriesId': '12345678904',
          'title': '测试剧第四季',
          'seasonIndex': 4,
          'upcoming': true,
        },
      ];
    await pumpDetail(tester, repository);
    await _dragToVisible(tester, find.text('相关剧集'));
    expect(find.text('相关剧集'), findsOneWidget);
    expect(
      _seriesCardIds(tester),
      ['hongguo:12345678901', 'hongguo:12345678902', 'hongguo:12345678903'],
    );
  });

  testWidgets('无兄弟季时相关区隐藏', (tester) async {
    final repository = SeriesTestRepository();
    await pumpDetail(tester, repository);
    expect(find.text('相关剧集'), findsNothing);
  });

  testWidgets('非红果剧没有相关区', (tester) async {
    final repository = SeriesTestRepository()
      ..related = [
        const Drama(
          id: 'huangdou:200',
          source: 'huangdou',
          title: '会员测试剧第二季',
          episodes: 2,
        ),
      ];
    await pumpDetail(tester, repository, drama: FixtureRepository.vip);
    expect(find.text('相关剧集'), findsNothing);
  });
}
