import 'package:moyi/app_drawer.dart';
import 'package:moyi/neon_glass_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDrawer(
    WidgetTester tester, {
    List<HomeZone>? zones,
    List<AppDrawerTool>? tools,
    List<int>? multimediaCalls,
    HomeZone zone = HomeZone.library,
    bool multimediaActive = false,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDrawer(
            zone: zone,
            currentVersion: '1.0.1',
            onZoneSelected: (value) => zones?.add(value),
            onWatchRoom: () {},
            onTool: (value) => tools?.add(value),
            onMinorProtectionChanged: (_) {},
            onMultimediaRequested: multimediaCalls == null
                ? null
                : () => multimediaCalls.add(1),
            multimediaActive: multimediaActive,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectNoSourceTypeLeak(WidgetTester tester) {
    for (final element in find.byType(Text).evaluate()) {
      final widget = element.widget as Text;
      final plain = widget.textSpan?.toPlainText() ?? widget.data ?? '';
      expect(
        plain,
        isNot(contains('sourceType')),
        reason: '抽屉文本漏出内部词: $plain',
      );
    }
  }

  testWidgets('drawer shelf tabs carry four entries including multimedia', (
    tester,
  ) async {
    await pumpDrawer(tester);
    expect(find.text('影视'), findsOneWidget);
    expect(find.text('阅读'), findsOneWidget);
    expect(find.text('小程序'), findsOneWidget);
    expect(find.text('多媒体'), findsOneWidget);
    // 未传多媒体回调时点按不崩（回调可空，与旧构造点兼容）。
    await tester.ensureVisible(find.text('多媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多媒体'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping multimedia tab fires only the multimedia callback', (
    tester,
  ) async {
    final zones = <HomeZone>[];
    final tools = <AppDrawerTool>[];
    final multimedia = <int>[];
    await pumpDrawer(
      tester,
      zones: zones,
      tools: tools,
      multimediaCalls: multimedia,
    );
    await tester.ensureVisible(find.text('多媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多媒体'));
    await tester.pumpAndSettle();
    expect(multimedia, [1]);
    expect(zones, isEmpty);
    expect(tools, isEmpty);
  });

  testWidgets(
    'tapping multimedia tab closes the drawer when the parent pops in the callback',
    (tester) async {
      final scaffoldKey = GlobalKey<ScaffoldState>();
      var requested = 0;
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            key: scaffoldKey,
            drawer: AppDrawer(
              zone: HomeZone.library,
              currentVersion: '1.0.1',
              onZoneSelected: (_) {},
              onWatchRoom: () {},
              onTool: (_) {},
              onMinorProtectionChanged: (_) {},
              // 模拟首页 _drawer() 的接线：回调里关抽屉再递请求。
              onMultimediaRequested: () {
                requested++;
                scaffoldKey.currentState?.closeDrawer();
              },
            ),
            body: const Text('正文'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      expect(find.text('多媒体'), findsOneWidget);
      await tester.ensureVisible(find.text('多媒体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('多媒体'));
      await tester.pumpAndSettle();
      expect(requested, 1);
      expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
      expect(find.text('多媒体'), findsNothing);
    },
  );

  testWidgets('tapping multimedia tab does nothing when already in multimedia', (
    tester,
  ) async {
    final multimedia = <int>[];
    await pumpDrawer(
      tester,
      multimediaCalls: multimedia,
      multimediaActive: true,
    );
    await tester.ensureVisible(find.text('多媒体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多媒体'));
    await tester.pumpAndSettle();
    expect(multimedia, isEmpty);
  });

  testWidgets('multimedia tab highlights only when multimedia is active', (
    tester,
  ) async {
    await pumpDrawer(tester, multimediaActive: true);
    NeonCapsule capsuleOf(String label) => tester.widget<NeonCapsule>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(NeonCapsule),
      ),
    );
    expect(capsuleOf('多媒体').selected, isTrue);
    expect(capsuleOf('影视').selected, isFalse);
    expect(capsuleOf('阅读').selected, isFalse);
    expect(capsuleOf('小程序').selected, isFalse);
    // 选中样式与现有胶囊一致：选中字重 w800，未选中 w600。
    expect(
      tester.widget<Text>(find.text('多媒体')).style?.fontWeight,
      FontWeight.w800,
    );
    expect(
      tester.widget<Text>(find.text('影视')).style?.fontWeight,
      FontWeight.w600,
    );
  });

  testWidgets('multimedia tab is unselected when multimedia is inactive', (
    tester,
  ) async {
    await pumpDrawer(tester);
    NeonCapsule capsuleOf(String label) => tester.widget<NeonCapsule>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(NeonCapsule),
      ),
    );
    expect(capsuleOf('多媒体').selected, isFalse);
    expect(capsuleOf('影视').selected, isTrue);
  });

  testWidgets('drawer shows no sourceType leak in any shelf', (tester) async {
    await pumpDrawer(tester);
    expectNoSourceTypeLeak(tester);
    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('打开阅读区 · 漫画源'), findsOneWidget);
    expectNoSourceTypeLeak(tester);
    await tester.ensureVisible(find.text('小程序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小程序'));
    await tester.pumpAndSettle();
    expectNoSourceTypeLeak(tester);
  });
}
