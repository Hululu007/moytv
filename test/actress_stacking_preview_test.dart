// 全站叠加横幅预览截图：只做测试内截图，不改业务代码。
// 假数据说明：人物均为测试内合成；头像为空占位；图标在测试环境
// 渲染为方块。调过 toImage 的测试在收尾时会挂起（PNG 已落地），
// 跑单测、超时杀掉只取 PNG。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_search.dart';
import 'package:moyi/actress/actress_stacking.dart';
import 'package:moyi/actress/actress_sync.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  TextStyle? cjk(TextStyle? style) => style?.copyWith(fontFamily: 'PreviewCJK');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjk(base.appBarTheme.titleTextStyle),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: cjk(base.chipTheme.labelStyle),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
}

class _PreviewRepository extends FixtureRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage([]);
}

Future<MemoryActressDatabase> _seedDatabase() async {
  final db = MemoryActressDatabase();
  const names = [
    ('波多野結衣', 'female', 320),
    ('友田真希', 'female', 240),
    ('陈小芳', 'female', 180),
    ('Alice', 'female', 120),
    ('Aoi', 'female', 96),
    ('さくら', 'female', 150),
    ('Bob', 'male', 210),
    ('刘大伟', 'male', 180),
    ('Ben', 'male', 64),
  ];
  var thirdId = 0;
  for (var i = 0; i < names.length; i++) {
    final (name, sex, works) = names[i];
    final person = await db.upsertRosterPerson(
      RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: 'seed-$i',
        name: name,
        sex: sex,
        worksHint: works,
      ),
    );
    if (i == 2) thirdId = person!.localId;
    await db.upsertWorks(person!.localId, [
      RosterFilm(code: 'SEED-$i', title: '作品$i'),
    ]);
  }
  // 压住自动同步：三家名册检查点全部记完成。
  for (final source in ActressRosterSourceId.values) {
    for (final phase in ['roster', 'films']) {
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.name,
          phase: phase,
          finished: true,
        ),
      );
    }
  }
  // 叠加断点在半程：已叠加 3/9 人，横幅显示“继续叠加”。
  await db.saveStackingCheckpoint(
    ActressSyncCheckpoint(
      source: actressStackingCheckpointSource,
      phase: actressStackingCheckpointPhase,
      cursor: '$thirdId',
      total: 3,
      finished: false,
    ),
  );
  return db;
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

  testWidgets('preview actress stacking banner', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    appThemeNotifier.value = AppThemeMode.purpleNeon;
    final db = await _seedDatabase();
    final repository = _PreviewRepository();
    final sync = ActressSyncService(
      db: db,
      sources: const [],
      fetch:
          (
            String url, {
            Map<String, String> headers = const {},
            Duration timeout = const Duration(seconds: 20),
          }) async => throw UnimplementedError(),
    );
    addTearDown(sync.dispose);
    final stacking = ActressStackingService(
      db: db,
      enrichment: ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      ),
    );
    addTearDown(stacking.dispose);
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
                      '预览 · 假数据 · 女优库全站叠加横幅（断点 3/9 人）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(
                    child: ActressListPage(
                      repository: repository,
                      store: store,
                      database: db,
                      syncService: sync,
                      stackingService: stacking,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/actress_stacking.png').writeAsBytesSync(bytes);
  });
}
