import 'package:moyi/app_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDrawer(
    WidgetTester tester, {
    bool midnightActivated = false,
    required List<HomeZone> zones,
    required List<AppDrawerTool> tools,
    required VoidCallback onWatchRoom,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDrawer(
            zone: HomeZone.drama,
            midnightActivated: midnightActivated,
            currentVersion: '1.0.1',
            onZoneSelected: zones.add,
            onWatchRoom: onWatchRoom,
            onTool: tools.add,
            onMinorProtectionChanged: (_) {},
            onVersionDoubleTap: () {},
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
      midnightActivated: true,
      zones: zones,
      tools: [],
      onWatchRoom: () => room++,
    );
    await tester.tap(find.text('点播'));
    expect(zones, [HomeZone.vod]);
    await tester.tap(find.text('午夜区'));
    expect(zones, [HomeZone.vod, HomeZone.midnight]);
    await tester.tap(find.text('直播'));
    expect(zones, [HomeZone.vod, HomeZone.midnight, HomeZone.live]);
    await tester.tap(find.text('听书'));
    expect(zones.last, HomeZone.audio);
    await tester.tap(find.text('一起看房间'));
    expect(room, 1);
  });

  testWidgets('drawer tool tiles map to their tools', (tester) async {
    final tools = <AppDrawerTool>[];
    await pumpDrawer(tester, zones: [], tools: tools, onWatchRoom: () {});
    const expected = {
      '站源管理': AppDrawerTool.sources,
      '内容源管理': AppDrawerTool.contentSources,
      '设置': AppDrawerTool.settings,
      '播放器选择': AppDrawerTool.player,
      '软件更新': AppDrawerTool.appUpdate,
      '导入中心': AppDrawerTool.importCenter,
      '解析接口': AppDrawerTool.parse,
      '站点验证': AppDrawerTool.clearance,
      '代理内核': AppDrawerTool.proxyKernel,
      '设备互联': AppDrawerTool.lanSync,
      '蜘蛛规则编辑器': AppDrawerTool.ruleEditor,
    };
    for (final entry in expected.entries) {
      await tester.tap(find.text(entry.key));
      if (entry.key == '软件更新') {
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.pumpAndSettle();
      expect(tools.last, entry.value);
    }
  });

  testWidgets('drawer sections are all expanded at once', (tester) async {
    await pumpDrawer(
      tester,
      midnightActivated: true,
      zones: [],
      tools: [],
      onWatchRoom: () {},
    );
    expect(find.text('影视区'), findsOneWidget);
    expect(find.text('阅读'), findsOneWidget);
    expect(find.text('应用工具'), findsOneWidget);
    expect(find.text('通用配置与管理'), findsOneWidget);
    for (final label in [
      '短剧',
      '点播',
      '午夜区',
      '直播',
      '一起看房间',
      '听书',
      '站源管理',
      '软件更新',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
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
    expect(find.text('当前版本 1.0.1'), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
  });

  testWidgets('midnight tile follows activation', (tester) async {
    await pumpDrawer(
      tester,
      midnightActivated: false,
      zones: [],
      tools: [],
      onWatchRoom: () {},
    );
    expect(find.text('午夜区'), findsNothing);
  });
}
