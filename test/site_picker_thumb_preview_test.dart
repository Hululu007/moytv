// 站点列表网格卡片缩图预览图。
//
// 只渲染出 PNG，不测行为（行为见 site_picker_thumb_test）。
// 缩图是测试里现画的占位图（纯色渐变块，按站 id 分色），
// 不是真实站内视频封面——本机拉不到真站首页是已知限制；
// 失效站（hema）故意不给缩图，卡片只显示站标，演示回落。
// 一测一张：调过 toImage 的测试收尾会挂起（PNG 已落地），
// 单跑、超时杀掉只取 PNG；不要把预览文件和普通测试文件
// 批量放在一次 flutter test 里跑。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/site_icon.dart';
import 'package:moyi/site_thumb_cache.dart';
import 'package:moyi/source_picker_sheet.dart';
import 'package:moyi/ui_style.dart';

const _previewDir = '/home/hatch/workspace/moyi_site_thumb_20261124/preview';

/// 给按钮/列表瓦片的字样补 PreviewCJK：应用主题给 FilledButton、
// TextButton、ListTile 都写了不带 fontFamily 的 textStyle，
// 只改 textTheme 盖不住它们，测试字体下会显示为空框（真机系统
// 字体有中文，不影响产品，只影响预览图）。
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
/// 站名用站内真实站名；缩图是现画占位图，不是真实站内封面；
/// hema（河马AV）故意不给缩图，演示失效站只显示站标。
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

/// 有缩图的站（hema 不在内：演示失效站只显示站标）。
const _thumbSites = [
  'hongguo',
  'ikanbot',
  'huangdou',
  'v_xvideos',
  'pornhub',
  'missav',
  'madou',
  'imp_drama',
  'imp_video',
  'imp_mid',
  'idj_chengguo',
  'idj_chaoliu',
  'idj_ai2048',
];

/// 按地址哈希现画一张 160x90 占位 PNG（斜向两色渐变 +
/// 中央播放三角）：颜色随站变、形状一看就是占位图，
/// 不冒充任何真实视频封面。
Future<List<int>> _placeholderPng(String url) async {
  var hash = 0;
  for (final unit in url.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final hue = (hash % 360).toDouble();
  final c1 = HSVColor.fromAHSV(1, hue, 0.75, 0.85).toColor();
  final c2 = HSVColor.fromAHSV(1, (hue + 40) % 360, 0.8, 0.55).toColor();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()
    ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(160, 90), [
      c1,
      c2,
    ]);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 160, 90), paint);
  final triangle = Paint()..color = const Color(0xCCFFFFFF);
  final path = Path()
    ..moveTo(66, 30)
    ..lineTo(66, 60)
    ..lineTo(96, 45)
    ..close();
  canvas.drawPath(path, triangle);
  final picture = recorder.endRecording();
  final image = await picture.toImage(160, 90);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required int initialZoneIndex,
  required int expectedImages,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  appThemeNotifier.value = AppThemeMode.lightClean;
  final tempDir = Directory.systemTemp.createTempSync('site_thumb_preview_');
  addTearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });
  // 缩图映射直接写盘（同步写），缓存首读即命中，不走真取数。
  File('${tempDir.path}/${SiteThumbCache.fileName}').writeAsStringSync(
    jsonEncode({
      for (final id in _thumbSites) id: 'https://example.com/thumb-$id.jpg',
    }),
  );
  final thumbCache = SiteThumbCache(directoryProvider: () async => tempDir);
  final imageCache = SiteIconCache(
    directoryProvider: () async => tempDir,
    fetcher: (url) => _placeholderPng(url),
  );
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
                      onDeleteSite: (entry) async => false,
                      onImport: () async {},
                      enableZoneFlip: true,
                      initialZoneIndex: initialZoneIndex,
                      thumbCache: thumbCache,
                      // hema 不在映射里：取数回 null，演示只显示站标。
                      thumbFetcher: (_) async => null,
                      thumbImageCache: imageCache,
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
    // 真异步链（缓存读盘、图片落盘、图片解码）每一跳要一个
    // runAsync 窗口 + 一个 pump：轮询等缩图都画出来（光是
    // Image 在树里还不够，解码没完截图出来是空白），再多等
    // 几轮让解码跑完再截图。
    for (var i = 0; i < 24; i++) {
      if (find.byType(Image).evaluate().length >= expectedImages) break;
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
    }
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
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

  testWidgets('预览 站点列表网格卡片 内置区', (tester) async {
    await _capture(
      tester,
      name: 'site_thumb_grid_builtin',
      label: '站点列表 · 网格卡片内置区（每行三张卡，16:9 小平图）· 缩图为现画占位图非真实站内封面 · 河马AV 无缩图只显示站标',
      initialZoneIndex: 0,
      // 内置区有缩图的卡：短剧 3 + 视频 2 + 午夜 2（hema 除外）。
      expectedImages: 7,
    );
  });

  testWidgets('预览 站点列表网格卡片 插件区', (tester) async {
    await _capture(
      tester,
      name: 'site_thumb_grid_plugin',
      label: '站点列表 · 网格卡片插件区（每行三张卡，16:9 小平图）· 缩图为现画占位图非真实站内封面',
      initialZoneIndex: 2,
      expectedImages: 3,
    );
  });
}
