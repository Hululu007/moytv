// 详情页信息卡 + 演员卡片排 + 剧照区（2026-11-26 照 AvPlay
// 详情页截图补）：
// - 信息卡只列真有字段（番号/发行日期/长度/制作商），评分不出现；
// - 演员区是照片卡（键 cast-<名字>），PESS-012 真值演员出现；
// - 剧照区带「全部 N >」，stills 为空时整区不显示；
// - 普通作品（无番号/无附加信息/无剧照）不显示信息卡与剧照区。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _EmptyDetailRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async =>
      DramaDetail(drama, const []);
}

const _drama = Drama(
  id: 'chaoliu:PESS-012',
  source: 'chaoliu',
  title: 'PESS-012 样本影片',
  category: '成人影片',
  onlineDate: '2024-06-15',
  tags: ['PESS-012'],
  episodes: 1,
);

Future<void> _pumpDetail(
  WidgetTester tester, {
  required Drama drama,
  DramaDetail? initialDetail,
  bool waitForCard = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  // 手机竖屏尺寸：走窄屏单列分支（宽屏是电视分栏布局）。
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = LocalStore(await SharedPreferences.getInstance());
  await tester.pumpWidget(
    MaterialApp(
      home: DetailScreen(
        drama: drama,
        repository: _EmptyDetailRepository(),
        store: store,
        initialDetail: initialDetail,
      ),
    ),
  );
  // 详情落地是真异步（仓库回空集 → 落 initialDetail），先等
  // 集数出来；信息卡随后随 _detail 一起出现。
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final ready = waitForCard
        ? find.byKey(const ValueKey('detail-info-card')).evaluate().isNotEmpty
        : find.text('第1集').evaluate().isNotEmpty;
    if (ready) break;
  }
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUpAll(() {
    // 潮流是 py 导入站：真机靠启动登记进 importedSites，详情
    // 页的 allowsSource 门才放行；测试里补登（与
    // detail_cast_row_test 同口径），完后摘掉。
    SourceSite.importedSites['chaoliu'] = const SourceSite(
      'chaoliu',
      '潮流',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originImport,
      importType: 'py',
    );
    SourceSite.importedSites['fixture'] = const SourceSite(
      'fixture',
      '样本',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originImport,
      importType: 'py',
    );
  });

  tearDownAll(() {
    SourceSite.importedSites.remove('chaoliu');
    SourceSite.importedSites.remove('fixture');
  });

  testWidgets('信息卡/演员卡/剧照区齐全且只放真数据', (tester) async {
    final initial = DramaDetail(
      _drama,
      [
        Episode({'id': 'x', 'title': '正片', 'direct': true}, 1),
      ],
      stills: [
        for (var i = 1; i <= 5; i++) 'https://img.example.com/still$i.jpg',
      ],
      tags: const [
        DetailTag(id: '秘书', name: '秘书'),
        DetailTag(id: '巨乳', name: '巨乳'),
      ],
      extraInfo: const [
        ('长度', '150 分钟'),
        ('制作商', '示例片商'),
      ],
    );
    await _pumpDetail(tester, drama: _drama, initialDetail: initial);

    final infoCard = find.byKey(const ValueKey('detail-info-card'));
    expect(infoCard, findsOneWidget);
    expect(
      find.descendant(of: infoCard, matching: find.text('番号：')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: infoCard, matching: find.text('PESS-012')),
      findsOneWidget,
    );
    // 发行日期不在 extraInfo 里 → 回落 Drama.onlineDate。
    expect(
      find.descendant(of: infoCard, matching: find.text('2024-06-15')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: infoCard, matching: find.text('150 分钟')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: infoCard, matching: find.text('示例片商')),
      findsOneWidget,
    );
    // 评分没有真数据：整页不许出现评分行/评分字样。
    expect(find.textContaining('评分'), findsNothing);

    // 演员卡片排：PESS-012 真值两位演员各一张卡（番号元数据
    // 索引真异步加载，轮询等卡出现）。
    for (var i = 0; i < 40; i++) {
      if (find
          .byKey(const ValueKey('cast-岸和水'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('cast-岸和水')), findsOneWidget);
    expect(find.byKey(const ValueKey('cast-佐々木あき')), findsOneWidget);

    // 相关分类胶囊还在（标签行）。
    expect(find.text('秘书'), findsOneWidget);

    // 剧照区：标题 + 全部 N（手动拖拽滚到该区——scrollUntilVisible
    // 与区内嵌套横滑列表犯冲）。
    for (var i = 0; i < 6; i++) {
      if (find
          .byKey(const ValueKey('detail-stills-section'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(0, -400),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      find.byKey(const ValueKey('detail-stills-section')),
      findsWidgets,
    );
    expect(find.text('剧照'), findsWidgets);
    expect(find.text('全部 5 >'), findsOneWidget);
  });

  testWidgets('普通作品不显示信息卡与剧照区', (tester) async {
    const plain = Drama(
      id: 'plain-1',
      source: 'fixture',
      title: '普通剧集',
      episodes: 1,
    );
    final initial = DramaDetail(plain, [
      Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
    ]);
    await _pumpDetail(
      tester,
      drama: plain,
      initialDetail: initial,
      waitForCard: false,
    );
    // 滑到底也没有这两块。
    for (var i = 0; i < 4; i++) {
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(0, -500),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byKey(const ValueKey('detail-info-card')), findsNothing);
    expect(
      find.byKey(const ValueKey('detail-stills-section')),
      findsNothing,
    );
  });
}
