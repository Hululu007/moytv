// 我的页新版预览截图：只做测试内截图，不改业务代码。
// 全部假数据；调过 toImage 的测试在收尾时可能挂起（旧现象，PNG 已落地），
// 跑单测、超时杀掉只取 PNG。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _MinePreviewRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async => throw AppFailure('测试不播');
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

  testWidgets('预览 我的页新版', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appThemeNotifier.value = AppThemeMode.purpleNeon;
    const categories = [
      CatalogCategory('', '全部'),
      CatalogCategory('short_play', '真人剧'),
      CatalogCategory('comic_series', '漫剧'),
      CatalogCategory('rec', '推荐'),
    ];
    SharedPreferences.setMockInitialValues({'appThemeMode': 'purpleNeon'});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final base = AppThemeConfig.forTheme(
      AppThemeMode.purpleNeon,
    ).toThemeData();
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    );
    final key = GlobalKey();
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
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
                        '预览 · 假数据 · 我的页新版：设置页风格分组、无顶部导航',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontFamily: 'PreviewCJK',
                        ),
                      ),
                    ),
                    Expanded(
                      child: HongguoDramaHome(
                        dramas: const [
                          Drama(
                            id: 'hongguo:1',
                            source: 'hongguo',
                            title: '普通短剧一',
                            cover: 'https://x.test/base.jpg',
                            episodes: 3,
                          ),
                        ],
                        repository: _MinePreviewRepository(),
                        store: store,
                        onOpenDrama: (_) {},
                        onOpenFeed: () {},
                        onPickSource: () {},
                        sourceLabel: '红果 (1)',
                        feedEnabled: true,
                        categories: categories,
                        selectedCategory: 'rec',
                        onCategorySelected: (_) {},
                        searchController: TextEditingController(),
                        searchHint: '搜索',
                        onSearchChanged: (_) {},
                        onSearchSubmitted: (_) {},
                        onOpenGlobalSearch: () {},
                        onMenuPressed: () {},
                        onFilterPressed: () {},
                        onRankingsPressed: () {},
                        onNewPressed: () {},
                        filtersActive: false,
                        newActive: false,
                        onOpenSaved: ({required bool history}) {},
                        onSettingsPressed: () {},
                        requestedTab: HongguoDramaHome.mineTabIndex,
                        hideCapsuleBar: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      const dir = '/home/hatch/workspace/moyi_previews';
      Directory(dir).createSync(recursive: true);
      File('$dir/mine_restyled.png').writeAsBytesSync(bytes);
      print('preview landed: mine_restyled');
    } finally {
      appThemeNotifier.value = AppThemeMode.purpleNeon;
    }
  });
}
