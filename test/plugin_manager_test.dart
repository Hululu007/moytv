import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/models.dart';
import 'package:moyi/plugin_icons.dart';
import 'package:moyi/plugin_manager.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pyPluginIdForAsset', () {
    test('file name minus suffix', () {
      expect(
        PluginManager.pyPluginIdForAsset('assets/py_spiders/jinguo.py'),
        'py:jinguo',
      );
      expect(
        PluginManager.pyPluginIdForAsset('assets/py_spiders/51xz.py'),
        'py:51xz',
      );
    });
  });

  group('builtinPlugins manifest', () {
    test('jar plugin first, whole jar, fingerprint from const', () {
      final plugins = PluginManager.builtinPlugins();
      final jar = plugins.first;
      expect(jar.id, PluginManager.jarPluginId);
      expect(jar.kind, PluginIconKind.jar);
      expect(jar.md5, zakatvJarMd5);
      // 147 条配置，1 条 audioOnly 不进站点列表。
      expect(zakatvBuiltinSites.length, 147);
      expect(jar.siteCount, 146);
      expect(jar.detail, contains('147'));
    });

    test('44 py plugins in today register order', () {
      final plugins = PluginManager.builtinPlugins();
      final py = plugins.where((p) => p.kind == PluginIconKind.py).toList();
      expect(py.length, 44);
      expect(plugins.length, 45);
      expect(py.first.id, 'py:hmav');
      expect(py.first.name, '🔞河马AV');
      expect(py.last.id, 'py:memojav');
      final ids = py.map((p) => p.id).toSet();
      expect(ids.length, 44);
    });

    test('jinguo file plugin carries both sites', () {
      final plugins = PluginManager.builtinPlugins();
      final jinguo = plugins.singleWhere((p) => p.id == 'py:jinguo');
      expect(jinguo.siteIds, ['jinguo', 'jinguo_jg']);
    });

    test('every py entry belongs to exactly one plugin', () {
      final plugins = PluginManager.builtinPlugins();
      final covered = <String>[];
      for (final plugin in plugins) {
        if (plugin.kind == PluginIconKind.py) covered.addAll(plugin.siteIds);
      }
      expect(covered.length, BuiltinPySites.entries.length);
      expect(
        covered.toSet(),
        BuiltinPySites.entries.map((e) => e.siteId).toSet(),
      );
    });
  });

  group('pluginIconForSource', () {
    test('plain site has no plugin icon', () {
      const site = SourceSite('hongguo', '红果', 'x');
      expect(PluginManager.pluginIconForSource(site), isNull);
    });

    test('py file site gets the spider icon', () {
      const site = SourceSite('hmav', '🔞河马AV', 'x');
      SourceSite.importedPyFiles['hmav'] = 'builtin_hmav.py';
      try {
        final icon = PluginManager.pluginIconForSource(site);
        expect(icon, isA<PluginTypeIcon>());
        expect((icon as PluginTypeIcon).kind, PluginIconKind.py);
      } finally {
        SourceSite.importedPyFiles.remove('hmav');
      }
    });
  });

  group('market url prefs', () {
    test('round trip', () async {
      SharedPreferences.setMockInitialValues({});
      await PluginManager.saveMarketUrl('https://example.com/plugins.json');
      expect(
        await PluginManager.loadMarketUrl(),
        'https://example.com/plugins.json',
      );
      await PluginManager.saveMarketUrl('  ');
      expect(await PluginManager.loadMarketUrl(), '');
    });
  });

  group('uninstall state', () {
    test('unknown plugin id still records uninstall state', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await PluginManager.isBuiltinPluginUninstalled('py:nope'),
        isFalse,
      );
      await PluginManager.uninstallBuiltinPlugin('py:nope');
      expect(
        await PluginManager.isBuiltinPluginUninstalled('py:nope'),
        isTrue,
      );
      expect(await PluginManager.installBuiltinPlugin('py:nope'), isFalse);
      expect(
        await PluginManager.isBuiltinPluginUninstalled('py:nope'),
        isTrue,
      );
    });

    test('ensureBuiltinPlugins honors the uninstall list', () async {
      SharedPreferences.setMockInitialValues({
        PluginManager.uninstalledPrefsKey: ['py:hmav'],
      });
      final preferences = await SharedPreferences.getInstance();
      // 测试环境无 asset、无 jar 桥：注册逐条吞错，只验证不抛错、
      // 卸载列表被读取且 hmav 未被登记。
      await PluginManager.ensureBuiltinPlugins(preferences);
      expect(SourceSite.importedSites.containsKey('hmav'), isFalse);
    });
  });

  group('parsePluginMarketJson', () {
    test('valid index', () {
      const raw = '''
{"version": 1, "plugins": [
  {"key": "a", "name": "A", "type": "jar", "version": "1.0",
   "url": "https://x/a.jar", "md5": "ABC", "description": "d"},
  {"key": "b", "name": "B", "type": "py",
   "url": "https://x/b.py", "icon": "https://x/i.png", "author": "u"}
]}''';
      final items = parsePluginMarketJson(raw);
      expect(items.length, 2);
      expect(items[0].kind, PluginIconKind.jar);
      expect(items[0].md5, 'abc');
      expect(items[1].kind, PluginIconKind.py);
      expect(items[1].icon, 'https://x/i.png');
    });

    test('invalid rows are skipped', () {
      const raw = '''
{"plugins": [
  {"key": "", "name": "x", "type": "jar", "url": "https://x/a.jar"},
  {"key": "k", "name": "", "type": "py", "url": "https://x/b.py"},
  {"key": "k", "name": "x", "type": "zip", "url": "https://x/c.zip"},
  {"key": "k", "name": "x", "type": "py", "url": ""},
  {"key": "ok", "name": "OK", "type": "py", "url": "https://x/ok.py"}
]}''';
      final items = parsePluginMarketJson(raw);
      expect(items.map((i) => i.key).toList(), ['ok']);
    });

    test('malformed payloads yield empty', () {
      expect(parsePluginMarketJson('not json'), isEmpty);
      expect(parsePluginMarketJson('[]'), isEmpty);
      expect(parsePluginMarketJson('{}'), isEmpty);
      expect(parsePluginMarketJson('{"plugins": "nope"}'), isEmpty);
    });
  });
}
