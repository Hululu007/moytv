// json 内置两页接线预览截图（2026-11-23）：只做测试内截图，不改业务代码。
// 假数据说明：片库详情页的标题/简介均为测试内合成；海报是纯色占位块，
// 绝非真实封面；演员来自内置 who's 索引（003T28-262 真值：絵色千佳，
// 不在 420 码里，纯 json 路）；演员库详情页的星冬香 1 部库内作品是
// 测试种子（TST-1），其余 JUR-487 / JUVR-316 是 json 补的真值。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/code_meta_section.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/actress_json_builtin_20261123/preview';

ThemeData _previewTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
}

/// 给索引留足真实加载时间（26MB gz 解压 + 33 万行建索引约 3–5 秒）：
/// 假时间 pump 等不到它，必须用 runAsync 放行真实异步。
Future<void> _waitForIndex(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(seconds: 6));
  });
  await tester.pump();
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required Widget child,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _previewTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
                child,
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  await _waitForIndex(tester);
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

/// 片库详情页样子（简化版）：标题 + 纯色海报占位 + 简介 + 演员区。
Widget _detailSnippet({required Drama drama}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Text(
          drama.title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          height: 180,
          width: double.infinity,
          color: const Color(0xFF7C4DFF),
          alignment: Alignment.center,
          child: const Text(
            '海报占位（纯色替身）',
            style: TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(
          '剧情简介（假数据）：这是一段测试用的简介文字，详情页其余部分一个字没动。',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
      ),
      CodeMetaSection.forDrama(drama),
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Text(
          '播放线路（假数据）：线路一 · 线路二',
          style: TextStyle(fontSize: 13),
        ),
      ),
    ],
  );
}

void main() {
  setUpAll(() async {
    try {
      // 用 boxplayer 的全量 Noto Sans CJK（44,810 字形，含平假名/片假名），
      // 旧 cjk_subset.ttf 没有假名，演员名会缺字只剩汉字。
      final bytes = File(
        '/home/hatch/workspace/boxplayer/src/assets/fonts/NotoSansCJKsc-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  testWidgets('片库详情页演员区：纯 json 演员（不在 420 码里）', (tester) async {
    // 003T28-262 只在 who's 演员映射里（絵色千佳），420 码没有它：
    // 演员区应出现絵色千佳，来源小字标 who's 索引，无导演行。
    await _capture(
      tester,
      name: 'json_actor_section',
      label: '假数据·003T28-262：演员絵色千佳来自 who\'s 索引（不在 420 码里），无导演、无头像回落首字圆圈',
      child: _detailSnippet(
        drama: const Drama(
          id: 'json:whos:003t28-262',
          source: 'whos',
          title: '003T28-262 测试标题',
        ),
      ),
    );
  });

  testWidgets('演员库详情页：库内 1 部 + json 补 3 部', (tester) async {
    // 星冬香：库里只给 1 部测试作品（TST-1），json 索引里她另有
    // JUR-487 / JUVR-316 / ROE-355-CHINESE-SUBTITLE，详情页应全出。
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final db = MemoryActressDatabase();
    final person = (await db.upsertRosterPerson(
      RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: 'id-星冬香',
        name: '星冬香',
        sex: 'female',
      ),
    ))!;
    await db.upsertWorks(person.localId, const [
      RosterFilm(code: 'TST-1'),
    ], site: ActressRosterSourceId.chaoliu.name);
    await _capture(
      tester,
      name: 'actress_detail_json_works',
      label: '星冬香：TST-1 是库内作品，JUR-487 / JUVR-316 是 json 索引补的作品（封面为网络图，测试里不加载只留占位）',
      child: SizedBox(
        height: 780,
        child: ActressDetailPage(
          localId: person.localId,
          repository: FixtureRepository(),
          store: store,
          database: db,
        ),
      ),
    );
  });
}
