import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/crosssite_probe_section.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _SheetFakeRepository extends FixtureRepository {
  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    final items = <Drama>[];
    for (final source in sources) {
      if (source == 'jar:zakatv:zakav01') {
        items.add(
          const Drama(
            id: 'hmn-927',
            source: 'jar:zakatv:zakav01',
            title: 'hmn-927',
          ),
        );
      }
    }
    return CatalogPage(items);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    return DramaDetail(drama, [
      Episode({'id': 'p0', 'title': '线路1 · 正片', 'flag': '线路1'}, 1),
      Episode({'id': 'p1', 'title': '线路2 · 正片', 'flag': '线路2'}, 2),
    ]);
  }
}

void main() {
  const candidateSites = [
    SourceSite('javmenu', 'JavMenu', '', section: SourceSite.sectionVideo),
    SourceSite(
      'jar:zakatv:zakav01',
      'AV01',
      '',
      section: SourceSite.sectionVideo,
    ),
    SourceSite(
      'jar:zakatv:ZakaJable',
      'Jable',
      '',
      section: SourceSite.sectionVideo,
    ),
    SourceSite(
      'jar:missav30:ZakaMissav',
      'MissAV',
      '',
      section: SourceSite.sectionVideo,
    ),
  ];

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<void> pumpSection(
    WidgetTester tester, {
    void Function(DramaDetail, int)? onPlayLine,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await createStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CrossSiteProbeSection(
              repository: _SheetFakeRepository(),
              store: store,
              avId: 'HMN-927',
              onPlayLine: onPlayLine ?? (_, _) {},
              candidateSites: candidateSites,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('crosssite-entry')));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  /// 在弹窗内拖到目标可点：靠下的行/胶囊在折叠处之下时直接点按落空。
  Future<void> dragSheetTo(WidgetTester tester, Finder target) async {
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('crosssite-sheet')),
      matching: find.byType(SingleChildScrollView),
    );
    for (var i = 0; i < 10 && target.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('detail page shows only the compact entry, no inline rows',
      (tester) async {
    await pumpSection(tester);
    await settle(tester);
    expect(find.byKey(const ValueKey('crosssite-section')), findsOneWidget);
    expect(find.text('跨站选线路'), findsOneWidget);
    expect(find.byKey(const ValueKey('crosssite-sheet')), findsNothing);
    expect(find.text('点击查询'), findsNothing);
    expect(find.text('Jable'), findsNothing);
    expect(find.text('MissAV'), findsNothing);
    // 入口行带摘要：AV01 已探出线路。
    expect(find.textContaining('1 家有线路'), findsOneWidget);
  });

  testWidgets('tapping the entry opens the sheet with all rows', (
    tester,
  ) async {
    await pumpSection(tester);
    await settle(tester);
    await openSheet(tester);
    expect(find.byKey(const ValueKey('crosssite-sheet')), findsOneWidget);
    expect(find.text('JavMenu'), findsOneWidget);
    expect(find.text('AV01'), findsOneWidget);
    expect(find.text('Jable'), findsOneWidget);
    expect(find.text('MissAV'), findsOneWidget);
    expect(find.text('点击查询'), findsNWidgets(2));
    expect(find.text('线路1'), findsOneWidget);
    expect(find.text('线路2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('crosssite-recommended')),
      findsOneWidget,
    );
  });

  testWidgets('closing the sheet keeps probes, tapping a line plays', (
    tester,
  ) async {
    DramaDetail? played;
    var playedIndex = -1;
    await pumpSection(
      tester,
      onPlayLine: (detail, index) {
        played = detail;
        playedIndex = index;
      },
    );
    await settle(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('crosssite-sheet-close')));
    // 关弹窗动画须多帧泵才走完：单帧泵 400ms 时计时器刚起步。
    for (
      var i = 0;
      i < 10 &&
          find.byKey(const ValueKey('crosssite-sheet')).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('crosssite-sheet')), findsNothing);
    // 再打开，探活结果还在（关弹窗不取消探活）。
    await openSheet(tester);
    expect(find.text('线路1'), findsOneWidget);
    final line = find.byKey(
      const ValueKey('crosssite-line-jar:zakatv:zakav01-0-1'),
    );
    await dragSheetTo(tester, line);
    await tester.tap(line);
    // 关弹窗动画须多帧泵才走完：单帧泵 400ms 时计时器刚起步。
    for (
      var i = 0;
      i < 10 &&
          find.byKey(const ValueKey('crosssite-sheet')).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(played, isNotNull);
    expect(playedIndex, 1);
    expect(find.byKey(const ValueKey('crosssite-sheet')), findsNothing);
  });
}
