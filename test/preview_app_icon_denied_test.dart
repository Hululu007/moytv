// 应用图标选择页“被拒态”预览截图：只做测试内截图，不改业务代码。
// 模拟鸿蒙 NEXT/卓易通桌面拒绝换图标后的页面：顶部横条 + “再试一次”按钮，点选停掉。
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
  testWidgets('应用图标选择页被拒态预览', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 拒绝记忆已置位：进页即显横条。
    SharedPreferences.setMockInitialValues({
      appIconSwitchDeniedKey: true,
    });
    const channel = MethodChannel('moyi/icon_switch');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'currentIcon') return 'default';
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
    File('/home/hatch/workspace/phone_feedback_20261119/preview/app_icon_picker_denied.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
