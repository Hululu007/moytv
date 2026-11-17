import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_home_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late HaikuoStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('haikuo-page-');
    store = HaikuoStore(rootOverride: temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: HaikuoHomePage(store: store)));
    // 页面首帧是加载圈，这里让真实的文件 IO 跑完再逐帧推进。
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('图标链：自带图标走网络图，无图标走 favicon，都无走字形', (tester) async {
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '有图标',
            'type': 'video',
            'url': 'hiker://empty##https://example.com',
            'icon': 'https://example.com/icon.png',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
          {
            'title': '无图标有站',
            'type': 'video',
            'url': 'hiker://empty##https://example.com',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
          {
            'title': '无图标无站',
            'type': 'video',
            'url': 'hiker://empty##fypage',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
        ]),
        origin: '测试',
      ),
    );
    await pumpPage(tester);
    expect(find.text('有图标'), findsOneWidget);
    expect(find.text('无图标有站'), findsOneWidget);
    expect(find.text('无图标无站'), findsOneWidget);
    // 前两张瓦片挂 Image（自带图标 / 站点 favicon；测试里请求
    // 失败走 errorBuilder 回字形，但 Image 部件本身在树里）；
    // 第三张无任何图标来源，只有字形、不挂 Image。
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('data: 图标解出内存图', (tester) async {
    const tinyPngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '内嵌图标',
            'type': 'video',
            'url': 'hiker://empty##fypage',
            'icon': 'data:image/png;base64,$tinyPngBase64',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
        ]),
        origin: '测试',
      ),
    );
    await pumpPage(tester);
    expect(find.text('内嵌图标'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('空库时给出三种导入入口，不报错', (tester) async {
    await pumpPage(tester);
    expect(find.text('还没有导入海阔小程序'), findsOneWidget);
    expect(find.text('导入 JSON 文件'), findsWidgets);
    expect(find.text('口令导入'), findsWidgets);
    expect(find.text('导入内置示例'), findsOneWidget);
  });

  testWidgets('已导入的小程序显示名称与类型', (tester) async {
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '测试海阔源',
            'type': 'video',
            'url': 'hiker://empty##https://example.com',
            'col_type': 'movie_3',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
        ]),
        origin: '测试',
      ),
    );
    await pumpPage(tester);
    expect(find.text('测试海阔源'), findsOneWidget);
    expect(find.textContaining('规则'), findsWidgets);
  });

  testWidgets('长按弹出官方操作表，点分享规则出分享弹窗', (tester) async {
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '详情源',
            'url': 'hiker://empty##https://example.com',
            'find_rule': 'js:\nsetResult([]);',
          },
        ]),
        origin: '口令',
      ),
    );
    await pumpPage(tester);
    await tester.longPress(find.text('详情源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('请选择操作'), findsOneWidget);
    await tester.tap(find.text('分享规则'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('分享「详情源」'), findsOneWidget);
    expect(find.text('复制口令'), findsOneWidget);
  });

  testWidgets('已导入的规则以网格平铺，长按菜单含九项操作、无角标按钮', (tester) async {
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '测试海阔源',
            'type': 'video',
            'url': 'hiker://empty##https://example.com',
            'col_type': 'movie_3',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
        ]),
        origin: '测试',
      ),
    );
    await pumpPage(tester);
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('测试海阔源'), findsOneWidget);
    expect(find.textContaining('规则'), findsWidgets);
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    await tester.longPress(find.text('测试海阔源'));
    await tester.pumpAndSettle();
    expect(find.text('请选择操作'), findsOneWidget);
    expect(find.text('编辑规则'), findsOneWidget);
    expect(find.text('搜索内容'), findsOneWidget);
    expect(find.text('分享规则'), findsOneWidget);
    expect(find.text('更多分享'), findsOneWidget);
    expect(find.text('网站首页'), findsOneWidget);
    expect(find.text('删除规则'), findsOneWidget);
    expect(find.text('清除缓存'), findsOneWidget);
    expect(find.text('Web编辑'), findsOneWidget);
    expect(find.text('重生恢复'), findsOneWidget);
    expect(find.text('打开'), findsNothing);
    expect(find.text('详情'), findsNothing);
  });

  Future<HaikuoDuplicateDecision?> pumpDuplicateDialog(
    WidgetTester tester,
    String choice,
  ) async {
    HaikuoDuplicateDecision? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showHaikuoDuplicateDialog(context, [
                  HaikuoDuplicate(
                    incoming: const HaikuoProgram(id: 'new', name: '同名站'),
                    existing: const HaikuoProgram(id: 'old', name: '同名站'),
                  ),
                ]);
              },
              child: const Text('问'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('问'));
    await tester.pumpAndSettle();
    expect(find.text('发现同名站点'), findsOneWidget);
    expect(find.textContaining('同名站'), findsWidgets);
    expect(find.textContaining('同名站_2'), findsOneWidget);
    if (choice == 'dismiss') {
      await tester.tapAt(const Offset(10, 10));
    } else {
      await tester.tap(find.text(choice));
    }
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('重复提示：选替换返回 replace', (tester) async {
    expect(
      await pumpDuplicateDialog(tester, '替换'),
      HaikuoDuplicateDecision.replace,
    );
  });

  testWidgets('重复提示：选保留两者返回 keepBoth', (tester) async {
    expect(
      await pumpDuplicateDialog(tester, '保留两者'),
      HaikuoDuplicateDecision.keepBoth,
    );
  });

  testWidgets('重复提示：选取消返回 cancel', (tester) async {
    expect(
      await pumpDuplicateDialog(tester, '取消'),
      HaikuoDuplicateDecision.cancel,
    );
  });

  testWidgets('重复提示：点遮罩关掉也算取消', (tester) async {
    expect(
      await pumpDuplicateDialog(tester, 'dismiss'),
      HaikuoDuplicateDecision.cancel,
    );
  });
}
