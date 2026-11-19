// JSON 导入批预览截图：只做测试内截图，不改业务代码。
// ①导入分流多出“导入 JSON” ②导入区 JSON 站 ③AV 详情 332 选集
// ④翻页中一帧（+ 号固定） ⑤底部栏“网盘”。
// 数据说明：②③用测试夹具里的真 AV 文件（test/fixtures/json_list/av.json，
// 332 个频道为真数据）；封面为空占位；图标在测试环境可能渲染为方块。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/json_list_import.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/py_contract.dart';
import 'package:moyi/site_import_flow.dart';
import 'package:moyi/source_picker_sheet.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
      subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: 'PreviewCJK'),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
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

Future<void> _shoot(
  WidgetTester tester, {
  required String name,
  required String label,
  required Widget screen,
  Future<void> Function()? interact,
  Duration? afterInteract,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  appThemeNotifier.value = AppThemeMode.purpleNeon;
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
                Expanded(child: screen),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  if (interact != null) {
    await interact();
    if (afterInteract != null) {
      // 翻页中一帧：只走指定时长，不等动画跑完。
      await tester.pump(afterInteract);
    } else {
      await _settle(tester);
    }
  }
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
  print('preview landed: $name');
}

Future<LocalStore> _previewStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

/// AV 详情只走这一份：夹具真数据拆出的 332 集。
/// 注意：文件读 + 解析必须放 setUpAll（真 async）——testWidgets
/// 体内是 FakeAsync，File.readAsBytes 在里面永远等不到完成回调。
class _AvDetailRepository extends FixtureRepository {
  _AvDetailRepository(this.avDetail);

  final DramaDetail avDetail;

  @override
  Future<DramaDetail> detail(Drama drama) async => avDetail;

  // 推荐区走 catalog：本预览站没有目录数据，返回空让推荐区
  // 按“无数据时隐藏”收起，别把夹具默认的合成剧画进来。
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage(const []);
}

late DramaDetail _avDetailData;

Future<void> _loadAvDetail() async {
  final bytes = await File('test/fixtures/json_list/av.json').readAsBytes();
  final parsed = parseJsonListBytes(bytes);
  final row = parsed.items.single;
  final drama = Drama(
    id: 'jsonlist:av:${row['vod_id']}',
    source: 'jsonlist:av',
    sourceId: '${row['vod_id']}',
    title: '${row['vod_name']}',
    description: '${row['vod_content'] ?? ''}',
  );
  _avDetailData = PyContract.detailFromResult('jsonlist:av', drama, {
    'list': [row],
  });
}

const _pickerGroups = [
  SourcePickerGroup(
    title: '内置短剧',
    entries: [
      SourcePickerEntry(id: 'all', name: '全部站源', deletable: false),
      SourcePickerEntry(id: 'hongguo', name: '红果短剧'),
    ],
    zone: SourcePickerGroup.zoneBuiltin,
  ),
  SourcePickerGroup(
    title: '内置影视',
    entries: [SourcePickerEntry(id: 'missav', name: '🔞MissAV')],
    zone: SourcePickerGroup.zoneBuiltin,
  ),
  SourcePickerGroup(
    title: '导入',
    entries: [
      SourcePickerEntry(id: 'jsonlist:av', name: '🔞AV'),
      SourcePickerEntry(id: 'jsonlist:hsck6', name: '🔞hsck·国产视频'),
      SourcePickerEntry(id: 'jsonlist:hsck5', name: '🔞hsck·动漫剧情'),
    ],
    zone: SourcePickerGroup.zoneImport,
  ),
  SourcePickerGroup(
    title: '导入配置',
    entries: [SourcePickerEntry(id: 'jsonlist:live', name: '直播')],
    zone: SourcePickerGroup.zoneImport,
  ),
];

Widget _openButton(String label, VoidCallback onPressed) => Scaffold(
  body: Center(
    child: FilledButton(onPressed: onPressed, child: Text(label)),
  ),
);

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.text('打开站点列表'));
  await tester.pumpAndSettle();
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
    await _loadAvDetail();
  });

  testWidgets('预览 导入分流新增导入JSON', (tester) async {
    await _shoot(
      tester,
      name: 'preview_json_import_choice',
      label: '① 导入分流：新增“导入 JSON”一项（选 TVBox 视频列表 .json 文件）',
      screen: _openButton('打开导入分流', () {
        showDialog(
          context: tester.element(find.text('打开导入分流')),
          builder: (_) => const SiteImportChoiceDialog(),
        );
      }),
      interact: () async {
        await tester.tap(find.text('打开导入分流'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('预览 导入区JSON站', (tester) async {
    await _shoot(
      tester,
      name: 'preview_json_import_zone',
      label: '② 导入区：JSON 站（🔞AV / 🔞hsck·国产视频 / 直播）已进导入区',
      screen: _openButton('打开站点列表', () {
        showSitePickerDialog(
          tester.element(find.text('打开站点列表')),
          sectionName: '片库',
          currentId: 'jsonlist:av',
          groups: _pickerGroups,
          onImport: () async {},
          enableZoneFlip: true,
          initialZoneIndex: 1,
        );
      }),
      interact: () async => _openPicker(tester),
    );
  });

  testWidgets('预览 AV详情332选集', (tester) async {
    final store = await _previewStore();
    // 按真导入流程登记：不登记时 DetailScreen 的 allowsSource
    // 拦住未注册的源 id，页内只出“当前用户无权访问”而不是选集。
    await store.syncImportedSites([
      ImportedSiteRecord(
        id: 'jsonlist:av',
        name: '🔞AV',
        type: ImportedSiteRecord.typeJsonList,
        fileName: 'jsonlist_av.py',
        contentHash: 'preview',
        ext: '{"path": "preview/av.json", "name": "🔞AV"}',
      ),
    ]);
    final detail = _avDetailData;
    expect(detail.episodes.length, 332);
    await _shoot(
      tester,
      name: 'preview_json_detail_av',
      label: '③ AV 详情：332 个频道做选集（真数据，封面占位）',
      screen: DetailScreen(
        drama: detail.drama,
        repository: _AvDetailRepository(detail),
        store: store,
      ),
      interact: () async {
        // 选集默认折叠在“选集 · 332 集”栏里：先点展开出选集格，
        // 再往上滚 300 让格子进画面；有界 pump——详情页有常驻动画，
        // pumpAndSettle 在这里永不返回（详情页测试同款 settleOperations）。
        await tester.tap(find.text('展开'));
        await _settle(tester);
        await tester.drag(find.byType(DetailScreen), const Offset(0, -300));
        await _settle(tester);
      },
    );
  });

  testWidgets('预览 翻页中一帧', (tester) async {
    await _shoot(
      tester,
      name: 'preview_json_flip_mid',
      label: '④ 翻页中：导入区正翻入，右上角 + 号固定在顶栏不动',
      screen: _openButton('打开站点列表', () {
        showSitePickerDialog(
          tester.element(find.text('打开站点列表')),
          sectionName: '片库',
          currentId: 'all',
          groups: _pickerGroups,
          onImport: () async {},
          enableZoneFlip: true,
        );
      }),
      interact: () async {
        await _openPicker(tester);
        await tester.tap(
          find.byKey(const ValueKey('site-picker-zone-import')),
        );
        // 先 pump 一帧让 AnimatedSwitcher 启动翻页，再由
        // afterInteract 的 160ms 把动画推到一半；否则 160ms
        // 在动画启动前就耗掉了，截到的是翻页前的静止帧。
        await tester.pump();
      },
      // 320ms 翻页走到一半时截：新页应已转出一半角度、旧页正绕边走。
      afterInteract: const Duration(milliseconds: 160),
    );
  });

  testWidgets('预览 底部栏网盘', (tester) async {
    const entries = [
      (LucideIcons.clapperboard, '片库'),
      (LucideIcons.tv, '直播'),
      (LucideIcons.bookHeadphones, '听读'),
      (LucideIcons.hardDrive, '网盘'),
      (LucideIcons.layoutGrid, '小程序'),
      (LucideIcons.user, '我的'),
      (LucideIcons.users, '演员库'),
      (LucideIcons.gamepad2, '游戏区'),
    ];
    await _shoot(
      tester,
      name: 'preview_local_disk_tab',
      label: '⑤ 底部标签：“多媒体”已改名“网盘”，图标为硬盘',
      screen: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: NeonCapsuleBar(
          entries: entries,
          index: 3,
          onSelect: (_) {},
          onCenter: () {},
          centerAfter: 3,
          tabKeyPrefix: 'shell-tab',
          centerKey: 'shell-center',
        ),
      ),
    );
  });
}
