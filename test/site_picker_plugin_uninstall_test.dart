// 片库站点列表：插件站长按卸载接线测试。
//
// 直接泵 HomeScreen（auto_load_retry_test.dart 的 pumpHome 模式），
// 不泵全应用 MoyiApp：全应用泵在本机测试环境会挂起（真异步 Future
// 令 pumpAndSettle 永不等到静止，10 分钟超时也跑不完），改手动 pump。
// 断言三件事同时成立——
// ① 弹窗里插件站消失、插件区变空；
// ② 安装索引里该插件消失（市场已安装列表读同一份索引，
//    下次打开即同步消失）；
// ③ 站点登记表里该站注销，片库可见站源里不再有它。
// 另断言内置站长按不给卸载入口：弹的是“隐藏内置站”，不是卸载。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/idj_plugin_store.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _pluginId = 'com.idj.ext.chengguo';
const _siteKey = 'idj_chengguo';

IdjPluginManifest _manifest() => IdjPluginManifest(
  id: _pluginId,
  name: '橙果短剧',
  version: '1.0.0',
  entry: 'main.js',
  type: 'video',
  adult: true,
  author: '测试',
  description: '接线测试用假插件',
  capabilities: const ['detail', 'play'],
  httpDomains: const [],
  mediaDomains: const [],
  cloudflare: false,
  storagePermission: false,
  loginPermission: false,
  minAppVersion: '',
  updateUrl: '',
  raw: const {},
);

/// 手动推进帧与假时钟：代替 pumpAndSettle（全应用真异步永不静止）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('插件站长按卸载：片库、索引、登记表一起消失', (tester) async {
    // 同步建临时目录：widget 测试里 await createTemp() 永不返回
    //（FakeAsync 下异步 dart:io 挂起），必须用同步 API。
    final tempDir = Directory.systemTemp.createTempSync('idj_uninstall_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    // path_provider 在测试里没有真实现：把应用目录指到临时目录，
    // 否则 IdjPluginStore().root / uninstall 拿不到目录。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getApplicationSupportDirectory') {
            return tempDir.path;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    // 安装索引里先记一条该插件（包文件故意不放：启动恢复会把它
    // 标损坏跳过，不拦启动、不反注册本站；uninstall 本身容忍
    // 包目录缺失，只清索引 + 注销登记）。
    SharedPreferences.setMockInitialValues({
      'source': 'missav',
      'hiddenSites': '[]',
      // 壳形态由存着的主题定，不钉主题默认进桌面壳、没有切换按钮
      //（auto_load_retry_test 同款钉法）。
      'appThemeMode': 'purpleNeon',
      idjPluginsPrefsKey: jsonEncode({
        _pluginId: {
          'name': '橙果短剧',
          'version': '1.0.0',
          'type': 'video',
          'adult': true,
          'enabled': true,
          'origin': 'import',
          'fileHash': 'test-hash',
          'siteKey': _siteKey,
          'installedAt': 1,
        },
      }),
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    // 测试环境默认 profile 不放行内置站：像 auto_load_retry_test 那样
    // 把一个内置站手动登记进 importedSites，否则片库只剩插件 1 站、
    // 切换按钮（需 2 站以上）不出现。红果不用登记：它本就在
    // SourceSite.values 里，profile 直接放行，再登记会重复出两行。
    SourceSite.importedSites['missav'] = const SourceSite(
      'missav',
      'MissAV',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    IdjPluginRegistry.registerPlugin(manifest: _manifest(), siteKey: _siteKey);
    addTearDown(() {
      SourceSite.importedSites.remove('missav');
      SourceSite.importedSites.remove(_siteKey);
      IdjPluginRegistry.onRegistryChanged = null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await _settle(tester);
    // 首屏初始加载是真异步：轮询等切换按钮出来（最多约 10 秒假时钟），
    // 不用 pumpAndSettle（永不等到静止）。
    for (
      var i = 0;
      i < 20 &&
          find.byKey(const ValueKey('source-switch')).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byKey(const ValueKey('source-switch')), findsWidgets);

    // 打开片库弹窗：三区签都在，插件区 1 站。
    await tester.tap(find.byKey(const ValueKey('source-switch')).first);
    await _settle(tester);
    expect(find.text('切换片库源'), findsOneWidget);
    expect(find.text('插件区（1）'), findsOneWidget);

    // 内置站长按：弹“隐藏内置站”，不是卸载；取消后站还在。
    await tester.longPress(
      find.byKey(const ValueKey('site-picker-row-hongguo')),
    );
    await _settle(tester);
    expect(find.text('隐藏内置站'), findsOneWidget);
    expect(find.text('卸载插件'), findsNothing);
    await tester.tap(find.text('取消'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('site-picker-row-hongguo')),
      findsOneWidget,
    );

    // 切到插件区，长按插件站卸载。
    await tester.tap(find.byKey(const ValueKey('site-picker-zone-plugin')));
    await _settle(tester);
    expect(find.text('橙果短剧'), findsOneWidget);
    // 长按开确认框 + 点卸载必须在同一个 runAsync 块里：卸载要做
    // 真实文件 IO（查包目录在不在），FakeAsync 下异步 dart:io
    // 永不返回；确认框在块外打开会让卸载续体落在 FakeAsync 区里
    // 静默不执行（行还在、无报错）。块里照常 pump。
    await tester.runAsync(() async {
      // tester.longPress 在 runAsync 里不认：它内部 pump 推不动
      // 真实计时器，手势没等到 500ms 就抬起、变成点选。手动发手势，
      // 用真实延时等长按识别（500ms 计时器）+ 读索引 + 弹框。
      final center = tester.getCenter(
        find.byKey(const ValueKey('site-picker-row-$_siteKey')),
      );
      final gesture = await tester.startGesture(center);
      await Future.delayed(const Duration(milliseconds: 700));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('卸载插件'), findsOneWidget);
      await gesture.up();
      await tester.tap(find.text('卸载'));
      await Future.delayed(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });
    await _settle(tester);

    // ① 弹窗里插件站消失、插件区变空。
    expect(
      find.byKey(const ValueKey('site-picker-row-$_siteKey')),
      findsNothing,
    );
    expect(find.text('插件区还没有站，去小程序「插件」tab 安装一个'), findsOneWidget);
    // ② 安装索引里消失（市场已安装列表读同一份索引）。
    final index = await IdjPluginStore().readIndex();
    expect(index.containsKey(_pluginId), isFalse);
    expect(await IdjPluginStore().listInstalled(), isEmpty);
    // ③ 登记表与片库可见站源里消失。
    expect(SourceSite.importedSites.containsKey(_siteKey), isFalse);
    expect(store.visibleSources.any((site) => site.id == _siteKey), isFalse);
    expect(tester.takeException(), isNull);
  });
}
