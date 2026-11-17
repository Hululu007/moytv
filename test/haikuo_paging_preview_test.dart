// G3 列表翻页预览截图：只做测试内截图，不改业务代码。
// 全部假数据：规则名与条目标题均为测试内合成，示意“第 1 页”与
// “滚到底追加第 2 页后”的列表状态（前 3 条不变、后 3 条新增）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧现象，PNG 已落地），
// 跑单测、超时杀掉只取 PNG。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';

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
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
  );
}

Widget _pagingPreview({required List<(String, String, bool)> items, required String footer}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _previewTheme(),
    home: DefaultTextStyle(
      style: const TextStyle(fontFamily: 'PreviewCJK'),
      child: Scaffold(
        backgroundColor: const Color(0xFF120B20),
        appBar: AppBar(
          title: const Text(
            '示例规则',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: const [
            Icon(Icons.search_rounded),
            Icon(Icons.refresh_rounded),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: const Text(
                '预览·假数据：列表翻页示意（滚到底追加，不重置已有列表）',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontFamily: 'PreviewCJK',
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    leading: Container(
                      width: 44,
                      height: 60,
                      color: item.$3 ? Colors.tealAccent : Colors.white24,
                      child: Icon(
                        Icons.movie_rounded,
                        color: item.$3 ? Colors.black54 : Colors.white70,
                      ),
                    ),
                    title: Text(
                      item.$1,
                      style: const TextStyle(fontFamily: 'PreviewCJK'),
                    ),
                    subtitle: Text(
                      item.$2,
                      style: const TextStyle(fontFamily: 'PreviewCJK'),
                    ),
                    trailing: item.$3
                        ? const Chip(
                            label: Text('第 2 页', style: TextStyle(fontSize: 10)),
                            visualDensity: VisualDensity.compact,
                          )
                        : const Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white54,
                          ),
                  );
                },
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                footer,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _shoot(WidgetTester tester, Widget page, String name) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(_loadPreviewFont);
  final key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(key: key, child: page));
  await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(bytes);
  print('preview landed: $name');
}

const _page1 = [
  ('示例剧名一', '第 1 页 · 假数据', false),
  ('示例剧名二', '第 1 页 · 假数据', false),
  ('示例剧名三', '第 1 页 · 假数据', false),
];

const _page2 = [
  ('示例剧名一', '第 1 页 · 假数据', false),
  ('示例剧名二', '第 1 页 · 假数据', false),
  ('示例剧名三', '第 1 页 · 假数据', false),
  ('示例剧名四', '第 2 页追加 · 假数据', true),
  ('示例剧名五', '第 2 页追加 · 假数据', true),
  ('示例剧名六', '第 2 页追加 · 假数据', true),
];

void main() {
  testWidgets('g3 paging preview p1', (tester) async {
    await _shoot(
      tester,
      _pagingPreview(items: _page1, footer: '上拉加载更多…'),
      'g3_paging_p1.png',
    );
  });

  testWidgets('g3 paging preview p2', (tester) async {
    await _shoot(
      tester,
      _pagingPreview(items: _page2, footer: '已加载第 2 页 · 继续上拉加载更多…'),
      'g3_paging_p2.png',
    );
  });
}
