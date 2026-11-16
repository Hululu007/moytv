import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/home_zone.dart';
import 'package:moyi/live_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/player_back.dart';
import 'package:moyi/player_route.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 模拟 PlayerScreen 的返回壳：PopScope(canPop:false) + 系统返回时
/// popUntil(isBackToListStop)，与 player_screen.dart 的 _backToList
/// 在 backToList 分支的行为一致。
class _StubPlayer extends StatelessWidget {
  const _StubPlayer();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).popUntil(isBackToListStop);
        }
      },
      child: const Scaffold(body: Center(child: Text('stub-player'))),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 当前区探针：直播屏在树里就是直播区，否则是片库区。
  HomeZone currentZone(WidgetTester tester) =>
      find.byType(LiveScreen).evaluate().isNotEmpty
      ? HomeZone.live
      : HomeZone.library;

  Future<void> switchToLive(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('shell-tab-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<BuildContext> pumpHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    late final BuildContext homeContext;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: Builder(
          builder: (context) {
            homeContext = context;
            return HomeScreen(repository: FixtureRepository(), store: store);
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return homeContext;
  }

  testWidgets('直播区播放返回后仍在直播区，不回片库区', (tester) async {
    final homeContext = await pumpHome(tester);
    await switchToLive(tester);
    expect(await currentZone(tester), HomeZone.live);

    // 推一个与播放页同名('player')的路由，模拟直播直达播放。
    Navigator.of(homeContext).push(playerRoute(const _StubPlayer()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('stub-player'), findsOneWidget);

    // 系统返回（手势/返回键）：应回到直播区。
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('stub-player'), findsNothing);
    expect(await currentZone(tester), HomeZone.live);
  }, skip: !allSourcesEnabled);

  testWidgets('直播区播放返回后，再按一次返回才回片库区（区历史一次只退一级）',
      (tester) async {
    final homeContext = await pumpHome(tester);
    await switchToLive(tester);
    Navigator.of(homeContext).push(playerRoute(const _StubPlayer()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await currentZone(tester), HomeZone.live);

    // 首页再按一次返回：先熬过返回保护期（400ms），否则这次返回
    // 会被当成同一手势的重复投递而吞掉、不退区历史。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(await currentZone(tester), HomeZone.library);
  }, skip: !allSourcesEnabled);

  testWidgets('播放页返回过渡中多余的返回不吞区历史', (tester) async {
    final homeContext = await pumpHome(tester);
    await switchToLive(tester);
    Navigator.of(homeContext).push(playerRoute(const _StubPlayer()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 第一次返回：播放页弹出。
    await tester.binding.handlePopRoute();
    // 过渡还没跑完，紧接着又来一次返回（手势重复投递）：不能吞区历史。
    await tester.pump(const Duration(milliseconds: 30));
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('stub-player'), findsNothing);
    expect(await currentZone(tester), HomeZone.live);
  }, skip: !allSourcesEnabled);
}
