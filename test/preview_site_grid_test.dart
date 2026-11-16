import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
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
      SourcePickerEntry(id: 's8', name: '🔞糖心Vlog'),
    ],
  ),
];

Future<void> _capture(
  WidgetTester tester, {
  required AppThemeMode mode,
  required String name,
  required String label,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  appThemeNotifier.value = mode;
  final key = GlobalKey();
  try {
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewThemeFor(mode),
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
                  const Expanded(
                    child: SitePickerDialog(
                      sectionName: '片库',
                      currentId: 's2',
                      groups: _groups,
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
    appThemeNotifier.value = AppThemeMode.purpleNeon;
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
  testWidgets('预览 站点宫格 普通主题', (tester) async {
    await _capture(
      tester,
      mode: AppThemeMode.lightClean,
      name: 'site_grid_default',
      label: '站点宫格 · 普通主题（lightClean）',
    );
  });

  testWidgets('预览 站点宫格 霓虹主题', (tester) async {
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      name: 'site_grid_neon',
      label: '站点宫格 · 霓虹主题（purpleNeon，无仓库路径）',
    );
  });
}
