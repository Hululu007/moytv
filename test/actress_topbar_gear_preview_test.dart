// 演员库顶栏预览（2026-11-26 23:00 用户令）：右上角「影片
// 库」入口删除、设置收成一个齿轮放右上角（搜索框旁，独立 /
// 内嵌两种模式都可见）。本文件出主页图
// actress_topbar_gear_home（搜索框 + 设置齿轮、没有「影片
// 库」药丸钮）；弹层图在 actress_topbar_sheet_preview_test
// （只剩数据库管理 / 重新加载数据库两行）。PNG 落本工作树
// preview/ 下。一测一张（toImage 收尾挂起是既有预览测试的
// 通病，靠 PNG 落盘判成败）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_film_library.dart';
import 'package:moyi/actress/actress_generic_db.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/actress/actress_nvku_cache.dart';
import 'package:moyi/actress/actress_nvku_page.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/whos_local_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir =
    '/home/hatch/workspace/moyi_javdb_gate_topbar_20261126/preview';

/// 空影视库服务（与入口恢复测试同款假服务）。
class _EmptyFilmService extends FilmLibraryService {
  _EmptyFilmService({required super.database});

  @override
  Future<FilmLibraryOpenResult> open() async {
    return const FilmLibraryOpenResult(
      dbPath: '/fake/MYTV/db/女优库.db',
      displayPath: 'MYTV/db/女优库.db',
      strict: true,
      total: 0,
      schema: GenericDbSchema(tables: [], fingerprint: 'test'),
      domain: '',
    );
  }
}

ThemeData _testTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settleReal(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shoot(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String name,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
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
  TestWidgetsFlutterBinding.ensureInitialized();

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

  late LocalStore store;
  late MemoryActressDatabase db;

  // 绑定 / 索引加载是真异步 IO，必须在 setUp（真异步区）里
  // 做完——放进 testWidgets 的 FakeAsync 区里永远等不回来
  // （与入口恢复测试同款分工）。
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NvkuEntryCache.clearForTest();
    store = LocalStore(await SharedPreferences.getInstance());
    db = MemoryActressDatabase();
    await ActressMytvBind.instance.ensureBound();
    await WhosLocalLibrary.shared.ensureLoaded();
  });

  tearDown(() => store.dispose());

  Future<GlobalKey> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: _testTheme(),
          home: ActressNvkuPage(
            repository: FixtureRepository(),
            store: store,
            database: db,
            filmService: _EmptyFilmService(database: db),
          ),
        ),
      ),
    );
    await _settleReal(tester);
    return key;
  }

  // 一测一张：调过 toImage 的测试在收尾时会挂起（既有预览
  // 测试通病），弹层图拆到 actress_topbar_sheet_preview_test
  // 单独一张，靠 PNG 落盘判成败。
  testWidgets('预览 顶栏齿轮主页', (tester) async {
    final key = await pumpPage(tester);
    expect(find.byKey(const ValueKey('nvku-open-film-library')), findsNothing);
    expect(find.text('影片库'), findsNothing);
    expect(find.byKey(const ValueKey('nvku-manage-open')), findsOneWidget);
    await _shoot(tester, key, 'actress_topbar_gear_home');
  });
}
