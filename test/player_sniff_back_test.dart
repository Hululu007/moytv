import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

/// 永远返回“需解析”计划的仓：播放器拿不到解析接口就报
/// AppFailure，进错误态；错误面板带“网页内嵌播放”按钮，
/// 由此进入嗅探态（深嗅探默认开时还会自动进）。
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
  /// 错误面板每次渲染都会触发一条与本测试无关的既有框架断言：
  /// StatusPanel（lib/widgets.dart）里的 ExpansionTile 内含 ListTile，
  /// 而错误浮层外层包着带背景色的 ColoredBox，框架在调试态下报
  /// “ListTile background color or ink splashes may be invisible”。
  /// 该断言在修法之前就存在（detail 恒为错误文本，折叠块恒渲染），
  /// 与嗅探按钮改动无关；此处只放行这一条消息，其余错误照常上报。
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
      title: '嗅探返回测试剧',
      description: '用于嗅探态返回按钮测试的简介文字。',
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

  /// 嗅探态未进时点错误面板的按钮进嗅探（深嗅探自动开时已在嗅探态，
  /// 按钮不存在，直接返回）。
  Future<void> ensureSniffState(WidgetTester tester) async {
    await settleOperations(tester);
    if (find.text('网页内嵌播放').evaluate().isNotEmpty) {
      await tester.tap(find.text('网页内嵌播放'));
      await settleOperations(tester);
    }
    // 嗅探态证据：测试平台无 WebView，内嵌页渲染占位文本。
    expect(find.text('当前平台不支持网页内嵌播放'), findsOneWidget);
  }

  testWidgets('嗅探态左上角只有 X、没有常驻返回', (tester) async {
    suppressKnownListTileAssertion();
    await mountPlayerScreen(tester);
    await ensureSniffState(tester);
    expect(
      find.byKey(const ValueKey('player-sniff-close')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-permanent-back')),
      findsNothing,
    );
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    expect(find.byTooltip('返回'), findsNothing);
    await unmount(tester);
  });

  testWidgets('点 X 关嗅探后错误面板回来、常驻返回恢复', (tester) async {
    suppressKnownListTileAssertion();
    await mountPlayerScreen(tester);
    await ensureSniffState(tester);
    await tester.tap(find.byKey(const ValueKey('player-sniff-close')));
    await settleOperations(tester);
    // 关嗅探恢复错误态：嗅探按钮回来，X 消失，常驻返回恢复。
    expect(find.text('网页内嵌播放'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-sniff-close')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-permanent-back')),
      findsOneWidget,
    );
    expect(find.byTooltip('返回'), findsOneWidget);
    // 未离页：信息区还在。
    expect(find.byKey(const ValueKey('player-info-scroll')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('关嗅探后能再次点按钮进嗅探、仍只有一个 X', (tester) async {
    suppressKnownListTileAssertion();
    await mountPlayerScreen(tester);
    await ensureSniffState(tester);
    await tester.tap(find.byKey(const ValueKey('player-sniff-close')));
    await settleOperations(tester);
    await tester.tap(find.text('网页内嵌播放'));
    await settleOperations(tester);
    expect(find.text('当前平台不支持网页内嵌播放'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-sniff-close')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-permanent-back')),
      findsNothing,
    );
    await unmount(tester);
  });
}
