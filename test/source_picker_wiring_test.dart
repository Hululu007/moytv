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

  testWidgets('直播区：点切换按钮弹弹窗，点选哔哩哔哩立即切换', (tester) async {
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
    // 首个可见源是内置片库（whos_lib 在源表首位），不是旧断言里的秀果。
    expect(find.text('🔞内置片库 直播源暂时不可用'), findsOneWidget);
    // 切换入口在顶栏信息单里：点信息钮，再点“切换直播源”。
    // 点按只发事件不跑帧：先 pump 一次让点按生效、单子入栈，
    // 再 pump 一次让入场动画走完，单子落到屏内再点里面的格。
    await tester.tap(find.byKey(const ValueKey('live-video-info')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const ValueKey('live-info-switch-source')));
    await tester.pumpAndSettle();
    expect(find.text('切换直播源'), findsOneWidget);
    // 弹窗无“当前：X”文字，当前源以选中态瓦片表示（渐变 + 对勾）。
    expect(
      find.byKey(const ValueKey('site-picker-row-xiuguo')),
      findsOneWidget,
    );
    // 虎牙已于 2026-11-15 按用户令从内置直播源里删除，改点仍在的哔哩哔哩。
    // 哔哩哔哩在列表最底（初始 y≈1500，屏外）：手拖 ListView 只能把瓦片
    // 挪到“布局位置在屏内”，点按仍落空（弹层背景接住）；ensureVisible
    // 才是框架的正路，滚到位再点按，弹窗即关、源即换。
    final bilibiliTile = find.byKey(const ValueKey('site-picker-row-bilibili'));
    await tester.ensureVisible(bilibiliTile);
    await tester.pumpAndSettle();
    await tester.tap(bilibiliTile);
    await tester.pumpAndSettle();
    expect(find.text('切换直播源'), findsNothing);
    expect(find.text('哔哩哔哩 直播源暂时不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
