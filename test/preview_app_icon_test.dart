// 应用图标选择页预览截图：只做测试内截图，不改业务代码。
// 调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，PNG 已落地），
// 跑单测、超时杀掉只取 PNG。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_icon_picker_page.dart';
import 'package:moyi/app_icon_switcher.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('应用图标选择页预览', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('moyi/icon_switch');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'currentIcon') return 'ant_flame';
      return true;
    });
    final base = AppThemeConfig.forTheme(AppThemeMode.xpWindows).toThemeData();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
            primaryTextTheme:
                base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
          ),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: AppIconPickerPage(
              switcher: AppIconSwitcher(supportedOverride: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 预览图是大 PNG，解码走引擎异步回调，FakeAsync 里泵帧推不动，
    // 须在 runAsync 里用真实延时等解码完成再截图。
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('/home/hatch/workspace/moyi_previews/app_icon_picker_main.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
