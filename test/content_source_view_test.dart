import 'package:moyi/content_source_screen.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/tvbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('py view only lists py records', () {
    const records = [
      ImportedSiteRecord(
        id: 'py:a',
        name: 'A站',
        type: 'py',
        fileName: 'a.py',
        contentHash: 'h1',
      ),
      ImportedSiteRecord(
        id: 'js:b',
        name: 'B站',
        type: 'js',
        fileName: 'b.js',
        contentHash: 'h2',
      ),
      ImportedSiteRecord(
        id: 'py:c',
        name: 'C站',
        type: 'py',
        fileName: 'c.py',
        contentHash: 'h3',
      ),
    ];
    expect(pySiteRecords(records).map((record) => record.id), ['py:a', 'py:c']);
  });

  test('config view groups sites by config', () {
    final groups = configSiteGroups([
      TvBoxConfigRecord(
        configId: 'cfg1',
        name: '配置一',
        url: 'https://example.com/one.json',
        sites: const [
          TvBoxSiteRecord(siteId: 's1', key: 'k1', name: '站点一', kind: 'api'),
          TvBoxSiteRecord(siteId: 's2', key: 'k2', name: '站点二', kind: 'py'),
        ],
        lives: const [],
        parseIds: const [],
        updatedAt: '',
      ),
      TvBoxConfigRecord(
        configId: 'cfg2',
        name: '配置二',
        url: '',
        sites: const [
          TvBoxSiteRecord(siteId: 's3', key: 'k3', name: '站点三', kind: 'jar'),
        ],
        lives: const [],
        parseIds: const [],
        updatedAt: '',
      ),
    ]);
    expect(groups.map((group) => group.name), ['配置一', '配置二']);
    expect(groups[0].sites.map((site) => site.name), ['站点一', '站点二']);
    expect(groups[1].sites.map((site) => site.kind), ['jar']);
  });
}
