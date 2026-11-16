// 海阔搜索界面预览截图：只做测试内截图，不改业务代码。
// 全部假数据：规则名、关键词、结果标题均为测试内合成。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧现象，PNG 已落地），
// 跑单测、超时杀掉只取 PNG。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';

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

void main() {
  testWidgets('haikuo search preview', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(_loadPreviewFont);
    const fakeResults = [
      ('示例剧名一', '2026 · 30 集 · 假数据'),
      ('示例剧名二', '2025 · 24 集 · 假数据'),
      ('示例剧名三', '2026 · 12 集 · 假数据'),
      ('示例剧名四', '2024 · 40 集 · 假数据'),
      ('示例剧名五', '2026 · 18 集 · 假数据'),
      ('示例剧名六', '2025 · 36 集 · 假数据'),
    ];
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
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(52),
                  child: HaikuoSearchBar(
                    initialKeyword: '仙逆',
                    onSubmitted: (_) {},
                    onClosed: () {},
                  ),
                ),
              ),
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
                      '预览·假数据：海阔搜索栏 + 搜索结果列表（点卡进详情页）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: fakeResults.length,
                      itemBuilder: (context, index) {
                        final item = fakeResults[index];
                        return ListTile(
                          leading: Container(
                            width: 44,
                            height: 60,
                            color: Colors.white24,
                            child: const Icon(
                              Icons.movie_rounded,
                              color: Colors.white70,
                            ),
                          ),
                          title: Text(
                            item.$1,
                            style: const TextStyle(
                              fontFamily: 'PreviewCJK',
                            ),
                          ),
                          subtitle: Text(
                            item.$2,
                            style: const TextStyle(
                              fontFamily: 'PreviewCJK',
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white54,
                          ),
                        );
                      },
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
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/haikuo_search.png').writeAsBytesSync(bytes);
    print('preview landed: haikuo_search');
  });
}
