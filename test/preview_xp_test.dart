import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/ui_style.dart';
import 'package:moyi/xp_boot_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewThemeFor(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _capturePng(
  WidgetTester tester, {
  required String name,
  required Widget app,
  Future<void> Function(WidgetTester tester)? setup,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: app,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
  if (setup != null) {
    await setup(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
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
  print('preview landed: $name');
}

Future<LocalStore> _previewStore() async {
  SharedPreferences.setMockInitialValues({
    'source': 'huangdou',
    'hiddenSites': '[]',
    'appThemeMode': 'xpWindows',
  });
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Widget _xpHome(LocalStore store) => MaterialApp(
  debugShowCheckedModeBanner: false,
  navigatorObservers: [homeRouteObserver],
  theme: _previewThemeFor(AppThemeMode.xpWindows),
  home: DefaultTextStyle(
    style: const TextStyle(fontFamily: 'PreviewCJK'),
    child: HomeScreen(repository: FixtureRepository(), store: store),
  ),
);

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

  // 注意：调过 toImage 的测试在收尾时会挂起（PNG 已落地）。一测一张、
  // 超时杀掉只取 PNG；不要把两张放进同一个测试体。
  testWidgets('预览 XP 桌面', (tester) async {
    appThemeNotifier.value = AppThemeMode.xpWindows;
    final store = await _previewStore();
    await _capturePng(tester, name: 'xp_desktop', app: _xpHome(store));
  });

  testWidgets('预览 XP 片库窗口', (tester) async {
    appThemeNotifier.value = AppThemeMode.xpWindows;
    final store = await _previewStore();
    await _capturePng(
      tester,
      name: 'xp_window',
      app: _xpHome(store),
      setup: (tester) async {
        await tester.tap(
          find.byKey(const ValueKey('xp-desktop-icon-library')),
        );
      },
    );
  });

  testWidgets('预览 XP 启动屏', (tester) async {
    // 直泵启动屏部件（MoyiApp 接线由 xp_boot_test 覆盖）：带预览
    // 中文字体；推到加载条半周期、段块居中时截图。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewThemeFor(AppThemeMode.win7),
          home: const DefaultTextStyle(
            style: TextStyle(fontFamily: 'PreviewCJK'),
            child: XpBootScreen(appName: '魔蚁box'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/xp_boot.png').writeAsBytesSync(bytes);
    print('preview landed: xp_boot');
  });
}
