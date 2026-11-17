// 导入入口搬家预览截图：只做测试内截图，不改业务代码。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
// 图里图标/个别字方块属测试字体，如实注。弹窗一律跟主题深色，不固定白色。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/site_import_flow.dart';
import 'package:moyi/source_picker_sheet.dart';
import 'package:moyi/ui_style.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewThemeFor(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: base.dialogTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
      subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith((states) {
          final style = base.textButtonTheme.style?.textStyle?.resolve(
            states,
          );
          return style?.copyWith(fontFamily: 'PreviewCJK');
        }),
      ),
    ),
  );
}

const _groups = [
  SourcePickerGroup(
    title: '内置影视',
    entries: [
      SourcePickerEntry(id: 's1', name: '🔞黄果'),
      SourcePickerEntry(id: 's2', name: '🔞河马AV'),
      SourcePickerEntry(id: 's3', name: 'MissAV'),
      SourcePickerEntry(id: 's4', name: '🔞麻豆TV'),
      SourcePickerEntry(id: 's5', name: '91短视频'),
    ],
  ),
  SourcePickerGroup(
    title: '导入',
    entries: [
      SourcePickerEntry(id: 's6', name: '🔞海角社区'),
      SourcePickerEntry(id: 's7', name: '🔞猫咪AV'),
    ],
  ),
];

Future<void> _snap(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
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

  testWidgets('preview import plus popup', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appThemeNotifier.value = AppThemeMode.win7;
    final key = GlobalKey();
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _previewThemeFor(AppThemeMode.win7),
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
                      child: const Text(
                        '站点弹窗右上角 + 号（Win7 深色主题）',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontFamily: 'PreviewCJK',
                        ),
                      ),
                    ),
                    const Expanded(
                      child: SitePickerDialog(
                        sectionName: '片库',
                        currentId: 's2',
                        groups: _groups,
                        onImport: _noopImport,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await _snap(tester, key, 'import_plus_popup');
    } finally {
      appThemeNotifier.value = AppThemeMode.purpleNeon;
    }
  });

  testWidgets('preview import plus dialog', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appThemeNotifier.value = AppThemeMode.win7;
    final key = GlobalKey();
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _previewThemeFor(AppThemeMode.win7),
            home: DefaultTextStyle(
              style: const TextStyle(fontFamily: 'PreviewCJK'),
              child: Scaffold(
                body: Builder(
                  builder: (context) => Column(
                    children: [
                      Container(
                        width: double.infinity,
                        color: Colors.black87,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: const Text(
                          '点 + 号后的导入分流弹窗（跟主题深色）',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontFamily: 'PreviewCJK',
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: FilledButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) =>
                                  const SiteImportChoiceDialog(),
                            ),
                            child: const Text('打开导入'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('打开导入'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _snap(tester, key, 'import_plus_dialog');
    } finally {
      appThemeNotifier.value = AppThemeMode.purpleNeon;
    }
  });
}

Future<void> _noopImport() async {}
