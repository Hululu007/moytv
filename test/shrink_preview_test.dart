// 顶栏/任务栏压缩预览截图：只做测试内截图，不改业务代码。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
// 图里图标/个别字方块属测试字体，如实注。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
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
  required String source,
  required AppThemeMode themeMode,
  String? openIconKey,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 手机（Android）才走玻璃顶栏；体末复位。
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  SharedPreferences.setMockInitialValues({
    'source': source,
    'hiddenSites': '[]',
    'appThemeMode': themeMode.name,
  });
  if (source == 'missav') {
    SourceSite.importedSites['missav'] = SourceSite(
      'missav',
      'MissAV',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    addTearDown(() => SourceSite.importedSites.remove('missav'));
  }
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorObservers: [homeRouteObserver],
        theme: _previewTheme(themeMode),
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
  if (openIconKey != null) {
    await tester.tap(find.byKey(ValueKey(openIconKey)));
    await _settle(tester);
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

  testWidgets('preview shrink win7 library missav', (tester) async {
    await _capture(
      tester,
      name: 'shrink_win7_library',
      label: '压缩后 · Win7 片库窗(MissAV 态) · 左上角站图标点弹站点选择 · 标题栏32/单行顶栏44/任务栏48',
      source: 'missav',
      themeMode: AppThemeMode.win7,
      openIconKey: 'win7-desktop-icon-library',
    );
  });

  testWidgets('preview shrink win7 miniapp', (tester) async {
    await _capture(
      tester,
      name: 'shrink_win7_miniapp',
      label: '压缩后 · Win7 小程序窗 · 顶栏42 · 标题栏32/任务栏48',
      source: 'huangdou',
      themeMode: AppThemeMode.win7,
      openIconKey: 'win7-desktop-icon-miniApp',
    );
  });

  testWidgets('preview shrink normal topbar', (tester) async {
    await _capture(
      tester,
      name: 'shrink_normal_topbar',
      label: '压缩后 · 普通主题片库顶栏对照 · 单行图标顶栏44 · 站图标左上角第一位',
      source: 'missav',
      themeMode: AppThemeMode.purpleNeon,
    );
  });

  testWidgets('preview shrink win7 drama', (tester) async {
    await _capture(
      tester,
      name: 'shrink_win7_drama',
      label: '压缩后 · Win7 短剧窗 · 站源头行40/导航行54 · 标题栏32/任务栏48',
      source: 'hongguo',
      themeMode: AppThemeMode.win7,
      openIconKey: 'win7-desktop-icon-library',
    );
  });
}
