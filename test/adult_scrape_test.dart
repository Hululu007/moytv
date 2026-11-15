import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/adult_scrape_service.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/models.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 有名表全员站源（顺序打乱传入时计划仍按固定顺序排，见计划测试）。
  List<SourceSite> chainSites() => [
    for (final id in adultScrapeSiteIds)
      SourceSite(id, '🔞$id', '', section: SourceSite.sectionVideo),
  ];

  const missav = 'jar:zakatv:ZakaMissav';
  const missavOff = 'jar:zakatv:ZakaMissavOff';
  const mirror = 'jar:zakatv:ZakaMirror';

  DramaDetail richDetail({required String id, required String source}) =>
      DramaDetail(
        Drama(
          id: id,
          source: source,
          title: 'HMN-927 富化标题',
          description: '富化简介',
          cover: 'https://cdn.test/cover.jpg',
          tags: const ['演员A', '标签B'],
        ),
        // 详情零集数：元数据命中也照常接纳，不要求可播线路。
        const [],
      );

  group('planAdultScrapeSiteIds', () {
    test('fixed order regardless of site table order, avdb last', () {
      final plans = planAdultScrapeSiteIds(
        sites: chainSites().reversed.toList(),
        siteVisible: (_) => true,
      );
      expect(plans, adultScrapeSiteIds);
      expect(plans.first, missav);
      expect(plans.last, BuiltinPySites.avdbSiteId);
    });

    test('current source excluded', () {
      final plans = planAdultScrapeSiteIds(
        sites: chainSites(),
        siteVisible: (_) => true,
        currentSourceId: missav,
      );
      expect(plans, isNot(contains(missav)));
      expect(plans.first, missavOff);
    });

    test('unregistered and hidden sites silently skipped', () {
      final sites = chainSites()
          .where((site) => site.id != missav)
          .toList();
      final plans = planAdultScrapeSiteIds(
        sites: sites,
        siteVisible: (id) => id != 'jar:zakatv:ZakaJable',
      );
      expect(plans, isNot(contains(missav)));
      expect(plans, isNot(contains('jar:zakatv:ZakaJable')));
      expect(plans.first, missavOff);
    });
  });

  group('AdultScrapeService.enrich', () {
    late _ScrapeFakeRepository repository;

    setUp(() {
      repository = _ScrapeFakeRepository();
    });

    test('① 番号命中 MissAV：只探首站、身份原样保留', () async {
      const original = Drama(
        id: 'orig-1',
        source: 'hongguo',
        title: 'HMN-927 测试片',
        episodes: 5,
        category: '短剧',
        tags: ['原标签'],
      );
      repository.searchResults = {
        missav: [
          const Drama(id: 'hmn-927', source: missav, title: 'hmn-927'),
        ],
      };
      repository.detailResults = {
        'hmn-927': richDetail(id: 'hmn-927', source: missav),
      };
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: [
          const SourceSite(
            'hongguo',
            '红果',
            '',
            section: SourceSite.sectionDrama,
          ),
          ...chainSites(),
        ],
      );
      expect(result, isNotNull);
      // 只带富化显示字段，身份字段一律是原始值。
      expect(result!.id, 'orig-1');
      expect(result.source, 'hongguo');
      expect(result.episodes, 5);
      expect(result.category, '短剧');
      expect(result.title, 'HMN-927 富化标题');
      expect(result.description, '富化简介');
      expect(result.cover, 'https://cdn.test/cover.jpg');
      expect(result.tags, ['演员A', '标签B']);
      // 首站命中即停，后面的站一个都不探。
      expect(repository.searchCalls, ['$missav:HMN-927']);
      // 同 id 才能走 merge 的同身份分支，不整体替换。
      final merged = original.merge(result);
      expect(merged.id, 'orig-1');
      expect(merged.source, 'hongguo');
      expect(merged.title, 'HMN-927 富化标题');
      expect(merged.episodes, 5);
    });

    test('② 大站无结果走 AVDB：按固定顺序探到底', () async {
      const original = Drama(
        id: 'orig-2',
        source: 'hongguo',
        title: 'HMN-927 测试片',
      );
      repository.searchResults = {
        missav: [
          const Drama(id: 'x', source: missav, title: '无关片'),
        ],
        BuiltinPySites.avdbSiteId: [
          const Drama(
            id: 'hmn-927',
            source: BuiltinPySites.avdbSiteId,
            title: 'HMN-927',
          ),
        ],
      };
      repository.detailResults = {
        'hmn-927': richDetail(
          id: 'hmn-927',
          source: BuiltinPySites.avdbSiteId,
        ),
      };
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: chainSites(),
      );
      expect(result, isNotNull);
      expect(result!.title, 'HMN-927 富化标题');
      expect(repository.searchCalls, [
        for (final id in adultScrapeSiteIds) '$id:HMN-927',
      ]);
      // 不匹配的命中不取详情，只有 AVDB 的命中取了详情。
      expect(repository.detailCallIds, ['hmn-927']);
    });

    test('③ 全无结果返回 null（调用方落回原链）', () async {
      const original = Drama(
        id: 'orig-3',
        source: 'hongguo',
        title: 'HMN-927 测试片',
      );
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: chainSites(),
      );
      expect(result, isNull);
      expect(repository.searchCalls.length, adultScrapeSiteIds.length);
      expect(repository.detailCalls, 0);
    });

    test('④ 非成人零请求：无番号且源站非 🔞', () async {
      const original = Drama(
        id: 'orig-4',
        source: 'hongguo',
        title: '测试短剧',
      );
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: [
          const SourceSite(
            'hongguo',
            '红果',
            '',
            section: SourceSite.sectionDrama,
          ),
          ...chainSites(),
        ],
      );
      expect(result, isNull);
      expect(repository.searchCalls, isEmpty);
      expect(repository.detailCalls, 0);
    });

    test('无站注册时不发请求', () async {
      const original = Drama(
        id: 'orig-5',
        source: 'hongguo',
        title: 'HMN-927 测试片',
      );
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(original, candidateSites: const []);
      expect(result, isNull);
      expect(repository.searchCalls, isEmpty);
      expect(repository.detailCalls, 0);
    });

    test('本站排除：当前站不进探查表', () async {
      const original = Drama(
        id: 'orig-6',
        source: missav,
        title: 'HMN-927 测试片',
      );
      repository.searchResults = {
        missav: [
          const Drama(id: 'hmn-927', source: missav, title: 'hmn-927'),
        ],
        missavOff: [
          const Drama(id: 'hmn-927-off', source: missavOff, title: 'hmn-927'),
        ],
      };
      repository.detailResults = {
        'hmn-927-off': richDetail(id: 'hmn-927-off', source: missavOff),
      };
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: chainSites(),
      );
      expect(result, isNotNull);
      expect(result!.source, missav);
      expect(
        repository.searchCalls.any((call) => call.startsWith('$missav:')),
        isFalse,
      );
      expect(repository.searchCalls.first, '$missavOff:HMN-927');
    });

    test('🔞源站无番号按标题搜：取首命中详情', () async {
      const original = Drama(
        id: 'orig-7',
        source: BuiltinPySites.javmenuSiteId,
        title: '没有番号的作品名',
      );
      repository.searchResults = {
        missav: [
          const Drama(id: 't1', source: missav, title: '没有番号的作品名'),
        ],
      };
      repository.detailResults = {
        't1': richDetail(id: 't1', source: missav),
      };
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: chainSites(),
      );
      expect(result, isNotNull);
      expect(result!.id, 'orig-7');
      expect(result.source, BuiltinPySites.javmenuSiteId);
      expect(repository.searchCalls.first, '$missav:没有番号的作品名');
    });

    test('未注册/不可见的站不探，只探其余站', () async {
      const original = Drama(
        id: 'orig-8',
        source: 'hongguo',
        title: 'HMN-927 测试片',
      );
      repository.searchResults = {
        missav: [
          const Drama(id: 'hmn-927', source: missav, title: 'hmn-927'),
        ],
        mirror: [
          const Drama(id: 'hmn-927-m', source: mirror, title: 'hmn-927'),
        ],
      };
      repository.detailResults = {
        'hmn-927-m': richDetail(id: 'hmn-927-m', source: mirror),
      };
      final sites = chainSites()
          .where((site) => site.id != missav)
          .toList();
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: sites,
        siteVisible: (id) => id != 'jar:zakatv:ZakaJable',
      );
      expect(result, isNotNull);
      expect(
        repository.searchCalls.any((call) => call.startsWith('$missav:')),
        isFalse,
      );
      expect(
        repository.searchCalls.any(
          (call) => call.startsWith('jar:zakatv:ZakaJable:'),
        ),
        isFalse,
      );
      expect(repository.searchCalls.first, '$missavOff:HMN-927');
      expect(repository.searchCalls, contains('$mirror:HMN-927'));
    });

    test('单站搜索失败不挡后站', () async {
      const original = Drama(
        id: 'orig-9',
        source: 'hongguo',
        title: 'HMN-927 测试片',
      );
      repository.searchFailures = {missav};
      repository.searchResults = {
        missavOff: [
          const Drama(id: 'hmn-927', source: missavOff, title: 'hmn-927'),
        ],
      };
      repository.detailResults = {
        'hmn-927': richDetail(id: 'hmn-927', source: missavOff),
      };
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: chainSites(),
      );
      expect(result, isNotNull);
      expect(repository.searchCalls.take(2), [
        '$missav:HMN-927',
        '$missavOff:HMN-927',
      ]);
    });

    test('单站超时不挡后站', () async {
      const original = Drama(
        id: 'orig-10',
        source: 'hongguo',
        title: 'HMN-927 测试片',
      );
      repository.hangSites = {missav};
      repository.searchResults = {
        missavOff: [
          const Drama(id: 'hmn-927', source: missavOff, title: 'hmn-927'),
        ],
      };
      repository.detailResults = {
        'hmn-927': richDetail(id: 'hmn-927', source: missavOff),
      };
      final service = AdultScrapeService(
        repository: repository,
        perSiteTimeout: const Duration(milliseconds: 50),
      );
      final result = await service.enrich(
        original,
        candidateSites: chainSites(),
      );
      expect(result, isNotNull);
      expect(repository.searchCalls.take(2), [
        '$missav:HMN-927',
        '$missavOff:HMN-927',
      ]);
    });

    test('空壳详情不算刮到：继续往下一家探', () async {
      const original = Drama(
        id: 'orig-11',
        source: 'hongguo',
        title: 'HMN-927 测试片',
      );
      repository.searchResults = {
        missav: [
          const Drama(id: 'bare', source: missav, title: 'HMN-927'),
        ],
        missavOff: [
          const Drama(id: 'hmn-927', source: missavOff, title: 'hmn-927'),
        ],
      };
      repository.detailResults = {
        'bare': DramaDetail(
          const Drama(id: 'bare', source: missav, title: 'HMN-927'),
          const [],
        ),
        'hmn-927': richDetail(id: 'hmn-927', source: missavOff),
      };
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrich(
        original,
        candidateSites: chainSites(),
      );
      expect(result, isNotNull);
      expect(result!.cover, 'https://cdn.test/cover.jpg');
      expect(repository.detailCallIds, ['bare', 'hmn-927']);
    });
  });

  group('AdultScrapeService.enrichFileName', () {
    late _ScrapeFakeRepository repository;

    setUp(() {
      repository = _ScrapeFakeRepository();
    });

    test('⑤ 网盘文件名提番号：首站命中即返回显示字段', () async {
      repository.searchResults = {
        missav: [
          const Drama(id: 'hmn-927', source: missav, title: 'hmn-927'),
        ],
      };
      repository.detailResults = {
        'hmn-927': richDetail(id: 'hmn-927', source: missav),
      };
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrichFileName(
        'HMN-927.mp4',
        candidateSites: chainSites(),
      );
      expect(result, isNotNull);
      expect(result!.title, 'HMN-927 富化标题');
      expect(result.description, '富化简介');
      expect(result.cover, 'https://cdn.test/cover.jpg');
      expect(result.tags, ['演员A', '标签B']);
      expect(repository.searchCalls, ['$missav:HMN-927']);
    });

    test('⑤ 网盘文件名无番号：零请求', () async {
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrichFileName(
        '仙剑 第1集.mp4',
        candidateSites: chainSites(),
      );
      expect(result, isNull);
      expect(repository.searchCalls, isEmpty);
      expect(repository.detailCalls, 0);
    });

    test('网盘文件名全无结果返回 null', () async {
      final service = AdultScrapeService(repository: repository);
      final result = await service.enrichFileName(
        'HMN-927.mp4',
        candidateSites: chainSites(),
      );
      expect(result, isNull);
      expect(repository.searchCalls.length, adultScrapeSiteIds.length);
    });
  });

  group('adultDramaToTmdbMetadata', () {
    test('只带标题/简介/封面，cast 留空', () {
      const drama = Drama(
        id: 'x',
        source: 's',
        title: 'HMN-927 富化标题',
        description: '富化简介',
        cover: 'https://cdn.test/cover.jpg',
        tags: ['演员A', '标签B'],
      );
      final meta = adultDramaToTmdbMetadata(drama);
      expect(meta.title, 'HMN-927 富化标题');
      expect(meta.overview, '富化简介');
      expect(meta.posterPath, 'https://cdn.test/cover.jpg');
      // tags 里分不清演员与标签，cast 宁缺毋滥。
      expect(meta.cast, isEmpty);
    });
  });
}

/// 刮削测试用仓库：只记录搜索/详情调用，命中与详情一律由测试预置。
class _ScrapeFakeRepository extends FixtureRepository {
  Map<String, List<Drama>> searchResults = {};
  Map<String, DramaDetail> detailResults = {};
  Set<String> searchFailures = {};
  Set<String> hangSites = {};
  final searchCalls = <String>[];
  final detailCallIds = <String>[];

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    for (final source in sources) {
      searchCalls.add('$source:$query');
      if (hangSites.contains(source)) {
        await Completer<void>().future;
      }
      if (searchFailures.contains(source)) {
        throw AppFailure('合成搜索失败');
      }
    }
    final items = <Drama>[];
    for (final source in sources) {
      items.addAll(searchResults[source] ?? const []);
    }
    return CatalogPage(items);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    detailCallIds.add(drama.id);
    final fixed = detailResults[drama.id];
    if (fixed != null) return fixed;
    return DramaDetail(drama, []);
  }
}
