// 网盘屏番号封面刮削：文件名/文件夹名带番号的条目（含文件夹）
// 后台补真封面；提不出番号不发查询；查不到保持占位；同番号会话
// 内只查一次。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:moyi/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _pan115 = SourceSite('cloud:pan115', '115网盘', '');

Drama _video(String id, String title) =>
    Drama(id: id, source: 'cloud:pan115', title: title, kind: 'video');

Drama _folder(String id, String title, String folderId) => Drama(
  id: id,
  source: 'cloud:pan115',
  title: title,
  kind: 'folder',
  folderId: folderId,
);

class _CoverFakeRepository extends FixtureRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (query.isNotEmpty) return CatalogPage([]);
    return CatalogPage([
      _folder('pan115:fd1', 'HRSM-032', 'fd1'),
      _video('pan115:v1', 'HJMO-652.mkv'),
      _video('pan115:v2', 'DV-390(53dv390).mp4'),
      _video('pan115:v3', '普通电影.mp4'),
      _video('pan115:v4', 'HJMO-652-C.mp4'),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpScreen(
    WidgetTester tester, {
    required PanCoverFetcher coverFetcher,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultimediaScreen(
            repository: _CoverFakeRepository(),
            store: store,
            driveSites: const [_pan115],
            onOpenDrama: (_) {},
            metadataFetcher:
                ({
                  required String title,
                  String? year,
                  String? typeHint,
                }) async => null,
            coverFetcher: coverFetcher,
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  String coverOf(WidgetTester tester, String id) {
    final tile = tester.widget<DramaTile>(find.byKey(ValueKey(id)));
    return tile.drama.cover;
  }

  group('网盘屏番号封面刮削', () {
    testWidgets('文件与文件夹都按番号补封面，普通名不发查询', (tester) async {
      final asked = <String>[];
      await pumpScreen(
        tester,
        coverFetcher: (code) async {
          asked.add(code);
          return 'https://img.example/$code.jpg';
        },
      );
      expect(coverOf(tester, 'pan115:fd1'), 'https://img.example/HRSM-032.jpg');
      expect(coverOf(tester, 'pan115:v1'), 'https://img.example/HJMO-652.jpg');
      expect(coverOf(tester, 'pan115:v2'), 'https://img.example/DV-390.jpg');
      expect(coverOf(tester, 'pan115:v3'), '');
      expect(asked, containsAll(<String>['HRSM-032', 'HJMO-652', 'DV-390']));
      expect(asked.length, 3);
    });

    testWidgets('同番号多条只查一次（缓存命中不重复请求）', (tester) async {
      final asked = <String>[];
      await pumpScreen(
        tester,
        coverFetcher: (code) async {
          asked.add(code);
          return 'https://img.example/$code.jpg';
        },
      );
      // HJMO-652.mkv 与 HJMO-652-C.mp4 同番号：只查一次，两条都上封面。
      expect(asked.where((code) => code == 'HJMO-652').length, 1);
      expect(coverOf(tester, 'pan115:v1'), 'https://img.example/HJMO-652.jpg');
      expect(coverOf(tester, 'pan115:v4'), 'https://img.example/HJMO-652.jpg');
    });

    testWidgets('查不到保持占位（封面为空）', (tester) async {
      await pumpScreen(tester, coverFetcher: (code) async => '');
      expect(coverOf(tester, 'pan115:fd1'), '');
      expect(coverOf(tester, 'pan115:v1'), '');
      expect(coverOf(tester, 'pan115:v2'), '');
    });

    testWidgets('刮削抛错不卡列表、条目照常显示', (tester) async {
      await pumpScreen(
        tester,
        coverFetcher: (code) async => throw StateError('刮削炸了'),
      );
      expect(find.text('HJMO-652.mkv'), findsOneWidget);
      expect(find.text('普通电影.mp4'), findsOneWidget);
      expect(coverOf(tester, 'pan115:v1'), '');
    });
  });
}
