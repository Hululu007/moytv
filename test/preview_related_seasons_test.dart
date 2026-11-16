// 预览：详情页相关剧集区。一测一张，收尾挂起是已知现象，PNG 落地即杀。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

class _PreviewRepository extends FixtureRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [];

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    return DramaDetail(drama, [
      Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
      Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
    ], related: [
      const Drama(
        id: 'hongguo:12345678902',
        source: 'hongguo',
        title: '测试剧第二季',
        episodes: 80,
        category: '合成数据',
      ),
      const Drama(
        id: 'hongguo:12345678903',
        source: 'hongguo',
        title: '测试剧第三季',
        episodes: 80,
        category: '合成数据',
      ),
      const Drama(
        id: 'hongguo:12345678904',
        source: 'hongguo',
        title: '测试剧第四季',
        episodes: 80,
        category: '合成数据',
      ),
    ]);
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

  testWidgets('预览详情页相关剧集区', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final key = GlobalKey();
    final base = AppThemeConfig.forTheme(
      AppThemeMode.purpleNeon,
    ).toThemeData();
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'PreviewCJK',
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: DetailScreen(
              drama: const Drama(
                id: 'hongguo:12345678901',
                source: 'hongguo',
                title: '测试剧第一季',
                episodes: 80,
                category: '合成数据',
                description: '同系列四季，相关区应按季号升序排卡，当前季标“当前”。',
              ),
              repository: _PreviewRepository(),
              store: store,
              playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    // 滚到相关剧集区，让它进画面。
    final scroll = find.byType(CustomScrollView);
    for (var i = 0; i < 30 && find.text('相关剧集').evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 再往上滚一段，让第一排卡片的标题与季标签完整进画面。
    await tester.drag(scroll, const Offset(0, -260));
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
    File('$_previewDir/related_seasons.png').writeAsBytesSync(bytes);
    print('preview landed: related_seasons');
  });
}
