import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/mini_app_builtin.dart';
import 'package:moyi/miniapp/mini_app_home_page.dart';
import 'package:moyi/miniapp/mini_app_manifest.dart';
import 'package:moyi/miniapp/mini_app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('miniapp_warm_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tempDir.path);
  });

  tearDownAll(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  setUp(() {
    MiniAppHomeCache.resetForTest();
    // 播种已记名：冷加载跳过 zip 安装（不解 59MB 大包）；市场地址
    // 指到本机闭口，拉取立刻失败，不碰真网。
    SharedPreferences.setMockInitialValues({
      MiniAppBuiltin.seededAppIdsKey: [
        'com.ant.emby',
        'com.leospring.cms_t4_bridge',
        'com.leospring.source_t4_bridge',
        'com.leospring.drpy_node',
      ],
      MiniAppSettings.keyMarketUrl: 'http://127.0.0.1:1/market.json',
    });
  });

  tearDown(() {
    MiniAppHomeCache.resetForTest();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MiniAppHomePage()));
  }

  // 交替排干：冷启动首帧的转圈是无限动画，pumpAndSettle 永远等不到
  // 静止；且 _load 的等待链是假异步（prefs/rootBundle/平台通道 mock，
  // 靠 pump 推）与真 I/O（目录 exists/create/list 流，靠 runAsync 推）
  // 交替出现，单次 runAsync + pump 只够推进一步、会卡在半道。两者
  // 交替推、暖了就停。
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      if (MiniAppHomeCache.isWarm) break;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('cold start shows spinner on first frame, then warms cache', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(TabBarView), findsNothing);
    await drain(tester);
    expect(find.byType(TabBarView), findsOneWidget);
    expect(MiniAppHomeCache.isWarm, isTrue);
  });

  testWidgets('warm start shows installed content on first frame', (
    tester,
  ) async {
    MiniAppHomeCache.warmForTest(
      settings: const MiniAppSettings(),
      installed: const [MiniAppManifest(appId: 'com.ant.emby', name: '影视库')],
    );
    await pumpPage(tester);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(TabBarView), findsOneWidget);
    expect(find.text('影视库'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('second entry reuses cache without spinner', (tester) async {
    await pumpPage(tester);
    await drain(tester);
    expect(MiniAppHomeCache.isWarm, isTrue);
    // 退出再进：全新一页，第一帧就该是内容。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    await pumpPage(tester);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(TabBarView), findsOneWidget);
    expect(find.text('还没有安装小程序'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('warm market list shows without spinner', (tester) async {
    MiniAppHomeCache.warmForTest(
      settings: const MiniAppSettings(),
      market: const [
        MiniAppMarketItem(
          appId: 'com.example.future',
          name: '上游新应用',
          url: 'https://example.com/future.zip',
        ),
      ],
      marketLoaded: true,
    );
    await pumpPage(tester);
    await tester.pump();
    await tester.tap(find.text('市场'));
    await drain(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('上游新应用'), findsOneWidget);
  });
}
