// 听读合并预览截图：只做测试内截图，不改业务代码。
// 图 1：Win7 桌面，听书/阅读已并成一个“听读”图标（第二位）。
// 图 2：点听读图标开窗口、切到阅读子区，一级分类胶囊（听书/阅读）
// 与阅读区屏；区内无真实数据，显示加载/空态（非正式数据）。
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

const _previewDir = '/home/hatch/workspace/moyi_previews';

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
  required Future<void> Function(WidgetTester tester) action,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'source': 'huangdou',
    'hiddenSites': '[]',
    'appThemeMode': AppThemeMode.win7.storageValue,
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
        theme: _previewTheme(AppThemeMode.win7),
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

  testWidgets('preview listenread desktop', (tester) async {
    await _capture(
      tester,
      name: 'listenread_desktop',
      label: '听读合并 · Win7 桌面：听书/阅读已并成一个“听读”图标',
      action: (_) async {},
    );
  });

  testWidgets('preview listenread reading zone', (tester) async {
    await _capture(
      tester,
      name: 'listenread_reading_zone',
      label: '听读合并 · 阅读区：一级分类胶囊（听书/阅读）+ 本站二级分类',
      action: (tester) async {
        await tester.tap(
          find.byKey(const ValueKey('win7-desktop-icon-listenRead')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('listenread-novel')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      },
    );
  });
}
