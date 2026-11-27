// 问题 6（2026-11-27）：片库站点列表里的「115网盘」站
// （cloud:pan115）文件夹点了没反应。复现/回归：片库入口点
// 文件夹卡应逐层下钻（请求带 folderId 作 category、回来渲
// 染下一层）、返回逐层退、底层 MP4 点按走详情起播链。
// 条目形状照 CloudDriveEngine._toCatalogPage 的真实产出：
// 文件夹 kind='folder' + folderId、id='<盘>:<文件id>'。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Drama _folder(String folderId, String title) => Drama(
  id: 'pan115:$folderId',
  source: 'cloud:pan115',
  title: title,
  description: '文件夹',
  kind: 'folder',
  folderId: folderId,
);

Drama _video(String fileId, String title) => Drama(
  id: 'pan115:$fileId',
  source: 'cloud:pan115',
  title: title,
  description: '视频',
  kind: 'video',
  episodes: 1,
);

class _CloudRepository extends FixtureRepository {
  final catalogCategories = <String>[];

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    requests.add(source);
    catalogCategories.add(category);
    final items = switch (category) {
      'folderB' => [_video('fileB', '影片乙.mp4')],
      'folderA' => [
        _folder('folderB', '子文件夹'),
        _video('fileA', '影片甲.mp4'),
      ],
      _ => [_folder('folderA', '外层文件夹'), _video('fileRoot', '根目录影片.mp4')],
    };
    return CatalogPage(items, page: page, hasMore: false);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'source': 'cloud:pan115',
      'hiddenSites': '[]',
      'appThemeMode': 'purpleNeon',
    });
    store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    SourceSite.cloudDriveSites['cloud:pan115'] = SourceSite(
      'cloud:pan115',
      '115网盘',
      '网盘站源',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    addTearDown(() => SourceSite.cloudDriveSites.remove('cloud:pan115'));
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  Future<void> pumpHome(WidgetTester tester, _CloudRepository repository) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: repository, store: store),
      ),
    );
  }

  Future<void> flushLoads(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('片库 115 站：文件夹逐层下钻、逐层返回、MP4 进详情', (tester) async {
    final repository = _CloudRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);

    // 根目录：文件夹卡与根目录影片都在。
    expect(find.text('外层文件夹'), findsWidgets);
    expect(find.text('根目录影片.mp4'), findsWidgets);

    // 点第一层文件夹 → 请求 category=folderA、渲染第二层。
    await tester.tap(find.text('外层文件夹').first);
    await flushLoads(tester);
    expect(repository.catalogCategories, contains('folderA'));
    expect(find.text('子文件夹'), findsWidgets);
    expect(find.text('影片甲.mp4'), findsWidgets);
    expect(find.text('外层文件夹'), findsWidgets); // 面包屑里还有它

    // 点第二层文件夹 → 请求 category=folderB、渲染第三层。
    await tester.tap(find.text('子文件夹').first);
    await flushLoads(tester);
    expect(repository.catalogCategories, contains('folderB'));
    expect(find.text('影片乙.mp4'), findsWidgets);

    // 返回上一级 → 回到 folderA 层。
    await tester.tap(find.byTooltip('返回上一级'));
    await flushLoads(tester);
    expect(find.text('影片甲.mp4'), findsWidgets);
    expect(find.text('影片乙.mp4'), findsNothing);

    // 底层 MP4 点按 → 进详情（不是没反应、不是报错面板）。
    await tester.tap(find.text('影片甲.mp4').first);
    await flushLoads(tester);
    expect(repository.detailCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('文件夹被无 kind 的元数据更新合并后，点按仍下钻不进详情', (
    tester,
  ) async {
    final repository = _CloudRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('外层文件夹'), findsWidgets);

    // 详情/封面链路重建的条目不带 kind：经 catalogUpdates 合并
    // 进当前列表后，文件夹性不许被冲掉（问题 6 的 merge 缺口）。
    repository.catalogUpdates.publish(
      const Drama(
        id: 'pan115:folderA',
        source: 'cloud:pan115',
        title: '外层文件夹',
        cover: 'https://t/cover.jpg',
      ),
    );
    await flushLoads(tester);

    await tester.tap(find.text('外层文件夹').first);
    await flushLoads(tester);
    expect(repository.catalogCategories, contains('folderA'));
    expect(find.text('子文件夹'), findsWidgets);
    expect(repository.detailCalls, 0);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
