// ZIP 选择器预览截图：只做测试内截图，不改业务代码。
// 全部假数据：条目名、频道数、分类数均为测试内合成。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧现象，PNG 已落地），
// 跑单测、超时杀掉只取 PNG；不要把多张放进同一个测试体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/import_center.dart';
import 'package:moyi/zip_contents.dart';
import 'package:moyi/zip_install.dart';
import 'package:moyi/zip_pick_screen.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

Future<void> _loadPreviewFont() async {
  try {
    const path = String.fromEnvironment(
      'PREVIEW_FONT',
      defaultValue: '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    );
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final loader = FontLoader('PreviewCJK')
      ..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
    await loader.load().timeout(
      const Duration(seconds: 30),
      onTimeout: () {},
    );
  } catch (_) {}
}

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
      subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith((states) {
          final style = base.filledButtonTheme.style?.textStyle?.resolve(
            states,
          );
          return style?.copyWith(fontFamily: 'PreviewCJK');
        }),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith((states) {
          final style = base.textButtonTheme.style?.textStyle?.resolve(states);
          return style?.copyWith(fontFamily: 'PreviewCJK');
        }),
      ),
    ),
  );
}

ZipPickItem _fakeItem({
  required String key,
  required String name,
  required ZipItemKind kind,
  required String detail,
  required ZipInstallKind installKind,
}) => ZipPickItem(
  key: key,
  name: name,
  archivePath: key,
  kind: kind,
  detail: detail,
  installKind: installKind,
  installName: name,
  bytes: const [1],
  unrecognizedReason: kind == ZipItemKind.unknown ? detail : '',
);

void main() {
  testWidgets('zip picker preview', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(_loadPreviewFont);
    final items = [
      _fakeItem(
        key: 'demo_site.py',
        name: '示例站点.py',
        kind: ZipItemKind.videoSource,
        detail: 'py 蜘蛛',
        installKind: ZipInstallKind.importEngine,
      ),
      _fakeItem(
        key: 'demo_plugin.jar',
        name: '示例插件.jar',
        kind: ZipItemKind.videoSource,
        detail: 'jar 插件',
        installKind: ZipInstallKind.importEngine,
      ),
      _fakeItem(
        key: 'demo_live.m3u',
        name: '示例直播.m3u',
        kind: ZipItemKind.liveList,
        detail: '128 个频道 · 6 个分类',
        installKind: ZipInstallKind.liveList,
      ),
      _fakeItem(
        key: 'demo_rule.js',
        name: '示例规则.js',
        kind: ZipItemKind.component,
        detail: 'JS 蜘蛛',
        installKind: ZipInstallKind.importEngine,
      ),
      _fakeItem(
        key: 'group:demo/manifest.json',
        name: '示例小程序',
        kind: ZipItemKind.component,
        detail: '小程序 · 4 个文件',
        installKind: ZipInstallKind.miniappZip,
      ),
      _fakeItem(
        key: 'demo_config.json',
        name: '示例配置.json',
        kind: ZipItemKind.component,
        detail: 'TVBox 配置',
        installKind: ZipInstallKind.importEngine,
      ),
      _fakeItem(
        key: 'note.txt',
        name: '说明.txt',
        kind: ZipItemKind.unknown,
        detail: '未解析到任何频道',
        installKind: ZipInstallKind.importEngine,
      ),
      _fakeItem(
        key: 'photo.png',
        name: '图片.png',
        kind: ZipItemKind.unknown,
        detail: '不支持的文件类型',
        installKind: ZipInstallKind.importEngine,
      ),
    ];
    final installer = ZipPickInstaller(
      importCandidates: (candidates) async => const ImportReport([]),
      installLiveList: (item) async => ImportOutcome(
        fileName: item.name,
        status: ImportOutcomeStatus.success,
        reason: 'ok',
      ),
      installMiniApp: (item) async => ImportOutcome(
        fileName: item.name,
        status: ImportOutcomeStatus.success,
        reason: 'ok',
      ),
      jarDuplicateCheck: (_) => null,
    );
    final key = GlobalKey();
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
                    child: const Text(
                      '预览·假数据：ZIP 选择器（分类列出条目 + 勾选安装）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(
                    child: ZipPickScreen(
                      zipName: '示例安装包.zip',
                      items: items,
                      installer: installer,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 取消勾选一条组件，展示“勾选/不勾选”两种状态。
    await tester.tap(
      find.byKey(const ValueKey('zip-pick-item-demo_rule.js')),
    );
    await tester.pump();
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
    File('$_previewDir/zip_picker.png').writeAsBytesSync(bytes);
    print('preview landed: zip_picker');
  });
}
