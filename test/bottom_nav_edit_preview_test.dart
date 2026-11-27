// 底部导航可编辑 + Windows 桌面图标编辑（用户 2026-11-27 令）预览
// 截图：只做测试内截图，不改业务代码。一测一张：调过 toImage 的
// 测试在收尾时会挂起（旧预览测试同样如此，PNG 已落地），逐个单跑、
// 超时杀掉只取 PNG，不要把多张放进同一个测试体连跑。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/bottom_nav_manager_page.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_bottomnav_edit_20261127/preview';

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

Future<void> _shoot(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
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

Widget _framed(GlobalKey key, String label, Widget child) {
  return RepaintBoundary(
    key: key,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _previewTheme(AppThemeMode.lightClean),
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
              Expanded(child: child),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<GlobalKey> _pumpHome(
  WidgetTester tester, {
  Map<String, Object> extraSeeds = const {},
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'source': 'huangdou',
    'hiddenSites': '[]',
    'appThemeMode': 'lightClean',
    ...extraSeeds,
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
        theme: _previewTheme(AppThemeMode.lightClean),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: HomeScreen(repository: FixtureRepository(), store: store),
        ),
      ),
    ),
  );
  await _settle(tester);
  return key;
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

  testWidgets('preview nav default', (tester) async {
    final key = await _pumpHome(tester);
    await _shoot(tester, key, 'nav_default');
  });

  testWidgets('preview nav editing', (tester) async {
    final key = await _pumpHome(tester);
    await tester.longPress(find.byKey(const ValueKey('shell-tab-0')));
    await _settle(tester);
    await _shoot(tester, key, 'nav_editing');
  });

  testWidgets('preview nav dragging', (tester) async {
    final key = await _pumpHome(tester);
    await tester.longPress(find.byKey(const ValueKey('shell-tab-0')));
    await _settle(tester);
    final start = tester.getCenter(find.byKey(const ValueKey('shell-tab-1')));
    final end = tester.getCenter(find.byKey(const ValueKey('shell-tab-3')));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 100));
    await _shoot(tester, key, 'nav_dragging');
    await gesture.up();
  });

  testWidgets('preview nav reduced', (tester) async {
    final key = await _pumpHome(
      tester,
      extraSeeds: const {'bottomNavHiddenV1': 'live,listen,pan,miniapp,game'},
    );
    await _shoot(tester, key, 'nav_reduced');
  });

  testWidgets('preview nav manager', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'bottomNavHiddenV1': 'game,live',
    });
    final prefs = await SharedPreferences.getInstance();
    final key = GlobalKey();
    await tester.pumpWidget(
      _framed(
        key,
        '预览 · 设置 → 底部导航管理（已隐藏池：直播、游戏区，可逐个恢复/一键重置）',
        BottomNavManagerPage(preferences: prefs),
      ),
    );
    await _settle(tester);
    await _shoot(tester, key, 'nav_manager');
  });

  testWidgets('preview desktop editing', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final key = GlobalKey();
    await tester.pumpWidget(
      _framed(key, '预览 · Win7 桌面编辑态（长按进编辑，右上角完成钮，末列空格子可落位）',
          Win7Desktop(onIconTap: (_) {})),
    );
    await _settle(tester);
    await tester.longPress(
      find.byKey(const ValueKey('win7-desktop-icon-game')),
    );
    await _settle(tester);
    await _shoot(tester, key, 'desktop_editing');
  });

  testWidgets('preview desktop swapped', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final key = GlobalKey();
    await tester.pumpWidget(
      _framed(key, '预览 · Win7 桌面互换后（红警2 与 听读 互换格子，已点完成退出编辑态）',
          Win7Desktop(onIconTap: (_) {})),
    );
    await _settle(tester);
    await tester.longPress(
      find.byKey(const ValueKey('win7-desktop-icon-game')),
    );
    await _settle(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('win7-desktop-icon-game'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('win7-desktop-icon-listenRead')),
      ),
    );
    await tester.pump();
    await gesture.up();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('win7-desktop-edit-done')));
    await _settle(tester);
    await _shoot(tester, key, 'desktop_swapped');
  });
}
