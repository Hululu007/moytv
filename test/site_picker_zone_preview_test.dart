// 站点列表三区翻页 + 长按卸载确认预览图。
//
// 只渲染出 PNG，不测行为（行为见 site_picker_zone_flip_test 与
// site_picker_plugin_uninstall_test）。一测一张：调过 toImage 的
// 测试收尾会挂起（PNG 已落地），单跑、超时杀掉只取 PNG；
// 不要把预览文件和普通测试文件批量放在一次 flutter test 里跑。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/source_picker_sheet.dart';
import 'package:moyi/ui_style.dart';

const _previewDir = '/home/hatch/workspace/moyi_idjplugin_fix_20261124/preview';

/// 给按钮/列表瓦片的字样补 PreviewCJK：应用主题给 FilledButton、
/// TextButton、ListTile 都写了不带 fontFamily 的 textStyle，
/// 只改 textTheme 盖不住它们，测试字体下会显示为空框（真机系统
/// 字体有中文，不影响产品，只影响预览图）。
ButtonStyle _withCjk(ButtonStyle? style) {
  final resolved = style?.textStyle?.resolve({}) ?? const TextStyle();
  return (style ?? const ButtonStyle()).copyWith(
    textStyle: WidgetStatePropertyAll(
      resolved.copyWith(fontFamily: 'PreviewCJK'),
    ),
  );
}

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.lightClean).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: base.dialogTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: _withCjk(base.filledButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: _withCjk(base.textButtonTheme.style),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
      subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
  );
}

/// 三区演示分组：每区里再按短剧类/视频类/午夜类分。
/// 站名用站内真实站名；站标在测试环境拿不到真图，显示本地占位图案。
const _groups = [
  SourcePickerGroup(
    title: '短剧类',
    entries: [
      SourcePickerEntry(id: 'hongguo', name: '红果'),
      SourcePickerEntry(id: 'ikanbot', name: '爱看机器人'),
      SourcePickerEntry(id: 'huangdou', name: '黄豆短剧'),
    ],
    zone: SourcePickerGroup.zoneBuiltin,
  ),
  SourcePickerGroup(
    title: '视频类',
    entries: [
      SourcePickerEntry(id: 'v_xvideos', name: 'XVideos'),
      SourcePickerEntry(id: 'pornhub', name: 'Pornhub'),
    ],
    zone: SourcePickerGroup.zoneBuiltin,
  ),
  SourcePickerGroup(
    title: '午夜类',
    entries: [
      SourcePickerEntry(id: 'missav', name: '🔞MissAV'),
      SourcePickerEntry(id: 'hema', name: '🔞河马AV'),
      SourcePickerEntry(id: 'madou', name: '🔞麻豆TV'),
    ],
    zone: SourcePickerGroup.zoneBuiltin,
  ),
  SourcePickerGroup(
    title: '短剧类',
    entries: [SourcePickerEntry(id: 'imp_drama', name: '导入短剧站')],
    zone: SourcePickerGroup.zoneImport,
  ),
  SourcePickerGroup(
    title: '视频类',
    entries: [SourcePickerEntry(id: 'imp_video', name: '我的导入站')],
    zone: SourcePickerGroup.zoneImport,
  ),
  SourcePickerGroup(
    title: '午夜类',
    entries: [SourcePickerEntry(id: 'imp_mid', name: '🔞导入午夜站')],
    zone: SourcePickerGroup.zoneImport,
  ),
  SourcePickerGroup(
    title: '短剧类',
    entries: [SourcePickerEntry(id: 'idj_chengguo', name: '橙果短剧')],
    zone: SourcePickerGroup.zonePlugin,
  ),
  SourcePickerGroup(
    title: '午夜类',
    entries: [
      SourcePickerEntry(id: 'idj_chaoliu', name: '🔞潮流AV'),
      SourcePickerEntry(id: 'idj_ai2048', name: '🔞2048AI'),
    ],
    zone: SourcePickerGroup.zonePlugin,
  ),
];

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required int initialZoneIndex,
  bool longPressPlugin = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  appThemeNotifier.value = AppThemeMode.lightClean;
  final key = GlobalKey();
  try {
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
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
                    child: SitePickerDialog(
                      sectionName: '片库',
                      currentId: 'hongguo',
                      groups: _groups,
                      // 长按卸载走弹窗自己的删除入口：预览里弹确认框
                      // 即止（返回 false 不真删），只拍确认框样子。
                      onDeleteSite: (entry) async {
                        final confirmed = await showDialog<bool>(
                          context: tester.element(
                            find.byKey(const ValueKey('site-picker-dialog')),
                          ),
                          builder: (context) => AlertDialog(
                            title: const Text('卸载插件'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('确定卸载「${entry.name}」吗？卸载后该站从片库消失。'),
                                const SizedBox(height: 8),
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('同时清除插件数据'),
                                  subtitle: const Text('勾选后插件的存储与 Cookie 一并删除'),
                                  value: false,
                                  onChanged: (_) {},
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('卸载'),
                              ),
                            ],
                          ),
                        );
                        return confirmed ?? false;
                      },
                      onImport: () async {},
                      enableZoneFlip: true,
                      initialZoneIndex: initialZoneIndex,
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
    if (longPressPlugin) {
      await tester.longPress(
        find.byKey(const ValueKey('site-picker-row-idj_chengguo')),
      );
      await tester.pumpAndSettle();
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

  testWidgets('预览 站点列表 内置区', (tester) async {
    await _capture(
      tester,
      name: 'site_picker_zone_builtin',
      label: '站点列表 · 内置区（区内分短剧类/视频类/午夜类）· 站标为本地占位图案，非真实站标',
      initialZoneIndex: 0,
    );
  });

  testWidgets('预览 站点列表 导入区', (tester) async {
    await _capture(
      tester,
      name: 'site_picker_zone_import',
      label: '站点列表 · 导入区（区内分短剧类/视频类/午夜类）· 站标为本地占位图案，非真实站标',
      initialZoneIndex: 1,
    );
  });

  testWidgets('预览 站点列表 插件区', (tester) async {
    await _capture(
      tester,
      name: 'site_picker_zone_plugin',
      label: '站点列表 · 插件区（区内分短剧类/午夜类）· 站标为本地占位图案，非真实站标',
      initialZoneIndex: 2,
    );
  });

  testWidgets('预览 站点列表 长按卸载确认', (tester) async {
    await _capture(
      tester,
      name: 'site_picker_uninstall_confirm',
      label: '站点列表 · 插件区长按「橙果短剧」弹卸载确认 · 站标为本地占位图案，非真实站标',
      initialZoneIndex: 2,
      longPressPlugin: true,
    );
  });
}
