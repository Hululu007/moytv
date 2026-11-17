import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/neon/neon_channel_view.dart';
import 'package:moyi/source_picker_sheet.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'real_fixture.dart';

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

Future<LocalStore> _previewStore(AppThemeMode mode, String source) async {
  SharedPreferences.setMockInitialValues({
    'source': source,
    'hiddenSites': '[]',
    'appThemeMode': mode.name,
  });
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
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
  testWidgets('预览 Win7 窗口安全区', (tester) async {
    appThemeNotifier.value = AppThemeMode.win7;
    final store = await _previewStore(AppThemeMode.win7, 'huangdou');
    await _capturePng(
      tester,
      name: 'win7_window_safearea',
      app: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorObservers: [homeRouteObserver],
        theme: _previewThemeFor(AppThemeMode.win7),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: HomeScreen(repository: FixtureRepository(), store: store),
        ),
      ),
      setup: (tester) async {
        await tester.tap(
          find.byKey(const ValueKey('win7-desktop-icon-library')),
        );
      },
    );
  });

  testWidgets('预览 非Win7 首页安全区', (tester) async {
    appThemeNotifier.value = AppThemeMode.purpleNeon;
    final store = await _previewStore(AppThemeMode.purpleNeon, 'huangdou');
    await _capturePng(
      tester,
      name: 'home_neon_safearea',
      app: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorObservers: [homeRouteObserver],
        theme: _previewThemeFor(AppThemeMode.purpleNeon),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: HomeScreen(repository: FixtureRepository(), store: store),
        ),
      ),
    );
  });

  testWidgets('预览 频道侧栏新样式', (tester) async {
    appThemeNotifier.value = AppThemeMode.win7;
    final data = loadRealFixture();
    await _capturePng(
      tester,
      name: 'channel_sidebar_new',
      app: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _previewThemeFor(AppThemeMode.win7),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: Scaffold(
            body: NeonChannelView(
              items: data.items,
              repository: RealFixtureRepository(data),
              categories: data.categories,
              selectedCategory: '',
              onCategory: (_) {},
              onOpen: (_) {},
              onBack: () {},
              onSearch: () {},
              onFilter: () {},
              onRankings: () {},
              onSwitchSource: () {},
              sourceLabel: data.stationName,
            ),
          ),
        ),
      ),
    );
  });

  testWidgets('预览 站点列表图标', (tester) async {
    appThemeNotifier.value = AppThemeMode.purpleNeon;
    const groups = [
      SourcePickerGroup(
        title: '内置影视',
        entries: [
          SourcePickerEntry(id: 'aijav', name: '🔞AiJav'),
          SourcePickerEntry(id: 'v_missav', name: 'MissAV'),
          SourcePickerEntry(id: 'jar:zakatv:ZakaLxs', name: '🔞撸先生'),
          SourcePickerEntry(id: 'sp91', name: '🔞91视频'),
          SourcePickerEntry(id: 'akmh', name: '🔞爱看漫画'),
          SourcePickerEntry(id: 'hmav', name: '🔞河马AV'),
          SourcePickerEntry(id: 'abjav', name: '🔞ABJAV'),
          SourcePickerEntry(id: 'v_javdb', name: 'JavDB'),
          SourcePickerEntry(id: 'chaoliu', name: '🔞潮流AV'),
          SourcePickerEntry(id: 'v_sihu', name: '四虎'),
          SourcePickerEntry(id: 'legado_8039_0', name: '禁漫天堂'),
        ],
      ),
    ];
    await _capturePng(
      tester,
      name: 'site_list_icons',
      app: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _previewThemeFor(AppThemeMode.purpleNeon),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: const Scaffold(
            body: SitePickerDialog(
              sectionName: '片库',
              currentId: 'aijav',
              groups: groups,
            ),
          ),
        ),
      ),
      setup: (tester) async {
        // 内置图标走 Image.asset：给资源加载与图片解码一段真实时间，
        // 否则截图时图标位还是空的。
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 800)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      },
    );
  });
}
