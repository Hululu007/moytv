// 详情页跨站选线区预览截图：只做测试内截图，不改业务代码。
// 假数据说明：探活结果（版本、线路名）、简介文字均为测试内合成；
// 海报封面为空占位（仓库 cover 返回空）；图标在测试环境渲染为方块。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/ui_style.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

const _drama = Drama(
  id: 'x:1',
  source: 'hongguo',
  title: 'HMN-927 测试片',
  description:
      '预览占位简介：本段文字为测试内合成的简介内容，用来占简介区的位置，说明选线区在选集区之后、简介之前。简介区最多显示三行，点展开简介可看全文。',
);

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  TextStyle? cjk(TextStyle? style) => style?.copyWith(fontFamily: 'PreviewCJK');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjk(base.appBarTheme.titleTextStyle),
    ),
    chipTheme: base.chipTheme.copyWith(labelStyle: cjk(base.chipTheme.labelStyle)),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) =>
              cjk(base.filledButtonTheme.style?.textStyle?.resolve(states)),
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: base.elevatedButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) =>
              cjk(base.elevatedButtonTheme.style?.textStyle?.resolve(states)),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) =>
              cjk(base.textButtonTheme.style?.textStyle?.resolve(states)),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) =>
              cjk(base.outlinedButtonTheme.style?.textStyle?.resolve(states)),
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

/// 测试里 JarBridge._specs 默认是空的（应用启动时的内置注册只在
/// Android 上跑），按内置登记直接注册探活要用的三家站源，否则
/// 六行全判成“未接入”。只注 id 与登记信息，不走平台通道。
void _registerProbeSpecs() {
  const wanted = {'zakav01', 'ZakaMissav', 'ZakaJable'};
  for (final builtin in zakatvBuiltinSites) {
    if (!wanted.contains(builtin.key)) continue;
    JarBridge.register(
      JarSiteSpec(
        siteId: JarSiteSpec.siteIdFor(zakatvJarId, builtin.key),
        configId: zakatvJarId,
        name: builtin.name,
        className: builtin.className,
        jarUrl: '',
        jarMd5: zakatvJarMd5,
        ext: builtin.ext,
      ),
    );
  }
}

void _unregisterProbeSpecs() {
  for (final key in ['zakav01', 'ZakaMissav', 'ZakaJable']) {
    JarBridge.unregister(JarSiteSpec.siteIdFor(zakatvJarId, key));
  }
}

DramaDetail _detailWithFlags(String id, List<String> flags) {
  final drama = Drama(id: id, source: 's', title: id);
  return DramaDetail(drama, [
    for (var i = 0; i < flags.length; i++)
      Episode({
        'id': 'p$i',
        'title': '${flags[i]} · 正片',
        'flag': flags[i],
      }, i + 1),
  ]);
}

/// 详情页预览仓库：封面返回空（避开封面失败延迟重试），搜索与
/// 探活详情走测试内合成数据，本片详情走 fixture（2 集）。
class _PreviewRepository extends RouteRepository {
  Map<String, List<Drama>> searchResults = {};
  Map<String, DramaDetail> detailResults = {};

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    final items = <Drama>[];
    for (final source in sources) {
      items.addAll(searchResults[source] ?? const []);
    }
    return CatalogPage(items);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final fixed = detailResults[drama.id];
    if (fixed != null) return fixed;
    return super.detail(drama);
  }
}

_PreviewRepository _repositoryWithAv01() {
  return _PreviewRepository()
    ..searchResults = {
      'jar:zakatv:zakav01': [
        const Drama(
          id: 'hmn-927',
          source: 'jar:zakatv:zakav01',
          title: 'hmn-927',
        ),
        const Drama(
          id: 'hmn-927-lada',
          source: 'jar:zakatv:zakav01',
          title: 'hmn-927-lada',
        ),
      ],
    }
    ..detailResults = {
      'hmn-927': _detailWithFlags('hmn-927', ['线路1', '线路2']),
      'hmn-927-lada': _detailWithFlags('hmn-927-lada', ['线路1']),
    };
}

/// 把选线区顶对到标签条下方约 175px，上露选集区、下露简介标题。
Future<void> _frameSection(WidgetTester tester) async {
  final section = find.byKey(const ValueKey('crosssite-section'));
  await tester.scrollUntilVisible(section, 200);
  await tester.pump();
  final top = tester.getTopLeft(section).dy;
  const targetTop = 175.0;
  final delta = top - targetTop;
  if (delta.abs() > 2) {
    await tester.drag(find.byType(CustomScrollView).first, Offset(0, -delta));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _captureDetail(
  WidgetTester tester, {
  required String name,
  required String label,
  required _PreviewRepository repository,
  required Future<void> Function() interact,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const frameChannel = MethodChannel('moyi/frame_extractor');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(frameChannel, (_) async => null);
  addTearDown(() => messenger.setMockMethodCallHandler(frameChannel, null));
  _registerProbeSpecs();
  addTearDown(_unregisterProbeSpecs);
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
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
                Expanded(
                  child: DetailScreen(
                    drama: _drama,
                    repository: repository,
                    store: store,
                    playerFactory: () =>
                        Player(platformPlayer: ScriptedPlayer()),
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
  await interact();
  await _settle(tester);
  await _frameSection(tester);
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

  // 混合态：AV01 已探出版本与线路；MissAV 懒查未点，显示“点击查询”；
  // Jable 点过懒查、探过无线标 ×；AVDB/JavMenu/MemoJav 三行“未接入”。
  // 注：固定 6 家里只有 AV01 一家自动探活，× 行只能来自点过的懒查行，
  // 故 Jable 点过、MissAV 保持未点，两态同屏。
  testWidgets('预览 跨站选线 混合态', (tester) async {
    final repository = _repositoryWithAv01()
      ..searchResults['jar:zakatv:ZakaJable'] = [];
    await _captureDetail(
      tester,
      name: 'crosssite_mixed',
      label: '预览 · 假探活数据 · AV01 已探出版本线路 · Jable 探过无线标叉 · 封面为占位',
      repository: repository,
      interact: () async {
        // 先展开选集网格，让选集区本体入画。
        await tester.tap(find.text('展开'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('crosssite-rowtap-jable')),
          200,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('crosssite-rowtap-jable')));
      },
    );
  });

  // 懒查后：MissAV/Jable 点过懒查后也探出版本与线路。
  testWidgets('预览 跨站选线 懒查后', (tester) async {
    final repository = _repositoryWithAv01()
      ..searchResults['jar:zakatv:ZakaMissav'] = [
        const Drama(
          id: 'hmn-927',
          source: 'jar:zakatv:ZakaMissav',
          title: 'hmn-927',
        ),
      ]
      ..searchResults['jar:zakatv:ZakaJable'] = [
        const Drama(
          id: 'hmn-927',
          source: 'jar:zakatv:ZakaJable',
          title: 'hmn-927',
        ),
      ];
    await _captureDetail(
      tester,
      name: 'crosssite_probed',
      label: '预览 · 假探活数据 · MissAV/Jable 点过懒查后也出线路 · 封面为占位',
      repository: repository,
      interact: () async {
        // 先展开选集网格，让选集区本体入画。
        await tester.tap(find.text('展开'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('crosssite-rowtap-missav')),
          200,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('crosssite-rowtap-missav')));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('crosssite-rowtap-jable')),
          200,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('crosssite-rowtap-jable')));
      },
    );
  });
}
