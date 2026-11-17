import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/app_orientation.dart';
import 'package:moyi/hongguo_playback_page.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const _portrait = [
  'DeviceOrientation.portraitUp',
  'DeviceOrientation.portraitDown',
];
const _landscape = [
  'DeviceOrientation.landscapeLeft',
  'DeviceOrientation.landscapeRight',
];
const _all = [
  'DeviceOrientation.portraitUp',
  'DeviceOrientation.landscapeLeft',
  'DeviceOrientation.portraitDown',
  'DeviceOrientation.landscapeRight',
];

/// 回环地址取流：shouldPreResolveRedirects 对回环地址不做 302 预解析，
/// _play 不会卡在 widget 环境里跑不通的真实 HTTP 上。
class _LoopbackRepository extends FixtureRepository {
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async => const PlaybackPlan(url: 'http://127.0.0.1:9/synthetic.mp4');
}

void main() {
  /// 方向通道捕获（照 haikuo_inline_player_test 的既定写法）：平台改
  /// android、桩上 moyi/device（方向控制器先调它）、用 JSON 编解码
  /// 桩 flutter/platform 抓 SystemChrome.setPreferredOrientations。
  List<List<String>> captureOrientations() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final orientationCalls = <List<String>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('moyi/device'),
      (call) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('moyi/device'),
        null,
      ),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter/platform', JSONMethodCodec()),
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationCalls.add(
            List<String>.from(call.arguments as List<dynamic>),
          );
        }
        return null;
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('flutter/platform', JSONMethodCodec()),
        null,
      ),
    );
    return orientationCalls;
  }

  /// 有界推进：播放器里有周期定时器，绝不用 pumpAndSettle。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> waitForLast(
    WidgetTester tester,
    List<List<String>> calls,
    List<String> expected,
  ) async {
    for (var i = 0; i < 40; i++) {
      if (calls.isNotEmpty && listEquals(calls.last, expected)) return;
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<LocalStore> freshStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<void> pumpEmbedded(
    WidgetTester tester, {
    required bool embeddedFullscreen,
    required FixtureRepository repository,
    required DramaDetail detail,
    required LocalStore store,
    required ScriptedPlayer platform,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppOrientationScope(
          television: false,
          child: Scaffold(
            body: PlayerScreen(
              detail: detail,
              initialIndex: 0,
              repository: repository,
              store: store,
              embedded: true,
              embeddedFullscreen: embeddedFullscreen,
              playerFactory: () => Player(platformPlayer: platform),
              videoBuilder: (controls) => controls,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  void resetPlatformOverride() {
    // debug 变量须在测试体内复位：框架在 tearDown 之前就做不变式检查。
    debugDefaultTargetPlatformOverride = null;
  }

  /// 退场前先拆树、再把假时钟推过 2 秒：PlayerScreen.dispose 里有
  /// 个 1 秒超时守卫（_operations.timeout），树若等到框架收尾时才
  /// 拆，超时定时器还挂着，收尾不变式检查会报 timersPending。
  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('内嵌全屏翻转：宽素材锁横屏、退出复位', (tester) async {
    final orientationCalls = captureOrientations();
    final store = await freshStore();
    final repository = _LoopbackRepository();
    final platform = ScriptedPlayer();
    final detail = await repository.detail(FixtureRepository.free);
    await pumpEmbedded(
      tester,
      embeddedFullscreen: false,
      repository: repository,
      detail: detail,
      store: store,
      platform: platform,
    );
    await waitForLast(tester, orientationCalls, _all);
    expect(orientationCalls, [_all]);

    // 宽素材先到：非全屏时方向不该动。
    platform.videoSize(320, 180);
    await settle(tester);
    expect(orientationCalls, [_all]);

    // 翻转进全屏：应锁横屏。
    await pumpEmbedded(
      tester,
      embeddedFullscreen: true,
      repository: repository,
      detail: detail,
      store: store,
      platform: platform,
    );
    await waitForLast(tester, orientationCalls, _landscape);
    expect(orientationCalls.last, _landscape);

    // 退出全屏：方向限制放开（全部方向）。
    await pumpEmbedded(
      tester,
      embeddedFullscreen: false,
      repository: repository,
      detail: detail,
      store: store,
      platform: platform,
    );
    await waitForLast(tester, orientationCalls, _all);
    expect(orientationCalls.last, _all);

    await tearDownTree(tester);
    resetPlatformOverride();
    expect(tester.takeException(), isNull);
  });

  testWidgets('内嵌首开即全屏：挂载即锁竖屏、宽高比到后跟横屏', (tester) async {
    final orientationCalls = captureOrientations();
    final store = await freshStore();
    final repository = _LoopbackRepository();
    final platform = ScriptedPlayer();
    final detail = await repository.detail(FixtureRepository.free);
    await pumpEmbedded(
      tester,
      embeddedFullscreen: true,
      repository: repository,
      detail: detail,
      store: store,
      platform: platform,
    );
    await waitForLast(tester, orientationCalls, _portrait);
    // 控制器会把初始化的方向应用与挂载同步合并，只认最终态：
    // 只要最后一次调用是竖屏锁即可，不钉死调用序列。
    expect(orientationCalls.last, _portrait);

    // 宽高比后到且越过 1.0 分界：全屏里的方向要跟着重锁。
    platform.videoSize(320, 180);
    await waitForLast(tester, orientationCalls, _landscape);
    expect(orientationCalls.last, _landscape);

    await tearDownTree(tester);
    resetPlatformOverride();
    expect(tester.takeException(), isNull);
  });

  testWidgets('内嵌默认竖屏素材：进全屏锁竖屏、退出复位', (tester) async {
    final orientationCalls = captureOrientations();
    final store = await freshStore();
    final repository = _LoopbackRepository();
    final platform = ScriptedPlayer();
    final detail = await repository.detail(FixtureRepository.free);
    await pumpEmbedded(
      tester,
      embeddedFullscreen: false,
      repository: repository,
      detail: detail,
      store: store,
      platform: platform,
    );
    await waitForLast(tester, orientationCalls, _all);
    orientationCalls.clear();

    await pumpEmbedded(
      tester,
      embeddedFullscreen: true,
      repository: repository,
      detail: detail,
      store: store,
      platform: platform,
    );
    await waitForLast(tester, orientationCalls, _portrait);
    expect(orientationCalls, [_portrait]);

    await pumpEmbedded(
      tester,
      embeddedFullscreen: false,
      repository: repository,
      detail: detail,
      store: store,
      platform: platform,
    );
    await waitForLast(tester, orientationCalls, _all);
    expect(orientationCalls.last, _all);

    await tearDownTree(tester);
    resetPlatformOverride();
    expect(tester.takeException(), isNull);
  });

  testWidgets('红果页：点全屏观看锁竖屏、点返回复位', (tester) async {
    final orientationCalls = captureOrientations();
    final store = await freshStore();
    final repository = FixtureRepository();
    final detail = await repository.detail(FixtureRepository.free);
    await tester.pumpWidget(
      MaterialApp(
        home: AppOrientationScope(
          television: false,
          child: HongguoPlaybackPage(
            drama: FixtureRepository.free,
            repository: repository,
            store: store,
            detail: detail,
          ),
        ),
      ),
    );
    await settle(tester);
    await waitForLast(tester, orientationCalls, _all);
    orientationCalls.clear();

    // 无视频尺寸时宽高比默认 9/16：全屏锁竖屏。
    await tester.tap(find.text('全屏观看'));
    await waitForLast(tester, orientationCalls, _portrait);
    expect(orientationCalls, [_portrait]);

    // 全屏布局里的返回键：先退全屏、方向复位。
    await tester.tap(find.byTooltip('返回'));
    await waitForLast(tester, orientationCalls, _all);
    expect(orientationCalls.last, _all);

    await tearDownTree(tester);
    resetPlatformOverride();
    expect(tester.takeException(), isNull);
  });
}
