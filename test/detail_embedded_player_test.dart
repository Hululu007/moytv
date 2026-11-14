import 'dart:async';

import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

class EmbeddedRouteRepository extends RouteRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

/// detail() 可挂起的仓库：装上 [deferredDetail] 后，下一次 detail()
/// 调用返回该挂起 future（模拟刷新中网络未回），用来复现“选集已
/// 显示、_loading 为真”时海报点按是否仍可用。
class DeferredDetailRepository extends EmbeddedRouteRepository {
  Completer<DramaDetail>? deferredDetail;

  @override
  Future<DramaDetail> detail(Drama drama) {
    final deferred = deferredDetail;
    if (deferred != null) return deferred.future;
    return super.detail(drama);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 详情页网格会触发后台取帧：测试里原生取帧通道不存在，桩返回 null
  //（取帧失败回落海报），避免 25 秒超时挂住假时钟、会话来不及释放。
  const frameChannel = MethodChannel('moyi/frame_extractor');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(frameChannel, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(frameChannel, null);
  });

  Future<void> settleOperations(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> settleDispose(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await settleOperations(tester);
  }

  testWidgets('detail play stays inline, switches episodes, closes to detail',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = EmbeddedRouteRepository();
    final store = LocalStore(await SharedPreferences.getInstance());
    final created = <ScriptedPlayer>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DetailScreen(
          drama: FixtureRepository.free,
          repository: repository,
          store: store,
          playerFactory: () {
            final platform = ScriptedPlayer();
            created.add(platform);
            return Player(platformPlayer: platform);
          },
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.byKey(const ValueKey('detail-poster-play')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('detail-poster-play')));
    await settleOperations(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(repository.requestedEpisodes, [1]);
    expect(find.text('正在播放 · 第 1 集'), findsOneWidget);
    expect(find.text('选集 · 2 集'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('close-embedded-player')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('toggle-embedded-fullscreen')));
    await settleOperations(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(created, hasLength(1));
    expect(find.text('正在播放 · 第 1 集'), findsNothing);
    await tester.tap(find.byTooltip('退出全屏').first);
    await settleOperations(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(created, hasLength(1));
    expect(find.text('正在播放 · 第 1 集'), findsOneWidget);

    await tester.tap(find.text('选集 · 2 集'));
    await settleOperations(tester);
    await tester.tap(find.byKey(const ValueKey('episode-2')));
    await settleOperations(tester);
    await settleDispose(tester);
    expect(repository.requestedEpisodes, [1, 2]);
    expect(created, hasLength(2));
    expect(repository.active, {'route-2'});
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.text('正在播放 · 第 2 集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-embedded-player')));
    await settleOperations(tester);
    await settleDispose(tester);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(repository.active, isEmpty);
    expect(find.byKey(const ValueKey('detail-poster-play')), findsOneWidget);
    expect(find.text('选集 · 2 集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('poster stays tappable while a reload is in flight',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = DeferredDetailRepository();
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DetailScreen(
          drama: FixtureRepository.free,
          repository: repository,
          store: store,
          playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-poster-play')), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);

    // 第二次 detail() 挂起：点刷新后 _loading 为真，但选集数据仍在。
    // 加载中刷新钮自带旋转动画，只用定量 pump，不用 pumpAndSettle。
    final pending = Completer<DramaDetail>();
    repository.deferredDetail = pending;
    await tester.tap(find.byTooltip('更新剧集信息'));
    await settleOperations(tester);
    expect(find.byKey(const ValueKey('detail-poster-play')), findsOneWidget);

    // 海报键必须仍能起播：加载态不许卡死海报播放入口。
    await tester.tap(find.byKey(const ValueKey('detail-poster-play')));
    await settleOperations(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.text('正在播放 · 第 1 集'), findsOneWidget);

    // 放行挂起的加载，干净收尾。
    pending.complete(await FixtureRepository().detail(FixtureRepository.free));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
