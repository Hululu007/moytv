import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_home_view.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

Drama _drama(String id, String title) => Drama(
  id: id,
  source: 'hongguo',
  title: title,
  cover: 'https://example.test/cover.jpg',
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

  // 注意：调过 toImage 的测试在收尾时会挂起（PNG 已落地）。单独跑、
  // 超时杀掉只取 PNG；绝不与普通测试混批。
  testWidgets('预览霓虹首页顶栏：标题 chevron + 刷新钮', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: NeonHomeView(
              items: [
                _drama('row0', '普通短剧一'),
                _drama('row1', '普通短剧二'),
                _drama('row2', '普通短剧三'),
              ],
              repository: FixtureRepository(),
              brand: '魔蚁box',
              sourceLabel: '红果 (1)',
              onOpen: (_) {},
              onSearch: () {},
              onSourceTap: () {},
              onLongPress: (_) {},
              onRefresh: () async {},
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
    File('$_previewDir/neon_header_refresh.png').writeAsBytesSync(bytes);
    print('preview landed: neon_header_refresh');
  });
}
