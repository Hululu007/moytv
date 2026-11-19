// 听书阅读合并（用户 2026-11-18 令）：桌面一个“听读”图标、旧顺序
// 迁移、开始菜单同口径合并、一级分类（听书/阅读）+ 二级分类（各站
// 自有分类）、书架/历史/下载数据键与入口不动。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/audio_history.dart';
import 'package:moyi/content_models.dart';
import 'package:moyi/content_zone_binding.dart';
import 'package:moyi/content_zone_screen.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/home_zone.dart';
import 'package:moyi/listen_read_page.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/novel_source_store.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _FakeSource extends ContentSource {
  _FakeSource(this._id, this._name, this._section, this._categories);

  final String _id;
  final String _name;
  final ContentSection _section;
  final List<ContentCategory> _categories;

  @override
  String get id => _id;
  @override
  String get name => _name;
  @override
  ContentSection get section => _section;

  @override
  Future<List<ContentCategory>> categories() async => _categories;

  @override
  Future<ContentPage> catalog(String categoryId, int page) async => ContentPage(
    items: [ContentBook(id: '$_id-book', title: '$_name-作品')],
  );

  @override
  Future<ContentPage> search(String keyword, int page) async =>
      const ContentPage(items: []);

  @override
  Future<ContentBookDetail> detail(String bookId) async => ContentBookDetail(
    book: ContentBook(id: bookId, title: '$_name-作品'),
    chapters: const [],
  );
}

final _fakeSources = <ContentSource>[
  _FakeSource('fake_audio', '听书甲', ContentSection.audio, [
    const ContentCategory(id: 'c1', name: '听书甲-言情'),
    const ContentCategory(id: 'c2', name: '听书甲-玄幻'),
  ]),
  _FakeSource('fake_novel', '小说甲', ContentSection.novel, [
    const ContentCategory(id: 'n1', name: '小说甲-都市'),
    const ContentCategory(id: 'n2', name: '小说甲-仙侠'),
  ]),
];

List<ContentSource> _fakeProvider(ContentSection section) =>
    _fakeSources.where((source) => source.section == section).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('桌面图标合并与旧顺序迁移', () {
    test('默认表 9 个图标，听读占原来听书的位置（第二位）', () {
      expect(win7DesktopIcons.length, 9);
      expect(win7DesktopIcons[0], Win7WindowKind.mine);
      expect(win7DesktopIcons[1], Win7WindowKind.listenRead);
      expect(
        win7DesktopIcons.where((kind) => kind == Win7WindowKind.listenRead),
        hasLength(1),
      );
    });

    test('听读图标定义：标题、字形、渐变', () {
      const kind = Win7WindowKind.listenRead;
      expect(kind.title, '听读');
      // 与底部“听读”标签同一字形（书 + 耳机）。
      expect(kind.icon, LucideIcons.bookHeadphones);
      // 渐变两头：听书琥珀 + 阅读绿。
      expect(kind.iconGradient, const [Color(0xFFF59E0B), Color(0xFF15803D)]);
    });

    test('旧顺序含 audio+novel：并成一个听读、占先出现者位置，其余不动', () {
      final resolved = resolveDesktopIconOrder([
        'mine',
        'audio',
        'novel',
        'library',
        'live',
        'miniApp',
        'actress',
        'game',
        'multimedia',
        'kof',
      ]);
      expect(resolved.map((kind) => kind.name).toList(), [
        'mine',
        'listenRead',
        'library',
        'live',
        'miniApp',
        'actress',
        'game',
        'multimedia',
        'kof',
      ]);
    });

    test('旧顺序里 novel 在 audio 前面：听读占 novel 的位置', () {
      final resolved = resolveDesktopIconOrder([
        'novel',
        'mine',
        'audio',
        'library',
      ]);
      expect(resolved[0], Win7WindowKind.listenRead);
      expect(resolved[1], Win7WindowKind.mine);
      expect(resolved[2], Win7WindowKind.library);
      expect(
        resolved.where((kind) => kind == Win7WindowKind.listenRead),
        hasLength(1),
      );
    });

    test('只存过一个旧名：同样并成一个听读', () {
      for (final legacy in ['audio', 'novel']) {
        final resolved = resolveDesktopIconOrder(['mine', legacy, 'library']);
        expect(resolved[1], Win7WindowKind.listenRead);
        expect(
          resolved.where((kind) => kind == Win7WindowKind.listenRead),
          hasLength(1),
        );
      }
    });

    test('新旧名字混存：去重后只有一个听读', () {
      final resolved = resolveDesktopIconOrder([
        'mine',
        'listenRead',
        'audio',
        'novel',
        'library',
      ]);
      expect(
        resolved.where((kind) => kind == Win7WindowKind.listenRead),
        hasLength(1),
      );
      expect(resolved[1], Win7WindowKind.listenRead);
    });

    test('拖过的顺序迁移后存盘：下次读回仍是一个听读', () async {
      SharedPreferences.setMockInitialValues({
        desktopIconOrderKey: ['actress', 'novel', 'mine', 'audio', 'live'],
      });
      final order = await loadDesktopIconOrder();
      expect(order[0], Win7WindowKind.actress);
      expect(order[1], Win7WindowKind.listenRead);
      expect(order[2], Win7WindowKind.mine);
      expect(order[3], Win7WindowKind.live);
      await saveDesktopIconOrder(order);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(desktopIconOrderKey)!;
      expect(stored.where((name) => name == 'listenRead'), hasLength(1));
      expect(stored, isNot(contains('audio')));
      expect(stored, isNot(contains('novel')));
    });
  });

  group('一级分类：听书/阅读胶囊 + 二级分类取各站自有分类', () {
    testWidgets('胶囊顺序：听书在左、阅读在右（与原底部标签/桌面顺序一致）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenReadPage(
              zone: HomeZone.audio,
              onZoneSelected: (_) {},
              zoneBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pump();
      final audioLeft = tester
          .getTopLeft(find.byKey(const ValueKey('listenread-audio')))
          .dx;
      final novelLeft = tester
          .getTopLeft(find.byKey(const ValueKey('listenread-novel')))
          .dx;
      expect(audioLeft, lessThan(novelLeft));
      expect(find.text('听书'), findsOneWidget);
      expect(find.text('阅读'), findsOneWidget);
    });

    testWidgets('点胶囊切子区、只建当前子区的屏', (tester) async {
      final built = <HomeZone>[];
      HomeZone? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenReadPage(
              zone: HomeZone.audio,
              onZoneSelected: (zone) => selected = zone,
              zoneBuilder: (zone) {
                built.add(zone);
                return Text('区:${zone.name}');
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(built, [HomeZone.audio]);
      await tester.tap(find.byKey(const ValueKey('listenread-novel')));
      expect(selected, HomeZone.novel);
    });

    testWidgets('二级分类取本站分类：切子区后 chips 换成另一站的分类', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final binding = ContentZoneBinding(sourcesProvider: _fakeProvider);
      var zone = HomeZone.audio;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ListenReadPage(
                zone: zone,
                onZoneSelected: (next) => setState(() => zone = next),
                zoneBuilder: (current) => ContentZoneScreen(
                  section: current == HomeZone.audio
                      ? ContentSection.audio
                      : ContentSection.novel,
                  binding: binding,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('听书甲-言情'), findsOneWidget);
      expect(find.text('听书甲-玄幻'), findsOneWidget);
      expect(find.text('小说甲-都市'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('listenread-novel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('小说甲-都市'), findsOneWidget);
      expect(find.text('小说甲-仙侠'), findsOneWidget);
      expect(find.text('听书甲-言情'), findsNothing);
    });
  });

  group('开始菜单与窗口合并', () {
    Future<void> pumpWin7Home(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'source': 'huangdou',
        'hiddenSites': '[]',
        'appThemeMode': 'win7',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [homeRouteObserver],
          theme: AppThemeConfig.forTheme(AppThemeMode.win7).toThemeData(),
          home: HomeScreen(repository: FixtureRepository(), store: store),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Finder win7Key(String name) => find.byKey(ValueKey(name));

    Future<void> openStartMenu(WidgetTester tester) async {
      await tester.tap(win7Key('win7-start-button'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('桌面只有一个听读图标，点它开一个听读窗口', (tester) async {
      await pumpWin7Home(tester);
      expect(win7Key('win7-desktop-icon-listenRead'), findsOneWidget);
      expect(win7Key('win7-desktop-icon-audio'), findsNothing);
      expect(win7Key('win7-desktop-icon-novel'), findsNothing);
      await tester.tap(win7Key('win7-desktop-icon-listenRead'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<Text>(win7Key('win7-window-title')).data, '听读');
      expect(win7Key('win7-taskbar-entry-listenRead'), findsOneWidget);
      expect(find.byType(ContentZoneScreen), findsOneWidget);
    });

    testWidgets('窗口内胶囊切换子区：不另开窗口，任务栏仍一条', (tester) async {
      await pumpWin7Home(tester);
      await tester.tap(win7Key('win7-desktop-icon-listenRead'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<ContentZoneScreen>(find.byType(ContentZoneScreen))
            .section,
        ContentSection.audio,
      );
      await tester.tap(find.byKey(const ValueKey('listenread-novel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<ContentZoneScreen>(find.byType(ContentZoneScreen))
            .section,
        ContentSection.novel,
      );
      expect(tester.widget<Text>(win7Key('win7-window-title')).data, '听读');
      expect(win7Key('win7-taskbar-entry-listenRead'), findsOneWidget);
      expect(find.byType(ContentZoneScreen), findsOneWidget);
    });

    testWidgets('最小化后从任务栏恢复：仍停在切换后的子区', (tester) async {
      await pumpWin7Home(tester);
      await tester.tap(win7Key('win7-desktop-icon-listenRead'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('listenread-novel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 最小化回桌面，再点任务栏条目恢复：子区仍是阅读，不被
      // 窗口描述里记的听书站点 id 拨回去。
      await tester.tap(win7Key('win7-window-minimize'));
      await tester.pump();
      expect(win7Key('win7-desktop'), findsOneWidget);
      await tester.tap(win7Key('win7-taskbar-entry-listenRead'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<ContentZoneScreen>(find.byType(ContentZoneScreen)).section,
        ContentSection.novel,
      );
      expect(
        tester.widget<Text>(win7Key('win7-window-title')).data,
        '听读',
      );
    });

    testWidgets('开始菜单：听读组下听书/阅读两层，点阅读叶子进阅读子区', (tester) async {
      await pumpWin7Home(tester);
      await openStartMenu(tester);
      // 组顺序：片库 0、直播 1、听读 2。
      await tester.tap(win7Key('win7-tree-node-2'));
      await tester.pump();
      expect(win7Key('win7-tree-node-2-0'), findsOneWidget);
      expect(win7Key('win7-tree-node-2-1'), findsOneWidget);
      await tester.ensureVisible(win7Key('win7-tree-node-2-1'));
      await tester.tap(win7Key('win7-tree-node-2-1'));
      await tester.pump();
      await tester.ensureVisible(win7Key('win7-tree-node-2-1-0'));
      await tester.tap(win7Key('win7-tree-node-2-1-0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<Text>(win7Key('win7-window-title')).data, '听读');
      expect(
        tester
            .widget<ContentZoneScreen>(find.byType(ContentZoneScreen))
            .section,
        ContentSection.novel,
      );
      expect(win7Key('win7-taskbar-entry-listenRead'), findsOneWidget);
    });

    testWidgets('开始菜单：点听书叶子进听书子区', (tester) async {
      await pumpWin7Home(tester);
      await openStartMenu(tester);
      await tester.tap(win7Key('win7-tree-node-2'));
      await tester.pump();
      await tester.ensureVisible(win7Key('win7-tree-node-2-0'));
      await tester.tap(win7Key('win7-tree-node-2-0'));
      await tester.pump();
      await tester.ensureVisible(win7Key('win7-tree-node-2-0-0'));
      await tester.tap(win7Key('win7-tree-node-2-0-0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<Text>(win7Key('win7-window-title')).data, '听读');
      expect(
        tester
            .widget<ContentZoneScreen>(find.byType(ContentZoneScreen))
            .section,
        ContentSection.audio,
      );
    });
  });

  group('书架/历史/下载：数据键与入口原样保留', () {
    test('小说源存档键未动', () {
      expect(NovelSourceStore.prefsKey, 'novel_py_imports');
      expect(NovelSourceStore.hiddenBuiltinKey, 'novel_builtin_json_hidden');
      expect(NovelSourceStore.removedBuiltinKey, 'novel_builtin_json_removed');
      expect(
        ContentZoneBinding.storageKey(ContentSection.audio),
        'content_zone_source_audio',
      );
      expect(
        ContentZoneBinding.storageKey(ContentSection.novel),
        'content_zone_source_novel',
      );
    });

    test('听书历史/断点/收藏走原来的存档键', () async {
      SharedPreferences.setMockInitialValues({});
      const record = AudioListenRecord(
        sourceId: 'fake_audio',
        sourceName: '听书甲',
        bookId: 'book1',
        title: '甲书',
      );
      await saveAudioHistory([record]);
      await saveAudioResume(record);
      await saveAudioFavorites([
        const AudioFavoriteEntry(
          sourceId: 'fake_audio',
          sourceName: '听书甲',
          bookId: 'book1',
          title: '甲书',
        ),
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('audioHistory'), isNotNull);
      expect(prefs.getString('audioResume'), isNotNull);
      expect(prefs.getString('audioFavorites'), isNotNull);
      expect((await loadAudioHistory()).single.bookId, 'book1');
      expect((await loadAudioResume('fake_audio', 'book1'))?.title, '甲书');
      expect((await loadAudioFavorites()).single.bookId, 'book1');
    });

    testWidgets('区屏入口键未动：书架/收听记录/收藏', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final binding = ContentZoneBinding(sourcesProvider: _fakeProvider);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentZoneScreen(
              section: ContentSection.novel,
              binding: binding,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('novel-bookshelf')), findsOneWidget);
      expect(find.byKey(const ValueKey('novel-import-py')), findsWidgets);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentZoneScreen(
              section: ContentSection.audio,
              binding: binding,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('audio-history')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-favorites')), findsOneWidget);
    });
  });
}
