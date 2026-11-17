// 女优模块预览截图：只做测试内截图，不改业务代码。
// 假数据说明：人物、作品、名次均为测试内合成；头像与封面为空占位
// （仓库 cover 返回空）；图标在测试环境渲染为方块。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_ranking_page.dart';
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
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: cjk(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: cjk(base.listTileTheme.subtitleTextStyle),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) =>
              cjk(base.textButtonTheme.style?.textStyle?.resolve(states)),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
  for (var i = 0; i < 10; i++) {
    try {
      if (tester.takeException() == null) break;
    } catch (_) {
      break;
    }
  }
}

/// 预览仓库：封面返回空（占位卡片），搜索返回空（补全不改动种子数据）。
class _PreviewRepository extends FixtureRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage([]);
}

Future<MemoryActressDatabase> _seedDatabase() async {
  final db = MemoryActressDatabase();
  final names = [
    ('安倍亚沙美', 'female', 320, 1),
    ('白石莉莉', 'female', 280, 2),
    ('陈小芳', 'female', 240, 3),
    ('刘大伟', 'male', 210, 4),
    ('王小明', 'male', 180, 5),
    ('赵小红', 'female', 160, 6),
    ('周小强', 'male', 150, 8),
    ('吴小丽', 'female', 120, 12),
    ('郑小华', 'female', 96, 20),
    ('孙小明', 'male', 88, 30),
    ('胡小美', 'female', 64, 45),
    ('郭小刚', 'male', 52, 60),
  ];
  for (var i = 0; i < names.length; i++) {
    final (name, sex, works, rank) = names[i];
    final person = (await db.upsertRosterPerson(
      RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: 'seed-$i',
        name: name,
        sex: sex,
        tags: switch (i % 4) {
          0 => const ['有码'],
          1 => const ['有码', '无码'],
          2 => const ['欧美'],
          _ => const <String>[],
        },
        worksHint: works,
      ),
    ))!;
    await db.setMissavRank(person.localId, rank);
    if (i == 0) {
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-05'),
        RosterFilm(code: 'SSIS-00145', date: '2024-02-03'),
        RosterFilm(code: 'HMN-927', date: '2024-03-11'),
        RosterFilm(code: 'ABW-168', date: '2024-04-02'),
        RosterFilm(code: 'MIDV-456', date: '2024-05-19'),
        RosterFilm(code: 'SONE-078', date: '2024-06-08'),
        RosterFilm(code: 'PRED-512', date: '2024-07-21'),
        RosterFilm(code: 'JUQ-903', date: '2024-08-14'),
        RosterFilm(code: 'FC2-PPV-1234567', date: '2024-09-01'),
        RosterFilm(code: '', title: '无番号示例作品标题'),
      ]);
    }
  }
  return db;
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required Widget Function(
    MemoryActressDatabase db,
    _PreviewRepository repository,
    LocalStore store,
  )
  buildPage,
}) async {
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
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontFamily: 'PreviewCJK',
                    ),
                  ),
                ),
                Expanded(child: buildPage(db, repository, store)),
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
  File('$_previewDir/$name.png').writeAsBytesSync(bytes);
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

  testWidgets('preview actress list', (tester) async {
    await _capture(
      tester,
      name: 'actress_list',
      label: '预览 · 假数据 · 女优库列表 · 封面头像为占位',
      buildPage: (db, repository, store) {
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
        return ActressListPage(
          repository: repository,
          store: store,
          database: db,
          syncService: sync,
        );
      },
    );
  });

  testWidgets('preview actress detail', (tester) async {
    await _capture(
      tester,
      name: 'actress_detail',
      label: '预览 · 假数据 · 人物详情作品卡片网格 · 封面为占位',
      buildPage: (db, repository, store) => ActressDetailPage(
        localId: 1,
        repository: repository,
        store: store,
        database: db,
      ),
    );
  });

  testWidgets('preview actress ranking', (tester) async {
    await _capture(
      tester,
      name: 'actress_ranking',
      label: '预览 · 假数据 · 女优排行榜 · 头像为占位',
      buildPage: (db, repository, store) => ActressRankingPage(
        repository: repository,
        store: store,
        database: db,
      ),
    );
  });
}
