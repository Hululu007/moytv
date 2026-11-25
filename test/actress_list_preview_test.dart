// 女优库列表页预览截图：左上角站点筛选器三态（全部 / mjv / whos）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把三张放进同一个
// 测试体，也不要批量跑。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir =
    '/home/hatch/workspace/moyi_actress_sql_only_20261125/preview';

// 预览种子（setUp 里填，测试体里用）：放文件级，_capture 是顶层函数。
late LocalStore _previewStore;
late MemoryActressDatabase _previewDb;
late ActressJsonFallback _previewFallback;


ThemeData _previewTheme(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  TextStyle? cjk(TextStyle? style) => style?.copyWith(fontFamily: 'PreviewCJK');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjk(base.appBarTheme.titleTextStyle),
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

/// 列表页种子数据：A 八木奈奈（本地有 MIDA-619，本地 mjv011.json 里有
/// 这部）、B 测试二号（JSON 里没有）；名册检查点全记完成，不自动跑同步。
Future<
    ({
      LocalStore store,
      MemoryActressDatabase db,
      ActressJsonFallback fallback,
    })> _seed() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  final db = MemoryActressDatabase();
  final a = await db.upsertRosterPerson(
    const RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: 'a1',
      name: '八木奈奈',
      sex: 'female',
    ),
  );
  await db.upsertWorks(a!.localId, [
    const RosterFilm(code: 'MIDA-619', title: '测试作品'),
  ]);
  await db.upsertRosterPerson(
    const RosterPerson(
      source: ActressRosterSourceId.whos,
      sourceId: 'b1',
      name: '测试二号',
      sex: 'female',
    ),
  );
  for (final source in ActressRosterSourceId.values) {
    for (final phase in const ['roster', 'films']) {
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.name,
          phase: phase,
          finished: true,
        ),
      );
    }
  }
  // 兜底只读本地文件（2026-11-22 用户令最终口径：不内置 JSON 种子）：
  // 本地 mjv011.json 里给八木奈奈放一部 MIDA-619（2026-11-22 前
  // 这部在随包 mjv JSON 里，随包已删，改写本地文件）——mjv 筛选
  // 预览就靠它留人；'全部'视图不受影响。
  final temp = Directory.systemTemp.createTempSync();
  final jsonDir = Directory('${temp.path}/actress_json')
    ..createSync(recursive: true);
  File('${jsonDir.path}/mjv011.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'list': [
        {
          'vod_id': 'mjv-mida-619',
          'vod_name': 'MIDA-619 测试作品',
          'vod_pic': '',
          'vod_actor': '八木奈奈',
          'vod_director': '',
          'vod_remarks': '高清',
          'vod_pubdate': '2026-01-01',
          'vod_area': '日本',
          'vod_year': '2026',
          'vod_content': '',
          'vod_play_from': 'mjv011',
          'vod_play_url': '正片\$https://example.test/mida619.m3u8',
          'type_name': '有码',
          'vod_code': 'MIDA-619',
          'vod_actress_pic': '',
        },
      ],
      'parse': 0,
      'jx': 0,
      'last_update': '2026-11-20T00:00:00',
    }),
  );
  final fallback = ActressJsonFallback(localJsonDir: jsonDir);
  await fallback.load();
  return (store: store, db: db, fallback: fallback);
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required Future<void> Function(WidgetTester tester) action,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(_previewStore.dispose);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _previewTheme(AppThemeMode.purpleNeon),
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
                  child: ActressListPage(
                    repository: FixtureRepository(),
                    store: _previewStore,
                    database: _previewDb,
                    fallback: _previewFallback,
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
  await action(tester);
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

Future<void> _selectSite(WidgetTester tester, String site) async {
  await tester.tap(find.byKey(const ValueKey('actress-site-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(site).last);
  await tester.pumpAndSettle();
}

void main() {
  // 种子放 setUp（FakeAsync 区之外，真实事件循环）：测试体内第一个
  // pump 之前 await 异步 I/O/通道调用时，绑定不投递完成事件，会
  // 一直卡住（实测卡在 fallback.load 的文件读取上）。
  setUp(() async {
    final seed = await _seed();
    _previewStore = seed.store;
    _previewDb = seed.db;
    _previewFallback = seed.fallback;
    // MYTV 绑定预解析（树里既定做法，见 actress_count_fix_test.dart）：
    // 列表页 bootstrap 开头 await ensureBound()，它里面有异步文件
    // IO（探针写/删），在 widget 测试 FakeAsync 下挂起；setUp 在
    // 真实异步区，先解析完缓存起来，页内再调直接回缓存值。
    await ActressMytvBind.instance.ensureBound();
  });

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

  testWidgets('preview actress list all', (tester) async {
    await _capture(
      tester,
      name: 'actress_list_all',
      label: '预览 · 女优库列表页 · 站点筛选：全部（两人都在）',
      action: (tester) async {},
    );
  });

  testWidgets('preview actress list mjv', (tester) async {
    await _capture(
      tester,
      name: 'actress_list_mjv',
      label: '预览 · 女优库列表页 · 站点筛选：mjv（只留 JSON 里有的人）',
      action: (tester) async {
        await _selectSite(tester, 'mjv');
      },
    );
  });

  testWidgets('preview actress settings sheet', (tester) async {
    await _capture(
      tester,
      name: 'actress_settings_sheet',
      label: '预览 · 女优库设置弹窗 · 只剩导入数据库（绑定行/重新加载/镜像/多库已删）',
      action: (tester) async {
        await tester.tap(
          find.byKey(const ValueKey('open-actress-settings')),
        );
        await _settle(tester);
        // 导入区在弹窗下方，滚到可见再拍（按按钮 key 找：标题文本
        // “导入数据库（.sql）”与按钮文本撞名，scrollUntilVisible
        // 要求单元素；scrollable 必须显式指定弹窗里那个，否则
        // 默认 find.byType(Scrollable) 会撞上页面上多个滚动容器）。
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('actress-sql-import-button')),
          200,
          // 弹窗的 SingleChildScrollView 里还嵌了一个横向滚动容器，
          // descendant 会撞两个；外层那个在深度优先顺序里排第一。
          scrollable: find
              .descendant(
                of: find.descendant(
                  of: find.byType(BottomSheet),
                  matching: find.byType(SingleChildScrollView),
                ),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await _settle(tester);
      },
    );
  });

}
