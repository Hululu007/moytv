import 'dart:convert';
import 'dart:io';

import 'package:moyi/core_bridge.dart';
import 'package:moyi/models.dart';

/// 2026-11-14 从 🔞柚子短剧（youzidj.com）真实拉回的响应：用树内
/// assets/py_spiders/youzidj.py 的 homeContent() 经出口代理实拉，
/// 原始响应存于 ~/workspace/moyi_previews/fixtures/youzidj_raw.json。
/// duanju.one 同日实拉被 CF 盾挡回 403（空列表），未用作数据来源。
class RealFixtureData {
  const RealFixtureData({
    required this.station,
    required this.stationName,
    required this.stationUrl,
    required this.fetchedAt,
    required this.categories,
    required this.items,
  });

  final String station;
  final String stationName;
  final String stationUrl;
  final String fetchedAt;
  final List<CatalogCategory> categories;
  final List<Drama> items;

  String get sourceLabel => '数据来源：$stationName ($stationUrl) · $fetchedAt 实拉';
}

/// 同步读文件：widget 测试跑在假时钟区里，真实异步 IO 等不到完成，
/// 与 preview_screens_test.dart 的 readAsBytesSync() 同一写法。
RealFixtureData loadRealFixture() {
  final file = File('test/fixtures/real_youzidj_20261114.json');
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final categories =
      (json['categories'] as List)
          .map(
            (entry) => CatalogCategory(
              entry['id'] as String,
              entry['name'] as String,
            ),
          )
          .toList();
  final items =
      (json['items'] as List)
          .map(
            (entry) => Drama(
              id: entry['id'] as String,
              source: json['station'] as String,
              title: entry['title'] as String,
              cover: entry['cover'] as String,
              description: entry['description'] as String? ?? '',
            ),
          )
          .toList();
  return RealFixtureData(
    station: json['station'] as String,
    stationName: '🔞柚子短剧',
    stationUrl: json['stationUrl'] as String,
    fetchedAt: json['fetchedAt'] as String,
    categories: categories,
    items: items,
  );
}

/// 用真实 fixture 供数据的仓库替身：分类与目录取 fixture，封面返回
/// fixture 里的真实封面地址（测试环境加载不到图片时显示占位）。
class RealFixtureRepository extends AppRepository {
  RealFixtureRepository(this.data);

  final RealFixtureData data;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => data.categories;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (query.isNotEmpty) {
      return CatalogPage(
        data.items.where((drama) => drama.title.contains(query)).toList(),
      );
    }
    return CatalogPage(data.items);
  }

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage(data.items);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(
        data.items.where((drama) => drama.title.contains(query)).toList(),
      );

  /// 测试环境没有下载好的本地封面文件：与 FixtureRepository 一致，
  /// 直接抛错走占位（cover() 契约返回的是本地文件路径，不是 URL；
  /// 真机上仓库会把远程封面下载到本地再返回路径）。
  @override
  Future<String> cover(Drama drama, {bool force = false}) async =>
      throw AppFailure('真实 fixture 没有本地封面文件');

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      DramaDetail(drama, const <Episode>[]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/real-fixture.mp4');

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async => current;

  @override
  Future<void> cancelPlayback() async {}

  @override
  Future<void> release(String session) async {}
}
