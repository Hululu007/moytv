// 问题 4b（2026-11-27）：网盘文件夹也要出封面。番号链
// （_enrichCovers）本来就含文件夹（multimedia_cover_scrape_test
// 守），但标题刮削链（_enrich：成人链 → TMDB）此前用
// !isFolder 把文件夹整条排除——文件夹名只有片名、提不出番号
// 时无图可出。本测试守：标题文件夹进 _enrich 被取数、虚拟
// “全部”夹不取数、文件夹点按仍走下钻（不被刮削副本带偏）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _pan115 = SourceSite('cloud:pan115', '115网盘', '');

class _FolderRepo extends FixtureRepository {
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
    if (category == 'fdT') return CatalogPage([]);
    return CatalogPage([
      Drama(
        id: 'pan115:fdT',
        source: 'cloud:pan115',
        title: '某部电影 2024',
        kind: 'folder',
        folderId: 'fdT',
      ),
      Drama(
        id: 'pan115:all',
        source: 'cloud:pan115',
        title: '全部',
        kind: 'folder',
        folderId: '__all__',
      ),
      Drama(id: 'pan115:v1', source: 'cloud:pan115', title: '另一部片子.mkv'),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('标题文件夹进标题刮削链，虚拟全部夹不刮', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final fetchedTitles = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultimediaScreen(
            repository: _FolderRepo(),
            store: store,
            driveSites: const [_pan115],
            onOpenDrama: (_) {},
            metadataFetcher:
                ({
                  required String title,
                  String? year,
                  String? typeHint,
                }) async {
                  fetchedTitles.add(title);
                  return null;
                },
            coverFetcher: (code) async => '',
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      fetchedTitles.any((t) => t.contains('某部电影')),
      isTrue,
      reason: '标题文件夹应进 _enrich 取数，实际取数标题：$fetchedTitles',
    );
    expect(
      fetchedTitles.any((t) => t.contains('全部')),
      isFalse,
      reason: '虚拟“全部”夹不许取数，实际取数标题：$fetchedTitles',
    );
  });
}
