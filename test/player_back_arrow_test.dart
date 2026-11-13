import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_controls.dart';
import 'package:moyi/player_interactions.dart';
import 'package:moyi/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

void main() {
  Future<void> settleOperations(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  DramaDetail buildDetail() {
    const peer = Drama(
      id: 'peer-1',
      source: 'pektino',
      title: '返回箭头测试剧',
      episodes: 12,
    );
    const main = Drama(
      id: 'main-1',
      source: 'hongguo',
      title: '返回箭头测试剧',
      description: '用于返回箭头测试的简介文字。',
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

  Future<ScriptedPlayer> mountPlayerScreen(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
    });
    // 方向偏好固定横屏模式：竖屏下不自动全屏，合一页保持展开。
    SharedPreferences.setMockInitialValues({
      'playback': '{"orientationMode":"landscape"}',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    final platform = ScriptedPlayer();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: buildDetail(),
          initialIndex: 0,
          repository: RouteRepository(),
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await settleOperations(tester);
    return platform;
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

  testWidgets('全屏控制层显示时左上角只有一个返回箭头', (tester) async {
    await mountPlayerScreen(tester);
    // 点其他集切播、再点当前集进全屏（与合一页测试同一流程）；
    // 信息区消失即已进全屏。
    await tester.ensureVisible(find.byKey(const ValueKey('episode-chip-2')));
    await settleOperations(tester);
    await tester.tap(find.byKey(const ValueKey('episode-chip-2')));
    await settleOperations(tester);
    await tester.tap(find.byKey(const ValueKey('episode-chip-2')));
    await settleOperations(tester);
    expect(find.byKey(const ValueKey('player-info-scroll')), findsNothing);
    // 全屏态控制层顶栏本应画“退出全屏”粗箭头，与常驻返回重叠；
    // 修后只留常驻返回（点按同样先退全屏），顶栏只留占位。
    // 注意：底部工具栏的全屏切换键在全屏时提示也是“退出全屏”，
    // 但图标是 fullscreen_exit 不是箭头，故只数箭头图标、不数该提示。
    expect(
      find.byKey(const ValueKey('player-permanent-back')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
    expect(find.byTooltip('返回'), findsOneWidget);
    // 点播后控制层 4 秒自动隐藏定时器起表，收尾前把假时钟推过它，
    // 否则拆树时框架会报 Timer 未清（合一页测试同一写法）。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await unmount(tester);
  });

  testWidgets('竖屏控制层显示时左上角只有一个返回箭头', (tester) async {
    await mountPlayerScreen(tester);
    // 控制层初始可见：常驻返回在，控制层顶栏的细箭头不能同时出现。
    expect(
      find.byKey(const ValueKey('player-permanent-back')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
    expect(find.byTooltip('返回'), findsOneWidget);
    await unmount(tester);
  });

  Future<void> mountControls(
    WidgetTester tester, {
    bool? showTopBarBackButton,
  }) async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1.0,
      onTogglePlayback: () {},
      onFullscreen: () {},
      onEpisode: (_) => '',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 225,
            child: PlayerControls(
              player: player,
              interactions: interactions,
              enabled: true,
              fullscreen: false,
              showOnPlaybackReady: true,
              onFullscreen: () {},
              onBack: () {},
              onPrevious: null,
              onNext: null,
              title: '测试剧 · 第 1 集',
              onTogglePlayback: () {},
              onEpisodes: () async {},
              onSpeed: () async {},
              onQuality: () async {},
              speed: 1,
              qualityLabel: '自动',
              onFocusSurface: () {},
              swipeEnabled: true,
              showTopBarBackButton: showTopBarBackButton ?? true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('控制层顶栏默认显示返回箭头', (tester) async {
    await mountControls(tester);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
  });

  testWidgets('控制层顶栏隐藏返回箭头时只留占位不画箭头', (tester) async {
    await mountControls(tester, showTopBarBackButton: false);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    expect(find.byTooltip('返回'), findsNothing);
    expect(find.byTooltip('退出全屏'), findsNothing);
  });
}
