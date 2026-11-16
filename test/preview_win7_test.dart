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

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required Future<void> Function(WidgetTester tester) setup,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  appThemeNotifier.value = AppThemeMode.win7;
  final key = GlobalKey();
  try {
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
      'appThemeMode': 'win7',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorObservers: [homeRouteObserver],
          theme: _previewThemeFor(AppThemeMode.win7),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: HomeScreen(
              repository: FixtureRepository(),
              store: store,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await setup(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
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
  } finally {
    appThemeNotifier.value = AppThemeMode.win7;
  }
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

  // 注意：调过 toImage 的测试在收尾时会挂起（PNG 已落地）。一测一张、
  // 超时杀掉只取 PNG；不要把两张放进同一个测试体。
  testWidgets('预览 Win7 桌面首页', (tester) async {
    await _capture(tester, name: 'win7_desktop', setup: (_) async {});
  });

  testWidgets('预览 Win7 片库窗口', (tester) async {
    await _capture(
      tester,
      name: 'win7_window',
      setup: (tester) async {
        await tester.tap(find.byKey(const ValueKey('win7-desktop-icon-library')));
      },
    );
  });

  testWidgets('预览 Win7 最小化后任务栏条目', (tester) async {
    await _capture(
      tester,
      name: 'win7_minimized',
      setup: (tester) async {
        await tester.tap(find.byKey(const ValueKey('win7-desktop-icon-library')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('win7-window-minimize')));
      },
    );
  });

  testWidgets('预览 Win7 开始菜单', (tester) async {
    await _capture(
      tester,
      name: 'win7_startmenu',
      setup: (tester) async {
        await tester.tap(find.byKey(const ValueKey('win7-start-button')));
      },
    );
  });
}
