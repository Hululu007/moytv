import 'package:moyi/app_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required List<HomeZone> zones,
    required List<AppDrawerTool> tools,
    required VoidCallback onWatchRoom,
    HomeZone zone = HomeZone.library,
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
            onZoneSelected: zones.add,
            onWatchRoom: onWatchRoom,
            onTool: tools.add,
            onMinorProtectionChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('drawer zone tiles map to their zones', (tester) async {
    final zones = <HomeZone>[];
    var room = 0;
    await pumpDrawer(
      tester,
      zones: zones,
      tools: [],
      onWatchRoom: () => room++,
    );
    await tester.tap(find.text('片库'));
    expect(zones, [HomeZone.library]);
    await tester.tap(find.text('直播'));
    expect(zones, [HomeZone.library, HomeZone.live]);
    await tester.tap(find.text('一起看房间'));
    expect(room, 1);
    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('听书'));
    expect(zones.last, HomeZone.audio);
  });

  testWidgets('drawer tool tiles map to their tools', (tester) async {
    final tools = <AppDrawerTool>[];
    await pumpDrawer(tester, zones: [], tools: tools, onWatchRoom: () {});
    const expected = {
      '站点区': AppDrawerTool.sources,
      '内容源管理': AppDrawerTool.contentSources,
      '设置': AppDrawerTool.settings,
      '播放器选择': AppDrawerTool.player,
      '软件更新': AppDrawerTool.appUpdate,
      '导入中心': AppDrawerTool.importCenter,
    };
    for (final entry in expected.entries) {
      await tester.ensureVisible(find.text(entry.key));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      if (entry.key == '软件更新') {
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.pumpAndSettle();
      expect(tools.last, entry.value);
    }
  });

  testWidgets('drawer sections are all expanded at once', (tester) async {
    await pumpDrawer(tester, zones: [], tools: [], onWatchRoom: () {});
    expect(find.text('影视模块'), findsOneWidget);
    expect(find.text('应用工具'), findsOneWidget);
    expect(find.text('常用入口 · 完整设置见「设置」'), findsOneWidget);
    for (final label in ['片库', '直播', '一起看房间', '站点区', '软件更新']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('音乐'), findsNothing);
    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('阅读模块'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('漫画区'), findsOneWidget);
    expect(find.text('听书'), findsOneWidget);
    expect(find.text('小说源'), findsOneWidget);
    expect(find.text('漫画源'), findsOneWidget);
    expect(find.text('书源文件'), findsOneWidget);
  });

  testWidgets('site source box keeps its key and tap callback', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SiteSourceBox(
            key: const ValueKey('drawer-site-box'),
            label: '测试站 (2)',
            onTap: () => tapped++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试站 (2)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('drawer-site-box')));
    expect(tapped, 1);
  });

  testWidgets('drawer header no longer shows the site box', (tester) async {
    await pumpDrawer(tester, zones: [], tools: [], onWatchRoom: () {});
    expect(find.text('魔蚁box'), findsOneWidget);
    expect(find.text('v1.0.1 (5)'), findsWidgets);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
  });

  testWidgets('drawer header carries avatar, name, version and footer', (
    tester,
  ) async {
    await pumpDrawer(tester, zones: [], tools: [], onWatchRoom: () {});
    expect(find.byKey(const ValueKey('drawer-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-app-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-version')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-footer')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-shelf-tabs')), findsOneWidget);
  });

  testWidgets('drawer shelf tabs switch grouped content', (tester) async {
    final tools = <AppDrawerTool>[];
    await pumpDrawer(tester, zones: [], tools: tools, onWatchRoom: () {});
    expect(find.text('影视模块'), findsOneWidget);
    expect(find.text('听书'), findsNothing);

    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('阅读模块'), findsOneWidget);
    expect(find.text('漫画区'), findsOneWidget);
    expect(find.text('听书'), findsOneWidget);
    expect(find.text('漫画'), findsNothing);

    await tester.ensureVisible(find.text('小程序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小程序'));
    await tester.pumpAndSettle();
    expect(find.text('小程序模块'), findsOneWidget);
    await tester.ensureVisible(find.text('小程序面板'));
    await tester.tap(find.text('小程序面板'));
    expect(tools.last, AppDrawerTool.miniApp);
  });

  testWidgets('shelf chips are three with no music chip', (tester) async {
    await pumpDrawer(tester, zones: [], tools: [], onWatchRoom: () {});
    expect(find.text('影视'), findsOneWidget);
    expect(find.text('阅读'), findsOneWidget);
    expect(find.text('小程序'), findsOneWidget);
    expect(find.text('音乐'), findsNothing);
    expect(find.text('音乐源'), findsNothing);
  });

  testWidgets('shelf chip taps switch the content zone', (tester) async {
    final zones = <HomeZone>[];
    final tools = <AppDrawerTool>[];
    await pumpDrawer(tester, zones: zones, tools: tools, onWatchRoom: () {});
    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(zones, [HomeZone.novel]);
    expect(find.text('阅读模块'), findsOneWidget);
    await tester.tap(find.text('影视'));
    await tester.pumpAndSettle();
    expect(zones, [HomeZone.novel, HomeZone.library]);
    expect(find.text('影视模块'), findsOneWidget);
    await tester.ensureVisible(find.text('小程序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小程序'));
    await tester.pumpAndSettle();
    expect(tools, [AppDrawerTool.miniApp]);
    expect(find.text('小程序模块'), findsOneWidget);
  });

  testWidgets('shelf chip taps do nothing when already selected', (
    tester,
  ) async {
    final zones = <HomeZone>[];
    await pumpDrawer(tester, zones: zones, tools: [], onWatchRoom: () {});
    await tester.tap(find.text('影视'));
    await tester.pumpAndSettle();
    expect(zones, isEmpty);
  });

  testWidgets('initial shelf follows the current zone', (tester) async {
    await pumpDrawer(
      tester,
      zones: [],
      tools: [],
      onWatchRoom: () {},
      zone: HomeZone.novel,
    );
    expect(find.text('阅读模块'), findsOneWidget);
    expect(find.text('影视模块'), findsNothing);
  });

  testWidgets('drawer has no midnight tile after the merge', (tester) async {
    await pumpDrawer(tester, zones: [], tools: [], onWatchRoom: () {});
    expect(find.text('午夜区'), findsNothing);
    expect(find.text('站点区'), findsOneWidget);
    expect(find.text('未成年保护'), findsOneWidget);
  });
}
