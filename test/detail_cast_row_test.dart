// 详情页头区演员行 + 一集不画选集 + 自动写入开关隐藏（2026-11-24 用户令）。
// PESS-012 真值：who's 映射里是佐々木あき；岸和水；420 码无此番号。
// 演员标签“佐佐木明希、岸和水”是蜘蛛 vod_actor 原样，头像行出现后
// 标签行应把这一片藏掉（岸和水精确命中即整片去掉）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir =
    '/home/hatch/workspace/actress_json_builtin_20261123/preview';

class _PessRepository extends FixtureRepository {
  static const pess = Drama(
    id: 'chaoliu:PESS-012',
    source: 'chaoliu',
    title: 'PESS-012',
    category: '成人影片',
    episodes: 1,
  );

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    return DramaDetail(
      drama,
      [Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1)],
      tags: const [
        DetailTag(id: '佐佐木明希、岸和水', name: '佐佐木明希、岸和水'),
      ],
    );
  }
}

ThemeData _theme() {
  final base = ThemeData.dark();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _pumpPessDetail(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _PessRepository();
  final store = LocalStore(await SharedPreferences.getInstance());
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(),
      home: DetailScreen(
        drama: _PessRepository.pess,
        repository: repository,
        store: store,
      ),
    ),
  );
  // 索引加载（26MB gz 解压 + 建索引约 3–5 秒）要放行真实异步。
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(seconds: 6));
  });
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.text('岸和水').evaluate().isNotEmpty) break;
  }
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUpAll(() async {
    // 潮流是 py 导入站：真机上启动时由 builtin_py_sites 登记进
    // SourceSite.importedSites，详情页的 allowed 门（allowsSource）
    // 才放行；测试里没走启动登记，这里补登一个最小登记，否则整页
    // 被“当前用户无权访问”挡住、演员行根本画不出来。sectionVideo
    // 是潮流的真实分区（视频站、不是短剧站），_isShortDramaSource
    // 不会把它当短剧站、演员行不受影响。
    SourceSite.importedSites['chaoliu'] = const SourceSite(
      'chaoliu',
      '潮流',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originImport,
      importType: 'py',
    );
    try {
      final bytes = File(
        '/home/hatch/workspace/boxplayer/src/assets/fonts/NotoSansCJKsc-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  tearDownAll(() {
    SourceSite.importedSites.remove('chaoliu');
  });

  testWidgets('一集不画选集、自动写入开关隐藏、演员头像行出现且标签去重', (
    tester,
  ) async {
    await _pumpPessDetail(tester);
    expect(find.text('选集 · 1 集'), findsNothing);
    expect(find.text('自动写入站点库'), findsNothing);
    expect(find.text('岸和水'), findsOneWidget);
    expect(find.text('佐々木あき'), findsOneWidget);
    expect(find.text('佐佐木明希、岸和水'), findsNothing);
    expect(find.text('推荐视频'), findsOneWidget);
  });

  testWidgets('预览：PESS-012 详情页头区演员行', (tester) async {
    final key = GlobalKey();
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PessRepository();
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: _theme(),
          home: DetailScreen(
            drama: _PessRepository.pess,
            repository: repository,
            store: store,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 6));
    });
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('岸和水').evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 200));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/detail_cast_row_pess012.png').writeAsBytesSync(bytes);
  });
}
