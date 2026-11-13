import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_clipboard.dart';
import 'package:moyi/miniapp/haikuo/haikuo_home_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

Map<String, dynamic> _rule({String title = '测试规则'}) => {
  'title': title,
  'author': '作者',
  'type': 'video',
  'url': 'hiker://empty##https://example.com/list',
  'col_type': 'movie_3',
  'find_rule': 'js:\nsetResult([]);',
  'searchFind': '',
};

String _shareCode(String title) {
  final payload = base64Encode(utf8.encode(jsonEncode(_rule(title: title))));
  return '海阔视界规则分享，当前分享的是：小程序￥home_rule￥$payload￥';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late HaikuoStore store;
  late InMemoryHaikuoClipboardSeenStore seen;

  /// 模拟剪贴板内容：widget 测试里没有真实剪贴板，`Clipboard.getData`
  /// 不装 mock 处理器会一直等不到引擎回包（测试挂死），所以这里
  /// 在平台通道上装一个内存 mock，页面读到的就是这个变量。
  String? mockClipboardText;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('haikuo-clipboard-');
    store = HaikuoStore(rootOverride: temp);
    seen = InMemoryHaikuoClipboardSeenStore();
    mockClipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.getData':
              final text = mockClipboardText;
              if (text == null) return null;
              return <String, dynamic>{'text': text};
            case 'Clipboard.setData':
              final args = call.arguments;
              if (args is Map) {
                mockClipboardText = args['text'] as String?;
              }
              return null;
            case 'Clipboard.hasStrings':
              return <String, dynamic>{
                'value':
                    mockClipboardText != null &&
                    mockClipboardText!.isNotEmpty,
              };
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> settleFrames(WidgetTester tester, {int rounds = 24}) async {
    // pump 必须带时长推进假时钟，否则对话框/底部列表的进场动画
    // 永远停在第 0 帧（底部列表整体在屏幕下方，点按会落空）；
    // runAsync 让真实文件 IO 在每帧之间推进。
    // 导入链是“弹窗关闭 → 解析 → 写盘 → 重读”多轮真实 IO，
    // 每轮都要一次 runAsync + pump 交替推进，8 轮不够收敛。
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: HaikuoHomePage(store: store, clipboardSeenStore: seen),
      ),
    );
    await settleFrames(tester);
  }

  testWidgets('剪贴板有 1 个口令：打开海阔页弹温馨提示，点立即导入能导进去', (
    tester,
  ) async {
    mockClipboardText = _shareCode('甲规则');
    await pumpPage(tester);

    expect(find.text('温馨提示'), findsOneWidget);
    expect(find.text('剪贴板检测到小程序规则，是否立即导入？'), findsOneWidget);
    await tester.tap(find.text('立即导入'));
    await settleFrames(tester);

    expect(find.text('甲规则'), findsOneWidget);
    expect(find.text('温馨提示'), findsNothing);
  });

  testWidgets('剪贴板有多个口令：弹底部列表，点全部导入逐个导进去', (
    tester,
  ) async {
    mockClipboardText = '${_shareCode('甲规则')}\n${_shareCode('乙规则')}';
    await pumpPage(tester);

    expect(find.text('从剪贴板检测到多个导入口令'), findsOneWidget);
    expect(find.text('甲规则'), findsOneWidget);
    expect(find.text('乙规则'), findsOneWidget);
    await tester.tap(find.text('全部导入'));
    await settleFrames(tester, rounds: 48);

    expect(find.text('甲规则'), findsOneWidget);
    expect(find.text('乙规则'), findsOneWidget);
    expect(find.text('从剪贴板检测到多个导入口令'), findsNothing);
  });

  testWidgets('底部列表点其中一项只导那一项', (tester) async {
    mockClipboardText = '${_shareCode('甲规则')}\n${_shareCode('乙规则')}';
    await pumpPage(tester);

    await tester.tap(find.text('乙规则'));
    await settleFrames(tester);

    expect(find.text('乙规则'), findsOneWidget);
    expect(find.text('甲规则'), findsNothing);
  });

  testWidgets('点了取消不导入，且同一内容重进页面不再弹', (tester) async {
    mockClipboardText = _shareCode('甲规则');
    await pumpPage(tester);
    expect(find.text('温馨提示'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await settleFrames(tester);
    expect(find.text('甲规则'), findsNothing);

    // 模拟退出重进：先换一个无关页面销毁状态，再重新打开海阔页。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await pumpPage(tester);
    expect(find.text('温馨提示'), findsNothing);
    expect(find.text('还没有导入海阔小程序'), findsOneWidget);
  });

  testWidgets('剪贴板是普通文本时静默，什么都不弹', (tester) async {
    mockClipboardText = '今晚吃什么？火锅还是烧烤';
    await pumpPage(tester);
    expect(find.text('温馨提示'), findsNothing);
    expect(find.text('从剪贴板检测到多个导入口令'), findsNothing);
    expect(find.text('还没有导入海阔小程序'), findsOneWidget);
  });

  testWidgets('剪贴板为空时静默', (tester) async {
    mockClipboardText = null;
    await pumpPage(tester);
    expect(find.text('温馨提示'), findsNothing);
    expect(find.text('还没有导入海阔小程序'), findsOneWidget);
  });

  testWidgets('新复制了不同口令后回到前台，会再弹一次', (tester) async {
    mockClipboardText = _shareCode('甲规则');
    await pumpPage(tester);
    expect(find.text('温馨提示'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settleFrames(tester);

    mockClipboardText = _shareCode('乙规则');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleFrames(tester);

    expect(find.text('温馨提示'), findsOneWidget);
    await tester.tap(find.text('立即导入'));
    await settleFrames(tester);
    expect(find.text('乙规则'), findsOneWidget);
  });

  testWidgets('回到前台时剪贴板内容没变，不重弹', (tester) async {
    mockClipboardText = _shareCode('甲规则');
    await pumpPage(tester);
    expect(find.text('温馨提示'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settleFrames(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleFrames(tester);
    expect(find.text('温馨提示'), findsNothing);
  });
}
