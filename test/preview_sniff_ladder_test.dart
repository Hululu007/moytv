// 壳级嗅探兜底预览图：主播放器取流失败自动落嗅探的两态。
// 一为嗅探中（内嵌嗅探盖住播放区，左上角只有 X 可关）；二为
// 嗅探超时收口（错误屏「暂时无法播放 · 站源问题」，原始错误
// 里写明「无法获取播放链接」）。假数据说明：剧名/集数均为
// 测试内合成的演示数据；测试环境没有 WebView，嗅探区渲染的
// 是占位文本，真机上是目标网页的加载画面。一测一张：调过
// toImage 的测试收尾会挂起（PNG 已落地），跑单测、超时杀掉
// 只取 PNG。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_miniapp_sniff_20261126/preview';

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

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 10));
    } catch (_) {}
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory(_previewDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(data!.buffer.asUint8List());
}

void main() {
  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    try {
      final bytes = File(
        '/home/hatch/workspace/tools/flutter-3.50.0/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  Future<GlobalKey> mountPlayer(WidgetTester tester, String caption) async {
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
    const main = Drama(
      id: 'main-1',
      source: 'pektino',
      title: '嗅探兜底预览剧',
      description: '用于嗅探兜底预览的演示简介文字。',
      episodes: 3,
      category: '短剧',
    );
    final detail = DramaDetail(main, [
      for (var i = 1; i <= 3; i++)
        Episode({'id': '$i', 'title': '第$i集', 'currentEpisode': i}, i),
    ]);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          home: Column(
            children: [
              Container(
                width: double.infinity,
                color: Colors.black87,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Text(
                  caption,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontFamily: 'PreviewCJK',
                  ),
                ),
              ),
              Expanded(
                child: PlayerScreen(
                  detail: detail,
                  initialIndex: 0,
                  repository: NeedsParseRepository(),
                  store: store,
                  playerFactory: () => Player(platformPlayer: platform),
                  videoBuilder: (controls) => controls,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await _settle(tester);
    if (find.text('网页内嵌播放').evaluate().isNotEmpty) {
      await tester.tap(find.text('网页内嵌播放'));
      await _settle(tester);
    }
    return key;
  }

  testWidgets('sniff ladder preview - sniffing', (tester) async {
    final key = await mountPlayer(
      tester,
      '预览·演示数据：取流失败自动落嗅探（嗅探中；测试环境无 WebView，真机为网页加载画面）',
    );
    expect(find.text('当前平台不支持网页内嵌播放'), findsOneWidget);
    await _capture(tester, key, 'sniff_ladder_sniffing.png');
  });

  testWidgets('sniff ladder preview - failed', (tester) async {
    final key = await mountPlayer(
      tester,
      '预览·演示数据：嗅探超时收口（无法获取播放链接）',
    );
    expect(find.text('当前平台不支持网页内嵌播放'), findsOneWidget);
    await tester.pump(const Duration(seconds: 46));
    await _settle(tester);
    expect(find.text('暂时无法播放 · 站源问题'), findsOneWidget);
    await _capture(tester, key, 'sniff_ladder_failed.png');
  });
}
