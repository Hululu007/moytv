import 'package:moyi/models.dart';
import 'package:moyi/tvbox_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class FakeT4Repository extends FixtureRepository {
  final added = <CustomSourceSite>[];
  var _sequence = 0;

  @override
  Future<List<CustomSourceSite>> customSources() async => List.of(added);

  @override
  Future<CustomSourceSite> addCustomSource({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    final site = CustomSourceSite(
      id: 'custom:${_sequence++}',
      name: name,
      base: base,
      rule: rule,
      kind: kind,
    );
    added.add(site);
    return site;
  }
}

const _configWithT4 = '''
{
  "name": "合成 T4 配置",
  "sites": [
    {
      "key": "t4demo",
      "name": "T4 聚合演示",
      "type": 4,
      "api": "https://t4.example.test/vod?sites=all&timeout=5",
      "searchable": 1,
      "quickSearch": 1
    },
    {
      "key": "apidemo",
      "name": "接口演示",
      "type": 1,
      "api": "https://api.example.test/api.php/provide/vod/",
      "searchable": 1
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'type:4 site imports as a t4 custom source with its full api url',
    () async {
      final repository = FakeT4Repository();
      final report = await TvBoxImporter(
        repository,
      ).importFromText(_configWithT4, sourceIdentity: 't4-import-test');

      expect(report.t4Sites, 1);
      expect(report.apiSites, 1);
      expect(repository.added.length, 2);
      final t4call = repository.added.firstWhere((site) => site.kind == 't4');
      expect(t4call.base, 'https://t4.example.test/vod?sites=all&timeout=5');
      expect(t4call.rule, '');

      final stored = TvBoxConfigStore.configFor(report.configId);
      expect(stored, isNotNull);
      final t4site = stored!.sites.firstWhere((site) => site.kind == 't4');
      expect(t4site.coreId, t4call.id);
      expect(t4site.siteId, t4call.id);

      final registered = SourceSite.importedSites[t4site.coreId];
      expect(registered, isNotNull);
      expect(registered!.section, SourceSite.sectionVideo);
      expect(registered.origin, SourceSite.originConfig);
      expect(registered.configName, '合成 T4 配置');
    },
  );

  test('type:4 entry without an http api is skipped, not registered', () async {
    const config = '''
{
  "sites": [
    {"key": "bad", "name": "坏 T4", "type": 4, "api": "csp_Bad"},
    {"key": "good", "name": "好 T4", "type": 4, "api": "https://t4.example.test/vod?sites=all"}
  ]
}
''';
    final repository = FakeT4Repository();
    final report = await TvBoxImporter(
      repository,
    ).importFromText(config, sourceIdentity: 't4-import-negative-test');

    expect(report.t4Sites, 1);
    expect(repository.added.length, 1);
    expect(repository.added.single.kind, 't4');
    expect(report.notes.any((note) => note.contains('坏 T4')), isTrue);
  });

  test('import report summary counts t4 sites', () {
    final report = TvBoxImportReport('cfg', '合成配置')
      ..apiSites = 2
      ..t4Sites = 3;
    expect(report.summary, contains('站点 5 个'));
    expect(report.summary, contains('T4 3'));
  });
}
