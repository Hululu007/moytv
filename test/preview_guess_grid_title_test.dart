import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_home_view.dart';
import 'package:moyi/ui_style.dart';

import 'fixtures.dart';

// 预览：猜你想看网格在封面全部加载失败（占位图状态）时仍有标题。
// 一测一图：调过 toImage 的测试收尾会挂起，PNG 落地即可，勿等它退。
const _previewDir = '/home/hatch/workspace/moyi_card_drama_fix_20261125/preview';

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Drama _drama(String id, String title, int episodes) => Drama(
  id: id,
  source: 'hongguo',
  title: title,
  cover: 'https://example.test/$id.jpg',
  episodes: episodes,
  kind: 'video',
);

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

  testWidgets('preview guess grid titles without covers', (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appThemeNotifier.value = AppThemeMode.purpleNeon;
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
                      '预览 · 假数据 · 封面全部加载失败 · 猜你想看仍有标题',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(
                    child: NeonHomeView(
                      items: [
                        _drama('g1', '猜你想看甲', 3),
                        _drama('g2', '猜你想看乙', 5),
                        _drama('g3', '猜你想看丙', 0),
                        _drama('g4', '猜你想看丁', 12),
                        _drama('g5', '猜你想看戊', 8),
                        _drama('g6', '猜你想看己', 1),
                      ],
                      repository: FixtureRepository(),
                      brand: '魔蚁TV',
                      sourceLabel: '测试站 (6)',
                      onOpen: (_) {},
                      onSearch: () {},
                      onSourceTap: () {},
                      onLongPress: (_) {},
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/guess_grid_cover_fail_title.png').writeAsBytesSync(bytes);
  });
}
