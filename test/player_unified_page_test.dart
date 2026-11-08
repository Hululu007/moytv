import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

/// 播放页合一（FongMi 骨架）widget 测试：
/// 竖屏下选集/简介/相关三区存在且选集在简介之前；
/// 点当前集进全屏后三区全部不渲染。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DramaDetail buildDetail() {
    const peer = Drama(
      id: 'peer-1',
      source: 'pektino',
      title: '合一测试剧',
      episodes: 12,
    );
    const main = Drama(
      id: 'main-1',
      source: 'hongguo',
      title: '合一测试剧',
      description: '这是一段用于合一页测试的简介文字，会被默认折叠为三行显示。',
      episodes: 12,
      category: '短剧',
      peers: [peer],
    );
    return DramaDetail(
      main,
      [
        for (var i = 1; i <= 12; i++)
          Episode({'id': '$i', 'title': '第$i集', 'currentEpisode': i}, i),
      ],
      related: const [
        Drama(id: 'rel-1', source: 'hongguo', title: '相关剧一'),
        Drama(id: 'rel-2', source: 'hongguo', title: '相关剧二'),
      ],
    );
  }

  Future<ScriptedPlayer> mount(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    // 方向偏好设为横屏模式：竖屏下不自动全屏，合一页保持展开
    // （本机测试环境的假播放器不发宽高流，auto 模式会停在初始
    // 9/16 宽高比误判竖版全屏，故显式固定模式）。
    SharedPreferences.setMockInitialValues({
      'playback': '{"orientationMode":"landscape"}',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    final player = ScriptedPlayer();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: buildDetail(),
          initialIndex: 0,
          repository: RouteRepository(),
          store: store,
          playerFactory: () => Player(platformPlayer: player),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    return player;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugDefaultTargetPlatformOverride = null;
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('竖屏合一页：选集/简介/相关三区存在，选集在简介之前', (tester) async {
    await mount(tester);
    expect(find.byKey(const ValueKey('player-info-scroll')), findsOneWidget);
    expect(find.byKey(const ValueKey('episode-chip-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-synopsis')), findsOneWidget);
    // 集数 ≥10 出现「更多」
    expect(find.byKey(const ValueKey('episode-more')), findsOneWidget);
    expect(find.byKey(const ValueKey('episode-reverse')), findsOneWidget);
    // 铁律：选集在简介之前
    final chipY = tester
        .getTopLeft(find.byKey(const ValueKey('episode-chip-0')))
        .dy;
    final synY = tester
        .getTopLeft(find.byKey(const ValueKey('player-synopsis')))
        .dy;
    expect(chipY, lessThan(synY));
    // 相关区双轨：站内相关卡 + 同名跨站卡
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('player-related-rel-1')),
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.byKey(const ValueKey('player-related-rel-1')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-peer-card-peer-1')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('点其他集切播、再点当前集进全屏且信息区消失', (tester) async {
    final player = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('episode-chip-2')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(player.opened.length, greaterThanOrEqualTo(2));
    // 再点当前集（第3集）→ 全屏
    await tester.tap(find.byKey(const ValueKey('episode-chip-2')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.byKey(const ValueKey('player-info-scroll')), findsNothing);
    expect(find.byKey(const ValueKey('player-synopsis')), findsNothing);
    await unmount(tester);
  });
}
