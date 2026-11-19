// “我的”固定到底部栏最后一位（用户 2026-11-19 令）预览截图：只做测试内
// 截图，不改业务代码。图 1：默认主题（浅色清爽）下底部栏顺序
// 片库/直播/听读/[播放键]/网盘/小程序/演员库/游戏区/我的。
// 图 2：紫蓝霓虹主题下点“我的”（最后一位）选中态。
// 全部主题共用同一份 NeonCapsuleBar 定义（只换配色），Windows 主题
// （Win7/XP 桌面壳）不用这条底栏、走任务栏+开始菜单，故只出这两张。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/my_tab_last_20261119/preview';

ThemeData _previewTheme(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  TextStyle? cjk(TextStyle? style) => style?.copyWith(fontFamily: 'PreviewCJK');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjk(base.appBarTheme.titleTextStyle),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
  for (var i = 0; i < 10; i++) {
    try {
      if (tester.takeException() == null) break;
    } catch (_) {
      break;
    }
  }
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required AppThemeMode mode,
  required Future<void> Function(WidgetTester tester) action,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'source': 'huangdou',
    'hiddenSites': '[]',
    'appThemeMode': mode.storageValue,
  });
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorObservers: [homeRouteObserver],
        theme: _previewTheme(mode),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: Scaffold(
            body: Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Colors.black87,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontFamily: 'PreviewCJK',
                    ),
                  ),
                ),
                Expanded(
                  child: HomeScreen(
                    repository: FixtureRepository(),
                    store: store,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  await action(tester);
  await _settle(tester);
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name.png').writeAsBytesSync(bytes);
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
  });

  testWidgets('preview my tab last light', (tester) async {
    await _capture(
      tester,
      name: 'my_tab_last_light',
      label: '预览 · 默认主题 · 底部栏顺序：片库/直播/听读/网盘/小程序/演员库/游戏区/我的（我的在最后一位）',
      mode: AppThemeMode.lightClean,
      action: (tester) async {},
    );
  });

  testWidgets('preview my tab last neon selected', (tester) async {
    await _capture(
      tester,
      name: 'my_tab_last_neon_selected',
      label: '预览 · 紫蓝霓虹主题 · 点“我的”（最后一位）选中态',
      mode: AppThemeMode.purpleNeon,
      action: (tester) async {
        await tester.tap(find.byKey(const ValueKey('shell-tab-7')));
      },
    );
  });
}
