import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

/// 永远返回“需解析”计划的仓：无解析接口可用时取流失败，
/// 播放器自动落嗅探兜底（深嗅探默认开）。测试平台无 WebView，
/// 嗅探页永远嗅不到地址，正好验超时收口。
class NeedsParseRepository extends RouteRepository {
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async {
    primaryCalls++;
    return const PlaybackPlan(
      url: 'https://page.test/watch/123',
      session: 'needs-parse',
      needsParse: true,
    );
  }
}

void main() {
  void suppressKnownListTileAssertion() {
    final original = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (details
          .toString()
          .contains('ListTile background color or ink splashes')) {
        return;
      }
      original?.call(details);
    };
    addTearDown(() {
      FlutterError.onError = original;
    });
  }

  Future<void> settleOperations(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  DramaDetail buildDetail() {
    const main = Drama(
      id: 'main-1',
      source: 'pektino',
      title: '嗅探超时测试剧',
      description: '用于嗅探超时收口测试的简介文字。',
      episodes: 3,
      category: '短剧',
    );
    return DramaDetail(main, [
      for (var i = 1; i <= 3; i++)
        Episode({'id': '$i', 'title': '第$i集', 'currentEpisode': i}, i),
    ]);
  }

  Future<void> mountPlayerScreen(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
    });
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
          repository: NeedsParseRepository(),
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await settleOperations(tester);
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

  testWidgets('嗅探超时后关嗅探、留无法获取播放链接错误态', (tester) async {
    suppressKnownListTileAssertion();
    await mountPlayerScreen(tester);
    await settleOperations(tester);
    if (find.text('网页内嵌播放').evaluate().isNotEmpty) {
      await tester.tap(find.text('网页内嵌播放'));
      await settleOperations(tester);
    }
    // 已进嗅探态（测试平台无 WebView，内嵌页是占位文本）。
    expect(find.text('当前平台不支持网页内嵌播放'), findsOneWidget);
    // 推进过 45 秒嗅探时限：应自动关嗅探并如实报失败，
    // 不再无限挂在嗅探态。
    await tester.pump(const Duration(seconds: 46));
    await settleOperations(tester);
    expect(find.text('当前平台不支持网页内嵌播放'), findsNothing);
    // 错误屏回来：归类标题是站源问题，嗅探按钮恢复。
    expect(find.text('暂时无法播放 · 站源问题'), findsOneWidget);
    expect(find.text('网页内嵌播放'), findsOneWidget);
    // 展开「查看原始错误」能看到如实收口的原文。
    await tester.tap(find.text('查看原始错误'));
    await settleOperations(tester);
    expect(find.textContaining('无法获取播放链接'), findsWidgets);
    await unmount(tester);
  });
}
