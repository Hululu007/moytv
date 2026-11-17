import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/boot_video.dart';
import 'package:moyi/xp_boot_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('测试环境播放器起不来时开机视频退成透明占位，不崩', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BootVideo())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(BootVideo), findsOneWidget);
    expect(find.byKey(const ValueKey('boot-video')), findsNothing);
    await tester.pumpWidget(Container());
    await tester.pump();
  });

  testWidgets('启动屏带视频层时回落透明，动画屏内容仍在', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: XpBootScreen(appName: '魔蚁box', video: BootVideo()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('xp-boot-app-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('xp-boot-xp-mark')), findsOneWidget);
    expect(find.byKey(const ValueKey('xp-boot-load-bar')), findsOneWidget);
    expect(find.text('正在启动…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('xp-boot-video-stack')),
      findsOneWidget,
    );
    await tester.pumpWidget(Container());
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('出错分支不显示视频层', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: XpBootScreen(
          appName: '魔蚁box',
          error: '初始化失败：测试错误',
          onRetry: () {},
          video: Container(key: const ValueKey('stub-video')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('stub-video')), findsNothing);
    expect(find.text('初始化失败：测试错误'), findsOneWidget);
    expect(find.text('重新打开'), findsOneWidget);
    await tester.pumpWidget(Container());
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('无视频层时启动屏没有 Stack 叠加', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: XpBootScreen(appName: '魔蚁box')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('xp-boot-video-stack')), findsNothing);
    await tester.pumpWidget(Container());
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  test('开机视频资源已打进包，字节数与源文件一致', () async {
    final data = await rootBundle.load(bootVideoAsset);
    expect(data.lengthInBytes, 106291);
  });
}
