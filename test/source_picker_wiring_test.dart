import 'package:moyi/app_build.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_screen.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/live_store.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _FailingLiveRepository extends LiveRepository {
  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => throw AppFailure('合成直播失败');
}

void main() {
  Future<LocalStore> makeStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  testWidgets('短剧区：点顶栏源名弹弹窗，点选爱看机器人立即切换', (tester) async {
    final repository = FixtureRepository();
    final store = await makeStore();
    await tester.pumpWidget(MoyiApp(repository: repository, store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    expect(find.text('切换短剧源'), findsOneWidget);
    expect(find.text('内置短剧'), findsOneWidget);
    expect(find.text('当前：红果'), findsOneWidget);
    await tester.tap(find.text('爱看机器人'));
    await tester.pumpAndSettle();
    expect(find.text('切换短剧源'), findsNothing);
    expect(store.source, 'ikanbot');
    expect(repository.requests, contains('ikanbot'));
    expect(tester.takeException(), isNull);
  }, skip: !allSourcesEnabled);

  testWidgets('影视区：点顶栏源名弹弹窗，点选 XVideos 立即切换', (tester) async {
    final repository = FixtureRepository();
    final store = await makeStore();
    await tester.pumpWidget(MoyiApp(repository: repository, store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bottom-nav-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    expect(find.text('切换影视源'), findsOneWidget);
    expect(find.text('内置影视'), findsOneWidget);
    await tester.tap(find.text('XVideos'));
    await tester.pumpAndSettle();
    expect(find.text('切换影视源'), findsNothing);
    expect(store.source, 'v_xvideos');
    expect(repository.requests, contains('v_xvideos'));
    expect(tester.takeException(), isNull);
  }, skip: !allSourcesEnabled);

  testWidgets('直播区：点切换按钮弹弹窗，点选虎牙立即切换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final liveStore = LiveStore(preferences, 'default')..load();
    addTearDown(liveStore.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveScreen(
            repository: _FailingLiveRepository(),
            store: liveStore,
            greenMode: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('秀果 直播源暂时不可用'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('live-source-button')));
    await tester.pumpAndSettle();
    expect(find.text('切换直播源'), findsOneWidget);
    expect(find.text('当前：秀果'), findsOneWidget);
    await tester.tap(find.text('虎牙'));
    await tester.pumpAndSettle();
    expect(find.text('切换直播源'), findsNothing);
    expect(find.text('虎牙 直播源暂时不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
