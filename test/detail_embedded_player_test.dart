import 'dart:async';

import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:flutter/foundation.dart';
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

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async {
    final plan = await super.resolve(
      drama,
      episode,
      adBlock: adBlock,
      quality: quality,
      route: route,
    );
    // 播放地址换成回环地址：_play 会对 http(s) 非回环地址做真实 HTTP
    // 302 预解析（5 秒真实时钟），桩地址 media.test 在测试里等不到
    // 回应，_loading 永远不清、加载遮罩盖住控制层点不到。回环地址
    // 跳过预解析，播放入口与控制层才能在测试里走到就绪态。
    return plan.withUrl(
      plan.url.replaceFirst('https://media.test', 'http://127.0.0.1'),
    );
  }
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

  /// 按手机形态测：常驻返回钮、手机控制行只在 Android/iOS 下渲染。
  /// 必须在测试体末尾复位（_verifyInvariants 在测试体返回后立即跑，
  /// tearDown/addTearDown 都赶不上）。
  void useAndroidPlatform() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  }

  void resetPlatform() {
    debugDefaultTargetPlatformOverride = null;
  }

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

  /// 点播放器控制层的按钮：控制层隐藏时按钮在树里但不可点（IgnorePointer
  /// 包裹，tap 会静默落空），先点一次手势面把控制层唤出来再点。
  /// 唤出后等 400ms：滑动手势开着时点按要过双击超时才认作单击。
  Future<void> tapPlayerControl(WidgetTester tester, Finder finder) async {
    if (finder.hitTestable().evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.tap(finder.first);
    await settleOperations(tester);
  }

  /// 等播放器就绪（加载遮罩消失）：_play 是异步链，播起来之前
  /// 遮罩盖住控制层，点不到。有界等待，超时后由后续断言说话。
  Future<void> waitForPlayerReady(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      final veil = find.descendant(
        of: find.byType(PlayerScreen),
        matching: find.byType(CircularProgressIndicator),
      );
      if (veil.evaluate().isEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('detail play stays inline, switches episodes, closes to detail', (
    tester,
  ) async {
    useAndroidPlatform();
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
    // 未开播时顶栏返回箭头正常画出。
    expect(
      tester.widget<AppBar>(find.byType(AppBar)).automaticallyImplyLeading,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('detail-poster-play')));
    await settleOperations(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await waitForPlayerReady(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(repository.requestedEpisodes, [1]);
    // 外置条已拿掉：详情页不再渲染“正在播放”条与条上的两个键。
    expect(find.text('正在播放 · 第 1 集'), findsNothing);
    expect(find.text('选集 · 2 集'), findsOneWidget);
    expect(find.byKey(const ValueKey('close-embedded-player')), findsNothing);
    expect(
      find.byKey(const ValueKey('toggle-embedded-fullscreen')),
      findsNothing,
    );
    // 内嵌打开时顶栏不再画返回箭头，只留播放器左上角常驻返回钮。
    expect(
      tester.widget<AppBar>(find.byType(AppBar)).automaticallyImplyLeading,
      isFalse,
    );
    expect(find.byKey(const ValueKey('player-permanent-back')), findsOneWidget);

    // 全屏改走播放器内控制层：点控制层的“全屏”进全屏，全屏分支无 AppBar。
    await tapPlayerControl(
      tester,
      find.descendant(
        of: find.byType(PlayerScreen),
        matching: find.byTooltip('全屏'),
      ),
    );
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(created, hasLength(1));
    await tapPlayerControl(
      tester,
      find.descendant(
        of: find.byType(PlayerScreen),
        matching: find.byTooltip('退出全屏'),
      ),
    );
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    expect(created, hasLength(1));

    await tester.tap(find.text('选集 · 2 集'));
    await settleOperations(tester);
    await tester.tap(find.byKey(const ValueKey('episode-2')));
    await settleOperations(tester);
    await settleDispose(tester);
    expect(repository.requestedEpisodes, [1, 2]);
    expect(created, hasLength(2));
    expect(repository.active, {'route-2'});
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.text('正在播放 · 第 2 集'), findsNothing);

    // 关闭改走播放器左上角常驻返回钮：回海报，顶栏返回箭头恢复。
    await tester.tap(find.byKey(const ValueKey('player-permanent-back')));
    await settleOperations(tester);
    await settleDispose(tester);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(repository.active, isEmpty);
    expect(find.byKey(const ValueKey('detail-poster-play')), findsOneWidget);
    expect(find.text('选集 · 2 集'), findsOneWidget);
    expect(
      tester.widget<AppBar>(find.byType(AppBar)).automaticallyImplyLeading,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    resetPlatform();
  });

  testWidgets('poster stays tappable while a reload is in flight', (
    tester,
  ) async {
    useAndroidPlatform();
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
    expect(find.text('正在播放 · 第 1 集'), findsNothing);

    // 放行挂起的加载，干净收尾（有界 pump，播放器场景不用 pumpAndSettle）。
    pending.complete(await FixtureRepository().detail(FixtureRepository.free));
    await settleDispose(tester);
    expect(tester.takeException(), isNull);
    resetPlatform();
  });

  testWidgets('embedded player stays pinned while scrolling, without rebuild', (
    tester,
  ) async {
    useAndroidPlatform();
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
    await tester.tap(find.byKey(const ValueKey('detail-poster-play')));
    await settleOperations(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await waitForPlayerReady(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(created, hasLength(1));
    expect(repository.requestedEpisodes, [1]);

    // 展开选集，让滚动内容超出视口、滑得动。
    await tester.tap(find.text('选集 · 2 集'));
    await settleOperations(tester);

    // 详情页主滚动视图：用固定头区下滚动区的键定位，不与播放器
    // 内部的滚动视图撞上；取最外层 Scrollable（推荐区 GridView 在
    // 视口内还有自己的 Scrollable，descendant 会一并命中）。
    Finder detailScrollable() => find
        .descendant(
          of: find
              .descendant(
                of: find.byKey(const ValueKey('detail-scroll-area')),
                matching: find.byType(CustomScrollView),
              )
              .first,
          matching: find.byType(Scrollable),
        )
        .first;
    double scrollPixels() =>
        tester.state<ScrollableState>(detailScrollable()).position.pixels;

    final playerElement = tester.element(find.byType(PlayerScreen));
    final playerTop = tester.getTopLeft(find.byType(PlayerScreen)).dy;
    expect(scrollPixels(), 0);

    // 往上滑到底：内容要动，播放器位置不能动。
    for (var i = 0; i < 6; i++) {
      await tester.drag(detailScrollable(), const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settleOperations(tester);
    expect(scrollPixels(), greaterThan(0));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(tester.getTopLeft(find.byType(PlayerScreen)).dy, playerTop);
    // 同一个 Element、同一个底层播放器、没有重新解析：没重建、没重播。
    expect(tester.element(find.byType(PlayerScreen)), same(playerElement));
    expect(created, hasLength(1));
    expect(created.single.disposed, isFalse);
    expect(repository.requestedEpisodes, [1]);
    // 滑到底后播放器仍可点（常驻返回钮在视口内、可命中）。
    expect(
      find.byKey(const ValueKey('player-permanent-back')).hitTestable(),
      findsOneWidget,
    );

    // 滑回去：播放器位置仍不变。
    for (var i = 0; i < 6; i++) {
      await tester.drag(detailScrollable(), const Offset(0, 400));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settleOperations(tester);
    expect(tester.getTopLeft(find.byType(PlayerScreen)).dy, playerTop);
    expect(tester.element(find.byType(PlayerScreen)), same(playerElement));
    expect(created, hasLength(1));

    // 关播：关闭回详情语义不受固定头区影响。
    await tester.tap(find.byKey(const ValueKey('player-permanent-back')));
    await settleOperations(tester);
    await settleDispose(tester);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.byKey(const ValueKey('detail-poster-play')), findsOneWidget);
    expect(tester.takeException(), isNull);
    resetPlatform();
  });
}
