// 演员库齿轮管理弹层预览（2026-11-26 23:00 用户令配套图）：
// 点顶栏设置齿轮打开管理弹层——只剩数据库管理 / 重新加载
// 数据库两行，「影片库」行已按令删除。PNG 落本工作树
// preview/actress_topbar_gear_sheet.png。台子与主页预览
// （actress_topbar_gear_preview_test）同款，拆单文件是因为
// toImage 后测试收尾会挂起，一测一张、靠 PNG 落盘判成败。
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NvkuEntryCache.clearForTest();
    store = LocalStore(await SharedPreferences.getInstance());
    db = MemoryActressDatabase();
    await ActressMytvBind.instance.ensureBound();
    await WhosLocalLibrary.shared.ensureLoaded();
  });

  tearDown(() => store.dispose());

  testWidgets('预览 齿轮管理弹层', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('nvku-manage-open')));
    await _settleReal(tester, rounds: 4);
    expect(find.text('数据库管理'), findsOneWidget);
    expect(find.text('重新加载数据库'), findsOneWidget);
    expect(find.text('影片库'), findsNothing);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/actress_topbar_gear_sheet.png').writeAsBytesSync(bytes);
  });
}
