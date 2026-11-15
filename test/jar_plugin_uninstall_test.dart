import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/jar_import.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _row({
  required String siteId,
  required String jarId,
  required String md5,
  required String className,
  required String name,
}) => {
  'siteId': siteId,
  'jarId': jarId,
  'jarUrl': '/tmp/x/imported_jars/$md5.jar',
  'jarMd5': md5,
  'className': className,
  'name': name,
  'baseName': name,
};

Future<void> _restore(List<Map<String, dynamic>> rows) async {
  SharedPreferences.setMockInitialValues({
    'standalone_jar_sites': jsonEncode(rows),
  });
  JarImport.restore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await _restore([]);
    for (final id in [
      'jar:imp1111111111:AAA',
      'jar:imp1111111111:BBB',
      'jar:imp2222222222:CCC',
    ]) {
      JarBridge.unregister(id);
      SourceSite.importedSites.remove(id);
    }
  });

  test('groupForJarMd5 finds the installed group by jar md5', () async {
    await _restore([
      _row(
        siteId: 'jar:imp1111111111:AAA',
        jarId: 'imp1111111111',
        md5: 'a' * 32,
        className: 'com.example.AAA',
        name: '甲插件',
      ),
      _row(
        siteId: 'jar:imp2222222222:CCC',
        jarId: 'imp2222222222',
        md5: 'c' * 32,
        className: 'com.example.CCC',
        name: '丙插件',
      ),
    ]);
    final group = JarImport.groupForJarMd5('a' * 32);
    expect(group, isNotNull);
    expect(group!.displayName, '甲插件');
    expect(group.siteCount, 1);
    expect(JarImport.groupForJarMd5('z' * 32), isNull);
  });

  test('removeImportedJar only removes its own sites', () async {
    await _restore([
      _row(
        siteId: 'jar:imp1111111111:AAA',
        jarId: 'imp1111111111',
        md5: 'a' * 32,
        className: 'com.example.AAA',
        name: '甲插件',
      ),
      _row(
        siteId: 'jar:imp1111111111:BBB',
        jarId: 'imp1111111111',
        md5: 'a' * 32,
        className: 'com.example.BBB',
        name: '甲插件',
      ),
      _row(
        siteId: 'jar:imp2222222222:CCC',
        jarId: 'imp2222222222',
        md5: 'c' * 32,
        className: 'com.example.CCC',
        name: '丙插件',
      ),
    ]);
    expect(JarImport.importedJarGroups().length, 2);
    expect(SourceSite.importedSites.containsKey('jar:imp2222222222:CCC'), isTrue);

    await JarImport.removeImportedJar('imp1111111111');

    // 甲插件的两个站全撤，丙插件的站原样保留：卸只卸自己一个。
    expect(JarImport.siteFor('jar:imp1111111111:AAA'), isNull);
    expect(JarImport.siteFor('jar:imp1111111111:BBB'), isNull);
    expect(JarImport.siteFor('jar:imp2222222222:CCC'), isNotNull);
    expect(JarBridge.specFor('jar:imp1111111111:AAA'), isNull);
    expect(JarBridge.specFor('jar:imp2222222222:CCC'), isNotNull);
    expect(
      SourceSite.importedSites.containsKey('jar:imp1111111111:AAA'),
      isFalse,
    );
    expect(
      SourceSite.importedSites.containsKey('jar:imp2222222222:CCC'),
      isTrue,
    );
    expect(
      JarImport.importedJarGroups().map((g) => g.jarId).toList(),
      ['imp2222222222'],
    );
    // 持久化里也不留甲插件。
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString('standalone_jar_sites')!) as List;
    expect(stored.length, 1);
    expect(stored.first['jarId'], 'imp2222222222');
  });

  test('removeImportedJar with unknown jarId is a no-op', () async {
    await _restore([
      _row(
        siteId: 'jar:imp2222222222:CCC',
        jarId: 'imp2222222222',
        md5: 'c' * 32,
        className: 'com.example.CCC',
        name: '丙插件',
      ),
    ]);
    await JarImport.removeImportedJar('imp9999999999');
    expect(JarImport.siteFor('jar:imp2222222222:CCC'), isNotNull);
  });
}
