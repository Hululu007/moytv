import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moyi/jar_bridge.dart';
import 'package:moyi/models.dart';
import 'package:moyi/tvbox_config.dart';
import 'package:moyi/zoo_builtin_seed.dart';

import 'fixtures.dart';

class _RecordingRepository extends FixtureRepository {
  final removedCustomIds = <String>[];

  @override
  Future<void> removeCustomSource(String id) async {
    removedCustomIds.add(id);
  }
}

TvBoxConfigRecord _warehouse({
  required String configId,
  required String name,
  required List<TvBoxSiteRecord> sites,
}) => TvBoxConfigRecord(
  configId: configId,
  name: name,
  url: 'https://example.invalid/$configId.json',
  sites: sites,
  lives: const [],
  parseIds: const [],
  updatedAt: '2026-10-29T00:00:00Z',
);

Future<void> _restoreRecords(List<TvBoxConfigRecord> records) async {
  SharedPreferences.setMockInitialValues({
    'tvbox_configs': jsonEncode([
      for (final record in records) record.toJson(),
    ]),
  });
  final prefs = await SharedPreferences.getInstance();
  TvBoxConfigStore.restore(prefs);
}

TvBoxSiteRecord _jar({
  required String siteId,
  required String name,
  String className = 'com.example.Shared',
  String jarUrl = 'https://example.invalid/shared.jar',
}) => TvBoxSiteRecord(
  siteId: siteId,
  key: 'shared',
  name: name,
  kind: 'jar',
  className: className,
  jarUrl: jarUrl,
  jarMd5: 'md5',
);

TvBoxSiteRecord _api({required String name}) => TvBoxSiteRecord(
  siteId: 'custom:0123456789abcdef',
  key: 'sharedapi',
  name: name,
  kind: 'api',
  coreId: 'custom:0123456789abcdef',
);

void main() {
  test('builtin stations group the same station across warehouses', () async {
    await _restoreRecords([
      _warehouse(
        configId: 'zoo_test_aaaa',
        name: '仓 A',
        sites: [_jar(siteId: 'jar:aaaa:shared', name: '共享站 A')],
      ),
      _warehouse(
        configId: 'zoo_test_bbbb',
        name: '仓 B',
        sites: [_jar(siteId: 'jar:bbbb:shared', name: '共享站 B')],
      ),
    ]);
    final stations = ZooBuiltinSeeder.builtinStations();
    expect(stations.length, 1);
    expect(stations.first.lines.length, 2);
    expect(stations.first.lines.map((line) => line.configName).toList(), [
      '仓 A',
      '仓 B',
    ]);
    expect(stations.first.name, '共享站 A');
  });

  test('deleting one jar line keeps the other warehouse line', () async {
    final repository = _RecordingRepository();
    await _restoreRecords([
      _warehouse(
        configId: 'zoo_test_aaaa',
        name: '仓 A',
        sites: [_jar(siteId: 'jar:aaaa:shared', name: '共享站 A')],
      ),
      _warehouse(
        configId: 'zoo_test_bbbb',
        name: '仓 B',
        sites: [_jar(siteId: 'jar:bbbb:shared', name: '共享站 B')],
      ),
    ]);
    final removed = await ZooBuiltinSeeder.deleteSite(
      repository,
      'zoo_test_aaaa',
      _jar(siteId: 'jar:aaaa:shared', name: '共享站 A'),
    );
    expect(removed, isTrue);
    expect(TvBoxConfigStore.configFor('zoo_test_aaaa')!.sites, isEmpty);
    expect(TvBoxConfigStore.configFor('zoo_test_bbbb')!.sites.length, 1);
    expect(JarBridge.specFor('jar:bbbb:shared'), isNotNull);
    expect(JarBridge.specFor('jar:aaaa:shared'), isNull);
  });

  test('api backend is removed only when no line references it', () async {
    final repository = _RecordingRepository();
    await _restoreRecords([
      _warehouse(
        configId: 'zoo_test_aaaa',
        name: '仓 A',
        sites: [_api(name: '共享接口')],
      ),
      _warehouse(
        configId: 'zoo_test_bbbb',
        name: '仓 B',
        sites: [_api(name: '共享接口')],
      ),
    ]);
    await ZooBuiltinSeeder.deleteSite(
      repository,
      'zoo_test_aaaa',
      _api(name: '共享接口'),
    );
    expect(repository.removedCustomIds, isEmpty);
    await ZooBuiltinSeeder.deleteSite(
      repository,
      'zoo_test_bbbb',
      _api(name: '共享接口'),
    );
    expect(repository.removedCustomIds, ['custom:0123456789abcdef']);
  });

  test('deleting a station removes its lines from every warehouse', () async {
    final repository = _RecordingRepository();
    await _restoreRecords([
      _warehouse(
        configId: 'zoo_test_aaaa',
        name: '仓 A',
        sites: [
          _jar(siteId: 'jar:aaaa:shared', name: '共享站 A'),
          _jar(
            siteId: 'jar:aaaa:other',
            name: '其它站',
            className: 'com.example.Other',
            jarUrl: 'https://example.invalid/other.jar',
          ),
        ],
      ),
      _warehouse(
        configId: 'zoo_test_bbbb',
        name: '仓 B',
        sites: [_jar(siteId: 'jar:bbbb:shared', name: '共享站 B')],
      ),
    ]);
    final removed = await ZooBuiltinSeeder.deleteStation(
      repository,
      'jar:com.example.Shared@https://example.invalid/shared.jar',
    );
    expect(removed, 2);
    expect(
      TvBoxConfigStore.configFor('zoo_test_aaaa')!.sites.map((s) => s.name),
      ['其它站'],
    );
    expect(TvBoxConfigStore.configFor('zoo_test_bbbb')!.sites, isEmpty);
  });

  test('deleting a warehouse keeps other warehouses intact', () async {
    final repository = _RecordingRepository();
    await _restoreRecords([
      _warehouse(
        configId: 'zoo_test_aaaa',
        name: '仓 A',
        sites: [_jar(siteId: 'jar:aaaa:shared', name: '共享站 A')],
      ),
      _warehouse(
        configId: 'zoo_test_bbbb',
        name: '仓 B',
        sites: [_jar(siteId: 'jar:bbbb:shared', name: '共享站 B')],
      ),
    ]);
    final removed = await ZooBuiltinSeeder.deleteConfig(
      repository,
      'zoo_test_aaaa',
    );
    expect(removed, 1);
    expect(TvBoxConfigStore.configFor('zoo_test_aaaa'), isNull);
    expect(TvBoxConfigStore.configFor('zoo_test_bbbb')!.sites.length, 1);
    expect(SourceSite.importedSites.containsKey('jar:bbbb:shared'), isTrue);
  });

  test('seed flag short-circuits and never resurrects deleted lines', () async {
    final repository = _RecordingRepository();
    SharedPreferences.setMockInitialValues({
      'tvbox_configs': jsonEncode([
        _warehouse(configId: 'zoo_test_aaaa', name: '仓 A', sites: []).toJson(),
      ]),
      'zoo_builtin_seeded_v1': true,
    });
    final prefs = await SharedPreferences.getInstance();
    TvBoxConfigStore.restore(prefs);
    final added = await ZooBuiltinSeeder.seed(repository);
    expect(added, 0);
    expect(TvBoxConfigStore.configFor('zoo_test_aaaa')!.sites, isEmpty);
  });
}
